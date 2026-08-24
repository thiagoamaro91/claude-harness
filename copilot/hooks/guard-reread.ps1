#!/usr/bin/env pwsh
# guard-reread.ps1 - preToolUse hook (GitHub Copilot, Windows, read tools).
# Token economics: re-reading a >15KB file already read this session is blocked
# unless the file changed (mtime) or the read is targeted (offset/limit/range).
#
# PowerShell 7+ twin of guard-reread.sh. The size threshold, the mtime ledger,
# the targeted-read bypass and the dual-emitted deny are identical.
#
# --- differences from the POSIX twin, all deliberate ------------------------
#
# NO stat(1). The .sh twin branches between BSD and GNU stat flags. .NET's
# FileInfo gives Length and LastWriteTimeUtc directly, so that whole branch
# disappears. The ledger stores LastWriteTimeUtc ticks, which is finer-grained
# than the .sh twin's whole-second epoch; the comparison is exact-match either
# way, so the two behave the same.
#
# STATE DIRECTORY. $env:TEMP on Windows, $TMPDIR then /tmp elsewhere, with the
# same per-user naming and the same symlink refusal as the .sh twin.
#
# Fails OPEN throughout (unparseable payload, unreadable state dir): this guard
# saves tokens, and no token-economics rule is worth hard-stopping a session.

$ErrorActionPreference = 'Stop'

function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}

$INPUT_RAW = [Console]::In.ReadToEnd()

# Self-filter FIRST: VS Code ignores hook matchers, so without this a write or a
# shell call would be charged against the read ledger.
$toolName = ''
$m = [regex]::Match($INPUT_RAW, '"tool_?[nN]ame"\s*:\s*"([^"]*)"')
if ($m.Success) { $toolName = $m.Groups[1].Value }
$toolLc = $toolName.ToLowerInvariant()

# str_replace_editor is deliberately NOT here: it is primarily an edit tool, and
# charging it against the read ledger would be the wrong failure.
$readTools = @('', 'read', 'view', 'read_file', 'readfile', 'cat')
if ($readTools -notcontains $toolLc) { exit 0 }

$obj = $null
try { $obj = $INPUT_RAW | ConvertFrom-Json } catch { $obj = $null }
if ($null -eq $obj) { exit 0 }

$SID = Get-Prop $obj 'session_id'
if (-not $SID) { $SID = Get-Prop $obj 'sessionId' }
if (-not $SID) { exit 0 }
$SID = [regex]::Replace([string]$SID, '[^a-zA-Z0-9_-]', '')
if ([string]::IsNullOrEmpty($SID)) { exit 0 }

$ti = Get-Prop $obj 'tool_input'
if ($null -eq $ti) { $ti = Get-Prop $obj 'toolInput' }
if ($null -eq $ti) { exit 0 }

$FP = $null
foreach ($k in @('file_path', 'filePath', 'path', 'file')) {
    $v = Get-Prop $ti $k
    if ($v -is [string] -and -not [string]::IsNullOrEmpty($v)) { $FP = $v; break }
}
if (-not $FP) { exit 0 }
if (-not (Test-Path -LiteralPath $FP -PathType Leaf)) { exit 0 }

# Targeted reads are always fine. view_range is the text-editor-style spelling
# of the same intent and must bypass too, or partial reads get refused.
foreach ($k in @('offset', 'limit', 'view_range', 'viewRange', 'range', 'start_line', 'startLine', 'end_line', 'endLine')) {
    $v = Get-Prop $ti $k
    if ($null -ne $v) { exit 0 }
}

$info = $null
try { $info = [System.IO.FileInfo]::new((Resolve-Path -LiteralPath $FP).ProviderPath) } catch { exit 0 }
if ($null -eq $info) { exit 0 }

$SIZE = $info.Length
if ($SIZE -lt 15360) { exit 0 }
$MTIME = $info.LastWriteTimeUtc.Ticks.ToString()

# Per-user state dir, honoring the platform temp root, so this never reads or
# deletes another user's files on a shared box. Refuse a symlinked dir
# (squatting defense), exactly as the .sh twin does.
$tmpRoot = $env:TEMP
if (-not $tmpRoot) { $tmpRoot = $env:TMPDIR }
if (-not $tmpRoot) { $tmpRoot = '/tmp' }
$uid = if ($IsWindows) { $env:USERNAME } else { (& id -u) 2>$null }
if (-not $uid) { $uid = 'user' }
$uid = [regex]::Replace([string]$uid, '[^a-zA-Z0-9_-]', '')
$STATEDIR = Join-Path $tmpRoot ("copilot-reads-" + $uid)

try {
    if (Test-Path -LiteralPath $STATEDIR) {
        $di = Get-Item -LiteralPath $STATEDIR -Force
        if ($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { exit 0 }
    } else {
        New-Item -ItemType Directory -Path $STATEDIR -Force | Out-Null
    }
} catch { exit 0 }

$LEDGER = Join-Path $STATEDIR ("reads-" + $SID)

# Prune only our own stale state files, never a global temp pattern.
try {
    $cutoff = (Get-Date).AddDays(-1)
    Get-ChildItem -LiteralPath $STATEDIR -Filter 'reads-*' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

$entries = @()
if (Test-Path -LiteralPath $LEDGER) {
    try { $entries = @(Get-Content -LiteralPath $LEDGER -ErrorAction Stop) } catch { $entries = @() }
}

$key = $FP + '|'
$prev = $null
foreach ($line in $entries) {
    if ([string]$line -like ($key + '*')) { $prev = ([string]$line).Substring($key.Length) }
}

if ($prev -and $prev -eq $MTIME) {
    $kb = [int][Math]::Floor($SIZE / 1024)
    $reason = "BLOCKED by guard-reread (token economics): '$FP' (${kb}KB) was already fully read this session and has not changed. It is still in your context. Re-reading it re-bills the whole file on every subsequent turn. If you need a specific region, read with an offset/limit or a line range; if you need analysis over it, delegate to a subagent."
    $payload = [ordered]@{
        permissionDecision       = 'deny'
        permissionDecisionReason = $reason
        hookSpecificOutput       = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $reason
        }
    }
    Write-Output ($payload | ConvertTo-Json -Depth 20 -Compress)
    [Console]::Error.WriteLine($reason)
    exit 2
}

# Record / update
try {
    $kept = @()
    foreach ($line in $entries) {
        if (-not ([string]$line -like ($key + '*'))) { $kept += [string]$line }
    }
    $kept += ($FP + '|' + $MTIME)
    Set-Content -LiteralPath $LEDGER -Value $kept -Encoding utf8
} catch { }

exit 0

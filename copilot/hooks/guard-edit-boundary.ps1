#!/usr/bin/env pwsh
# preToolUse guardrail (GitHub Copilot, Windows, file-writing tools): opt-in
# edit boundary. While a state file names a boundary directory, edits outside it
# are blocked.
#
# PowerShell 7+ twin of guard-edit-boundary.sh. The boundary LOGIC is identical:
# same state-file resolution order including the Claude fallback, same
# canonicalization, same trailing-separator prefix match, same refusal to judge
# an unresolved traversal, same dual-emitted deny.
#
# While the state file exists, any file edit OUTSIDE the boundary directory it
# names is blocked. No state file = allow everything (opt-in per session).
#   arm:    $cfg = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
#           New-Item -ItemType Directory -Force (Join-Path $cfg 'hooks/state') | Out-Null
#           Set-Content -LiteralPath (Join-Path $cfg 'hooks/state/edit-boundary') -Value 'C:\abs\dir'
#   disarm: Remove-Item -LiteralPath (Join-Path $cfg 'hooks/state/edit-boundary')
# The edit-freeze skill wraps the POSIX form of these two commands.
#
# Honest limits: stops the file tools only, NOT the shell tool (redirection
# still writes); the state file is global, so arm it only while a single session
# is active. Boundary paths may contain spaces: the path is read as a raw line
# and never whitespace-split.
#
# --- differences from the POSIX twin, all deliberate ------------------------
#
# CASE-INSENSITIVE PATH COMPARISON. Windows filesystems are case-insensitive, so
# the prefix match is too. The .sh twin stays case-sensitive because POSIX
# filesystems are. The two are therefore NOT byte-identical in behavior, and
# that is correct on each platform rather than a porting slip.
#
# SEPARATOR NORMALIZATION. The payload may carry backslashes, forward slashes,
# or a mix. Both sides of the comparison are normalized before matching, so a
# boundary written one way still matches a path written the other.
#
# NO EXTERNAL DEPENDENCIES, so the .sh twin's missing-jq fail-closed branch has
# no counterpart. Its equivalent is a JSON parse failure, which fails closed for
# the same reason: a boundary that cannot read the path must not allow the edit.

$ErrorActionPreference = 'Stop'

$LOG = $env:GUARD_LOG
if (-not $LOG) {
    $cop = $env:COPILOT_HOME
    if (-not $cop) { $cop = Join-Path $HOME '.copilot' }
    $LOG = Join-Path (Join-Path $cop 'hooks') 'guard.log'
}

function Write-GuardLog([string]$line) {
    try {
        $dir = Split-Path -Parent $LOG
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $LOG -Value $line -Encoding utf8
    } catch { }
}

function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}

# State-file resolution, in order: explicit override, Copilot path, Claude path.
#
# The Claude fallback is what makes the feature work at all. The edit-freeze
# skill is SHARED verbatim between the two targets and its arm/disarm commands
# name the Claude config directory. Without this fallback the skill would arm a
# file this hook never reads, and the boundary would be silently dead: the worst
# possible failure for a guard, because the user believes edits are frozen and
# they are not.
$STATE = $env:EDIT_BOUNDARY_FILE
if (-not $STATE) {
    $cop = $env:COPILOT_HOME
    if (-not $cop) { $cop = Join-Path $HOME '.copilot' }
    $STATE = Join-Path $cop 'hooks/state/edit-boundary'
    if (-not (Test-Path -LiteralPath $STATE)) {
        $cl = $env:CLAUDE_CONFIG_DIR
        if (-not $cl) { $cl = Join-Path $HOME '.claude' }
        $claudeState = Join-Path $cl 'hooks/state/edit-boundary'
        if (Test-Path -LiteralPath $claudeState) { $STATE = $claudeState }
    }
}

# Not armed: allow. The common case, kept fast and checked before stdin is read.
if (-not (Test-Path -LiteralPath $STATE)) { exit 0 }

$INPUT_RAW = [Console]::In.ReadToEnd()

# Self-filter FIRST, on the raw text, for the same reason as the other guards:
# VS Code ignores hook matchers, so an armed boundary would otherwise refuse
# READS outside the directory, which was never the policy.
$toolName = ''
$m = [regex]::Match($INPUT_RAW, '"tool_?[nN]ame"\s*:\s*"([^"]*)"')
if ($m.Success) { $toolName = $m.Groups[1].Value }
$toolLc = $toolName.ToLowerInvariant()

# An empty tool name is treated as in-scope: the payload is malformed, and while
# a boundary is deliberately armed the protective direction is to evaluate the
# path rather than skip it. A payload with no path key still falls through.
$writeTools = @('', 'write', 'edit', 'multiedit', 'notebookedit', 'create', 'create_file',
                'createfile', 'str_replace', 'str_replace_editor', 'apply_patch',
                'insert_edit_into_file')
if ($writeTools -notcontains $toolLc) { exit 0 }

function Deny([string]$reason) {
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
    [Console]::Error.WriteLine("BLOCKED: $reason")
    exit 2
}

$obj = $null
try { $obj = $INPUT_RAW | ConvertFrom-Json } catch { $obj = $null }
if ($null -eq $obj) {
    Write-GuardLog ("{0} guard-edit-boundary: unparseable payload, failing closed" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Deny 'payload could not be parsed, cannot verify edit boundary (failing closed)'
}

$BOUNDARY = ''
try {
    $lines = @(Get-Content -LiteralPath $STATE -ErrorAction Stop)
    if ($lines.Count -gt 0) { $BOUNDARY = [string]$lines[0] }
} catch { $BOUNDARY = '' }
if ([string]::IsNullOrWhiteSpace($BOUNDARY)) { exit 0 }

$ti = Get-Prop $obj 'tool_input'
if ($null -eq $ti) { $ti = Get-Prop $obj 'toolInput' }
if ($null -eq $ti) { exit 0 }

$FILE = $null
foreach ($k in @('file_path', 'filePath', 'path', 'file', 'notebook_path', 'notebookPath')) {
    $v = Get-Prop $ti $k
    if ($v -is [string] -and -not [string]::IsNullOrEmpty($v)) { $FILE = $v; break }
}
# No file path in the input: not a file edit we can judge; allow.
if (-not $FILE) { exit 0 }

# Normalize separators, then resolve relative paths against the session cwd.
function ConvertTo-Slash([string]$p) { return ($p -replace '\\', '/') }

$fileNorm = ConvertTo-Slash $FILE
if (-not [System.IO.Path]::IsPathRooted($FILE) -and -not ($fileNorm -match '^[A-Za-z]:/')) {
    $FILE = Join-Path (Get-Location).ProviderPath $FILE
}

# Canonicalize the directory part so symlinks and ".." cannot sidestep the
# prefix match. [IO.Path] and Resolve-Path rather than string splitting.
$dirPart = [System.IO.Path]::GetDirectoryName($FILE)
$leaf = [System.IO.Path]::GetFileName($FILE)
$resolvedDir = $null
if ($dirPart) {
    try { $resolvedDir = (Resolve-Path -LiteralPath $dirPart -ErrorAction Stop).ProviderPath }
    catch { $resolvedDir = $dirPart }
}
if ($resolvedDir) { $FILE = [System.IO.Path]::Combine($resolvedDir, $leaf) }

# If the directory could not be canonicalized (it does not exist yet), a ".."
# component may survive and defeat the prefix match. Fail closed rather than
# boundary-check a path that cannot be resolved.
$fileFwd = ConvertTo-Slash $FILE
if (('/' + $fileFwd + '/') -like '*/../*') {
    Write-GuardLog ("{0} BLOCKED: edit-boundary unresolved-traversal {1} :: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $BOUNDARY, $FILE)
    Deny "$FILE has an unresolved '..' component and cannot be verified against the edit boundary ($BOUNDARY). Create the parent directory or pass a fully resolved path."
}

# Canonicalize the boundary the same way, or a symlinked prefix (macOS
# /tmp -> /private/tmp) breaks the match between the two sides.
$boundaryTrimmed = (ConvertTo-Slash $BOUNDARY).TrimEnd('/')
try {
    $canon = (Resolve-Path -LiteralPath $boundaryTrimmed -ErrorAction Stop).ProviderPath
    $boundaryTrimmed = (ConvertTo-Slash $canon).TrimEnd('/')
} catch { }

$fileFwd = ConvertTo-Slash $FILE

# Trailing-separator prefix match: /src/ does not match /src-old. Case-insensitive
# on Windows because the filesystem is; see the header note.
$cmp = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if ($fileFwd.Equals($boundaryTrimmed, $cmp) -or $fileFwd.StartsWith($boundaryTrimmed + '/', $cmp)) {
    exit 0
}

Write-GuardLog ("{0} BLOCKED: edit-boundary {1} :: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $BOUNDARY, $FILE)
Deny "$FILE is outside the armed edit boundary ($BOUNDARY). If this edit is intentional, disarm first by deleting $STATE"

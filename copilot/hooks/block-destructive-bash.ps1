#!/usr/bin/env pwsh
# preToolUse guardrail (GitHub Copilot, Windows): destructive-command policy.
#
# PowerShell 7+ twin of block-destructive-bash.sh. The POLICY is identical and
# deliberately unchanged: same three-tier rm handling, same ephemeral allowlist,
# same hard blocks, same dual-emitted contracts, same self-filter ordering.
# Where the two differ at all it is noted inline and in
# docs/copilot-port_design_2026-08-24.md.
#
#   1. ALLOW untouched  - every rm -rf target matches the ephemeral allowlist.
#   2. REWRITE to trash - simple single rm invocation, emitted as a rewrite with
#                         permissionDecision "allow" (the bin is reversible).
#   3. BLOCK            - compound/quoted rm -rf a token rewrite cannot handle
#                         deterministically.
# Hard blocks unchanged: find -delete, git clean -f, git push --force,
# git reset --hard, git checkout/restore ".", SQL DROP/TRUNCATE.
#
# --- differences from the POSIX twin, all deliberate ------------------------
#
# NO EXTERNAL DEPENDENCIES. The .sh twin fails closed when jq is missing.
# PowerShell parses JSON natively, so that failure mode does not exist here. The
# equivalent guard is a JSON PARSE failure, which fails closed the same way and
# for the same reason: a guard that cannot read the command must not allow it.
#
# THE RECYCLE BIN REPLACES `trash`. Windows ships no trash CLI, so tier 2
# rewrites to `pwsh -NoProfile -File <hooks>/lib/recycle.ps1 <targets>`, a
# helper this harness installs. $env:HARNESS_TRASH_CMD overrides it with any
# command of your choosing, exactly as in the .sh twin. With neither available
# (notably on non-Windows, where the Recycle Bin has no meaning) tier 2 BLOCKS
# instead of rewriting, which is the same safe direction the .sh twin takes when
# no trash binary is on PATH.
#
# PATH SEPARATORS. The payload may carry a Windows path with backslashes, a
# POSIX path with forward slashes, or a mix. Targets are normalized to forward
# slashes before the allowlist match so one set of patterns covers both.
#
# REGEX DIALECT. POSIX bracket classes ([[:space:]]) do not exist in .NET, so
# every pattern is transliterated to the .NET equivalent (\s, [a-zA-Z0-9]).
# Patterns live in single-quoted strings so PowerShell's backtick escape and $
# sigil cannot touch them.
#
# SPEED. Hook timeouts ALWAYS FAIL OPEN in Copilot, so a slow guard is a silent
# hole. Nothing here does I/O beyond reading stdin and appending one log line.

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
    } catch { }   # logging must never be the reason a guard fails
}

function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}

$INPUT_RAW = [Console]::In.ReadToEnd()

# Self-filter FIRST, on the raw text, before anything that can fail. Same
# ordering rationale as the .sh twin: VS Code parses hook matchers and then
# ignores them, so this hook sees every tool call, and a parse failure must not
# deny the whole session when only shell calls are this guard's business.
$toolName = ''
$m = [regex]::Match($INPUT_RAW, '"tool_?[nN]ame"\s*:\s*"([^"]*)"')
if ($m.Success) { $toolName = $m.Groups[1].Value }
$toolLc = $toolName.ToLowerInvariant()

$shellTools = @('', 'bash', 'shell', 'run_command', 'run_in_terminal', 'execute_command', 'terminal')
if ($shellTools -notcontains $toolLc) { exit 0 }

function Deny([string]$reason) {
    Write-GuardLog ("{0} BLOCKED: {1} :: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $reason, $script:CMD_LOG)
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

$script:CMD_LOG = ''

# Parse. A failure here is this twin's equivalent of the .sh twin's missing-jq
# branch: fail closed for a NAMED shell call, fail open when the payload did not
# even identify a tool, because denying every unidentifiable call bricks the
# session.
$obj = $null
try { $obj = $INPUT_RAW | ConvertFrom-Json } catch { $obj = $null }
if ($null -eq $obj) {
    if ([string]::IsNullOrEmpty($toolLc)) {
        Write-GuardLog ("{0} block-destructive-bash: unparseable payload and no tool_name, failing open" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        exit 0
    }
    Deny 'payload could not be parsed, cannot verify command safely (failing closed)'
}

$ti = Get-Prop $obj 'tool_input'
if ($null -eq $ti) { $ti = Get-Prop $obj 'toolInput' }
if ($null -eq $ti) { exit 0 }

# Probe for the command key in both casings, and remember which one matched so a
# rewrite is written back to the same place.
$CMDKEY = $null
$CMD = $null
foreach ($k in @('command', 'cmd', 'script', 'shellCommand', 'shell_command', 'commandLine', 'command_line')) {
    $v = Get-Prop $ti $k
    if ($v -is [string] -and -not [string]::IsNullOrEmpty($v)) { $CMDKEY = $k; $CMD = $v; break }
}
if (-not $CMDKEY) { exit 0 }

# Command-name de-obfuscation. A backslash before an ordinary character is a
# shell no-op, so \rm and r\m run the plain command while dodging the anchored
# matchers below. Detection and the rewrite both run against the normalized
# copy; CMD_RAW keeps the original for the audit log.
$CMD_RAW = $CMD
$script:CMD_LOG = ($CMD_RAW -replace "`r?`n", ' ')
if ($script:CMD_LOG.Length -gt 500) { $script:CMD_LOG = $script:CMD_LOG.Substring(0, 500) }
$CMD = [regex]::Replace($CMD, '\\([a-zA-Z0-9])', '$1')

function Write-AllowLog([string]$reason) {
    Write-GuardLog ("{0} ALLOWED: {1} :: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $reason, $script:CMD_LOG)
}

# --- ephemeral-path allowlist ----------------------------------------------
# Rebuildable or already-disposable targets where rm -rf is legitimate cleanup.
# Windows path comparison is case-insensitive by design (the filesystem is), and
# backslashes are normalized so one pattern set covers both separator styles.
function Test-Ephemeral([string]$t) {
    if ([string]::IsNullOrWhiteSpace($t)) { return $false }
    $p = $t -replace '\\', '/'

    # A traversal target is never ephemeral, whatever prefix it wears.
    if (('/' + $p + '/') -like '*/../*') { return $false }

    $p = $p.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }

    $globs = @(
        'node_modules', 'node_modules/*', '*/node_modules', '*/node_modules/*',
        '.next', '.next/*', '*/.next', '*/.next/*',
        '.claude/worktrees/?*', '*/.claude/worktrees/?*',
        '.copilot/worktrees/?*', '*/.copilot/worktrees/?*',
        'worktrees/?*', '*/worktrees/?*',
        '/private/tmp/claude-*scratchpad*', '/tmp/claude-*scratchpad*',
        '/private/tmp/copilot-*scratchpad*', '/tmp/copilot-*scratchpad*'
    )
    foreach ($g in $globs) { if ($p -like $g) { return $true } }

    # Home-anchored disposables, in both separator styles.
    $homeFwd = ($HOME -replace '\\', '/').TrimEnd('/')
    foreach ($base in @(($homeFwd + '/.Trash'), '~/.Trash')) {
        if ($p -like ($base + '/?*')) { return $true }
    }
    # Windows temp directories. $env:TEMP is the per-user temp root; anything
    # under it is disposable by definition.
    foreach ($envName in @('TEMP', 'TMP')) {
        $tv = [Environment]::GetEnvironmentVariable($envName)
        if ($tv) {
            $tf = ($tv -replace '\\', '/').TrimEnd('/')
            if ($tf -and ($p -like ($tf + '/?*'))) { return $true }
        }
    }
    return $false
}

# Extract each rm invocation segment. Per-segment matching avoids the flag-bleed
# and quoted-literal false positives a whole-command match suffers from.
$rmSegRe = '(^|[;&|`(]|(sudo|xargs|command|nohup|nice)\s+)\s*rm\s+[^;&|]*'
$recursiveRe = '(^|\s)-[a-zA-Z]*[rR]|--recursive'
$forceRe = '(^|\s)-[a-zA-Z]*[fF]|--force'

function Get-RmSegments([string]$text) {
    $out = @()
    foreach ($mm in [regex]::Matches($text, $rmSegRe)) { $out += $mm.Value }
    return $out
}
function Test-RmRf([string]$seg) {
    return ([regex]::IsMatch($seg, $recursiveRe, 'IgnoreCase') -and
            [regex]::IsMatch($seg, $forceRe, 'IgnoreCase'))
}
function Get-RmTargets([string]$seg) {
    $tokens = $seg -split '\s+' | Where-Object { $_ -ne '' }
    $targets = @()
    $started = $false
    foreach ($tok in $tokens) {
        if (-not $started) {
            if ($tok -match '(^|/)rm$' -or $tok -match '(^|\\)rm$') { $started = $true }
            continue
        }
        if ($tok.StartsWith('-')) { continue }
        $targets += $tok
    }
    return $targets
}

$rmSegs = Get-RmSegments $CMD
if ($rmSegs.Count -gt 0) {
    $sawRmRf = $false
    $needsAction = $false
    foreach ($seg in $rmSegs) {
        if (-not (Test-RmRf $seg)) { continue }
        $sawRmRf = $true
        $targets = Get-RmTargets $seg
        if ($targets.Count -eq 0) { $needsAction = $true; continue }
        $allOk = $true
        foreach ($t in $targets) {
            $tt = $t.Trim('"').Trim("'")
            if (-not (Test-Ephemeral $tt)) { $allOk = $false }
        }
        if (-not $allOk) { $needsAction = $true }
    }

    if ($sawRmRf -and -not $needsAction) {
        Write-AllowLog 'rm -rf on ephemeral allowlist path(s)'
    }
    elseif ($needsAction) {
        # Quoted-data check: a real rm command name is never inside quotes unless
        # handed to an interpreter. If stripping quoted spans removes every
        # rm -rf segment, the match was data (a grep pattern, a test fixture).
        $quotedOnly = $false
        $hasInterpreter = $false
        foreach ($needle in @('bash -c', 'sh -c', 'zsh -c', 'eval ', 'ssh ')) {
            if ($CMD.Contains($needle)) { $hasInterpreter = $true; break }
        }
        if (-not $hasInterpreter) {
            $stripped = [regex]::Replace($CMD, "'[^']*'", '')
            $stripped = [regex]::Replace($stripped, '"[^"]*"', '')
            $quotedOnly = $true
            foreach ($seg in (Get-RmSegments $stripped)) {
                if (Test-RmRf $seg) { $quotedOnly = $false }
            }
        }

        if ($quotedOnly) {
            Write-AllowLog 'rm -rf appears only inside quoted strings (data, not a command)'
        }
        else {
            # Rewrite only when the WHOLE command is one simple rm invocation:
            # no separators, substitution, redirection, quoting, or newline.
            # Anything else makes a token rewrite non-deterministic -> block.
            $simple = $true
            foreach ($ch in @(';', '&', '|', '`', '$', '(', ')', '{', '}', '<', '>', '"', "'")) {
                if ($CMD.Contains($ch)) { $simple = $false; break }
            }
            if ($CMD.Contains("`n") -or $CMD.Contains("`r")) { $simple = $false }

            # Resolve the reversible-delete mechanism.
            $trashCmd = $env:HARNESS_TRASH_CMD
            $rewritePrefix = $null
            if ($trashCmd) {
                $rewritePrefix = $trashCmd
            }
            elseif ($IsWindows) {
                # Microsoft.VisualBasic loads on non-Windows too, but the
                # SendToRecycleBin option throws there, so $IsWindows is the real
                # gate rather than the Add-Type result alone.
                $vbOk = $false
                try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; $vbOk = $true } catch { $vbOk = $false }
                if ($vbOk) {
                    $helper = Join-Path $PSScriptRoot (Join-Path 'lib' 'recycle.ps1')
                    if (Test-Path -LiteralPath $helper) {
                        $rewritePrefix = 'pwsh -NoProfile -File "' + $helper + '"'
                    }
                }
            }

            if ($simple -and $rewritePrefix -and [regex]::IsMatch($CMD, '^\s*rm\s')) {
                $tokens = $CMD -split '\s+' | Where-Object { $_ -ne '' }
                $keep = @()
                for ($i = 1; $i -lt $tokens.Count; $i++) {
                    if ($tokens[$i].StartsWith('-')) { continue }
                    $keep += $tokens[$i]
                }
                if ($keep.Count -gt 0) {
                    $newcmd = $rewritePrefix + ' ' + ($keep -join ' ')
                    $newArgs = [ordered]@{}
                    foreach ($prop in $ti.PSObject.Properties) { $newArgs[$prop.Name] = $prop.Value }
                    $newArgs[$CMDKEY] = $newcmd
                    $reason = "rm -rf rewritten to: $newcmd"
                    Write-GuardLog ("{0} REWRITTEN: rm -> {1} :: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $newcmd, $script:CMD_LOG)
                    $payload = [ordered]@{
                        permissionDecision       = 'allow'
                        permissionDecisionReason = $reason
                        modifiedArgs             = $newArgs
                        hookSpecificOutput       = [ordered]@{
                            hookEventName            = 'PreToolUse'
                            permissionDecision       = 'allow'
                            permissionDecisionReason = $reason
                            updatedInput             = $newArgs
                        }
                    }
                    Write-Output ($payload | ConvertTo-Json -Depth 20 -Compress)
                    exit 0
                }
            }
            Deny 'Use trash instead of rm -rf (unrewritable compound/quoted command)'
        }
    }
}

# find ... -delete
if ([regex]::IsMatch($CMD, '(^|[;&|(`]\s*)find\s[^;&|]*\s-delete(\s|$)')) {
    Deny 'Use trash instead of find -delete'
}

# git clean -f : force-removes untracked files.
if ([regex]::IsMatch($CMD, '(^|[;&|(`]\s*)git\s+clean\s') -and
    [regex]::IsMatch($CMD, $forceRe, 'IgnoreCase')) {
    Deny 'git clean -f removes untracked files; stage or stash instead'
}

# git push --force : rewrites remote history. --force-with-lease stays allowed:
# it refuses to clobber unseen work and is the form to reach for.
foreach ($mm in [regex]::Matches($CMD, '(^|[;&|`(]|(sudo|command)\s+)\s*git\s+push\s+[^;&|]*')) {
    if ([regex]::IsMatch($mm.Value, '(^|\s)--force(\s|$)|(^|\s)-[a-zA-Z]*f[a-zA-Z]*(\s|$)')) {
        Deny 'git push --force rewrites remote history; use --force-with-lease, or push manually'
    }
}

# git reset --hard : discards uncommitted changes irrecoverably.
if ([regex]::IsMatch($CMD, '(^|[;&|(`]\s*)git\s+reset\s[^;&|]*--hard')) {
    Deny 'git reset --hard discards uncommitted work; stash or commit first'
}

# git checkout . / git checkout -- . : whole-tree discard.
if ([regex]::IsMatch($CMD, '(^|[;&|(`]\s*)git\s+checkout\s+(--\s+)?\.(\s|$)')) {
    Deny 'git checkout . discards uncommitted work; stash first'
}

# git restore . ; git restore --staged . only unstages, so it stays allowed.
foreach ($mm in [regex]::Matches($CMD, '(^|[;&|`(]\s*)git\s+restore\s+[^;&|]*')) {
    if ($mm.Value -notmatch '--staged' -and [regex]::IsMatch($mm.Value, '(^|\s)\.(\s|$)')) {
        Deny 'git restore . discards uncommitted work; stash first'
    }
}

# SQL DROP / TRUNCATE reaching a shell client. Honest limit: SQL issued through
# an MCP server never reaches this hook. Bare TRUNCATE without TABLE is
# deliberately unmatched (coreutils `truncate -s` is legitimate). Authoring DDL
# into a .sql file is not execution, so a shell client must be present.
$sqlClient = '(^|[\s/])(psql|mysql|mariadb|sqlite3)(\s|$)'
if ([regex]::IsMatch($CMD, $sqlClient, 'IgnoreCase')) {
    if ([regex]::IsMatch($CMD, 'drop\s+(table|database|schema)\s', 'IgnoreCase')) {
        Deny 'SQL DROP detected; run destructive DDL yourself, not through the agent'
    }
    if ([regex]::IsMatch($CMD, 'truncate\s+table\s', 'IgnoreCase')) {
        Deny 'SQL TRUNCATE detected; run destructive DDL yourself, not through the agent'
    }
}

exit 0

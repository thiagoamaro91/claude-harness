#!/usr/bin/env pwsh
# preToolUse TRANSFORM (GitHub Copilot, Windows): rewrite em-dashes (U+2014) in
# content about to be written, instead of blocking the write and burning a model
# retry round-trip.
#
# PowerShell 7+ twin of block-em-dash.sh. The rewrite RULES, their ORDER, and
# the dual-emitted output contract are identical.
#
# House rule: never write U+2014. With EM standing for that character (never
# written literally in this file, so the transform cannot fire on its own source
# and the repo leak scan stays clean):
#   line-start "EM text"  -> "- text"   (list/dialogue dash)
#   spaced     "a EM b"   -> "a - b"    (already a separator, keep hyphen form)
#   tight      "aEMb"     -> "a, b"     (clause break, comma reads naturally)
#   leftovers  (mixed)    -> " - "
# An edit's OLD text is NEVER touched: it must keep matching the file bytes.
# That is structural rather than a special case, because only the new-content
# keys in $CONTENT_KEYS are ever rewritten and no old-text key appears there.
#
# --- differences from the POSIX twin, all deliberate ------------------------
#
# NO EXTERNAL DEPENDENCIES. The .sh twin shells out to perl for UTF-8-safe
# matching and fails open when perl or jq is missing. .NET strings are UTF-16
# natively and PowerShell parses JSON natively, so neither dependency nor either
# failure mode exists here.
#
# LINE ANCHORING. The .sh twin gets per-line "^" semantics free from `perl -pe`,
# which loops over lines. .NET needs RegexOptions.Multiline to match that, and
# rule 1 is the only rule that depends on it. Without Multiline the first rule
# would fire once for the whole payload rather than once per line, which is a
# silent behavior change rather than an error.
#
# TRAILING NEWLINES. The .sh twin needs a printf sentinel because $(...) strips
# them. [Console]::In.ReadToEnd() plus [regex]::Replace preserves them exactly,
# so no sentinel is needed. The e-trailing-newline case in the smoke test is the
# canary for this and runs against both twins.
#
# OUTPUT IS DUAL-EMITTED, matching the .sh twin: top-level modifiedArgs for the
# CLI and hookSpecificOutput.updatedInput for VS Code, same rewritten arguments
# in each, no permissionDecision in either so the normal permission flow still
# governs the write.
#
# ARGUMENT KEYS AND CASING: probed in both spellings, same list as the .sh twin.

$ErrorActionPreference = 'Stop'

# Log path, resolved in order: the GUARD_LOG override (the test suite points it
# at a temp file), the directory this script is INSTALLED IN, then the Copilot
# config dir. The script-dir step is what lets one twin serve both targets:
# under <copilot>/hooks it resolves to exactly the same guard.log as before,
# and under <claude>/hooks (the Windows install of the Claude target, see
# bin/install.sh --windows) it logs beside the Claude guards instead of into a
# .copilot tree that may not exist on that machine at all.
$LOG = $env:GUARD_LOG
if (-not $LOG) {
    if ($PSScriptRoot) {
        $LOG = Join-Path $PSScriptRoot 'guard.log'
    } else {
        $cop = $env:COPILOT_HOME
        if (-not $cop) { $cop = Join-Path $HOME '.copilot' }
        $LOG = Join-Path (Join-Path $cop 'hooks') 'guard.log'
    }
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

$INPUT_RAW = [Console]::In.ReadToEnd()

$obj = $null
try { $obj = $INPUT_RAW | ConvertFrom-Json } catch { $obj = $null }
# Fails OPEN on an unparseable payload: this is a convenience transform, and one
# em-dash slipping through is recoverable. Hard-stopping every write is not.
if ($null -eq $obj) { exit 0 }

$ti = Get-Prop $obj 'tool_input'
if ($null -eq $ti) { $ti = Get-Prop $obj 'toolInput' }
if ($null -eq $ti) { exit 0 }

$tool = Get-Prop $obj 'tool_name'
if (-not $tool) { $tool = Get-Prop $obj 'toolName' }
if (-not $tool) { $tool = 'unknown' }

# New-content keys only, in both casings. No old-text key belongs here, ever.
# A bare "text" key is deliberately excluded: no write tool in either harness
# uses it as its content key, and it is generic enough to appear on unrelated
# tools, which would draw a rewrite out of this hook on a tool it has no
# business touching.
$CONTENT_KEYS = @('content', 'file_text', 'fileText', 'new_string', 'newString', 'new_str', 'newStr')

$EM = [char]0x2014
$EM_ESC = [regex]::Escape($EM)

function Test-HasEmDash([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $false }
    return $s.IndexOf($EM) -ge 0
}

# Rewrite rules, applied in the same order as the .sh twin. Rule 1 uses
# Multiline so "^" means start-of-line, matching perl's per-line loop.
function Convert-EmDash([string]$s) {
    $r = [regex]::Replace($s, '^[ \t]*' + $EM_ESC + '[ \t]*', '- ', 'Multiline')
    $r = [regex]::Replace($r, '[ \t]+' + $EM_ESC + '[ \t]+', ' - ')
    $r = [regex]::Replace($r, '(?<=\S)' + $EM_ESC + '(?=\S)', ', ')
    $r = [regex]::Replace($r, $EM_ESC, ' - ')
    return $r
}

# Build a mutable ordered copy of tool_input, preserving every key and value.
function Copy-ToOrdered($src) {
    $d = [ordered]@{}
    foreach ($p in $src.PSObject.Properties) { $d[$p.Name] = $p.Value }
    return $d
}

$newArgs = Copy-ToOrdered $ti
$touched = $false

$fpath = $null
foreach ($k in @('file_path', 'filePath', 'path', 'file', 'notebook_path', 'notebookPath')) {
    $v = Get-Prop $ti $k
    if ($v -is [string] -and -not [string]::IsNullOrEmpty($v)) { $fpath = $v; break }
}
if (-not $fpath) { $fpath = '?' }

# --- batch-edit form: an `edits` array of per-edit objects -------------------
$edits = Get-Prop $ti 'edits'
if ($edits -is [System.Collections.IEnumerable] -and $edits -isnot [string]) {
    $editList = @($edits)
    if ($editList.Count -gt 0) {
        $rebuilt = @()
        foreach ($e in $editList) {
            if ($null -eq $e -or -not $e.PSObject) { $rebuilt += $e; continue }
            $ed = Copy-ToOrdered $e
            foreach ($k in $CONTENT_KEYS) {
                if (-not $ed.Contains($k)) { continue }
                $v = $ed[$k]
                if ($v -is [string] -and (Test-HasEmDash $v)) {
                    $ed[$k] = Convert-EmDash $v
                    $touched = $true
                }
            }
            $rebuilt += ,$ed
        }
        if ($touched) { $newArgs['edits'] = $rebuilt }
    }
}

# --- single-content form ----------------------------------------------------
foreach ($k in $CONTENT_KEYS) {
    if (-not $newArgs.Contains($k)) { continue }
    $v = $newArgs[$k]
    if ($v -is [string] -and (Test-HasEmDash $v)) {
        $newArgs[$k] = Convert-EmDash $v
        $touched = $true
    }
}

if (-not $touched) { exit 0 }

Write-GuardLog ("{0} TRANSFORMED: em-dash rewrite :: {1} ({2})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $fpath, $tool)

$payload = [ordered]@{
    modifiedArgs       = $newArgs
    hookSpecificOutput = [ordered]@{
        hookEventName = 'PreToolUse'
        updatedInput  = $newArgs
    }
}
Write-Output ($payload | ConvertTo-Json -Depth 20 -Compress)
exit 0

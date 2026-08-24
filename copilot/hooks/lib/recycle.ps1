#!/usr/bin/env pwsh
# recycle.ps1 - send paths to the Windows Recycle Bin.
#
# This is the Windows stand-in for the `trash` / `trash-put` CLI that
# block-destructive-bash.sh rewrites to on macOS and Linux. Windows ships no
# such command, so the harness provides one.
#
#   pwsh -NoProfile -File recycle.ps1 <path> [<path> ...]
#
# WHY A SEPARATE FILE rather than an inline -Command string in the rewritten
# command: the guard rewrites a destructive command into a reversible one, and
# the rewritten string is executed by whatever shell Copilot spawns. An inline
# PowerShell one-liner would carry nested quoting and `$` sigils whose survival
# depends on that shell (pwsh, cmd.exe, or Git Bash all treat them differently),
# which is not something the guard can verify. Rewriting to a plain
# `pwsh -NoProfile -File <script> <targets>` invocation keeps the emitted
# command quoting-free and mirrors exactly how the POSIX twin rewrites to an
# external binary.
#
# Exits 0 when every path was recycled or did not exist, 1 otherwise. Refuses
# to run anywhere but Windows: the Recycle Bin has no cross-platform meaning,
# and silently deleting instead would be the exact opposite of this script's
# purpose.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    [Console]::Error.WriteLine("recycle.ps1: the Recycle Bin is Windows-only; refusing to run on this platform. Nothing was deleted.")
    exit 1
}

if ($args.Count -eq 0) {
    [Console]::Error.WriteLine("recycle.ps1: no paths given.")
    exit 1
}

try {
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine("recycle.ps1: Microsoft.VisualBasic is unavailable, so nothing can be sent to the Recycle Bin. Nothing was deleted.")
    exit 1
}

$failed = 0
foreach ($p in $args) {
    $target = [string]$p
    if ([string]::IsNullOrWhiteSpace($target)) { continue }

    # -LiteralPath throughout: a target holding [ or ] is a real filename, not a
    # wildcard, and Test-Path without -LiteralPath would silently miss it.
    try {
        if (Test-Path -LiteralPath $target -PathType Container) {
            $full = (Resolve-Path -LiteralPath $target).ProviderPath
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $full,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
            Write-Output "recycled directory: $full"
        }
        elseif (Test-Path -LiteralPath $target) {
            $full = (Resolve-Path -LiteralPath $target).ProviderPath
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $full,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
            Write-Output "recycled file: $full"
        }
        else {
            # Matching `rm -f` semantics: a missing target is not an error.
            Write-Output "not found, nothing to do: $target"
        }
    }
    catch {
        [Console]::Error.WriteLine("recycle.ps1: FAILED on ${target}: $($_.Exception.Message)")
        $failed = 1
    }
}

exit $failed

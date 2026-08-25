#!/usr/bin/env bash
# Tests for the WINDOWS tier 2 of the Claude Code target: the settings template
# that wires the PowerShell twins, the manifest rows that install them, and the
# twins' behavior when they are fed CLAUDE-shaped preToolUse payloads.
#
#   bash claude/hooks/tests/test-claude-windows.sh
#   PWSH_BIN=/path/to/pwsh bash claude/hooks/tests/test-claude-windows.sh
#
# Three halves.
#
# The REPO half always runs. It asserts that the Windows template is valid
# JSON, that it differs from the POSIX template in exactly the intended way
# (same env, same permissions, same matchers, pwsh commands, no PostToolUse),
# that every .ps1 it names is a file this repo actually ships at the path the
# manifest installs it to, and that bin/install.sh honors the authored-win kind
# in both directions.
#
# The PAYLOAD half feeds each guard a CLAUDE-shaped preToolUse payload (tool
# names Write, Edit, Bash, Read; snake_case inner keys) and asserts the Claude
# contract on the way out. It runs once per ENGINE. The .sh engine always runs,
# so the expectations in this file are never vacuous, not even on a machine
# with no PowerShell: if a twin's contract drifts, the sh run catches it.
#
# The .ps1 engine runs only when pwsh is found, and is SKIPPED, not failed,
# otherwise: the POSIX side of this harness must stay testable on a machine
# with no PowerShell installed. On such a machine the PowerShell twins' own
# behavior is UNVERIFIED; the skip line says so.
#
# What the pwsh half checks is the CONTRACT, not just the presence of a key.
# Claude Code ignores a hookSpecificOutput block with no hookEventName, and it
# replaces tool_input wholesale from updatedInput, so a rewrite that drops
# file_path breaks the write instead of sanitizing it. Both are asserted.
#
# The em-dash inputs are built at runtime from bytes, so this file contains no
# literal U+2014 and stays consistent with the rule it helps enforce.
set -u

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
PWSH_BIN="${PWSH_BIN:-pwsh}"
POSIX_TPL="$REPO/claude/settings.work.template.json"
WIN_TPL="$REPO/claude/settings.work.windows.template.json"
MANIFEST="$REPO/manifest.txt"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT INT TERM
EM=$(printf '\xe2\x80\x94')   # U+2014, built at runtime so this file stays clean
pass=0; fail=0; skip=0

ENGINE=""
ok()   { echo "ok   $1"; pass=$((pass+1)); }
bad()  { echo "FAIL $1: $2"; fail=$((fail+1)); }
eq()   { # NAME EXPECT GOT
  n="$1"; [ -z "$ENGINE" ] || n="$ENGINE:$1"
  if [ "$2" = "$3" ]; then ok "$n"; else bad "$n" "got [$3], wanted [$2]"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 2; }
[ -f "$WIN_TPL" ] || { echo "FAIL: $WIN_TPL missing"; exit 1; }

# ----------------------------------------------------------------- repo half
if jq empty "$WIN_TPL" 2>/dev/null; then ok "w1-valid-json"; else bad w1-valid-json "jq empty rejected the template"; fi

eq w2-env-identical "$(jq -Sc '.env' "$POSIX_TPL")" "$(jq -Sc '.env' "$WIN_TPL")"
eq w3-permissions-identical "$(jq -Sc '.permissions' "$POSIX_TPL")" "$(jq -Sc '.permissions' "$WIN_TPL")"
eq w4-no-posttooluse false "$(jq -c '.hooks|has("PostToolUse")' "$WIN_TPL")"
eq w5-matchers-identical \
  "$(jq -c '[.hooks.PreToolUse[].matcher]' "$POSIX_TPL")" \
  "$(jq -c '[.hooks.PreToolUse[].matcher]' "$WIN_TPL")"
eq w6-four-guards 4 "$(jq '[.hooks.PreToolUse[].hooks[]]|length' "$WIN_TPL")"

# Every command must be the pwsh form, and the .ps1 it names must be a file in
# this repo at the path the manifest installs it to. A wired guard that points
# at nothing is worse than no guard: it looks configured and never fires.
jq -r '.hooks.PreToolUse[].hooks[].command' "$WIN_TPL" > "$TMPD/cmds"
while IFS= read -r cmd; do
  case "$cmd" in
    "pwsh -NoProfile -File __CLAUDE_HOME__/hooks/"*.ps1) ;;
    *) bad w7-command-form "not the pwsh form: $cmd"; continue ;;
  esac
  live="hooks/${cmd##*/hooks/}"
  repo_path=$(awk -F'|' -v l="$live" '$1=="authored-win" && $4==l {print $3}' "$MANIFEST")
  if [ -z "$repo_path" ]; then
    bad w7-manifest-row "no authored-win row installs $live"
  elif [ ! -f "$REPO/$repo_path" ]; then
    bad w7-file-exists "$repo_path named by the manifest is not in the repo"
  else
    ok "w7-wired $live -> $repo_path"
  fi
done < "$TMPD/cmds"

# Every authored-win row with a live path must exist in the repo, including the
# Recycle Bin helper, which no template names but the rewrite tier calls.
awk -F'|' '$1=="authored-win" && $4!="-" {print $3}' "$MANIFEST" > "$TMPD/winrows"
eq w8-authored-win-count 5 "$(wc -l < "$TMPD/winrows" | tr -d ' ')"
while IFS= read -r rp; do
  [ -f "$REPO/$rp" ] && ok "w8-exists $rp" || bad w8-exists "$rp is in the manifest but not in the repo"
done < "$TMPD/winrows"

# The installer must honor the kind in BOTH directions.
winout=$("$REPO/bin/install.sh" --tier 2 --windows --dry-run --config-dir "$TMPD/c1" 2>&1)
posout=$("$REPO/bin/install.sh" --tier 2 --no-windows --dry-run --config-dir "$TMPD/c2" 2>&1)
n=$(printf '%s\n' "$winout" | grep -c 'would install .*\.ps1$')
eq w9-windows-installs-twins 5 "$n"
n=$(printf '%s\n' "$posout" | grep -c 'would install .*\.ps1$')
eq w10-posix-installs-none 0 "$n"
case "$winout" in
  *"settings.work.windows.template.json"*) ok w11-windows-template-used ;;
  *) bad w11-windows-template-used "the windows dry run never names the windows template" ;;
esac
case "$posout" in
  *"settings.work.windows.template.json"*) bad w12-posix-template-used "the posix dry run named the windows template" ;;
  *) ok w12-posix-template-used ;;
esac

# -------------------------------------------------------------- payload half
HOOKS="$REPO/copilot/hooks"
export GUARD_LOG="$TMPD/guard.log"

# One guard invocation, dispatched by BASE NAME so no case names an extension.
run() {
  case "$ENGINE" in
    sh)  bash "$HOOKS/$1.sh" ;;
    ps1) "$PWSH_BIN" -NoProfile -File "$HOOKS/$1.ps1" ;;
  esac
}

# Claude-contract assertion: the block must carry hookEventName, or Claude Code
# ignores it outright.
ev() { printf '%s' "$1" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null; }

run_payload_cases() {

  # --- block-em-dash, Write ------------------------------------------------
  out=$(jq -n --arg c "a${EM}b" '{session_id:"win",tool_name:"Write",tool_input:{file_path:"/tmp/x.md",content:$c}}' | run block-em-dash 2>/dev/null); ec=$?
  eq p1-em-write-exit 0 "$ec"
  eq p1-em-write-event PreToolUse "$(ev "$out")"
  eq p1-em-write-content "a, b" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.content')"
  # updatedInput REPLACES tool_input, so every other key must survive it.
  eq p1-em-write-keeps-path /tmp/x.md "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.file_path')"

  # --- block-em-dash, Edit -------------------------------------------------
  out=$(jq -n --arg c "a${EM}b" '{session_id:"win",tool_name:"Edit",tool_input:{file_path:"/tmp/x.md",old_string:"a",new_string:$c}}' | run block-em-dash 2>/dev/null); ec=$?
  eq p2-em-edit-exit 0 "$ec"
  eq p2-em-edit-new "a, b" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.new_string')"
  eq p2-em-edit-keeps-old a "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.old_string')"

  # --- block-em-dash leaves a clean write alone ----------------------------
  out=$(jq -n '{session_id:"win",tool_name:"Write",tool_input:{file_path:"/tmp/x.md",content:"plain"}}' | run block-em-dash 2>/dev/null); ec=$?
  eq p3-em-clean-exit 0 "$ec"
  eq p3-em-clean-silent "" "$out"

  # --- block-destructive-bash, Bash ----------------------------------------
  out=$(jq -n '{session_id:"win",tool_name:"Bash",tool_input:{command:"git reset --hard HEAD~1",description:"t"}}' | run block-destructive-bash 2>/dev/null); ec=$?
  eq p4-bash-deny-exit 2 "$ec"
  eq p4-bash-deny-event PreToolUse "$(ev "$out")"
  eq p4-bash-deny-decision deny "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')"

  out=$(jq -n '{session_id:"win",tool_name:"Bash",tool_input:{command:"git status",description:"t"}}' | run block-destructive-bash 2>/dev/null); ec=$?
  eq p5-bash-allow-exit 0 "$ec"
  eq p5-bash-allow-silent "" "$out"

  # --- guard-edit-boundary, Write ------------------------------------------
  mkdir -p "$TMPD/$ENGINE/inside"
  : >"$TMPD/$ENGINE/inside/in.md"
  : >"$TMPD/$ENGINE/out.md"
  printf '%s\n' "$TMPD/$ENGINE/inside" > "$TMPD/$ENGINE/boundary"
  EDIT_BOUNDARY_FILE="$TMPD/$ENGINE/boundary"; export EDIT_BOUNDARY_FILE
  out=$(jq -n --arg f "$TMPD/$ENGINE/out.md" '{session_id:"win",tool_name:"Write",tool_input:{file_path:$f,content:"x"}}' | run guard-edit-boundary 2>/dev/null); ec=$?
  eq p6-boundary-deny-exit 2 "$ec"
  eq p6-boundary-deny-event PreToolUse "$(ev "$out")"
  eq p6-boundary-deny-decision deny "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')"
  out=$(jq -n --arg f "$TMPD/$ENGINE/inside/in.md" '{session_id:"win",tool_name:"Write",tool_input:{file_path:$f,content:"x"}}' | run guard-edit-boundary 2>/dev/null); ec=$?
  eq p7-boundary-allow-exit 0 "$ec"
  eq p7-boundary-allow-silent "" "$out"
  # A Read must pass an armed boundary: the policy is about writes.
  out=$(jq -n --arg f "$TMPD/$ENGINE/out.md" '{session_id:"win",tool_name:"Read",tool_input:{file_path:$f}}' | run guard-edit-boundary 2>/dev/null); ec=$?
  eq p8-boundary-read-exit 0 "$ec"
  eq p8-boundary-read-silent "" "$out"
  unset EDIT_BOUNDARY_FILE

  # --- guard-reread, Read ---------------------------------------------------
  big="$TMPD/$ENGINE/big.md"; small="$TMPD/$ENGINE/small.md"
  awk 'BEGIN{for(i=0;i<900;i++) printf "%s\n", "0123456789012345678901234567890123456789"}' > "$big"
  printf 'tiny\n' > "$small"
  rr() { jq -n --arg f "$1" --arg s "win-rr-$ENGINE" '{session_id:$s,tool_name:"Read",tool_input:{file_path:$f}}' | run guard-reread 2>/dev/null; }
  out=$(rr "$big"); ec=$?
  eq p9-reread-first-exit 0 "$ec"
  out=$(rr "$big"); ec=$?
  eq p9-reread-second-exit 2 "$ec"
  eq p9-reread-second-event PreToolUse "$(ev "$out")"
  eq p9-reread-second-decision deny "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')"
  out=$(rr "$small"); ec=$?
  out=$(rr "$small"); ec=$?
  eq p10-reread-small-allowed 0 "$ec"
}

for ENGINE in sh ps1; do
  if [ "$ENGINE" = "ps1" ] && ! command -v "$PWSH_BIN" >/dev/null 2>&1; then
    echo "SKIP ps1 engine: no pwsh at PWSH_BIN=$PWSH_BIN. The PowerShell twins'"
    echo "     Claude-contract behavior is UNVERIFIED on this machine. Run this"
    echo "     on a box with PowerShell 7+, or set PWSH_BIN."
    skip=$((skip+1))
    continue
  fi
  run_payload_cases
done
ENGINE=""

echo ""
echo "PASS=$pass FAIL=$fail SKIP=$skip"
[ "$fail" -eq 0 ] || exit 1
exit 0

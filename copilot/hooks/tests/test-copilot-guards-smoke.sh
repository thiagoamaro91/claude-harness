#!/usr/bin/env bash
# Smoke tests for the Copilot guard hooks shipped in this repo. Synthetic
# preToolUse JSON on stdin, in the snake_case shape Copilot emits; asserts exit
# codes, both deny contracts on a block, and both rewrite contracts on a
# transform.
#
# EVERY case runs TWICE: once against the POSIX .sh guard and once against its
# PowerShell .ps1 twin. The two are parameterized over one body rather than
# written as two suites, because two suites drift and nobody notices. Test names
# are prefixed with the engine, so a failure names which twin broke.
#
# Run it by path, not as an inline command string: the invocation itself would
# otherwise contain destructive substrings and trip the live guard.
#   bash copilot/hooks/tests/test-copilot-guards-smoke.sh
#   HOOKS_DIR=~/.copilot/hooks bash .../test-copilot-guards-smoke.sh   # test an install
#   PWSH_BIN=/path/to/pwsh bash .../test-copilot-guards-smoke.sh       # pwsh off PATH
#
# PWSH_BIN defaults to plain `pwsh`, resolved on PATH. No absolute path is
# hardcoded here on purpose: this repo forbids committed absolute home paths,
# and the leak scanner enforces it. On a machine where pwsh is installed
# somewhere unusual, pass PWSH_BIN explicitly.
#
# The .ps1 engine is SKIPPED, not failed, when no pwsh is found: the POSIX half
# of the harness must stay testable on a machine without PowerShell installed.
#
# The em-dash inputs are built at runtime from bytes, so this file contains no
# literal U+2014 and stays consistent with the rule it helps enforce.
#
# The pass-through block has no counterpart in the Claude suite: VS Code parses
# hook matchers but currently IGNORES them, so every hook fires on every tool
# call. Each guard must therefore self-filter and exit 0 with empty stdout on a
# tool it does not own.
set -u
DIR="${HOOKS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
PWSH_BIN="${PWSH_BIN:-pwsh}"
TMPDIR_T=$(mktemp -d)
export GUARD_LOG="$TMPDIR_T/test-guard.log"
: >"$GUARD_LOG"
EM=$(printf '\xe2\x80\x94')   # U+2014, built at runtime so this file stays clean
pass=0; fail=0; skip=0

# ENGINE is set by the driver loop at the bottom. hook_run dispatches one guard
# by BASE NAME, so no case below names a file extension.
ENGINE=sh
hook_run() { # $1 = guard base name; payload on stdin
  case "$ENGINE" in
    sh)  bash "$DIR/$1.sh" ;;
    ps1) "$PWSH_BIN" -NoProfile -File "$DIR/$1.ps1" ;;
  esac
}
D=block-destructive-bash
E=block-em-dash
EB=guard-edit-boundary
RR=guard-reread

# check NAME WANT_EXIT GOT_EXIT JQPATH EXPECT STDOUT
#   JQPATH '' means stdout must be empty; otherwise it is a path under the
#   rewritten arguments that must equal EXPECT. Rewrites are DUAL-EMITTED, so
#   the same value is asserted under BOTH .modifiedArgs (CLI contract) and
#   .hookSpecificOutput.updatedInput (VS Code contract). A rewrite that reaches
#   only one front end is a failure, not a partial pass.
check() {
  local name="${ENGINE}:$1" want=$2 got=$3 path=$4 expect=$5 out=$6
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: exit $got, wanted $want"; fail=$((fail+1)); return
  fi
  if [ -z "$path" ]; then
    if [ -n "$out" ]; then echo "FAIL $name: expected empty stdout, got: $out"; fail=$((fail+1)); return; fi
  else
    local a b
    a=$(printf '%s' "$out" | jq -r ".modifiedArgs${path}" 2>/dev/null)
    b=$(printf '%s' "$out" | jq -r ".hookSpecificOutput.updatedInput${path}" 2>/dev/null)
    if [ "$a" != "$expect" ]; then
      echo "FAIL $name: modifiedArgs$path = [$a], wanted [$expect]"; fail=$((fail+1)); return
    fi
    if [ "$b" != "$expect" ]; then
      echo "FAIL $name: hookSpecificOutput.updatedInput$path = [$b], wanted [$expect]"; fail=$((fail+1)); return
    fi
  fi
  pass=$((pass+1))
}

# check_deny NAME GOT_EXIT STDOUT
#   A block must exit 2 AND emit BOTH deny contracts: the top-level CLI form and
#   the VS Code hookSpecificOutput mirror. Every path must deny, so the call is
#   refused whichever way the runtime reads the response.
check_deny() {
  local name="${ENGINE}:$1" got=$2 out=$3 decision mirror
  if [ "$got" != "2" ]; then
    echo "FAIL $name: exit $got, wanted 2"; fail=$((fail+1)); return
  fi
  decision=$(printf '%s' "$out" | jq -r '.permissionDecision' 2>/dev/null)
  if [ "$decision" != "deny" ]; then
    echo "FAIL $name: permissionDecision = [$decision], wanted [deny]"; fail=$((fail+1)); return
  fi
  mirror=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
  if [ "$mirror" != "deny" ]; then
    echo "FAIL $name: hookSpecificOutput.permissionDecision = [$mirror], wanted [deny]"; fail=$((fail+1)); return
  fi
  if [ -z "$(printf '%s' "$out" | jq -r '.permissionDecisionReason // empty' 2>/dev/null)" ]; then
    echo "FAIL $name: empty permissionDecisionReason"; fail=$((fail+1)); return
  fi
  if [ -z "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)" ]; then
    echo "FAIL $name: empty hookSpecificOutput.permissionDecisionReason"; fail=$((fail+1)); return
  fi
  pass=$((pass+1))
}


# Every case below lives in one function and runs once per engine. Adding a
# case here automatically covers both twins, which is the whole point: two
# parallel suites would drift and the drift would be invisible.
run_all_cases() {
# ---------------------------------------------------------------- destructive
# Copilot's shell tool, snake_case envelope.
sh_json() { jq -n --arg c "$1" '{hook_event_name:"preToolUse",session_id:"smoke",tool_name:"shell",tool_input:{command:$c,description:"t"}}'; }
run_d() { out=$(sh_json "$1" | hook_run "$D" 2>/dev/null); ec=$?; }

run_d 'rm -rf node_modules';                       check d1-allow-nm 0 $ec '' '' "$out"
run_d 'rm -rf .next';                              check d2-allow-next 0 $ec '' '' "$out"
run_d 'rm -rf /opt/proj/node_modules/';            check d3-allow-abs-nm 0 $ec '' '' "$out"
run_d 'rm -rf ~/.copilot/worktrees/feature-x';     check d4-allow-worktree 0 $ec '' '' "$out"
run_d "rm -rf $HOME/.Trash/old";                   check d5-allow-trashdir 0 $ec '' '' "$out"
run_d 'rm -rf /private/tmp/copilot-501/abc/scratchpad/tmp'; check d6-allow-scratch 0 $ec '' '' "$out"

# The rewrite-to-trash tier needs a reversible-delete mechanism. The .sh twin
# looks for a trash CLI on PATH; the .ps1 twin uses the Windows Recycle Bin,
# which does not exist here. HARNESS_TRASH_CMD is the override BOTH twins
# honor, so exporting it makes the rewrite deterministic and the assertions
# identical across engines. With no mechanism at all both twins BLOCK instead,
# which is the documented safe fallback, so assert whichever this box produces.
TC="${HARNESS_TRASH_CMD:-}"
if [ -z "$TC" ]; then
  for c in trash trash-put gtrash; do command -v "$c" >/dev/null 2>&1 && { TC="$c"; break; }; done
fi
export HARNESS_TRASH_CMD="$TC"
if [ -n "$TC" ]; then
  run_d 'rm -rf src build';                        check d7-rewrite 0 $ec '.command' "$TC src build" "$out"
  run_d 'rm -rf docs/old-notes';                   check d8-rewrite2 0 $ec '.command' "$TC docs/old-notes" "$out"
  run_d 'rm -rf node_modules src';                 check d16-mixed-targets 0 $ec '.command' "$TC node_modules src" "$out"
  # A rewrite must also carry an explicit allow decision, and must echo the
  # unchanged fields back: modifiedArgs REPLACES the whole tool_input.
  run_d 'rm -rf src build'
  d7d=$(printf '%s' "$out" | jq -r '.permissionDecision')
  d7e=$(printf '%s' "$out" | jq -r '.modifiedArgs.description')
  if [ "$d7d" = "allow" ] && [ "$d7e" = "t" ]; then pass=$((pass+1));
  else echo "FAIL d7b-rewrite-allow-and-echo: decision=[$d7d] description=[$d7e]"; fail=$((fail+1)); fi
else
  echo "SKIP d7/d8/d16/d7b: no trash CLI on PATH, hook blocks instead of rewriting"
  skip=$((skip+4))
  run_d 'rm -rf src build';                        check_deny d7-block-no-trash $ec "$out"
fi

# .ps1 only: with HARNESS_TRASH_CMD cleared there is no Recycle Bin off
# Windows, so tier 2 must BLOCK rather than rewrite. That is the documented safe
# direction and the one recycle-path behavior that IS testable on a Mac.
if [ "$ENGINE" = "ps1" ]; then
  out=$(sh_json 'rm -rf src build' | HARNESS_TRASH_CMD= hook_run "$D" 2>/dev/null); ec=$?
  check_deny d7c-no-recyclebin-blocks $ec "$out"
fi

run_d 'cd /tmp && rm -rf stuff';                   check_deny d9-block-compound $ec "$out"
run_d 'rm -rf "My Dir"';                           check_deny d10-block-quoted $ec "$out"
run_d 'git reset --hard HEAD~1';                   check_deny d11-block-reset $ec "$out"
run_d 'psql -c "DROP TABLE users;"';               check_deny d12-block-drop $ec "$out"
run_d "find . -name '*.tmp' -delete";              check_deny d13-block-find $ec "$out"
run_d 'git push --force origin main';              check_deny d14-block-push $ec "$out"
run_d 'echo hello';                                check d15-clean 0 $ec '' '' "$out"
# A quoted rm -rf after a separator is data, not a command.
run_d 'grep -n "em-dash\|rm -rf blocked\|rm -fr blocked" notes.txt'; check d17-quoted-alternation-allowed 0 $ec '' '' "$out"
run_d 'bash -c "cd /tmp && rm -rf x"';             check_deny d18-interpreter-still-blocked $ec "$out"
# Authoring SQL into a file is not execution; a shell client still blocks.
run_d 'cat > /tmp/041_full.sql << SQLEOF
DROP TABLE users;
SQLEOF';                                           check d19-sql-authoring-allowed 0 $ec '' '' "$out"
run_d 'sqlite3 app.db "DROP TABLE users;"';        check_deny d20-sqlite-drop-blocked $ec "$out"
# Backslash de-obfuscation: \rm is the plain command.
run_d 'cd /tmp && \rm -rf stuff';                  check_deny d21-deobfuscated-blocked $ec "$out"
# Claude Code's tool name must still be honored: one script, both harnesses.
out=$(jq -n '{tool_name:"Bash",tool_input:{command:"git reset --hard HEAD~1"}}' | hook_run "$D" 2>/dev/null); ec=$?
check_deny d22-claude-toolname-blocked $ec "$out"

# -------------------------------------------------------------------- em dash
# Copilot write tool with the Claude-style `content` key.
we_json() { jq -n --arg c "$1" '{tool_name:"write",tool_input:{file_path:"/tmp/t.md",content:$c}}'; }
# text-editor-style write tool, whose new content lives under `file_text`.
ft_json() { jq -n --arg c "$1" '{tool_name:"create",tool_input:{path:"/tmp/t.md",file_text:$c}}'; }
# text-editor-style edit, old_str must survive untouched.
sr_json() { jq -n --arg o "$1" --arg n "$2" '{tool_name:"str_replace_editor",tool_input:{path:"/tmp/t.md",old_str:$o,new_str:$n}}'; }

out=$(we_json "a${EM}b" | hook_run "$E" 2>/dev/null); ec=$?
check e1-tight 0 $ec '.content' 'a, b' "$out"
out=$(we_json "a ${EM} b" | hook_run "$E" 2>/dev/null); ec=$?
check e2-spaced 0 $ec '.content' 'a - b' "$out"
out=$(we_json "${EM} quote line" | hook_run "$E" 2>/dev/null); ec=$?
check e3-linestart 0 $ec '.content' '- quote line' "$out"
out=$(we_json 'perfectly clean' | hook_run "$E" 2>/dev/null); ec=$?
check e4-clean 0 $ec '' '' "$out"
out=$(we_json "end${EM}dash
second line" | hook_run "$E" 2>/dev/null); ec=$?
check e5-multiline 0 $ec '.content' 'end, dash
second line' "$out"
out=$(we_json "one${EM}two
" | hook_run "$E" 2>/dev/null); ec=$?
check e6-trailing-newline 0 $ec '.content | length' '9' "$out"
# Key-agnostic: the same rewrite through a different argument key.
out=$(ft_json "a${EM}b" | hook_run "$E" 2>/dev/null); ec=$?
check e7-file_text-key 0 $ec '.file_text' 'a, b' "$out"
# An edit's OLD text is never rewritten, even when it holds an em-dash.
out=$(sr_json "old ${EM} text" 'clean new' | hook_run "$E" 2>/dev/null); ec=$?
check e8-oldstr-untouched 0 $ec '' '' "$out"
out=$(sr_json 'clean old' "new${EM}text" | hook_run "$E" 2>/dev/null); ec=$?
check e9-newstr-rewritten 0 $ec '.new_str' 'new, text' "$out"
# When both are present, only the new side moves.
out=$(sr_json "old ${EM} text" "new${EM}text" | hook_run "$E" 2>/dev/null); ec=$?
check e10-oldstr-preserved 0 $ec '.old_str' "old ${EM} text" "$out"
# A transform must NOT carry a permission decision: the normal flow governs.
if [ -z "$(printf '%s' "$out" | jq -r '.permissionDecision // empty' 2>/dev/null)" ]; then
  pass=$((pass+1))
else
  echo "FAIL e11-no-decision-on-transform: transform emitted a permissionDecision"; fail=$((fail+1))
fi

# ------------------------------------------------- tool_input round-trip
# modifiedArgs and updatedInput REPLACE the whole tool_input, so every unrelated
# field must survive the rewrite byte-identically. This is the case that catches
# a ConvertTo-Json depth truncation or a type coercion in the PowerShell twin:
# asserting only the field we changed would miss all of it.
fid_json=$(jq -n --arg c "a${EM}b" '{
  tool_name:"write",
  tool_input:{
    file_path:"/tmp/t.md",
    content:$c,
    nested:{deep:{deeper:{deepest:"kept"}},list:[1,2,3]},
    arr:["x","y"],
    emptyArr:[],
    nullField:null,
    boolField:true,
    numField:42,
    floatField:1.5,
    unicodeField:"caf\u00e9 \u00f1"
  }}')
out=$(printf '%s' "$fid_json" | hook_run "$E" 2>/dev/null); ec=$?
if [ "$ec" != "0" ]; then
  echo "FAIL ${ENGINE}:fid0-exit: exit $ec, wanted 0"; fail=$((fail+1))
else
  want=$(printf '%s' "$fid_json" | jq -S -c '.tool_input | .content = "a, b"')
  for fpath in .modifiedArgs .hookSpecificOutput.updatedInput; do
    got=$(printf '%s' "$out" | jq -S -c "$fpath" 2>/dev/null)
    if [ "$got" = "$want" ]; then
      pass=$((pass+1))
    else
      echo "FAIL ${ENGINE}:fid-roundtrip$fpath"
      echo "  want: $want"
      echo "  got:  $got"
      fail=$((fail+1))
    fi
  done
fi

# ------------------------------------------------------------- edit boundary
ebroot=$(mktemp -d); mkdir -p "$ebroot/inside"
ebstate="$TMPDIR_T/edit-boundary"
eb_json() { jq -n --arg f "$1" '{tool_name:"edit",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}'; }
eb_run() { out=$(eb_json "$1" | EDIT_BOUNDARY_FILE="$ebstate" hook_run "$EB" 2>/dev/null); ec=$?; }

eb_run "$ebroot/inside/x.md";                      check eb1-unarmed-allows 0 $ec '' '' "$out"
printf '%s\n' "$ebroot/inside" >"$ebstate"
eb_run "$ebroot/inside/x.md";                      check eb2-inside-allows 0 $ec '' '' "$out"
eb_run "$ebroot/outside.md";                       check_deny eb3-outside-blocks $ec "$out"
# Path key probing: the same file under the text-editor-style `path` key.
out=$(jq -n --arg f "$ebroot/outside.md" '{tool_name:"str_replace_editor",tool_input:{path:$f,old_str:"a",new_str:"b"}}' \
  | EDIT_BOUNDARY_FILE="$ebstate" hook_run "$EB" 2>/dev/null); ec=$?
check_deny eb4-path-key-blocks $ec "$out"
# An armed boundary must not touch reads: that is the fire-on-every-tool case.
out=$(jq -n --arg f "$ebroot/outside.md" '{tool_name:"read",tool_input:{file_path:$f}}' \
  | EDIT_BOUNDARY_FILE="$ebstate" hook_run "$EB" 2>/dev/null); ec=$?
check eb5-read-outside-allowed 0 $ec '' '' "$out"
rm -f "$ebstate"
eb_run "$ebroot/outside.md";                       check eb6-disarmed-allows 0 $ec '' '' "$out"

# State-path resolution WITHOUT the EDIT_BOUNDARY_FILE override, which every
# case above uses and which therefore never exercises the default. The
# edit-freeze skill is shared verbatim with the Claude target and arms the
# CLAUDE state path, so the hook must honor that path too or the boundary is
# silently dead on this target.
ebhome=$(mktemp -d)
mkdir -p "$ebhome/copilot/hooks/state" "$ebhome/claude/hooks/state"
eb_plain() { out=$(eb_json "$1" | COPILOT_HOME="$ebhome/copilot" CLAUDE_CONFIG_DIR="$ebhome/claude" hook_run "$EB" 2>/dev/null); ec=$?; }

eb_plain "$ebroot/outside.md";                     check eb7-neither-armed-allows 0 $ec '' '' "$out"
printf '%s\n' "$ebroot/inside" >"$ebhome/claude/hooks/state/edit-boundary"
eb_plain "$ebroot/outside.md";                     check_deny eb8-claude-state-honored $ec "$out"
eb_plain "$ebroot/inside/x.md";                    check eb9-claude-state-inside-allows 0 $ec '' '' "$out"
# The Copilot path wins when both exist.
printf '%s\n' "$ebroot" >"$ebhome/copilot/hooks/state/edit-boundary"
eb_plain "$ebroot/outside.md";                     check eb10-copilot-state-wins 0 $ec '' '' "$out"
rm -rf "$ebhome"

# --------------------------------------------------------------------- reread
big="$TMPDIR_T/big.md"
head -c 20000 /dev/zero | tr '\0' 'a' >"$big"
rr_json() { jq -n --arg f "$1" --arg s "$2" '{session_id:$s,tool_name:"read",tool_input:{file_path:$f}}'; }
SID="smoke$$"
out=$(rr_json "$big" "$SID" | hook_run "$RR" 2>/dev/null); ec=$?
check rr1-first-read-allowed 0 $ec '' '' "$out"
out=$(rr_json "$big" "$SID" | hook_run "$RR" 2>/dev/null); ec=$?
check_deny rr2-second-read-blocked $ec "$out"
# A targeted re-read must still pass, including the text-editor-style spelling.
out=$(jq -n --arg f "$big" --arg s "$SID" '{session_id:$s,tool_name:"view",tool_input:{path:$f,view_range:[1,20]}}' \
  | hook_run "$RR" 2>/dev/null); ec=$?
check rr3-view_range-bypasses 0 $ec '' '' "$out"
small="$TMPDIR_T/small.md"; printf 'tiny\n' >"$small"
out=$(rr_json "$small" "$SID" | hook_run "$RR" 2>/dev/null); ec=$?
out=$(rr_json "$small" "$SID" | hook_run "$RR" 2>/dev/null); ec=$?
check rr4-small-file-never-blocked 0 $ec '' '' "$out"
rm -f "${TMPDIR:-/tmp}/copilot-reads-$(id -u)/reads-${SID}" 2>/dev/null

# ------------------------------------------------------- matcher-ignored case
# VS Code parses matchers but currently IGNORES them, so every hook sees every
# tool. Each guard must exit 0 with empty stdout on a tool it does not own.
# The boundary guard is checked while ARMED, which is its worst case.
printf '%s\n' "$ebroot/inside" >"$ebstate"
for probe in \
  'grep|{"tool_name":"grep","tool_input":{"pattern":"rm -rf","path":"/etc"}}' \
  'web_fetch|{"tool_name":"web_fetch","tool_input":{"url":"https://example.com"}}' \
  'glob|{"tool_name":"glob","tool_input":{"pattern":"**/*.md"}}'
do
  pname="${probe%%|*}"; payload="${probe#*|}"
  for h in "$D" "$E" "$EB" "$RR"; do
    hname=$(basename "$h" .sh)
    out=$(printf '%s' "$payload" | EDIT_BOUNDARY_FILE="$ebstate" hook_run "$h" 2>/dev/null); ec=$?
    check "pt-${hname}-${pname}" 0 $ec '' '' "$out"
  done
done
rm -f "$ebstate"

# ------------------------------------------------- camelCase inner tool_input
# The ENVELOPE keys are snake_case, but VS Code sends the INNER tool_input
# properties in camelCase (tool_input.filePath) while the CLI may send them
# snake_case. Every guard must fire identically on both spellings; reading only
# one is a guard that silently never triggers on the other front end.
out=$(jq -n '{tool_name:"shell",tool_input:{command:"git reset --hard HEAD~1"}}' | hook_run "$D" 2>/dev/null); ec=$?
check_deny cc1-shell-snake $ec "$out"

out=$(jq -n --arg c "a${EM}b" '{tool_name:"write",tool_input:{filePath:"/tmp/t.md",content:$c}}' | hook_run "$E" 2>/dev/null); ec=$?
check cc2-emdash-camel-path 0 $ec '.content' 'a, b' "$out"
out=$(jq -n --arg c "a${EM}b" '{tool_name:"create",tool_input:{filePath:"/tmp/t.md",fileText:$c}}' | hook_run "$E" 2>/dev/null); ec=$?
check cc3-emdash-fileText 0 $ec '.fileText' 'a, b' "$out"
out=$(jq -n --arg o "old ${EM} text" --arg n "new${EM}text" \
  '{tool_name:"str_replace_editor",tool_input:{filePath:"/tmp/t.md",oldStr:$o,newStr:$n}}' | hook_run "$E" 2>/dev/null); ec=$?
check cc4-emdash-newStr 0 $ec '.newStr' 'new, text' "$out"
check cc5-emdash-oldStr-untouched 0 $ec '.oldStr' "old ${EM} text" "$out"
out=$(jq -n --arg c "a${EM}b" '{tool_name:"edit",tool_input:{filePath:"/tmp/t.md",newString:$c}}' | hook_run "$E" 2>/dev/null); ec=$?
check cc6-emdash-newString 0 $ec '.newString' 'a, b' "$out"

printf '%s\n' "$ebroot/inside" >"$ebstate"
out=$(jq -n --arg f "$ebroot/outside.md" '{tool_name:"edit",tool_input:{filePath:$f,oldStr:"a",newStr:"b"}}' \
  | EDIT_BOUNDARY_FILE="$ebstate" hook_run "$EB" 2>/dev/null); ec=$?
check_deny cc7-boundary-camel-path $ec "$out"
rm -f "$ebstate"

bigc="$TMPDIR_T/bigcamel.md"
head -c 20000 /dev/zero | tr '\0' 'b' >"$bigc"
CSID="camel$$"
out=$(jq -n --arg f "$bigc" --arg s "$CSID" '{session_id:$s,tool_name:"read",tool_input:{filePath:$f}}' | hook_run "$RR" 2>/dev/null); ec=$?
check cc8-reread-camel-first 0 $ec '' '' "$out"
out=$(jq -n --arg f "$bigc" --arg s "$CSID" '{session_id:$s,tool_name:"read",tool_input:{filePath:$f}}' | hook_run "$RR" 2>/dev/null); ec=$?
check_deny cc9-reread-camel-blocked $ec "$out"
out=$(jq -n --arg f "$bigc" --arg s "$CSID" '{session_id:$s,tool_name:"view",tool_input:{filePath:$f,viewRange:[1,20]}}' | hook_run "$RR" 2>/dev/null); ec=$?
check cc10-reread-camel-viewRange-bypasses 0 $ec '' '' "$out"
rm -f "${TMPDIR:-/tmp}/copilot-reads-$(id -u)/reads-${CSID}" 2>/dev/null


}

# --- driver: run the whole suite against each available engine --------------
ENGINE=sh
run_all_cases

if [ -x "$PWSH_BIN" ] || command -v "$PWSH_BIN" >/dev/null 2>&1; then
  ENGINE=ps1
  run_all_cases
else
  echo "SKIP ps1 engine: no pwsh at PWSH_BIN=$PWSH_BIN (set PWSH_BIN to test the PowerShell twins)"
  skip=$((skip+1))
fi

rm -rf "$ebroot"
echo "----"
echo "PASS=$pass FAIL=$fail SKIP=$skip"
echo "guard.log lines:"; cat "$GUARD_LOG"
[ "$fail" -eq 0 ]

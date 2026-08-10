#!/usr/bin/env bash
# Smoke tests for the five guard hooks shipped in this repo. Synthetic
# PreToolUse/PostToolUse JSON on stdin; asserts exit codes and, where the hook
# emits one, the updatedInput JSON on stdout.
#
# Run it by path, not as an inline command string: the invocation itself would
# otherwise contain destructive substrings and trip the live guard.
#   bash claude/hooks/tests/test-guards-smoke.sh
#   HOOKS_DIR=~/.claude/hooks bash .../test-guards-smoke.sh   # test an install
#
# The em-dash inputs are built at runtime from bytes, so this file contains no
# literal U+2014 and stays consistent with the rule it helps enforce.
set -u
DIR="${HOOKS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPDIR_T=$(mktemp -d)
export GUARD_LOG="$TMPDIR_T/test-guard.log"
: >"$GUARD_LOG"
EM=$(printf '\xe2\x80\x94')   # U+2014, built at runtime so this file stays clean
pass=0; fail=0; skip=0

check() {  # $1 name, $2 want_exit, $3 got_exit, $4 jq path ('' = stdout must be empty), $5 expected value, $6 stdout
  local name=$1 want=$2 got=$3 path=$4 expect=$5 out=$6
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: exit $got, wanted $want"; fail=$((fail+1)); return
  fi
  if [ -z "$path" ]; then
    if [ -n "$out" ]; then echo "FAIL $name: expected empty stdout, got: $out"; fail=$((fail+1)); return; fi
  else
    local actual
    actual=$(printf '%s' "$out" | jq -r ".hookSpecificOutput.updatedInput${path}" 2>/dev/null)
    if [ "$actual" != "$expect" ]; then
      echo "FAIL $name: updatedInput$path = [$actual], wanted [$expect]"; fail=$((fail+1)); return
    fi
  fi
  pass=$((pass+1))
}

# ---------------------------------------------------------------- destructive
bash_json() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c,description:"t"}}'; }

D="$DIR/block-destructive-bash.sh"
run_d() { out=$(bash_json "$1" | bash "$D" 2>/dev/null); ec=$?; }

run_d 'rm -rf node_modules';                       check d1-allow-nm 0 $ec '' '' "$out"
run_d 'rm -rf .next';                              check d2-allow-next 0 $ec '' '' "$out"
run_d 'rm -rf /opt/proj/node_modules/';            check d3-allow-abs-nm 0 $ec '' '' "$out"
run_d 'rm -rf ~/.claude/worktrees/feature-x';      check d4-allow-worktree 0 $ec '' '' "$out"
run_d "rm -rf $HOME/.Trash/old";                   check d5-allow-trashdir 0 $ec '' '' "$out"
run_d 'rm -rf /private/tmp/claude-501/abc/scratchpad/tmp'; check d6-allow-scratch 0 $ec '' '' "$out"

# The rewrite-to-trash tier needs a trash CLI on PATH. Without one the hook
# blocks instead, which is the documented safe fallback, so assert whichever
# behavior this box can actually produce.
TC="${HARNESS_TRASH_CMD:-}"
if [ -z "$TC" ]; then
  for c in trash trash-put gtrash; do command -v "$c" >/dev/null 2>&1 && { TC="$c"; break; }; done
fi
if [ -n "$TC" ]; then
  run_d 'rm -rf src build';                        check d7-rewrite 0 $ec '.command' "$TC src build" "$out"
  run_d 'rm -rf docs/old-notes';                   check d8-rewrite2 0 $ec '.command' "$TC docs/old-notes" "$out"
  run_d 'rm -rf node_modules src';                 check d16-mixed-targets 0 $ec '.command' "$TC node_modules src" "$out"
else
  echo "SKIP d7/d8/d16: no trash CLI on PATH, hook blocks instead of rewriting"
  skip=$((skip+3))
  run_d 'rm -rf src build';                        check d7-block-no-trash 2 $ec '' '' "$out"
fi

run_d 'cd /tmp && rm -rf stuff';                   check d9-block-compound 2 $ec '' '' "$out"
run_d 'rm -rf "My Dir"';                           check d10-block-quoted 2 $ec '' '' "$out"
run_d 'git reset --hard HEAD~1';                   check d11-block-reset 2 $ec '' '' "$out"
run_d 'psql -c "DROP TABLE users;"';               check d12-block-drop 2 $ec '' '' "$out"
run_d "find . -name '*.tmp' -delete";              check d13-block-find 2 $ec '' '' "$out"
run_d 'git push --force origin main';              check d14-block-push 2 $ec '' '' "$out"
run_d 'echo hello';                                check d15-clean 0 $ec '' '' "$out"
# A quoted rm -rf after a separator is data, not a command.
run_d 'grep -n "em-dash\|rm -rf blocked\|rm -fr blocked" notes.txt'; check d17-quoted-alternation-allowed 0 $ec '' '' "$out"
run_d 'bash -c "cd /tmp && rm -rf x"';             check d18-interpreter-still-blocked 2 $ec '' '' "$out"
# Authoring SQL into a file is not execution; a shell client still blocks.
run_d 'cat > /tmp/041_full.sql << SQLEOF
DROP TABLE users;
SQLEOF';                                           check d19-sql-authoring-allowed 0 $ec '' '' "$out"
run_d 'sqlite3 app.db "DROP TABLE users;"';        check d20-sqlite-drop-blocked 2 $ec '' '' "$out"
# Backslash de-obfuscation: \rm is the plain command.
run_d 'cd /tmp && \rm -rf stuff';                  check d21-deobfuscated-blocked 2 $ec '' '' "$out"

# -------------------------------------------------------------------- em dash
E="$DIR/block-em-dash.sh"
we_json() { jq -n --arg c "$1" '{tool_name:"Write",tool_input:{file_path:"/tmp/t.md",content:$c}}'; }
ed_json() { jq -n --arg o "$1" --arg n "$2" '{tool_name:"Edit",tool_input:{file_path:"/tmp/t.md",old_string:$o,new_string:$n}}'; }

out=$(we_json "a${EM}b" | bash "$E" 2>/dev/null); ec=$?
check e1-tight 0 $ec '.content' 'a, b' "$out"
out=$(we_json "a ${EM} b" | bash "$E" 2>/dev/null); ec=$?
check e2-spaced 0 $ec '.content' 'a - b' "$out"
out=$(we_json "${EM} quote line" | bash "$E" 2>/dev/null); ec=$?
check e3-linestart 0 $ec '.content' '- quote line' "$out"
out=$(we_json 'perfectly clean' | bash "$E" 2>/dev/null); ec=$?
check e4-clean 0 $ec '' '' "$out"
out=$(we_json "end${EM}dash
second line" | bash "$E" 2>/dev/null); ec=$?
check e5-multiline 0 $ec '.content' 'end, dash
second line' "$out"
out=$(ed_json "old ${EM} text" 'clean new' | bash "$E" 2>/dev/null); ec=$?
check e6-oldstring-untouched 0 $ec '' '' "$out"
out=$(ed_json 'clean old' "new${EM}text" | bash "$E" 2>/dev/null); ec=$?
check e7-edit-newstring 0 $ec '.new_string' 'new, text' "$out"
out=$(we_json "one${EM}two
" | bash "$E" 2>/dev/null); ec=$?
check e8-trailing-newline 0 $ec '.content | length' '9' "$out"

# ------------------------------------------------------------- edit boundary
EB="$DIR/guard-edit-boundary.sh"
ebroot=$(mktemp -d); mkdir -p "$ebroot/inside"
ebstate="$TMPDIR_T/edit-boundary"
eb_json() { jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}'; }
eb_run() { out=$(eb_json "$1" | EDIT_BOUNDARY_FILE="$ebstate" bash "$EB" 2>/dev/null); ec=$?; }

eb_run "$ebroot/inside/x.md";                      check eb1-unarmed-allows 0 $ec '' '' "$out"
printf '%s\n' "$ebroot/inside" >"$ebstate"
eb_run "$ebroot/inside/x.md";                      check eb2-inside-allows 0 $ec '' '' "$out"
eb_run "$ebroot/outside.md";                       check eb3-outside-blocks 2 $ec '' '' "$out"
rm -f "$ebstate"
eb_run "$ebroot/outside.md";                       check eb4-disarmed-allows 0 $ec '' '' "$out"

# --------------------------------------------------------------------- reread
RR="$DIR/guard-reread.sh"
big="$TMPDIR_T/big.md"
head -c 20000 /dev/zero | tr '\0' 'a' >"$big"
rr_json() { jq -n --arg f "$1" --arg s "$2" '{session_id:$s,tool_name:"Read",tool_input:{file_path:$f}}'; }
SID="smoke$$"
out=$(rr_json "$big" "$SID" | bash "$RR" 2>/dev/null); ec=$?
check rr1-first-read-allowed 0 $ec '' '' "$out"
out=$(rr_json "$big" "$SID" | bash "$RR" 2>/dev/null); ec=$?
check rr2-second-read-blocked 2 $ec '' '' "$out"
small="$TMPDIR_T/small.md"; printf 'tiny\n' >"$small"
out=$(rr_json "$small" "$SID" | bash "$RR" 2>/dev/null); ec=$?
out=$(rr_json "$small" "$SID" | bash "$RR" 2>/dev/null); ec=$?
check rr3-small-file-never-blocked 0 $ec '' '' "$out"
rm -f "${TMPDIR:-/tmp}/claude-reads-$(id -u)/reads-${SID}" 2>/dev/null

# ------------------------------------------------------------- skill telemetry
LS="$DIR/log-skill-fire.sh"
lscfg="$TMPDIR_T/cfg"
out=$(jq -n '{session_id:"s1",tool_name:"Skill",tool_input:{skill:"spec-diagram"}}' \
  | CLAUDE_CONFIG_DIR="$lscfg" bash "$LS" 2>/dev/null); ec=$?
if [ "$ec" = "0" ] && [ "$(jq -r '.skill' <"$lscfg/telemetry/skill-fires.jsonl" 2>/dev/null)" = "spec-diagram" ]; then
  pass=$((pass+1))
else
  echo "FAIL ls1-telemetry-written: exit $ec, file $lscfg/telemetry/skill-fires.jsonl"; fail=$((fail+1))
fi

rm -rf "$ebroot"
echo "----"
echo "PASS=$pass FAIL=$fail SKIP=$skip"
echo "guard.log lines:"; cat "$GUARD_LOG"
[ "$fail" -eq 0 ]

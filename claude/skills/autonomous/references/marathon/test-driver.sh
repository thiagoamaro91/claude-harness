#!/bin/bash
# test-driver.sh: exercises run.sh with fake claude binaries. No tokens spent.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

mk_state() {
  cat > "$1" <<'EOF'
# Marathon State: test
STATUS: running
GOAL: prove the driver loops
ACCEPTANCE:
- [ ] three ticks recorded
DONE LOG:
NEXT STEP: tick
GOTCHAS:
DECISIONS:
BLOCKERS:
EOF
}

# Fake 1: makes progress each run, flips STATUS to done on the 3rd tick.
cat > "$TMP/fake-progress" <<'EOF'
#!/bin/bash
S="$MARATHON_STATE"
echo "- tick" >> "$S"
if [ "$(grep -c '^- tick' "$S")" -ge 3 ]; then
  sed -i '' 's/^STATUS: running/STATUS: done/' "$S"
fi
EOF

# Fake 2: burns the iteration without touching the state.
cat > "$TMP/fake-stuck" <<'EOF'
#!/bin/bash
exit 0
EOF

# Fake 3: always progresses, never finishes.
cat > "$TMP/fake-endless" <<'EOF'
#!/bin/bash
echo "- tick" >> "$MARATHON_STATE"
EOF
chmod +x "$TMP"/fake-*

check() { # name expected_rc actual_rc extra_ok
  if [ "$2" = "$3" ] && [ "${4:-1}" = "1" ]; then echo "test-driver $1 PASS"; else echo "test-driver $1 FAIL (rc want=$2 got=$3 extra=${4:-1})"; FAIL=1; fi
}

mk_state "$TMP/s1.md"
"$HERE/run.sh" --state "$TMP/s1.md" --claude-bin "$TMP/fake-progress" --max-iter 10 --stall-limit 2 --no-notify >/dev/null 2>&1
rc=$?
ticks_ok=$([ "$(grep -c '^- tick' "$TMP/s1.md")" -eq 3 ] && echo 1 || echo 0)
check "completes-on-done" 0 "$rc" "$ticks_ok"

mk_state "$TMP/s2.md"
"$HERE/run.sh" --state "$TMP/s2.md" --claude-bin "$TMP/fake-stuck" --max-iter 10 --stall-limit 2 --no-notify >/dev/null 2>&1
rc=$?
stall_ok=$(grep -q '^DRIVER: stalled' "$TMP/s2.md" && echo 1 || echo 0)
check "stall-circuit-breaker" 2 "$rc" "$stall_ok"

mk_state "$TMP/s3.md"
"$HERE/run.sh" --state "$TMP/s3.md" --claude-bin "$TMP/fake-endless" --max-iter 3 --stall-limit 2 --no-notify >/dev/null 2>&1
rc=$?
cap_ok=$(grep -q '^DRIVER: max iterations' "$TMP/s3.md" && echo 1 || echo 0)
check "max-iter-cap" 4 "$rc" "$cap_ok"

mk_state "$TMP/s4.md"
sed -i '' 's/^STATUS: running/STATUS: blocked/' "$TMP/s4.md"
"$HERE/run.sh" --state "$TMP/s4.md" --claude-bin "$TMP/fake-progress" --no-notify >/dev/null 2>&1
check "blocked-passthrough" 3 "$?"

"$HERE/run.sh" --state "$TMP/does-not-exist.md" --no-notify >/dev/null 2>&1
check "usage-guard" 64 "$?"

# Space-containing state path (paths may contain spaces): the loop must
# still run, and the generated prompt must carry the path single-quoted.
mkdir -p "$TMP/dir with space"
mk_state "$TMP/dir with space/s5.md"
cat > "$TMP/fake-prompt-check" <<'EOF'
#!/bin/bash
# $1 = -p, $2 = prompt
case "$2" in
  *"--resume-state '$MARATHON_STATE'"*) echo "- tick" >> "$MARATHON_STATE"; sed -i '' 's/^STATUS: running/STATUS: done/' "$MARATHON_STATE" ;;
  *) exit 0 ;; # no progress -> driver stalls -> test fails via rc
esac
EOF
chmod +x "$TMP/fake-prompt-check"
"$HERE/run.sh" --state "$TMP/dir with space/s5.md" --claude-bin "$TMP/fake-prompt-check" --max-iter 3 --stall-limit 1 --no-notify >/dev/null 2>&1
check "spaces-path-and-quoted-prompt" 0 "$?"

mk_state "$TMP/s6.md"
"$HERE/run.sh" --state "$TMP/s6.md" --cwd "$TMP/nope-not-a-dir" --claude-bin "$TMP/fake-progress" --no-notify >/dev/null 2>&1
check "bad-cwd-guard" 64 "$?"

"$HERE/run.sh" --state --no-notify >/dev/null 2>&1
check "missing-value-guard" 64 "$?"

# --claude-args must reach the claude invocation word-split (e.g. --model sonnet),
# so iterations can be pinned to the executor tier instead of the session default.
cat > "$TMP/fake-args" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$MARATHON_ARGS_OUT"
echo "- tick" >> "$MARATHON_STATE"
sed -i '' 's/^STATUS: running/STATUS: done/' "$MARATHON_STATE"
EOF
chmod +x "$TMP/fake-args"
mk_state "$TMP/s7.md"
export MARATHON_ARGS_OUT="$TMP/args-seen.txt"
"$HERE/run.sh" --state "$TMP/s7.md" --claude-bin "$TMP/fake-args" --claude-args "--model sonnet" --max-iter 2 --stall-limit 1 --no-notify >/dev/null 2>&1
rc=$?
args_ok=$(grep -q -- "--model sonnet" "$TMP/args-seen.txt" 2>/dev/null && echo 1 || echo 0)
check "claude-args-passthrough" 0 "$rc" "$args_ok"

exit "$FAIL"

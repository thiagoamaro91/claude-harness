#!/bin/bash
# Marathon driver: fresh-context outer loop for /autonomous --marathon.
# Each iteration is a brand-new headless Claude session; the state file is the
# ONLY carry-over. Quality stays flat because context never degrades, and
# compaction stops being a threat entirely.
#
# Usage:
#   run.sh --state <state.md> [--cwd <dir>] [--max-iter N] [--stall-limit N]
#          [--claude-bin BIN] [--claude-args "--model sonnet ..."]
#          [--extra "text appended to the prompt"]
#          [--iter-timeout SECONDS] [--no-notify]
#
# Exit codes: 0 done | 2 stalled | 3 blocked | 4 max-iterations | 64 usage
# Stall = an iteration that leaves the state file byte-identical. The session
# contract requires updating the state every iteration, so no-change means the
# loop is wedged, not thinking.
set -u

STATE="" CWD="" MAX_ITER=12 STALL_LIMIT=2 CLAUDE_BIN="claude" CLAUDE_ARGS="" EXTRA="" ITER_TIMEOUT="" NOTIFY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --cwd) CWD="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --claude-args) CLAUDE_ARGS="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --max-iter) MAX_ITER="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --stall-limit) STALL_LIMIT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --claude-bin) CLAUDE_BIN="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --extra) EXTRA="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --iter-timeout) ITER_TIMEOUT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --no-notify) NOTIFY=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[ -n "$STATE" ] && [ -f "$STATE" ] || { echo "usage: run.sh --state <existing state.md>" >&2; exit 64; }
case "$MAX_ITER" in ''|*[!0-9]*) echo "--max-iter needs a number" >&2; exit 64 ;; esac
case "$STALL_LIMIT" in ''|*[!0-9]*) echo "--stall-limit needs a number" >&2; exit 64 ;; esac
[ -z "$CWD" ] || [ -d "$CWD" ] || { echo "--cwd does not exist: $CWD" >&2; exit 64; }

STATE_DIR="$(cd "$(dirname "$STATE")" && pwd)"
STATE="$STATE_DIR/$(basename "$STATE")"
LOG="$STATE_DIR/marathon.log"
# CONFIGURE ME: out-of-band notifier. Any command taking --title "<t>" "<body>".
# Unset means in-log only; the loop never fails on a missing notifier.
NOTIFY_CMD="${HARNESS_NOTIFY_CMD:-}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }
notify() { # best-effort: never fail the run
  [ "$NOTIFY" = "1" ] || return 0
  [ -n "$NOTIFY_CMD" ] && $NOTIFY_CMD --title "$1" "$2" >/dev/null 2>&1
  # Second, local channel: a macOS banner so a stopped overnight loop is visible
  # on the machine itself even if the out-of-band channel fails or is unset.
  if command -v osascript >/dev/null 2>&1; then
    local t="${1//\"/\\\"}" m="${2//\"/\\\"}"
    osascript -e "display notification \"$m\" with title \"$t\" sound name \"Glass\"" >/dev/null 2>&1 || true
  fi
}
state_hash() { shasum -a 256 "$STATE" | cut -d' ' -f1; }
# tail -1: the contract says STATUS is edited in place (one line), but if a
# session appends a fresh STATUS line instead, the newest one is the intent.
state_status() { sed -n 's/^STATUS:[[:space:]]*//p' "$STATE" | tail -1; }

# Path is single-quoted inside the prompt (paths may contain spaces) and
# also exported as MARATHON_STATE; the session treats the env var as canonical.
PROMPT_BASE="/autonomous --resume-state '$STATE'
Marathon iteration: read the state file (path above; also in \$MARATHON_STATE), execute exactly ONE increment (NEXT STEP first), update the state file per the marathon contract, then end the session. Do not attempt more than one increment."
[ -n "$EXTRA" ] && PROMPT_BASE="$PROMPT_BASE
$EXTRA"

export MARATHON_STATE="$STATE"
stall=0
log "driver start: max_iter=$MAX_ITER stall_limit=$STALL_LIMIT bin=$CLAUDE_BIN"

for i in $(seq 1 "$MAX_ITER"); do
  case "$(state_status)" in
    done)    log "state=done before iteration $i"; notify "marathon done" "$STATE"; exit 0 ;;
    blocked) log "state=blocked before iteration $i"; notify "marathon BLOCKED" "see BLOCKERS in $STATE"; exit 3 ;;
  esac

  pre="$(state_hash)"
  log "iteration $i start"
  # $CLAUDE_ARGS is deliberately unquoted: it word-splits into extra flags.
  if [ -n "$ITER_TIMEOUT" ] && command -v gtimeout >/dev/null 2>&1; then
    ( if [ -n "$CWD" ]; then cd "$CWD" || exit 97; fi; gtimeout "$ITER_TIMEOUT" "$CLAUDE_BIN" $CLAUDE_ARGS -p "$PROMPT_BASE" ) >> "$LOG" 2>&1
  else
    ( if [ -n "$CWD" ]; then cd "$CWD" || exit 97; fi; "$CLAUDE_BIN" $CLAUDE_ARGS -p "$PROMPT_BASE" ) >> "$LOG" 2>&1
  fi
  rc=$?
  if [ "$rc" -eq 97 ]; then
    log "FATAL: cd to --cwd failed ($CWD); refusing to run in the wrong directory"
    notify "marathon config error" "cd failed: $CWD"
    exit 64
  fi
  log "iteration $i end rc=$rc"

  if [ "$(state_hash)" = "$pre" ]; then
    stall=$((stall + 1))
    log "iteration $i made no state progress (stall $stall/$STALL_LIMIT)"
  else
    stall=0
  fi

  if [ "$stall" -ge "$STALL_LIMIT" ]; then
    printf '\nDRIVER: stalled, %s consecutive iterations left the state unchanged (%s)\n' "$stall" "$(date '+%Y-%m-%d %H:%M')" >> "$STATE"
    log "stalled; stopping"
    notify "marathon STALLED" "$stall no-progress iterations on $STATE"
    exit 2
  fi
done

case "$(state_status)" in
  done)    notify "marathon done" "$STATE"; exit 0 ;;
  blocked) notify "marathon BLOCKED" "see BLOCKERS in $STATE"; exit 3 ;;
esac
printf '\nDRIVER: max iterations (%s) reached without done/blocked (%s)\n' "$MAX_ITER" "$(date '+%Y-%m-%d %H:%M')" >> "$STATE"
log "max iterations reached"
notify "marathon max-iter" "$MAX_ITER iterations spent, not done: $STATE"
exit 4

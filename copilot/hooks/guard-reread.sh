#!/usr/bin/env bash
# guard-reread.sh - preToolUse hook (GitHub Copilot, read tools).
# Token economics: re-reading a >15KB file already read this session is blocked
# unless the file changed (mtime) or the read is targeted (offset/limit/range).
#
# Port of claude/hooks/guard-reread.sh. The mtime/size LOGIC is identical.
#
# --- Copilot contract differences from the Claude original -------------------
#
# SELF-FILTERING. VS Code parses hook matchers but currently IGNORES them, so
# this hook fires on every tool call. Unfiltered it would charge a write or a
# shell call against the read ledger. The tool name is checked first, jq-free,
# and anything outside the read family exits 0 immediately.
#
# DECISION OUTPUT IS DUAL-EMITTED. A block emits the top-level CLI contract
# {"permissionDecision":"deny","permissionDecisionReason":...} AND the VS Code
# form {"hookSpecificOutput":{...}} in Claude Code's shape, then exits 2, so the
# read is refused whichever contract the runtime reads. MED CONFIDENCE that the
# two front ends need different shapes; dual-emitting removes the dependency.
# The reason is the whole point of this guard (it tells the model what to do
# instead), so it goes to stdout and stderr both.
#
# ARGUMENT KEYS AND CASING. The path and the targeted-read arguments are probed
# across the spellings the two harnesses use (file_path / path / file, and
# offset / limit / view_range) AND both casings, because the envelope is
# snake_case while the INNER tool_input properties are camelCase in VS Code
# (tool_input.filePath) and may arrive snake_case from the CLI. Missing the
# targeted-read bypass would be the expensive failure here: it would refuse
# legitimate partial reads of a large file.
#
# Fails OPEN throughout (missing jq, unreadable state dir): this guard saves
# tokens, and no token-economics rule is worth hard-stopping a session over.

INPUT=$(cat)

raw_tool_name() {
  printf '%s' "$INPUT" \
    | sed -n 's/.*"tool_[nN]ame"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}
TOOL_LC=$(raw_tool_name | tr '[:upper:]' '[:lower:]')

# Read-tool family across both harnesses. str_replace_editor is deliberately
# NOT here: it is primarily an edit tool, and charging it against the read
# ledger (or refusing it) would be the wrong failure.
case "$TOOL_LC" in
  ''|read|view|read_file|readfile|cat) ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

# BSD (macOS) and GNU (Linux) stat take different flags; pick once.
if stat -f %z / >/dev/null 2>&1; then
  stat_size()  { stat -f %z "$1" 2>/dev/null || echo 0; }
  stat_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
else
  stat_size()  { stat -c %s "$1" 2>/dev/null || echo 0; }
  stat_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fi

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // .sessionId // empty')
SID="${SID//[^a-zA-Z0-9_-]/}"
[ -z "$SID" ] && exit 0

TI=$(printf '%s' "$INPUT" | jq -c '.tool_input // .toolInput // empty')
[ -n "$TI" ] || exit 0

FP=$(printf '%s' "$TI" | jq -r '.file_path // .filePath // .path // .file // empty')
[ -z "$FP" ] && exit 0
[ -f "$FP" ] || exit 0

# Targeted reads are always fine. view_range is the text-editor-style spelling
# of the same intent and must bypass too, or partial reads get refused.
TARGETED=$(printf '%s' "$TI" | jq -r '
  if (.offset // .limit // .view_range // .viewRange // .range // .start_line // .startLine // .end_line // .endLine) != null
  then "y" else "" end')
[ -n "$TARGETED" ] && exit 0

SIZE=$(stat_size "$FP")
[ "$SIZE" -lt 15360 ] && exit 0

MTIME=$(stat_mtime "$FP")
# Per-user state dir, honoring $TMPDIR, so this never reads or deletes another
# user's files on a shared box. Refuse a symlinked dir (squatting defense).
STATEDIR="${TMPDIR:-/tmp}/copilot-reads-$(id -u)"
[ -L "$STATEDIR" ] && exit 0
mkdir -p "$STATEDIR" 2>/dev/null || exit 0
chmod 700 "$STATEDIR" 2>/dev/null || true
LOG="$STATEDIR/reads-${SID}"
touch "$LOG" 2>/dev/null || exit 0
# Prune only our own stale state files, never a global /tmp pattern.
find "$STATEDIR" -maxdepth 1 -name 'reads-*' -mtime +1 -delete 2>/dev/null

PREV=$(grep -F "${FP}|" "$LOG" 2>/dev/null | tail -1 | awk -F'|' '{print $2}')

if [ -n "$PREV" ] && [ "$PREV" = "$MTIME" ]; then
  msg="BLOCKED by guard-reread (token economics): '$FP' ($(( SIZE / 1024 ))KB) was already fully read this session and has not changed. It is still in your context. Re-reading it re-bills the whole file on every subsequent turn. If you need a specific region, read with an offset/limit or a line range; if you need analysis over it, delegate to a subagent."
  jq -n --arg r "$msg" '{permissionDecision:"deny",permissionDecisionReason:$r,hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  echo "$msg" >&2
  exit 2
fi

# Record / update
grep -vF "${FP}|" "$LOG" > "${LOG}.tmp" 2>/dev/null
echo "${FP}|${MTIME}" >> "${LOG}.tmp"
mv "${LOG}.tmp" "$LOG"
exit 0

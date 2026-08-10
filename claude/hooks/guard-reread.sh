#!/usr/bin/env bash
# guard-reread.sh - PreToolUse hook (matcher: Read).
# Token economics: re-reading a >15KB file already read this session is blocked
# unless the file changed (mtime) or the Read is targeted (offset/limit).
# Blocks with exit 2 so the model sees the reason.

# BSD (macOS) and GNU (Linux) stat take different flags; pick once.
if stat -f %z / >/dev/null 2>&1; then
  stat_size()  { stat -f %z "$1" 2>/dev/null || echo 0; }
  stat_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
else
  stat_size()  { stat -c %s "$1" 2>/dev/null || echo 0; }
  stat_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fi

INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty')
SID="${SID//[^a-zA-Z0-9_-]/}"
[ -z "$SID" ] && exit 0

FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FP" ] && exit 0
[ -f "$FP" ] || exit 0

# Targeted reads are always fine
OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty')
LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty')
if [ -n "$OFFSET" ] || [ -n "$LIMIT" ]; then exit 0; fi

SIZE=$(stat_size "$FP")
[ "$SIZE" -lt 15360 ] && exit 0

MTIME=$(stat_mtime "$FP")
# Per-user state dir, honoring $TMPDIR, so this never reads or deletes another
# user's files on a shared box. Refuse a symlinked dir (squatting defense).
STATEDIR="${TMPDIR:-/tmp}/claude-reads-$(id -u)"
[ -L "$STATEDIR" ] && exit 0
mkdir -p "$STATEDIR" 2>/dev/null || exit 0
chmod 700 "$STATEDIR" 2>/dev/null || true
LOG="$STATEDIR/reads-${SID}"
touch "$LOG" 2>/dev/null || exit 0
# Prune only our own stale state files, never a global /tmp pattern.
find "$STATEDIR" -maxdepth 1 -name 'reads-*' -mtime +1 -delete 2>/dev/null

PREV=$(grep -F "${FP}|" "$LOG" 2>/dev/null | tail -1 | awk -F'|' '{print $2}')

if [ -n "$PREV" ] && [ "$PREV" = "$MTIME" ]; then
  echo "BLOCKED by guard-reread (token economics): '$FP' ($(( SIZE / 1024 ))KB) was already fully read this session and has not changed. It is still in your context. Re-reading it re-bills the whole file on every subsequent turn. If you need a specific region, use Read with offset/limit; if you need analysis over it, delegate to an Explore subagent." >&2
  exit 2
fi

# Record / update
grep -vF "${FP}|" "$LOG" > "${LOG}.tmp" 2>/dev/null
echo "${FP}|${MTIME}" >> "${LOG}.tmp"
mv "${LOG}.tmp" "$LOG"
exit 0

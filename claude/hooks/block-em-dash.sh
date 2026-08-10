#!/usr/bin/env bash
# PreToolUse TRANSFORM: rewrite em-dashes (U+2014) in content about to be
# written, instead of blocking the write and burning a model retry round-trip.
# A deterministic correction belongs in the harness, not in a retry loop.
#
# House rule (CLAUDE.core.md): never write U+2014. Deterministic rewrite rules,
# with EM standing for the U+2014 character (kept out of this file so the
# transform never fires on its own source):
#   line-start "EM text"  -> "- text"   (list/dialogue dash)
#   spaced     "a EM b"   -> "a - b"    (already a separator, keep hyphen form)
#   tight      "aEMb"     -> "a, b"     (clause break, comma reads naturally)
#   leftovers  (mixed)    -> " - "
# Edit's old_string is NEVER touched: it must keep matching the file bytes
# (e.g. when an edit is removing an existing em-dash from a file).
#
# Emits hookSpecificOutput.updatedInput (FULL tool_input replacement per
# code.claude.com/docs/en/hooks.md) with NO permissionDecision, so the normal
# permission flow still governs the write. JSON only honored on exit 0.
# This covers file writes only; nothing here polices the chat reply itself.
#
# Scans/rewrites in UTF-8 mode via `perl -CSD`. Byte-mode tools silently miss
# U+2014, so perl is deliberate here.
# Wired for PreToolUse matcher "Write|Edit|MultiEdit".
#
# Fails OPEN if jq or perl is missing: a missing dependency must not hard-stop
# every write in the session; one em-dash slipping through is recoverable.

LOG="${GUARD_LOG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/guard.log}"
INPUT=$(cat)

command -v jq   >/dev/null 2>&1 || { echo 'em-dash: jq missing, failing open'   >&2; exit 0; }
command -v perl >/dev/null 2>&1 || { echo 'em-dash: perl missing, failing open' >&2; exit 0; }

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

# True (exit 0) when $1 contains at least one U+2014. Uses a flag + END:
# calling `exit` mid-loop would still run END blocks, which can override the
# intended status (a real bug caught in the pre-wiring fixture run).
has_emdash() {
  printf '%s' "$1" | perl -CSD -ne '$f = 1 if /\x{2014}/; END { exit($f ? 0 : 1) }'
}

# Rewrite em-dashes per the rules above. Callers preserve trailing newlines
# via the sentinel trick ($(...) alone would strip them and corrupt content).
de_emdash() {
  printf '%s' "$1" | perl -CSD -pe '
    s/^[ \t]*\x{2014}[ \t]*/- /;
    s/[ \t]+\x{2014}[ \t]+/ - /g;
    s/(?<=\S)\x{2014}(?=\S)/, /g;
    s/\x{2014}/ - /g;
  '
}

NEWTI=""
fpath=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // "?"')

case "$tool" in
  Write)
    # jq -j + sentinel: $(jq -r) strips trailing newlines from the extracted
    # content, which would silently drop a file's final newline on transform
    # (caught in the live-fire test).
    content=$(printf '%s' "$INPUT" | jq -j '.tool_input.content // empty'; printf x); content=${content%x}
    has_emdash "$content" || exit 0
    new=$(de_emdash "$content"; printf x); new=${new%x}
    NEWTI=$(printf '%s' "$INPUT" | jq -c --arg v "$new" '.tool_input | .content = $v')
    ;;
  Edit)
    ns=$(printf '%s' "$INPUT" | jq -j '.tool_input.new_string // empty'; printf x); ns=${ns%x}
    has_emdash "$ns" || exit 0
    new=$(de_emdash "$ns"; printf x); new=${new%x}
    NEWTI=$(printf '%s' "$INPUT" | jq -c --arg v "$new" '.tool_input | .new_string = $v')
    ;;
  MultiEdit)
    n=$(printf '%s' "$INPUT" | jq -r '.tool_input.edits | length' 2>/dev/null) || exit 0
    [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || exit 0
    NEWTI=$(printf '%s' "$INPUT" | jq -c '.tool_input')
    touched=0
    i=0
    while [ "$i" -lt "$n" ]; do
      ns=$(printf '%s' "$NEWTI" | jq -j --argjson i "$i" '.edits[$i].new_string // empty'; printf x); ns=${ns%x}
      if has_emdash "$ns"; then
        new=$(de_emdash "$ns"; printf x); new=${new%x}
        NEWTI=$(printf '%s' "$NEWTI" | jq -c --argjson i "$i" --arg v "$new" '.edits[$i].new_string = $v')
        touched=1
      fi
      i=$((i + 1))
    done
    [ "$touched" -eq 1 ] || exit 0
    ;;
  *)
    exit 0
    ;;
esac

printf '%s TRANSFORMED: em-dash rewrite :: %s (%s)\n' "$(date '+%F %T')" "$fpath" "$tool" >>"$LOG"
jq -n --argjson ti "$NEWTI" '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:$ti}}'
exit 0

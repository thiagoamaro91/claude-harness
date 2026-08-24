#!/usr/bin/env bash
# preToolUse TRANSFORM (GitHub Copilot): rewrite em-dashes (U+2014) in content
# about to be written, instead of blocking the write and burning a model retry
# round-trip. A deterministic correction belongs in the harness, not in a retry
# loop.
#
# Port of claude/hooks/block-em-dash.sh. The rewrite RULES are identical.
#
# House rule (harness-core.instructions.md): never write U+2014. Deterministic
# rewrite rules, with EM standing for the U+2014 character (kept out of this
# file so the transform never fires on its own source):
#   line-start "EM text"  -> "- text"   (list/dialogue dash)
#   spaced     "a EM b"   -> "a - b"    (already a separator, keep hyphen form)
#   tight      "aEMb"     -> "a, b"     (clause break, comma reads naturally)
#   leftovers  (mixed)    -> " - "
# An edit's OLD text is NEVER touched: it must keep matching the file bytes
# (e.g. when an edit is removing an existing em-dash from a file). That is
# structural here, not incidental: only the new-content keys listed in
# CONTENT_KEYS below are ever rewritten, and no old-text key appears in it.
#
# --- Copilot contract differences from the Claude original -------------------
#
# SELF-FILTERING. VS Code parses hook matchers but currently IGNORES them, so
# this hook fires on every tool call. It exits 0 with empty stdout when the
# payload carries no rewritable content key, which covers reads, greps, and
# shell calls at negligible cost.
#
# OUTPUT IS DUAL-EMITTED. The two front ends document different response
# shapes, so the response carries both and each runtime reads the half it
# understands. Unknown fields are ignored, so the duplication is free.
#
#   CLI      top-level {"modifiedArgs": {...}}
#   VS Code  {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#            "updatedInput":{...}}}, Claude Code's shape (VS Code's documented
#            output fields are continue, stopReason, systemMessage and
#            hookSpecificOutput)
#
# MED CONFIDENCE: that top-level modifiedArgs is CLI-only. Dual-emitting means
# the transform does not depend on which way that resolves.
#
# Neither form carries a permissionDecision, so the normal permission flow still
# governs the write. Both REPLACE the whole tool_input, so unchanged fields are
# echoed back. JSON is only honored on exit 0. UNVERIFIED: whether a response
# carrying no permissionDecision is honored at all; if not, the fix is to add
# "permissionDecision":"ask", behavior-preserving relative to the normal flow
# but noisier.
#
# ARGUMENT KEYS AND CASING. The argument holding new content differs per tool,
# per harness, AND per casing: the envelope keys are snake_case but the INNER
# tool_input properties are camelCase in VS Code (tool_input.filePath) and may
# arrive snake_case from the CLI. Every candidate key is probed in both
# spellings and each one present is rewritten in place, so the port depends on
# neither an argument schema nor a casing convention the docs do not publish.
#
# This covers file writes only; nothing here polices the chat reply itself.
#
# Scans/rewrites in UTF-8 mode via `perl -CSD`. Byte-mode tools silently miss
# U+2014, so perl is deliberate here.
#
# Fails OPEN if jq or perl is missing: a missing dependency must not hard-stop
# every write in the session; one em-dash slipping through is recoverable.

LOG="${GUARD_LOG:-${COPILOT_HOME:-$HOME/.copilot}/hooks/guard.log}"
INPUT=$(cat)

command -v jq   >/dev/null 2>&1 || { echo 'em-dash: jq missing, failing open'   >&2; exit 0; }
command -v perl >/dev/null 2>&1 || { echo 'em-dash: perl missing, failing open' >&2; exit 0; }

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // .toolName // empty')

# New-content keys only, in both casings. No old-text key belongs in this list,
# ever: that is what keeps an edit's OLD side matching the file bytes.
# A bare "text" key is deliberately excluded: no write tool in either harness
# uses it as its content key, and it is generic enough to appear on unrelated
# tools, which would draw a rewrite response out of this hook on a tool it has
# no business touching.
CONTENT_KEYS="content file_text fileText new_string newString new_str newStr"

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

NEWARGS=$(printf '%s' "$INPUT" | jq -c '.tool_input // .toolInput // empty')
[ -n "$NEWARGS" ] || exit 0
touched=0

fpath=$(printf '%s' "$NEWARGS" | jq -r '.file_path // .filePath // .path // .file // .notebook_path // .notebookPath // "?"')

# --- batch-edit form: an `edits` array of per-edit objects -------------------
n=$(printf '%s' "$NEWARGS" | jq -r 'if (.edits | type) == "array" then (.edits | length) else 0 end' 2>/dev/null) || n=0
[ -n "$n" ] || n=0
if [ "$n" -gt 0 ] 2>/dev/null; then
  i=0
  while [ "$i" -lt "$n" ]; do
    for k in $CONTENT_KEYS; do
      v=$(printf '%s' "$NEWARGS" | jq -j --argjson i "$i" --arg k "$k" '.edits[$i][$k] // empty'; printf x); v=${v%x}
      [ -n "$v" ] || continue
      if has_emdash "$v"; then
        new=$(de_emdash "$v"; printf x); new=${new%x}
        NEWARGS=$(printf '%s' "$NEWARGS" | jq -c --argjson i "$i" --arg k "$k" --arg v "$new" '.edits[$i][$k] = $v')
        touched=1
      fi
    done
    i=$((i + 1))
  done
fi

# --- single-content form ----------------------------------------------------
for k in $CONTENT_KEYS; do
  v=$(printf '%s' "$NEWARGS" | jq -j --arg k "$k" 'if (.[$k] | type) == "string" then .[$k] else empty end'; printf x); v=${v%x}
  [ -n "$v" ] || continue
  if has_emdash "$v"; then
    new=$(de_emdash "$v"; printf x); new=${new%x}
    NEWARGS=$(printf '%s' "$NEWARGS" | jq -c --arg k "$k" --arg v "$new" '.[$k] = $v')
    touched=1
  fi
done

[ "$touched" -eq 1 ] || exit 0

printf '%s TRANSFORMED: em-dash rewrite :: %s (%s)\n' "$(date '+%F %T')" "$fpath" "${tool:-unknown}" >>"$LOG"
# Dual-emit: modifiedArgs for the CLI, hookSpecificOutput.updatedInput for
# VS Code. Same rewritten arguments in each, no permission decision in either.
jq -n --argjson a "$NEWARGS" '{
  modifiedArgs: $a,
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: $a
  }
}'
exit 0

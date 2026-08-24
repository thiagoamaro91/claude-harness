#!/usr/bin/env bash
# preToolUse guardrail (GitHub Copilot, file-writing tools): opt-in edit
# boundary. While a state file names a boundary directory, edits outside it are
# blocked.
#
# Port of claude/hooks/guard-edit-boundary.sh. The boundary LOGIC (state file,
# canonicalization, trailing-slash prefix match, unresolved-traversal refusal)
# is identical.
#
# While the state file exists, any file edit OUTSIDE the boundary directory it
# names is blocked. No state file = allow everything (opt-in per session).
#   arm:    CFG="${COPILOT_HOME:-$HOME/.copilot}"
#           mkdir -p "$CFG/hooks/state" && printf '%s\n' "/abs/dir" > "$CFG/hooks/state/edit-boundary"
#   disarm: command rm "$CFG/hooks/state/edit-boundary"
# The edit-freeze skill wraps these two commands.
#
# Honest limits: stops the file tools only, NOT the shell tool
# (sed/tee still write); the state file is global, so arm it only while a
# single session is active.
# Boundary paths may contain spaces: the path is read as a raw line, never
# whitespace-stripped.
#
# --- Copilot contract differences from the Claude original -------------------
#
# SELF-FILTERING. VS Code parses hook matchers but currently IGNORES them, so
# this hook fires on every tool call. Unfiltered, an armed boundary would block
# reads and greps outside the directory too, which is not the policy. The tool
# name is therefore checked against the file-writing family before anything
# else. The check uses a jq-free extraction so it can run BEFORE the
# missing-jq fail-closed branch, which otherwise would deny every tool call in
# the session on a jq-less machine rather than only the writes this guard owns.
#
# DECISION OUTPUT. A block emits {"permissionDecision":"deny",
# "permissionDecisionReason":...} on stdout and also exits 2, so the call is
# refused whichever contract the runtime reads, with the reason on stderr.
#
# ARGUMENT KEYS. The file path is probed across the spellings the two harnesses
# use (file_path, path, file, notebook_path) rather than hardcoded, because the
# Copilot docs name the write tools but do not publish their argument schema.

LOG="${GUARD_LOG:-${COPILOT_HOME:-$HOME/.copilot}/hooks/guard.log}"

# State-file resolution, in order: an explicit override, the Copilot path, then
# the Claude path.
#
# The Claude fallback is not tidiness, it is what makes the feature work at all.
# The edit-freeze skill is SHARED verbatim between the two targets (the
# SKILL.md format is identical, so it is installed from claude/skills/ rather
# than duplicated), and its arm/disarm commands name
# "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/state/edit-boundary". Without this
# fallback the skill would arm a file this hook never reads, and the boundary
# would be silently dead on the Copilot target: the worst possible failure for
# a guard, since the user believes edits are frozen and they are not.
#
# Honoring both paths also means one "freeze" intent covers both agents on a
# machine that has both installed, which is the behavior a human asking for a
# freeze actually wants.
STATE="${EDIT_BOUNDARY_FILE:-}"
if [ -z "$STATE" ]; then
  STATE="${COPILOT_HOME:-$HOME/.copilot}/hooks/state/edit-boundary"
  if [ ! -f "$STATE" ]; then
    claude_state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/state/edit-boundary"
    [ -f "$claude_state" ] && STATE="$claude_state"
  fi
fi

# Not armed: allow (the common case; keep it fast). Checked before stdin is
# even read, so an unarmed session pays almost nothing.
[ -f "$STATE" ] || exit 0

INPUT=$(cat)

raw_tool_name() {
  printf '%s' "$INPUT" \
    | sed -n 's/.*"tool_[nN]ame"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}
TOOL_LC=$(raw_tool_name | tr '[:upper:]' '[:lower:]')

# File-writing tool family across both harnesses. An empty tool name is treated
# as in-scope: the payload is malformed, and while a boundary is deliberately
# armed the protective direction is to evaluate the path rather than skip it.
# A payload with no file-path key at all still falls through to allow below.
case "$TOOL_LC" in
  ''|write|edit|multiedit|notebookedit|create|create_file|createfile|str_replace|str_replace_editor|apply_patch|insert_edit_into_file) ;;
  *) exit 0 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "$(date '+%F %T') guard-edit-boundary: jq missing, failing closed" >>"$LOG"
  printf '%s\n' '{"permissionDecision":"deny","permissionDecisionReason":"jq missing, cannot verify edit boundary (failing closed)"}'
  echo 'BLOCKED: jq missing, cannot verify edit boundary (failing closed)' >&2
  exit 2
fi

IFS= read -r BOUNDARY <"$STATE" || BOUNDARY=""
[ -n "$BOUNDARY" ] || exit 0

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.file // .tool_input.notebook_path // empty')
# No file path in the input: not a file edit we can judge; allow.
[ -n "$FILE" ] || exit 0

# Resolve relative paths against the session cwd, then canonicalize the
# directory part so symlinks/.. cannot sidestep the prefix match.
case "$FILE" in
  /*) : ;;
  *) FILE="$PWD/$FILE" ;;
esac
DIR=$(cd "$(dirname "$FILE")" 2>/dev/null && pwd -P) || DIR=$(dirname "$FILE")
FILE="$DIR/$(basename "$FILE")"
# If the directory could not be canonicalized (it does not exist yet), a ".."
# component may survive and defeat the prefix match below. Fail closed rather
# than boundary-check a path we cannot resolve.
case "/$FILE/" in
  */../*)
    printf '%s BLOCKED: edit-boundary unresolved-traversal %s :: %s\n' "$(date '+%F %T')" "$BOUNDARY" "$FILE" >>"$LOG"
    msg="$FILE has an unresolved '..' component and cannot be verified against the edit boundary ($BOUNDARY). Create the parent directory or pass a fully resolved path."
    jq -n --arg r "$msg" '{permissionDecision:"deny",permissionDecisionReason:$r}'
    echo "BLOCKED: $msg" >&2
    exit 2 ;;
esac
# Canonicalize the boundary the same way, or a symlinked prefix (macOS
# /tmp -> /private/tmp) breaks the match between the two sides.
BOUNDARY="${BOUNDARY%/}"
canon=$(cd "$BOUNDARY" 2>/dev/null && pwd -P) && BOUNDARY="$canon"

# Trailing-slash prefix match: /src/ does not match /src-old.
case "$FILE" in
  "$BOUNDARY"/*|"$BOUNDARY") exit 0 ;;
esac

printf '%s BLOCKED: edit-boundary %s :: %s\n' "$(date '+%F %T')" "$BOUNDARY" "$FILE" >>"$LOG"
msg="$FILE is outside the armed edit boundary ($BOUNDARY). If this edit is intentional, disarm first: command rm \"${STATE}\""
jq -n --arg r "$msg" '{permissionDecision:"deny",permissionDecisionReason:$r}'
echo "BLOCKED: $msg" >&2
exit 2

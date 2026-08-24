#!/usr/bin/env bash
# preToolUse guardrail (GitHub Copilot): destructive-command policy.
#
# Port of claude/hooks/block-destructive-bash.sh. The POLICY is identical and
# deliberately unchanged; only the harness contract differs. See the design note
# at docs/copilot-port_design_2026-08-24.md for the full mapping.
#
# The rm -rf class is not block-only: most such commands are legitimate
# ephemeral cleanup, so blocking them all just trains the agent to route around
# the guard. Three-tier handling instead:
#   1. ALLOW untouched  - every rm -rf target matches the ephemeral allowlist
#                         (.next/, node_modules/, worktrees/<name>, agent
#                         scratchpads under /private/tmp, ~/.Trash).
#   2. REWRITE to trash - simple single rm invocation (no separators, quoting,
#                         or substitution): emitted as modifiedArgs JSON with
#                         permissionDecision "allow" (trash is reversible).
#                         Needs a trash CLI on PATH: macOS `trash` (homebrew) or
#                         `trash-put` (trash-cli) on Linux. Set HARNESS_TRASH_CMD
#                         to pick one; with none installed this tier BLOCKS
#                         instead of rewriting, which is the safe direction.
#   3. BLOCK            - compound/quoted rm -rf a token rewrite can't handle
#                         deterministically.
# Hard blocks unchanged for the ambiguous-intent classes: find -delete,
# git clean -f, git push --force, git reset --hard, git checkout/restore ".",
# SQL DROP/TRUNCATE.
#
# --- Copilot contract differences from the Claude original -------------------
#
# SELF-FILTERING. VS Code parses hook matchers but currently IGNORES them, so a
# hook scoped to the shell tool fires on EVERY tool call. This script therefore
# checks tool_name itself and exits 0 fast when the tool is not a shell tool.
# The check runs BEFORE the missing-jq fail-closed branch on purpose: a jq-less
# machine must not have every single tool call in the session denied, only the
# shell calls this guard actually owns.
#
# DECISION OUTPUT IS DUAL-EMITTED. The two front ends document different
# response shapes, so every response carries BOTH and lets each runtime read the
# half it understands. Unknown fields are ignored, so the duplication is free.
#
#   CLI      top-level "permissionDecision" / "permissionDecisionReason", plus
#            top-level "modifiedArgs" for a rewrite.
#   VS Code  "hookSpecificOutput" in Claude Code's shape (VS Code's documented
#            output fields are continue, stopReason, systemMessage and
#            hookSpecificOutput); a rewrite goes in as updatedInput.
#
# MED CONFIDENCE: that top-level modifiedArgs is CLI-only and that VS Code needs
# the hookSpecificOutput form. Dual-emitting means the port does not depend on
# which way that resolves.
#
# A block additionally exits 2. Exit 2 is documented to deny a preToolUse call
# outright, and stdout is documented to be parsed on exit 0, so emitting both
# means the call is refused whichever way the runtime reads the response, with
# the human-readable reason still reaching the log via stderr.
#
# Both rewrite forms REPLACE the whole tool_input, so unchanged fields are
# echoed back.
#
# ARGUMENT KEYS AND CASING. The envelope keys are snake_case, but the INNER
# tool_input properties are camelCase in VS Code (tool_input.filePath) and may
# arrive snake_case from the CLI. Every field is read in both spellings, and the
# command key itself is probed rather than hardcoded, with any rewrite written
# back to whichever key was found. UNVERIFIED: the exact argument key and casing
# of Copilot's shell tool, which is why this is probed rather than assumed.
#
# SPEED. Hook timeouts ALWAYS FAIL OPEN in Copilot, so a slow guard is a silent
# hole. Nothing here does I/O beyond reading stdin and appending one log line.

# GUARD_LOG is env-overridable so the test suite can point fires at a temp log
# instead of polluting the production audit log.
LOG="${GUARD_LOG:-${COPILOT_HOME:-$HOME/.copilot}/hooks/guard.log}"

INPUT=$(cat)

# Raw tool-name extraction that does NOT need jq, so the self-filter can run
# before the fail-closed dependency check. Accepts both the snake_case and the
# camelCase spelling Copilot emits.
raw_tool_name() {
  printf '%s' "$INPUT" \
    | sed -n 's/.*"tool_[nN]ame"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}
TOOL=$(raw_tool_name)
TOOL_LC=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')

# Shell-tool family across both harnesses. Claude Code: Bash. Copilot CLI and
# VS Code: shell / bash / run_command / run_in_terminal / execute_command.
case "$TOOL_LC" in
  ''|bash|shell|run_command|run_in_terminal|execute_command|terminal) ;;
  *) exit 0 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  # No tool name in the payload means relevance could not be established at all.
  # Denying every unidentifiable call would brick the session, so fail open and
  # say so in the log. A NAMED shell call still fails closed, as it must.
  if [ -z "$TOOL_LC" ]; then
    echo "$(date '+%F %T') block-destructive-bash: jq missing and no tool_name, failing open" >>"$LOG"
    exit 0
  fi
  echo "$(date '+%F %T') block-destructive-bash: jq missing, failing closed" >>"$LOG"
  # Hand-written rather than built with jq, for obvious reasons. Dual-emitted
  # like every other decision in this script.
  printf '%s\n' '{"permissionDecision":"deny","permissionDecisionReason":"jq missing, cannot verify command safely (failing closed)","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"jq missing, cannot verify command safely (failing closed)"}}'
  echo 'BLOCKED: jq missing, cannot verify command safely (failing closed)' >&2
  exit 2
fi

# Normalize the envelope once. The envelope key is snake_case in both front
# ends, but read the camelCase spelling too rather than betting on it.
TI=$(printf '%s' "$INPUT" | jq -c '.tool_input // .toolInput // empty')
[ -n "$TI" ] || exit 0

# Probe for the command key rather than hardcoding one, in both casings, and
# remember which key matched so a rewrite is written back to the same place.
CMDKEY=""
for k in command cmd script shellCommand shell_command commandLine command_line; do
  v=$(printf '%s' "$TI" | jq -r --arg k "$k" '.[$k] // empty')
  if [ -n "$v" ]; then CMDKEY="$k"; CMD="$v"; break; fi
done
[ -n "$CMDKEY" ] || exit 0
[ -n "$CMD" ] || exit 0

# Command-name de-obfuscation. A backslash before an ordinary character is a
# shell no-op, so \rm, r\m, \g\it all run the plain command while dodging the
# boundary-anchored matchers below (the class prefix never included backslash).
# Normalize a copy by dropping backslashes that escape an alphanumeric, then run
# ALL detection and the trash-rewrite against it, so evasive forms are handled
# identically to their plain forms. CMD_RAW keeps the original for the audit log.
CMD_RAW="$CMD"
CMD=$(printf '%s' "$CMD" | sed -E 's/\\([[:alnum:]])/\1/g')

logline() {
  # One line per fire: multi-line commands (heredocs) would otherwise spill
  # their whole body into guard.log and break the line-anchored format that
  # log parsers and human audits depend on.
  printf '%s %s: %s :: %s\n' "$(date '+%F %T')" "$1" "$2" \
    "$(printf '%s' "$CMD_RAW" | tr '\n' ' ' | cut -c1-500)" >>"$LOG"
}

block() {
  logline BLOCKED "$1"
  # Dual-emit: top-level for the CLI, hookSpecificOutput for VS Code.
  jq -n --arg r "$1" '{
    permissionDecision: "deny",
    permissionDecisionReason: $r,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  echo "BLOCKED: $1" >&2
  exit 2
}

# Ephemeral-path allowlist: rebuildable or already-disposable
# targets where rm -rf is legitimate cleanup. Matched per target token.
is_ephemeral() {
  # A traversal target is never ephemeral, whatever prefix it wears: reject a
  # ".." path component before the globs below (which cross "/") can match it.
  case "/$1/" in
    */../*) return 1 ;;
  esac
  case "$1" in
    node_modules|node_modules/*|*/node_modules|*/node_modules/*) return 0 ;;
    .next|.next/*|*/.next|*/.next/*) return 0 ;;
    .claude/worktrees/?*|*/.claude/worktrees/?*) return 0 ;;
    .copilot/worktrees/?*|*/.copilot/worktrees/?*) return 0 ;;
    /private/tmp/claude-*scratchpad*|/tmp/claude-*scratchpad*) return 0 ;;
    /private/tmp/copilot-*scratchpad*|/tmp/copilot-*scratchpad*) return 0 ;;
    "$HOME"/.Trash/?*|'~'/.Trash/?*) return 0 ;;
  esac
  return 1
}

# rm with BOTH -r and -f present, evaluated per rm invocation segment.
# Per-segment extraction avoids the flag-bleed and quoted-literal
# false-positive modes that a whole-command match suffers from.
rm_segs=$(echo "$CMD" | grep -oE '(^|[;&|`(]|(sudo|xargs|command|nohup|nice)[[:space:]]+)[[:space:]]*rm[[:space:]]+[^;&|]*' || true)
if [ -n "$rm_segs" ]; then
  saw_rmrf=0
  needs_action=0
  while IFS= read -r seg; do
    if echo "$seg" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[rR]|--recursive' \
       && echo "$seg" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[fF]|--force'; then
      saw_rmrf=1
      # Collect this rm's target tokens (everything after `rm` that is not a flag)
      targets=$(printf '%s\n' "$seg" | awk '{
        started=0
        for (i=1; i<=NF; i++) {
          if (!started) { if ($i ~ /(^|\/)rm$/) started=1; continue }
          if ($i ~ /^-/) continue
          print $i
        }
      }')
      if [ -z "$targets" ]; then
        needs_action=1
        continue
      fi
      all_ok=1
      while IFS= read -r t; do
        # strip one layer of simple quoting before the match
        t=${t%\"}; t=${t#\"}; t=${t%\'}; t=${t#\'}
        is_ephemeral "$t" || all_ok=0
      done <<EOF_T
$targets
EOF_T
      [ "$all_ok" -eq 1 ] || needs_action=1
    fi
  done <<EOF_RM_SEGS
$rm_segs
EOF_RM_SEGS

  if [ "$saw_rmrf" -eq 1 ] && [ "$needs_action" -eq 0 ]; then
    logline ALLOWED 'rm -rf on ephemeral allowlist path(s)'
  elif [ "$needs_action" -eq 1 ]; then
    # Quoted-data check: a real rm command name is never inside quotes unless
    # handed to an interpreter. If stripping quoted spans removes every rm -rf
    # segment, the match was data (a grep/sed pattern, a test fixture).
    quoted_only=0
    case "$CMD" in
      *'bash -c'*|*'sh -c'*|*'zsh -c'*|*'eval '*|*'ssh '*) : ;;  # interpreter present: quoted rm is executable, keep blocking
      *)
        stripped=$(printf '%s' "$CMD" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")
        s_segs=$(echo "$stripped" | grep -oE '(^|[;&|`(]|(sudo|xargs|command|nohup|nice)[[:space:]]+)[[:space:]]*rm[[:space:]]+[^;&|]*' || true)
        quoted_only=1
        if [ -n "$s_segs" ]; then
          while IFS= read -r seg; do
            if echo "$seg" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[rR]|--recursive' \
               && echo "$seg" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[fF]|--force'; then
              quoted_only=0
            fi
          done <<EOF_S
$s_segs
EOF_S
        fi
        ;;
    esac
    if [ "$quoted_only" -eq 1 ]; then
      logline ALLOWED 'rm -rf appears only inside quoted strings (data, not a command)'
    else
      # Rewrite to trash only when the WHOLE command is one simple rm invocation:
      # no separators, substitution, redirection, quoting, or embedded newline.
      # Anything else makes a token-level rewrite non-deterministic -> block.
      simple=1
      case "$CMD" in
        *';'*|*'&'*|*'|'*|*'`'*|*'$'*|*'('*|*')'*|*'{'*|*'}'*|*'<'*|*'>'*|*'"'*|*"'"*) simple=0 ;;
      esac
      case "$CMD" in *$'\n'*) simple=0 ;; esac
      TRASH_CMD="${HARNESS_TRASH_CMD:-}"
      if [ -z "$TRASH_CMD" ]; then
        for c in trash trash-put gtrash; do
          command -v "$c" >/dev/null 2>&1 && { TRASH_CMD="$c"; break; }
        done
      fi
      if [ "$simple" -eq 1 ] && [ -n "$TRASH_CMD" ] \
         && command -v "$TRASH_CMD" >/dev/null 2>&1 \
         && printf '%s' "$CMD" | grep -qE '^[[:space:]]*rm[[:space:]]'; then
        newcmd=$(printf '%s\n' "$CMD" | awk -v tc="$TRASH_CMD" '{
          out=tc
          for (i=2; i<=NF; i++) { if ($i ~ /^-/) continue; out=out " " $i }
          print out
        }')
        if [ "$newcmd" != "$TRASH_CMD" ]; then
          NEWARGS=$(printf '%s' "$TI" | jq -c --arg k "$CMDKEY" --arg cmd "$newcmd" '.[$k] = $cmd')
          logline REWRITTEN "rm -> $newcmd"
          # Dual-emit: modifiedArgs for the CLI, hookSpecificOutput.updatedInput
          # for VS Code. Same rewritten args in each.
          jq -n --argjson a "$NEWARGS" --arg cmd "$newcmd" '{
            permissionDecision: "allow",
            permissionDecisionReason: ("rm -rf rewritten to: " + $cmd),
            modifiedArgs: $a,
            hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "allow",
              permissionDecisionReason: ("rm -rf rewritten to: " + $cmd),
              updatedInput: $a
            }
          }'
          exit 0
        fi
      fi
      block 'Use trash instead of rm -rf (unrewritable compound/quoted command)'
    fi
  fi
fi

# find ... -delete
if echo "$CMD" | grep -qE '(^|[;&|(`][[:space:]]*)find[[:space:]][^;&|]*[[:space:]]-delete([[:space:]]|$)'; then
  block 'Use trash instead of find -delete'
fi

# git clean -f / -fd / -fdx : force-removes untracked files, and can wipe
# untracked work in a worktree. Require both `git clean` and a force flag.
if echo "$CMD" | grep -qE '(^|[;&|(`][[:space:]]*)git[[:space:]]+clean[[:space:]]' \
   && echo "$CMD" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[fF]|--force'; then
  block 'git clean -f removes untracked files; stage or stash instead'
fi

# --- Additional destructive-command patterns, per-segment matching. ---

# git push --force / -f : rewrites remote history. --force-with-lease (and its
# companion --force-if-includes) stays allowed: it refuses to clobber unseen
# work and is the form the agent should reach for when a rewrite is intended.
push_segs=$(echo "$CMD" | grep -oE '(^|[;&|`(]|(sudo|command)[[:space:]]+)[[:space:]]*git[[:space:]]+push[[:space:]]+[^;&|]*' || true)
if [ -n "$push_segs" ]; then
  while IFS= read -r seg; do
    if echo "$seg" | grep -qE '(^|[[:space:]])--force([[:space:]]|$)|(^|[[:space:]])-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)'; then
      block 'git push --force rewrites remote history; use --force-with-lease, or push manually'
    fi
  done <<EOF_PUSH_SEGS
$push_segs
EOF_PUSH_SEGS
fi

# git reset --hard : discards all uncommitted changes irrecoverably.
if echo "$CMD" | grep -qE '(^|[;&|(`][[:space:]]*)git[[:space:]]+reset[[:space:]][^;&|]*--hard'; then
  block 'git reset --hard discards uncommitted work; stash or commit first'
fi

# git checkout . / git checkout -- . : whole-tree discard of uncommitted changes.
if echo "$CMD" | grep -qE '(^|[;&|(`][[:space:]]*)git[[:space:]]+checkout[[:space:]]+(--[[:space:]]+)?\.([[:space:]]|$)'; then
  block 'git checkout . discards uncommitted work; stash first'
fi

# git restore . (worktree discard). git restore --staged . only unstages, allowed.
restore_segs=$(echo "$CMD" | grep -oE '(^|[;&|`(][[:space:]]*)git[[:space:]]+restore[[:space:]]+[^;&|]*' || true)
if [ -n "$restore_segs" ]; then
  while IFS= read -r seg; do
    if ! echo "$seg" | grep -q -- '--staged' \
       && echo "$seg" | grep -qE '(^|[[:space:]])\.([[:space:]]|$)'; then
      block 'git restore . discards uncommitted work; stash first'
    fi
  done <<EOF_RESTORE_SEGS
$restore_segs
EOF_RESTORE_SEGS
fi

# SQL DROP / TRUNCATE reaching a shell client (psql/mysql/sqlite3 paths).
# Honest limit: SQL issued through an MCP server never reaches this shell hook;
# this covers shell-path SQL only.
# Bare TRUNCATE without TABLE is deliberately unmatched: coreutils `truncate -s`
# is a legitimate command and the FP would cry wolf.
# Fire only when a shell SQL client appears in the command (the hook's stated
# scope): authoring DROP statements into a .sql file via cat/heredoc is not
# execution.
sqlclient='(^|[[:space:]/])(psql|mysql|mariadb|sqlite3)([[:space:]]|$)'
if echo "$CMD" | grep -qiE "$sqlclient" \
   && echo "$CMD" | grep -qiE 'drop[[:space:]]+(table|database|schema)[[:space:]]'; then
  block 'SQL DROP detected; run destructive DDL yourself, not through the agent'
fi
if echo "$CMD" | grep -qiE "$sqlclient" \
   && echo "$CMD" | grep -qiE 'truncate[[:space:]]+table[[:space:]]'; then
  block 'SQL TRUNCATE detected; run destructive DDL yourself, not through the agent'
fi

exit 0

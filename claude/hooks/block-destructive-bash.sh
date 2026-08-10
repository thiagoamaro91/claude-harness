#!/usr/bin/env bash
# PreToolUse guardrail (Bash): destructive-command policy.
#
# The rm -rf class is not block-only: most such commands are legitimate
# ephemeral cleanup, so blocking them all just trains the agent to route around
# the guard. Three-tier handling instead:
#   1. ALLOW untouched  - every rm -rf target matches the ephemeral allowlist
#                         (.next/, node_modules/, .claude/worktrees/<name>,
#                         claude scratchpads under /private/tmp, ~/.Trash).
#   2. REWRITE to trash - simple single rm invocation (no separators, quoting,
#                         or substitution): emitted as updatedInput JSON with
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
# JSON contract (code.claude.com/docs/en/hooks.md): updatedInput REPLACES the
# whole tool_input, so unchanged fields are echoed back; JSON is only honored
# on exit 0.
#
# Fails CLOSED if jq is missing: a guard that cannot parse the command must not
# silently allow it (contrast the em-dash transform, which fails open).

# GUARD_LOG is env-overridable so the test suite can point fires at a temp log
# instead of polluting the production audit log.
LOG="${GUARD_LOG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/guard.log}"

if ! command -v jq >/dev/null 2>&1; then
  echo "$(date '+%F %T') block-destructive-bash: jq missing, failing closed" >>"$LOG"
  echo 'BLOCKED: jq missing, cannot verify command safely (failing closed)' >&2
  exit 2
fi

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
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
    /private/tmp/claude-*scratchpad*|/tmp/claude-*scratchpad*) return 0 ;;
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
          NEWTI=$(printf '%s' "$INPUT" | jq -c --arg cmd "$newcmd" '.tool_input | .command = $cmd')
          logline REWRITTEN "rm -> $newcmd"
          jq -n --argjson ti "$NEWTI" \
            '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:("rm -rf rewritten to: "+$ti.command),updatedInput:$ti}}'
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
# Honest limit: SQL issued through an MCP server never reaches this Bash hook;
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

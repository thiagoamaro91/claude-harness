#!/usr/bin/env bash
# PreToolUse guardrail: enforce subagent dispatch discipline on any session
# model (DISPATCH.core.md rules 1-2). Failure modes covered:
#   a) one-line subagent prompts - the agent starts with zero conversation
#      context, so a thin prompt produces thin work -> BLOCK;
#   b) generic dispatches silently inheriting the session model -> INJECT a pin;
#   c) Workflow scripts whose agent() calls inherit the main-loop model, which
#      can silently fan out a whole fleet on a premium tier
#      -> BLOCK unless the script pins models or carries [conductor-ok];
#   d) casual dispatch of a premium / conductor-tier model as a bulk executor.
#      Which models count is set by HARNESS_CONDUCTOR_MODELS (empty by default);
#      a listed model used as an executor is a cost leak -> BLOCK unless the
#      prompt carries [conductor-ok].
#
# A missing model pin on a generic type is a DETERMINISTIC correction, so it is
# INJECTED via hookSpecificOutput.updatedInput instead of blocked. Injection is
# split by role: executor types (general-purpose, claude) get opus; recon types
# (Explore, Plan) get sonnet. Typed specialists are injected too, because
# marketplace plugin agents commonly ship model:"inherit", which resolves to the
# session model; an explicit call-time model always wins.
# The under-briefing check stays a BLOCK: briefing quality is judgment, not
# a deterministic correction. Escape hatch: [brief-ok] in the prompt waives
# the length minimum only, never the model handling.
#
# JSON contract (code.claude.com/docs/en/hooks.md): updatedInput REPLACES the
# whole tool_input (jq edits the original object in place, so all other
# fields are preserved); JSON only honored on exit 0. No permissionDecision
# is set: the normal permission flow governs the dispatch.
#
# Wired for PreToolUse matcher "Task|Agent|Workflow".
#
# Fails OPEN if jq is missing: a broken dependency must not block all
# delegation in the session.

LOG="${GUARD_LOG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/guard.log}"
input=$(cat)

command -v jq >/dev/null 2>&1 || { echo 'guard-agent-briefing: jq missing, failing open' >&2; exit 0; }

# Which models to treat as premium / conductor-tier and therefore refuse as bulk
# executors. Space- or comma-separated, EMPTY by default so the gate is inert
# until a site opts in (the default-executor injection below uses opus, so a
# non-empty default here could block the harness's own default). Example:
# HARNESS_CONDUCTOR_MODELS="premium-model".
CONDUCTOR_MODELS="${HARNESS_CONDUCTOR_MODELS:-}"
is_conductor_model() { # $1 = model name
  [ -n "$CONDUCTOR_MODELS" ] || return 1
  case " $(printf '%s' "$CONDUCTOR_MODELS" | tr ',' ' ') " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')

# --- Workflow guard: agent() calls inherit the main-loop model unless each
# --- one pins its own. A pin-free script on a conductor-tier session is the
# --- single most expensive leak there is. -----------------------------------
if [ "$tool" = "Workflow" ]; then
  script=$(printf '%s' "$input" | jq -r '.tool_input.script // empty')
  spath=$(printf '%s' "$input" | jq -r '.tool_input.scriptPath // empty')
  wname=$(printf '%s' "$input" | jq -r '.tool_input.name // empty')
  if [ -z "$script" ] && [ -n "$spath" ] && [ -f "$spath" ]; then
    script=$(cat "$spath")
  fi
  if [ -z "$script" ]; then
    if [ -n "$wname" ]; then
      cat >&2 <<EOF
BLOCKED: name-resolved workflow "$wname" cannot be pin-verified, and unpinned
agent() calls inherit the session model, which on a premium-tier session fans
a whole fleet out at the higher rate. Invoke a pinned copy of the script via
scriptPath instead, or pass the script inline with a model pin on every
agent() call.
EOF
      exit 2
    fi
    exit 0
  fi
  if printf '%s' "$script" | grep -qF '[conductor-ok]'; then
    exit 0
  fi
  if printf '%s' "$script" | grep -q 'agent(' && \
     ! printf '%s' "$script" | grep -Eq "model[\"']?[[:space:]]*:"; then
    cat >&2 <<EOF
BLOCKED: this Workflow script has agent() calls but no model pins. Unpinned
agent() inherits the main-loop model, so one script can spawn a fleet on a
premium tier. Add model: "opus" | "sonnet" | "haiku" to every agent() call
(agentType-based calls may rely on the agent's frontmatter model), or include
[conductor-ok] in a script comment if premium-tier executors are genuinely
intended.
EOF
    exit 2
  fi
  exit 0
fi

case "$tool" in
  Task|Agent) ;;
  *) exit 0 ;;
esac

prompt=$(printf '%s' "$input" | jq -r '.tool_input.prompt // empty')
stype=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // "general-purpose"')
model=$(printf '%s' "$input" | jq -r '.tool_input.model // empty')

# --- Check 0 (BLOCK): a premium / conductor-tier model as executor needs the
# --- tag. Which models count is set by HARNESS_CONDUCTOR_MODELS. -------------
if [ -n "$model" ] && is_conductor_model "$model" && ! printf '%s' "$prompt" | grep -qF '[conductor-ok]'; then
  cat >&2 <<EOF
BLOCKED: model:"$model" executor dispatch. This model is configured as a
premium / conductor tier (HARNESS_CONDUCTOR_MODELS), not a bulk executor.
Executors run on opus (default), sonnet, or haiku. If this model is genuinely
intended here (rare: an adversarial judge on a high-stakes call), add
[conductor-ok] to the prompt.
EOF
  exit 2
fi

# --- Check 1 (BLOCK): briefing length. -------------------------------------
# Explore/Plan are read-only recon agents; short, precise prompts are more
# often legitimate there. Everything else must carry a real briefing.
# [brief-ok] waives this check only.
if ! printf '%s' "$prompt" | grep -qF '[brief-ok]'; then
  len=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
  case "$stype" in
    Explore|Plan) min=200 ;;
    *)            min=500 ;;
  esac
  if [ "$len" -lt "$min" ]; then
    cat >&2 <<EOF
BLOCKED: under-briefed subagent dispatch ($len chars, minimum $min for subagent_type=$stype).
The subagent starts with ZERO conversation context: it has not seen the user's
request, prior tool results, or decisions made this session. Re-issue the
dispatch as a self-contained briefing (DISPATCH.core.md rule 1):
  1. OBJECTIVE - one verifiable goal.
  2. CONTEXT  - why the task exists, decisions already made, exact file paths,
                and PASTED snippets/data. Never "as discussed" or "the file above".
  3. SCOPE    - what NOT to touch (write boundaries, adjacent workstreams).
  4. OUTPUT   - exact shape of the final message; it is the ONLY thing returned.
  5. DONE     - how the agent verifies its own work before returning.
If a tiny prompt is genuinely right here, add [brief-ok] to the prompt.
EOF
    exit 2
  fi
fi

# --- Check 2 (TRANSFORM): model pin. ---------------------------------------
# ANY unpinned dispatch -> inject the default for its role: recon (Explore,
# Plan) gets sonnet, everything else opus. Typed specialists are injected too:
# marketplace plugin agents commonly ship model:"inherit", which resolves to
# the session model, and local agent frontmatter is opus anyway, so blanket
# opus injection is behavior-preserving where it matters. An explicit
# call-time model always wins (fork ignores the field, harmless).
if [ -z "$model" ]; then
  case "$stype" in
    Explore|Plan) inject="sonnet" ;;
    *)            inject="opus" ;;
  esac
  if [ -n "$inject" ]; then
    NEWTI=$(printf '%s' "$input" | jq -c --arg m "$inject" '.tool_input | .model = $m')
    printf '%s INJECTED: model=%s (%s) :: %s\n' "$(date '+%F %T')" "$inject" "$stype" \
      "$(printf '%s' "$prompt" | tr '\n' ' ' | cut -c1-120)" >>"$LOG"
    jq -n --argjson ti "$NEWTI" '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:$ti}}'
    exit 0
  fi
fi

exit 0

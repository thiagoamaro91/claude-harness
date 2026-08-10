#!/usr/bin/env bash
# PostToolUse(Skill) telemetry: append {ts, skill, session} JSONL per skill
# fire. Ground truth for skill-usage counts; a transcript grep under-counts
# because it cannot see subagent invocations.
# Fail-open and silent: telemetry must never block or slow a skill call.
command -v jq >/dev/null 2>&1 || exit 0
TELEMETRY_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/telemetry"
mkdir -p "$TELEMETRY_DIR" 2>/dev/null || exit 0
jq -c --arg ts "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
  '{ts: $ts, skill: (.tool_input.skill // "?"), session: (.session_id // "?")}' \
  >> "$TELEMETRY_DIR/skill-fires.jsonl" 2>/dev/null || true
exit 0

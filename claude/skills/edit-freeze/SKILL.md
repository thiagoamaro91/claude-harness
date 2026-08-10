---
name: edit-freeze
description: Arm or disarm the session edit boundary (directory freeze). Use when the user says "freeze edits to X", "lock edits to this folder", "only touch files under X", "edit boundary on/off", "unfreeze", or wants edits mechanically confined to one directory during debugging or a risky cross-workstream session. Also use to check whether a boundary is currently armed.
---

# Edit Freeze

Arms `guard-edit-boundary.sh` (PreToolUse on Edit/Write/MultiEdit/NotebookEdit): while armed, file edits outside the boundary directory are hook-blocked. Mechanical enforcement of a write boundary for one session.

The state file lives under the Claude config dir, so the snippets below use `$CFG`:

```bash
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
```

## Arm

1. Resolve the user's directory to an ABSOLUTE path (no `~`, no relative). If ambiguous, confirm with the user before arming.
2. Run:
   ```bash
   mkdir -p "$CFG/hooks/state" && printf '%s\n' "/absolute/path/to/dir" > "$CFG/hooks/state/edit-boundary"
   ```
3. Confirm to the user: the exact boundary path, and the two honest limits:
   - blocks the file tools only, NOT Bash (`sed`/`tee` still write)
   - the boundary is global across concurrent Claude sessions; arm only while this is the single active session

## Disarm

```bash
command rm "$CFG/hooks/state/edit-boundary"
```

Confirm it is gone. (`command rm` bypasses any `rm` alias; the file is state, not user data.)

## Status

```bash
cat "$CFG/hooks/state/edit-boundary" 2>/dev/null || echo "not armed"
```

## Rules

- Never arm a boundary the user did not ask for.
- At the end of a session, if a boundary is still armed, disarm it and mention that you did.
- If a blocked edit was actually legitimate (scope grew), ask the user whether to move the boundary up a level or disarm; do not silently disarm to push an edit through.

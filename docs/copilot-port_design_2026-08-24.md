# Copilot port: design note

**Date:** 2026-08-24
**Status:** implemented on branch `copilot-port`
**Why now:** the work machine has a GitHub Copilot license and no Claude Code
license. The harness is worth more than the tool it was written for, so it grows
a second target rather than being rewritten.

## The shape of the port

The repository now has two targets and one body of content.

```
claude/       the Claude Code target      -> bin/install.sh          -> ~/.claude
copilot/      the GitHub Copilot target   -> bin/install-copilot.sh  -> ~/.copilot
claude/skills/  shared by BOTH targets, installed from one place
```

The single most important decision: **skills are not duplicated.** The
`SKILL.md` format is the same in both harnesses, frontmatter included, so
`manifest.copilot.txt` points the Copilot installer straight at the
`claude/skills/**` rows. Duplicating them would have created seven pairs of
files that drift apart silently.

`claude/` is otherwise untouched by this port. Nothing in it changed.

## Three-way surface mapping

| Harness surface | Claude Code | Copilot CLI | Copilot in VS Code |
|---|---|---|---|
| Core rules | `CLAUDE.md`, `DISPATCH.core.md` | `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md`, `.github/copilot-instructions.md`, `.github/instructions/**/*.instructions.md`, `~/.copilot/instructions/**` | all of the CLI set, plus `.claude/rules/` and `~/.claude/rules/`; gated by `chat.useAgentsMdFile`, `chat.useClaudeMdFile`, `chat.instructionsFilesLocations` |
| Rule scoping | whole file applies | `applyTo:` glob in `*.instructions.md` frontmatter | same |
| Skills | `~/.claude/skills` | `.github/skills`, `.claude/skills`, `.agents/skills` (project); `~/.copilot/skills`, `~/.agents/skills` (user). **`~/.claude/skills` is NOT read** | all of the above **plus** `~/.claude/skills` |
| Skill frontmatter | name, description, allowed-tools | name, description, license, allowed-tools | plus argument-hint, user-invocable, disable-model-invocation, context: fork |
| Slash commands | skill invocation, `.claude/commands/` | skills with `user-invocable: true`; `.claude/commands/` also read | same |
| Subagents | `agents/*.md`, Agent tool | `.github/agents/*.agent.md` (project), `~/.copilot/agents/*.agent.md` (user, **home wins on collision**); `/agent`, `/fleet`, `/delegate`, `--agent NAME` | additionally reads `.claude/agents/`; frontmatter also takes model, handoffs, agents, user-invocable |
| Hook config | `settings.json` `hooks` key | `.github/hooks/*.json`, `~/.copilot/hooks/*.json`, `hooks` key in `~/.copilot/settings.json` | also reads `.claude/settings.json` and `~/.claude/settings.json` in Claude format |
| Hook events | PreToolUse, PostToolUse, ... | sessionStart, sessionEnd, userPromptSubmitted, preToolUse, postToolUse, postToolUseFailure, preCompact, agentStop, subagentStart, subagentStop, permissionRequest (CLI only), notification (CLI only), errorOccurred | 8 events, including PreToolUse, PostToolUse, SessionStart, Stop |
| Payload shape | snake_case on stdin | **both** camelCase and snake_case | same |
| Allow/deny output | `hookSpecificOutput.permissionDecision` | top-level `permissionDecision` + `permissionDecisionReason` | same |
| Argument rewrite | `hookSpecificOutput.updatedInput` | top-level `modifiedArgs` | same |
| Matcher honored | yes | yes | **parsed but IGNORED** |
| Permissions | `permissions.deny` in settings.json | `--allow-tool` / `--deny-tool` flags; `~/.copilot/settings.json` | `chat.tools.terminal.autoApprove`, `chat.tools.edits.autoApprove` |
| MCP config | `.mcp.json` | `~/.copilot/mcp-config.json`, `.mcp.json`, `.github/mcp.json`; key `mcpServers` | `.vscode/mcp.json`; key **`servers`**, incompatible |
| Shell tool name | `Bash` | `shell` | terminal tool |
| Edit tool names | `Write`, `Edit`, `MultiEdit` | `write`, `edit`, `str_replace_editor`, `create` | same family |

Because the payload arrives in snake_case as well as camelCase, and snake_case
is exactly Claude Code's shape, the ported scripts keep reading `.tool_input`
and `.session_id` unchanged. That is the one place the port was free.

## What each guard hook needed

The policy logic of all four hooks is byte-for-byte the same decision tree as
the Claude originals: the three-tier destructive-command policy with its
ephemeral allowlist and trash rewrite, the four em-dash rewrite rules, the
edit-boundary state file with its canonicalization and traversal refusal, and
the reread mtime ledger. Five things changed, and only these five.

### 1. Every hook self-filters on tool name

VS Code parses hook matchers and then ignores them, so a hook scoped to the
shell tool fires on reads, greps, and web fetches too. Unfiltered, the
consequences were concrete rather than theoretical:

- the edit boundary, once armed, would have refused *reads* outside the
  directory, which was never the policy;
- the reread ledger would have charged writes and shell calls against the read
  budget.

Each script now checks `tool_name` itself against both naming families,
case-insensitively, and exits 0 with empty stdout on a tool it does not own.
The matchers stay in the config file anyway, because the CLI does honor them
and the double filter costs nothing.

### 2. The self-filter runs before the fail-closed dependency check

This is the trap worth writing down. `block-destructive-bash.sh` fails closed
when `jq` is missing, which is correct: a guard that cannot parse the command
must not allow it. Under Claude Code that blast radius is bounded by the `Bash`
matcher. Under Copilot in VS Code, with matchers ignored, the natural port
(self-filter after the jq check, since you need jq to read the tool name) would
deny **every tool call in the session** on a machine without jq.

The fix is a jq-free tool-name extraction with `sed`, run first. A named shell
call still fails closed. A payload with no tool name at all fails open and says
so in the log, because denying every unidentifiable call is worse than the risk
it removes. `guard-edit-boundary.sh` uses the same ordering.

### 3. Output contracts

- **Block:** emit `{"permissionDecision":"deny","permissionDecisionReason":...}`
  on stdout **and** exit 2. Exit 2 denies a `preToolUse` call outright; stdout
  is documented to be parsed on exit 0. Emitting both means the call is refused
  whichever way the runtime reads the response, and the reason still reaches the
  log via stderr, exactly as the Claude originals did.
- **Rewrite:** `{"permissionDecision":"allow","permissionDecisionReason":...,
  "modifiedArgs":{...}}`. `modifiedArgs` replaces the whole `tool_input`, so
  unchanged fields are echoed back. This is Copilot's spelling of
  `hookSpecificOutput.updatedInput`.
- **Transform without a decision:** the em-dash hook emits `modifiedArgs` alone,
  with no `permissionDecision`, so the normal permission flow still governs the
  write. This preserves the Claude behavior exactly and is the one contract
  detail marked UNVERIFIED below.

### 4. Argument keys are probed, not hardcoded

The Copilot docs name the tools but do not publish their argument schemas.
`str_replace_editor` follows the text-editor convention, which uses `old_str`,
`new_str`, and `path`, not Claude's `old_string`, `new_string`, and
`file_path`. Hardcoding one spelling would have produced a hook that looks like
it works and silently no-ops, or worse, writes a `modifiedArgs` object the tool
cannot read.

Every script therefore probes a candidate list and writes back to whichever key
it found:

| What | Keys probed |
|---|---|
| shell command | `command`, `cmd`, `script`, `shellCommand` |
| new content | `content`, `file_text`, `new_string`, `new_str`, `text` |
| file path | `file_path`, `path`, `file`, `notebook_path` |
| targeted read | `offset`, `limit`, `view_range`, `range`, `start_line`, `end_line` |

The old-text keys (`old_string`, `old_str`) are deliberately absent from the
content list. That is what keeps the em-dash transform from corrupting an edit
whose whole purpose is to remove an existing em-dash from a file, and it is now
structural rather than a special case in the code.

Missing the targeted-read bypass would have been the expensive failure: every
legitimate partial read of a large file would have been refused.

### 5. Log and state roots move

`GUARD_LOG` now defaults to `${COPILOT_HOME:-$HOME/.copilot}/hooks/guard.log`,
the edit-boundary state file to `${COPILOT_HOME:-$HOME/.copilot}/hooks/state/`,
and the reread ledger to `$TMPDIR/copilot-reads-$(id -u)/`. Both targets can be
installed on one machine without sharing state.

## The cost of sharing skills verbatim

Not duplicating the skills is the right call, and it has one consequence worth
naming: a shared skill that references the *Claude* config directory in prose
or in a shell snippet is installed unchanged onto the Copilot target, and the
installer's placeholder substitution does not rewrite it, because it is a
literal path rather than a `__CLAUDE_HOME__` placeholder.

One case actually breaks something. `edit-freeze/SKILL.md` arms the boundary
with `CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`, so on the Copilot target it
would write a state file that the ported hook never reads. The boundary would
appear armed and freeze nothing, which is the worst failure mode a guard has:
the user believes edits are confined and they are not.

Fixed inside `copilot/`, not by touching the shared skill:
`copilot/hooks/guard-edit-boundary.sh` resolves its state file in the order
override, Copilot path, Claude path. The skill keeps working, one freeze intent
covers both agents on a machine that has both, and `claude/` stays untouched.
The smoke test now exercises the default resolution path explicitly, which the
original suite never did because every boundary case passed
`EDIT_BOUNDARY_FILE`.

The remaining cases are cosmetic or benign and are deliberately left alone:

| File | Reference | Effect on the Copilot target |
|---|---|---|
| `edit-freeze/SKILL.md` | arms `$CLAUDE_CONFIG_DIR/hooks/state/` | **fixed** by the fallback above |
| `autonomous/references/ledger/append.py` | writes its ledger under `$CLAUDE_CONFIG_DIR` or `~/.claude` | ledger lands in the Claude directory instead of the Copilot one. It still works; the file is just in the neighboring folder. |
| `autonomous/references/marathon.md`, `workflows/README.md` | quote `~/.claude/skills/...` invocation paths in prose | a human following the instruction literally uses the wrong path. Documentation, not behavior. |
| `expert-panel/SKILL.md` | reads a project manifest at `.claude/expert-panel.md` | unaffected: that is a per-project path, not a config-directory path, and Copilot reads `.claude/` project files anyway. |

Fixing the middle two properly means parameterizing the shared skills, which
touches `claude/` and changes the Claude target's behavior. That is a separate
change with its own testing, not something to smuggle into a port.

## Timeouts fail open, so a short timeout is less safe, not more

Copilot hook timeouts **always fail open**: the tool call proceeds. The default
is 30 seconds and the shipped config sets 10. Nobody should later "harden" that
to 2 seconds. A shorter timeout does not make a guard stricter, it makes it more
likely to be skipped entirely, and a skipped `block-destructive-bash.sh` is a
destructive command that runs.

The scripts are written to stay far below any plausible timeout: no network, no
recursive filesystem walks, one appended log line. The 10 second value is
headroom against a loaded machine, not a target.

The honest consequence: the hooks are a safety net, not a wall. The VS Code deny
lists in `copilot/vscode-settings.snippet.jsonc` are the second line, and they
do not time out.

## Deliberate non-goals in v1

**No plugin packaging.** Agent Plugins 1.0 went GA on 2026-08-12 and can bundle
agents, skills, hooks, and MCP config into one installable unit, which is
obviously where this should end up. It is not where it ends up today, because
plugin-shipped hooks are broken: `github/copilot-cli` issue #2540 tracks a
regression introduced between 1.0.59 and 1.0.60, and #3659 has plugin hook
commands resolved against the current working directory instead of the plugin
root. A plugin whose hooks do not fire is worse than an installer, because it
looks installed. Revisit when both issues close.

**No PowerShell hook twins.** Copilot hook objects accept `bash` and
`powershell` keys side by side, so a Windows port is a matter of writing the
second half of each hook object rather than changing any architecture. v1 ships
bash only. On Windows the guards simply do not fire, which is a real gap and is
stated as one in the README rather than papered over.

**`log-skill-fire.sh` is not ported.** It hooks `PostToolUse` on the `Skill`
tool. Copilot has no Skill tool: skills trigger from their description or from a
slash command, and neither surfaces as a tool call to hook. The telemetry it
produced has no equivalent here, so the file stays Claude-only rather than being
ported into something that never fires.

**MCP ships as examples only.** MCP is disabled by default in GitHub
organizations and an administrator has to allowlist each server. Tier 3 stays
what it always was: a reading list.

## UNVERIFIED

Everything below is prose-documented, inferred, or environment-specific. None of
it is load-bearing for tiers 0 through 2, and each item names how to settle it.

1. **Exact argument schemas of the Copilot tools.** Mitigated by key probing
   rather than resolved. Settle it by running one call of each tool with a
   logging `postToolUse` hook and reading the payload.
2. **Whether `modifiedArgs` is honored without an accompanying
   `permissionDecision`.** The em-dash transform depends on it. If it turns out
   not to be, the fix is to add `"permissionDecision":"ask"`, which is
   behavior-preserving relative to the normal flow but noisier.
3. **The exact permissions schema inside `~/.copilot/settings.json`.** Prose
   documentation only, which is why the shipped template sets nothing active and
   puts every candidate key in a comment marked UNVERIFIED.
4. **Whether the CLI reads `.claude/settings.json`.** High confidence for VS
   Code, unverified for the CLI. The port does not rely on it either way: the
   Copilot hooks are wired in their own file.
5. **Exit codes of `copilot -p`.** Matters only if this gets wrapped in a
   script; nothing here does.
6. **Which models and features the organization enables.** Unknowable from
   outside. `managed-settings.json` can pin models, disable bypass modes, deny
   MCP, and force policy hooks, and its precedence (MDM, then server-managed,
   then file, then user) beats everything installed here. Run `/env` and
   `copilot plugins list --json` on the work box before assuming any capability
   exists.

## Sources

All facts above come from a research pass on 2026-08-24 against official
documentation, principally:

- `docs.github.com/en/copilot/reference/hooks-reference` (hook events, config
  locations, payload shape, decision contract, exit codes, timeout behavior)
- `docs.github.com/en/copilot` reference pages for skills, custom agents,
  instruction files, MCP configuration, and CLI permission flags
- `github.com/github/copilot-cli` issues #2540 and #3659 (plugin hook
  regression, plugin command path resolution)
- VS Code documentation for `chat.useAgentsMdFile`, `chat.useClaudeMdFile`,
  `chat.instructionsFilesLocations`, `chat.tools.terminal.autoApprove`, and
  `chat.tools.edits.autoApprove`

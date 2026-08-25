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
| Hook events | PreToolUse, PostToolUse, ... | 13 events per the hooks reference: sessionStart, sessionEnd, userPromptSubmitted, preToolUse, postToolUse, postToolUseFailure, preCompact, agentStop, subagentStart, subagentStop, notification, errorOccurred and one further event. `permissionRequest` is **not** among them | 8 events, including PreToolUse, PostToolUse, SessionStart, Stop |
| Payload envelope | snake_case on stdin | snake_case (`tool_name`, `tool_input`, `session_id`) | same |
| Payload INNER keys | snake_case (`file_path`) | may be snake_case | **camelCase** (`tool_input.filePath`) |
| Allow/deny output | `hookSpecificOutput.permissionDecision` | top-level `permissionDecision` + `permissionDecisionReason` | documented output fields are continue, stopReason, systemMessage, `hookSpecificOutput` (Claude-style) |
| Argument rewrite | `hookSpecificOutput.updatedInput` | top-level `modifiedArgs` | `hookSpecificOutput.updatedInput` |
| Matcher honored | yes | yes | **parsed but IGNORED** |
| Permissions | `permissions.deny` in settings.json | `--allow-tool` / `--deny-tool` flags; `~/.copilot/settings.json` | `chat.permissions.default`, `chat.tools.eligibleForAutoApproval`, `chat.tools.global.autoApprove`, `chat.tools.urls.autoApprove`, `chat.tools.terminal.autoApprove` |
| MCP config | `.mcp.json` | `~/.copilot/mcp-config.json`, `.mcp.json`, `.github/mcp.json`; key `mcpServers` | `.vscode/mcp.json`; key **`servers`**, incompatible |
| Shell tool name | `Bash` | `shell` | terminal tool |
| Edit tool names | `Write`, `Edit`, `MultiEdit` | `write`, `edit`, `str_replace_editor`, `create` | same family |

The casing split is the trap in that table. The ENVELOPE keys are snake_case in
both front ends, so the scripts keep reading `.tool_input` and `.session_id`
unchanged and that much of the port was free. The INNER `tool_input` properties
are not: VS Code sends `tool_input.filePath` where Claude Code sends
`tool_input.file_path`, and the CLI may send either. Every field the scripts
touch is therefore read in both spellings. A guard that reads only one casing is
a guard that silently never fires on one of the two front ends, which is
indistinguishable from a guard that is working until the day it matters.

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

### 3. Output contracts are dual-emitted

The two front ends document different response shapes. The CLI reference
describes top-level `permissionDecision` / `permissionDecisionReason` and
top-level `modifiedArgs`. The VS Code hooks documentation lists its output
fields as `continue`, `stopReason`, `systemMessage` and `hookSpecificOutput`,
which is Claude Code's shape, with a rewrite carried as `updatedInput`.

**Confidence that `modifiedArgs` is CLI-only is medium**, not high. Rather than
bet the guard layer on which way that resolves, every response carries both
halves. Unknown fields are ignored by both parsers, so the duplication costs
nothing and removes the dependency entirely.

- **Block:** top-level `permissionDecision: "deny"` plus
  `permissionDecisionReason`, AND a `hookSpecificOutput` mirror carrying the
  same decision and reason, AND exit 2. Exit 2 denies a `preToolUse` call
  outright; stdout is documented to be parsed on exit 0. Three paths all deny,
  so the call is refused whichever way the runtime reads the response, and the
  reason still reaches the log via stderr exactly as the Claude originals did.
- **Rewrite:** `permissionDecision: "allow"` plus `modifiedArgs`, AND
  `hookSpecificOutput.updatedInput` carrying the same rewritten arguments. Both
  forms replace the whole `tool_input`, so unchanged fields are echoed back.
- **Transform without a decision:** the em-dash hook emits `modifiedArgs` and
  `hookSpecificOutput.updatedInput` with no `permissionDecision` in either, so
  the normal permission flow still governs the write. This preserves the Claude
  behavior exactly and is the one contract detail still marked UNVERIFIED below.

The smoke test asserts both halves of every rewrite and both halves of every
deny. A response that reaches only one front end counts as a failure, not a
partial pass: a guard that works in the CLI and not in the editor is exactly the
kind of half-installed protection this repo exists to avoid.

### 4. Argument keys are probed, in both casings

The Copilot docs name the tools but do not publish their argument schemas.
`str_replace_editor` follows the text-editor convention, which uses `old_str`,
`new_str`, and `path`, not Claude's `old_string`, `new_string`, and
`file_path`. Hardcoding one spelling would have produced a hook that looks like
it works and silently no-ops, or worse, writes a `modifiedArgs` object the tool
cannot read.

The casing makes it worse. The envelope is snake_case, but the inner
`tool_input` properties are camelCase in VS Code and may be snake_case from the
CLI, so each candidate key has two spellings.

Every script therefore probes a candidate list in both casings and writes back
to whichever key it found:

| What | Keys probed |
|---|---|
| shell command | `command`, `cmd`, `script`, `shellCommand`, `shell_command`, `commandLine`, `command_line` |
| new content | `content`, `file_text`, `fileText`, `new_string`, `newString`, `new_str`, `newStr` |
| file path | `file_path`, `filePath`, `path`, `file`, `notebook_path`, `notebookPath` |
| targeted read | `offset`, `limit`, `view_range`, `viewRange`, `range`, `start_line`, `startLine`, `end_line`, `endLine` |
| envelope | `tool_input`, `toolInput` |

The old-text keys (`old_string`, `oldString`, `old_str`, `oldStr`) are
deliberately absent from the content list, in every casing. That is what keeps the em-dash transform from corrupting an edit
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

**PowerShell twins: shipped.** This was listed as a v1 non-goal and is now
done, because the work machine turned out to be Windows. See the section below.

**`log-skill-fire.sh` is not ported.** It hooks `PostToolUse` on the `Skill`
tool. Copilot has no Skill tool: skills trigger from their description or from a
slash command, and neither surfaces as a tool call to hook. The telemetry it
produced has no equivalent here, so the file stays Claude-only rather than being
ported into something that never fires.

**MCP ships as examples only.** MCP is disabled by default in GitHub
organizations and an administrator has to allowlist each server. Tier 3 stays
what it always was: a reading list.

## Platform deltas worth knowing before you touch this again

Facts from a second research pass that do not change the port but change what a
future reader should assume.

**Both harnesses can run inside VS Code.** The Session Target dropdown selects
between Local, Copilot, Claude, Codex and Cloud, and the Claude side is gated by
`github.copilot.chat.claudeAgent.enabled`. Separately, the organization's
"Third-party coding agents" policy toggles Anthropic Claude on its own. So
"Copilot is the only license" and "Claude Code cannot run here" are different
statements, and the second needs checking rather than assuming.

**Enterprise settings can kill the plugin path outright.** Managed settings
carry `enabledPlugins` and `strictKnownMarketplaces`, which an administrator can
use to restrict plugins to an approved marketplace list or disable them. That is
independent support for the no-plugin-in-v1 decision: even once
`github/copilot-cli` #2540 and #3659 close, the plugin route may simply not be
open on this machine, whereas an installer copying files into a home directory
is not policy-gated in the same way.

**Instruction and skill portability is narrower than it looks.**

- The portable `SKILL.md` frontmatter subset is just `name` and `description`.
  `name` must be lowercase letters, digits and hyphens, at most 64 characters;
  `description` at most 1024 characters. `allowed-tools` is CLI-only.
  `user-invocable` and `context` are VS Code-only. All seven shared skills were
  checked against these limits and all seven pass unchanged, the longest
  description being 958 characters.
- `~/.claude/rules/` scopes with a `paths:` key, not the `applyTo:` key that
  `*.instructions.md` uses. Do not copy frontmatter between the two formats.
- `*.chatmode.md` is deprecated. Nothing here uses it; noted so nobody
  reintroduces it.
- The Agent Host does not read VS Code profile user-data customizations, which
  is a legacy location. Anything that must reach the Agent Host goes in the
  documented file locations, which is what the installer targets.

**MCP:** `.vscode/mcp.json` additionally supports a top-level `sandbox` key,
which has no counterpart in the `mcpServers` shape. One more reason the two
example files in `copilot/mcp/` are not interchangeable.

## PowerShell twins

Each guard now ships twice: `<name>.sh` and `<name>.ps1`. The `.ps1` files are
behavioral twins, not ports in the loose sense. Same three-tier destructive
policy, same em-dash rules in the same order, same boundary logic including the
Claude state-path fallback, same reread ledger, same dual-emitted contracts,
same self-filter-before-anything ordering. Every hook entry in
`harness-hooks.json` carries both a `bash` and a `powershell` path, and Copilot
picks per platform, so one config file drives both.

They require **PowerShell 7+**. Windows PowerShell 5.1 is a different product
and will not run them: they use `$IsWindows`, which 5.1 does not define, and
rely on PowerShell 7 JSON handling.

### What the rewrite tier does without a `trash` CLI

Windows ships no trash command, so tier 2 rewrites to a bundled helper,
`hooks/lib/recycle.ps1`, invoked as
`pwsh -NoProfile -File <hooks>/lib/recycle.ps1 <targets>`. It sends each path to
the Recycle Bin through `Microsoft.VisualBasic.FileIO.FileSystem`.

A separate file rather than an inline `-Command` string, deliberately: the
rewritten command is executed by whatever shell Copilot spawns, and an inline
PowerShell one-liner would carry nested quoting and `$` sigils whose survival
depends on whether that shell is pwsh, cmd.exe or Git Bash. The guard cannot
verify that from inside. Rewriting to a plain `-File` invocation keeps the
emitted command quoting-free and mirrors exactly how the POSIX twin rewrites to
an external binary. `$env:HARNESS_TRASH_CMD` overrides the helper in both twins.

With neither a helper nor an override the tier BLOCKS rather than rewriting,
which is the same safe direction the POSIX twin takes when no trash binary is on
PATH.

### PowerShell gotchas this port had to handle

| Gotcha | Consequence if missed | Handling |
|---|---|---|
| `ConvertTo-Json` defaults to depth 2 | nested `tool_input` silently serialized as `"System.Collections.Hashtable"`, corrupting the rewrite | `-Depth 20` on every emit, with a round-trip test asserting a nested/array/null/bool/number payload survives byte-identically |
| `Microsoft.VisualBasic` loads on non-Windows | an availability check based on `Add-Type` alone reports success, then `SendToRecycleBin` throws at runtime | gate on `$IsWindows` **and** the `Add-Type` result |
| String comparison is case-insensitive by default | wrong for exact matching | explicit `StringComparison` on the boundary match; see the case note below |
| Pipeline stringification adds trailing newlines | a file's final newline silently changes on transform | `[Console]::In.ReadToEnd()` plus `[regex]::Replace`, which preserve them exactly; the trailing-newline test case is the canary |
| `perl -pe` loops per line, .NET does not | the line-start em-dash rule would fire once per payload instead of once per line | `RegexOptions.Multiline` on rule 1 |
| POSIX bracket classes do not exist in .NET | `[[:space:]]` matches literal characters, so patterns silently never fire | every pattern transliterated to `\s` / `[a-zA-Z0-9]`, in single-quoted strings so PowerShell's backtick and `$` cannot touch them |
| Payload paths may use either separator | a backslash path misses a forward-slash allowlist pattern | both sides normalized to forward slashes before matching |
| `Test-Path` without `-LiteralPath` treats `[` as a wildcard | a real filename containing brackets silently no-ops | `-LiteralPath` throughout |
| `Set-StrictMode` plus dynamic property access | throws on any absent key | not used in the hooks; a `Get-Prop` helper returns `$null` for absent keys |

### One deliberate behavioral difference

Boundary path comparison is **case-insensitive in the `.ps1` twin and
case-sensitive in the `.sh` twin**. That is correct on each platform rather than
a porting slip: Windows filesystems are case-insensitive, POSIX ones are not. It
is the only place the twins do not agree, and it is invisible on the test suite
because the suite uses consistent casing.

### What remains Windows-unverified

The recycle path itself. `recycle.ps1` refuses to run off Windows by design, so
on macOS the suite asserts the BLOCK fallback instead, which is the behavior
that actually protects the user. Needs a real Windows box to confirm: that
`Microsoft.VisualBasic` loads there, that `DeleteDirectory`/`DeleteFile` with
`SendToRecycleBin` behave as expected, and that the rewritten command string
survives whatever shell Copilot spawns. Everything else, including every block,
every allow, every self-filter and the full round-trip fidelity of
`modifiedArgs`, is exercised on both twins by the standard suite.

## UNVERIFIED

Everything below is prose-documented, inferred, or environment-specific. None of
it is load-bearing for tiers 0 through 2, and each item names how to settle it.

1. **Exact argument schemas of the Copilot tools.** Mitigated by key probing
   rather than resolved. Settle it by running one call of each tool with a
   logging `postToolUse` hook and reading the payload.
2. **Whether a rewrite is honored without an accompanying
   `permissionDecision`.** The em-dash transform depends on it, in both emitted
   forms. If it turns out not to be, the fix is to add
   `"permissionDecision":"ask"` to both, which is behavior-preserving relative
   to the normal flow but noisier.
   Related and also open: **which rewrite contract each front end actually
   reads.** Medium confidence that `modifiedArgs` is CLI-only and that
   `hookSpecificOutput.updatedInput` is the VS Code form. Mitigated by
   dual-emitting both rather than resolved. Settle it by watching whether a
   rewrite takes effect in each front end.
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
- `code.visualstudio.com/docs/agent-customization/hooks` (VS Code hook output
  fields, matcher behavior, inner-key casing)
- `code.visualstudio.com/docs/agent-customization/custom-agents`,
  `/custom-instructions`, `/mcp-servers`
- `code.visualstudio.com/docs/agents/run/approvals` (`chat.permissions.default`,
  `chat.tools.eligibleForAutoApproval`, `chat.tools.global.autoApprove`,
  `chat.tools.urls.autoApprove`, `chat.tools.terminal.autoApprove`)
- `code.visualstudio.com/docs/agents/agent-harnesses` (Session Target,
  `github.copilot.chat.claudeAgent.enabled`)
- `docs.github.com/en/copilot/reference/enterprise-administrators/enterprise-managed-settings`
  (`enabledPlugins`, `strictKnownMarketplaces`)

## Addendum, 2026-08-25: the Claude target also runs on a Copilot-only Windows box

Two things learned after this document was written, both of which change which
installer runs first on a work machine that has a Copilot license and no Claude
Code license.

**1. The Copilot-hosted Claude coding agent loads the full `~/.claude` tree.**
It is built on the Claude Agent SDK, billed to Copilot, and driven from VS Code,
and in daily use it picks up the `CLAUDE.md` rules, `~/.claude/skills`, the
`settings.json` hooks, and the `agents/*.md` subagents. This is observed
behavior, not a documented guarantee: the mapping table above was built from
vendor documentation, and both vendors are silent on this. Treat it as it is
written here, something confirmed in use that could change without notice.

The consequence for this repo: `bin/install.sh` is the PRIMARY install on such
a box, and the Copilot port documented above becomes the fallback that covers
Copilot CLI and the non-Claude models. Nothing in the port changes; what changes
is the install order in the README.

**2. Tier 2 of the Claude target needed a Windows wiring, and now has one.**
Tiers 0, 1 and 3 are markdown and already worked through Git Bash or WSL. Tier 2
did not: `claude/settings.work.template.json` wires each guard as a bare `.sh`
path, and which shell the agent spawns a hook command through on Windows is
undocumented. If it is not Git Bash, those guards silently never fire.

`claude/settings.work.windows.template.json` wires the same four guards as
`pwsh -NoProfile -File "__CLAUDE_HOME__/hooks/<name>.ps1"` (script path quoted:
a profile directory with a space in it would split an unquoted one, and a guard
wired to a split path never fires), using the very same
PowerShell twins this document specified for the Copilot target. They were
written to be reusable that way: they self-filter on both tool-name families,
read both inner-key casings, and dual-emit the Claude contract alongside the
Copilot CLI's top-level keys, so no policy change was needed to adopt them here.
Two adjustments were needed:

- The twins resolved `guard.log` and the edit-boundary state file against
  `~/.copilot`. They now resolve against the directory the script is installed
  in first, falling back to the old `COPILOT_HOME` and `CLAUDE_CONFIG_DIR`
  chain. Under `~/.copilot/hooks` every path resolves exactly as before.
- `manifest.txt` rows have no platform column, so the kind carries it: the five
  `.ps1` rows are now `authored-win`, and `bin/install.sh --windows` is the only
  reader that installs them. `bin/export.sh` and `bin/import.sh` walk `sync`
  rows only and are unaffected; `guard/scan.sh` never reads the manifest.

`log-skill-fire` has no PowerShell twin, so the Windows template carries no
`PostToolUse` block. That hook only appends a line to a log, so nothing
protective is missing. The Recycle Bin rewrite tier stays unverified on real
Windows, exactly as the known-gaps section of the README says: it is the same
helper script, and only a real Windows box can settle it.

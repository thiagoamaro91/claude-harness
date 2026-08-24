# claude-harness

The portable, work-safe subset of a personal agent harness: seven skills, one
subagent, guard hooks, two core rule documents, and the tooling to install them
on a machine you do not control.

It installs onto **two targets**: Claude Code, and GitHub Copilot (both the CLI
and Copilot in VS Code). The rules, the skills, and the guard policies are the
same on both; only the harness plumbing differs.

This exists because a good agent setup takes months to tune and none of it
should have to be rebuilt from memory on a new laptop. It also exists because
the obvious shortcut, cloning the whole personal config, drags along a personal
note vault, a personal messaging bridge, family names, and client names. This
repo is the half that can travel.

## The litmus rule

**Every committed byte must pass both tests: employer IT can read it without
raising an eyebrow, and it touches no client or personal data.**

That rule is enforced mechanically, not by good intentions:

- `guard/scan.sh` scans tracked files for absolute home paths, personal vault
  paths and URL schemes, personal hostnames, chat ids, IBAN-shaped strings, and
  stray email addresses, plus every pattern in a private denylist.
- `guard/denylist.local` holds the genuinely sensitive strings (real names,
  employer and client names, internal hostnames, phone numbers). It is
  gitignored, because a committed denylist would name the very things it
  protects. Copy `guard/denylist.example` and fill it in.
- `.githooks/pre-push` runs the scan and refuses the push on any finding.
  Enable it once per clone with `git config core.hooksPath .githooks`.
- `manifest.txt` is the allowlist. Every file has a row. Nothing outside it
  belongs in the repo, and the sync scripts iterate that file rather than
  walking the tree.

## Two targets, one body of content

```
claude/       Claude Code target       -> bin/install.sh          -> ~/.claude
copilot/      GitHub Copilot target    -> bin/install-copilot.sh  -> ~/.copilot
claude/skills/   shared by both, installed from one place, never duplicated
```

The `SKILL.md` format is identical in both harnesses, so the Copilot installer
reads the skills straight out of `claude/skills/`. There is no second copy to
drift.

What is genuinely per-target: the rule files (Copilot wants
`*.instructions.md` with `applyTo:` frontmatter), the subagent file (Copilot
wants `*.agent.md`), the hook scripts (different decision contract), the hook
wiring, and the settings shape.

Both targets can be installed on the same machine. They share no state: separate
config directories, separate guard logs, separate boundary state.

Design detail, gotchas, and the full three-way mapping table:
`docs/copilot-port_design_2026-08-24.md`.

## The tier ladder

Work policies are unknown until you ask. Each tier adds capability and adds a
thing that could be blocked, so you can stop at whatever tier the answers allow
and still have something useful. The ladder is the same for both targets.

| Tier | Claude Code adds | Copilot adds | Needs |
|---|---|---|---|
| 0 | `CLAUDE.core.md`, `DISPATCH.core.md`, the work `CLAUDE.md` template | the same two documents as `harness-core.instructions.md` and `dispatch.instructions.md` | Nothing. Plain markdown, nothing executes. |
| 1 | 7 skills, 1 subagent | the same 7 skills, the same subagent as `web-verifier.agent.md` | Markdown only, nothing executes. Two caveats: the `autonomous` skill installs its guidance here but its automation only at tier 2, so at tier 1 it walks you through the work by hand; and `graphify` expects a third-party CLI installed from PyPI, a software-approval item on a managed machine. |
| 2 | 5 guard hooks, settings wiring, the `autonomous` skill's executable helpers | 4 guard hooks, `hooks/harness-hooks.json` wiring, the settings template, the same helpers | Permission for the agent to run local shell scripts. The guards fire on every tool call; the helper scripts run only when you invoke the `autonomous` skill. Needs `jq`; `perl` for the em-dash transform. |
| 3 | MCP and plugin manifests | the same, plus two MCP example files and the VS Code settings snippet | Network access and a policy decision per server. Installs nothing by itself. |

Tier 1 is the default because it is the best capability-per-risk trade: it is
pure markdown, nothing executes. Tier 2 is the real step up in what you are
asking IT to accept.

Copilot gets four guard hooks rather than five: `log-skill-fire.sh` is not
ported, because Copilot has no Skill tool to hook. Skills trigger from their
description or from a slash command, and neither surfaces as a tool call.

## Work-PC quickstart, Copilot

This is the path for a machine with a Copilot license and no Claude Code
license.

```bash
git clone <your-remote>/claude-harness ~/claude-harness
cd ~/claude-harness
git config core.hooksPath .githooks
cp guard/denylist.example guard/denylist.local   # then fill it in, see below

./bin/install-copilot.sh --tier 1 --dry-run      # always look first
./bin/install-copilot.sh --tier 1
```

`guard/denylist.local` never travels with a clone (it is gitignored on purpose),
so a fresh clone has no private guard at all and `guard/scan.sh` fails closed
until you fill one in. Replace every `PLACEHOLDER` line with a real pattern; a
verbatim copy of the example is treated as unconfigured and still fails.

Per tier:

- **Tier 0**, if executable content is a problem or you are still waiting on
  answers: `./bin/install-copilot.sh --tier 0`. You get the two instruction
  files and nothing else. This is a real, useful state.
- **Tier 1**, the default: adds `autonomous`, `edit-freeze`, `expert-panel`,
  `forcing-questions`, `graphify`, `humanizer`, `spec-diagram`, plus the
  `web-verifier` custom agent (`/agent web-verifier`).
- **Tier 2**, once shell hooks are cleared: adds the four guards, writes
  `~/.copilot/hooks/harness-hooks.json` with the real paths substituted in, and
  either installs `settings.json` (if none exists) or writes the template
  beside yours. Verify afterwards:
  ```bash
  bash copilot/hooks/tests/test-copilot-guards-smoke.sh
  HOOKS_DIR=~/.copilot/hooks bash copilot/hooks/tests/test-copilot-guards-smoke.sh
  ```
  The second form tests the installed copies rather than the repo copies.
  Then merge `copilot/vscode-settings.snippet.jsonc` into your VS Code settings
  by hand. That is not optional if you use VS Code: see the known gaps below.
  The snippet covers the instruction-file gates (`chat.useAgentsMdFile`,
  `chat.useClaudeMdFile`, `chat.useNestedAgentsMdFiles`), which decide whether
  the harness rule files are read at all, and the approvals set
  (`chat.permissions.default`, `chat.tools.eligibleForAutoApproval`,
  `chat.tools.terminal.autoApprove` and friends).
- **Tier 3** prints a reading list and copies nothing. Work through it with IT.

Set `COPILOT_HOME` (or pass `--config-dir`) if your config lives somewhere other
than `~/.copilot`. The installer substitutes `__COPILOT_HOME__` and
`__CLAUDE_HOME__` in every installed file with the real directory.

## First-run detection on the work box

Do this **before** planning around any capability. Organization policy can pin
models, disable bypass modes, deny MCP outright, and force its own hooks through
`managed-settings.json`, whose precedence (MDM, then server-managed, then file,
then user) beats everything this repo installs. Copilot CLI itself is an
organization toggle, so it may not be available at all.

```bash
copilot plugins list --json     # what is already installed and forced
copilot                         # then, inside the session:
  /env                          # environment and effective settings
  /model                        # which models the organization actually enables
  /agent                        # whether the web-verifier agent was picked up
```

Expect MCP to be **off**. It is disabled by default in GitHub organizations and
needs an administrator to allowlist each server. Nothing in tiers 0 through 2
depends on it.

## Work-PC quickstart, Claude Code

Unchanged from before:

```bash
git config core.hooksPath .githooks
./bin/install.sh --tier 1 --dry-run
./bin/install.sh --tier 1
bash claude/hooks/tests/test-guards-smoke.sh
```

Set `CLAUDE_CONFIG_DIR` (or pass `--config-dir`) if your config lives somewhere
other than `~/.claude`.

## Known gaps on the Copilot target

Stated plainly, because a guard you believe in and that does not fire is worse
than no guard.

- **VS Code parses hook matchers but ignores them.** Every hook fires on every
  tool call. Each ported script therefore self-filters on the tool name and
  exits immediately when the tool is not its own. This is handled, but it is the
  reason the Copilot hooks are not a byte-for-byte copy of the Claude ones.
- **Hook timeouts always fail open.** The tool call proceeds. A shorter timeout
  is therefore *less* safe, not more; the shipped value is 10 seconds and should
  not be lowered. Treat the hooks as a safety net and use the VS Code deny lists
  in `copilot/vscode-settings.snippet.jsonc` as the second line, since those do
  not time out.
- **The two front ends want different hook response shapes.** The CLI documents
  top-level `permissionDecision` and `modifiedArgs`; VS Code documents
  Claude-style `hookSpecificOutput`. Confidence on that split is only medium, so
  every guard emits BOTH forms in one response and lets each runtime read the
  half it understands. Unknown fields are ignored, so the duplication is free.
- **VS Code sends camelCase inner tool arguments.** The payload envelope is
  snake_case in both front ends, but the inner `tool_input` properties are
  camelCase in VS Code (`tool_input.filePath`) and may be snake_case from the
  CLI. Every guard reads both spellings; a guard reading one casing would
  silently never fire on the other front end.
- **Hooks are a Preview feature.** The contract can change under you. The smoke
  test is the canary: run it after any Copilot upgrade.
- **Windows is not covered.** Hook objects accept `bash` and `powershell` keys
  side by side, but v1 ships bash only. On Windows the guards do not fire.
- **No plugin packaging.** Agent Plugins 1.0 would bundle all of this into one
  installable unit, but plugin-shipped hooks are currently broken
  (`github/copilot-cli` issues #2540 and #3659). An installer that works beats a
  plugin that looks installed. Revisit when those close.
- **`log-skill-fire.sh` is not ported.** No Skill tool exists to hook.
- **Two shared skills still name the Claude config directory.** The skills are
  installed verbatim onto both targets, so a literal `~/.claude` path inside one
  is not rewritten. The case that actually broke something, `edit-freeze` arming
  a state file the Copilot hook never read, is fixed inside the Copilot hook,
  which now honors both state paths. What remains: the `autonomous` skill's
  ledger writes under the Claude directory rather than the Copilot one (it
  works, it is just in the neighboring folder), and two of its reference
  documents quote `~/.claude/skills/...` invocation paths in prose. Fixing those
  properly means parameterizing the shared skills, which changes the Claude
  target too, so it is left as a separate change.
- **The settings template sets nothing active.** The permissions schema inside
  `~/.copilot/settings.json` is prose-documented only, and an unverified key
  that fails to parse is worse than an empty file. The real wiring lives in
  `~/.copilot/hooks/harness-hooks.json`, and the deny rules are `--deny-tool`
  command-line flags, which the template documents as a ready-to-use one-liner.

## Ask IT these questions before installing anything

Read the acceptable-use policy first. Then:

1. **Personal repository access.** May I clone a private repository from my
   personal GitHub account onto this machine? (Tier 0 and up.)
2. **Token usage.** If yes, may I authenticate with a **fine-grained personal
   access token scoped to that single repository**, and where should it be
   stored? Never a full `gh auth login` on a work box: that grants the machine
   your whole personal GitHub account.
3. **Agent-run shell hooks.** May the agent execute local shell scripts on
   every tool call? That is what a hook is. (Tier 2. The guards here only block,
   rewrite, or log; none makes a network call.)
4. **MCP servers.** May I run local helper processes that the agent calls, some
   of which make outbound network requests? (Tier 3, see
   `claude/mcp.manifest.md`. Expect the organization default to be no.)
5. **Plugin marketplaces.** May I install plugins from third-party
   marketplaces, and does each one need software approval first? (Tier 3, see
   `claude/plugins.manifest.md`.)

Ask 1 through 3 on day one. Questions 4 and 5 can wait until something actually
needs them.

## The context loop is not in this repo

The session-start context load and the wrap-up save deliberately live
elsewhere: they already ship publicly in **warmstart**
(github.com/thiagoamaro91/warmstart). Install that plugin if you want the
context loop. Duplicating it here would mean maintaining two copies of the
same thing.

## The sync workflow

Three scripts, all reading `manifest.txt`, none of them ever blind-copying a
tree.

```
home ~/.claude  --[bin/export.sh]-->  repo  --[bin/install.sh]-->  work ~/.claude
                <--[bin/import.sh]--        --[bin/install-copilot.sh]--> work ~/.copilot
```

1. **Export at home.** `./bin/export.sh` diffs every live file against its repo
   copy and prints the hunks. `--apply <path>` pulls named files in. The repo
   copies are scrubbed and parameterized on purpose, so they are meant to
   differ from the live originals: a diff is information, not a defect, and
   anything you pull in must be re-scrubbed before it is committed. Any
   `--apply` run finishes with `guard/scan.sh` and exits nonzero if it finds
   something.

2. **Install at work.** `./bin/install.sh --tier N` or
   `./bin/install-copilot.sh --tier N`. Existing files are backed up to
   `<config-dir>/harness-backup-<timestamp>/` before being overwritten, so a
   second run over a modified install is recoverable. `settings.json` is never
   clobbered by either installer.

3. **Import back home.** A tweak authored at work gets committed there, pulled
   home, and reviewed with `./bin/import.sh`. It diffs repo against live in the
   other direction and applies named files with a `.harness-bak-<timestamp>`
   backup. Read every hunk: the repo copy carries placeholders that a live
   personal file must not keep.

Export and import cover the Claude target only. The Copilot config directory has
no live counterpart at home to diff against, so `manifest.copilot.txt` is read
by its installer alone.

Nothing here pushes, and nothing runs on a schedule. Both directions are
manual and diff-reviewed, which is the point.

## What is deliberately absent

Skills and hooks that depend on a personal vault, a personal messaging account,
a second personal machine, or a specific folder tree were left out rather than
shipped broken. Anything that is a reinstallable product in its own right was
also left out. The short version: if it could not be made honest and portable
in place, it did not ship.

## Layout

```
claude/
  CLAUDE.core.md              portable rules (tier 0)
  DISPATCH.core.md            subagent dispatch contract (tier 0)
  settings.work.template.json hook wiring + deny list (tier 2)
  mcp.manifest.md             optional MCP servers (tier 3, reading only)
  plugins.manifest.md         optional plugins (tier 3, reading only)
  skills/                     7 skills (tier 1), shared by BOTH targets
  agents/                     1 subagent (tier 1)
  hooks/                      5 guards + smoke test (tier 2)
copilot/
  instructions/               the two core documents as *.instructions.md (tier 0)
  agents/web-verifier.agent.md  the same subagent, Copilot format (tier 1)
  hooks/                      4 ported guards + smoke test (tier 2)
  hooks/harness-hooks.template.json  hook wiring, __COPILOT_HOME__ substituted
  settings.work.template.json ~/.copilot/settings.json template (tier 2)
  vscode-settings.snippet.jsonc  VS Code settings to merge by hand (tier 3)
  mcp/                        two MCP example files, incompatible shapes (tier 3)
templates/CLAUDE.md.work      thin work-machine CLAUDE.md
docs/copilot-port_design_*.md the port design and the surface mapping table
bin/{export,install,install-copilot,import}.sh
guard/{scan.sh,denylist.example}
manifest.txt                  the allowlist
manifest.copilot.txt          the Copilot installer's file list
```

# claude-harness

The portable, work-safe subset of a personal Claude Code harness: seven skills,
three subagents, six guard hooks, two core rule documents, and the tooling to
install them on a machine you do not control.

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

## The tier ladder

Work policies are unknown until you ask. Each tier adds capability and adds a
thing that could be blocked, so you can stop at whatever tier the answers allow
and still have something useful.

| Tier | Adds | Needs |
|---|---|---|
| 0 | `CLAUDE.core.md`, `DISPATCH.core.md`, the work `CLAUDE.md` template | Nothing. Plain markdown, nothing executes. |
| 1 | 7 skills, 3 subagents | Mostly markdown, but not purely: the `autonomous` skill also ships helper scripts (`marathon/run.sh`, `ledger/append.py`, five Node workflow files) that the agent runs only when that skill is invoked, and `graphify` expects a third-party CLI installed from PyPI, which is a software-approval item on a managed machine. Nothing here is wired to run automatically. |
| 2 | 6 guard hooks, settings wiring | Permission for the agent to run local shell scripts on every tool call. Needs `jq`; `perl` for the em-dash transform. |
| 3 | MCP and plugin manifests | Network access and a policy decision per server or plugin. Installs nothing by itself. |

Tier 1 is the default because it is the best capability-per-risk trade. Its
helper scripts execute only inside a skill you deliberately invoke, whereas a
tier-2 hook runs on every single tool call, which is the real step up in what
you are asking IT to accept.

## Work-PC quickstart

```bash
git clone <your-remote>/claude-harness ~/claude-harness
cd ~/claude-harness
git config core.hooksPath .githooks

./bin/install.sh --tier 1 --dry-run     # always look first
./bin/install.sh --tier 1
```

Per tier:

- **Tier 0**, if executable content is a problem or you are still waiting on
  answers:
  ```bash
  ./bin/install.sh --tier 0
  cp templates/CLAUDE.md.work ~/.claude/CLAUDE.md   # then fill in the overlay
  ```
  You now have the core rules and nothing else. This is a real, useful state.

- **Tier 1**, the default: adds `autonomous`, `edit-freeze`, `expert-panel`,
  `forcing-questions`, `graphify`, `humanizer`, `spec-diagram`, plus the
  `web-verifier`, `agent-google`, and `agent-db` subagents.

- **Tier 2**, once shell hooks are cleared: adds the guards and either installs
  `settings.json` (if none exists) or writes the substituted template beside
  yours and prints merge steps. Verify afterwards:
  ```bash
  bash claude/hooks/tests/test-guards-smoke.sh
  HOOKS_DIR=~/.claude/hooks bash claude/hooks/tests/test-guards-smoke.sh
  ```
  The second form tests the installed copies rather than the repo copies.

- **Tier 3** prints two reading lists and copies nothing. Work through them
  with IT.

Set `CLAUDE_CONFIG_DIR` (or pass `--config-dir`) if your config lives somewhere
other than `~/.claude`. The installer substitutes `__CLAUDE_HOME__` in every
installed file with the real directory.

## Ask IT these five questions before installing anything

1. **Personal repository access.** May I clone a private repository from my
   personal GitHub account onto this machine? (Tier 0 and up. If no, the whole
   repo arrives by another route or not at all.)
2. **Token usage.** If yes, may I authenticate with a fine-grained personal
   access token scoped to that single repository, and where should it be
   stored? (A credential helper, a keychain, or an environment variable are
   very different answers.)
3. **Agent-run shell hooks.** May the agent execute local shell scripts on
   every tool call? That is what a hook is. (Tier 2. The six here only block,
   rewrite, or log; none makes a network call.)
4. **MCP servers.** May I run local helper processes that the agent calls, some
   of which make outbound network requests? (Tier 3, see
   `claude/mcp.manifest.md`.)
5. **Plugin marketplaces.** May I install Claude Code plugins from third-party
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
                <--[bin/import.sh]--
```

1. **Export at home.** `./bin/export.sh` diffs every live file against its repo
   copy and prints the hunks. `--apply <path>` pulls named files in. The repo
   copies are scrubbed and parameterized on purpose, so they are meant to
   differ from the live originals: a diff is information, not a defect, and
   anything you pull in must be re-scrubbed before it is committed. Any
   `--apply` run finishes with `guard/scan.sh` and exits nonzero if it finds
   something.

2. **Install at work.** `./bin/install.sh --tier N`. Existing files are backed
   up to `<config-dir>/harness-backup-<timestamp>/` before being overwritten,
   so a second run over a modified install is recoverable. `settings.json` is
   never clobbered.

3. **Import back home.** A tweak authored at work gets committed there, pulled
   home, and reviewed with `./bin/import.sh`. It diffs repo against live in the
   other direction and applies named files with a `.harness-bak-<timestamp>`
   backup. Read every hunk: the repo copy carries `__CLAUDE_HOME__`
   placeholders that a live personal file must not keep.

Nothing here pushes, and nothing runs on a schedule. Both directions are
manual and diff-reviewed, which is the point.

## What is deliberately absent

Skills and hooks that depend on a personal vault, a personal messaging account,
a second personal machine, or a specific folder tree were left out rather than
shipped broken. Anything that is a reinstallable product in its own right was
also left out. The full reasoning lives in the extraction notes rather than in
this file, but the short version: if it could not be made honest and portable
in place, it did not ship.

## Layout

```
claude/
  CLAUDE.core.md              portable rules (tier 0)
  DISPATCH.core.md            subagent dispatch contract (tier 0)
  settings.work.template.json hook wiring + deny list (tier 2)
  mcp.manifest.md             optional MCP servers (tier 3, reading only)
  plugins.manifest.md         optional plugins (tier 3, reading only)
  skills/                     7 skills (tier 1)
  agents/                     3 subagents (tier 1)
  hooks/                      6 guards + smoke test (tier 2)
templates/CLAUDE.md.work      thin work-machine CLAUDE.md
bin/{export,install,import}.sh
guard/{scan.sh,denylist.example}
manifest.txt                  the allowlist
```

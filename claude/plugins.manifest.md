# Plugin manifest (tier 3, policy-gated)

**Every plugin on this page is tier 3.** Plugins install from a marketplace,
which means a network fetch of third-party code that then runs inside your
agent session. On a managed machine, ask before installing any of them.

Nothing in tiers 0 through 2 depends on a plugin. This page is a shopping list
to work through with IT, not an install script.

## The policy question to ask first

> Can I install Claude Code plugins from a third-party marketplace on this
> machine, or does each plugin need to go through software approval first?

If the answer is no, stop here. Tiers 0 through 2 are a complete, working
harness without a single plugin.

## Recommended, in the order they earn their keep

### claude-mem

Cross-session memory: what was tried, what worked, how something was done
weeks ago.

- **Start it with a fresh, work-local database.** Do not carry a personal
  memory store onto a work machine, and do not carry a work memory store home.
  That is the whole boundary, and this is the plugin most able to violate it by
  accident.
- **Ask IT**: it persists session transcripts (your prompts and tool activity) to
  a local database on disk. Confirm that keeping that record on this machine is
  allowed before enabling it.
- Without it: every session starts cold. Compensate by keeping decisions in
  committed markdown in the repo you are working in.

### commit-commands

Commit, push, and pull-request helpers.

- Without it: you write the git commands yourself, which is fine. This is
  convenience, not capability.

### hookify

Turns an observed unwanted behavior into a hook that prevents it. The natural
companion to the six hooks in this repo when you find a seventh you need.

- Without it: write the hook by hand, using the shipped ones as templates.

### skill-creator

Scaffolds, edits, and evaluates skills. Useful when a work-specific workflow
turns out to be worth a skill.

- Without it: copy an existing `SKILL.md` and adapt it.

### code-review

Structured review of a branch or a pull request.

- Without it: ask for a review in plain language, or use the `expert-panel`
  skill shipped at tier 1, which covers a good part of the same ground.

### claude-md-management

Audits and improves `CLAUDE.md` files across a repository. Handy when you
inherit a codebase whose project memory has drifted.

- Without it: read and edit those files by hand.

## Deliberately NOT installed on a work machine

Each of these authenticates to a personal account or a personal service, so none
belong on a work machine. Bridging a personal account to a work machine is exactly
the boundary this repo protects.

| Plugin category | Why it stays home |
|---|---|
| Personal messaging integrations | Authenticate to a personal messaging account. Work notifications belong on a work channel. |
| Personal note-vault integrations | Read and write a personal knowledge base. |
| Personal deployment / hosting integrations | Authenticate to a personal deployment account with personal project credentials. |
| Front-end / visual-design helpers | Design work that is not part of this job. Reinstallable any time if that changes. |
| Personal-project database integrations | Carry personal-project database credentials. Reinstall from the marketplace if a work project genuinely needs one, with work credentials only. |

## If plugins are blocked entirely

Nothing above is load-bearing. Tier 1 gives you seven skills and three agents;
tier 2 adds the six guard hooks. That is the harness. Plugins are the layer you
add if and when policy allows.

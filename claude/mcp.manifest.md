# MCP manifest (tier 3, policy-gated)

**Every MCP server on this page is tier 3.** An MCP server is an external
process that the agent can call, and most of them talk to the network. On a
managed machine that is a security-review question, not a preference. Ask
before installing any of them, and install none of them by default.

Nothing in tiers 0 through 2 depends on an MCP server. Skills and agents that can
use one carry an "MCP optional" fallback line telling you what to do without it.

## The policy question to ask first

> Are agent-launched local helper processes that make outbound network calls
> allowed on this machine, and if so, does each one need to go through a review
> before I add it?

Get that answered once, in writing, before you install anything below. Then ask
the per-server question in each entry.

## Recommended, in the order they earn their keep

### playwright

Browser automation: form fills, portals with no API, downloads, checking how a
page actually renders.

- **Without it**: the "exhaust the toolbox" rule in `CLAUDE.core.md` loses its
  first and best option. Anything that needs a real browser becomes a manual
  step for the human.
- **Ask IT**: it downloads and runs a bundled browser binary. Is that allowed,
  and does the browser need to go through the standard software-approval path?
  Does it need to reach internal sites through the corporate proxy?

### context7

Current library, framework, and SDK documentation, fetched on demand.

- **Without it**: the agent answers library questions from training data, which
  is stale by construction. Compensate by pasting the relevant doc page into
  the conversation, or by pointing the agent at the vendored copy in the repo.
- **Ask IT**: it queries a third-party documentation service. Is that an
  approved outbound destination? Note that the queries themselves (library
  names, sometimes API shapes) leave the machine.

### sequential-thinking

A structured multi-step reasoning scratchpad the model can call into.

- **Without it**: nothing breaks. Reasoning quality on long chains drops
  slightly. This is the most droppable entry on the page.
- **Ask IT**: it runs locally and makes no outbound calls, which usually makes
  it the easiest one to get approved. Confirm that reading of the local
  process-spawn policy.

### mermaid

Diagram validation and white-background PNG/SVG/PDF export, used by the
`spec-diagram` skill.

- **Without it**: `spec-diagram` still writes correct diagrams and says plainly
  that they went out unvalidated. For export, install the `mmdc` CLI
  (`npx @mermaid-js/mermaid-cli`) and use the CLI fallback the skill documents.
- **Ask IT**: rendering pulls the mermaid toolchain from npm. Is npm registry
  access allowed, and is there an internal mirror to point at instead?

## Deliberately not recommended for a work machine

Anything that connects to a personal account: personal note vaults, personal
messaging, personal cloud storage, personal deployment platforms. Not because
they are bad tools, but because bridging a work machine to a personal account
is the exact boundary this repo exists to keep intact. See
`plugins.manifest.md` for the same split on the plugin side.

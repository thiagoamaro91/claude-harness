---
name: expert-panel
description: Use when reviewing design decisions, architecture choices, specs, or implementation approaches. Convenes a panel of expert agents in parallel and synthesizes a unified verdict. Reads a per-project manifest (.claude/expert-panel.md) to anchor the panel to real project personas + ground each reviewer in the actual repo; falls back to 4 generic personas when no manifest exists.
---

# Expert Panel Review

Convenes a panel of specialized agents in parallel to review a decision, design, or spec. Collects individual verdicts and synthesizes a unified recommendation.

The panel is **project-aware**. If the current project ships a manifest (`.claude/expert-panel.md`), the skill uses *that project's own personas* (e.g. a backend fleet's `agent-backend`, `agent-code`) and grounds every reviewer in the real codebase. With no manifest, it falls back to 4 generic principal-level personas reviewing from the brief alone. Nothing breaks either way.

**Announce at start:** `Convening expert panel to review: [topic]` and one line naming the panel that resolved (e.g. `Panel: acme-api manifest - backend, code, architect, product (deep grounding)` or `Panel: default 4 personas (no manifest, brief-only)`).

## Two grounding modes

- **brief** - the reviewers see only the review brief plus any grounding files the manifest lists (their content is read and injected). Cheap, deterministic. Good for pure design/trade-off questions.
- **deep** - each reviewer is dispatched as a general-purpose agent **with `Read`/`Grep`/`Glob`** and told the project root + which paths to study, so it cites real files and line numbers instead of abstractions. ~3-5x the tokens, non-deterministic, but the verdicts are grounded in what the code actually does. Good for architecture reviews and "will this break X" questions.

`mode` is set by the manifest. With no manifest the mode is **brief**.

## Execution

### Step 1: Resolve the panel

1. Look for a manifest at `./.claude/expert-panel.md` (the directory the skill was invoked from). If `ARGUMENTS` names a different project directory, look there too. Do not walk above the git root.
2. **Manifest found** → parse its YAML frontmatter:
   - `personas:` - list of `{ file: <path>, as: <label> }`. `file` is relative to the project root, or `~/`-prefixed for home. `as` is an optional display label.
   - `grounding:` - list of file or directory paths (relative to project root or `~/`).
   - `mode:` - `deep` or `brief` (default `brief` if omitted).
   Resolve every persona `file` and confirm it exists. Skip (and note) any path that does not resolve - never invent a persona.
3. **No manifest** → default panel: the four `references/*.md` files below, `mode: brief`, grounding = only what's in `ARGUMENTS`.

| Default persona | File | Lens |
|-----------------|------|------|
| Principal Software Architect | `references/architect.md` | Architecture, coupling, extensibility, failure modes |
| Principal Software Developer | `references/dev-lead.md` | Implementation effort, testing, risk, deployment |
| Principal Data Architect | `references/data-architect.md` | Schema, queries, indexes, migration, data integrity |
| Product Owner | `references/product-owner.md` | User value, MVP scope, prioritization, market fit |

### Step 2: Build the review brief

From `ARGUMENTS`, assemble:
- **What's being reviewed**: the decision, design, or spec (if `ARGUMENTS` is a file path, read it and include its content).
- **Constraints**: tech stack, team size, timeline, budget (pull from the manifest's grounding / project CLAUDE.md if present).
- **Options** (if applicable) and **current state**.

### Step 3: Build grounding

- Resolve each `grounding:` path relative to the project root; expand `~`. For a directory, treat its files as a unit.
- **brief mode** → read each grounding file (cap ~1500 lines/file; for a large directory read the most relevant files and note any you skipped - no silent truncation). Concatenate into a `PROJECT GROUNDING` block that goes into every reviewer's prompt.
- **deep mode** → do **not** pre-read. Build a `GROUNDING PATHS` list (the resolved paths + the project root) and instruct each reviewer to read those paths, follow references, and inspect related code before voting.

### Step 4: Dispatch the panel

Launch **all personas in parallel** with the Agent tool. For each persona, read its file and use its body as the persona prompt (an agent-definition file's frontmatter is fine to include; its body is the system prompt). Build each agent's prompt as:

```
[persona file body]
---
PROJECT GROUNDING:           # brief mode: injected file contents
[grounding block]
   ...OR...
GROUNDING PATHS (read these before you vote):   # deep mode
project root: <abs path>
- <path>
- <path>
You have Read/Grep/Glob. Study these paths and any related code, then review.
---
REVIEW BRIEF:
[brief from Step 2]
---
Respond ONLY in the output format specified in your persona file. If your persona
file has no output format, use: Verdict (APPROVE / APPROVE WITH CONCERNS / REJECT),
Key Points (2-4), Risks, Suggested Changes.
```

- **brief mode**: dispatch with `model: "sonnet"` to keep cost reasonable. Note: the `CLAUDE_CODE_SUBAGENT_MODEL` env var in settings.json silently overrides all Agent tool `model:` hints; check settings.json if cost behavior is unexpected.
- **deep mode**: dispatch as `subagent_type: "general-purpose"` so the reviewer has file tools. The persona's own model applies only if the persona file lives under `.claude/agents/` in the current project; otherwise dispatch as general-purpose (the safe default). Note: `CLAUDE_CODE_SUBAGENT_MODEL` overrides model hints here too.

### Step 5: Synthesize

After all reviewers return, synthesize into this format:

```markdown
## Panel Verdict: [UNANIMOUS APPROVE / MAJORITY APPROVE / SPLIT / MAJORITY REJECT / UNANIMOUS REJECT]

**Panel**: [which manifest or "default"] | **Grounding**: [deep/brief]
**Votes**: [Persona1] [A/C/R] | [Persona2] [A/C/R] | ...

### Consensus Points
- Points where all/most panelists agree (2-4 bullets)

### Dissent
- Any disagreements or minority positions (skip if unanimous)

### Recommended Changes
- Merged, deduplicated, prioritized by severity. Tag each with who raised it.
- In deep mode, keep the file:line citations the reviewers gave.

### Risk Summary
- Top 3 risks across all reviews, with mitigation suggestions
```

## The manifest

A project opts in by dropping `.claude/expert-panel.md` in its root. See `references/MANIFEST-TEMPLATE.md` for a copy-paste starting point. Minimal example:

```markdown
---
personas:
  - file: .claude/agents/agent-backend.md
    as: Backend Lead
  - file: ~/.claude/skills/expert-panel/references/architect.md
    as: Principal Architect
grounding:
  - CLAUDE.md
  - src/
mode: deep
---
# Notes (optional, human-facing): how this panel should weigh trade-offs.
```

Anchoring rule: prefer the project's **own** agent definitions as personas - they are the real, opinionated profiles for that codebase. Mix in generic `references/*.md` personas only to cover a lens the project fleet lacks (e.g. a Product Owner for a code-only fleet). **Never** model a persona on a real named individual - the agent will fabricate that person's opinions, which violates the workspace anti-fabrication rule.

## Customization

- Edit a generic persona: change the matching `references/*.md`. The skill reads them fresh each run.
- Add a project persona: point a manifest `personas:` entry at any agent-definition or persona markdown file.
- Add a brand-new generic persona: create `references/[name].md`, then reference it from a manifest or add it to the default table above.

## Guardrails

- Dispatch all resolved personas in parallel - never sequential.
- Never fabricate a reviewer's opinion - only report what each actually returned.
- Never invent a persona or grounding path. If a manifest path does not resolve, skip it and say so in the synthesis.
- If a reviewer has not returned by Agent tool timeout, mark it as "timed out" in the synthesis and proceed with the remaining verdicts.
- In deep mode, if a reviewer could not read a path it was asked to, surface that rather than letting it review blind.
- Keep the synthesis concise - the user asked for a verdict, not a novel.

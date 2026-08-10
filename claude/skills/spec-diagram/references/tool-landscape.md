# Tool landscape and provenance

Background for the skill: which Mermaid tool does what, why this skill exists in the shape it does,
and the sources behind it. Not needed for routine diagram work; read it when deciding tooling or
onboarding someone to the setup.

## The two-MCP split (this is the operational core)

Two MCP servers cover two different jobs. They complement, they do not compete:

| MCP server | Job | Writes to disk? | When |
|------------|-----|-----------------|------|
| **Mermaid Chart** (`validate_and_render_mermaid_diagram`) | One-shot syntax validation + render | No (returns inline SVG/PNG payload) | Before saving any diagram. Read only the `valid` field. |
| **claude-mermaid** (`mermaid_preview`, `mermaid_save`) | Live browser preview + white-background PNG/SVG/PDF export | Yes (`mermaid_save`) | When the diagram must embed in a white-page docx/pptx/PDF. |

claude-mermaid is what makes the docx/pptx workflow possible: `mermaid_save` with a white background
is the only one of the two that writes a white-bg image to disk. Mermaid Chart cannot do
that (inline only). Hence both are used together.

### Install (portable steps)

- `npm install -g claude-mermaid` installs the CLI. It pulls Puppeteer plus a pinned Chromium
  (~150-200MB). To skip the bundled Chromium download and reuse an existing browser, point
  `PUPPETEER_EXECUTABLE_PATH` at a local Chrome/Chromium binary before installing.
- `claude mcp add --scope user mermaid claude-mermaid` registers it as the `mermaid` user MCP server.
- Live preview runs a local server on ports 3737-3747 while Claude Code is active; SVG live-reload,
  multiple concurrent previews, themes, pan/zoom.

Plugin-policy note: this is a CLI + MCP server, NOT a marketplace plugin, so it fits a
marketplace-only plugin policy. Custom skills like this one live in `~/.claude/skills/`, also allowed.

## Why one folded skill instead of adopting third-party skills

The approach: fold the best two third-party skills into ONE skill, plus the
collected gotchas and this research, rather than clone-and-maintain. Reasons: single source of truth, no
low-star third-party maintenance risk, no per-clone palette edits, and the skill's specifics (warm-dark
gold, ELK >15, 60-30-10, the two-MCP workflow) live nowhere else.

### Source skills surveyed (six tools disambiguated; no official Anthropic Mermaid skill exists)

| Tool | Stars | Verdict | What was folded in |
|------|-------|---------|--------------------|
| `veelenga/claude-mermaid` (MCP server) | 174 | INSTALLED | The white-bg disk-export half of the workflow. |
| `mgranberry/mermaid-diagram-skill` | 4 | FOLDED IN | "Diagrams argue" philosophy, isomorphism/education tests, concept->pattern matrix, line-crossing reduction, classDef-with-color discipline. |
| `awesome-skills/mermaid-syntax-skill` | 13 | FOLDED IN | The v11 trap list: reserved words beyond `end`, markdown-by-default, linkStyle-hex-last, arrowless-edge bug, the `<br>` compatibility matrix. |
| `WH-2099/mermaid-skill` | 120 | SKIPPED | Breadth only (23 diagram types); no quality guidance. |
| `Agents365-ai/mermaid-skill` | 97 | SKIPPED | Vision self-check of rendered PNG is interesting but needs mmdc/Kroki and adds per-call friction. |
| `ccheney/robust-skills` mermaid | 48 | SKIPPED | Obsidian-aware + proactive, but minimal quality uplift over the above. |

### What the third-party skills did NOT cover (now in this skill)

- The warm-dark **gold** palette (all third-party recipes default to a blue `#3b82f6` primary).
- The **ELK renderer** rule for >15 nodes.
- The **60-30-10** colour ratio discipline.
- The **firm spec-leads-with-a-diagram** requirement and the markdown-native embedded render path.
- The **two-MCP** validate-then-export workflow.

## Design principles this skill operationalizes

- Every spec leads with an embedded diagram (architecture-first; the why).
- Mermaid for architecture and data flow, not ASCII.

The rendering gotchas are expanded in `syntax-gotchas.md`. These principles carry the preference and
rationale; the skill carries the how.

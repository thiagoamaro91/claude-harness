---
name: spec-diagram
description: >-
  Author Mermaid diagrams and any spec/design doc in a consistent style. Use this skill WHENEVER you
  are about to write a spec, design doc, architecture note, ADR, or technical plan (every one must
  LEAD with an embedded ```mermaid block, architecture-first, prose as backup), AND whenever
  creating, embedding, fixing, or debugging any Mermaid diagram (flowchart, sequence, state, ER,
  C4, class, mindmap, timeline) - even when the user only says "diagram this", "visualize the
  flow", "add an architecture diagram", "sketch the data flow", or "why won't my mermaid render".
  Bakes in the warm-dark gold palette, the v11 syntax traps, the validate-via-Mermaid-Chart-MCP
  loop, ELK layout for large graphs, and white-background PNG/SVG export (claude-mermaid) for
  docx/pptx embedding. Reach for it BEFORE writing the diagram, not after.
---

# spec-diagram

A skill for diagrams that carry an argument and specs that lead with a picture. It folds three
sources into one: mgranberry's "diagrams that argue" design philosophy, awesome-skills' v11 syntax
safety net, and the collected rendering gotchas + warm-dark gold palette. Two MCP servers do the
mechanical work (see Validate and Export below); this skill supplies the judgment.

## The firm requirement (non-negotiable)

Every spec, design doc, or technical plan the user reads must **lead with the architecture shown
visually**, not open with a wall of text. Concretely:

- Put an embedded ` ```mermaid ` block near the top, in an **"Architecture at a glance"** section,
  BEFORE the prose. It renders natively in most markdown viewers, so no image file is needed for
  reading.
- The prose spec is detailed backup. The diagram is the primary review surface: the reader grasps the
  structure and the decision rationale in seconds and reacts fast. A 15-minute wall of text to
  validate a design wastes their time.
- Do this for every spec, not only when asked. When showing 2-4 design options, lead each with its
  own small diagram.

Why a diagram and not ASCII: Mermaid is for architecture and data flow; ASCII boxes do not survive
edits or scale. The embedded block is the required baseline; a warm-dark HTML one-pager is an
optional companion when a richer artifact helps.

## Core philosophy: diagrams ARGUE, they do not DISPLAY

A diagram is a visual argument about relationships, causality, and flow that words alone cannot
express. The shape should BE the meaning. Two tests before you commit:

- **Isomorphism test**: strip all text. Does the structure alone still communicate the concept? If
  not, redesign the structure, do not add labels.
- **Education test**: could someone learn something concrete from this, or does it just label
  boxes? Good diagrams show real event names, real formats, real decision points, not generic
  "Process -> Output".

Five equal boxes in a row is displaying. Each concept getting a shape and position that mirrors its
behaviour is arguing. Match the visual pattern to the concept:

| If the concept...            | Use this pattern                          |
|------------------------------|-------------------------------------------|
| Spawns multiple outputs      | Fan-out (one node, many outgoing edges)   |
| Combines inputs into one     | Convergence (many nodes into one)         |
| Has hierarchy / nesting      | Tree (mindmap or nested subgraphs)        |
| Is a sequence of steps       | Sequence diagram or timeline              |
| Loops / improves continuously| Cycle (state self-transition or back-edge)|
| Transforms input to output   | Assembly line (flowchart pipeline)        |
| Compares two things          | Side-by-side parallel subgraphs           |
| Separates into phases        | Subgraph boundaries                       |

For a multi-concept diagram, each major concept should use a **different** visual pattern. Uniform
card grids are a smell.

## Workflow

1. **Pick depth and type.** Executive overview = 5-7 nodes, high-level boxes. Technical doc = 10-15
   nodes, subgraphs and edge labels. Deep reference = split into multiple diagrams past ~20 nodes.
   If one system needs several audiences, draw several diagrams, not one that serves none.
2. **Draft the syntax** following `references/syntax-gotchas.md`. Use `flowchart`, never legacy
   `graph`. Use meaningful node IDs (`authService`, not `A`). Quote any label with special chars.
3. **Style with the default palette** (`references/palette.md`): `classDef` per semantic group, gold
   for the hero/decision node, max 3 fills per diagram (60-30-10). Never set a global
   `primaryTextColor`.
4. **Validate** before saving (see below). Fix syntax until valid.
5. **For >15 nodes**, switch on the ELK renderer (YAML frontmatter, see palette/gotchas) so the
   layout is not crushed.
6. **Export to white-background PNG/SVG** only when the diagram is headed for a docx/pptx/PDF on a
   white page (see Export). For on-screen reading in a markdown viewer, skip this; the embedded
   block is enough.

## Validate (Mermaid Chart MCP, inline, no disk write)

**MCP optional.** MCP servers are policy-gated in some environments. If the Mermaid Chart MCP is
not connected, validate with the `mmdc` CLI instead (`npx @mermaid-js/mermaid-cli -i in.mmd -o
/dev/null`, nonzero exit means invalid); if neither is available, say plainly in your output that
the diagram went out unvalidated rather than claiming it validated.

Use the **Mermaid Chart** MCP tool `validate_and_render_mermaid_diagram` as a
one-shot syntax check. It returns a large SVG/PNG payload: **read only the `valid` field, never
pull the whole result into context** (jq it or inspect just that key). A diagram that fails to
validate must not ship in a spec.

## Export white-background images (claude-mermaid MCP, writes to disk)

When the diagram must embed in a white-page document, use the **claude-mermaid** MCP (`mermaid`
server, tools `mermaid_preview` and `mermaid_save`). `mermaid_save` with a white background is the
only thing in this setup that writes a white-bg PNG/SVG/PDF to disk, which is the docx/pptx
embedding need. It complements the Mermaid Chart MCP; they do not conflict. Neither MCP is
required: the CLI fallback below covers both jobs.

CLI fallback if the MCP is unavailable:
```bash
npx @mermaid-js/mermaid-cli -i in.mmd -o out.png -b white -w 1400 -s 2
```
(`-b white` forces the white background, `-s 2` renders at 2x for crispness.)

## Reference files (load only when needed)

| File | Load when... |
|------|--------------|
| `references/palette.md` | Styling nodes: the warm-dark gold `classDef` recipes, ELK frontmatter, 60-30-10 discipline, dual-mode (dark viewer + white docx) reasoning. |
| `references/syntax-gotchas.md` | Writing or debugging syntax: the folded v11 trap list (reserved words, markdown-by-default, linkStyle hex, arrowless-edge bug, `<br>` matrix, quoting rules). Read it before a complex diagram and whenever a render fails. |
| `references/tool-landscape.md` | Deciding tooling or onboarding: which Mermaid tool does what, the verdicts and sources behind this skill, the two-MCP split. Background, not needed for routine diagram work. |

## Quality bar before shipping a diagram

- Syntax validates (Mermaid Chart MCP `valid: true`, or a clean `mmdc` run).
- Structure passes the isomorphism test (shape carries meaning without the labels).
- Each major concept uses a distinct visual pattern; no uniform grid.
- Palette: at most 3 fills, gold on the hero node, every `classDef` sets `fill` + `stroke` +
  `color` (so it survives both a dark markdown viewer and white docx pages).
- Labels with `(){}/:` or `<br>` are double-quoted; no node label is bare `end`.
- More than 15 nodes: ELK renderer on, or the diagram is split.

# Palette: warm-dark gold (dual-mode safe)

The single styling reference for spec-diagram. All branding is done through `classDef` semantic
styles embedded in the diagram itself, so the diagram is self-contained and renders consistently
everywhere: Obsidian (dark), GitHub, VS Code, and the white-background export pipeline. No
`%%{init}%%` themeVariables, no external theme files.

## The dual-mode problem (why pastel fills, not a saturated dashboard gold)

A dark-dashboard look (saturated gold on a near-black canvas with cream text) cannot be copied
directly into a Mermaid diagram, because the SAME diagram has to read on two opposite backgrounds:

- a **dark** markdown-viewer canvas (where the embedded block renders for reading), and
- a **white** docx/pptx/PDF page (where the exported PNG lands).

A fill tuned for one background fails on the other. The fix is the rule below, which makes contrast
depend only on the node's own fill and text, not on the page behind it.

**The rule: every `classDef` MUST set all three of `fill`, `stroke`, and `color`.** If you omit
`color`, the renderer's theme controls the text, and in dark mode that means light text on a pastel
fill, which destroys contrast. This is the single most common cause of unreadable diagrams. Never
set a global `primaryTextColor: '#fff'` in a theme init block; it is global and kills contrast on
every light node at once.

So the palette identity comes through the **hue family** (warm: gold, peach, rioja red, stone) at
**pastel saturation with dark text**, not through the dark-canvas gold of a dashboard. The gold
node still reads as the hero; it just wears an amber pastel instead of a neon.

## The recipes

Use `classDef` to name a semantic style, then apply with `:::` or `class`:

```
classDef accent fill:#fde68a,stroke:#b45309,color:#374151
A["Decision point"]:::accent
class B accent
```

| Concept (semantic role)     | Fill      | Stroke    | Text      | classDef line |
|-----------------------------|-----------|-----------|-----------|---------------|
| Hero / decision / the point | `#fde68a` | `#b45309` | `#374151` | `classDef accent fill:#fde68a,stroke:#b45309,color:#374151` |
| Start / trigger / input     | `#fed7aa` | `#c2410c` | `#374151` | `classDef trigger fill:#fed7aa,stroke:#c2410c,color:#374151` |
| Success / positive / done   | `#a7f3d0` | `#047857` | `#374151` | `classDef success fill:#a7f3d0,stroke:#047857,color:#374151` |
| Error / negative / blocked  | `#fecaca` | `#b91c1c` | `#374151` | `classDef error fill:#fecaca,stroke:#b91c1c,color:#374151` |
| Neutral / data / component  | `#e7e5e4` | `#78716c` | `#374151` | `classDef neutral fill:#e7e5e4,stroke:#78716c,color:#374151` |

`#fde68a` (amber) is the gold; it is the **10** in the 60-30-10 ratio and belongs on the one node
the reader's eye should land on. `#e7e5e4` (warm stone) is the **60** neutral for the bulk of the
boxes. Pick ONE of green/red/peach as the **30** accent for the diagram's secondary theme.

## 60-30-10 colour discipline

Max **3 fills** per diagram: roughly 60% neutral (stone), 30% one secondary, 10% gold accent.
Differentiate the rest with **shape and position**, not more colours. A rainbow of fills reads as
noise and defeats the "diagrams argue" goal. If you find yourself reaching for a fourth fill, the
diagram probably wants to be split or restructured instead.

## Large graphs: the ELK renderer

Mermaid's default layout engine crushes graphs past ~15 nodes into spaghetti. Switch to ELK via
YAML frontmatter (the modern, non-deprecated way; do not use `%%{init}%%`, deprecated since
v10.5.0):

```mermaid
---
config:
  flowchart:
    defaultRenderer: elk
---
flowchart TD
    ...
```

Past ~20 nodes, prefer splitting into multiple diagrams (one per layer or phase) over a single ELK
mega-graph.

## Diagram types that do not support classDef

- **Flowchart**: full support. The primary branding target.
- **State**: `classDef` applies to state nodes.
- **Sequence**: no `classDef`. Group with `box Color Title` using a pastel background.
- **Class**: limited; use `style` instead.
- **C4**: use `UpdateElementStyle`.
- **Mindmap**: no `classDef`; use `:::className` (beta) or `::icon()`.
- **ER / Sankey**: no `classDef`. Let them inherit the renderer default.

For types without `classDef`, leave nodes unstyled; the renderer's default theme is already tuned
for its own light/dark context. Do not fight it.

# Syntax gotchas (folded v11 safety net)

The defensive-syntax half of the skill. Folded from awesome-skills/mermaid-syntax-skill, mgranberry's
syntax-pitfalls, and collected rendering gotchas, deduplicated. Read this before a complex
diagram and whenever a render fails. The single rule that prevents about half of all failures:

> **When in doubt, quote the label.** `["My label"]` is always safer than `[My label]`.

## The critical few (prevent ~90% of errors)

1. **Quote special characters.** Any label containing `( ) [ ] { } / \ : ; # @ ! ? < > " '` or a
   comma must be wrapped in double quotes: `A["Step 1: init (fast)"]`, `B{"auth@domain?"}`. Naked
   special chars break the parser.
2. **Reserved words, not just `end`.** `end`, `default`, `style`, `linkStyle`, `classDef`, `class`,
   `call`, `href`, `click`, `interpolate` all break when used as a bare node. Pattern:
   `safeId["reserved text"]`. A node whose entire label is `end` is parsed as a block terminator;
   quote it (`["end"]`) or capitalize (`End`).
3. **`flowchart`, never `graph`.** Use modern `flowchart TD`; legacy `graph TD` lacks subgraph
   direction and modern shapes. Never mix the two in one block.
4. **Comments use `%%`.** A single `%` breaks the diagram.
5. **Hex colours only in styles** (`#RRGGBB`), never named colours in theme vars (they fail
   silently). Named colours are fine only inside `linkStyle` as a workaround (see #12).
6. **No node IDs starting with bare `o` or `x`.** `oNode`, `xLink` can be parsed as circle/cross
   edge types. Use full descriptive IDs.

## Line breaks: the `<br>` matrix

`\n` **never** works; it renders as the literal text `\n` in every diagram type. Use `<br>` inside a
double-quoted label. Prefer the bare `<br>` over the self-closing `<br/>`: both work in flowcharts,
but `<br/>` fails in some contexts (notably timeline event details). (This is sharper than the older
"use `<br/>` not `\n`" guidance; prefer `<br>`.)

| Diagram type | Node labels | Edge labels | Notes |
|--------------|-------------|-------------|-------|
| Flowchart    | yes `<br>`  | yes `<br>`  | n/a   |
| Sequence     | yes         | yes         | yes   |
| State        | yes         | yes         | n/a   |
| Class        | NO (members) | yes (rel labels only) | n/a |
| ER           | n/a         | inconsistent (works mmdc, fails IntelliJ) | n/a |
| C4           | yes         | yes         | n/a   |
| Mindmap      | yes         | n/a         | n/a   |
| Timeline     | yes `<br>`  | n/a         | `<br/>` fails in event details |
| Sankey       | NO          | NO          | keep labels short |

Always wrap any label containing `<br>` in double quotes.

## v11-specific traps (Mermaid 11)

7. **Markdown-by-default (breaking change from v10).** All node labels render as Markdown now, so
   `file_name_here` becomes `file` + italic + `here`. Quote labels with underscores: `["file_name"]`.
   Only `**bold**` and `_italic_` are supported; inline backtick code may not render.
8. **Arrowless edge bug (v11.0-11.4).** `A --- B` (line, no arrow) wrongly shows an arrow. Fixed in
   v11.5.0+. If stuck on an older version, use `A --> B` plus a `linkStyle` instead.
9. **linkStyle hex colour as LAST attribute fails.** `linkStyle 0 stroke-width:4px,stroke:#FF69B4`
   errors. Put the hex first (`stroke:#FF69B4,stroke-width:4px`) or use a CSS colour name as the
   last attribute.
10. **Escape commas in `stroke-dasharray`:** `stroke-dasharray:5\,5`.
11. **`%%{init}%%` is deprecated (since v10.5.0).** Put theme and config (including the ELK renderer)
    in YAML frontmatter at the top of the block instead. The only place `%%{init}%%` still shows up
    is one-off looks like hand-drawn mode, and even those are better in frontmatter.
12. **Secure settings cannot be set in frontmatter.** `maxTextSize` (default 50,000) and `maxEdges`
    (default 500) are ignored if set in the diagram; they need `mermaid.initialize()` in JS. If a
    diagram is big enough to hit `maxEdges`, split it.

## Subgraph traps

13. **Subgraph `direction` is ignored if an internal node links outside.** Any edge crossing the
    subgraph boundary forces the parent direction. To keep an internal `direction LR`, keep all of
    that subgraph's links internal, and link to/from the subgraph **container id** for external
    connections.
14. **Do not link to both a parent subgraph and its nested child.** It is a syntax error. Link to the
    nodes inside, never the subgraph id, when nesting.
15. **Every block needs its `end`.** `subgraph`, `alt`, `loop`, `opt`, `par`, `critical`, `rect`,
    `box` each require a matching `end`. Nested blocks are the usual culprits for a missing one.

## Per-type quick traps

16. **Class diagram:** relationships and `note` go OUTSIDE `namespace` blocks; nested namespaces are
    unsupported. Generic types with colons (`Map~String, Object~`) are fragile.
17. **Sequence diagram:** a literal semicolon is a line break; use `#59;` for a real semicolon. Async
    open arrow is `A-)B`; activation is `A->>+B` / `B-->>-A`.
18. **Mindmap:** `<` renders as `&lt;`; write "less than 10", not "< 10".
19. **architecture-beta:** node labels accept only `[a-zA-Z0-9_ ]`; hyphens break. Use underscores.

## Layout quality (reduce line crossings)

You cannot pixel-position anything. All layout control comes from declaration order, `rankDir`, and
subgraphs:

- **Declaration order sets rank.** Declare nodes in reading order (top-to-bottom or left-to-right);
  earlier declarations get the leading rank.
- **Minimize back-edges.** Every edge pointing back to an earlier node forces a crossing. For cycles,
  use a state diagram or isolate the back-edge in a subgraph.
- **Group related nodes adjacently in source.** Scattered declarations produce scattered placement.
- **Subgraphs constrain placement** and prevent global crossings.
- **Reduce fan-out.** A node with 5+ outgoing edges makes a spider web; insert a dispatcher node.
- **Flip orientation.** When crossings persist, try the orthogonal `rankDir` (`TD` <-> `LR`); this
  alone often clears most of them.
- **Spacing knobs (YAML frontmatter).** When nodes crowd or edges hug labels, set proven defaults
  under `config: flowchart:` (`nodeSpacing: 48`, `rankSpacing: 72`, `diagramPadding: 16`,
  `wrappingWidth: 160`; the last wraps long labels before the box grows).

Stop when: syntax validates, the structure communicates without crossed text, and the eye flows
cleanly through it.

## Pre-ship checklist

1. Special-char labels quoted.
2. No reserved word as a bare node id.
3. No node id starting with bare `o`/`x`.
4. `<br>` (not `\n`, not `<br/>`) for line breaks, in quoted labels.
5. `flowchart` not `graph`; `%%` for comments.
6. Underscored labels quoted (v11 markdown).
7. linkStyle hex not the last attribute.
8. `stroke-dasharray` commas escaped.
9. Subgraph directions internal-only; no parent+child links; every block has its `end`.
10. Validated via Mermaid Chart MCP (`valid: true`) before saving.

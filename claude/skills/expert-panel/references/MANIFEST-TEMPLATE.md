---
# Copy this file to <your-project>/.claude/expert-panel.md and edit.
# It tells /expert-panel WHO sits on the panel and WHAT they're grounded on.
# Delete every comment line before using if you want a clean file.

personas:
  # Prefer this project's OWN agent definitions - they are the real, opinionated
  # profiles for this codebase. `file` is relative to the project root, or ~/ for home.
  # `as` is an optional display label shown in the verdict.
  # Note: ~/ in persona file paths must be expanded to $HOME before reading.
  # The skill handles this expansion; do not hard-code the literal home path here.
  - file: .claude/agents/agent-one.md
    as: Domain Expert
  - file: .claude/agents/agent-two.md
    as: Lead Engineer
  # Mix in a generic principal-level persona only to cover a lens your fleet lacks:
  - file: ~/.claude/skills/expert-panel/references/product-owner.md
    as: Product Owner

grounding:
  # Files or directories the reviewers should know about. Relative to project root or ~/.
  - CLAUDE.md
  - lib/

# deep  = reviewers get Read/Grep/Glob and study the repo before voting (cites file:line, ~3-5x tokens)
# brief = reviewers see only the brief + the grounding files' contents (cheap, deterministic)
mode: brief
---

# Notes (optional, human-facing)

Anything the panel should keep in mind: what to weigh heavily, known constraints,
non-goals. This body is not parsed; it's context for whoever edits the manifest.

# Core Rules

The portable, employer-neutral core of the harness. Nothing here assumes a
particular machine, folder layout, or employer. Machine and
job specifics belong in the importing file's own "Work overlay" section, never
here.

## Exhaust the toolbox before claiming "can't"

Saying "I can't do that", "my hands are tied", or asking the user to do a step
manually is FORBIDDEN until you have run this checklist and can name what
failed:

- **Browser automation, if available** (a Playwright MCP server or equivalent):
  anything a human could do in a browser is attemptable. Portals with no API,
  form fills, file downloads and uploads, JS-rendered pages, checking how
  something actually renders. If it is doable by hand in a browser, the default
  is "I will try it", not "I can't". A login screen is not a blocker: drive the
  flow up to the login and hand the user only that step.
- **Bash plus curl** for anything with an HTTP surface.
- **The OS scripting layer** for local apps (AppleScript and `open` on macOS,
  `xdg-open` and DBus on Linux, PowerShell on Windows).
- **A subagent** when the main context lacks a tool or the reading is bulky.

"Blocked" may only be reported after a real attempt failed, and the report must
name the tool tried and the exact error.

## Memory authority

A loaded memory entry that records a corrected or settled fact (especially one
marked re-confirmed, SETTLED, or learned from a real-world miss) is
authoritative. Answer from it firmly. Never re-hedge it against generic
training-data knowledge ("the general rule is...", "this varies, verify"). If
evidence suggests the fact has changed, say so explicitly and verify, but the
loaded fact is the default, not the prior.

## Punctuation

**Never use the em dash character (Unicode U+2014, the long horizontal dash) in
any output or saved file.** Use commas, parentheses, colons, or regular hyphens
instead. This applies to all written deliverables (drafts, notes, code
comments) and to chat replies. The `block-em-dash.sh` hook rewrites it in file
writes when hooks are installed; this rule extends the same standard to chat,
where no hook can reach.

## Dispatch intent

Dispatch whatever is dispatchable, whenever it makes sense. The main session is
the conductor and its context is reserved for decisions, judgment, and
integration. Mechanical or self-contained work goes to subagents so the main
session stays clear. That a task is small or quick is not a reason to keep it
inline.

Triggers and mechanics: `DISPATCH.core.md`, which sits beside this file. Import
it from your top-level config with `@DISPATCH.core.md` if your `CLAUDE.md`
lives in the same directory, or with the full path to the installed copy
otherwise. It is deliberately not imported from here, so this file stays usable
on its own.

## graphify

`graphify` turns any input (code, docs, papers, images, video) into a
persistent knowledge graph. The skill lives at
`<claude-config-dir>/skills/graphify/SKILL.md` once installed. Trigger:
`/graphify`. When the user types `/graphify`, invoke the Skill tool with
`skill: "graphify"` before doing anything else.

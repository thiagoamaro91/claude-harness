# Produce-Heads - detail for phases 5-7

Read the section for the head Triage detected. Each head is a thin adapter over
the shared skeleton: it picks the candidate angles, the acceptance MUSTs, and
the critique lenses; the machinery itself (candidates.js, fresh verifier,
panel.js, formats) lives in `quality-gates.md` and is not repeated here.

The pattern to keep in mind: the Verify gate is the truth gate. It is the one
step you must not fake, and it is never run by whoever produced the artifact.

---

## Code

**Produce.** Isolate in a git worktree first (workspace policy: worktrees for 3+
file changes). Candidates apply at the SPEC level only (2: minimal-diff vs
clean-slate-redesign; judged before the TDD plan is written), never as parallel
full builds. Build with `test-driven-development`; when the plan has independent
tasks, fan them out in parallel worktree waves via `workflows/build-sdd.js`
(fresh implementer + reviewer per task; merge order, full-suite run, and the
whole-branch review stay with the controller). When you hit an unknown API
mid-build, do a scoped `context7`/web lookup instead of guessing. Use
`systematic-debugging` on any failure rather than patching symptoms; the
watchdog ladder applies from the second identical failure.

**Verify gate.** The fresh verifier executes `acceptance.md`, which for code
always includes **a real end-to-end run on real or seeded data** with output
pasted. Green unit tests are necessary, not sufficient: they miss integration
gaps, key-contract mismatches, and one-of-N escapes. Then
`verification-before-completion` before any success claim.

**Critique room.** `requesting-code-review`, then `/code-review` and
`gemini-review` in parallel (those two ARE code's diverse lenses for the diff;
the panel.js pass belongs to the spec, pre-Checkpoint 1, for risky designs).
Note: `gemini-review` exits non-zero if the repo has no `.gemini-review/`
config; treat that as skip, not failure. `web-verifier` on any fact the code
now hardcodes (a rate, a limit, a deadline). Triage feedback with
`receiving-code-review` - verify suggestions, don't perform agreement. Fix
criticals before ship.

**Ship.** `finishing-a-development-branch` → PR / merge per the project's flow.

---

## Decision

For consequential choices: vendor selection, build-vs-buy, migration timing, or
contract terms. This is the highest-stakes head - the
dollar figures dwarf any code bug, so the grounding has to be real.

**Produce.** Three candidate memos via `candidates.js` (angles:
downside-minimizer / upside-maximizer / status-quo-challenger), each framing
the live options with the key facts and where each came from. Anchor any
dispute in the governing document's own clauses (cite by article/section), and
treat a named authority's written answer as authoritative over generic rules,
and verify before stating a statutory rule. The judged winner
becomes the working memo.

**Verify gate.** The fresh verifier checks: every load-bearing fact carries a
verified source (recon `escalate` list empty or explicitly waived), and the memo
lands on **ONE clear recommendation with rationale.** No "it depends." If the
facts genuinely fork the recommendation, name the single variable that decides
it and recommend per its likely value. Prefer recent, primary sources (e.g. regulator
rulings over blog summaries).

**Critique room.** `panel.js` with lenses: fact-freshness / downside-exposure /
missed-option / stupid-in-12-months. Fix criticals, re-run until clean
(fallback: `expert-panel` with the same lenses as a manifest).

**Ship.** Record the decision and its rationale to memory (correct any wrong
prior memory you found) and to your context notes. This is a decision
*recorded*, not an action taken - if the decision implies an outward action
(send, sign, pay), that's a separate confirmed step, never automatic.

---

## Document

For SOWs, decks, CVs, cover emails, formal/admin letters, pricing playbooks,
reports.

**Produce.** Three candidates via `candidates.js` (angles: point-first /
narrative-hook / data-led), all in one consistent style: **lead with the one point +
the concrete ask up front in plain conversational language**; heavy
legal/technical scaffolding goes in an appendix, never the body. No em dash.
For admin/legal correspondence, anchor in the governing contract's clauses. In a
multilingual exchange, match the language the counterpart uses. Use the
right generator skill for the format: `docx` for Word, `pptx` for decks, `pdf`
for PDFs, plain markdown otherwise. (Trivial or rigidly-formatted output may
skip candidates - announced at Checkpoint 1, never silently.)

**Verify gate.** The fresh verifier checks acceptance.md, which always includes:
leads with point + ask, and every external fact/figure/clause verified
(`web-verifier` the facts; cross-check clause citations against the actual
contract). A deliverable that opens with throat-clearing or cites an unverified
number fails the gate.

**Critique room.** `panel.js` with lenses: claim-support / clarity-of-the-ask /
voice-and-style. Fix criticals before ship.

**Ship - DRAFT only. Never send or publish.** Save the artifact, surface the path
at Checkpoint 2, and tell the user it is ready for their review and send. Leave
email as an unsent draft. This is a hard rule, not a default.

---

## Strategy

For "what should we build/do next", roadmap calls, positioning, competitor
response, outreach sequencing.

**Produce.** Ground first: `deep-research` (built-in skill) on competitors,
market, and prior art so the thinking sits on real signals, not vibes. Then
three candidate directions via `candidates.js` (angles: one-focused-bet /
portfolio-of-cheap-tests / contrarian-take). Challenge the premise before the
plan (validate the pain is real and impacting before designing for it).

**Verify gate.** The fresh verifier checks: grounded in real competitor/market
data AND a falsifiable next step is named. A strategy with no cheap test that
could prove it wrong is a vibe, not a strategy. Name the smallest experiment
that would validate or kill it.

**Critique room.** `panel.js` with lenses: premise-validity / sequencing-risk /
cheapest-falsifier. For a first-venture lens, challenge enterprise-sales framing
where it doesn't fit a founder-stage reality. (Fallback: `expert-panel` with an
appropriate manifest.)

**Ship.** A prioritized direction with the next concrete action, recorded to the
relevant context notes and memory. Not an action taken - the next step is for
the user to greenlight or for a follow-up `/autonomous` run to execute.

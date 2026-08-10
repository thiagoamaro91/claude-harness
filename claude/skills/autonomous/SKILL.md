---
name: autonomous
description: >-
  Drive a task end to end autonomously with research grounding and adversarial
  review, across code OR decisions OR documents OR strategy. Use whenever the
  user says "/autonomous", "run this autonomously", "do this autonomously", "take
  this to done", "drive this to done", "run with this", "handle this end to
  end", "just build/decide/draft this and surface when done", or otherwise hands
  off a whole task to run heads-down. Trigger even when they describe the intent
  loosely ("can you just take care of this whole thing", "go do X and ping me
  when it's ready") rather than naming the skill. Covers far more than code: a
  high-stakes decision (which vendor, which architecture, whether to migrate), a
  deliverable (SOW, deck, CV, email, playbook), or a strategy call (what to
  build next) all run through the same engine. Do NOT trigger for a quick
  one-shot answer the user wants inline right now, or when they explicitly want
  to stay in the loop at every step.
---

# Autonomous Delivery Engine

One research-grounded loop, four produce-heads, adversarial verification at both
ends. You drive it heads-down and surface at exactly two checkpoints.

## Why this exists

Autonomous work fails two symmetric ways: you build confidently on wrong or
stale facts (garbage in), or you ship confidently-wrong output (garbage out). A
wrong pricing assumption and a wrong API signature are the same bug class at
different altitudes. So this engine bookends one delivery loop with the same
adversarial-verification discipline at both ends: **research verifies the
inputs, critique verifies the outputs.** Code is just one head; the skeleton is
identical for a decision, a document, or a strategy call.

Two more laws, learned the expensive way:
- **Spend parallel compute at produce time, not only at review time.** N
  attempts judged beats one attempt critiqued.
- **The builder never grades its own work.** Verification runs in a fresh
  context or it is theater.

## The autonomy contract (read first)

Bypass mode is on, so run end to end without asking permission at every phase.
That is trust, not a blank cheque:

- **Self-confirm before irreversible or outward-facing actions** even under
  bypass: sending email, force-push, deleting things you did not create, posting
  publicly, anything covered by a confidentiality obligation. Bypass changes the
  harness, not your judgment.
- **Non-code heads stop at a draft or recommendation for review. They never
  auto-send or auto-publish.** Drive all the way to the artifact, then stop at
  the doorstep.
- The global PreToolUse hooks (e.g. the destructive-command guard) are the
  real safety net and still fire. Don't fight them; if one blocks you, that's
  the signal to stop and surface.

## Start every run by laying down the rails

The phases below are not a suggestion you hold in your head for 40 messages.
**Create one TodoWrite item per phase you'll actually run** (skip phases a head
doesn't use, e.g. Isolate for non-code). Then announce in one line: the detected
head, whether research fires, how many produce candidates, marathon on or off,
and the acceptance gate you're driving toward.

## Shared skeleton

```
0 Triage      head + knowns-vs-unknowns + marathon call; prior memory / project KB FIRST
1 Recon       lean-by-default research (gated); refuter on load-bearing facts; brief cached
2 Frame       brainstorming, seeded by the brief
3 Plan        head-specific plan + acceptance.md + pre-mortem
              ── CHECKPOINT 1: plan + top risks; veto semantics below ──
4 Isolate     git worktree (code only)
5 Produce     multi-candidate engine (candidates.js) or head engine
6 Verify      acceptance.md executed by a FRESH verifier, never the builder
7 Critique    diverse-lens panel (panel.js) → fix criticals → re-run
8 Ship        code: PR/merge · others: draft/recommendation for review
9 Persist     context save + runs-ledger record + findings to research/ and memory
              ── CHECKPOINT 2: done / blocked ──
```

Steps 0-4 and 8-9 are the same for every head. Only 5-7 vary. Per-head detail
for 5-7 lives in `references/produce-heads.md`; the shared quality machinery
(acceptance format, fresh verifier, candidate angles, critique lenses,
pre-mortem) lives in `references/quality-gates.md`. Read both once you know the
head.

## Phase 0a - Ledger check (ALWAYS first, before Triage)

If the invocation carries `--resume-state <path>`, this is a **marathon
iteration**: skip the normal spine, follow the iteration contract in
`references/marathon.md` (one increment, update state, end), and ignore the
rest of this section.

Otherwise read `.superpowers/sdd/ledger.json` in the project (or the workspace
root for non-code heads). Shape:

    { "version": 1, "runs": [ { "phase", "runId", "resultPath", "artifactHash", "scriptHash", "ts" } ] }

For each phase about to run: if a `runs` entry exists for it, the phase already
ran. Verify the file at `resultPath` exists and its content hash equals
`artifactHash`; if so, re-load that payload and SKIP re-running the phase. If the
artifact is missing or the hash differs (a sync conflict copy or partial write), or
the current template's content hash differs from `scriptHash` (the template was
edited since), invalidate that entry and re-run the phase. If no ledger exists,
start fresh.

## Phase 0 - Triage

**Detect the head** from cwd + task verbs (override with `--type`):

- cwd in a code repo (e.g. `projects/`), or verbs build/fix/refactor/implement/debug → **code**
- "should I / which / X vs Y / is it worth / decide" → **decision**
- "draft / write / email / SOW / deck / CV / post / letter / playbook" → **document**
- "what to build/do next / roadmap / competitor / positioning / strategy" → **strategy**
- genuinely ambiguous on consequential work → ask once, don't guess.

**Classify unknowns.** A task is *knowns-only* (skip research) when it's a
bugfix/refactor in familiar code, or a deliverable where every fact is already
in hand. It *has unknowns* when it touches a new library/API, a version
migration, an open "best way" question, or any external constant (rate, date,
price, limit, clause) that would be wrong if you guessed. Mark each unknown
`loadBearing: true` when the plan or recommendation flips if it's wrong.

**Call marathon or not.** Estimated wall-clock over ~90 minutes, overnight or
a handoff to another machine, or `--marathon` passed → arm the outer loop
(`references/marathon.md`) at the end of Plan.

**Always check what's already known first:** search prior-session memory if you
have it, and read the project KB / `research/` docs and whatever context notes
this environment keeps. Re-researching something already verified is waste and
risks contradicting a hard-won correction.

## Phase 1 - Recon (only if unknowns, or `--deep`)

Lean by default. After Triage classifies the unknowns, choose the executor:

- **2+ unknowns -> the Workflow tool.** Call
  `Workflow({ scriptPath: "__CLAUDE_HOME__/skills/autonomous/references/workflows/recon.js",
  args: { projectRoot, unknowns: [ { id, question, type, loadBearing } ] } })`
  (absolute path; tilde expansion by the Workflow tool is unverified).
  `type` is `fact` (web-verifier), `library` (context7), or `approach`
  (deep-research). This is the authorized opt-in: for Recon you ARE expected to
  call the Workflow tool. Models are pinned inside the template (fact→haiku,
  library/approach→sonnet); load-bearing unknowns get an independent refuter,
  and anything contested or low-confidence comes back in `escalate`.
- **1 unknown -> inline.** Resolve it with the single matching verifier and
  assemble the SAME envelope by hand:
  `{ ok: true, brief: [ { id, question, finding, source: { type, ref }, confidence } ], unresolved: [], escalate: [] }`.
- Log which executor ran: `[autonomous] recon executor=workflow reason=N-unknowns`
  or `[autonomous] recon executor=inline reason=1-unknown`.

Either way you now hold one envelope. Write `brief` to the project's `research/`
or KB dir; corrected facts -> memory; workstream state -> your context notes. For
each id in `escalate` or `unresolved`, decide: re-run just that unknown with
`--deep`, proceed naming the gap, or stop. A contested load-bearing fact is
never silently treated as settled. The brief feeds Frame and Plan, so the plan
cites verified facts instead of memory. `--no-research` skips this phase
entirely.

## Phases 2-3 - Frame and Plan

Frame with the `brainstorming` skill, seeded by the brief. Then build the
head-specific plan (see references): a `writing-plans` plan for code, an
option-set for a decision, an outline for a document or strategy.

**The plan is not done until `acceptance.md` exists** (format and standing
MUSTs: `references/quality-gates.md`). Every MUST carries a CHECK an outsider
could execute. This file is what the Verify gate runs; writing it after
producing is writing the exam after the answers.

**Pre-mortem before presenting:** one cheap agent writes the three-months-later
incident report; fold cheap mitigations in, attach the top 3 risks to the
checkpoint message. For risky or expensive designs, also pressure-test with
`expert-panel` before the checkpoint.

**CHECKPOINT 1.** Surface plan + acceptance + risks (semantics in Checkpoints
below), then go heads-down. If marathon is armed, write the state file now
(GOAL, ACCEPTANCE mirrored from acceptance.md, first NEXT STEP) and either
iterate in-session or hand off to the driver.

## Phases 4-8 - Isolate, Produce, Verify, Critique, Ship

Read `references/produce-heads.md` for your head's detail and
`references/quality-gates.md` for the shared machinery. Non-negotiables:

- **Produce runs multi-candidate by default** (document/decision/strategy 3,
  code at spec level 2, `--candidates N` / `--ultra` override; skip only for
  trivial output and say so at Checkpoint 1). Producers and judge run via
  `references/workflows/candidates.js`.
- **The Verify gate is `acceptance.md` executed by a fresh verifier** with no
  build context. The builder never self-certifies. Do not advance to Critique
  until the verifier's evidence says the gate is met.
- **Critique is a diverse-lens panel** (`references/workflows/panel.js`, or
  `expert-panel` fallback): one refuter per lens, adjudicated; fix criticals and
  re-run until `merged.criticals` is empty AND `merged.survives` is true.
  Exception: the CODE diff's lens set is `/code-review` + `gemini-review` (see
  produce-heads.md); panel.js serves the code head at the SPEC stage instead.
- For code, isolate in a worktree first (workspace worktree policy for 3+ file
  changes).

**Code head = the gated walk (default).** The canonical, detailed procedure for
code is: brainstorm -> spec ->
adversarial-verify expert panel -> TDD plan -> subagent-driven build (fresh
implementer + reviewer per task) -> Opus whole-branch review -> `/code-review`
xhigh -> human gate. **Independent plan tasks build in parallel worktree
waves** via `references/workflows/build-sdd.js` (fan-out only; merge order,
full-suite run, and the whole-branch review stay with the controller). Run the
verification-heavy phases as BACKGROUND workflows: it keeps controller context
lean and survives compaction. Keep durable state on disk. Default envelope for
code: ONE human gate, at Ship (merge + deploy); Checkpoint 1 is optional under
this default. Log each gate as you pass it. Sonnet executors,
Opus for the whole-branch review and the controller's adjudication.

## Marathon mode (long runs)

Armed at Triage, set up at Plan: persistent state file + fresh-context
iterations, driver-run or in-session. Contract, template, and driver usage:
`references/marathon.md`. The two facts that matter here: the state file is the
only memory (an unrecorded increment does not exist), and `STATUS: done`
requires the fresh verifier's pass first.

Durable-store precedence on any resume (they answer different questions and
never override each other upward): `state.md` (task truth) > `ledger.json`
(phase cache) > any narrative progress notes (lowest). When
marathon is armed, `acceptance.md` lives in the same `marathon-<slug>` folder
as the state file.

## Watchdog (all modes, not just marathon)

Stuck is a signal, not a mood: same test failing 3 attempts, same error
signature twice, or a phase 2x over its budget. Climb the ladder in
`references/marathon.md`: systematic-debugging once → write off the approach in
GOTCHAS and attack differently → surface blocked at Checkpoint 2. The third
identical retry is forbidden.

## Budgets and effort

Guideline, not straitjacket; log actuals in the runs ledger. Fan-out work never
inherits the session tier (templates pin their own models).

| Stage | Tier | Note |
|-------|------|------|
| Recon verifiers | haiku/sonnet, low-med | pinned in recon.js (fact haiku/low; library sonnet/low; approach + refuter sonnet/medium) |
| Producers / implementers | sonnet, medium | candidates.js, build-sdd.js |
| Judge / adjudicator / whole-branch review | opus, high | quality moments |
| Controller adjudication | session tier | you |

`--ultra` = deliberate max-quality: 5 candidates, extra lenses, judge on the
highest tier the dispatch guard allows, budgets roughly doubled; announce the
cost choice at Checkpoint 1.
Marathon caps: `--max-iter` 12, `--stall-limit` 2 by default.

## Phase 9 - Persist

Run whatever context-save routine this environment has (the public warmstart
plugin ships one) to update context. Write durable research findings to the
project KB / `research/`, correct any wrong memory you found, and record
decisions (decision head) to memory + context.

**Append one run record** to the runs ledger via the validating helper, never by
hand-writing JSONL:
`python3 "__CLAUDE_HOME__/skills/autonomous/references/ledger/append.py" '<record-json>'`
(ledger path defaults to `__CLAUDE_HOME__/autonomous/runs-ledger.jsonl`; override
with `AUTONOMOUS_LEDGER` or `--ledger`)
(strict: unknown fields, missing fields, and bad enums are rejected, exit 2).
The record schema is: `ts,
head, task, mode, candidates, iterations, stalls, retries, criticals_found,
criticals_fixed, acceptance, wall_min, outcome, notes`. This is the data that
earns more autonomy and feeds skill-tuner; a run that isn't logged can't
improve the engine, and a record without `ts`+`task` can't be queried.

### Resume ledger (controller-managed)

After each Workflow phase returns, the controller (not the template) persists:
1. Write the phase payload to `resultPath` (e.g. `.superpowers/sdd/recon.json`).
2. Compute the artifact content hash and the template's content hash.
3. Append `{ phase, runId, resultPath, artifactHash, scriptHash, ts }` to
   `ledger.json` (`ts` stamped by the controller; templates cannot read the clock).

On resume, re-load `resultPath` and continue from the seam AFTER that phase. Do
not replay earlier phases. To resume a phase that did not finish, call
`Workflow({ scriptPath, resumeFromRunId: <runId> })`.

## Checkpoints (exactly two)

1. **Plan ready.** Stakes decide the semantics:
   - *Low-stakes* (reversible, no human-reserved category touched): send the
     checkpoint and **proceed immediately**; the veto is retroactive and the
     user can redirect mid-run. Never idle waiting for a reply.
   - *High-stakes* (outbound comms, money, anything contractual, anything
     touching client or confidential data, or `--gate` passed): **block.** Ask
     via AskUserQuestion in-session; if the user is away, park the run resumable
     (state file + exact resume command in the checkpoint message) and end the
     turn.
2. **Done or blocked.** What shipped, the verifier's evidence, artifact paths,
   cost actuals vs. budget; or the blocker and the crisp ask.

Each checkpoint fires an in-session message AND, if one is configured, a
**best-effort out-of-band** notification. CONFIGURE ME: set `HARNESS_NOTIFY_CMD`
to a command taking `--title "<title>" "<body>"` (a chat webhook poster, `mail`,
anything). If it is unset or fails, in-session only. Never block the run on
notification delivery.

Do not add a third checkpoint. The whole point is heads-down between these two.
If you feel the urge to check in mid-build, that's usually a sign the plan was
underspecified - fix the plan next time, don't add interrupts.

## Flags

- `--type code|decision|document|strategy` - force the head
- `--deep` - force full deep-research in recon
- `--no-research` - skip recon (knowns-only, max speed)
- `--candidates N` - produce fan-out (0 or 1 disables the judge round)
- `--ultra` - max-quality envelope (5 candidates, extra lenses, top-tier judge)
- `--marathon` - arm the fresh-context outer loop at Plan
- `--resume-state <path>` - marathon iteration: one increment per the contract
- `--gate` - force Checkpoint 1 to block even for low-stakes work

## Red flags (stop and correct)

| Thought | Reality |
|---------|---------|
| "I'll just build on what I remember" | If it's an external fact, verify it. That's the front bookend. |
| "Tests pass, I'm done" (code) | The gate is acceptance.md run by a fresh verifier, not green units. |
| "I built it, I know it passes" | The builder never grades. Fresh context or it's theater. |
| "It's obviously the right call" (decision) | Verify each option's facts before recommending. No "it depends". |
| "I'll send the email to save a step" | Non-code ships as a draft. Never auto-send. |
| "One more retry will crack it" | Third identical attempt = wedged. Climb the watchdog ladder. |
| "Candidates are overkill here" | Maybe, but skipping is announced at Checkpoint 1, not decided silently. |
| "The state file can wait" | An unrecorded increment doesn't exist. Update before ending the iteration. |
| "Let me check in real quick" | Two checkpoints only. Underspecified plan, not a new interrupt. |
| "Research first, always" | Triage gates it. Knowns-only tasks skip recon. |

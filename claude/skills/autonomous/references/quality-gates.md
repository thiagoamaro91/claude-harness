# Quality Gates - acceptance, fresh verifier, candidates, lenses, pre-mortem

## Acceptance checklist (required Plan output)

The Plan phase is not finished until `acceptance.md` exists next to the run's
state (`.superpowers/sdd/<run-or-marathon-slug>/acceptance.md`):

```
# Acceptance: <task>
- [ ] MUST <criterion> (CHECK: <exact command + expected signal, or observable evidence>)
- [ ] SHOULD <criterion> (CHECK: ...)
```

Every MUST carries a CHECK an outsider could execute without conversation
context. "Works" is not a criterion; name the observable. Standing MUSTs:
code always includes a real end-to-end run on realistic input (green units are
not the gate); documents always include "leads with point + ask" and "every
external figure/clause verified"; decisions always include "ONE recommendation,
every load-bearing fact verified".

## Fresh verifier (who executes the Verify gate)

The builder never grades its own work; sunk cost reads evidence generously.
Dispatch a clean subagent with NO build context, briefed with only: artifact
paths, the full acceptance.md content, cwd, and the instruction to execute
every CHECK and paste real output or evidence per item, then verdict pass/fail
per item plus overall. Any MUST fails: controller fixes, then a NEW fresh
verifier re-runs (the old one is contaminated by its own findings). Model:
sonnet when the CHECKs are mechanical, opus when judgment dominates. In
marathon mode this verifier runs before `STATUS: done` is allowed.

## Multi-candidate produce (workflows/candidates.js)

One attempt critiqued is weaker than N attempts judged. Defaults: 3 candidates
for document/decision/strategy; 2 for code at the DESIGN/spec level only (never
parallel full builds of the same change); `--candidates N` overrides; `--ultra`
means 5. Skip only for trivial or rigidly-formatted output (a config tweak, a
form email), and say so at Checkpoint 1.

Angle menus (pick per task, invent better ones freely):
- document: point-first / narrative-hook / data-led
- decision: downside-minimizer / upside-maximizer / status-quo-challenger
- strategy: one-focused-bet / portfolio-of-cheap-tests / contrarian-take
- code spec: minimal-diff / clean-slate-redesign

Call: `Workflow({ scriptPath: "__CLAUDE_HOME__/skills/autonomous/references/workflows/candidates.js",
args: { briefing, angles, rubric } })` (absolute path; tilde expansion by the
Workflow tool is unverified). The briefing must be a fully
self-contained produce briefing (objective, pasted context, output contract);
producers and judge see nothing else. Rubric: 3-5 criteria drawn from the
acceptance MUSTs plus style conventions. The judge is blind to angles; synthesis
merges its grafts into the winner. Workflow unavailable: two inline Agent
producers and judge in-controller, or single-candidate with the compromise
named in the ship message.

## Diverse-lens critique (workflows/panel.js)

Identical reviewers converge on identical misses; the critique room is N
refuters with one distinct lens each, then an adjudicator merges. Lens menus:
- code, SPEC stage only (the diff's lenses are `/code-review` + `gemini-review`,
  per produce-heads.md): correctness-on-real-data / security-and-edge-cases / spec-compliance
- decision: fact-freshness / downside-exposure / missed-option / stupid-in-12-months
- document: claim-support / clarity-of-the-ask / voice-and-style
- strategy: premise-validity / sequencing-risk / cheapest-falsifier

Call: `Workflow({ scriptPath: "__CLAUDE_HOME__/skills/autonomous/references/workflows/panel.js",
args: { artifact, context, lenses } })`. The gate to Ship: `merged.criticals`
empty AND `merged.survives` true (fix, then re-run the panel). An adjudicator
failure fails closed: criticals pass through un-deduped and `survives` is
false, so the gate cannot pass vacuously. Fallback when Workflow is
unavailable: the `expert-panel` skill with a per-head manifest built from the
same lens list.

## Pre-mortem (rides with Checkpoint 1)

One sonnet/medium agent, before presenting the plan: "It is three months after
this shipped and it failed. Write the incident report: what broke and which
plan assumption caused it." Fold cheap mitigations into the plan; attach the
top 3 risks to the Checkpoint 1 message so the veto is informed, not
ceremonial.

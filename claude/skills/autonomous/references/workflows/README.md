# Workflow templates for /autonomous

Templates are run by the Claude Code Workflow tool. They cannot be unit-tested
in CI; the test story is a Node shim run before each deploy. All templates pin
their own models: fan-out work never inherits the session tier.

| Template | Phase | Does |
|----------|-------|------|
| `recon.js` | Recon | One verifier per unknown (typed fact/library/approach, tier-pinned); independent refuter on `loadBearing` unknowns; returns `{brief, unresolved, escalate}` |
| `candidates.js` | Produce | N blind producers from distinct angles, blind judge with rubric, optional graft synthesis; returns `{candidates, judgment, final}` |
| `panel.js` | Critique | One adversarial refuter per lens, adjudicator merges/dedups; returns `{byLens, lensesFailed, merged}` |
| `build-sdd.js` | Build (code) | Wave-parallel worktree implementers (Kahn batching over task deps), fresh reviewer per task, one fix round + re-review; integration stays with the controller |

`panel.js` implements the refute/adjudicate critique contract: one adversarial
refuter per lens, then an adjudicator that merges and dedups the findings.

## Run the template tests

    cd ~/.claude/skills/autonomous/references/workflows
    node _shim.test.mjs
    for t in *.test.mjs; do node "$t" || echo "FAIL $t"; done

Every line must print PASS. The shim (`_shim.mjs`) injects mock
`agent`/`parallel` hooks and executes a template's body the way the Workflow
tool does (body wrapped in an async function, `return` is the result).

## Contract reminder (see the spec)

- Every template returns `{ ok, error?, ...payload }`.
- Args must be self-contained briefings (subagents see zero session context).
- Outputs are schema-validated via `agent({ schema })`.
- Failed agents degrade, never crash the run: recon -> `unresolved`,
  candidates -> fewer candidates, panel -> `lensesFailed`, build-sdd ->
  `failed[]` with dependents skipped as `dep-failed`.
- No filesystem, no Date.now/Math.random/new Date in templates.

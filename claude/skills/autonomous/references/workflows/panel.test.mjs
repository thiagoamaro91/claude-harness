// panel.test.mjs
import assert from 'node:assert'
import { runTemplate } from './_shim.mjs'

const PATH = new URL('./panel.js', import.meta.url).pathname
const baseArgs = {
  artifact: 'DRAFT: we should adopt Postgres over MongoDB because the data is relational.',
  context: 'Design memo recommending a database choice.',
  lenses: [
    { id: 'facts', instruction: 'Attack every external fact and figure.' },
    { id: 'downside', instruction: 'Attack the worst-case exposure.' },
    { id: 'stale-in-12mo', instruction: 'What makes this look stupid in 12 months?' },
  ],
}

// Happy path: one refuter per lens, findings merged by adjudicator.
{
  const calls = []
  const agent = async (prompt, opts) => {
    calls.push(opts.label)
    if (opts.label.startsWith('refute:')) {
      const lens = baseArgs.lenses.find((l) => `refute:${l.id}` === opts.label)
      assert.ok(prompt.includes(baseArgs.artifact), 'refuter sees the artifact')
      assert.ok(prompt.includes(lens.instruction), 'refuter gets its own lens')
      assert.deepEqual({ model: opts.model, effort: opts.effort }, { model: 'sonnet', effort: 'medium' })
      if (opts.label === 'refute:facts') {
        return { findings: [{ claim: 'relational-fit assumption unverified', severity: 'critical', rationale: 'no source' }], verdict: 'refuted' }
      }
      return { findings: [{ claim: 'minor style', severity: 'minor', rationale: 'nit' }], verdict: 'holds' }
    }
    if (opts.label === 'adjudicate') {
      assert.deepEqual({ model: opts.model, effort: opts.effort }, { model: 'opus', effort: 'high' })
      assert.ok(prompt.includes('relational-fit assumption unverified'), 'adjudicator sees all findings')
      return { criticals: ['relational-fit assumption unverified'], majors: [], minors: ['minor style'], survives: false, notes: '1 of 3 lenses refuted on facts' }
    }
    throw new Error(`unexpected ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, true)
  assert.equal(out.byLens.length, 3)
  assert.equal(out.byLens.find((b) => b.lens === 'facts').verdict, 'refuted')
  assert.deepEqual(out.merged.criticals, ['relational-fit assumption unverified'])
  assert.equal(out.merged.survives, false)
  assert.equal(calls.filter((l) => l.startsWith('refute:')).length, 3)
  console.log('panel.test happy-path PASS')
}

// No findings anywhere: adjudicator is skipped, artifact survives.
{
  const agent = async (_p, opts) => {
    if (opts.label.startsWith('refute:')) return { findings: [], verdict: 'holds' }
    throw new Error(`adjudicator must not run, got ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, true)
  assert.equal(out.merged.survives, true)
  assert.deepEqual(out.merged.criticals, [])
  console.log('panel.test clean-artifact PASS')
}

// One refuter dies: panel proceeds on the survivors and says which lens is missing.
{
  const agent = async (_p, opts) => {
    if (opts.label === 'refute:downside') throw new Error('boom')
    if (opts.label.startsWith('refute:')) return { findings: [{ claim: 'x', severity: 'major', rationale: 'y' }], verdict: 'holds' }
    if (opts.label === 'adjudicate') return { criticals: [], majors: ['x'], minors: [], survives: true, notes: '' }
    throw new Error(`unexpected ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, true)
  assert.equal(out.byLens.length, 2)
  assert.deepEqual(out.lensesFailed, ['downside'])
  console.log('panel.test refuter-failure PASS')
}

// Every refuter dies: ok:false so the controller falls back to expert-panel.
{
  const agent = async () => { throw new Error('all dead') }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, false)
  console.log('panel.test all-dead PASS')
}

// Adjudicator dies: fail CLOSED. Criticals stay criticals (the ship gate reads
// that array), survives=false, nothing silently demoted.
{
  const agent = async (_p, opts) => {
    if (opts.label === 'refute:facts') return { findings: [{ claim: 'fatal fact', severity: 'critical', rationale: 'r' }], verdict: 'refuted' }
    if (opts.label.startsWith('refute:')) return { findings: [{ claim: 'style nit', severity: 'minor', rationale: 'n' }], verdict: 'holds' }
    if (opts.label === 'adjudicate') return null
    throw new Error(`unexpected ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, true)
  assert.deepEqual(out.merged.criticals, ['[facts] fatal fact'])
  assert.equal(out.merged.survives, false)
  console.log('panel.test adjudicator-dead-fails-closed PASS')
}

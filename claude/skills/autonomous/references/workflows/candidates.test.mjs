// candidates.test.mjs
import assert from 'node:assert'
import { runTemplate } from './_shim.mjs'

const PATH = new URL('./candidates.js', import.meta.url).pathname
const baseArgs = {
  briefing: 'OBJECTIVE: draft the kickoff email. CONTEXT: pasted. OUTPUT CONTRACT: markdown email body.',
  angles: [
    { id: 'point-first', instruction: 'Lead with the single point and the concrete ask.' },
    { id: 'narrative', instruction: 'Open with the project background, then the ask.' },
    { id: 'data-led', instruction: 'Open with the one number that matters.' },
  ],
  rubric: ['clarity of the ask', 'voice match', 'evidence quality'],
}

// Happy path: N blind producers -> blind judge -> synthesis.
{
  const calls = []
  const agent = async (prompt, opts) => {
    calls.push({ prompt, opts })
    if (opts.label.startsWith('produce:')) {
      assert.ok(prompt.includes(baseArgs.briefing), 'producer gets the full briefing')
      assert.deepEqual({ model: opts.model, effort: opts.effort }, { model: 'sonnet', effort: 'medium' })
      return { artifact: `draft-by-${opts.label.split(':').pop()}` }
    }
    if (opts.label === 'judge') {
      assert.deepEqual({ model: opts.model, effort: opts.effort }, { model: 'opus', effort: 'high' })
      assert.ok(prompt.includes('draft-by-point-first') && prompt.includes('draft-by-data-led'), 'judge sees all artifacts')
      assert.ok(!prompt.includes('Lead with the single point'), 'judge is blind to angle instructions')
      assert.ok(prompt.includes('clarity of the ask'), 'judge gets the rubric')
      return {
        scores: [
          { candidate: 1, total: 6, notes: 'ok' },
          { candidate: 2, total: 8, notes: 'best' },
          { candidate: 3, total: 5, notes: 'meh' },
        ],
        winner: 2,
        grafts: ['steal the subject line from candidate 1'],
      }
    }
    if (opts.label === 'synthesize') {
      assert.ok(prompt.includes('draft-by-narrative'), 'synthesis starts from the winner')
      assert.ok(prompt.includes('steal the subject line'), 'synthesis applies grafts')
      return { artifact: 'final-merged' }
    }
    throw new Error(`unexpected label ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, true)
  assert.equal(out.candidates.length, 3)
  assert.equal(out.judgment.winner, 2)
  assert.equal(out.final, 'final-merged')
  assert.equal(calls.filter((c) => c.opts.label.startsWith('produce:')).length, 3)
  console.log('candidates.test happy-path PASS')
}

// One producer dies -> judge picks among survivors; candidate numbering stays aligned.
{
  const agent = async (prompt, opts) => {
    if (opts.label === 'produce:narrative') throw new Error('boom')
    if (opts.label.startsWith('produce:')) return { artifact: `draft-by-${opts.label.split(':').pop()}` }
    if (opts.label === 'judge') {
      assert.ok(!prompt.includes('draft-by-narrative'))
      return { scores: [{ candidate: 1, total: 5, notes: '' }, { candidate: 2, total: 7, notes: '' }], winner: 2, grafts: [] }
    }
    // zero grafts -> synthesis would be a paid no-op; winner returns verbatim
    throw new Error(`unexpected ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, true)
  assert.equal(out.candidates.length, 2)
  assert.equal(out.final, 'draft-by-data-led', 'winner index maps to surviving candidate list, verbatim when no grafts')
  console.log('candidates.test producer-failure PASS')
}

// Single survivor: no judge, no synthesis, survivor is final.
{
  const agent = async (_p, opts) => {
    if (opts.label === 'produce:point-first') return { artifact: 'only-one' }
    if (opts.label.startsWith('produce:')) throw new Error('boom')
    throw new Error(`no judge/synth expected, got ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, true)
  assert.equal(out.final, 'only-one')
  assert.equal(out.judgment, null)
  console.log('candidates.test single-survivor PASS')
}

// Zero survivors: ok:false so the controller falls back to producing inline.
{
  const agent = async () => { throw new Error('all dead') }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, false)
  console.log('candidates.test zero-survivors PASS')
}

// synthesize:false returns the winner verbatim and never calls a synth agent.
{
  const agent = async (_p, opts) => {
    if (opts.label.startsWith('produce:')) return { artifact: `draft-by-${opts.label.split(':').pop()}` }
    if (opts.label === 'judge') return { scores: [{ candidate: 1, total: 9, notes: '' }, { candidate: 2, total: 2, notes: '' }, { candidate: 3, total: 1, notes: '' }], winner: 1, grafts: ['g'] }
    throw new Error(`synth must not run, got ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: { ...baseArgs, synthesize: false }, agent })
  assert.equal(out.final, 'draft-by-point-first')
  assert.deepEqual(out.judgment.grafts, ['g'])
  console.log('candidates.test no-synthesis PASS')
}

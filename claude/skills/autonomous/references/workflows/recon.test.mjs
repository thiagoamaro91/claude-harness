// recon.test.mjs
import assert from 'node:assert'
import { runTemplate } from './_shim.mjs'

// Happy path + model/effort pins per unknown type (the template itself must
// pin, or verifiers inherit the session model).
{
  const args = {
    projectRoot: '/tmp',
    unknowns: [
      { id: 'u1', question: 'Postgres default port', type: 'fact' },
      { id: 'u2', question: 'context7 reachable?', type: 'library' },
      { id: 'u3', question: 'best resume approach', type: 'approach' },
    ],
  }
  const canned = {
    u1: { finding: '5432', source: { type: 'web', ref: 'https://x' }, confidence: 'high' },
    u2: { finding: 'yes', source: { type: 'tool', ref: 'context7' }, confidence: 'med' },
    u3: { finding: 'runId', source: { type: 'inference', ref: 'reasoning' }, confidence: 'high' },
  }
  const seenOpts = {}
  const agent = async (_p, opts) => {
    const id = opts.label.split(':').pop()
    seenOpts[id] = { model: opts.model, effort: opts.effort }
    return canned[id]
  }
  const out = await runTemplate(new URL('./recon.js', import.meta.url).pathname, { args, agent })

  assert.equal(out.ok, true)
  assert.equal(out.brief.length, 3)
  assert.equal(out.unresolved.length, 0)
  assert.deepEqual(out.escalate, [])
  const u1 = out.brief.find((b) => b.id === 'u1')
  assert.deepEqual(u1.source, { type: 'web', ref: 'https://x' })
  assert.equal(u1.confidence, 'high')
  // pins: fact -> haiku/low, library -> sonnet/low, approach -> sonnet/medium
  assert.deepEqual(seenOpts.u1, { model: 'haiku', effort: 'low' })
  assert.deepEqual(seenOpts.u2, { model: 'sonnet', effort: 'low' })
  assert.deepEqual(seenOpts.u3, { model: 'sonnet', effort: 'medium' })
  console.log('recon.test happy-path+pins PASS')
}

// Partial failure: a throwing verifier lands in unresolved, never dropped.
{
  const args = {
    projectRoot: '/tmp',
    unknowns: [
      { id: 'k1', question: 'ok', type: 'fact' },
      { id: 'k2', question: 'will throw', type: 'fact' },
    ],
  }
  const agent = async (_p, opts) => {
    const id = opts.label.split(':').pop()
    if (id === 'k2') throw new Error('verifier failed')
    return { finding: 'ok', source: { type: 'web', ref: 'https://y' }, confidence: 'high' }
  }
  const out = await runTemplate(new URL('./recon.js', import.meta.url).pathname, { args, agent })
  assert.equal(out.ok, true)
  assert.equal(out.brief.length, 1)
  assert.deepEqual(out.unresolved, ['k2'])
  console.log('recon.test partial-failure PASS')
}

// Load-bearing facts get an independent refuter. Refuted -> contested, low
// confidence, listed in escalate. Confirmed -> untouched. Low-confidence
// findings escalate even without a refuter.
{
  const args = {
    projectRoot: '/tmp',
    unknowns: [
      { id: 'lb1', question: 'latest Node LTS major', type: 'fact', loadBearing: true },
      { id: 'lb2', question: 'HTTPS default port', type: 'fact', loadBearing: true },
      { id: 'weak', question: 'fuzzy thing', type: 'approach' },
    ],
  }
  const calls = []
  const agent = async (prompt, opts) => {
    calls.push(opts.label)
    if (opts.label.startsWith('refute:')) {
      const id = opts.label.split(':').pop()
      assert.match(prompt, /REFUTE/i)
      assert.deepEqual({ model: opts.model, effort: opts.effort }, { model: 'sonnet', effort: 'medium' })
      return id === 'lb1'
        ? { verdict: 'refuted', counterEvidence: 'newer release', source: { type: 'web', ref: 'https://z' } }
        : { verdict: 'confirmed', counterEvidence: '', source: { type: 'web', ref: 'https://ok' } }
    }
    const id = opts.label.split(':').pop()
    if (id === 'weak') return { finding: 'maybe', source: { type: 'inference', ref: 'model-knowledge' }, confidence: 'low' }
    return { finding: 'fact', source: { type: 'web', ref: 'https://a' }, confidence: 'high' }
  }
  const out = await runTemplate(new URL('./recon.js', import.meta.url).pathname, { args, agent })

  assert.equal(calls.filter((l) => l.startsWith('refute:')).length, 2) // only load-bearing get refuters
  const lb1 = out.brief.find((b) => b.id === 'lb1')
  assert.equal(lb1.contested, true)
  assert.equal(lb1.confidence, 'low')
  assert.equal(lb1.counterEvidence, 'newer release')
  const lb2 = out.brief.find((b) => b.id === 'lb2')
  assert.equal(lb2.contested, undefined)
  assert.equal(lb2.confidence, 'high')
  assert.deepEqual(out.escalate.sort(), ['lb1', 'weak'])
  console.log('recon.test adversarial+escalate PASS')
}

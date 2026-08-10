// build-sdd.test.mjs
import assert from 'node:assert'
import { runTemplate } from './_shim.mjs'

const PATH = new URL('./build-sdd.js', import.meta.url).pathname
const tasks = [
  { id: 'a', title: 'model layer', brief: 'BRIEF-A with paths and spec', deps: [] },
  { id: 'b', title: 'cli flags', brief: 'BRIEF-B with paths and spec', deps: [] },
  { id: 'c', title: 'wire together', brief: 'BRIEF-C with paths and spec', deps: ['a', 'b'] },
]
const baseArgs = { projectRoot: '/tmp/proj', baseBranch: 'main', tasks }

// Waves: [a,b] then [c]; c is briefed with a+b outcomes; worktree isolation + pins.
{
  const calls = []
  const agent = async (prompt, opts) => {
    calls.push(opts.label)
    if (opts.label.startsWith('impl:')) {
      const id = opts.label.split(':').pop()
      assert.equal(opts.isolation, 'worktree', 'implementers run isolated')
      assert.deepEqual({ model: opts.model, effort: opts.effort }, { model: 'sonnet', effort: 'medium' })
      if (id === 'c') {
        assert.ok(prompt.includes('done-a') && prompt.includes('done-b'), 'dependent task sees prior-wave outcomes')
      }
      return { branch: `sdd/${id}`, summary: `done-${id}`, testOutput: 'tests pass', filesChanged: [`${id}.js`] }
    }
    if (opts.label.startsWith('review:')) {
      const id = opts.label.split(':').pop()
      assert.ok(prompt.includes(`sdd/${id}`), 'reviewer told which branch to diff')
      assert.ok(prompt.includes('/tmp/proj'), 'reviewer told the repo root')
      return { verdict: 'approve', mustFix: [], notes: 'clean' }
    }
    throw new Error(`unexpected ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, true)
  assert.deepEqual(out.waves, [['a', 'b'], ['c']])
  const implC = calls.indexOf('impl:c')
  assert.ok(implC > calls.indexOf('impl:a') && implC > calls.indexOf('impl:b'), 'wave 2 starts after wave 1')
  assert.equal(out.reports.length, 3)
  assert.equal(out.reports.find((r) => r.id === 'c').review.verdict, 'approve')
  assert.deepEqual(out.failed, [])
  console.log('build-sdd.test waves PASS')
}

// must-fix triggers one fix round in the same branch, then a re-review.
{
  let reviews = 0
  const agent = async (prompt, opts) => {
    if (opts.label.startsWith('impl:')) return { branch: 'sdd/a', summary: 'done', testOutput: 'ok', filesChanged: [] }
    if (opts.label.startsWith('fix:')) {
      assert.equal(opts.isolation, 'worktree')
      assert.ok(prompt.includes('missing null guard'), 'fix agent gets the must-fix list')
      return { branch: 'sdd/a', summary: 'fixed', testOutput: 'ok', filesChanged: ['a.js'] }
    }
    if (opts.label.startsWith('review:')) {
      reviews += 1
      return reviews === 1
        ? { verdict: 'must-fix', mustFix: ['missing null guard'], notes: '' }
        : { verdict: 'approve', mustFix: [], notes: 'fixed' }
    }
    throw new Error(`unexpected ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: { ...baseArgs, tasks: [tasks[0]] }, agent })
  assert.equal(out.ok, true)
  const rep = out.reports[0]
  assert.equal(rep.fixApplied, true)
  assert.equal(rep.review.verdict, 'approve')
  assert.equal(reviews, 2)
  console.log('build-sdd.test must-fix PASS')
}

// Implementer death fails the task; dependents are skipped as dep-failed; siblings survive.
{
  const agent = async (_p, opts) => {
    if (opts.label === 'impl:a') throw new Error('implementer crashed')
    if (opts.label.startsWith('impl:')) {
      const id = opts.label.split(':').pop()
      return { branch: `sdd/${id}`, summary: `done-${id}`, testOutput: 'ok', filesChanged: [] }
    }
    if (opts.label.startsWith('review:')) return { verdict: 'approve', mustFix: [], notes: '' }
    throw new Error(`unexpected ${opts.label}`)
  }
  const out = await runTemplate(PATH, { args: baseArgs, agent })
  assert.equal(out.ok, true)
  assert.deepEqual(out.failed.map((f) => f.id).sort(), ['a', 'c'])
  assert.equal(out.failed.find((f) => f.id === 'c').reason, 'dep-failed')
  assert.equal(out.reports.length, 1) // only b shipped
  console.log('build-sdd.test failure-cascade PASS')
}

// Dependency cycles are a plan bug: refuse to run.
{
  const cyclic = [
    { id: 'x', title: 'x', brief: 'bx', deps: ['y'] },
    { id: 'y', title: 'y', brief: 'by', deps: ['x'] },
  ]
  const agent = async () => { throw new Error('must not dispatch') }
  const out = await runTemplate(PATH, { args: { ...baseArgs, tasks: cyclic }, agent })
  assert.equal(out.ok, false)
  assert.match(out.error, /cycle/i)
  console.log('build-sdd.test cycle PASS')
}

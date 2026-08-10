// _shim.test.mjs
import assert from 'node:assert'
import { writeFile, rm } from 'node:fs/promises'
import { runTemplate } from './_shim.mjs'

const dummy = `export const meta = { name: 'dummy', description: 'd', phases: [] }
phase('X')
log('hi')
const r = await agent('q', { schema: {} })
const both = await parallel([async () => 1, async () => { throw new Error('x') }])
return { ok: true, r, both }`

const path = new URL('./_dummy.js', import.meta.url).pathname
await writeFile(path, dummy)
const out = await runTemplate(path, {
  args: {},
  agent: async () => 'A',
  parallel: (thunks) => Promise.all(thunks.map((t) => t().catch(() => null))),
})
await rm(path)
assert.equal(out.ok, true)
assert.equal(out.r, 'A')
assert.deepEqual(out.both, [1, null]) // thrown thunk becomes null
console.log('_shim.test PASS')

// _shim.mjs
import { readFile } from 'node:fs/promises'

// Runs a Workflow template under Node by injecting the harness hooks as locals.
// Mirrors how the Workflow tool wraps a script body in an async function whose
// `return` value is the result. `export const meta` is downgraded to a local so
// the body is valid inside the wrapper.
// NOTE: new Function runs in global scope, so templates cannot use static import
// or import.meta; they rely only on the injected hooks (agent, parallel, etc.).
export async function runTemplate(absPath, hooks) {
  const {
    args = {},
    agent,
    parallel = (thunks) => Promise.all(thunks.map((t) => t().catch(() => null))),
    pipeline,
    log = () => {},
    phase = () => {},
  } = hooks
  let src = await readFile(absPath, 'utf8')
  src = src.replace(/export\s+const\s+meta/, 'const meta')
  const body = `return (async () => { ${src} })()`
  const fn = new Function('agent', 'parallel', 'pipeline', 'log', 'phase', 'args', body)
  return fn(agent, parallel, pipeline, log, phase, args)
}

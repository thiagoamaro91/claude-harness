// panel.js
export const meta = {
  name: 'autonomous-panel',
  description: 'Diverse-lens adversarial critique: one refuter per lens, adjudicator merges findings',
  phases: [
    { title: 'Refute', detail: 'one refuter per lens' },
    { title: 'Adjudicate', detail: 'merge, dedup, verdict' },
  ],
}

const REFUTER_SCHEMA = {
  type: 'object',
  required: ['findings', 'verdict'],
  additionalProperties: false,
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['claim', 'severity', 'rationale'],
        additionalProperties: false,
        properties: {
          claim: { type: 'string' },
          severity: { enum: ['critical', 'major', 'minor'] },
          rationale: { type: 'string' },
        },
      },
    },
    verdict: { enum: ['holds', 'refuted'] },
  },
}

const MERGED_SCHEMA = {
  type: 'object',
  required: ['criticals', 'majors', 'minors', 'survives', 'notes'],
  additionalProperties: false,
  properties: {
    criticals: { type: 'array', items: { type: 'string' } },
    majors: { type: 'array', items: { type: 'string' } },
    minors: { type: 'array', items: { type: 'string' } },
    survives: { type: 'boolean' },
    notes: { type: 'string' },
  },
}

// args: { artifact, context, lenses: [{id, instruction}],
//         refuterModel?, refuterEffort?, adjudicatorModel?, adjudicatorEffort? }
// Identical reviewers converge on the same misses; each refuter here holds ONE
// distinct lens and is prompted to attack, not to review politely.
const artifact = args.artifact
const context = args.context || ''
const lenses = args.lenses || []
const refuterOpts = { model: args.refuterModel || 'sonnet', effort: args.refuterEffort || 'medium' }
const adjudicatorOpts = { model: args.adjudicatorModel || 'opus', effort: args.adjudicatorEffort || 'high' }

phase('Refute')
const settled = await parallel(
  lenses.map((l) => async () => {
    try {
      const r = await agent(
        `You are an adversarial refuter with exactly one lens. Attack the artifact through it; ignore everything outside your lens. Finding nothing real is a valid outcome; do not invent findings to look useful.\n\nCONTEXT: ${context}\n\nYOUR LENS: ${l.instruction}\n\nARTIFACT UNDER ATTACK:\n${artifact}\n\nReturn findings [{claim, severity critical|major|minor, rationale}] and verdict holds|refuted (refuted = a critical finding invalidates the artifact as-is).`,
        { label: `refute:${l.id}`, phase: 'Refute', schema: REFUTER_SCHEMA, ...refuterOpts },
      )
      return r ? { lens: l.id, verdict: r.verdict, findings: r.findings } : null
    } catch {
      return { lens: l.id, failed: true }
    }
  })
)

const byLens = settled.filter((s) => s && !s.failed)
const lensesFailed = settled.filter((s) => s && s.failed).map((s) => s.lens)
if (lensesFailed.length) log(`lenses with no verdict (refuter died): ${lensesFailed.join(', ')}`)

if (byLens.length === 0) {
  return { ok: false, byLens: [], lensesFailed, merged: null, error: 'every refuter failed' }
}

const allFindings = byLens.flatMap((b) => b.findings.map((f) => ({ ...f, lens: b.lens })))

phase('Adjudicate')
if (allFindings.length === 0) {
  return {
    ok: true,
    byLens,
    lensesFailed,
    merged: { criticals: [], majors: [], minors: [], survives: true, notes: 'no findings from any lens' },
  }
}

const merged = await agent(
  `Adjudicate this adversarial panel. Merge duplicate findings, drop performative ones (nits dressed up as risks, findings with no concrete failure), keep severity honest. survives=false only if an unresolved critical invalidates the artifact as-is.\n\nCONTEXT: ${context}\n\nFINDINGS (lens-tagged):\n${JSON.stringify(allFindings, null, 2)}\n\nReturn criticals/majors/minors as deduped claim strings, survives, and notes (one line on the overall shape).`,
  { label: 'adjudicate', phase: 'Adjudicate', schema: MERGED_SCHEMA, ...adjudicatorOpts },
)

// Adjudicator death must FAIL CLOSED: the ship gate reads criticals, so raw
// critical findings stay criticals (deduping loses to gate integrity).
return {
  ok: true,
  byLens,
  lensesFailed,
  merged: merged || {
    criticals: allFindings.filter((f) => f.severity === 'critical').map((f) => `[${f.lens}] ${f.claim}`),
    majors: allFindings.filter((f) => f.severity === 'major').map((f) => `[${f.lens}] ${f.claim}`),
    minors: allFindings.filter((f) => f.severity === 'minor').map((f) => `[${f.lens}] ${f.claim}`),
    survives: false,
    notes: 'adjudicator failed; raw findings passed through un-deduped, severities preserved',
  },
}

// recon.js
export const meta = {
  name: 'autonomous-recon',
  description: 'Parallel verification of recon unknowns, one verifier per unknown, refuter on load-bearing facts',
  phases: [{ title: 'Recon', detail: 'one verifier per unknown' }],
}

const RECON_ITEM_SCHEMA = {
  type: 'object',
  required: ['finding', 'source', 'confidence'],
  additionalProperties: false,
  properties: {
    finding: { type: 'string' },
    source: {
      type: 'object',
      required: ['type', 'ref'],
      additionalProperties: false,
      properties: {
        type: { enum: ['web', 'file', 'tool', 'inference'] },
        ref: { type: 'string' },
      },
    },
    confidence: { enum: ['high', 'med', 'low'] },
  },
}

const REFUTE_SCHEMA = {
  type: 'object',
  required: ['verdict', 'counterEvidence', 'source'],
  additionalProperties: false,
  properties: {
    verdict: { enum: ['confirmed', 'refuted', 'uncertain'] },
    counterEvidence: { type: 'string' },
    source: {
      type: 'object',
      required: ['type', 'ref'],
      additionalProperties: false,
      properties: {
        type: { enum: ['web', 'file', 'tool', 'inference'] },
        ref: { type: 'string' },
      },
    },
  },
}

const PROMPT = {
  fact: (u) => `Verify this discrete fact. Use a web source. Return finding, a typed source {type,ref}, and confidence. Question: ${u.question}`,
  library: (u) => `Resolve this library/API/CLI question via context7 (cap 3000 tokens). Return finding, source {type:"tool",ref:"context7"} (or {type:"inference",ref:"model-knowledge"} if context7 is unavailable), and confidence. Question: ${u.question}`,
  approach: (u) => `Research this open "best approach" question across multiple sources. Return finding, a typed source {type,ref}, and confidence. Question: ${u.question}`,
}

// Unpinned agents inherit the session model, so pin per unknown type: recon is
// mechanical fan-out work and never deserves the session tier.
const TIER = {
  fact: { model: 'haiku', effort: 'low' },
  library: { model: 'sonnet', effort: 'low' },
  approach: { model: 'sonnet', effort: 'medium' },
}
const REFUTER_TIER = { model: 'sonnet', effort: 'medium' }

phase('Recon')
const unknowns = (args && args.unknowns) || []

const settled = await parallel(
  unknowns.map((u) => async () => {
    const tier = TIER[u.type] || TIER.fact
    try {
      const r = await agent((PROMPT[u.type] || PROMPT.fact)(u), {
        label: `recon:${u.type}:${u.id}`,
        phase: 'Recon',
        schema: RECON_ITEM_SCHEMA,
        model: tier.model,
        effort: tier.effort,
      })
      if (!r) return { id: u.id, question: u.question, result: null, error: 'verifier returned null' }

      // Load-bearing facts (the plan or recommendation flips if they are wrong)
      // get one independent refuter. Anything not confirmed is contested.
      if (u.loadBearing) {
        const ref = await agent(
          `Independently try to REFUTE this finding. Hunt for counter-evidence (newer ruling, version change, contradicting primary source); do not rubber-stamp. Question: ${u.question} Finding under test: ${r.finding} (source: ${r.source.ref}). Return verdict confirmed|refuted|uncertain, counterEvidence, and a typed source {type,ref}.`,
          { label: `refute:${u.id}`, phase: 'Recon', schema: REFUTE_SCHEMA, model: REFUTER_TIER.model, effort: REFUTER_TIER.effort },
        )
        if (ref && ref.verdict !== 'confirmed') {
          return { id: u.id, question: u.question, result: { ...r, confidence: 'low', contested: true, counterEvidence: ref.counterEvidence, counterSource: ref.source } }
        }
      }
      return { id: u.id, question: u.question, result: r }
    } catch (e) {
      return { id: u.id, question: u.question, result: null, error: String(e) }
    }
  })
)

const brief = []
const unresolved = []
const escalate = []
for (const s of settled) {
  if (s && s.result) {
    const r = s.result
    const item = { id: s.id, question: s.question, finding: r.finding, source: r.source, confidence: r.confidence }
    if (r.contested) {
      item.contested = true
      item.counterEvidence = r.counterEvidence
      item.counterSource = r.counterSource
    }
    brief.push(item)
    // Contested or low-confidence findings are not settled facts: the
    // controller re-runs just these with --deep or proceeds naming the gap.
    if (r.contested || r.confidence === 'low') escalate.push(s.id)
  } else if (s) {
    unresolved.push(s.id)
  }
  // a null slot (s == null) is unreachable: each thunk's try/catch always returns
  // an object, so no unknown is silently lost between brief and unresolved.
}

return { ok: true, brief, unresolved, escalate }

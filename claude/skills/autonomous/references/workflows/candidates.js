// candidates.js
export const meta = {
  name: 'autonomous-candidates',
  description: 'Multi-candidate produce: N blind producers from distinct angles, one blind judge, optional synthesis',
  phases: [
    { title: 'Produce', detail: 'one producer per angle' },
    { title: 'Judge', detail: 'blind rubric scoring + synthesis' },
  ],
}

const ARTIFACT_SCHEMA = {
  type: 'object',
  required: ['artifact'],
  additionalProperties: false,
  properties: { artifact: { type: 'string' } },
}

const JUDGE_SCHEMA = {
  type: 'object',
  required: ['scores', 'winner', 'grafts'],
  additionalProperties: false,
  properties: {
    scores: {
      type: 'array',
      items: {
        type: 'object',
        required: ['candidate', 'total', 'notes'],
        additionalProperties: false,
        properties: {
          candidate: { type: 'integer' },
          total: { type: 'number' },
          notes: { type: 'string' },
        },
      },
    },
    winner: { type: 'integer' },
    grafts: { type: 'array', items: { type: 'string' } },
  },
}

// args: { briefing, angles: [{id, instruction}], rubric: [string],
//         producerModel?, producerEffort?, judgeModel?, judgeEffort?, synthesize? }
// briefing must be self-contained (subagents see nothing else). Producers each
// get briefing + their angle; the judge is BLIND to angles (prevents the judge
// scoring the instruction instead of the artifact).
const briefing = args.briefing
const angles = args.angles || []
const rubric = args.rubric || []
const producerOpts = { model: args.producerModel || 'sonnet', effort: args.producerEffort || 'medium' }
const judgeOpts = { model: args.judgeModel || 'opus', effort: args.judgeEffort || 'high' }

phase('Produce')
const produced = await parallel(
  angles.map((a) => async () => {
    try {
      const r = await agent(
        `${briefing}\n\nANGLE for this attempt (yours alone, other attempts take different angles): ${a.instruction}\n\nReturn ONLY the finished artifact content in the artifact field, no commentary.`,
        { label: `produce:${a.id}`, phase: 'Produce', schema: ARTIFACT_SCHEMA, ...producerOpts },
      )
      return r && r.artifact ? { angle: a.id, artifact: r.artifact } : null
    } catch {
      return null
    }
  })
)

const candidates = produced.filter(Boolean)
if (candidates.length === 0) {
  return { ok: false, candidates: [], judgment: null, final: null, error: 'all producers failed' }
}

phase('Judge')
if (candidates.length === 1) {
  log('only one candidate survived; skipping judge')
  return { ok: true, candidates, judgment: null, final: candidates[0].artifact }
}

const numbered = candidates.map((c, i) => `--- CANDIDATE ${i + 1} ---\n${c.artifact}`).join('\n\n')
const judgment = await agent(
  `You are a blind judge. Score each candidate against the rubric (0-10 per criterion, sum to total). You do not know how each was produced; judge only what is on the page.\n\nRUBRIC:\n${rubric.map((r) => `- ${r}`).join('\n')}\n\nTASK BRIEFING the candidates answered:\n${briefing}\n\n${numbered}\n\nReturn scores per candidate (1-based), the winner, and grafts: concrete elements from LOSING candidates worth merging into the winner.`,
  { label: 'judge', phase: 'Judge', schema: JUDGE_SCHEMA, ...judgeOpts },
)

if (!judgment) {
  log('judge failed; returning first candidate un-judged')
  return { ok: true, candidates, judgment: null, final: candidates[0].artifact }
}

const winnerIdx = Math.min(Math.max(judgment.winner, 1), candidates.length) - 1
const winner = candidates[winnerIdx]

if (args.synthesize === false || judgment.grafts.length === 0) {
  return { ok: true, candidates, judgment, final: winner.artifact }
}

const synth = await agent(
  `${briefing}\n\nBelow is the winning draft plus judge-selected grafts from other drafts. Merge the grafts into the winner without diluting its strengths; keep one consistent voice. Return ONLY the finished artifact.\n\nWINNING DRAFT:\n${winner.artifact}\n\nGRAFTS TO APPLY:\n${judgment.grafts.map((g) => `- ${g}`).join('\n')}`,
  { label: 'synthesize', phase: 'Judge', schema: ARTIFACT_SCHEMA, ...producerOpts },
)

return { ok: true, candidates, judgment, final: synth && synth.artifact ? synth.artifact : winner.artifact }

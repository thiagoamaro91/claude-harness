// build-sdd.js
export const meta = {
  name: 'autonomous-build-sdd',
  description: 'Wave-parallel subagent build: independent tasks in concurrent worktrees, fresh implementer + reviewer per task',
  phases: [{ title: 'Build', detail: 'waves of worktree implementers + per-task review' }],
}

const IMPL_SCHEMA = {
  type: 'object',
  required: ['branch', 'summary', 'testOutput', 'filesChanged'],
  additionalProperties: false,
  properties: {
    branch: { type: 'string' },
    summary: { type: 'string' },
    testOutput: { type: 'string' },
    filesChanged: { type: 'array', items: { type: 'string' } },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['verdict', 'mustFix', 'notes'],
  additionalProperties: false,
  properties: {
    verdict: { enum: ['approve', 'must-fix'] },
    mustFix: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

// args: { projectRoot, baseBranch?, tasks: [{id, title, brief, deps}],
//         implementerModel?, implementerEffort?, reviewerModel?, reviewerEffort? }
// Task briefs must be self-contained (spec excerpt, exact paths, test commands):
// implementers see nothing else. Integration (merge order, full-suite run,
// whole-branch review) stays with the controller; this template only fans out.
const projectRoot = args.projectRoot
const baseBranch = args.baseBranch || 'main'
const tasks = args.tasks || []
const implOpts = { model: args.implementerModel || 'sonnet', effort: args.implementerEffort || 'medium' }
const reviewOpts = { model: args.reviewerModel || 'sonnet', effort: args.reviewerEffort || 'medium' }

// Kahn batching: wave N = every unbuilt task whose deps all landed in waves < N.
const byId = new Map(tasks.map((t) => [t.id, t]))
const waves = []
{
  const placed = new Set()
  let remaining = tasks.slice()
  while (remaining.length) {
    const wave = remaining.filter((t) => (t.deps || []).every((d) => placed.has(d) || !byId.has(d)))
    if (wave.length === 0) {
      return { ok: false, waves, reports: [], failed: [], error: `dependency cycle among: ${remaining.map((t) => t.id).join(', ')}` }
    }
    wave.forEach((t) => placed.add(t.id))
    remaining = remaining.filter((t) => !wave.includes(t))
    waves.push(wave.map((t) => t.id))
  }
}

phase('Build')
const reports = []
const failed = []
const done = new Map() // id -> summary, for briefing dependents

for (const waveIds of waves) {
  const results = await parallel(
    waveIds.map((id) => async () => {
      const t = byId.get(id)
      const badDep = (t.deps || []).find((d) => byId.has(d) && !done.has(d))
      if (badDep) return { id, failedReason: 'dep-failed', detail: `dependency ${badDep} did not ship` }

      const depContext = (t.deps || [])
        .filter((d) => done.has(d))
        .map((d) => `- ${d}: ${done.get(d)}`)
        .join('\n')

      try {
        const impl = await agent(
          `Implement one task in an isolated worktree of ${projectRoot}.\n\nTASK ${t.id}: ${t.title}\n${t.brief}\n${depContext ? `\nALREADY LANDED (branches sdd/<id>, build on their interfaces):\n${depContext}\n` : ''}\nRULES: commit your work on branch sdd/${t.id}. Run the task's tests and paste real output. Touch only files this task owns.\n\nReturn branch, summary (what a dependent task needs to know), testOutput, filesChanged.`,
          { label: `impl:${t.id}`, phase: 'Build', schema: IMPL_SCHEMA, isolation: 'worktree', ...implOpts },
        )
        if (!impl) return { id, failedReason: 'implementer-null' }

        const reviewPrompt = (extra) =>
          `Fresh-eyes review of one task branch. Repo: ${projectRoot}. Run \`git -C ${projectRoot} diff ${baseBranch}...${impl.branch}\` and read the full diff. Task spec:\n${t.brief}\n${extra}\nVerdict approve|must-fix; mustFix lists only defects that block merging (spec misses, broken contracts, failing paths), not taste.`

        let review = await agent(reviewPrompt(''), { label: `review:${t.id}`, phase: 'Build', schema: REVIEW_SCHEMA, ...reviewOpts })
        let fixApplied = false

        if (review && review.verdict === 'must-fix' && review.mustFix.length) {
          const fix = await agent(
            `Fix review findings on branch ${impl.branch} of ${projectRoot} (check it out in your isolated worktree). Findings to fix, nothing else:\n${review.mustFix.map((m) => `- ${m}`).join('\n')}\n\nTask spec for reference:\n${t.brief}\n\nCommit on the same branch, re-run tests, paste real output. Return branch, summary, testOutput, filesChanged.`,
            { label: `fix:${t.id}`, phase: 'Build', schema: IMPL_SCHEMA, isolation: 'worktree', ...implOpts },
          )
          if (fix) {
            fixApplied = true
            review = await agent(reviewPrompt(`\nThis is a RE-REVIEW after fixes for: ${review.mustFix.join('; ')}.`), { label: `review:${t.id}:2`, phase: 'Build', schema: REVIEW_SCHEMA, ...reviewOpts })
          }
        }

        if (!review) return { id, failedReason: 'review-null' }
        return { id, report: { id, branch: impl.branch, implSummary: impl.summary, testOutput: impl.testOutput, filesChanged: impl.filesChanged, review, fixApplied } }
      } catch (e) {
        return { id, failedReason: 'implementer-crashed', detail: String(e) }
      }
    })
  )

  for (const r of results) {
    if (!r) continue
    if (r.report) {
      reports.push(r.report)
      done.set(r.id, r.report.implSummary)
    } else {
      failed.push({ id: r.id, reason: r.failedReason, detail: r.detail || '' })
    }
  }
}

log(`build-sdd: ${reports.length} shipped, ${failed.length} failed across ${waves.length} wave(s)`)
return { ok: true, waves, reports, failed }

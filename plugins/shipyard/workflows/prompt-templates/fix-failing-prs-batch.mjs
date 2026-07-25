/*
 * fix-failing-prs-batch.mjs — buildFixFailingPrsBatchPrompt, the
 * fix-failing-prs-batch mode's workflow-substrate dispatch-prompt builder
 * (synthetic divert; no originating issue).
 *
 * SOURCE OF TRUTH, NOT RUNTIME CODE (issue #958) — see shared.mjs's header
 * for the full generated-file contract. Edit here, then run
 * `node plugins/shipyard/scripts/generate-dispatch-workflow.mjs` to
 * regenerate `do-work-dispatch.workflow.js`; do not hand-edit that file's
 * copy of this function.
 */
import { worktreeAnchorLines } from './shared.mjs'

// ===========================================================================
// Helper — build the fix-failing-prs-batch dispatch prompt (synthetic divert;
// no originating issue). Mirrors dispatch-rules.md's `mode: fix-failing-prs-batch`
// template.
// ===========================================================================
export function buildFixFailingPrsBatchPrompt(unit, repoSlug) {
  const lines = [`mode: fix-failing-prs-batch`, ``, ...worktreeAnchorLines(unit, 'fix-failing-prs-batch')]
  if (!unit.worktreePath) return lines.join('\n')

  lines.push(
    ``,
    `Investigate the failing-PR pileup on ${repoSlug}. ${unit.failingPrCountAll} open PRs`,
    `across all authors currently failing: ${unit.failingPrNumbers}. Load the`,
    `\`shipyard:worker-preamble\` skill, then \`agents/issue-worker/fix-failing-prs-batch.md\`.`,
    `Branch: ${unit.branch}. Synthetic divert — no \`Closes #N\` line.`,
    ``,
    `Return a STRUCTURED result matching schemas/worker-return.schema.json — e.g.`,
    `{ "mode": "fix-failing-prs-batch", "outcome": "shipped", "pr": <M> },`,
    `{ "mode": "fix-failing-prs-batch", "outcome": "noop", "summary": "pileup already cleared" },`,
    `or { "mode": "fix-failing-prs-batch", "outcome": "blocked", "blocked_reason": "no common`,
    `root cause — <N> independent failures, sample: PR #X (<err1>), PR #Y (<err2>)" }. This is`,
    `the workflow-substrate return contract — NOT the free-text return string the Agent-tool`,
    `path uses.`,
  )
  return lines.join('\n')
}

/*
 * fix-main-ci.mjs — buildFixMainCiPrompt, the fix-main-ci mode's
 * workflow-substrate dispatch-prompt builder (synthetic divert; no
 * originating issue).
 *
 * SOURCE OF TRUTH, NOT RUNTIME CODE (issue #958) — see shared.mjs's header
 * for the full generated-file contract. Edit here, then run
 * `node plugins/shipyard/scripts/generate-dispatch-workflow.mjs` to
 * regenerate `do-work-dispatch.workflow.js`; do not hand-edit that file's
 * copy of this function.
 */
import { worktreeAnchorLines, awaitingExternalReturnLines } from './shared.mjs'

// ===========================================================================
// Helper — build the fix-main-ci dispatch prompt (synthetic divert; no
// originating issue). Mirrors dispatch-rules.md's `mode: fix-main-ci` template.
// ===========================================================================
export function buildFixMainCiPrompt(unit, repoSlug) {
  const lines = [`mode: fix-main-ci`, ``, ...worktreeAnchorLines(unit, 'fix-main-ci')]
  if (!unit.worktreePath) return lines.join('\n')

  lines.push(
    ``,
    `Restore green main on ${repoSlug}. Earliest unfixed red run on the default branch:`,
    `${unit.earliestRedRunUrl} at SHA ${unit.earliestRedSha} — triage that run's failure`,
    `logs first. Load the \`shipyard:worker-preamble\` skill, then`,
    `\`agents/issue-worker/fix-main-ci.md\`. Branch: ${unit.branch}. Synthetic divert — no`,
    `\`Closes #N\` line.`,
    ``,
    `Return a STRUCTURED result matching schemas/worker-return.schema.json — e.g.`,
    `{ "mode": "fix-main-ci", "outcome": "shipped", "pr": <M> },`,
    `{ "mode": "fix-main-ci", "outcome": "noop", "summary": "main already green" }, or`,
    `{ "mode": "fix-main-ci", "outcome": "blocked", "blocked_reason": "<reason>" }.`,
    `This is the workflow-substrate return contract — NOT the free-text return string the`,
    `Agent-tool path uses.`,
    ...awaitingExternalReturnLines(unit, 'fix-main-ci'),
  )
  return lines.join('\n')
}

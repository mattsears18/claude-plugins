/*
 * fix-rebase.mjs — buildFixRebasePrompt, the fix-rebase mode's
 * workflow-substrate dispatch-prompt builder (drain-phase only).
 *
 * SOURCE OF TRUTH, NOT RUNTIME CODE (issue #958) — see shared.mjs's header
 * for the full generated-file contract. Edit here, then run
 * `node plugins/shipyard/scripts/generate-dispatch-workflow.mjs` to
 * regenerate `do-work-dispatch.workflow.js`; do not hand-edit that file's
 * copy of this function.
 */
import { worktreeAnchorLines } from './shared.mjs'

// ===========================================================================
// Helper — build the fix-rebase dispatch prompt (drain-phase only). Mirrors
// dispatch-rules.md's `mode: fix-rebase` template, including the optional
// version-coordination paragraph (pre-formatted by the orchestrator and passed
// as `unit.versionCoordinationParagraph` — the vc_* config reads + manifest
// lookups stay orchestrator-side, exactly as for every other augmentation).
// ===========================================================================
export function buildFixRebasePrompt(unit, repoSlug) {
  const lines = [`mode: fix-rebase`, ``, ...worktreeAnchorLines(unit, 'fix-rebase')]
  if (!unit.worktreePath) return lines.join('\n')

  lines.push(
    ``,
    `The worktree above was pre-provisioned already checked out on PR #${unit.pr}'s head`,
    `branch \`${unit.headRefName}\`.`,
    ``,
    `Rebase PR #${unit.pr} in ${repoSlug} (head branch \`${unit.headRefName}\`) onto current`,
    `default branch. Drain-phase snapshot found this PR \`mergeStateStatus: DIRTY\` with no`,
    `failing checks — stale relative to advanced main, auto-merge blocked until rebased.`,
    `Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/fix-rebase.md\`.`,
    `Do NOT touch PR title/body/labels. Do NOT manually \`gh pr merge\` — auto-merge was armed`,
    `at PR creation and rebasing doesn't un-arm it.`,
  )

  if (unit.versionCoordinationParagraph) {
    lines.push(``, unit.versionCoordinationParagraph)
  }

  lines.push(
    ``,
    `Return a STRUCTURED result matching schemas/worker-return.schema.json — e.g.`,
    `{ "mode": "fix-rebase", "outcome": "rebased", "pr": ${unit.pr} },`,
    `{ "mode": "fix-rebase", "outcome": "noop", "pr": ${unit.pr}, "summary": "not dirty (<reason>)" },`,
    `or { "mode": "fix-rebase", "outcome": "blocked", "pr": ${unit.pr}, "blocked_reason": "<reason>" }.`,
    `This is the workflow-substrate return contract — NOT the free-text return string the`,
    `Agent-tool path uses.`,
  )
  return lines.join('\n')
}

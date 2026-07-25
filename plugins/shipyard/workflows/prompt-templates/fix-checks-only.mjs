/*
 * fix-checks-only.mjs — buildFixChecksOnlyPrompt, the fix-checks-only mode's
 * workflow-substrate dispatch-prompt builder.
 *
 * SOURCE OF TRUTH, NOT RUNTIME CODE (issue #958) — see shared.mjs's header
 * for the full generated-file contract. Edit here, then run
 * `node plugins/shipyard/scripts/generate-dispatch-workflow.mjs` to
 * regenerate `do-work-dispatch.workflow.js`; do not hand-edit that file's
 * copy of this function.
 */
import { worktreeAnchorLines } from './shared.mjs'

// ===========================================================================
// Helper — build the fix-checks-only dispatch prompt. Mirrors dispatch-rules.md's
// `mode: fix-checks-only` template. Targets an EXISTING PR's head branch — the
// caller pre-provisions the worktree checked out directly onto that branch (see
// the file-header "Worktree isolation" note), so no NEW branch is created here.
// ===========================================================================
export function buildFixChecksOnlyPrompt(unit, repoSlug) {
  const lines = [`mode: fix-checks-only`, ``, ...worktreeAnchorLines(unit, 'fix-checks-only')]
  if (!unit.worktreePath) return lines.join('\n')

  lines.push(
    ``,
    `The worktree above was pre-provisioned already checked out on PR #${unit.pr}'s head`,
    `branch \`${unit.headRefName}\` — the \`git fetch origin && git switch\` step in`,
    `fix-checks-only.md's own Setup section is a no-op safety net here, not additional`,
    `required work.`,
    ``,
    `Fix failing CI checks on PR #${unit.pr} in ${repoSlug} (head branch \`${unit.headRefName}\`).`,
    `Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/fix-checks-only.md\`.`,
    `Existing PR — do NOT open a new one, do NOT change scope, do NOT modify title/body/labels.`,
    ``,
    `Return a STRUCTURED result matching schemas/worker-return.schema.json — e.g.`,
    `{ "mode": "fix-checks-only", "outcome": "green", "pr": ${unit.pr}, "checks": "green" },`,
    `{ "mode": "fix-checks-only", "outcome": "noop", "pr": ${unit.pr}, "summary": "already green" },`,
    `{ "mode": "fix-checks-only", "outcome": "green", "pr": ${unit.pr}, "checks": "pending",`,
    `"summary": "flake: re-ran failed jobs (<signature>)" } (the infra-flake re-run —`,
    `there is no separate schema outcome for it; the "flake: " summary prefix is what the`,
    `orchestrator's translation table keys on to reconstruct the free-text \`flake #<M>: ...\``,
    `form), or { "mode": "fix-checks-only", "outcome": "blocked", "pr": ${unit.pr},`,
    `"blocked_reason": "<last failing check> — <last error excerpt>" }. This is the`,
    `workflow-substrate return contract — NOT the free-text return string the Agent-tool`,
    `path uses.`,
  )
  return lines.join('\n')
}

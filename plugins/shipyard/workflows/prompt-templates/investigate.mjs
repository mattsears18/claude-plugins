/*
 * investigate.mjs — buildInvestigatePrompt, the investigate mode's
 * workflow-substrate dispatch-prompt builder.
 *
 * SOURCE OF TRUTH, NOT RUNTIME CODE (issue #958) — see shared.mjs's header
 * for the full generated-file contract. Edit here, then run
 * `node plugins/shipyard/scripts/generate-dispatch-workflow.mjs` to
 * regenerate `do-work-dispatch.workflow.js`; do not hand-edit that file's
 * copy of this function.
 */
import { worktreeAnchorLines, awaitingExternalReturnLines } from './shared.mjs'

// ===========================================================================
// Helper — build the investigate dispatch prompt. Mirrors dispatch-rules.md's
// `mode: investigate` template — fresh `do-work/issue-<N>` branch off default,
// same shape as issue-work's worktree provisioning.
// ===========================================================================
export function buildInvestigatePrompt(unit, repoSlug) {
  const lines = [`mode: investigate`, ``, ...worktreeAnchorLines(unit, 'investigate')]
  if (!unit.worktreePath) return lines.join('\n')

  lines.push(
    ``,
    `Work untriaged issue #${unit.number} in ${repoSlug} end-to-end. The \`shipyard\` label is`,
    `already applied (self-assignment is config-gated via \`backlog.self_assign\`, default off —`,
    `see worker-preamble). The originating issue's author trust is **${unit.trust}** — load-bearing`,
    `for auto-merge gating on the fixable-disposition path. \`triage.auto_close\` policy:`,
    `**${unit.triageAutoClose}**. Load the \`shipyard:worker-preamble\` skill, then`,
    `\`agents/issue-worker/investigate.md\`. Branch: ${unit.branch}.`,
    ``,
    `Return a STRUCTURED result matching schemas/worker-return.schema.json — e.g.`,
    `{ "mode": "investigate", "outcome": "shipped", "issue": ${unit.number}, "pr": <M>,`,
    `"auto_merge": "enabled", "checks": "green" } (investigated+fixed),`,
    `{ "mode": "investigate", "outcome": "disposition", "issue": ${unit.number},`,
    `"disposition": "needs-human-review" },`,
    `{ "mode": "investigate", "outcome": "disposition", "issue": ${unit.number},`,
    `"disposition": "auto-close-noise" },`,
    `{ "mode": "investigate", "outcome": "disposition", "issue": ${unit.number},`,
    `"disposition": "duplicate", "summary": "duplicate of #<K>" }, or`,
    `{ "mode": "investigate", "outcome": "blocked", "issue": ${unit.number},`,
    `"blocked_reason": "<reason>" }. This is the workflow-substrate return contract — NOT`,
    `the free-text return string the Agent-tool path uses.`,
    ...awaitingExternalReturnLines(unit, 'investigate'),
  )
  return lines.join('\n')
}

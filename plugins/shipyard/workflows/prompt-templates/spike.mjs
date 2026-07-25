/*
 * spike.mjs — buildSpikePrompt, the spike mode's workflow-substrate
 * dispatch-prompt builder.
 *
 * SOURCE OF TRUTH, NOT RUNTIME CODE (issue #958) — see shared.mjs's header
 * for the full generated-file contract. Edit here, then run
 * `node plugins/shipyard/scripts/generate-dispatch-workflow.mjs` to
 * regenerate `do-work-dispatch.workflow.js`; do not hand-edit that file's
 * copy of this function.
 */
import { worktreeAnchorLines } from './shared.mjs'

// ===========================================================================
// Helper — build the spike dispatch prompt. Mirrors dispatch-rules.md's
// `mode: spike` template — fresh `do-work/issue-<N>` branch off default, same
// shape as issue-work's worktree provisioning, plus the optional directly-
// committable-slice version-coordination paragraph (spike.md step 7).
// ===========================================================================
export function buildSpikePrompt(unit, repoSlug) {
  const lines = [`mode: spike`, ``, ...worktreeAnchorLines(unit, 'spike')]
  if (!unit.worktreePath) return lines.join('\n')

  lines.push(
    ``,
    `Work issue #${unit.number} in ${repoSlug} to completion. You are already self-assigned.`,
    `The originating issue's author trust is **${unit.trust}** — load-bearing for auto-merge`,
    `gating. Fan-out cap for follow-on sub-issues: **${unit.decomposeMaxSubissues}** (default 8).`,
    `Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/spike.md\`.`,
    `Branch: ${unit.branch}.`,
  )

  if (unit.nextAvailableVersion) {
    lines.push(
      ``,
      `**Next-available version (orchestrator-supplied):** the manifest's version row is`,
      `coordination-managed across this session's in-flight PRs. The next available`,
      `version is **${unit.nextAvailableVersion}**. Use this exact value when bumping the`,
      `manifest${unit.changelogPath ? ` and add a fresh entry above the highest existing entry in \`${unit.changelogPath}\`` : ''} — do NOT compute your own version from`,
      `\`origin/<default-branch>\`.`,
    )
  }

  lines.push(
    ``,
    `Return a STRUCTURED result matching schemas/worker-return.schema.json — e.g.`,
    `{ "mode": "spike", "outcome": "shipped", "issue": ${unit.number}, "pr": <M>,`,
    `"auto_merge": "enabled", "checks": "green" } (spiked+shipped),`,
    `{ "mode": "spike", "outcome": "disposition", "issue": ${unit.number},`,
    `"disposition": "needs-human-review" } (spiked+needs-human-review), or`,
    `{ "mode": "spike", "outcome": "blocked", "issue": ${unit.number}, "blocked_reason": "<reason>" }.`,
    `This is the workflow-substrate return contract — NOT the free-text return string the`,
    `Agent-tool path uses.`,
  )
  return lines.join('\n')
}

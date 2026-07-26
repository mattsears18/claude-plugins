/*
 * shared.mjs — worktree-anchor helpers shared by every per-mode dispatch-
 * prompt builder in this directory.
 *
 * SOURCE OF TRUTH, NOT RUNTIME CODE (issue #958)
 * -----------------------------------------------
 * This file is one of the fragments `scripts/generate-dispatch-workflow.mjs`
 * concatenates (imports stripped, `export` dropped) into the generated
 * `workflows/do-work-dispatch.workflow.js` — the single flat literal the
 * Dynamic Workflows runtime actually executes (it has no filesystem access
 * of its own, so it cannot `import` this file directly at runtime; see
 * `do-work-dispatch.core.js`'s header for the full constraint). Edit the
 * function bodies HERE, then run:
 *
 *   node plugins/shipyard/scripts/generate-dispatch-workflow.mjs
 *
 * to regenerate `do-work-dispatch.workflow.js`. `scripts/tests/
 * dispatch-workflow-generated-958.test.sh` fails CI if the checked-in
 * generated file has drifted from what regenerating these sources produces
 * — hand-editing the generated file directly (instead of this one) will be
 * caught there, not silently accepted.
 *
 * This module IS a normal, valid ES module (importable, `node --check`-able,
 * lintable in isolation) — unlike `do-work-dispatch.core.js`, which contains
 * runtime-only constructs (a top-level `return`, undeclared `agent`/
 * `parallel`/`log`/`args` globals) that only make sense once the generator
 * has assembled the full file and the Dynamic Workflows runtime is
 * interpreting it.
 */

// ===========================================================================
// Shared helper — the worktree-anchor CHECK block itself (the `cd` plus the
// git-dir-vs-git-common-dir verification). Extracted to its own function so
// EVERY per-mode builder emits the SAME text via `worktreeAnchorLines` below
// instead of each hand-maintaining its own copy — the exact "prose/generated-
// text duplicated in two places drifts" problem issue #826 closed for
// `shipyard:worker-preamble`'s two markdown sections, applied here to this
// script's builder functions (`buildIssueWorkPrompt` used to carry its own
// separate copy of both this check block AND the CALLER-BUG guard below it;
// issue #880 folded it onto `worktreeAnchorLines` like the other six
// builders, so this function now has exactly one caller).
//
// Runs the SAME script-based predicate `shipyard:worker-preamble`'s step-0
// fail-fast now uses (scripts/assert-worktree-cwd.sh) rather than inlining
// the compound `TOPLEVEL`/`GIT_DIR`/`COMMON_DIR`/`if` snippet as ONE fenced
// code block the way this helper used to. That compound shape is exactly
// what the harness's Auto Mode classifier refuses to run as a single Bash
// tool call ("too complex to verify that it stays inside the worktree; break
// it into plain, separate commands" — #826's repro) — and because this text
// is literally the FIRST instruction a Workflow-dispatched worker reads, a
// worker that pasted the old single fenced block into one Bash call would
// hit that refusal before doing anything else. Each command below is now its
// OWN fenced block, mirroring the three-separate-plain-calls discipline
// `shipyard:worker-preamble` documents for its own step-0 / mid-session
// sections (issue #802).
// ===========================================================================
export function worktreeAnchorCheckLines(worktreePath, pluginRoot) {
  const pluginRootExportLines = pluginRoot
    ? [
        '```bash',
        `export CLAUDE_PLUGIN_ROOT="${pluginRoot}"`,
        '```',
      ]
    : [
        '```bash',
        `export CLAUDE_PLUGIN_ROOT="\${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "\${M:-$R/plugins/shipyard}"; fi; fi)}"`,
        '```',
      ]
  return [
    `**Anchor to your isolated worktree FIRST, before anything else.** Run each of the`,
    `following as its OWN separate command — do not chain them with \`&&\`, a subshell,`,
    `or an inline \`if\` (that compound shape is refused — issue #826):`,
    '```bash',
    `cd "${worktreePath}"`,
    '```',
    pluginRoot
      ? `Your dispatching orchestrator already resolved CLAUDE_PLUGIN_ROOT — use this literal path directly rather than re-deriving it (issue #965):`
      : `No orchestrator-supplied plugin root was provided for this dispatch (a caller predating #965) — resolve it yourself:`,
    ...pluginRootExportLines,
    '```bash',
    `bash "\${CLAUDE_PLUGIN_ROOT}/scripts/assert-worktree-cwd.sh"`,
    '```',
    `Read the last command's stdout. \`worktree\` (exit 0) means the anchor landed`,
    `correctly — every "never cd outside your worktree" / "never git switch to the`,
    `default branch" rule in \`shipyard:worker-preamble\` applies unmodified from this`,
    `point on. \`primary\` or \`error\` (exit 1 / 2) means the anchor at ${worktreePath}`,
    `did NOT resolve to an isolated worktree (git-dir == git-common-dir, or no git`,
    `working tree at all) — stop and return a STRUCTURED result with outcome "blocked",`,
    `blocked_stage "worktree-anchor", and blocked_reason "worktree anchor at`,
    `${worktreePath} did not resolve to an isolated worktree — refusing to proceed".`,
    ``,
    `If \`scripts/assert-worktree-cwd.sh\` can't be located (an installed plugin`,
    `predating #826, or the \`CLAUDE_PLUGIN_ROOT\` resolution above comes back empty),`,
    `fall back to three separate plain calls: \`TOPLEVEL="$(git rev-parse --show-toplevel`,
    `2>/dev/null)"\`, \`GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)"\`, and`,
    `\`COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"\` as three separate`,
    `\`Bash\` calls. If GIT_DIR and COMMON_DIR canonicalize to the same path (or TOPLEVEL`,
    `came back empty), treat that as the same primary-checkout failure as above.`,
    ``,
    `Reuse this same resolved plugin-root value for the rest of the dispatch (issue #965)`,
    `— every later \`\${CLAUDE_PLUGIN_ROOT}\`-referencing call in \`shipyard:worker-preamble\``,
    `and \`agents/issue-worker/<mode>.md\` (mid-session anchoring, the CHANGELOG`,
    `monotonicity scan, the verify_gate model resolution, §6.a's ungated-admin-direct-`,
    `merge detector) can substitute the literal value directly instead of re-running a`,
    `resolution block.`,
  ]
}

// ===========================================================================
// Shared helper — the worktree-anchor preamble EVERY per-mode builder in this
// directory delegates to: a CALLER BUG guard when `worktreePath` is missing,
// otherwise the anchor-check block above. Centralized here (rather than
// copy-pasted seven times) so there is exactly one copy for
// check-dispatch-prompt-parity.mjs's CHECK 4 to keep honest, and so the
// generated do-work-dispatch.workflow.js's size stays down. `buildIssueWorkPrompt`
// used to inline its own separate copy of the CALLER-BUG guard (to fold
// `unit.number` into the diagnostic text) instead of calling this helper —
// issue #880 folded it in here instead, generalizing the guard to include the
// issue number whenever `unit.number` is set (issue-work, investigate, spike
// all carry it; the synthetic diverts fix-main-ci/fix-failing-prs-batch and
// the existing-PR modes fix-checks-only/fix-rebase don't, so they keep the
// generic "this <mode> dispatch" phrasing) rather than leaving a second
// hand-maintained copy for check-dispatch-prompt-parity.mjs to catch drifting
// back apart.
// ===========================================================================
export function worktreeAnchorLines(unit, mode) {
  if (!unit.worktreePath) {
    const label = unit.number != null ? `issue #${unit.number}` : `this ${mode} dispatch`
    const issueField = unit.number != null ? `"issue": ${unit.number}, ` : ''
    return [
      `CALLER BUG: no worktreePath was supplied for ${label}. A Dynamic-` +
        `Workflows-dispatched agent's cwd is NOT pre-pinned to an isolated worktree the ` +
        `way an Agent-tool "isolation: worktree" dispatch's is (see do-work-dispatch.` +
        `workflow.js's header comment). Return a STRUCTURED result immediately: ` +
        `{ "mode": "${mode}", "outcome": "blocked", ${issueField}` +
        `"blocked_stage": "worktree-anchor", "blocked_reason": "workflow dispatch supplied ` +
        `no worktreePath — refusing to operate from an unpinned cwd" }. Do not proceed ` +
        `past this line.`,
    ]
  }
  return worktreeAnchorCheckLines(unit.worktreePath, unit.pluginRoot)
}

#!/usr/bin/env bash
# PreToolUse hook — refuses any /shipyard:do-work worker dispatch that would run
# outside an isolated git worktree. A worker that lands in the user's primary
# checkout has caused real harm (HEAD jumping mid-session, surprise rebases on
# the wrong branch), so the guarantee is enforced mechanically, not just
# documented. The skill telling the model "always isolate the worker" is
# necessary but not sufficient; this hook makes the omission impossible to ship.
#
# TWO DISPATCH SHAPES ARE GUARDED (issue #791, the final phase of the #782
# Dynamic Workflows epic, retired the legacy `Agent`-tool dispatch path for the
# seven `mode:`-driven worker modes — but "worktree-isolated dispatch" still
# exists in both shapes, for different callers):
#
#   1. `Workflow` tool — the substrate every `mode:`-driven worker now dispatches
#      through (workflows/do-work-dispatch.workflow.js). The Dynamic Workflows
#      `agent()` primitive has NO isolation option of its own, so the ORCHESTRATOR
#      pre-provisions each worker's worktree with `git worktree add` and passes the
#      absolute path in as the work unit's `worktreePath`. A work unit dispatched
#      with no `worktreePath` would run from an unpinned cwd — the exact harm this
#      hook exists to prevent — so it is blocked here. This is the `Workflow`-tool
#      equivalent of the `isolation: "worktree"` parameter.
#
#   2. `Agent` tool — still the dispatch mechanism for the worktree-isolated
#      agents that are NOT `mode:`-driven workers, chiefly `shipyard:verify-worker`
#      (dispatched by the issue-work worker itself, not by the orchestrator's
#      per-mode routing). The seven retired mode shims stay in the guarded set as
#      defense-in-depth: their agent definitions still exist and can still be
#      dispatched by hand, and a hand dispatch needs the same guarantee.
#
# Guarded subagents on the `Agent` shape (closes #293 — the original check only
# matched the `shipyard:issue-worker` name exactly, silently passing through the
# model-pinned shims, which forward to the same per-mode specs under
# agents/issue-worker/ and need the same isolation guarantee):
#
#   shipyard:issue-worker               (mode: issue-work)
#   shipyard:fix-checks-worker          (mode: fix-checks-only — haiku)
#   shipyard:fix-rebase-worker          (mode: fix-rebase — sonnet, #854)
#   shipyard:fix-main-ci-worker         (mode: fix-main-ci — sonnet)
#   shipyard:fix-pr-batch-worker        (mode: fix-failing-prs-batch — sonnet)
#   shipyard:investigate-worker         (mode: investigate — sonnet)
#   shipyard:spike-worker               (mode: spike, added #774)
#   shipyard:verify-worker              (mode: verify — opus 4.8, added #783)
#
# Also guards the colon-namespaced form `shipyard:issue-worker:*` as
# defense-in-depth in case a future shim ever uses that scheme.
#
# Deliberately NOT guarded: the decomposition agent (see its own file under
# agents/ for why) — it never touches code and must never be dispatched with
# isolation: "worktree".
#
# Contract: read PreToolUse JSON from stdin, exit 2 + stderr to block.
# Exit 0 for any call we don't care about (different tool, different subagent,
# a `Workflow` call against some other workflow). Malformed input fails OPEN —
# a hook crash would block every dispatch.
#
# ---------------------------------------------------------------------------
# ADDITIONAL, INDEPENDENT gate layered on top of isolation (issue #1414) —
# CI-backpressure check-skipped.
# ---------------------------------------------------------------------------
# Once isolation passes for a call that fills a BACKLOG SLOT (a fresh
# mode-driven-worker dispatch — the same set the isolation guard above
# governs, MINUS shipyard:verify-worker: verify-worker is a nested,
# read-only sub-dispatch from WITHIN an already-running issue-work worker,
# not a step-C backlog-slot fill, and generates no new CI load, so it's out
# of scope for a check that exists to protect a self-hosted CI pool from
# over-dispatch), this file also runs
# scripts/assert-ci-backpressure-checked.sh --live and blocks the dispatch
# when it prints "block".
#
# That script is the mechanical backstop for steady-state.md's queue-depth
# backpressure check (issue #1156) having ACTUALLY RUN this turn — the same
# "prose the orchestrating model is expected to execute, with nothing that
# fails when it's skipped" gap the isolation guard above already closes for
# worktree isolation, applied to the backpressure hold. #1399 made a
# systematically-skipping session VISIBLE (the `ci_backpressure=` invariant-
# line token); this closes the loop by PREVENTING the skip's consequence —
# see steady-state.md's "Queue-depth backpressure check" section and
# invariant-line.md's `ci_backpressure` entry for the full mechanism.
#
# Fails OPEN on every ambiguity, per the #938 precedent (a plausible-looking
# mechanical gate that bricked the dispatch loop): an unresolvable session,
# unreadable session state, a missing script, a failed live `gh` re-read, or
# non-numeric threshold inputs all degrade to "allow" inside that script —
# never to "block". This wrapper only escalates an EXACT "block" string; a
# crashed, timed-out, or unexpected-output run of the checker is
# indistinguishable from "allow" here, by construction.
#
# ASSERT_CI_BACKPRESSURE_CHECKED_SH lets a test suite substitute a stub
# script (see hooks/tests/enforce-worktree-isolation.test.sh) rather than
# exercising the real session-state/gh-backed --live path.
run_ci_backpressure_gate() {
  local here checker
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  checker="${ASSERT_CI_BACKPRESSURE_CHECKED_SH:-${here}/../scripts/assert-ci-backpressure-checked.sh}"

  [[ -f "$checker" ]] || return 0

  local verdict
  if command -v timeout >/dev/null 2>&1; then
    verdict=$(timeout 15 bash "$checker" --live 2>/dev/null)
  else
    verdict=$(bash "$checker" --live 2>/dev/null)
  fi

  if [[ "$verdict" == "block" ]]; then
    cat >&2 <<EOF
BLOCKED by shipyard/hooks/enforce-worktree-isolation.sh (CI-backpressure
check-skipped gate, issue #1414).

This repo's CI runs on a self-hosted runner pool whose live queue depth is
over the configured backpressure threshold (ci.backpressure_multiplier),
and there is no fresh evidence this turn's step-C queue-depth backpressure
check (steady-state.md, issues #1156/#1399) actually ran. Dispatching
another backlog-slot-filling worker right now would add more CI load onto
an already-saturated pool.

Re-run steady-state.md's "Queue-depth backpressure check" block this turn
(it writes a fresh .last_backpressure_check marker as a side effect) before
retrying the dispatch. If the check legitimately produced a "hold" verdict,
either let the slot stay parked this turn, or use the CI-cheap candidate
bias (issue #1157) to pick a substitute candidate instead.

This gate fails OPEN on any ambiguity per the #938 precedent — it only
blocks when a live re-read positively confirms an over-threshold pool AND
no fresh checked/held marker exists. Docs:
commands/do-work/steady-state.md (queue-depth backpressure check),
commands/do-work/invariant-line.md (ci_backpressure token),
scripts/assert-ci-backpressure-checked.sh (the decision logic), issue #1414.
EOF
    exit 2
  fi

  return 0
}

set -u

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')

# ---------------------------------------------------------------------------
# Shape 1 — the `Workflow` tool dispatching shipyard's do-work substrate.
# ---------------------------------------------------------------------------
if [[ "$tool_name" == "Workflow" ]]; then
  # Only guard shipyard's own dispatch workflow. The tool's exact input field
  # names aren't part of a stable public contract, so match on the script
  # identifier appearing anywhere in tool_input rather than pinning a key path.
  if ! printf '%s' "$input" \
    | jq -e '((.tool_input // {}) | tostring) | test("do-work-dispatch")' >/dev/null 2>&1; then
    exit 0
  fi

  # Recursively find every work unit — an object carrying a `mode` field inside
  # some `issues` array — and collect the ones dispatched with no worktreePath.
  # Recursive descent (`..`) keeps this robust against the args payload being
  # nested one level deeper than expected.
  unisolated=$(printf '%s' "$input" | jq -r '
    [ (.tool_input // {})
      | .. | objects | select(has("issues"))
      | .issues | arrays | .[]
      | objects | select(has("mode"))
      | select((.worktreePath // "") == "")
      | .mode ]
    | join(", ")
  ' 2>/dev/null) || exit 0

  if [[ -z "$unisolated" ]]; then
    # Isolation is fine for every work unit in this call. Every mode
    # dispatched through this substrate fills a backlog slot (see this
    # file's header), so the CI-backpressure gate applies unconditionally
    # here — no subagent-type filtering needed the way Shape 2 needs it.
    run_ci_backpressure_gate
    exit 0
  fi

  cat >&2 <<EOF
BLOCKED by shipyard/hooks/enforce-worktree-isolation.sh.

You invoked the Workflow tool against do-work-dispatch.workflow.js with one or
more work units that carry no "worktreePath": ${unisolated}

The Dynamic Workflows agent() primitive has no isolation option — unlike the
Agent tool's isolation: "worktree", nothing in the workflow runtime provisions
or cwd-pins a worktree for the dispatched worker. The orchestrator MUST do it
itself before the call:

  WORKTREE_ID="agent-workflow-\$(date +%s)-\$\$"
  WORKTREE_PATH="\$(git rev-parse --show-toplevel)/.claude/worktrees/\${WORKTREE_ID}"
  git worktree add "\$WORKTREE_PATH" -b "<branch>" "origin/<default-branch>"

…then pass that absolute path as each work unit's "worktreePath". Without it the
worker runs from an unpinned cwd — in practice the user's PRIMARY checkout —
where \`git switch\`, \`git rebase\`, and \`gh pr checkout\` move the user's
terminal HEAD around mid-session. This has caused real damage.

This rule is documented in plugins/shipyard/commands/do-work/dispatch-rules.md
("Workflow-substrate dispatch for every worker mode", step 1).
EOF

  exit 2
fi

# ---------------------------------------------------------------------------
# Shape 2 — the `Agent` tool dispatching a guarded shipyard worker shim.
# ---------------------------------------------------------------------------
[[ "$tool_name" != "Agent" ]] && exit 0

subagent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty')

# Match any guarded shim. The set is small enough to inline rather than read
# from a separate registry file — the trade-off here is "one place to update
# when a new worker shim is added" vs "no extra file I/O per Agent dispatch."
# When adding a new worktree-isolated Agent-tool worker, add it here too.
case "$subagent" in
  shipyard:issue-worker | \
  shipyard:fix-checks-worker | \
  shipyard:fix-rebase-worker | \
  shipyard:fix-main-ci-worker | \
  shipyard:fix-pr-batch-worker | \
  shipyard:investigate-worker | \
  shipyard:spike-worker | \
  shipyard:verify-worker | \
  shipyard:issue-worker:* )
    ;;
  *)
    exit 0
    ;;
esac

isolation=$(printf '%s' "$input" | jq -r '.tool_input.isolation // empty')
if [[ "$isolation" == "worktree" ]]; then
  # Isolation is fine. Only a backlog-slot-filling dispatch is subject to
  # the CI-backpressure gate — shipyard:verify-worker is a nested sub-
  # dispatch, not a slot fill (see this file's header), so it's excluded.
  if [[ "$subagent" != "shipyard:verify-worker" ]]; then
    run_ci_backpressure_gate
  fi
  exit 0
fi

cat >&2 <<EOF
BLOCKED by shipyard/hooks/enforce-worktree-isolation.sh.

You dispatched subagent_type "${subagent}" without
isolation: "worktree". That would run the agent inside the user's PRIMARY
checkout instead of an isolated git worktree — \`git switch\`, \`git rebase\`,
and \`gh pr checkout\` inside the agent would move the user's terminal HEAD
around mid-session. This has caused real damage; the orchestrator must
never make this mistake.

Re-dispatch with isolation: "worktree" added to the Agent call. The
harness will provision an isolated worktree under .claude/worktrees/agent-<id>/
and run the agent there.

(The seven \`mode:\`-driven worker modes are dispatched through the Workflow
substrate now — see workflows/do-work-dispatch.workflow.js and this hook's
Workflow branch — but their shims remain guarded here for hand dispatches.)

This rule is documented in plugins/shipyard/commands/do-work.md
(Setup §7, Dispatch rules, and the "Don't" list).
EOF

exit 2

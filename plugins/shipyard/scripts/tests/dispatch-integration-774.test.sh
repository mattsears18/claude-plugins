#!/usr/bin/env bash
# Test: orchestrator dispatch-site integration for the decompose-worker (#772)
# and spike-worker (#773) agent modes — issue #774.
#
# Background
# ----------
# #772 and #773 each added a first-class, registered agent shim
# (agents/decompose-worker.md, agents/spike-worker.md + its per-mode spec
# agents/issue-worker/spike.md) but both explicitly scoped out the runtime
# wiring that would make /do-work actually route to them:
#
#   - decompose-worker existed, but /decompose-epic's own bulk dispatch and
#     /do-work's inline auto-decompose path (setup/06-scope-preflight.md)
#     still dispatched an anonymous `general-purpose` subagent with the
#     decomposition template inlined, rather than the registered agent.
#   - spike-worker existed with a full per-mode spec, but nothing in
#     commands/do-work/dispatch-rules.md or steady-state.md recognized a
#     spike-shaped issue, routed it to `mode: spike` / shipyard:spike-worker,
#     or reconciled its spiked+shipped / spiked+needs-human-review returns.
#     It was reachable only via manual, explicit dispatch.
#
# This is the #774 slice: it wires both. This test is the regression guard —
# if anyone reverts the subagent_type from shipyard:decompose-worker back to
# general-purpose, drops the spike-shape detection branch, forgets to guard
# shipyard:spike-worker in the isolation hook, or drops the spike-work
# reconcile handling from steady-state.md's A.1, the test fails.
#
# It also guards the inverse: shipyard:decompose-worker must NEVER be added
# to the mode-routing table or the isolation hook's guarded set — that would
# contradict decompose-worker.md's own documented (and unchanged-by-#774)
# no-worktree contract.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/dispatch-integration-774.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

issue_worker_path="$repo_root/plugins/shipyard/agents/issue-worker.md"
dispatch_rules_path="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
# 06-scope-preflight.md was further split into 06/06b/06c (issue #994) once it
# grew past the per-Read token cap on its own. The inline auto-decompose
# dispatch text this suite checks now lives in 06c-scope-handling-ui.md.
# scope_preflight_router_path is the canonical filename (for the file-exists
# check below); scope_preflight_path is a concatenation of all three sub-files
# so the content assertions keep finding the wiring regardless of which
# sub-file it lives in.
scope_preflight_router_path="$repo_root/plugins/shipyard/commands/do-work/setup/06-scope-preflight.md"
scope_preflight_path="$(mktemp -t dispatch-integration-774-scope-preflight-concat.XXXXXX)"
cat "$scope_preflight_router_path" \
  "$repo_root/plugins/shipyard/commands/do-work/setup/06b-scope-carveouts.md" \
  "$repo_root/plugins/shipyard/commands/do-work/setup/06c-scope-handling-ui.md" \
  > "$scope_preflight_path" 2>/dev/null
trap 'rm -f "$scope_preflight_path"' EXIT
decompose_epic_path="$repo_root/plugins/shipyard/commands/decompose-epic.md"
spike_worker_path="$repo_root/plugins/shipyard/agents/spike-worker.md"
decompose_worker_path="$repo_root/plugins/shipyard/agents/decompose-worker.md"
mode_shim_preamble_path="$repo_root/plugins/shipyard/skills/mode-shim-preamble/SKILL.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    missing: %s\n' "$path"
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s:\n    %s\n' "$file" "$needle"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if [[ ! -f "$file" ]] || ! grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    did NOT expect to find in %s:\n    %s\n' "$file" "$needle"
  fi
}

for f in "$issue_worker_path" "$dispatch_rules_path" "$steady_state_path" \
         "$scope_preflight_router_path" "$decompose_epic_path" "$spike_worker_path" "$decompose_worker_path" \
         "$mode_shim_preamble_path"; do
  assert_file_exists "$f" "$(basename "$f") exists"
done

echo
echo "== (A) agents/issue-worker.md — spike is a 7th routed mode; decompose is explicitly NOT"

assert_contains "$issue_worker_path" "| \`spike\`" \
  "mode-routing table has a spike row"
assert_contains "$issue_worker_path" "issue-worker/spike.md" \
  "spike row points at issue-worker/spike.md"
assert_contains "$issue_worker_path" "shipyard:spike-worker" \
  "spike row's dispatched shim is shipyard:spike-worker"
assert_contains "$issue_worker_path" "7 mutually-exclusive jobs" \
  "entry file's job count updated from 6 to 7"
assert_contains "$issue_worker_path" "shipyard:decompose-worker" \
  "entry file documents shipyard:decompose-worker as a related-but-excluded agent"
# The full decompose-worker carve-out explanation (including the "does NOT get
# a routing-table row" wording) lives in shipyard:mode-shim-preamble as of
# issue #879's dedup — issue-worker.md's Worktree isolation contract section
# now just points at it rather than re-stating it. Check it there instead.
assert_contains "$mode_shim_preamble_path" "shipyard:decompose-worker" \
  "mode-shim-preamble skill documents shipyard:decompose-worker as a related-but-excluded agent"
assert_contains "$mode_shim_preamble_path" "not an eighth row" \
  "mode-shim-preamble skill is explicit that decompose-worker does NOT get a mapping-table row"

echo


echo
echo "== (C) dispatch-rules.md — spike routing table row"

# #791 retired the Agent-tool `subagent_type` column from this table (the
# Workflow substrate's agent() primitive takes no subagent_type), so the spike
# row now identifies its per-mode SPEC rather than a shim name. The guard is
# unchanged in substance: dispatch-rules.md must carry a spike row that routes
# to the spike spec and justifies its model tier.
assert_contains "$dispatch_rules_path" "issue-worker/spike.md" \
  "per-mode routing table's spike row points at the spike per-mode spec"
assert_contains "$dispatch_rules_path" "Feasibility judgment + design-doc authorship" \
  "per-mode routing table gives a model-choice rationale for the spike row"

echo
echo "== (D) dispatch-rules.md — spike-shape detection at the ready_issues dispatch site"

assert_contains "$dispatch_rules_path" "Spike-shape detection" \
  "dispatch-rules.md documents a spike-shape detection step"
assert_contains "$dispatch_rules_path" "mode: spike" \
  "dispatch-rules.md's spike prompt template names mode: spike"
assert_contains "$dispatch_rules_path" "spike" \
  "dispatch-rules.md mentions the spike label as a detection signal"
assert_contains "$dispatch_rules_path" "decompose.max_subissues" \
  "dispatch-rules.md's spike prompt reads the decompose.max_subissues fan-out cap"
assert_contains "$dispatch_rules_path" "spiked+shipped" \
  "dispatch-rules.md's spike prompt template documents the spiked+shipped return value"

echo
echo "== (E) dispatch-rules.md — decompose-worker wiring documented, never added as a routed mode"

assert_contains "$dispatch_rules_path" "Wiring \`shipyard:decompose-worker\`" \
  "dispatch-rules.md has a section documenting the decompose-worker wiring"
assert_contains "$dispatch_rules_path" "intentionally absent from this table" \
  "dispatch-rules.md states shipyard:decompose-worker is absent from the per-mode routing table"

echo
echo "== (F) setup/06-scope-preflight.md — inline auto-decompose now targets shipyard:decompose-worker"

assert_contains "$scope_preflight_path" 'subagent_type: "shipyard:decompose-worker"' \
  "inline auto-decompose dispatch uses subagent_type: \"shipyard:decompose-worker\""
assert_not_contains "$scope_preflight_path" 'subagent_type: "general-purpose"' \
  "inline auto-decompose dispatch no longer uses subagent_type: \"general-purpose\""
assert_contains "$scope_preflight_path" "the worker only reads the codebase read-only and calls the GitHub API" \
  "inline auto-decompose dispatch still documents the no-worktree rationale"

echo
echo "== (G) commands/decompose-epic.md — bulk dispatch now targets shipyard:decompose-worker"

assert_contains "$decompose_epic_path" 'subagent_type: "shipyard:decompose-worker"' \
  "decompose-epic.md's bulk dispatch uses subagent_type: \"shipyard:decompose-worker\""
assert_not_contains "$decompose_epic_path" 'subagent_type: "general-purpose"' \
  "decompose-epic.md's bulk dispatch no longer uses subagent_type: \"general-purpose\""

echo
echo "== (H) steady-state.md — A.1 reconciles the spike-work return contract"

assert_contains "$steady_state_path" "For **spike work**" \
  "steady-state.md has a dedicated spike-work reconcile section"
assert_contains "$steady_state_path" "spiked+shipped" \
  "steady-state.md reconciles the spiked+shipped return"
assert_contains "$steady_state_path" "spiked+needs-human-review" \
  "steady-state.md reconciles the spiked+needs-human-review return"
assert_contains "$steady_state_path" "spike-worker shipped" \
  "steady-state.md's session_prs description includes spike-worker shipped"

echo
echo "== (I) spike-worker.md — self-description reflects that dispatch-site routing IS wired"

assert_not_contains "$spike_worker_path" "Dispatch-site routing is not yet wired" \
  "spike-worker.md no longer claims routing is unwired"
assert_contains "$spike_worker_path" "dispatch-rules.md" \
  "spike-worker.md points at dispatch-rules.md for the routing logic"

echo
echo "== (J) decompose-worker.md — still documents the no-worktree contract unchanged by #774"

assert_contains "$decompose_worker_path" "deliberately carries no \`isolation:\` frontmatter field" \
  "decompose-worker.md still documents its worktree-isolation exemption"
assert_contains "$decompose_worker_path" "out of scope" \
  "decompose-worker.md still scopes out a mode-routing-table row for itself"

echo
printf 'passed: %d  failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1

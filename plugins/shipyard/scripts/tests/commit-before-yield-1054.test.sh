#!/usr/bin/env bash
# Test: a mode-agnostic "commit locally-verified work before any yield point"
# invariant lives in shipyard:worker-preamble's always-loaded core (#1054).
#
# Background
# ----------
# #1054 is a sixth confirmed instance of the same failure class already
# closed five times: #813, #529, #753, #707, #838. An `issue-work` worker
# opened a `Monitor` sub-task mid-implementation, before ever running
# `git commit`, then returned the narrative non-terminal
# "I'll wait for the Monitor's notification before continuing." — stranding
# a complete, correct diff as uncommitted working-tree changes. The
# orchestrator's steady-state.md A.0.5 inspect-before-reap + resume-the-
# same-agent contract caught it and recovered the work, but at the cost of
# a full extra dispatch cycle.
#
# The staleness probe for this issue confirmed the five prior fixes are
# live and correctly scoped: #529/#813 forbid arming a background process
# and returning before it resolves; #753 forbids opening your own Monitor/
# poll loop to watch CI; #707 forbids gating the commit/push/PR-open on a
# CI result; #838 is the orchestrator-side "never reap a stalled worker's
# worktree before inspecting it" contract. Every worker-side rule frames
# the prohibition around a specific trigger (a CI watch, a background test-
# waiter, gating a commit on CI) — none of them said "commit first" as a
# standalone, mode-agnostic gate independent of *why* you're about to
# yield. That's the actual gap #1054 diagnoses.
#
# The fix: a new bullet in shipyard:worker-preamble's SKILL.md core (loaded
# unconditionally by every mode, not an on-demand fragment) stating the
# commit-before-yield invariant, citing #1054, naming `issue-work`
# explicitly as covered, and generalizing #707's CI-watch-specific
# statement to "any yield point" (Monitor, background Bash, or otherwise).
# agents/issue-worker/issue-work.md itself was left untouched — it sits at
# 115926 of a 116000-byte ceiling with ~74 bytes of headroom, no room for
# meaningful growth — and it already cross-references #529/#707/#753 by
# name at its own step-8 return contract, so it doesn't need a new bullet
# to be "covered."
#
# The orchestrator-side recovery contract that caught this session's
# incident (steady-state.md A.0.5) is unchanged and unweakened; the only
# addition there is a purely additive canned resume-message template so
# future recoveries are deterministic rather than improvised per incident.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/commit-before-yield-1054.test.sh

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

skill_path="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"
issue_work_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s (file missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail + 1))
    return
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s (did not find %q in %s)\n' "$RED" "$RESET" "$label" "$needle" "$path"
    fail=$((fail + 1))
  fi
}

assert_under() {
  local path="$1" ceiling="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s (file missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail + 1))
    return
  fi
  local size
  size=$(wc -c < "$path" | tr -d ' ')
  if (( size <= ceiling )); then
    printf '  %sPASS%s  %s (%d bytes, ceiling %d)\n' "$GREEN" "$RESET" "$label" "$size" "$ceiling"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s (%d bytes exceeds %d-byte ceiling)\n' "$RED" "$RESET" "$label" "$size" "$ceiling"
    fail=$((fail + 1))
  fi
}

echo "== commit-before-yield-1054.test.sh =="

# --- The new invariant lives in worker-preamble's core, cites #1054 ---
assert_contains "$skill_path" "Commit-before-yield invariant" \
  "SKILL.md core names the commit-before-yield invariant"
assert_contains "$skill_path" "#1054" \
  "SKILL.md core cites #1054"
assert_contains "$skill_path" "https://github.com/mattsears18/shipyard/issues/1054" \
  "SKILL.md core links the #1054 issue"

# --- Generalizes #707 to "any yield point", not just CI-watch ---
assert_contains "$skill_path" "every yield point" \
  "SKILL.md states the rule applies to every yield point, not only CI-watch"
assert_contains "$skill_path" "#707 below states this for the CI-watch case only" \
  "SKILL.md explicitly frames the new rule as a generalization of #707"

# --- Names issue-work explicitly as covered ---
assert_contains "$skill_path" "This covers \`issue-work\` as much as any CI-watch mode" \
  "SKILL.md names issue-work explicitly as covered by the invariant"

# --- Recurrence context: names all five prior closed issues ---
assert_contains "$skill_path" "recurrence of #813/#529/#753/#707/#838" \
  "SKILL.md documents this as a recurrence of the five prior closes"

# --- The rule is in the always-loaded core section (Return-contract discipline), not a fragment ---
assert_contains "$skill_path" "## Return-contract discipline" \
  "SKILL.md still has the Return-contract discipline core section"
# Assert the new bullet's line number falls before the "## On-demand fragments"
# heading — i.e. it lives in the eagerly-loaded core, not a fragment pointer.
if [[ -f "$skill_path" ]]; then
  invariant_line=$(grep -n "Commit-before-yield invariant" "$skill_path" | head -1 | cut -d: -f1)
  fragments_line=$(grep -n "^## On-demand fragments" "$skill_path" | head -1 | cut -d: -f1)
  if [[ -n "$invariant_line" && -n "$fragments_line" && "$invariant_line" -lt "$fragments_line" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "commit-before-yield bullet precedes the On-demand fragments index (i.e. lives in the core)"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "commit-before-yield bullet precedes the On-demand fragments index (i.e. lives in the core)"
    fail=$((fail + 1))
  fi
else
  printf '  %sFAIL%s  %s (file missing)\n' "$RED" "$RESET" "commit-before-yield bullet precedes the On-demand fragments index"
  fail=$((fail + 1))
fi

# --- issue-work.md was deliberately left untouched (no headroom) but still
#     cross-references the prior rules by name, so issue-work workers are
#     covered without growing the file. ---
assert_contains "$issue_work_path" "Return synchronously — never arm a background process and return" \
  "issue-work.md still carries its own #529 cross-reference"
assert_contains "$issue_work_path" "Your terminal state was reached at \"local gates green, PR opened, auto-merge armed\"" \
  "issue-work.md still carries its own #707 cross-reference"

# --- Both always-loaded files stay under their spec-size-budget.test.sh
#     ceilings. These literals mirror spec-size-budget.test.sh's own
#     assert_under_budget calls — that file is the canonical source for the
#     ceiling values and their raise history; keep these two in sync with it
#     whenever a ceiling changes there (most recently 59000 -> 60000 by
#     #1135, 116000 -> 120000 by #1088, and 120000 -> 121000 by #1166). ---
assert_under "$skill_path" 60000 "SKILL.md stays under its 60000-byte ceiling"
assert_under "$issue_work_path" 121000 "issue-work.md stays under its 121000-byte ceiling"

# --- Orchestrator-side canned resume-message template (item 4, optional) ---
assert_contains "$steady_state_path" "Canned resume-message template" \
  "steady-state.md A.0.5 gained a canned resume-message template"
assert_contains "$steady_state_path" "#1054" \
  "steady-state.md's resume template cites #1054"
# The pre-existing recovery contract this issue asked NOT to be weakened
# must still be present verbatim.
assert_contains "$steady_state_path" "Resume the SAME agent when one is live and addressable; otherwise re-enter the SAME worktree with a fresh call." \
  "steady-state.md still preserves the resume-the-same-agent recovery contract"
assert_contains "$steady_state_path" "**Pre-reap recovery check — save committed and uncommitted work before discarding the worktree" \
  "steady-state.md still preserves the pre-reap recovery check"

printf '\n'
if [[ "$fail" -eq 0 ]]; then
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
else
  printf '%sFAIL%s  %d passed, %d failed\n' "$RED" "$RESET" "$pass" "$fail"
  exit 1
fi

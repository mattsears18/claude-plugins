#!/usr/bin/env bash
# Test: issue-work.md's branch checkout is folded into an early, mandatory
# step — no ordering in which "read the issue -> start editing" can precede
# it (issue #1334).
#
# Background
# ----------
# #1258 added a *check* (assert-branch-switched.sh) as the first action of
# step 4 ("Implement") — hard-stop before the first Edit/Write if the
# worktree is still on the harness placeholder branch (`worktree-agent-
# <id>`). #1334's repro showed a worker can still slip past a check it
# never reaches on its own: it implemented and committed onto the
# placeholder branch, self-corrected before pushing, but nothing
# structural stopped it — the check confirmed the cleanup, it didn't
# prevent the slip.
#
# The gap #1334 diagnoses isn't that the check is wrong, it's *when* the
# branch actually gets created. Step 3 ("Sync + branch") sat several
# paragraphs downstream of step 1 (self-assign) and step 2 (read the
# issue) — exactly the codebase-research phase where a worker's attention
# drifts from checklist-following into task flow. The fix: a new step 0.6
# that runs step 3's checkout immediately after step 0.5 (the last
# pre-flight step), before step 1 or step 2 — closing the drift window by
# construction instead of only detecting it after the fact. Step 3's own
# numbered position, and the step 4 backstop check, are both left in place
# (external cross-references, #1270's "51 references" concern) — this
# suite asserts the ORDERING is real, not just documented.
#
# A PreToolUse hook (mirroring enforce-worktree-isolation.sh, the issue's
# suggestion 1) was considered and rejected for this fix — see the raise-
# history comment in spec-size-budget.test.sh for the full reasoning: the
# Edit/Write/Bash PreToolUse payload carries no signal distinguishing a
# `/do-work` worker's isolated worktree from any other `Agent`-tool
# `isolation: "worktree"` dispatch, which lands on an identical
# `worktree-agent-<id>` branch. A hook blocking Edit/Write while on that
# branch name alone would false-positive-block every generic isolated-
# agent task that legitimately never renames its branch (this repo's own
# CLAUDE.md recommends that pattern broadly, not just for do-work) — the
# same concern #1270 raised when it first rejected this mechanism, widened
# here to cover generic Agent-tool dispatches, not just other one-off
# worktree tasks.
#
# Pure bash + grep, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/branch-checkout-ordering-1334.test.sh

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

issue_work_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"

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

echo "== branch-checkout-ordering-1334.test.sh =="

if [[ ! -f "$issue_work_path" ]]; then
  echo "FAIL: issue-work.md not found at $issue_work_path" >&2
  exit 1
fi

# --- The new step exists, cites #1334, and instructs running step 3 now ---
assert_contains "$issue_work_path" "### 0.6 Branch — run step 3 now, before self-assign or reading the issue" \
  "step 0.6 heading exists"
assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/1334" \
  "issue-work.md links the #1334 issue"
assert_contains "$issue_work_path" "Jump to [step 3 \"Sync + branch\"](#3-sync--branch) and execute it in full right now" \
  "step 0.6 instructs jumping to step 3 immediately"

# --- Ordering: step 0.6 must appear BEFORE step 1 (self-assign) and BEFORE
# step 2 (read the issue) in the file's physical byte order, not merely in
# its numbered label. This is the load-bearing assertion — a numbered
# heading that says "0.6" but was accidentally left positioned after step 1
# would silently reopen the exact drift window #1334 closes.
step_06_line=$(grep -n "^### 0.6 Branch" "$issue_work_path" | head -1 | cut -d: -f1)
step_1_line=$(grep -n "^### 1\. Self-assign" "$issue_work_path" | head -1 | cut -d: -f1)
step_2_line=$(grep -n "^### 2\. Read the issue carefully" "$issue_work_path" | head -1 | cut -d: -f1)
step_3_line=$(grep -n "^### 3\. Sync + branch" "$issue_work_path" | head -1 | cut -d: -f1)
step_4_line=$(grep -n "^### 4\. Implement" "$issue_work_path" | head -1 | cut -d: -f1)

if [[ -n "$step_06_line" && -n "$step_1_line" && "$step_06_line" -lt "$step_1_line" ]]; then
  printf '  %sPASS%s  step 0.6 (line %s) physically precedes step 1 (line %s)\n' "$GREEN" "$RESET" "$step_06_line" "$step_1_line"
  pass=$((pass + 1))
else
  printf '  %sFAIL%s  step 0.6 does not physically precede step 1 (0.6=%s, step1=%s)\n' "$RED" "$RESET" "${step_06_line:-<missing>}" "${step_1_line:-<missing>}"
  fail=$((fail + 1))
fi

if [[ -n "$step_06_line" && -n "$step_2_line" && "$step_06_line" -lt "$step_2_line" ]]; then
  printf '  %sPASS%s  step 0.6 (line %s) physically precedes step 2 (line %s)\n' "$GREEN" "$RESET" "$step_06_line" "$step_2_line"
  pass=$((pass + 1))
else
  printf '  %sFAIL%s  step 0.6 does not physically precede step 2 (0.6=%s, step2=%s)\n' "$RED" "$RESET" "${step_06_line:-<missing>}" "${step_2_line:-<missing>}"
  fail=$((fail + 1))
fi

# step 3 and step 4 stay in their existing numbered position (after step 2) —
# this fix intentionally does NOT renumber the file (#1270's "51 external
# cross-references" concern), it only adds an earlier pointer.
if [[ -n "$step_2_line" && -n "$step_3_line" && "$step_2_line" -lt "$step_3_line" && -n "$step_4_line" && "$step_3_line" -lt "$step_4_line" ]]; then
  printf '  %sPASS%s  step 3 and step 4 remain in their original numbered position (2 < 3 < 4)\n' "$GREEN" "$RESET"
  pass=$((pass + 1))
else
  printf '  %sFAIL%s  step 3/step 4 physical ordering regressed (step2=%s step3=%s step4=%s)\n' "$RED" "$RESET" "${step_2_line:-<missing>}" "${step_3_line:-<missing>}" "${step_4_line:-<missing>}"
  fail=$((fail + 1))
fi

# --- Step 4's assert-branch-switched.sh checkpoint is still present as a
# backstop — this fix must not remove #1258's original defense-in-depth.
assert_contains "$issue_work_path" "assert-branch-switched.sh" \
  "step 4 still invokes assert-branch-switched.sh (backstop retained)"
assert_contains "$issue_work_path" "this checkpoint is the backstop for the rare path where it didn't" \
  "step 4's framing describes itself as the backstop, not the primary defense"

# --- The Don't-list bullet points at the new early checkpoint ---
assert_contains "$issue_work_path" "Run [step 0.6]" \
  "Don't-list bullet points at step 0.6 as the primary defense"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]

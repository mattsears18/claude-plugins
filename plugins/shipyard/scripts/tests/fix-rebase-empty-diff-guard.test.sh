#!/usr/bin/env bash
# Test: the fix-rebase worker contract documents a post-rebase empty-diff
# guard that bails (instead of force-pushing) when the conflict resolution
# silently dropped the PR's substantive change, collapsing the branch to an
# empty diff vs base.
#
# Background — issue #646: a `shipyard:fix-rebase-worker` dispatched against
# a DIRTY PR resolved a same-line provenance conflict by taking main's side
# WHOLESALE (a whole-file `--theirs`, which also discarded the PR's
# non-conflicting substantive hunk in the same file). The net diff vs base
# went empty, the force-push auto-closed the PR (GitHub auto-closes a PR
# whose head force-pushes to an empty-diff state), and the worker returned
# `rebased #<M>` (success) — so the shipped work was lost with NO `blocked`
# signal. Repro (session do-work-20260627T202012Z-45017): lightwork PR
# #2165 force-pushed to an empty diff, auto-closed, issue #2116 reverted to
# OPEN, the change had to be redone from scratch (new PR #2175).
#
# The fix adds:
#   (1) a §5.7 post-rebase empty-diff guard (the root fix) that compares the
#       PR's net contribution vs base before vs after the rebase and bails
#       with `blocked rebase #<M>: rebase produced an empty diff ...` when a
#       previously-non-empty change went empty — placed BEFORE the §6
#       force-push so the empty-diff branch is never pushed; and
#   (2) a step-4 hunk-level resolution rule forbidding whole-file
#       `git checkout --theirs/--ours <file>` (the proximate cause), with the
#       §4.6 coordinated-manifest path carved out as the one safe exception.
#
# This test is the regression guard: if either guard is removed or its
# load-bearing semantics (the bail string, the pre/post diff comparison, the
# before-force-push placement, the whole-file-checkout prohibition) regress,
# the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/fix-rebase-empty-diff-guard.test.sh

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

fix_rebase_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

assert_section_ordering() {
  local file="$1"
  local before="$2"
  local after="$3"
  local label="$4"
  local before_line after_line
  before_line=$(grep -nF -- "$before" "$file" | head -1 | cut -d: -f1)
  after_line=$(grep -nF -- "$after" "$file" | head -1 | cut -d: -f1)
  if [[ -z "$before_line" ]]; then
    printf '  %sFAIL%s  %s (could not find before-marker: %s)\n' "$RED" "$RESET" "$label" "$before"
    fail=$((fail+1))
    return
  fi
  if [[ -z "$after_line" ]]; then
    printf '  %sFAIL%s  %s (could not find after-marker: %s)\n' "$RED" "$RESET" "$label" "$after"
    fail=$((fail+1))
    return
  fi
  if (( before_line < after_line )); then
    printf '  %sPASS%s  %s (before @ line %d, after @ line %d)\n' "$GREEN" "$RESET" "$label" "$before_line" "$after_line"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected before-marker before after-marker; got before @ %d, after @ %d)\n' "$RED" "$RESET" "$label" "$before_line" "$after_line"
    fail=$((fail+1))
  fi
}

echo "fix-rebase empty-diff guard regression tests (issue #646)"
echo

# (0) The fix-rebase spec must exist.
assert_file_exists "$fix_rebase_path" "agents/issue-worker/fix-rebase.md exists"

# The needles below are literal substrings of the markdown spec; the `$DEFAULT_BRANCH`
# / `$HEAD_REF` / `$vc_manifest` tokens are meant to be matched verbatim (they are
# documented shell-variable references inside the spec's code blocks), so single
# quotes are correct and SC2016's "did you mean to expand" does not apply.
# shellcheck disable=SC2016
if [[ -f "$fix_rebase_path" ]]; then
  # (1) §5.7 post-rebase empty-diff guard — the root fix.
  assert_contains "$fix_rebase_path" "5.7. **Post-rebase empty-diff guard" \
    "fix-rebase.md adds a §5.7 Post-rebase empty-diff guard (issue #646)"
  assert_contains "$fix_rebase_path" "https://github.com/mattsears18/shipyard/issues/646" \
    "fix-rebase.md links to the originating issue #646"
  assert_contains "$fix_rebase_path" "rebase produced an empty diff (conflict resolution dropped the PR's change) — needs manual rebase" \
    "fix-rebase.md documents the canonical empty-diff bail string"
  assert_contains "$fix_rebase_path" "blocked rebase #<M>:" \
    "fix-rebase.md uses the blocked rebase #<M>: return format"

  # (2) The guard must compare pre- vs post-rebase net contribution. The
  # load-bearing mechanism is comparing the pre-rebase head (origin/\$HEAD_REF,
  # untouched until the §6 force-push) against the rebased HEAD, both vs base.
  # As of issue #1336 that comparison runs as a standalone script invocation
  # rather than an inline snippet — see (6) below for why.
  assert_contains "$fix_rebase_path" 'scripts/assert-rebase-diff-nonempty.sh" "origin/$DEFAULT_BRANCH" "origin/$HEAD_REF"' \
    "fix-rebase.md invokes assert-rebase-diff-nonempty.sh with base + pre-rebase head"
  assert_contains "$fix_rebase_path" "Never force-push a branch whose net change vs base vanished" \
    "fix-rebase.md states the never-force-push-an-empty-diff rule"

  # (3) The guard MUST be placed AFTER §5.6 (CHANGELOG monotonicity) and
  # BEFORE §6 (the force-push). Placing it after the push would defeat it —
  # the empty-diff branch would already have auto-closed the PR.
  assert_section_ordering "$fix_rebase_path" \
    "5.6. **Assert no released CHANGELOG headings were deleted" \
    "5.7. **Post-rebase empty-diff guard" \
    "§5.7 lands after §5.6 CHANGELOG monotonicity assertion"
  assert_section_ordering "$fix_rebase_path" \
    "5.7. **Post-rebase empty-diff guard" \
    "6. **Push the rebased branch.**" \
    "§5.7 lands before §6 (the force-push)"

  # (4) Step-4 hunk-level resolution rule — the proximate-cause fix. A
  # whole-file --theirs/--ours discards the PR's non-conflicting hunks.
  assert_contains "$fix_rebase_path" 'never `git checkout --theirs/--ours <file>` on a whole file' \
    "fix-rebase.md forbids whole-file --theirs/--ours resolution (issue #646)"
  assert_contains "$fix_rebase_path" "Resolve at the hunk level" \
    "fix-rebase.md states the hunk-level resolution rule"

  # (5) The §4.6 coordinated-manifest path must remain carved out as the one
  # safe exception — the rule must not contradict §4.6's checkout --theirs.
  assert_contains "$fix_rebase_path" 'a `git checkout --theirs "$vc_manifest"` followed by a single `jq`-set of the version row is safe' \
    "fix-rebase.md carves out §4.6 coordinated-manifest as the safe whole-file-checkout exception"

  # (6) Issue #1336 — the guard must NOT be prescribed as the original inline
  # snippet. Two reproduced failures compound there: the git-command-
  # substitutions-plus-inline-`if` shape is deterministically refused by the
  # harness's worktree-isolation Bash guard (the #802 refusal class, and
  # fix-rebase workers are always worktree-isolated), and the refusal's own
  # remediation — "break it into plain, separate commands" — lands on a bare
  # `git diff --name-only <refs> | wc -l` single-call shape that a
  # diff-rewriting shell proxy (#1333) makes return 1 for a genuinely-empty
  # diff. With POST_FILES stuck at 1 the `== 0` bail can never fire, silently
  # disabling this guard for exactly the #646 case it exists to catch.
  assert_not_contains "$fix_rebase_path" 'PRE_FILES=$(git diff --name-only' \
    "fix-rebase.md no longer inlines the PRE_FILES wc -l pipeline (issue #1336)"
  assert_not_contains "$fix_rebase_path" 'POST_FILES=$(git diff --name-only' \
    "fix-rebase.md no longer inlines the POST_FILES wc -l pipeline (issue #1336)"
  assert_contains "$fix_rebase_path" "https://github.com/mattsears18/shipyard/issues/1336" \
    "fix-rebase.md links to issue #1336 for why the guard is a script, not an inline snippet"

  # The exit-2 INDETERMINATE result must be handled as a bail, never a pass —
  # the "an absence-assertion that observed nothing is not a pass" rule.
  assert_contains "$fix_rebase_path" "Treat exactly like exit 1 — never as a pass" \
    "fix-rebase.md treats the script's INDETERMINATE exit 2 as a bail, not a pass"
fi

# (7) The script the spec delegates to must actually exist and be executable.
assert_file_exists "$repo_root/plugins/shipyard/scripts/assert-rebase-diff-nonempty.sh" \
  "scripts/assert-rebase-diff-nonempty.sh exists (issue #1336)"
if [[ -x "$repo_root/plugins/shipyard/scripts/assert-rebase-diff-nonempty.sh" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "scripts/assert-rebase-diff-nonempty.sh has the exec bit set"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "scripts/assert-rebase-diff-nonempty.sh has the exec bit set"
  fail=$((fail+1))
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

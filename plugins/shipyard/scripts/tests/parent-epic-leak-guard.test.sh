#!/usr/bin/env bash
# Test: the issue-work worker contract documents a post-PR-create guard that
# stops a child PR from silently auto-closing a "do NOT close" parent epic it
# was told only to *reference*.
#
# Background — issue #624: when an issue-work dispatch is told to reference a
# parent epic but NOT close it, GitHub can still promote a bare `#<E>` token
# (in the PR body, a squashed-commit message, or a CHANGELOG entry that rides
# the merge) into the PR's `closingIssuesReferences` — so merging the PR
# auto-closes the epic, even though no closing keyword was ever written.
# Observed twice: PR #621 carried only "Part of #613" / "Does NOT close #613"
# bare phrasing yet GitHub added #613 to closingIssuesReferences and the merge
# closed epic #613; PR #623 also leaked #613 on create and the worker only
# caught it because the orchestrator had hand-rolled a closingIssuesReferences
# check into that dispatch prompt.
#
# The fix makes the guard intrinsic to the worker contract (not dependent on a
# dispatch-prompt instruction) by adding §5.85 to
# `agents/issue-worker/issue-work.md`:
#   - When a non-close parent/epic relationship is in scope, after `gh pr
#     create` assert the epic is absent from `closingIssuesReferences`.
#   - If it leaked: rewrite the PR body to reference the epic by bare URL (not
#     a `#<n>` token), re-verify, and reopen the epic if the PR already merged.
#   - Document the real trigger (bare `#N` tokens + commit/CHANGELOG mentions,
#     NOT only closing keywords) and the bare-URL mitigation.
#
# Updated for issue #980: §5.85's full verification-and-remediation procedure
# (the three-tier escalation, the branch-naming prevention, the reopen-on-
# merge logic) now lives in an on-demand fragment,
# `agents/issue-worker/issue-work-parent-epic-leak.md`, loaded only when the
# trigger condition fires — issue-work.md itself keeps only the load-bearing
# trigger condition and a pointer to the fragment (part of the thin-router
# split that cut the always-loaded worker-spec floor). This suite now checks
# the detailed procedure against the fragment and checks issue-work.md for
# the trigger + pointer + section-ordering contract.
#
# This is the inverse of issue #481 (a resolving PR leaving its own issue stuck
# OPEN); here a non-resolving mention silently CLOSES an epic it should only
# reference.
#
# This test is the regression guard: if the §5.85 guard is removed or its
# load-bearing semantics regress, the test fails.
#
# Extended for issue #893: a live dispatch found the single
# rewrite-and-reverify loop above did NOT reliably clear a leaked
# closingIssuesReferences entry — it survived a PR-body rewrite, a
# commit-message rewrite + force-push, and a full close+reopen. The only
# thing that cleared it was abandoning the branch/PR entirely and reopening
# from a neutrally-named branch (not the `do-work/issue-<N>`-shaped one),
# consistent with a branch-name-based auto-link independent of body/commit
# text. §5.85 now documents a three-tier escalation (body rewrite → commit
# message rewrite → abandon-and-reopen-from-neutral-branch) instead of a
# single-shot rewrite, plus a prevention callout: never name a
# deliberately-non-closing PR's branch `do-work/issue-<E>`-shaped in the
# first place.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/parent-epic-leak-guard.test.sh

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
fragment_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work-parent-epic-leak.md"
fix_checks_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"
fix_rebase_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"
fix_main_ci_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-main-ci.md"
fix_failing_prs_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-failing-prs-batch.md"

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
  if ! grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
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

echo "parent-epic leak guard regression tests (issue #624)"
echo

# (1) The issue-work spec must exist.
assert_file_exists "$issue_work_path" "agents/issue-worker/issue-work.md exists"

if [[ -f "$issue_work_path" ]]; then
  # (2) The §5.85 guard section exists.
  assert_contains "$issue_work_path" "### 5.85 Post-PR-create non-close parent/epic leak verification" \
    "issue-work.md adds a §5.85 non-close parent/epic leak verification (issue #624)"
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/624" \
    "issue-work.md links to the originating issue #624"

  # (2.5) Issue #980: the full procedure now lives in an on-demand fragment;
  # issue-work.md's §5.85 must be a stub that POINTS to it, not a dead end.
  assert_contains "$issue_work_path" "issue-work-parent-epic-leak.md" \
    "issue-work.md's §5.85 stub points to the on-demand fragment (issue #980)"

  # (6) The §5.85 check MUST be placed after §5.8 (dispatched-issue closing-link
  # verification) and before §6 (Enable auto-merge) so a protected epic can
  # never ride an armed auto-merge to a silent close.
  assert_section_ordering "$issue_work_path" \
    "### 5.8 Post-PR-create closing-link verification" \
    "### 5.85 Post-PR-create non-close parent/epic leak verification" \
    "§5.85 lands after §5.8 closing-link verification"
  assert_section_ordering "$issue_work_path" \
    "### 5.85 Post-PR-create non-close parent/epic leak verification" \
    "### 6. Enable auto-merge" \
    "§5.85 lands before §6 Enable auto-merge"

  assert_contains "$issue_work_path" "even with NO closing keyword" \
    "issue-work.md states the trigger is broader than closing keywords"
fi

# (2.6) Issue #980: the detailed procedure — verification, remediation tiers,
# branch-naming prevention — now lives in the on-demand fragment. Check it
# there rather than in issue-work.md, since that's where it correctly lives
# once the trigger fires.
assert_file_exists "$fragment_path" "agents/issue-worker/issue-work-parent-epic-leak.md exists (issue #980)"

if [[ -f "$fragment_path" ]]; then
  # (3) The guard verifies closingIssuesReferences after PR create.
  assert_contains "$fragment_path" "closingIssuesReferences" \
    "issue-work-parent-epic-leak.md verifies closingIssuesReferences for the protected epic"

  # (4) The guard remediates a leak: bare-URL body rewrite + reopen-if-merged.
  assert_contains "$fragment_path" "bare URL" \
    "issue-work-parent-epic-leak.md documents the bare-URL mitigation"
  assert_contains "$fragment_path" "gh issue reopen" \
    "issue-work-parent-epic-leak.md reopens the epic if the PR already merged and closed it"
  assert_contains "$fragment_path" "blocked #<N> at parent-epic-leak-verify:" \
    "issue-work-parent-epic-leak.md uses the blocked #<N> at parent-epic-leak-verify: return format"

  # (5) The guidance names the REAL trigger — not only the closing keywords,
  # but bare #N tokens + commit/CHANGELOG mentions.
  assert_contains "$fragment_path" "squashed-commit message" \
    "issue-work-parent-epic-leak.md names squashed-commit messages as a leak vector"
  assert_contains "$fragment_path" "CHANGELOG" \
    "issue-work-parent-epic-leak.md names CHANGELOG entries as a leak vector"

  # (6.5) Issue #893: a single rewrite-and-reverify was not reliable in a live
  # dispatch. The fragment must document a three-tier escalation and must not
  # imply a single body rewrite is the complete remediation.
  assert_contains "$fragment_path" "https://github.com/mattsears18/shipyard/issues/893" \
    "issue-work-parent-epic-leak.md links to the non-reliable-remediation follow-up #893"
  assert_contains "$fragment_path" "Tier 1: rewrite the PR body to bare-URL form" \
    "issue-work-parent-epic-leak.md names tier 1 of the escalation (body rewrite)"
  assert_contains "$fragment_path" "Tier 2: also rewrite the HEAD commit message" \
    "issue-work-parent-epic-leak.md names tier 2 of the escalation (commit-message rewrite)"
  assert_contains "$fragment_path" "Tier 3: escape hatch" \
    "issue-work-parent-epic-leak.md names tier 3 of the escalation (escape hatch)"
  assert_contains "$fragment_path" "don't stop early" \
    "issue-work-parent-epic-leak.md instructs running the tiers in order without stopping early"
  assert_contains "$fragment_path" "NEUTRAL_BRANCH=" \
    "issue-work-parent-epic-leak.md's tier-3 escape hatch reopens from a neutrally-named branch"
  assert_not_contains "$fragment_path" \
    "if it leaked, rewrite the PR body to reference the epic by bare URL (replacing any \`#<E>\` token), re-verify, and — if the PR has *already merged*" \
    "issue-work-parent-epic-leak.md no longer documents ONLY a single rewrite-and-reverify pass (issue #893)"

  # (6.6) Issue #893: prevention guidance — never name a deliberately
  # non-closing PR's branch `do-work/issue-<E>`-shaped, since GitHub's
  # branch-to-issue auto-linking can register a closing reference
  # independent of the PR body or commit-message text.
  assert_contains "$fragment_path" "Prevention — never name a protected-issue-referencing PR's branch" \
    "issue-work-parent-epic-leak.md documents the branch-naming prevention (issue #893)"
  assert_contains "$fragment_path" "independent of the PR body or commit-message text" \
    "issue-work-parent-epic-leak.md names the branch-name vector as independent of body/commit text (issue #893)"
fi

# (7) Scope guard — the other modes' specs MUST NOT contain the §5.85 guard.
# Only issue-work writes a Closes #N / references a parent epic in a PR body;
# the other modes (fix-checks-only, fix-rebase, fix-main-ci,
# fix-failing-prs-batch) don't open issue-closing PRs, so the guard would be
# dead weight there.
assert_file_exists "$fix_checks_path" "agents/issue-worker/fix-checks-only.md exists"
assert_file_exists "$fix_rebase_path" "agents/issue-worker/fix-rebase.md exists"
assert_file_exists "$fix_main_ci_path" "agents/issue-worker/fix-main-ci.md exists"
assert_file_exists "$fix_failing_prs_path" "agents/issue-worker/fix-failing-prs-batch.md exists"

for path in "$fix_checks_path" "$fix_rebase_path" "$fix_main_ci_path" "$fix_failing_prs_path"; do
  if [[ -f "$path" ]]; then
    base=$(basename "$path")
    assert_not_contains "$path" \
      "blocked #<N> at parent-epic-leak-verify:" \
      "$base does not contain the issue-work parent-epic-leak bail string"
    assert_not_contains "$path" \
      "non-close parent/epic leak verification" \
      "$base does not duplicate the issue-work §5.85 header"
  fi
done

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

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
# Extended for issue #990: the bare-URL form alone doesn't protect against a
# closing-keyword-shaped word (close/fix/resolve, even negated — "does NOT
# close") sharing a line with an already-URL-form reference; §5's prevention
# note and the fragment's tier 1 remediation now name and grep for this
# hazard, and tier 3's branch-name attribution is softened pending that
# re-check.
#
# Extended for issue #982: `gh pr view --json closingIssuesReferences` can
# return a stale (falsely empty) result immediately after `gh pr
# create`/`gh pr edit` — GitHub computes the field asynchronously, so a lone
# read right after create can miss a link that registers moments later. That
# is a false NEGATIVE: it would let the worker arm auto-merge believing a
# leak is clean when it isn't, silently closing the protected issue on
# merge. The fragment now defines a `check_closing_ref` helper that queries
# `closingIssuesReferences` directly via `gh api graphql` (skipping `gh pr
# view`'s own object-resolution layer) and requires two consecutive reads,
# a few seconds apart, to agree before trusting an empty result — every
# LEAKED= check in the verification/remediation script routes through it.
#
# Extended for issue #1001: §5.8 has a complete add-and-verify path for the
# dispatched issue's own closing link, but no remove path — and the naive
# fix (edit the body) is not reliably one-way. A fourth trigger shape,
# "retracting an already-live closing link," was added for the case where a
# later dispatch finding (e.g. a post-open validation/landing-gate check)
# disproves the disposition after §5.8 already confirmed the link. Live
# testing on this repo confirmed: (a) no direct GraphQL mutation exists to
# unlink a PR from an issue — closingIssuesReferences is derived, not a
# mutable edge; (b) a clean bare-URL body rewrite usually clears the link
# within seconds, but GitHub does not contractually bound the recompute
# window, so a worker must always re-verify via check_closing_ref rather
# than trust a single edit; (c) a closing keyword confined to a commit
# message (absent from the PR body) did not register in the pre-merge
# closingIssuesReferences read, but tier 2 remains necessary defense-in-depth
# for non-squash merge strategies the pre-merge check can't validate.
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

  # (2.7) Issue #990: the URL form alone doesn't protect against a
  # closing-keyword word sharing the reference's own sentence/line, even in
  # negated form ("does NOT close ..."). issue-work.md's §5 prevention note
  # must name this before the worker ever reaches the fragment's guard.
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/990" \
    "issue-work.md links to the negation-blind-parser follow-up #990"
  assert_contains "$issue_work_path" "GitHub's parser doesn't understand negation" \
    "issue-work.md's §5 prevention note names the negation-blind-parser hazard (issue #990)"

  # (2.8) Issue #1001: a closing link that already registered via §5.8's
  # normal flow can need RETRACTION (not just prevention) when a later
  # dispatch finding disproves the disposition. §5.85's stub must widen from
  # three to four trigger shapes, §5.8 must point forward to shape (4) rather
  # than leaving the worker to improvise an untested body edit, and the
  # Don't list must warn against trusting a single edit.
  assert_contains "$issue_work_path" "https://github.com/mattsears18/shipyard/issues/1001" \
    "issue-work.md links to the closing-link-retraction follow-up #1001"
  assert_contains "$issue_work_path" "Four shapes trigger it" \
    "issue-work.md's §5.85 stub widens from three to four trigger shapes (issue #1001)"
  assert_contains "$issue_work_path" "a disposition change on the SAME PR that opened as \`#<N>\`'s own resolving PR" \
    "issue-work.md's §5.85 stub names shape (4): retracting an already-live closing link (issue #1001)"
  assert_contains "$issue_work_path" "This step only adds a closing link — it has no remove path of its own" \
    "issue-work.md's §5.8 points forward to §5.85 shape (4) for retraction (issue #1001)"
  assert_contains "$issue_work_path" "Don't assume editing the PR body to remove a closing keyword reliably retracts an already-registered closing link" \
    "issue-work.md's Don't list warns against trusting a single untested retraction edit (issue #1001)"
  assert_contains "$issue_work_path" "unlinkPullRequestFromIssue" \
    "issue-work.md's Don't list names the (nonexistent) unlinkPullRequestFromIssue mutation (issue #1001)"
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

  # (6.7) Issue #990: the bare-URL form alone is not sufficient — a
  # closing-keyword-shaped word sharing a line with the reference (even in
  # negated form, "does NOT close") still registers a closing link. The
  # fragment must name this hazard, add a keyword-adjacency check to tier 1,
  # and soften tier 3's branch-name attribution to account for it.
  assert_contains "$fragment_path" "https://github.com/mattsears18/shipyard/issues/990" \
    "issue-work-parent-epic-leak.md links to the negation-blind-parser follow-up #990"
  assert_contains "$fragment_path" "no negation awareness" \
    "issue-work-parent-epic-leak.md states the parser has no negation awareness (issue #990)"
  assert_contains "$fragment_path" "does NOT close" \
    "issue-work-parent-epic-leak.md gives the negated-sentence example (issue #990)"
  assert_contains "$fragment_path" "keyword-adjacency grep" \
    "issue-work-parent-epic-leak.md's tier 1 adds a keyword-adjacency check, not just the #<E>-token rewrite (issue #990)"
  assert_contains "$fragment_path" "Don't jump to the branch-name conclusion without first re-checking for the keyword-adjacency hazard" \
    "issue-work-parent-epic-leak.md softens tier 3's branch-name attribution pending the keyword-adjacency re-check (issue #990)"

  # (6.8) Issue #982: `gh pr view --json closingIssuesReferences` can serve a
  # stale (falsely empty) value right after `gh pr create`/`gh pr edit`,
  # producing a false negative that would arm auto-merge on a real leak. The
  # fragment must document the staleness hazard and provide a direct-GraphQL,
  # two-consecutive-reads-agree helper, and every LEAKED check in the
  # verification/remediation script must go through it rather than a bare
  # `gh pr view --json closingIssuesReferences` call.
  assert_contains "$fragment_path" "https://github.com/mattsears18/shipyard/issues/982" \
    "issue-work-parent-epic-leak.md links to the stale-read false-negative follow-up #982"
  assert_contains "$fragment_path" "check_closing_ref" \
    "issue-work-parent-epic-leak.md defines the check_closing_ref direct-GraphQL helper (issue #982)"
  assert_contains "$fragment_path" "gh api graphql" \
    "issue-work-parent-epic-leak.md's helper queries closingIssuesReferences directly via gh api graphql (issue #982)"
  assert_contains "$fragment_path" "false negative" \
    "issue-work-parent-epic-leak.md names the stale-read failure as a false negative (issue #982)"

  # (6.95) Issue #1001: §5.8 can add a closing link but had no documented
  # remove path, and the naive fix (edit the body) is not reliable — verified
  # empirically. The fragment must widen to a fourth trigger shape
  # (retraction, not just prevention), state that no direct GraphQL unlink
  # mutation exists, and document the empirical findings (body-rewrite
  # reliability, the commit-message vector, why tier 2 still matters).
  assert_contains "$fragment_path" "https://github.com/mattsears18/shipyard/issues/1001" \
    "issue-work-parent-epic-leak.md links to the closing-link-retraction follow-up #1001"
  assert_contains "$fragment_path" "Four shapes trigger it" \
    "issue-work-parent-epic-leak.md's applicability paragraph widens to four trigger shapes (issue #1001)"
  assert_contains "$fragment_path" "Shape (4) — retracting an already-live closing link" \
    "issue-work-parent-epic-leak.md documents shape (4): retraction, not prevention (issue #1001)"
  assert_contains "$fragment_path" "unlinkPullRequestFromIssue" \
    "issue-work-parent-epic-leak.md confirms no direct GraphQL unlink mutation exists (issue #1001)"
  assert_contains "$fragment_path" "There is no direct mutation to unlink a PR from an issue" \
    "issue-work-parent-epic-leak.md states the escalation ladder IS the API, not a workaround (issue #1001)"
  assert_contains "$fragment_path" "usually — not reliably — clears the link within seconds" \
    "issue-work-parent-epic-leak.md documents the empirical body-rewrite reliability finding (issue #1001)"
  assert_contains "$fragment_path" "A closing keyword confined to a commit message" \
    "issue-work-parent-epic-leak.md documents the commit-message-vector empirical finding (issue #1001)"

  # (6.9) Every LEAKED= assignment in the verification script must call the
  # check_closing_ref helper — none should fall back to a bare `gh pr view
  # --json closingIssuesReferences` read (the exact hazard #982 reports).
  # shellcheck disable=SC2016  # literal needles — must NOT expand $( in this shell
  leaked_lines=$(grep -c '^\s*LEAKED=\$(' "$fragment_path" 2>/dev/null || echo 0)
  # shellcheck disable=SC2016  # literal needle — must NOT expand $( in this shell
  leaked_helper_lines=$(grep -c 'LEAKED=\$(check_closing_ref' "$fragment_path" 2>/dev/null || echo 0)
  if [[ "$leaked_lines" -gt 0 && "$leaked_lines" == "$leaked_helper_lines" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "issue-work-parent-epic-leak.md routes every LEAKED= check through check_closing_ref (issue #982)"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "issue-work-parent-epic-leak.md routes every LEAKED= check through check_closing_ref (issue #982)"
    printf '    LEAKED= assignments: %s, routed through check_closing_ref: %s\n' "$leaked_lines" "$leaked_helper_lines"
    fail=$((fail+1))
  fi
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

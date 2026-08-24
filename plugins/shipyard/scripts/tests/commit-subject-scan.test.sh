#!/usr/bin/env bash
# Test: the commit-subject gate (issues #1410 / #1412).
#
# Background — issue #1408: GitHub's squash-merge uses the SOLE commit's
# subject when a PR has exactly one commit; the PR title is only the
# squash-message default at two or more commits. PR #1408 carried the
# fully-compliant title
#
#   fix(scripts): shipped-immediate-branch-reap.sh reported reaped=true on a
#   failed removal (closes #1404)
#
# but its single commit was subject-prefixed `wip:`. On squash-merge `main`
# got `wip: fix false-success reaped=true in shipped-immediate-branch-reap.sh
# (#1404) (#1408)` — a subject that parses as none of major/minor/patch under
# Conventional-Commits-driven release tooling, and that no existing CI gate
# (`conflict markers`, `gitleaks`, the bash test suites, `shellcheck`)
# inspects.
#
# #1410 shipped the prose remediation (`skills/worker-preamble/
# commit-hygiene.md` § "Final commit subject"). #1412 tracks the mechanical
# one: `scripts/commit-subject-scan.sh`, in the same family as
# `conflict-marker-scan.sh` / `compound-block-scan.sh` — a check that catches
# the defect regardless of whether the worker read or internalized the prose.
#
# SCOPE NOTE (superseded by #1534) — this suite originally did NOT assert on
# any `.github/workflows/` file: per the maintainer's recorded decision on
# #1412 the workflow wiring was a hand-done follow-up, and asserting a
# workflow that did not exist yet would have redded this suite on a correct
# tree. #1534 landed that wiring (a `pull_request`-gated Conventional Commits
# step inside `tests.yml`'s already-required `bash test suites` job), so the
# deferred `assert_contains "$workflow" ...` block the note asked for now
# lives in section (12) below.
#
# VACUOUS-ASSERTION NOTE (#1534) — this suite used to end with a self-check
# that scanned `HEAD~5..HEAD` of the real repo, guarded on `HEAD~5`
# resolving. `actions/checkout` fetched at depth 1, so the guard was false on
# every CI run and the assertion silently did not execute — a skip
# indistinguishable from a pass, the exact vacuous shape #1312 exists to
# catch. It has been replaced (section 13) by a deterministic corpus of real,
# already-merged shipyard subjects replayed into the fixture repo. That
# keeps the original intent — the grammar must not false-positive on the
# subject shapes this repo actually writes — while removing both defects:
# it does not depend on ambient clone depth, and it does not slide over
# whatever five commits happen to be at `HEAD` (a window that today contains
# the genuinely non-conforming `c667873`, and would therefore have redded
# `main` for the next few merges and then gone quietly green again).
#
# Pure bash + git. Run with:
#
#   bash plugins/shipyard/scripts/tests/commit-subject-scan.test.sh

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

script="$repo_root/plugins/shipyard/scripts/commit-subject-scan.sh"
hygiene="$repo_root/plugins/shipyard/skills/worker-preamble/commit-hygiene.md"
workflow="$repo_root/.github/workflows/tests.yml"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (expected in $1: $2)"; fi
}

echo "commit-subject gate regression tests (issues #1410 / #1412)"
echo

# ── (1) Artifact presence + invocability ───────────────────────────────────
if [[ -f "$script" ]]; then
  ok "scripts/commit-subject-scan.sh exists"
else
  bad "scripts/commit-subject-scan.sh exists (missing: $script)"
  echo
  echo "  ${pass} passed, ${fail} failed"
  exit 1
fi

if [[ -x "$script" ]]; then
  ok "scripts/commit-subject-scan.sh has the exec bit set"
else
  bad "scripts/commit-subject-scan.sh has the exec bit set"
fi

# (2) The prose rule and the mechanical gate point at each other, so a future
# edit to either surfaces the other.
if [[ -f "$hygiene" ]]; then
  assert_contains "$hygiene" 'commit-subject-scan.sh' \
    "commit-hygiene.md references the mechanical scanner"
else
  bad "skills/worker-preamble/commit-hygiene.md exists (missing: $hygiene)"
fi

# ── Fixture ────────────────────────────────────────────────────────────────
# A throwaway repo whose branches encode each subject shape under test.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
# Never let a developer's global signing config break the fixture commits.
git -C "$repo" config commit.gpgsign false

# `n` distinct files keep every commit a real, non-empty change.
seq=0
mk_commit() { # mk_commit <subject>
  seq=$((seq + 1))
  printf 'content %s\n' "$seq" > "$repo/f$seq.txt"
  git -C "$repo" add "f$seq.txt"
  git -C "$repo" commit -q -m "$1"
}

mk_branch() { # mk_branch <name> <subject>...
  local name="$1"; shift
  git -C "$repo" checkout -q -b "$name" main
  local s
  for s in "$@"; do mk_commit "$s"; done
}

mk_commit "chore: base commit"
git -C "$repo" branch -q -M main

# Helper: run the scanner inside the fixture repo, capturing stdout+stderr.
run_scan() { # run_scan <branch> [<base> [<head>]]
  local branch="$1"; shift
  git -C "$repo" checkout -q "$branch"
  ( cd "$repo" && bash "$script" "$@" 2>&1 )
}

expect_rc() { # expect_rc <expected-rc> <label> <branch> [args...]
  local want="$1"; shift
  local label="$1"; shift
  local out status
  out="$(run_scan "$@")"
  status=$?
  if [[ "$status" -eq "$want" ]]; then
    ok "$label"
  else
    bad "$label (expected exit $want, got $status: ${out//$'\n'/ | })"
  fi
}

# ── (3) A fully compliant branch passes ────────────────────────────────────
mk_branch clean \
  "feat(ci): add the commit-subject gate" \
  "fix(scripts): correct the range resolution" \
  "docs: explain the wip carve-out"
expect_rc 0 "all-conventional branch exits 0" clean main

# The pass line must report a non-zero scanned count — an "everything is
# fine" message over zero inspected commits is a vacuous pass, not a pass.
clean_out="$(run_scan clean main)"
if [[ "$clean_out" == *"3 commit subject(s) conform"* ]]; then
  ok "pass line reports the number of subjects actually scanned (anti-vacuity)"
else
  bad "pass line should report 3 scanned subjects, got: $clean_out"
fi

# ── (4) The #1408 regression case: a `wip:` FINAL commit ───────────────────
mk_branch wip-final \
  "wip: fix false-success reaped=true in shipped-immediate-branch-reap.sh (#1404)"
wip_out="$(run_scan wip-final main)"
wip_rc=$?
if [[ "$wip_rc" -eq 1 ]]; then
  ok "single-commit branch with a wip: subject exits 1 (#1408 regression)"
else
  bad "single-commit wip: branch should exit 1, got $wip_rc: ${wip_out//$'\n'/ | }"
fi
if [[ "$wip_out" == *"FINAL commit carries a scratch 'wip:' subject"* ]]; then
  ok "the wip: FINAL failure names the squash-merge hazard explicitly"
else
  bad "expected the FINAL-wip diagnostic, got: ${wip_out//$'\n'/ | }"
fi
if [[ "$wip_out" == *"shipped-immediate-branch-reap"* ]]; then
  ok "the failure output echoes the offending subject"
else
  bad "expected the offending subject in the output, got: ${wip_out//$'\n'/ | }"
fi

# ── (5) The final-vs-non-final distinction ─────────────────────────────────
# Identical `wip:` subject, but no longer the tip → tolerated.
mk_branch wip-nonfinal \
  "wip: fix false-success reaped=true in shipped-immediate-branch-reap.sh (#1404)" \
  "fix(scripts): report reaped=false on a failed removal (closes #1404)"
expect_rc 0 "wip: on a non-final commit is tolerated" wip-nonfinal main

nonfinal_out="$(run_scan wip-nonfinal main)"
if [[ "$nonfinal_out" == *"tolerated scratch subject on a non-final commit"* ]]; then
  ok "a tolerated non-final wip: is still reported (visible, not silent)"
else
  bad "expected a tolerated-scratch note, got: ${nonfinal_out//$'\n'/ | }"
fi

# "Final" is relative to the scanned <head-ref>, not to the branch tip: the
# same commit that was tolerated above becomes the final one when the range
# ends on it, and must then fail.
wip_sha="$(git -C "$repo" rev-parse wip-nonfinal~1)"
expect_rc 1 "the same wip: commit fails when it IS the scanned head" \
  wip-nonfinal main "$wip_sha"

# ── (6) Non-conventional subjects that are not `wip:` ──────────────────────
mk_branch junk-final "update stuff"
expect_rc 1 "a non-conventional final subject exits 1" junk-final main

# Only `wip:` is carved out for non-final commits — arbitrary junk is not.
mk_branch junk-nonfinal "update stuff" "fix(scripts): do the thing"
expect_rc 1 "a non-conventional NON-final subject still exits 1" junk-nonfinal main

mk_branch unknown-type "wibble(scripts): not a recognized type"
expect_rc 1 "an unrecognized type exits 1" unknown-type main

mk_branch no-desc "fix:"
expect_rc 1 "a type with no description exits 1" no-desc main

mk_branch no-space "fix:missing the space"
expect_rc 1 "a missing colon-space exits 1" no-space main

mk_branch empty-scope "fix(): empty scope"
expect_rc 1 "an empty scope exits 1" empty-scope main

# ── (7) Accepted grammar variants ──────────────────────────────────────────
mk_branch variants \
  "docs: no scope at all" \
  "fix(detect-ungated-admin-direct-merge): a long hyphenated scope" \
  "feat(ci)!: a breaking change marker" \
  "refactor(do-work/setup): a slash in the scope"
expect_rc 0 "scope-less, hyphenated-scope, breaking-marker and slashed-scope subjects pass" \
  variants main

# ── (8) git-generated subjects are exempt ──────────────────────────────────
git -C "$repo" checkout -q -b merge-target main
mk_commit "fix(scripts): a change to merge in"
git -C "$repo" checkout -q -b merge-host main
mk_commit "feat(scripts): the host branch change"
git -C "$repo" merge -q --no-ff -m "Merge branch 'merge-target' into merge-host" merge-target
expect_rc 0 "a git-generated merge subject is exempt" merge-host main

merge_out="$(run_scan merge-host main)"
if [[ "$merge_out" == *"1 git-generated subject(s) skipped"* ]]; then
  ok "the merge subject is reported as skipped, not as scanned"
else
  bad "expected a skipped-count of 1, got: $merge_out"
fi

mk_branch revert-branch \
  "fix(scripts): something to revert" \
  'Revert "fix(scripts): something to revert"'
expect_rc 0 "a git-generated revert subject is exempt" revert-branch main

# A subject that merely STARTS with the word "Merge" is not git-generated and
# must still be held to the grammar.
mk_branch merge-lookalike "Merge the two code paths into one"
expect_rc 1 "a prose subject starting with 'Merge' is NOT exempted" merge-lookalike main

# ── (9) Range / ref handling ───────────────────────────────────────────────
expect_rc 0 "an empty range exits 0" main main
empty_out="$(run_scan main main)"
if [[ "$empty_out" == *"no commits in range"* ]]; then
  ok "an empty range says so explicitly rather than printing a clean verdict"
else
  bad "expected a 'no commits in range' message, got: $empty_out"
fi

expect_rc 2 "an unresolvable base ref exits 2" clean no-such-ref-xyz
expect_rc 2 "an unresolvable head ref exits 2" clean main no-such-ref-xyz

# Base auto-detection: with no args at all the scanner falls back to `main`.
expect_rc 1 "base auto-detection finds main when no base is passed" wip-final

# ── (10) Usage / environment errors ────────────────────────────────────────
help_out="$( ( cd "$repo" && bash "$script" --help ) 2>&1 )"
help_rc=$?
if [[ "$help_rc" -eq 2 && "$help_out" == *"usage: commit-subject-scan.sh"* ]]; then
  ok "--help prints usage and exits 2"
else
  bad "--help should print usage and exit 2, got $help_rc: ${help_out//$'\n'/ | }"
fi

extra_out="$( ( cd "$repo" && bash "$script" a b c ) 2>&1 )"
extra_rc=$?
if [[ "$extra_rc" -eq 2 && "$extra_out" == *"too many arguments"* ]]; then
  ok "more than two arguments exits 2"
else
  bad "extra args should exit 2, got $extra_rc: ${extra_out//$'\n'/ | }"
fi

outside="$work/not-a-repo"
mkdir -p "$outside"
outside_out="$( ( cd "$outside" && bash "$script" ) 2>&1 )"
outside_rc=$?
if [[ "$outside_rc" -eq 2 && "$outside_out" == *"not inside a git work tree"* ]]; then
  ok "running outside a git work tree exits 2"
else
  bad "outside a work tree should exit 2, got $outside_rc: ${outside_out//$'\n'/ | }"
fi

# ── (11) COMMIT_SUBJECT_SCAN_TYPES override ────────────────────────────────
mk_branch custom-type "spike(research): a repo-specific type"
expect_rc 1 "a repo-specific type is rejected under the default type list" custom-type main

git -C "$repo" checkout -q custom-type
custom_out="$( cd "$repo" && COMMIT_SUBJECT_SCAN_TYPES='spike,fix,chore' bash "$script" main 2>&1 )"
custom_rc=$?
if [[ "$custom_rc" -eq 0 ]]; then
  ok "COMMIT_SUBJECT_SCAN_TYPES accepts a repo-specific type"
else
  bad "type override should accept 'spike', got $custom_rc: ${custom_out//$'\n'/ | }"
fi

empty_types_out="$( cd "$repo" && COMMIT_SUBJECT_SCAN_TYPES=',,' bash "$script" main 2>&1 )"
empty_types_rc=$?
if [[ "$empty_types_rc" -eq 2 && "$empty_types_out" == *"empty type list"* ]]; then
  ok "an empty COMMIT_SUBJECT_SCAN_TYPES list exits 2 rather than matching nothing"
else
  bad "empty type list should exit 2, got $empty_types_rc: ${empty_types_out//$'\n'/ | }"
fi

# ── (12) The CI wiring that makes this a real gate (#1534) ─────────────────
# The scanner is only a gate if something runs it against a PR's own commit
# range with enough clone depth for that range to resolve. These assertions
# pin that wiring — the block the #1412 SCOPE NOTE deferred until the
# workflow landed.
if [[ -f "$workflow" ]]; then
  ok ".github/workflows/tests.yml exists"

  assert_contains "$workflow" "plugins/shipyard/scripts/commit-subject-scan.sh" \
    "tests.yml invokes the scanner script"

  # Depth 1 (the `actions/checkout` default) leaves `<base>..<head>`
  # unresolvable. This line is what turns the scan from a no-op into a gate,
  # and is the specific defect #1534 reported.
  assert_contains "$workflow" "fetch-depth: 0" \
    "tests.yml checks out full history so the PR's commit range resolves"

  # The PR's real commit range — not an ambient `HEAD~N` window, and not the
  # `refs/pull/N/merge` tip (whose subject is git-generated and whose use as
  # <head-ref> would misidentify which commit is final for the `wip:` rule).
  assert_contains "$workflow" 'github.event.pull_request.base.sha' \
    "tests.yml scans from the PR's base SHA"
  assert_contains "$workflow" 'github.event.pull_request.head.sha' \
    "tests.yml scans to the PR's head SHA (not the test-merge tip)"

  # Event-supplied values reach the scan through `env:`, never interpolated
  # into the `run:` body — the workflow's own stated security posture.
  # shellcheck disable=SC2016  # literal needles — the ${{ }} and $PR_* forms
  # are the workflow's own text, matched verbatim by grep -F, not expanded here.
  assert_contains "$workflow" 'PR_BASE_SHA: ${{ github.event.pull_request.base.sha }}' \
    "tests.yml passes the base SHA via env:, not run: interpolation"
  # shellcheck disable=SC2016
  assert_contains "$workflow" '"$PR_BASE_SHA" "$PR_HEAD_SHA"' \
    "tests.yml's scan step reads the SHAs from the environment"

  # `pull_request`-only: on a push to `main` the merge already happened, so
  # flagging then would red `main` over unfixable history.
  assert_contains "$workflow" "if: github.event_name == 'pull_request'" \
    "tests.yml runs the subject scan on pull_request only"

  assert_contains "$workflow" "contents: read" \
    "tests.yml is read-only (least privilege)"
else
  bad ".github/workflows/tests.yml exists (missing: $workflow)"
fi

# ── (13) The grammar accepts the subject shapes this repo really writes ────
# Replaces the former `HEAD~5..HEAD` self-check, which was guarded on an
# ambient range that never resolved under CI's depth-1 checkout and so
# silently asserted nothing (#1534 — see the VACUOUS-ASSERTION NOTE above).
#
# Same intent, deterministic mechanism: a frozen corpus of subjects taken
# verbatim from already-merged `mattsears18/shipyard` history, replayed into
# the fixture repo. It exercises the shapes a sliding window over real
# history would have — hyphenated and dotted scopes, `!` breaking-change
# markers, `<...>` / quotes / backticks / brackets in the description, the
# trailing `(closes #N) (#M)` parenthesis pair, and the bare no-scope form —
# without depending on clone depth or on which commits happen to be at HEAD.
#
# When adding to this corpus, copy a subject verbatim from `git log
# --format=%s origin/main`. A subject that fails here means the grammar
# rejects something this repo actually ships, i.e. the regex is too strict.
real_subjects=(
  "fix(do-work): forbid instructing a worker past a documented spec short-circuit (closes #1513) (#1516)"
  "fix(scripts): reject an unrecognized flag in the positional <owner/repo> detectors instead of forwarding it to gh (closes #1502) (#1514)"
  "feat(scope-preflight): re-validate an issue's self-declared \"out of scope for an agent\" claim (closes #1491) (#1507)"
  "fix(detect-ungated-admin-direct-merge): report a real required-checks count on the ruleset path (closes #1488) (#1489)"
  "fix(main-ci): treat a path-filtered vacuous CI success as unproven, not green (closes #1495) (#1497)"
  "chore(do-work)!: retire the legacy Agent-tool dispatch path"
  "feat(do-work)!: make autonomous operation the default; add --no-operate/--hands-off opt-out [phase a of #659] (#666)"
  "docs: record main's required status checks and the two that must never be added"
  "chore: release 4.2.6"
  "refactor(harness-convergence): fold the duplicated preamble into one skill"
  "perf(worker): drop the redundant per-dispatch config re-read"
  "test(worktree-reap): cover the stray-tombstone bounded pass"
)
mk_branch real-history "${real_subjects[@]}"
expect_rc 0 "the grammar accepts a frozen corpus of real merged shipyard subjects" \
  real-history main

# The negative half of the same corpus: the two real subjects that motivated
# this gate must still be rejected, so the assertion above can never pass by
# the grammar having gone permissive.
mk_branch real-history-wip "wip: fix false-success reaped=true in shipped-immediate-branch-reap.sh (#1404) (#1408)"
expect_rc 1 "the real #1408 subject (wip: on the final commit) is still rejected" \
  real-history-wip main

mk_branch real-history-c667873 "do work/issue 1513 (#1533)"
expect_rc 1 "the real c667873 subject on main is still rejected" \
  real-history-c667873 main

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

#!/usr/bin/env bash
# Test: the conflict-marker gate (issue #436).
#
# Background — issue #436: during a high-concurrency /shipyard:do-work
# session, a fix-rebase/merge force-pushed a CHANGELOG.md carrying
# unresolved Git conflict markers (`=======` / `>>>>>>> <sha>`) which then
# merged to `main`. None of the existing CI gates (shellcheck, bash tests,
# secret-scan) grep for conflict markers, so the corruption rode a green CI
# run onto the default branch and every subsequent PR branched from a
# poisoned base. The fix is two-layer:
#
#   1. A repo-side CI gate (.github/workflows/conflict-markers.yml) that
#      runs scripts/conflict-marker-scan.sh on every push + PR.
#   2. A worker-side assertion in agents/issue-worker/fix-rebase.md step 5.5
#      that greps the rebased tree before force-push and bails `blocked
#      rebase` if any marker survived the conflict resolution.
#
# This test pins all three artifacts: the scanner's behavior (clean pass /
# marker fail / allow-directive opt-out / precise regex), the workflow's
# wiring, and the fix-rebase.md assertion. If any regress, the test fails.
#
# Pure bash + git. Run with:
#
#   bash plugins/shipyard/scripts/tests/conflict-marker-scan.test.sh
#
# This file constructs conflicted-file fixtures (heredocs containing bare
# conflict markers) to exercise the scanner, so it carries the scanner's
# own opt-out directive on the next line — otherwise the gate would flag
# this test's fixtures as a real conflict and red itself.
#   conflict-marker-scan: allow

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

scanner="$repo_root/plugins/shipyard/scripts/conflict-marker-scan.sh"
workflow="$repo_root/.github/workflows/conflict-markers.yml"
fix_rebase="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()   { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

assert_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (expected in $1: $2)"; fi
}

echo "conflict-marker gate regression tests (issue #436)"
echo

# (1) All three artifacts exist.
assert_file_exists "$scanner" "scripts/conflict-marker-scan.sh exists"
assert_file_exists "$workflow" ".github/workflows/conflict-markers.yml exists"
assert_file_exists "$fix_rebase" "agents/issue-worker/fix-rebase.md exists"

# (2) The CI workflow wires the scanner script and runs on push + PR.
if [[ -f "$workflow" ]]; then
  assert_contains "$workflow" "plugins/shipyard/scripts/conflict-marker-scan.sh" \
    "workflow invokes the scanner script"
  assert_contains "$workflow" "pull_request" "workflow triggers on pull_request"
  assert_contains "$workflow" "contents: read" "workflow is read-only (least privilege)"
fi

# (3) The fix-rebase worker-side assertion exists and bails (not force-pushes).
if [[ -f "$fix_rebase" ]]; then
  assert_contains "$fix_rebase" 'git grep -nE' \
    "fix-rebase.md greps for conflict markers before force-push"
  assert_contains "$fix_rebase" 'conflict markers remain after resolution' \
    "fix-rebase.md documents the canonical bail substring"
  assert_contains "$fix_rebase" 'https://github.com/mattsears18/shipyard/issues/436' \
    "fix-rebase.md links to originating issue #436"
fi

# (4) Behavioral: the scanner exits 0 on a clean tracked tree.
if [[ -x "$scanner" || -f "$scanner" ]]; then
  if bash "$scanner" >/dev/null 2>&1; then
    ok "scanner exits 0 on the current (clean) repo"
  else
    bad "scanner exited non-zero on the current repo — is main poisoned, or is the regex over-broad?"
  fi
fi

# (5) Behavioral: the scanner detects a real conflict marker and exits 1.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
conflicted="$work/conflicted.txt"
cat > "$conflicted" <<'FIXTURE'
line before
<<<<<<< HEAD
ours
=======
theirs
>>>>>>> 0ff725a
line after
FIXTURE

if bash "$scanner" "$conflicted" >/dev/null 2>&1; then
  bad "scanner FAILED to detect markers in a conflicted file (exited 0)"
else
  rc=$?
  if [[ "$rc" -eq 1 ]]; then
    ok "scanner exits 1 on a file with conflict markers"
  else
    bad "scanner exited $rc (expected 1) on a conflicted file"
  fi
fi

# (6) Behavioral: a file carrying the `conflict-marker-scan: allow` opt-out
# directive is skipped even when it contains bare markers.
printf 'conflict-marker-scan: allow\n' >> "$conflicted"
if bash "$scanner" "$conflicted" >/dev/null 2>&1; then
  ok "scanner skips a file carrying the allow directive"
else
  bad "scanner did NOT honor the allow directive (still exited non-zero)"
fi

# (7) Precision: inline / mid-line marker-like prose must NOT trip the gate.
# A doc that writes `=======` inside backticks, or a `===` divider, or a
# 6-or-8-char run, is not a real marker. Only the anchored exactly-7 pattern
# followed by space-or-EOL counts.
benign="$work/benign.md"
cat > "$benign" <<'FIXTURE'
Here is some prose mentioning `=======` inline inside backticks.
=== a three-equals divider ===
====== six equals, not seven ======
======== eight equals ========
A line with >>>>>>> markers but not at the start.
FIXTURE
if bash "$scanner" "$benign" >/dev/null 2>&1; then
  ok "scanner does NOT false-positive on inline / wrong-length marker-like prose"
else
  bad "scanner FALSE-POSITIVED on benign marker-like prose (regex too broad)"
fi

# (8) Each of the three marker forms is independently detected, including a
# LONE `=======` with no matching `<<<<<<<` / `>>>>>>>` anywhere else in the
# file — the exact shape issue #1282 found live on `main`.
lone_open="$work/lone-open.md"
printf 'line before\n<<<<<<< HEAD\nline after\n' > "$lone_open"
if bash "$scanner" "$lone_open" >/dev/null 2>&1; then
  bad "scanner FAILED to detect a lone <<<<<<< marker (exited 0)"
else
  ok "scanner detects a lone <<<<<<< marker"
fi

lone_equals="$work/lone-equals.md"
printf 'line before\n=======\nline after\n' > "$lone_equals"
if bash "$scanner" "$lone_equals" >/dev/null 2>&1; then
  bad "scanner FAILED to detect a lone ======= marker with no matching <<<<<<< / >>>>>>> (issue #1282)"
else
  ok "scanner detects a lone ======= marker with no matching <<<<<<< / >>>>>>>"
fi

lone_close="$work/lone-close.md"
printf 'line before\n>>>>>>> 0ff725a\nline after\n' > "$lone_close"
if bash "$scanner" "$lone_close" >/dev/null 2>&1; then
  bad "scanner FAILED to detect a lone >>>>>>> marker (exited 0)"
else
  ok "scanner detects a lone >>>>>>> marker"
fi

# (9) Regression for issue #1282: a file whose ONLY occurrence of the allow
# directive is a backtick-quoted mention inside a running prose sentence
# (exactly the shape of CHANGELOG.md's own #436-era release note, which
# documents this very convention) must NOT opt the file out of scanning. A
# real marker elsewhere in that same file must still be caught. This is the
# root cause #1282 diagnosed: the old `grep -qF` substring check treated any
# occurrence anywhere in the file as an opt-out, so that single doc mention
# permanently silenced the gate for the rest of CHANGELOG.md.
prose_mention="$work/prose-mention.md"
cat > "$prose_mention" <<'FIXTURE'
# Changelog

Some entry describing the scanner: fixtures opt out with a
`conflict-marker-scan: allow` directive somewhere in the file, per the
usual convention.
=======
### next entry
FIXTURE
if bash "$scanner" "$prose_mention" >/dev/null 2>&1; then
  bad "scanner FAILED to catch a real marker in a file that only mentions the allow directive in prose (issue #1282 regression)"
else
  ok "scanner ignores a prose/backtick-quoted mention of the allow directive and still catches a real marker (issue #1282)"
fi

# (10) The legitimate opt-out shapes still work: a bare directive line (no
# comment wrapper — already covered by test (6) above) and a `#`-prefixed
# comment-line directive, the exact shape this test file itself uses to
# exempt its own conflict-marker fixtures.
comment_directive="$work/comment-directive.md"
cat > "$comment_directive" <<'FIXTURE'
line before
=======
line after
#   conflict-marker-scan: allow
FIXTURE
if bash "$scanner" "$comment_directive" >/dev/null 2>&1; then
  ok "scanner honors a #-prefixed comment-line allow directive"
else
  bad "scanner did NOT honor a #-prefixed comment-line allow directive (still exited non-zero)"
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

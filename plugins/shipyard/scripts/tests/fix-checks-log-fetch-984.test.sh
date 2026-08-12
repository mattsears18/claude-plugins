#!/usr/bin/env bash
# Test: fix-checks-only.md prescribes the per-job REST endpoint as the
# PRIMARY way to pull a failing job's CI logs, names the `gh run view
# --log-failed` empty-output trap explicitly, and keeps `--log-failed` as a
# fallback rather than the default — issue #984.
#
# Background
# ----------
# `gh run view <run-id> --log-failed` returns EMPTY output whenever any
# sibling job in the same workflow run is still `in_progress` — even when
# the job the worker actually needs already finished and failed. Two
# consecutive fix-checks-only dispatches against lightwork PR #3245 (session
# do-work-20260727T132741Z-21391) read that emptiness as "logs not ready
# yet," polled for 15+ minutes waiting on a slow `Web E2E Tests` sibling, and
# both returned `blocked` — burning ~310k tokens combined — when the failing
# `Unit Tests` job's logs were retrievable the whole time via:
#
#   JOBID=$(gh api "repos/<owner>/<repo>/actions/runs/<run-id>/jobs" \
#     --jq '.jobs[]|select(.conclusion=="failure")|.id' | head -1)
#   gh api "repos/<owner>/<repo>/actions/jobs/$JOBID/logs"
#
# The fix rewrites the fix-loop's log-pulling step (and the Infra-flake
# classification's Step A, which carried the same false "wait for the whole
# run" premise) to resolve the failing job id and hit the per-job logs
# endpoint FIRST, naming the empty-`--log-failed`-while-siblings-run trap
# explicitly so a worker never reads it as a wait signal.
#
# This is a companion regression guard to
# fix-checks-infra-flake-classification.test.sh (issue #654), which already
# covers the broader Infra-flake classification gate and was updated
# alongside this fix to track Step A's reworded heading.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/fix-checks-log-fetch-984.test.sh

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

fix_checks_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-checks-only.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"; local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"; fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"; local needle="$2"; local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  fi
}

assert_count_at_least() {
  local file="$1"; local needle="$2"; local min="$3"; local label="$4"
  local count
  count=$(grep -oF -- "$needle" "$file" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${count:-0}" -ge "$min" ]]; then
    printf '  %sPASS%s  %s (found %s)\n' "$GREEN" "$RESET" "$label" "$count"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (found %s, wanted >= %s)\n' "$RED" "$RESET" "$label" "${count:-0}" "$min"; fail=$((fail+1))
  fi
}

echo "fix-checks-only per-job log-fetch primacy (issue #984)"
echo

assert_file_exists "$fix_checks_path" "fix-checks-only.md exists"

# --- Provenance: issue #984 is cited ----------------------------------------

assert_contains "$fix_checks_path" \
  "github.com/mattsears18/shipyard/issues/984" \
  "links issue #984 for provenance"

# --- The per-job endpoint is prescribed as the PRIMARY path -----------------

assert_contains "$fix_checks_path" \
  "resolve the job id and use the per-job REST endpoint as the primary path" \
  "fix-loop step 2 prescribes the per-job endpoint as primary"

# shellcheck disable=SC2016  # single-quoted needle is a literal string to grep for, not an expansion
assert_contains "$fix_checks_path" \
  'gh api "repos/<owner/repo>/actions/runs/$RUN_ID/jobs"' \
  "documents resolving the failing job id from /actions/runs/<run-id>/jobs"

# shellcheck disable=SC2016  # single-quoted needle is a literal string to grep for, not an expansion
assert_count_at_least "$fix_checks_path" \
  'gh api "repos/<owner/repo>/actions/jobs/$JOBID/logs"' \
  2 \
  "documents fetching per-job logs from /actions/jobs/<job-id>/logs (fix-loop + Step A)"

# --- The empty-output trap is named explicitly ------------------------------

assert_contains "$fix_checks_path" \
  "empty output whenever ANY sibling job in the same run is still" \
  "names the gh run view --log-failed empty-output-while-siblings-run trap"

assert_contains "$fix_checks_path" \
  "Don't read an empty \`gh run view --log-failed\` as \"logs not ready yet.\"" \
  "Don't section forbids reading empty --log-failed as a wait signal"

# --- --log-failed is demoted to a fallback, never the default --------------

assert_contains "$fix_checks_path" \
  "\`gh run view --log-failed\` is a fallback, not the default" \
  "demotes --log-failed to a fallback"

assert_contains "$fix_checks_path" \
  "It is never the right first move while any job in the run is still running." \
  "states --log-failed is never the right first move mid-run"

# --- Step A no longer tells the worker to wait on the WHOLE run ------------

assert_contains "$fix_checks_path" \
  "resolve the failing job's own logs; don't wait on siblings" \
  "Step A heading scopes the wait to the specific job, not the whole run"

assert_contains "$fix_checks_path" \
  "Only block your own turn when the job you actually need" \
  "Step A only blocks on the specific job's own conclusion"

echo
if [[ "$fail" -eq 0 ]]; then
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
else
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass"
  exit 1
fi

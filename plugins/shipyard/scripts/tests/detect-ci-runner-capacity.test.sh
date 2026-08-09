#!/usr/bin/env bash
# Test: the CI-runner-capacity detector — read a repo's self-hosted CI runner
# pool shape (issue #1141).
#
# Background — issue #1141
# -------------------------
# `--concurrency N` bounds worker count, not CI-run count. On a repo whose CI
# runs on a small, fixed self-hosted runner pool, worker throughput and
# CI-landing throughput can decouple: `/shipyard:do-work` dispatches happily
# while the queue behind the runners grows without bound (the repro: a
# 4-runner self-hosted pool against a session that opened 13 PRs, reaching a
# 20+-run queue). `scripts/detect-ci-runner-capacity.sh` is the single
# executable read of that pool's shape, consumed by setup step 1.36 (clamp a
# config-sourced concurrency toward the pool) and the end-of-session summary
# (surface a "queue depth far exceeds pool capacity" banner).
#
# This test pins:
#   (A) the detector script's decision truth table (pure `--decide` mode);
#   (B) the live-path usage/error handling (missing args, --decide arg count);
#   (C) setup step 1.36 exists, calls the detector, and clamps only a
#       config-sourced EFFECTIVE_CONCURRENCY (never an explicit --concurrency);
#   (D) the `ci_capacity` write-through is wired into step 1.5, right after
#       `init`;
#   (E) the session-state schema documents the `ci_capacity` field;
#   (F) cleanup-summary.md documents the `CI executor capacity` banner,
#       gated on shape == self-hosted, a fresh re-query, and F > 0.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/detect-ci-runner-capacity.test.sh

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

DETECTOR="$repo_root/plugins/shipyard/scripts/detect-ci-runner-capacity.sh"
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"
CLEANUP_MD="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
SESSION_STATE_MD="$repo_root/plugins/shipyard/commands/do-work/session-state-file.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$label (got [$actual])"
  else
    assert_fail "$label (expected [$expected], got [$actual])"
  fi
}

echo "CI-runner-capacity detector regression tests (issue #1141)"
echo

# ---------------------------------------------------------------------------
# (A) decide() — pure decision truth table.
# ---------------------------------------------------------------------------
echo "(A) detector script — decision truth table"
if [[ -f "$DETECTOR" ]]; then
  assert_pass "detect-ci-runner-capacity.sh exists"

  # decide <runner_count> <online_count> <busy_count> <expected> <label>
  assert_verdict() {
    local got
    got="$(bash "$DETECTOR" --decide "$1" "$2" "$3" 2>/dev/null)"
    assert_equals "$5" "$4" "$got"
  }

  assert_verdict 0 0 0 "hosted" "zero registered runners is hosted (elastic, no fixed pool)"
  assert_verdict 4 4 3 "self-hosted pool_total=4 pool_idle=1" "4 online, 3 busy -> pool_total=4 pool_idle=1"
  assert_verdict 6 4 4 "self-hosted pool_total=4 pool_idle=0" "6 registered but only 4 online, all busy -> pool_idle=0"
  assert_verdict 4 4 0 "self-hosted pool_total=4 pool_idle=4" "4 online, none busy -> pool_idle=4 (fully idle pool)"
  # A pathological busy_count > online_count (stale/racy API read) must never
  # produce a negative idle count.
  assert_verdict 4 2 5 "self-hosted pool_total=2 pool_idle=0" "busy_count exceeding online_count clamps idle at 0, never negative"

  # Non-numeric inputs degrade to 0 for that signal rather than crashing.
  got="$(bash "$DETECTOR" --decide "" "" "" 2>/dev/null)"
  assert_equals "empty inputs degrade to hosted (0 runners)" "hosted" "$got"
else
  assert_fail "detect-ci-runner-capacity.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (B) Live-path usage/error handling — no network calls, just argument shape.
# ---------------------------------------------------------------------------
echo "(B) live-path usage handling"
if [[ -f "$DETECTOR" ]]; then
  bash "$DETECTOR" >/dev/null 2>/tmp/detect-ci-runner-capacity-usage.$$
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    assert_pass "no-args invocation exits non-zero with a usage message"
  else
    assert_fail "no-args invocation exits non-zero with a usage message (got exit 0)"
  fi
  assert_contains /tmp/detect-ci-runner-capacity-usage.$$ "usage:" "usage message printed to stderr on missing <owner/repo>"
  rm -f /tmp/detect-ci-runner-capacity-usage.$$

  bash "$DETECTOR" --decide 1 2 >/dev/null 2>/tmp/detect-ci-runner-capacity-decide-usage.$$
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    assert_pass "--decide with wrong arg count exits non-zero"
  else
    assert_fail "--decide with wrong arg count exits non-zero (got exit 0)"
  fi
  rm -f /tmp/detect-ci-runner-capacity-decide-usage.$$
else
  assert_fail "live-path usage handling (detector missing)"
fi
echo

# ---------------------------------------------------------------------------
# (C) setup step 1.36 — exists, calls the detector, clamps only a
#     config-sourced EFFECTIVE_CONCURRENCY (never an explicit --concurrency).
# ---------------------------------------------------------------------------
echo "(C) setup step 1.36 — detector wiring + narrow clamp"
if [[ -f "$SETUP_MD" ]]; then
  assert_pass "01-repo-recovery.md exists"
  assert_contains "$SETUP_MD" "### 1.36 Detect CI executor pool capacity and clamp toward it" \
    "step 1.36 heading present"
  assert_contains "$SETUP_MD" "detect-ci-runner-capacity.sh" \
    "step 1.36 invokes the detector script"
  assert_contains "$SETUP_MD" 'issues/1141' \
    "step 1.36 cites issue #1141"
  assert_contains "$SETUP_MD" '-z "<--concurrency CLI value, if passed>"' \
    "the pool clamp only fires when no explicit --concurrency was passed (mirrors #733)"
  assert_contains "$SETUP_MD" 'CI_POOL_TOTAL' \
    "step 1.36 resolves a pool-total variable"
else
  assert_fail "01-repo-recovery.md exists (missing at $SETUP_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (D) ci_capacity write-through wired into step 1.5, right after `init`.
# ---------------------------------------------------------------------------
echo "(D) ci_capacity write-through"
if [[ -f "$SETUP_MD" ]]; then
  assert_contains "$SETUP_MD" '.ci_capacity = { shape:' \
    "step 1.5 writes .ci_capacity through via session-state.sh update"
  assert_contains "$SETUP_MD" 'queued_at_start' \
    "ci_capacity write-through carries queued_at_start"
else
  assert_fail "ci_capacity write-through (setup doc missing)"
fi
echo

# ---------------------------------------------------------------------------
# (E) session-state-file.md schema documents ci_capacity.
# ---------------------------------------------------------------------------
echo "(E) session-state-file.md — schema"
if [[ -f "$SESSION_STATE_MD" ]]; then
  assert_pass "session-state-file.md exists"
  assert_contains "$SESSION_STATE_MD" '"ci_capacity"' \
    "schema block includes ci_capacity"
  assert_contains "$SESSION_STATE_MD" 'self-hosted' \
    "schema prose documents the self-hosted shape"
else
  assert_fail "session-state-file.md exists (missing at $SESSION_STATE_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (F) cleanup-summary.md — CI executor capacity banner gating.
# ---------------------------------------------------------------------------
echo "(F) cleanup-summary.md — banner"
if [[ -f "$CLEANUP_MD" ]]; then
  assert_pass "cleanup-summary.md exists"
  assert_contains "$CLEANUP_MD" 'CI executor capacity (#1141)' \
    "banner line present in the full summary shape"
  assert_contains "$CLEANUP_MD" '.ci_capacity.shape == "self-hosted"' \
    "banner gate documents the self-hosted-shape precondition"
  assert_contains "$CLEANUP_MD" 'is at least **3×**' \
    "banner gate documents the 3x queue-depth-vs-pool threshold"
  assert_contains "$CLEANUP_MD" "\`F\` (the \`In flight at exit\`" \
    "banner gate requires F (still-open PRs) > 0"
else
  assert_fail "cleanup-summary.md exists (missing at $CLEANUP_MD)"
fi
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1

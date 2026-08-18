#!/usr/bin/env bash
# Test: assert-ci-backpressure-checked.sh — mechanical gate that fails a
# backlog-slot-filling dispatch when a self-hosted repo's CI pool is
# genuinely over the backpressure threshold AND there is no fresh evidence
# steady-state.md's own per-turn check block ran (issue #1414, follow-up to
# #1156/#1399).
#
# This suite exercises ONLY the pure --decide mode (fixture inputs, zero
# I/O — no session-state.sh, no `gh`, no network). The --live wrapper is
# integration glue around session-state.sh + a live `gh` call; it composes
# the same decide() this suite pins, so pinning decide()'s truth table is
# what actually matters for correctness. See the script's own header for
# why --live has no dedicated fixture harness here (it needs a real or
# heavily-mocked session-state.sh session file, which is out of scope for
# a fast, hermetic unit suite) and for the two-verdict-only ("allow" /
# "block", no third "error" state) design rationale.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/assert-ci-backpressure-checked.test.sh

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

CHECKER="$repo_root/plugins/shipyard/scripts/assert-ci-backpressure-checked.sh"
STEADY_STATE_MD="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
INVARIANT_LINE_MD="$repo_root/plugins/shipyard/commands/do-work/invariant-line.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$label (got [$actual])"
  else
    assert_fail "$label (expected [$expected], got [$actual])"
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

echo "CI-backpressure-checked gate regression tests (issue #1414)"
echo

if [[ ! -f "$CHECKER" ]]; then
  assert_fail "assert-ci-backpressure-checked.sh exists (missing at $CHECKER)"
  echo
  total=$((pass+fail))
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$total" "$fail" "$RESET"
  exit 1
fi
assert_pass "assert-ci-backpressure-checked.sh exists"
echo

# decide <shape> <pool_total> <marker_verdict> <marker_age> <freshness_window> <backpressure_verdict>
assert_decision() {
  local got
  got="$(bash "$CHECKER" --decide "$1" "$2" "$3" "$4" "$5" "$6" 2>/dev/null)"
  assert_equals "$8" "$7" "$got"
}

# ---------------------------------------------------------------------------
echo "(A) True-negative — repo shape doesn't even trigger the gate"
# ---------------------------------------------------------------------------
assert_decision "hosted"      4 ""        999999999 300 "hold" "allow" "hosted repo -> always allow, regardless of everything else"
assert_decision "unknown"     4 ""        999999999 300 "hold" "allow" "unknown pool shape -> always allow"
assert_decision ""            4 ""        999999999 300 "hold" "allow" "empty shape -> always allow"
assert_decision "self-hosted" 0 ""        999999999 300 "hold" "allow" "self-hosted but pool_total=0 -> allow (nothing to protect)"
assert_decision "self-hosted" "" ""       999999999 300 "hold" "allow" "self-hosted, non-numeric pool_total -> allow (degrades to 0)"
echo

# ---------------------------------------------------------------------------
echo "(B) True-negative — fresh evidence the check block ran this turn"
# ---------------------------------------------------------------------------
assert_decision "self-hosted" 4 "checked" 10  300 "hold" "allow" "fresh 'checked' marker -> allow, even if a live re-read would say hold"
assert_decision "self-hosted" 4 "held"    10  300 "hold" "allow" "fresh 'held' marker -> allow (check ran; CI-cheap bias may have legitimately dispatched anyway)"
assert_decision "self-hosted" 4 "checked" 300 300 "hold" "allow" "marker exactly at the freshness-window boundary -> allow"
echo

# ---------------------------------------------------------------------------
echo "(C) True-positive — the failure mode this gate exists to catch"
# ---------------------------------------------------------------------------
assert_decision "self-hosted" 4 ""        999999999 300 "hold" "block" "no marker at all + live re-read confirms hold -> block"
assert_decision "self-hosted" 4 "checked" 301 300 "hold" "block" "marker one second past the freshness window + live hold -> block"
assert_decision "self-hosted" 4 "n/a"     999999999 300 "hold" "block" "marker verdict is a stale 'n/a' (never checked/held) + live hold -> block"
echo

# ---------------------------------------------------------------------------
echo "(D) Fail-open — every ambiguity allows, never blocks (#938 precedent)"
# ---------------------------------------------------------------------------
assert_decision "self-hosted" 4 ""        999999999 300 ""         "allow" "stale marker but live backpressure verdict unreadable (empty) -> allow"
assert_decision "self-hosted" 4 ""        999999999 300 "dispatch" "allow" "stale marker but live re-read says dispatch (not over threshold) -> allow"
assert_decision "self-hosted" 4 ""        999999999 300 "garbage"  "allow" "stale marker + unrecognized backpressure verdict -> allow (never a guess)"
echo

# Non-numeric marker age degrades to "very old" (999999999), which is
# staler than any freshness window -- the marker can never count as fresh,
# so the outcome falls through to whatever the live backpressure verdict
# says (matching a genuinely-absent marker).
got="$(bash "$CHECKER" --decide "self-hosted" 4 "checked" "not-a-number" 300 "hold" 2>/dev/null)"
assert_equals "non-numeric marker age degrades to 'very old' -> falls through to the live-verdict branch (hold) -> block" "block" "$got"

got="$(bash "$CHECKER" --decide "self-hosted" 4 "checked" "not-a-number" 300 "dispatch" 2>/dev/null)"
assert_equals "non-numeric marker age + live verdict says dispatch -> allow" "allow" "$got"

got="$(bash "$CHECKER" --decide "self-hosted" "not-a-number" "" 999999999 300 "hold" 2>/dev/null)"
assert_equals "non-numeric pool_total degrades to 0 -> allow" "allow" "$got"

got="$(bash "$CHECKER" --decide "self-hosted" 4 "" "not-a-number" "not-a-number" "hold" 2>/dev/null)"
assert_equals "non-numeric freshness window degrades to built-in default, marker still stale -> block on live hold" "block" "$got"
echo

# ---------------------------------------------------------------------------
echo "(E) --decide argument-count usage handling"
# ---------------------------------------------------------------------------
bash "$CHECKER" --decide self-hosted 4 checked 10 >/dev/null 2>/tmp/assert-ci-backpressure-usage.$$
rc=$?
if [[ "$rc" -eq 64 ]]; then
  assert_pass "--decide with too few args exits 64"
else
  assert_fail "--decide with too few args exits 64 (got $rc)"
fi
assert_contains /tmp/assert-ci-backpressure-usage.$$ "usage:" "usage message printed to stderr on wrong --decide arity"
rm -f /tmp/assert-ci-backpressure-usage.$$

bash "$CHECKER" >/dev/null 2>/tmp/assert-ci-backpressure-noargs.$$
rc=$?
if [[ "$rc" -eq 64 ]]; then
  assert_pass "no-args invocation exits 64 with a usage message"
else
  assert_fail "no-args invocation exits 64 with a usage message (got $rc)"
fi
rm -f /tmp/assert-ci-backpressure-noargs.$$
echo

# ---------------------------------------------------------------------------
echo "(F) --live never crashes when run outside any /shipyard:do-work session"
# ---------------------------------------------------------------------------
# This suite's own cwd carries no .shipyard-session-id / .shipyard-primary-root
# stash, so --live must resolve straight through to "allow" with no network
# call and no non-zero exit -- the exact fail-open path a CI runner (or any
# ad hoc invocation) hits by construction.
live_out="$(cd "$repo_root" && timeout 20 bash "$CHECKER" --live 2>/dev/null)"
live_rc=$?
assert_equals "--live outside a session prints 'allow'" "allow" "$live_out"
if [[ "$live_rc" -eq 0 ]]; then
  assert_pass "--live always exits 0 regardless of the printed verdict"
else
  assert_fail "--live always exits 0 regardless of the printed verdict (got $live_rc)"
fi
echo

# ---------------------------------------------------------------------------
echo "(G) Docs cross-references (issue #1414 AC4)"
# ---------------------------------------------------------------------------
assert_contains "$STEADY_STATE_MD" "assert-ci-backpressure-checked.sh" \
  "steady-state.md's backpressure-check section references the mechanical gate"
assert_contains "$STEADY_STATE_MD" "last_backpressure_check" \
  "steady-state.md documents the persisted evidence-marker write"
assert_contains "$INVARIANT_LINE_MD" "assert-ci-backpressure-checked.sh" \
  "invariant-line.md's ci_backpressure entry references the mechanical gate"
echo

# ---------------------------------------------------------------------------
echo "Summary"
# ---------------------------------------------------------------------------

total=$((pass+fail))
if (( fail == 0 )); then
  printf '%s%d/%d tests pass.%s\n' "$GREEN" "$pass" "$total" "$RESET"
  exit 0
else
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$total" "$fail" "$RESET"
  exit 1
fi

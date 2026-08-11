#!/usr/bin/env bash
# Test suite for milestone-aware backlog ranking (issue #1241) --
# scripts/backlog-filter.sh classify's --milestones-enabled /
# --milestones-prioritize-dispatch flags and the resulting _sort_key.
#
# Background: #1239 shipped the `milestones` config block as inert
# scaffolding. #1247 (backlog-filter.test.sh) made classify's ranking the
# single executable source of truth for /do-work's dispatch order. This
# issue makes that ranking milestone-aware WHEN a repo opts in, per the
# maintainer's final decision recorded on #1241:
#
#   0. Hard gates (drop, never sort): open Blocked by #N, needs-human-review,
#      assigned, blocked:* -- unaffected by this issue, tested elsewhere.
#   1. P0 -- global, any milestone (an emergency escape, not part of the plan)
#   2. --prioritize-label -- explicit per-run operator override
#   3. Milestone -- earliest phase with dispatchable work
#   4. P1 > P2 > unlabeled  |
#   5. Type                 |- tiebreakers, not priorities
#   6. Staleness             |
#
# The two required consistency obligations this suite pins:
#   - milestones.enabled:false OR milestones.prioritize_dispatch:false ->
#     ranking byte-identical to the pre-#1241 order (both AND-gate legs
#     tested independently, since the AND itself is the correctness
#     property, not just "the feature is off").
#   - An issue with no milestone (or an unparseable milestone title) still
#     ranks -- it sorts to the tail, never dropped.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/backlog-milestone-ranking.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../backlog-filter.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed -- backlog-filter.sh requires it" >&2
  exit 0
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

order_of() {
  local ndjson="$1"
  printf '%s\n' "$ndjson" | jq -r 'select(.verdict=="eligible") | .number'
}

classify_off() {
  # Default -- both flags omitted entirely, exactly as every pre-#1241
  # caller invokes classify today. Never called with extra args in this
  # suite (see classify_on below for the flag-passing variant).
  bash "$helper" classify --me "test-me" --trusted-authors "alice" --today "2026-08-11"
}

classify_on() {
  bash "$helper" classify --me "test-me" --trusted-authors "alice" --today "2026-08-11" \
    --milestones-enabled true --milestones-prioritize-dispatch true "$@"
}

echo "backlog-filter.sh milestone-ranking tests (issue #1241)"
echo

# --- fixture: three milestones, deliberately out of number order in the
# input array, plus one P0 sitting in the LAST phase and one unmilestoned
# issue. This is the concrete scenario the issue body opens with: "a P1 in
# the last phase outranks a P2 in the current one" under flat priority --
# and its inverse, "a P0 in the last phase still outranks a P1 in the
# first" (an explicit acceptance-criteria line).

fixture_core='[
  {"number":101,"title":"t","body":"","labels":["P2"],"milestone":"1 · Foundation","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-03-01"},
  {"number":102,"title":"t","body":"","labels":["P1"],"milestone":"3 · Polish","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":103,"title":"t","body":"","labels":["P0"],"milestone":"3 · Polish","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":104,"title":"t","body":"","labels":["P1"],"milestone":"2 · Middle","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":105,"title":"t","body":"","labels":[],"milestone":null,"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'

out=$(classify_on <<<"$fixture_core")
order=$(order_of "$out" | paste -sd, -)
# 103: P0 in phase 3 -- global, wins outright.
# 101: phase 1 (earliest with dispatchable work).
# 104: phase 2.
# 102: phase 3 (P1, non-P0) -- last real phase.
# 105: unmilestoned -- tail, after every real phase.
assert_equals "$order" "103,101,104,102,105" "(1) P0 in the LAST phase still outranks every non-P0 issue anywhere, then milestone ascending, unmilestoned last"

# --- same fixture with milestone ranking OFF (default, no flags at all) --
# must reproduce the flat P0>P1>P2>unlabeled, then staleness order exactly
# as if the milestone field were never present in the payload at all.

out=$(classify_off <<<"$fixture_core")
order=$(order_of "$out" | paste -sd, -)
# 103: P0. 102 and 104 both P1 -- 104 is older (2026-01-01 == 2026-01-01,
# tie broken by... both are equal updatedAt, so input order/stability
# applies; jq sort_by is stable, so 102 (appears before 104 in the input)
# stays first among equal keys). 101: P2. 105: unlabeled (P3 fallback).
assert_equals "$order" "103,102,104,101,105" "(2) milestones ranking OFF (no flags passed) ignores the milestone field entirely -- flat P0>P1>P2>unlabeled, then staleness"

# --- the two-leg AND-gate: EITHER flag false alone must reproduce the
# identical off-order, not just "enabled:false" -- the acceptance
# criterion says "enabled:false OR prioritize_dispatch:false", so both
# legs need independent coverage.

out_leg1=$(bash "$helper" classify --me "test-me" --trusted-authors "alice" --today "2026-08-11" \
  --milestones-enabled false --milestones-prioritize-dispatch true <<<"$fixture_core")
order_leg1=$(order_of "$out_leg1" | paste -sd, -)
assert_equals "$order_leg1" "103,102,104,101,105" "(3) milestones.enabled:false alone (prioritize_dispatch:true) reproduces the off-order byte-identically"

out_leg2=$(bash "$helper" classify --me "test-me" --trusted-authors "alice" --today "2026-08-11" \
  --milestones-enabled true --milestones-prioritize-dispatch false <<<"$fixture_core")
order_leg2=$(order_of "$out_leg2" | paste -sd, -)
assert_equals "$order_leg2" "103,102,104,101,105" "(4) milestones.prioritize_dispatch:false alone (enabled:true) reproduces the off-order byte-identically"

# --- --prioritize-label ranks ABOVE the milestone tier but BELOW global P0
# -- the maintainer's explicit "change to existing behavior" call: today
# the prioritized-label tier is outermost (can beat a P0); under milestone
# ranking, P0 always wins first.

fixture_prioritize='[
  {"number":201,"title":"t","body":"","labels":["P2","hot"],"milestone":"3 · Late","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":202,"title":"t","body":"","labels":["P1"],"milestone":"1 · Early","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":203,"title":"t","body":"","labels":["P0"],"milestone":"3 · Late","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(classify_on --prioritize-label hot <<<"$fixture_prioritize")
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "203,201,202" "(5) global P0 (203) beats --prioritize-label (201), which in turn beats the earliest milestone (202) with no prioritized label"

# --- an issue with NO --prioritize-label match, under milestone ranking,
# still ranks by milestone -- the prioritized_tier(1) is a tie across
# every non-matching issue, so milestone breaks it (this is the same
# mechanism as the pre-#1241 order, just relocated below the P0 tier).

out=$(classify_on --prioritize-label nonexistent-label <<<"$fixture_core")
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "103,101,104,102,105" "(6) a --prioritize-label that matches nothing falls through to the same milestone-ranked order as no label at all"

# --- unmilestoned and malformed-title issues both sort to the tail,
# never dropped -- the acceptance criterion's explicit "does not silently
# skip unmilestoned issues" line.

fixture_tail='[
  {"number":301,"title":"t","body":"","labels":["P2"],"milestone":"2 · Real Phase","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":302,"title":"t","body":"","labels":["P0"],"milestone":null,"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":303,"title":"t","body":"","labels":["P2"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":304,"title":"t","body":"","labels":["P2"],"milestone":"not a numbered phase","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(classify_on <<<"$fixture_tail")
order=$(order_of "$out" | paste -sd, -)
# 302 is P0 (global escape) despite having NO milestone at all -- proves
# the tail-sentinel treatment doesn't accidentally exempt P0 from the
# global tier. 301 is the one real, parseable milestone. 303 (milestone
# key entirely absent from the object) and 304 (milestone present but
# unparseable) both land in the tail bucket -- order between them is a
# tiebreak (equal priority/type/staleness -- stable sort keeps input
# order: 303 before 304).
assert_equals "$order" "302,301,303,304" "(7) P0 wins with no milestone at all; unmilestoned (absent key) and unparseable-title issues both sort to the tail, never dropped"

# --- within-milestone tiebreakers (P1>P2>unlabeled, then type, then
# staleness) are unaffected by milestone ranking -- they operate WITHIN
# the milestone tier exactly as they did across the whole backlog before.

fixture_tiebreak='[
  {"number":401,"title":"chore: z","body":"","labels":["P2"],"milestone":"1 · Phase","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-03-01"},
  {"number":402,"title":"fix(x): y","body":"","labels":["P1"],"milestone":"1 · Phase","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-04-01"},
  {"number":403,"title":"an old bug","body":"","labels":["bug","P1"],"milestone":"1 · Phase","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(classify_on <<<"$fixture_tiebreak")
order=$(order_of "$out" | paste -sd, -)
# 403: P1 + bug (type_rank 0) beats 402: P1 + fix(*) (type_rank 1), same
# priority and milestone. 401 is P2, same milestone, behind both P1s.
assert_equals "$order" "403,402,401" "(8) within one milestone, priority then type then staleness still applies exactly as the milestone-off order does"

# --- investigate_candidates ranking is untouched by milestone ranking --
# no prioritized-label or type tier there, and no milestone tier either
# (scope: raw_backlog only, per 04d-investigate-routing.md).

fixture_investigate='[
  {"number":501,"title":"t","body":"","labels":["needs-triage","P1"],"milestone":"3 · Late","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-02-01"},
  {"number":502,"title":"t","body":"","labels":["needs-triage","P0"],"milestone":"1 · Early","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-03-01"}
]'
out=$(classify_on <<<"$fixture_investigate")
order=$(printf '%s\n' "$out" | jq -r 'select(.verdict=="route" and .reason=="investigate") | .number' | paste -sd, -)
assert_equals "$order" "502,501" "(9) investigate_candidates ranking (priority then staleness) is unaffected by milestone ranking, even when the milestone-on flags are set"

# --- bad usage: invalid values for the two new flags exit 64, matching
# the existing --investigate-dispatch validation pattern.

out=$(bash "$helper" classify --me x --trusted-authors a --milestones-enabled maybe </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(10) invalid --milestones-enabled exits 64"

out=$(bash "$helper" classify --me x --trusted-authors a --milestones-prioritize-dispatch maybe </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(11) invalid --milestones-prioritize-dispatch exits 64"

# --- composition with #1248's --respect-assignees ---------------------------
# The two features are structurally orthogonal and must stay that way:
# --respect-assignees decides MEMBERSHIP in the eligible bucket (it gates the
# drop:assigned-other clause), while the milestone flags decide only the ORDER
# of whatever ends up in that bucket. Nothing in either implementation should
# make one observable through the other. Both landed independently against the
# same classify() -- same case-statement, same validation block, same jq
# --argjson list -- so a bad merge between them is the realistic way this
# breaks, and it would break silently (a wrong rank, or a resurrected drop).
#
# The fixture is built so all FOUR flag combinations yield a DIFFERENT order.
# That is the actual proof of independence: if either flag were being ignored,
# dropped on the floor by a merge, or aliased onto the other, at least two of
# the four expectations below would collide.
#
#   601  P1  milestone 1  assigned to "bob"      (other-assigned, newest)
#   602  P1  milestone 2  unassigned
#   603  P1  milestone 3  assigned to "test-me"  (self-assigned, oldest)
#   604  P0  milestone 3  unassigned             (global P0 escape)

fixture_compose='[
  {"number":601,"title":"t","body":"","labels":["P1"],"milestone":"1 · Foundation","assignees":["bob"],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-03-01"},
  {"number":602,"title":"t","body":"","labels":["P1"],"milestone":"2 · Middle","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-02-01"},
  {"number":603,"title":"t","body":"","labels":["P1"],"milestone":"3 · Polish","assignees":["test-me"],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":604,"title":"t","body":"","labels":["P0"],"milestone":"3 · Polish","assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'

classify_flags() {
  bash "$helper" classify --me "test-me" --trusted-authors "alice" --today "2026-08-11" "$@"
}

# (a) milestones ON + --respect-assignees true: 601 drops out entirely; the
#     survivors rank P0-global first, then ascending milestone.
out=$(classify_flags --milestones-enabled true --milestones-prioritize-dispatch true \
  --respect-assignees true <<<"$fixture_compose")
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "604,602,603" "(12) compose: milestones ON + --respect-assignees true -- assigned-other still drops, survivors still milestone-ranked"
assert_equals "$(printf '%s\n' "$out" | jq -r 'select(.number==601) | .verdict + ":" + .reason')" "drop:assigned-other" "(12b) compose: milestone ranking does not resurrect the assigned-other drop"

# (b) milestones ON + --respect-assignees false: 601 rejoins the bucket and
#     takes its milestone-1 slot -- i.e. the newly-admitted issue is ranked by
#     the milestone key, not appended arbitrarily.
out=$(classify_flags --milestones-enabled true --milestones-prioritize-dispatch true \
  --respect-assignees false <<<"$fixture_compose")
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "604,601,602,603" "(13) compose: milestones ON + --respect-assignees false -- the re-admitted assigned-other issue sorts into its milestone slot"

# (c) milestones OFF + --respect-assignees true: the drop still applies and
#     ordering falls back to flat priority-then-staleness, ignoring milestones.
out=$(classify_flags --respect-assignees true <<<"$fixture_compose")
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "604,603,602" "(14) compose: milestones OFF + --respect-assignees true -- drop applies, order is flat priority/staleness (milestone ignored)"

# (d) milestones OFF + --respect-assignees false: everything is eligible and
#     ordering is flat -- the pre-#1241, pre-#1248-default baseline.
out=$(classify_flags --respect-assignees false <<<"$fixture_compose")
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "604,603,602,601" "(15) compose: milestones OFF + --respect-assignees false -- all eligible, flat priority/staleness order"

# (e) argv order-independence: the three flags share one case-statement, so a
#     merge that mis-nests a branch could make parsing position-sensitive.
out=$(classify_flags --respect-assignees false --milestones-prioritize-dispatch true \
  --milestones-enabled true <<<"$fixture_compose")
assert_equals "$(order_of "$out" | paste -sd, -)" "604,601,602,603" "(16) compose: the three flags parse identically regardless of argv order"

echo
echo "----------------------------------------"
echo "pass=$pass fail=$fail"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0

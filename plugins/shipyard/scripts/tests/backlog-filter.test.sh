#!/usr/bin/env bash
# Test suite for scripts/backlog-filter.sh (issue #1247).
#
# backlog-filter.sh is the single, fixture-testable implementation of
# /shipyard:do-work's backlog eligibility filter -- the predicate that used
# to be re-derived from prose at three independent call-sites
# (setup/04-backlog-divert.md step 4, steady-state.md step C, drain.md's
# termination-assertion step 4) and drifted twice as a result (#332, #1194),
# plus a third divergence caught in the spec text itself (needs-triage
# classified as a drop at two call-sites and a route at the third).
#
# This suite exercises `classify` only -- `closed-by-healthy-pr` performs
# live `gh`/gh-batch.sh network calls by design (see the script's own
# header comment for why that split exists) and is not fixture-tested here;
# its bad-usage paths are covered, its network path is not.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/backlog-filter.test.sh

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

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'
    fail=$((fail+1))
  fi
}

# verdict_of <ndjson> <number> -- extract "verdict" (or "verdict:reason")
# for a given issue number out of classify's NDJSON stdout.
verdict_of() {
  local ndjson="$1" number="$2"
  printf '%s\n' "$ndjson" | jq -r --argjson n "$number" '
    select(.number == $n) | if (.reason // "") == "" then .verdict else (.verdict + ":" + .reason) end
  '
}

# order_of <ndjson> -- newline list of issue numbers in output order.
order_of() {
  local ndjson="$1"
  printf '%s\n' "$ndjson" | jq -r '.number'
}

classify() {
  bash "$helper" classify --me "test-me" --trusted-authors "alice,bob" --today "2026-08-11" "$@"
}

echo "backlog-filter.sh tests (issue #1247)"
echo

# --- bad usage -------------------------------------------------------------

out=$(bash "$helper" classify </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(1) missing --me exits 64"
assert_contains "$out" "--me is required" "(1) missing --me explains why"

out=$(bash "$helper" classify --me x </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(2) missing --trusted-authors exits 64"

out=$(bash "$helper" classify --me x --trusted-authors a --investigate-dispatch maybe </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(3) invalid --investigate-dispatch exits 64"

out=$(bash "$helper" classify --me x --trusted-authors a --today "not-a-date" </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(4) invalid --today exits 64"

out=$(bash "$helper" bogus-subcommand 2>&1); rc=$?
assert_equals "$rc" "64" "(5) unknown subcommand exits 64"

out=$(bash "$helper" 2>&1); rc=$?
assert_equals "$rc" "64" "(6) no subcommand exits 64"

out=$(bash "$helper" --help 2>&1); rc=$?
assert_equals "$rc" "0" "(7) --help exits 0"

out=$(bash "$helper" closed-by-healthy-pr 2>&1); rc=$?
assert_equals "$rc" "64" "(8) closed-by-healthy-pr missing --repo exits 64"

out=$(bash "$helper" closed-by-healthy-pr --repo acme/widgets 2>&1); rc=$?
assert_equals "$rc" "64" "(9) closed-by-healthy-pr missing --me exits 64"

out=$(bash "$helper" summary </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(9a) summary missing --me exits 64"
assert_contains "$out" "--me is required" "(9a) summary missing --me explains why"

# --- empty input -------------------------------------------------------------

out=$(printf '%s' '[]' | classify); rc=$?
assert_equals "$rc" "0" "(10) empty array exits 0"
assert_equals "$out" "" "(10) empty array emits nothing"

# --- #1194 regression: assignee handling ------------------------------------
# The regression: a shorthand like "drop issues with no assignee" (or
# "--assignee @me" as a required filter) is NOT the same predicate as "drop
# issues assigned to someone OTHER than @me". Self-assigned issues, and
# unassigned issues, must both pass; only other-assigned issues drop.

fixture_assignees='[
  {"number":101,"title":"unassigned","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":102,"title":"self-assigned","body":"","labels":[],"assignees":["test-me"],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":103,"title":"other-assigned","body":"","labels":[],"assignees":["someone-else"],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":104,"title":"self-plus-other","body":"","labels":[],"assignees":["test-me","someone-else"],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_assignees" | classify)
assert_equals "$(verdict_of "$out" 101)" "eligible" "(11) #1194: unassigned issue is eligible"
assert_equals "$(verdict_of "$out" 102)" "eligible" "(12) #1194: self-assigned (@me) issue is eligible -- the resumable-work case"
assert_equals "$(verdict_of "$out" 103)" "drop:assigned-other" "(13) #1194: other-assigned issue drops"
assert_equals "$(verdict_of "$out" 104)" "eligible" "(14) #1194: self+other assigned issue is still eligible (me is among assignees)"

# --- #332 regression: closed-PR does not lock the issue ---------------------
# The regression: excluding every issue that ever had ANY linked PR
# (including closed/abandoned ones) erased resumable work. This filter
# only drops on --closed-by-healthy-pr membership (an OPEN, healthy PR) --
# an issue with no entry in that set is eligible regardless of whether it
# had a prior, now-closed PR (the caller simply never puts a closed PR's
# issue numbers into that set to begin with).

fixture_closed_pr='[{"number":201,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_closed_pr" | classify)
assert_equals "$(verdict_of "$out" 201)" "eligible" "(15) #332: issue with no entry in closed-by-healthy-pr set is eligible (a prior closed PR does not lock it)"

out=$(printf '%s' "$fixture_closed_pr" | classify --closed-by-healthy-pr 201)
assert_equals "$(verdict_of "$out" 201)" "drop:closed-by-healthy-pr" "(16) closed-by-healthy-pr membership drops the issue"

# --- needs-triage divergence (the spec-text contradiction this issue names) --
# setup.md never dropped needs-triage via the gate-label enumeration --
# it always routed it to investigate_candidates. steady-state.md and
# drain.md's prose had it listed INSIDE the gate-label drop enumeration,
# contradicting setup.md in the same repo. The executable filter can only
# have one behavior: route, never gate/drop, by label alone.

fixture_triage='[{"number":301,"title":"t","body":"ordinary body","labels":["needs-triage"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_triage" | classify)
assert_equals "$(verdict_of "$out" 301)" "route:investigate" "(17) needs-triage-labeled trusted-author issue routes to investigate, never gate/drop"

out=$(printf '%s' "$fixture_triage" | classify --investigate-dispatch false)
assert_equals "$(verdict_of "$out" 301)" "drop:investigate-disabled" "(18) needs-triage drops (not gates) when triage.investigate_dispatch is false"

# --- agent-console is a route, not a drop -----------------------------------

fixture_console='[{"number":401,"title":"t","body":"","labels":["agent-console"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_console" | classify)
assert_equals "$(verdict_of "$out" 401)" "route:operator" "(19) agent-console labeled issue routes to operator, never a plain drop"

# --- dispatch-gate labels ----------------------------------------------------

fixture_gates='[
  {"number":501,"title":"t","body":"","labels":["blocked:ci"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":502,"title":"t","body":"","labels":["wontfix"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":503,"title":"t","body":"","labels":["discussion"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":504,"title":"t","body":"","labels":["needs-human-review"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":505,"title":"t","body":"","labels":["tracking"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_gates" | classify)
assert_equals "$(verdict_of "$out" 501)" "gate:blocked:ci" "(20) blocked:ci gates"
assert_equals "$(verdict_of "$out" 502)" "gate:wontfix" "(21) wontfix gates"
assert_equals "$(verdict_of "$out" 503)" "gate:discussion" "(22) discussion gates"
assert_equals "$(verdict_of "$out" 504)" "gate:needs-human-review" "(23) needs-human-review gates"
assert_equals "$(verdict_of "$out" 505)" "gate:tracking" "(24) tracking gates"

# --- untrusted author ---------------------------------------------------------

fixture_untrusted='[{"number":601,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"mallory"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_untrusted" | classify)
assert_equals "$(verdict_of "$out" 601)" "drop:untrusted-author" "(25) untrusted author drops -- checked before every other clause"

fixture_untrusted_case='[{"number":602,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"ALICE"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_untrusted_case" | classify)
assert_equals "$(verdict_of "$out" 602)" "eligible" "(26) author-login match is case-insensitive"

# --- peer-claimed --------------------------------------------------------------

fixture_peer='[{"number":701,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_peer" | classify --peer-claimed "701")
assert_equals "$(verdict_of "$out" 701)" "drop:peer-claimed" "(27) peer-claimed number drops"

out=$(printf '%s' "$fixture_peer" | classify --peer-claimed "999")
assert_equals "$(verdict_of "$out" 701)" "eligible" "(28) not-claimed number is unaffected by an unrelated peer-claimed set"

# --- Blocked by #N still-open --------------------------------------------------

fixture_blocked='[
  {"number":801,"title":"blocker","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":802,"title":"blocked","body":"Blocked by #801","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":803,"title":"blocked-by-absent","body":"Blocked by #99999","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_blocked" | classify)
assert_equals "$(verdict_of "$out" 802)" "drop:blocked-by-open-issue" "(29) Blocked by #N drops when #N is present in the open payload"
assert_equals "$(verdict_of "$out" 803)" "eligible" "(30) Blocked by #N does not drop when #N is absent from the open payload (closed/unknown)"

# --- time-gate ------------------------------------------------------------------

fixture_timegate='[
  {"number":901,"title":"t","body":"<!-- do-work-blocked-until: 2099-01-01 -->\nrest of body","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":902,"title":"t","body":"<!-- do-work-blocked-until: 2000-01-01 -->\nrest of body","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":903,"title":"t","body":"some text\n<!-- do-work-blocked-until: 2099-01-01 -->","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":904,"title":"t","body":"<!-- do-work-blocked-until: not-a-date -->\nrest","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":905,"title":"t","body":"no marker at all","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_timegate" | classify)
assert_equals "$(verdict_of "$out" 901)" "drop:time-gated" "(31) future do-work-blocked-until on line 1 drops"
assert_equals "$(verdict_of "$out" 902)" "eligible" "(32) past do-work-blocked-until on line 1 is eligible -- self-clearing"
assert_equals "$(verdict_of "$out" 903)" "eligible" "(33) marker NOT on line 1 is not live -- position discipline"
assert_equals "$(verdict_of "$out" 904)" "eligible" "(34) unparseable date on line 1 fails open -- not blocked"
assert_equals "$(verdict_of "$out" 905)" "eligible" "(35) no marker at all is unaffected"

# --- bot-shaped author / symptom-shaped body (investigate signals 2 and 3) ---

fixture_bot='[{"number":1001,"title":"t","body":"ordinary text","labels":[],"assignees":[],"author":{"login":"sentry[bot]"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(bash "$helper" classify --me "test-me" --trusted-authors "alice,sentry[bot]" --today "2026-08-11" < <(printf '%s' "$fixture_bot"))
assert_equals "$(verdict_of "$out" 1001)" "route:investigate" "(36) bot-shaped trusted author routes to investigate"

fixture_symptom='[{"number":1002,"title":"crash","body":"Traceback (most recent call last):\n  File x, line 1","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_symptom" | classify)
assert_equals "$(verdict_of "$out" 1002)" "route:investigate" "(37) symptom-shaped body (traceback) routes to investigate"

fixture_no_symptom='[{"number":1003,"title":"a normal bug report","body":"clicking the button does nothing, expected it to submit the form","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_no_symptom" | classify)
assert_equals "$(verdict_of "$out" 1003)" "eligible" "(38) an ordinary bug report with no crash markers is NOT routed to investigate"

# --- ranking: eligible list ---------------------------------------------------
# prioritized-label tier, then P0>P1>P2>unlabeled, then bug>fix(*)>feat(*)>
# chore(*)>other, then oldest-updatedAt-first within a tier.

fixture_rank='[
  {"number":1101,"title":"chore: z","body":"","labels":["P2"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-03-01"},
  {"number":1102,"title":"feat(x): y","body":"","labels":["P0"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-02-01"},
  {"number":1103,"title":"an old bug","body":"","labels":["bug","P0"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":1104,"title":"fix(x): w","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-04-01"}
]'
out=$(printf '%s' "$fixture_rank" | classify)
order=$(order_of "$out" | paste -sd, -)
# #1103: P0 + bug (type_rank 0) beats #1102: P0 + feat (type_rank 2), same
# priority tier, so type breaks the tie. #1104 is unlabeled (P3) and #1101
# is P2 -- both behind the P0 pair.
assert_equals "$order" "1103,1102,1101,1104" "(39) eligible ranking: priority then type then staleness"

fixture_prioritize='[
  {"number":1201,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":1202,"title":"t","body":"","labels":["hot"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-06-01"}
]'
out=$(printf '%s' "$fixture_prioritize" | classify --prioritize-label hot)
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "1202,1201" "(40) --prioritize-label tier beats every other tier, including staleness"

# --- ranking: investigate list (priority + staleness only, no type tier) ----

fixture_rank_investigate='[
  {"number":1301,"title":"fix(x): a","body":"","labels":["needs-triage","P1"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-02-01"},
  {"number":1302,"title":"chore: b","body":"","labels":["needs-triage","P0"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-03-01"},
  {"number":1303,"title":"z","body":"","labels":["needs-triage"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_rank_investigate" | classify)
order=$(printf '%s\n' "$out" | jq -r 'select(.verdict=="route" and .reason=="investigate") | .number' | paste -sd, -)
assert_equals "$order" "1302,1301,1303" "(41) investigate ranking: P0 > P1 > unlabeled, then staleness -- no type tier"

# --- reason field is absent (not null) on eligible verdicts -------------------

fixture_reason='[{"number":1401,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}]'
out=$(printf '%s' "$fixture_reason" | classify)
has_reason_key=$(printf '%s\n' "$out" | jq -r 'has("reason")')
assert_equals "$has_reason_key" "false" "(42) eligible verdict has no reason key at all (not a null-valued one)"

# --- order grouping: eligible first, then investigate, then everything else --

fixture_grouping='[
  {"number":1501,"title":"t","body":"","labels":["wontfix"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":1502,"title":"t","body":"","labels":["needs-triage"],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"},
  {"number":1503,"title":"t","body":"","labels":[],"assignees":[],"author":{"login":"alice"},"createdAt":"a","updatedAt":"2026-01-01"}
]'
out=$(printf '%s' "$fixture_grouping" | classify)
order=$(order_of "$out" | paste -sd, -)
assert_equals "$order" "1503,1502,1501" "(43) output groups eligible first, investigate second, everything else last"

# --- summary — unfiltered_open_count / me_assigned_open (issue #1246) -------
# The invariant-line tokens the orchestrator stamps at drain.md's
# termination step 4 and steady-state.md step C, from the SAME wide-fetch
# payload classify reads, BEFORE classification runs.

out=$(printf '%s' '[]' | bash "$helper" summary --me "test-me")
assert_equals "$out" '{"unfiltered_open_count":0,"me_assigned_open":0}' "(44) summary on an empty array returns both counts as 0"

out=$(printf '' | bash "$helper" summary --me "test-me")
assert_equals "$out" '{"unfiltered_open_count":0,"me_assigned_open":0}' "(45) summary on genuinely empty stdin (not even '[]') defaults to an empty array, same as classify"

fixture_summary='[
  {"number":2001,"assignees":["Alice"]},
  {"number":2002,"assignees":["bob"]},
  {"number":2003,"assignees":[]},
  {"number":2004,"assignees":["alice","carol"]}
]'
out=$(printf '%s' "$fixture_summary" | bash "$helper" summary --me "ALICE")
assert_equals "$out" '{"unfiltered_open_count":4,"me_assigned_open":2}' "(46) summary counts total issues and case-insensitively matches --me against assignees (alone or alongside others)"

out=$(printf '%s' "$fixture_summary" | bash "$helper" summary --me "nobody")
assert_equals "$out" '{"unfiltered_open_count":4,"me_assigned_open":0}' "(47) summary: unfiltered_open_count is unaffected by who --me is; me_assigned_open is 0 when --me matches no assignee"

fixture_summary_missing_assignees='[{"number":2101},{"number":2102,"assignees":["alice"]}]'
out=$(printf '%s' "$fixture_summary_missing_assignees" | bash "$helper" summary --me "alice")
assert_equals "$out" '{"unfiltered_open_count":2,"me_assigned_open":1}' "(48) summary tolerates an issue object with no assignees key at all (defensive // [])"

echo
echo "----------------------------------------"
echo "pass=$pass fail=$fail"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0

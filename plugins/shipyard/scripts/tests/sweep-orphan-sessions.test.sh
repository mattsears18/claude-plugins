#!/usr/bin/env bash
# Test suite for scripts/sweep-orphan-sessions.sh (issue #1182).
#
# Extracted from do-work/setup's step 1.6 inline orphan-session sweep loop
# (a piped `find | while read` that had no test coverage of its own).
# Covers the same "age floor AND liveness" safety shape sweep-orphan-tmp.sh
# already established (issue #858): a session file only qualifies for
# reap once it's BOTH older than the stale floor AND its owning process
# is confirmed dead via session-state.sh's `is-active` check. Either gate
# alone must NOT be enough to trigger a reap.
#
# Pure bash + the real session-state.sh / cost-history.sh siblings (run
# against a throwaway --shipyard-home, never the real $HOME/.shipyard).
# Run with:
#   bash plugins/shipyard/scripts/tests/sweep-orphan-sessions.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../sweep-orphan-sessions.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
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

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file not found: %s\n' "$path"
    fail=$((fail+1))
  fi
}

assert_file_missing() {
  local path="$1" label="$2"
  if [[ ! -e "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file still present: %s\n' "$path"
    fail=$((fail+1))
  fi
}

# Set a file's mtime to <minutes> ago, portable across BSD (macOS, local
# dev) and GNU (ubuntu-latest CI) `touch`/`date` dialects — same pattern
# sweep-orphan-tmp.test.sh's own backdate() uses.
backdate() {
  local path="$1" mins="$2" ts
  ts=$(date -v-"${mins}M" +%Y%m%d%H%M 2>/dev/null) || \
    ts=$(date -d "${mins} minutes ago" +%Y%m%d%H%M 2>/dev/null)
  touch -t "$ts" "$path"
}

mktmphome() { mktemp -d; }

# implausibly large — not a live pid on any test host
dead_pid=99999999
# our own pid — guaranteed alive for the duration of this test run
alive_pid=$$

write_session() {
  local path="$1" pid="$2"
  mkdir -p "$(dirname "$path")"
  jq -n --argjson pid "$pid" '{pid: $pid, repo: "test/repo"}' > "$path"
}

# write_session_with_state — issue #1252 fixtures. Extends write_session
# with `.in_flight` and `.session_end`, the two fields the abnormal-exit
# advisory reads. `in_flight_count` seeds that many synthetic slots;
# `session_end_reason` is either "" (field omitted/null — simulates a
# session that never reached record-session-end) or one of the recorded
# reason strings.
write_session_with_state() {
  local path="$1" pid="$2" in_flight_count="$3" session_end_reason="$4"
  mkdir -p "$(dirname "$path")"
  local in_flight_json="{}"
  if [[ "$in_flight_count" -gt 0 ]]; then
    in_flight_json=$(jq -n --argjson n "$in_flight_count" \
      '[range($n)] | map({("slot" + (. | tostring)): {kind: "issue", target: 1252}}) | add')
  fi
  local session_end_json="null"
  if [[ -n "$session_end_reason" ]]; then
    session_end_json=$(jq -n --arg r "$session_end_reason" '{reason: $r, detail: null, recorded_at: "2026-08-10T12:00:00Z"}')
  fi
  jq -n --argjson pid "$pid" --argjson in_flight "$in_flight_json" --argjson session_end "$session_end_json" \
    '{pid: $pid, repo: "test/repo", in_flight: $in_flight, session_end: $session_end}' > "$path"
}

echo "sweep-orphan-sessions.sh tests (issue #1182)"
echo

# --- bad usage -------------------------------------------------------------

out=$(bash "$helper" sweep 2>&1); rc=$?
assert_equals "$rc" "64" "(1) missing --shipyard-home exits 64"
assert_contains "$out" "shipyard-home is required" "(1) missing --shipyard-home explains why"

tmphome=$(mktmphome)
out=$(bash "$helper" sweep --shipyard-home "$tmphome" 2>&1); rc=$?
assert_equals "$rc" "64" "(2) missing --current-session-id exits 64"
assert_contains "$out" "current-session-id is required" "(2) missing --current-session-id explains why"
rm -rf "$tmphome"

tmphome=$(mktmphome)
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "s1" --stale-min notanumber 2>&1); rc=$?
assert_equals "$rc" "64" "(3) non-numeric --stale-min exits 64"
rm -rf "$tmphome"

out=$(bash "$helper" bogus-subcommand 2>&1); rc=$?
assert_equals "$rc" "64" "(4) unknown subcommand exits 64"

out=$(bash "$helper" 2>&1); rc=$?
assert_equals "$rc" "64" "(5) no subcommand exits 64"

out=$(bash "$helper" --help 2>&1); rc=$?
assert_equals "$rc" "0" "(6) --help exits 0"

# --- empty layout ------------------------------------------------------------

tmphome=$(mktmphome)
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "s1" 2>&1); rc=$?
assert_equals "$rc" "0" "(7) empty \$SHIPYARD_HOME sweep exits 0"
assert_contains "$out" "summary: reaped=0 skipped=0" "(7) empty layout reaps nothing, skips nothing"
rm -rf "$tmphome"

# --- the acceptance case: stale + dead-pid session is reaped ---------------

tmphome=$(mktmphome)
orphan_json="$tmphome/sessions/dead-orphan.json"
write_session "$orphan_json" "$dead_pid"
backdate "$orphan_json" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" 2>&1); rc=$?
assert_equals "$rc" "0" "(8) sweep with a stale, dead-pid orphan exits 0"
assert_file_missing "$orphan_json" "(8) stale + dead-pid session file is reaped"
assert_contains "$out" "reaped: dead-orphan" "(8) reap is logged, names the session id"
assert_contains "$out" "summary: reaped=1 skipped=0" "(8) summary counts the reap"
rm -rf "$tmphome"

# --- NOT swept: fresh (< 30min) session, regardless of pid liveness --------

tmphome=$(mktmphome)
fresh_json="$tmphome/sessions/fresh-session.json"
write_session "$fresh_json" "$dead_pid"
# no backdate — mtime is "now"
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" 2>&1); rc=$?
assert_file_exists "$fresh_json" "(9) fresh (< 30min) session with a dead pid is NOT reaped — mtime floor not crossed by find -mmin"
assert_contains "$out" "summary: reaped=0 skipped=0" "(9) fresh session is never even considered (find -mmin +30 excludes it)"
rm -rf "$tmphome"

# --- NOT swept: owning process is still alive, even though stale by mtime --

tmphome=$(mktmphome)
alive_json="$tmphome/sessions/still-active.json"
write_session "$alive_json" "$alive_pid"
backdate "$alive_json" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "some-other-session" 2>&1); rc=$?
assert_file_exists "$alive_json" "(10) stale-by-mtime session with a LIVE writer pid is NOT reaped"
assert_contains "$out" "skip: still-active (owning process still alive)" "(10) skip reason names the live-pid gate"
assert_contains "$out" "summary: reaped=0 skipped=1" "(10) live-pid session is counted as skipped"
rm -rf "$tmphome"

# --- the current session's own file is never touched, even if stale --------

tmphome=$(mktmphome)
self_json="$tmphome/sessions/current-run.json"
write_session "$self_json" "$dead_pid"
backdate "$self_json" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "current-run" 2>&1); rc=$?
assert_file_exists "$self_json" "(11) the sweep's own --current-session-id file is skipped outright, never reaped"
assert_contains "$out" "summary: reaped=0 skipped=0" "(11) self-skip isn't counted as reaped or skipped"
rm -rf "$tmphome"

# --- mixed batch: one reaped, one alive-skipped, one self, one fresh -------

tmphome=$(mktmphome)
mixed_dead="$tmphome/sessions/mixed-dead.json"
mixed_alive="$tmphome/sessions/mixed-alive.json"
mixed_self="$tmphome/sessions/mixed-self.json"
mixed_fresh="$tmphome/sessions/mixed-fresh.json"
write_session "$mixed_dead" "$dead_pid"; backdate "$mixed_dead" 60
write_session "$mixed_alive" "$alive_pid"; backdate "$mixed_alive" 60
write_session "$mixed_self" "$dead_pid"; backdate "$mixed_self" 60
write_session "$mixed_fresh" "$dead_pid"
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "mixed-self" 2>&1); rc=$?
assert_file_missing "$mixed_dead" "(12) mixed batch: dead-pid stale session reaped"
assert_file_exists "$mixed_alive" "(12) mixed batch: alive-pid stale session untouched"
assert_file_exists "$mixed_self" "(12) mixed batch: current session's own file untouched"
assert_file_exists "$mixed_fresh" "(12) mixed batch: fresh session untouched"
assert_contains "$out" "summary: reaped=1 skipped=1" "(12) mixed batch summary: 1 reaped, 1 skipped (self + fresh not counted)"
rm -rf "$tmphome"

# --- reap-audit line is written for the reaped session ----------------------

tmphome=$(mktmphome)
audit_json="$tmphome/sessions/audit-me.json"
write_session "$audit_json" "$dead_pid"
backdate "$audit_json" 45
bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" --reaper-session-id "reaper-1" >/dev/null 2>&1
audit_log="$tmphome/reap-audit.jsonl"
assert_file_exists "$audit_log" "(13) reap writes a reap-audit.jsonl entry"
audit_line=$(cat "$audit_log" 2>/dev/null)
assert_contains "$audit_line" "\"reaped_session_id\":\"audit-me\"" "(13) audit line names the reaped session id"
assert_contains "$audit_line" "\"reaper_session_id\":\"reaper-1\"" "(13) audit line names the reaper session id"
assert_contains "$audit_line" "\"action\":\"reaped-session-file\"" "(13) audit line's action is reaped-session-file"
rm -rf "$tmphome"

# --- --reaper-session-id defaults to --current-session-id when unset -------

tmphome=$(mktmphome)
default_reaper_json="$tmphome/sessions/default-reaper.json"
write_session "$default_reaper_json" "$dead_pid"
backdate "$default_reaper_json" 45
bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" >/dev/null 2>&1
audit_line=$(cat "$tmphome/reap-audit.jsonl" 2>/dev/null)
assert_contains "$audit_line" "\"reaper_session_id\":\"live-session\"" "(14) --reaper-session-id defaults to --current-session-id"
rm -rf "$tmphome"

# --- --dry-run never removes anything ---------------------------------------

tmphome=$(mktmphome)
dry_json="$tmphome/sessions/would-reap.json"
write_session "$dry_json" "$dead_pid"
backdate "$dry_json" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" --dry-run 2>&1)
assert_file_exists "$dry_json" "(15) --dry-run never removes the session file"
assert_contains "$out" "reaped (dry-run): would-reap" "(15) --dry-run still reports what it would reap"
assert_contains "$out" "summary: reaped=1 skipped=0" "(15) --dry-run still counts toward the summary"
rm -rf "$tmphome"

# --- --stale-min override ----------------------------------------------------

tmphome=$(mktmphome)
override_json="$tmphome/sessions/override.json"
write_session "$override_json" "$dead_pid"
backdate "$override_json" 2
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" --stale-min 1 2>&1)
assert_file_missing "$override_json" "(16) --stale-min lets the floor be lowered below the 30-min default"
rm -rf "$tmphome"

tmphome=$(mktmphome)
still_young="$tmphome/sessions/still-young.json"
write_session "$still_young" "$dead_pid"
backdate "$still_young" 2
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" --stale-min 30 2>&1)
assert_file_exists "$still_young" "(17) --stale-min 30 (explicit default) still protects a 2-min-old session"
rm -rf "$tmphome"

# --- abnormal-exit advisory (issue #1252) -----------------------------------
# A dead-PID orphan with a still-non-empty .in_flight and no .session_end
# is exactly the signature the issue's own observation table documents: the
# orchestrator process ended while it still believed workers were running,
# and never reached cleanup-summary.md's normal exit path to record why.
# By the time a file reaches this loop the is-active gate has already
# confirmed the owning PID is dead, so this is the sweep's one chance to
# surface the abnormal termination before the file (and the signal) is gone.

tmphome=$(mktmphome)
abnormal_json="$tmphome/sessions/died-mid-flight.json"
write_session_with_state "$abnormal_json" "$dead_pid" 1 ""
backdate "$abnormal_json" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" 2>&1)
assert_file_missing "$abnormal_json" "(18) abnormal orphan (in_flight non-empty, no session_end) is still reaped"
assert_contains "$out" "reaped: died-mid-flight" "(18) abnormal orphan reap line names the session id"
assert_contains "$out" "[abnormal-exit: no session_end recorded, in_flight=1]" "(18) abnormal orphan reap line carries the #1252 advisory"
rm -rf "$tmphome"

# --- NOT flagged: session recorded why it ended, even with a residual slot -
# Defensive coverage of the detector's own logic in isolation — in
# practice .in_flight is empty by the time record-session-end runs, but the
# advisory should key off .session_end being present, not off in_flight
# alone, so this combination (however contrived) must not false-positive.

tmphome=$(mktmphome)
recorded_json="$tmphome/sessions/recorded-clean.json"
write_session_with_state "$recorded_json" "$dead_pid" 1 "completed"
backdate "$recorded_json" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" 2>&1)
assert_file_missing "$recorded_json" "(19) session with .session_end recorded is still reaped"
assert_contains "$out" "reaped: recorded-clean" "(19) recorded-clean reap line names the session id"
if [[ "$out" == *"abnormal-exit"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(19) no abnormal-exit advisory when .session_end was recorded"
  printf '    actual: %s\n' "$out"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(19) no abnormal-exit advisory when .session_end was recorded"
  pass=$((pass+1))
fi
rm -rf "$tmphome"

# --- NOT flagged: no session_end, but in_flight was already empty ----------
# A session with no residual work (it quiesced before dying, or predates
# this field entirely) is not the failure mode this advisory targets —
# only pair with a non-empty in_flight.

tmphome=$(mktmphome)
quiet_json="$tmphome/sessions/quiet-orphan.json"
write_session_with_state "$quiet_json" "$dead_pid" 0 ""
backdate "$quiet_json" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" 2>&1)
assert_file_missing "$quiet_json" "(20) session with no .session_end but empty in_flight is still reaped"
if [[ "$out" == *"abnormal-exit"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(20) no abnormal-exit advisory when in_flight was already empty"
  printf '    actual: %s\n' "$out"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(20) no abnormal-exit advisory when in_flight was already empty"
  pass=$((pass+1))
fi
rm -rf "$tmphome"

# --- reap-audit line carries the same #1252 fields (cross-check against
# session-state.sh's own cleanup --reap-audit coverage, exercised here
# through the sweep's actual call path rather than a direct helper call).

tmphome=$(mktmphome)
audit_abnormal_json="$tmphome/sessions/audit-abnormal.json"
write_session_with_state "$audit_abnormal_json" "$dead_pid" 2 ""
backdate "$audit_abnormal_json" 45
bash "$helper" sweep --shipyard-home "$tmphome" --current-session-id "live-session" --reaper-session-id "reaper-1252" >/dev/null 2>&1
audit_line=$(cat "$tmphome/reap-audit.jsonl" 2>/dev/null)
out=$(printf '%s' "$audit_line" | jq -r '.reaped_in_flight_count')
assert_equals "$out" "2" "(21) sweep's reap-audit line carries reaped_in_flight_count"
out=$(printf '%s' "$audit_line" | jq -c '.reaped_session_end')
assert_equals "$out" "null" "(21) sweep's reap-audit line carries reaped_session_end = null"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo
echo "== Summary"
echo "  $pass passed, $fail failed"

if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0

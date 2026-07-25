#!/usr/bin/env bash
# Test suite for scripts/sweep-orphan-tmp.sh (issue #858).
#
# Covers the `sweep` subcommand's three categories:
#   - sessions/*.json.tmp.<pid>        (session-state.sh atomic_write)
#   - flake-registry.jsonl.tmp.<pid>   (flake-registry.sh prune rewrite)
#   - cost-history.jsonl.<rand> / .err.<rand> (cost-history.sh reconcile)
#
# The load-bearing property under test is the SAFETY gate, not just the
# reap: a .tmp file that's still within the age floor, or whose writer
# pid is still alive, or that sits behind a fresh cost-history.jsonl.lock,
# must NEVER be removed — only a genuinely stale, genuinely-abandoned
# leftover is fair game.
#
# Pure bash. Run with:
#   bash plugins/shipyard/scripts/tests/sweep-orphan-tmp.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../sweep-orphan-tmp.sh"

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

# Set a file/dir's mtime to <minutes> ago, portable across BSD (macOS,
# local dev) and GNU (ubuntu-latest CI) `touch`/`date` dialects. `-v` is
# BSD-only and fails cleanly (non-zero, no output) on GNU, so trying it
# first and falling back to GNU's `-d` form is safe in both directions —
# unlike the GNU-`-c`-vs-BSD-`-f` `stat` ambiguity cost-history.sh's own
# _dir_mtime_epoch has to guard against, `-v` simply doesn't exist on GNU
# date at all, so there's no silent-wrong-mode risk to order against.
backdate() {
  local path="$1" mins="$2" ts
  ts=$(date -v-"${mins}M" +%Y%m%d%H%M 2>/dev/null) || \
    ts=$(date -d "${mins} minutes ago" +%Y%m%d%H%M 2>/dev/null)
  touch -t "$ts" "$path"
}

mktmphome() { mktemp -d; }

echo "sweep-orphan-tmp.sh tests (issue #858)"
echo

# --- bad usage -------------------------------------------------------------

out=$(bash "$helper" sweep 2>&1); rc=$?
assert_equals "$rc" "64" "(1) missing --shipyard-home exits 64"
assert_contains "$out" "shipyard-home is required" "(1) missing --shipyard-home explains why"

tmphome=$(mktmphome)
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --stale-min notanumber 2>&1); rc=$?
assert_equals "$rc" "64" "(2) non-numeric --stale-min exits 64"
rm -rf "$tmphome"

out=$(bash "$helper" bogus-subcommand 2>&1); rc=$?
assert_equals "$rc" "64" "(3) unknown subcommand exits 64"

out=$(bash "$helper" 2>&1); rc=$?
assert_equals "$rc" "64" "(4) no subcommand exits 64"

out=$(bash "$helper" --help 2>&1); rc=$?
assert_equals "$rc" "0" "(5) --help exits 0"

# --- empty layout ------------------------------------------------------------

tmphome=$(mktmphome)
out=$(bash "$helper" sweep --shipyard-home "$tmphome" 2>&1); rc=$?
assert_equals "$rc" "0" "(6) empty \$SHIPYARD_HOME sweep exits 0"
assert_contains "$out" "summary: reaped=0 skipped=0" "(6) empty layout reaps nothing, skips nothing"
rm -rf "$tmphome"

# --- sessions/*.json.tmp.<pid> ----------------------------------------------

# (7) the acceptance-criteria repro: a crash mid-atomic_write leaves a
# .tmp.<pid> file with NO corresponding .json ever having landed. Backdate
# it past the 30-min floor and use a definitely-dead pid.
tmphome=$(mktmphome)
mkdir -p "$tmphome/sessions"
dead_pid=99999999   # implausibly large — not a live pid on any test host
orphan_tmp="$tmphome/sessions/crash-mid-init.json.tmp.$dead_pid"
: > "$orphan_tmp"
backdate "$orphan_tmp" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" 2>&1); rc=$?
assert_equals "$rc" "0" "(7) sweep with a stale orphaned session tmp exits 0"
assert_file_missing "$orphan_tmp" "(7) stale .tmp.<dead-pid> with no sibling .json is reaped"
assert_contains "$out" "reaped:" "(7) reap is logged, not silent"
assert_contains "$out" "category=sessions" "(7) reap log names its category"
rm -rf "$tmphome"

# (8) NOT swept: an in-progress/recent .tmp — fresh mtime, dead pid. This
# is the safety-floor regression guard the issue's AC calls out
# explicitly ("assert an in-progress/recent .tmp is NOT swept").
tmphome=$(mktmphome)
mkdir -p "$tmphome/sessions"
recent_tmp="$tmphome/sessions/live-session.json.tmp.$dead_pid"
: > "$recent_tmp"
# No backdate — mtime is "now", well inside the 30-min floor.
out=$(bash "$helper" sweep --shipyard-home "$tmphome" 2>&1); rc=$?
assert_equals "$rc" "0" "(8) sweep with a fresh tmp exits 0"
assert_file_exists "$recent_tmp" "(8) fresh (< 30min) .tmp is NOT reaped, regardless of pid liveness"
assert_contains "$out" "summary: reaped=0 skipped=1" "(8) fresh tmp is counted as skipped, not reaped"
rm -rf "$tmphome"

# (9) NOT swept: writer pid is still alive, even though the file is
# stale by mtime — defense in depth on top of the age floor. Use our own
# $$ as a guaranteed-alive pid.
tmphome=$(mktmphome)
mkdir -p "$tmphome/sessions"
alive_tmp="$tmphome/sessions/still-writing.json.tmp.$$"
: > "$alive_tmp"
backdate "$alive_tmp" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" 2>&1); rc=$?
assert_file_exists "$alive_tmp" "(9) stale-by-mtime .tmp with a LIVE writer pid is NOT reaped"
assert_contains "$out" "still alive" "(9) skip reason names the live-pid gate"
rm -rf "$tmphome"

# (10) a fresh, healthy .json sibling alongside a stale, dead-pid orphan
# .tmp — only the .tmp is touched; the real session file is untouched.
tmphome=$(mktmphome)
mkdir -p "$tmphome/sessions"
real_json="$tmphome/sessions/real-session.json"
echo '{"session_id":"real-session"}' > "$real_json"
sibling_orphan="$tmphome/sessions/real-session.json.tmp.$dead_pid"
: > "$sibling_orphan"
backdate "$sibling_orphan" 60
bash "$helper" sweep --shipyard-home "$tmphome" >/dev/null 2>&1
assert_file_missing "$sibling_orphan" "(10) stale orphan .tmp sibling is reaped"
assert_file_exists "$real_json" "(10) the real .json session file is left completely untouched"
rm -rf "$tmphome"

# --- flake-registry.jsonl.tmp.<pid> -----------------------------------------

tmphome=$(mktmphome)
fr_orphan="$tmphome/flake-registry.jsonl.tmp.$dead_pid"
: > "$fr_orphan"
backdate "$fr_orphan" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" 2>&1)
assert_file_missing "$fr_orphan" "(11) stale flake-registry.jsonl.tmp.<dead-pid> is reaped"
assert_contains "$out" "category=flake-registry" "(11) reap log names the flake-registry category"
rm -rf "$tmphome"

tmphome=$(mktmphome)
fr_live="$tmphome/flake-registry.jsonl.tmp.$$"
: > "$fr_live"
backdate "$fr_live" 45
bash "$helper" sweep --shipyard-home "$tmphome" >/dev/null 2>&1
assert_file_exists "$fr_live" "(12) flake-registry tmp with a live writer pid is NOT reaped"
rm -rf "$tmphome"

# --- cost-history.jsonl.<rand> / .err.<rand> --------------------------------

tmphome=$(mktmphome)
ch_orphan="$tmphome/cost-history.jsonl.a1b2c3"
: > "$ch_orphan"
backdate "$ch_orphan" 45
ch_err_orphan="$tmphome/cost-history.jsonl.err.d4e5f6"
: > "$ch_err_orphan"
backdate "$ch_err_orphan" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" 2>&1)
assert_file_missing "$ch_orphan" "(13) stale cost-history.jsonl.<rand> reconcile tmp is reaped"
assert_file_missing "$ch_err_orphan" "(13) stale cost-history.jsonl.err.<rand> tmp is reaped"
assert_contains "$out" "category=cost-history" "(13) reap log names the cost-history category"
rm -rf "$tmphome"

# (14) NOT swept: a fresh (held) cost-history.jsonl.lock means a flush may
# be actively mid-write — skip the WHOLE category even though the
# individual tmp file itself is old enough by mtime alone.
tmphome=$(mktmphome)
ch_racy="$tmphome/cost-history.jsonl.g7h8i9"
: > "$ch_racy"
backdate "$ch_racy" 45
mkdir "$tmphome/cost-history.jsonl.lock"   # fresh — just created, "now"
out=$(bash "$helper" sweep --shipyard-home "$tmphome" 2>&1)
assert_file_exists "$ch_racy" "(14) cost-history tmp is NOT reaped while its flush lock is held and fresh"
assert_contains "$out" "lock" "(14) skip reason mentions the lock"
rm -rf "$tmphome"

# (15) a STALE (crashed-owner) lock does NOT protect the category — same
# staleness posture cost-history.sh's own acquire_flush_lock applies when
# deciding whether to steal a lock.
tmphome=$(mktmphome)
ch_after_crash="$tmphome/cost-history.jsonl.j1k2l3"
: > "$ch_after_crash"
backdate "$ch_after_crash" 45
mkdir "$tmphome/cost-history.jsonl.lock"
backdate "$tmphome/cost-history.jsonl.lock" 5   # 5 min > 30s stale floor
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --stale-min 30 2>&1)
assert_file_missing "$ch_after_crash" "(15) a stale (crashed-owner) lock does not block the sweep"
rm -rf "$tmphome"

# --- --dry-run ---------------------------------------------------------------

tmphome=$(mktmphome)
mkdir -p "$tmphome/sessions"
dry_tmp="$tmphome/sessions/would-reap.json.tmp.$dead_pid"
: > "$dry_tmp"
backdate "$dry_tmp" 45
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --dry-run 2>&1)
assert_file_exists "$dry_tmp" "(16) --dry-run never removes the file"
assert_contains "$out" "reaped (dry-run):" "(16) --dry-run still reports what it would reap"
rm -rf "$tmphome"

# --- --stale-min override ----------------------------------------------------

tmphome=$(mktmphome)
mkdir -p "$tmphome/sessions"
override_tmp="$tmphome/sessions/override.json.tmp.$dead_pid"
: > "$override_tmp"
backdate "$override_tmp" 2   # 2 minutes old
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --stale-min 1 2>&1)
assert_file_missing "$override_tmp" "(17) --stale-min lets the floor be lowered below the 30-min default"
rm -rf "$tmphome"

tmphome=$(mktmphome)
mkdir -p "$tmphome/sessions"
still_young="$tmphome/sessions/still-young.json.tmp.$dead_pid"
: > "$still_young"
backdate "$still_young" 2
out=$(bash "$helper" sweep --shipyard-home "$tmphome" --stale-min 30 2>&1)
assert_file_exists "$still_young" "(18) --stale-min 30 (explicit default) still protects a 2-min-old tmp"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo
echo "== Summary"
echo "  $pass passed, $fail failed"

if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0

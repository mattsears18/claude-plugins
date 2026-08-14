#!/usr/bin/env bash
# Test suite for scripts/operator-denial-registry.sh (issue #1363).
#
# Covers the data-layer subcommands:
#   record — append a denial event (with/without optional fields, dry-run,
#            arg validation, kind/outcome enum enforcement).
#   report — windowed per-(repo,kind,target) aggregation, repeat detection.
#   read   — raw jsonl passthrough, missing-file exit 3.
#   prune  — drop out-of-window events.
#   reset  — move file aside to .bak.
#
# Pure bash + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/operator-denial-registry.test.sh

# shellcheck disable=SC2162
# SC2162 (read without -r) fires on `run read` invocations below — but
# `read` there is the helper's subcommand name passed to the `run` wrapper,
# NOT the bash `read` builtin. shellcheck can't distinguish the two; the
# disable is file-scoped because the pattern recurs across several
# assertions (same rationale as flake-registry.test.sh).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../operator-denial-registry.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400; printf '\n'
    fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_exit() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (exit %s, expected %s)\n' "$RED" "$RESET" "$label" "$actual" "$expected"
    fail=$((fail+1))
  fi
}

# Isolated SHIPYARD_HOME per run.
TMPHOME="$(mktemp -d)"
export SHIPYARD_HOME="$TMPHOME"
trap 'rm -rf "$TMPHOME"' EXIT

run() { bash "$helper" "$@"; }

# A timestamp N days in the past (UTC). Mirrors the helper's cutoff math so
# tests can plant in-window and out-of-window events deterministically.
days_ago() {
  date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

echo "== record =="

# Missing required args -> usage error 64.
run record --kind console-action --target x >/dev/null 2>&1; assert_exit 64 "$?" "record without --outcome exits 64"
run record --target x --outcome handed-back >/dev/null 2>&1; assert_exit 64 "$?" "record without --kind exits 64"

# Invalid enum values -> usage error 64.
run record --kind bogus-kind --target x --outcome handed-back >/dev/null 2>&1
assert_exit 64 "$?" "record with invalid --kind exits 64"
run record --kind console-action --target x --outcome bogus-outcome >/dev/null 2>&1
assert_exit 64 "$?" "record with invalid --outcome exits 64"

# Dry-run emits the line, doesn't write.
line=$(run record --repo o/r --kind console-action --target "console.cloud.google.com/auth/branding" \
  --denial-text "Permission for this action was denied by the Claude Code auto mode classifier." \
  --outcome handed-back --dry-run)
assert_contains "$line" '"kind":"console-action"' "dry-run line carries kind"
assert_contains "$line" '"outcome":"handed-back"' "dry-run line carries outcome"
assert_contains "$line" '"repo":"o/r"' "dry-run line carries repo"
assert_exit 3 "$(run read >/dev/null 2>&1; echo $?)" "registry still missing after dry-run (read exits 3)"

# Optional fields omitted when empty.
line=$(run record --kind console-action --target x --outcome handed-back --dry-run)
repopresent=$(printf '%s' "$line" | jq 'has("repo")')
assert_equals "$repopresent" "false" "repo field omitted when not provided"

# Real append.
run record --repo o/r --kind console-action --target "console.cloud.google.com/x" \
  --denial-text "denied" --outcome handed-back --session sess-1
run read >/dev/null 2>&1; assert_exit 0 "$?" "read exits 0 after first append"
count=$(run read | wc -l | tr -d ' ')
assert_equals "$count" "1" "one line after one append"

echo "== report =="

rm -f "$TMPHOME/operator-denials.jsonl"
# Plant: same (repo,kind,target) denied 3 times across 3 sessions (a
# repeated, standing constraint); a second target denied once.
for s in sess-1 sess-2 sess-3; do
  run record --repo o/r --kind console-action --target "console.cloud.google.com/auth/branding" \
    --denial-text "denied" --outcome handed-back --session "$s" --at "$(days_ago 1)"
done
run record --repo o/r --kind merge-pr --target "#42" --denial-text "denied" \
  --outcome handed-back --session sess-4 --at "$(days_ago 1)"

rep=$(run report --repo o/r --window-days 7)
repeated_events=$(printf '%s' "$rep" | jq '.[] | select(.target=="console.cloud.google.com/auth/branding") | .events')
repeated_sessions=$(printf '%s' "$rep" | jq '.[] | select(.target=="console.cloud.google.com/auth/branding") | .distinct_sessions')
assert_equals "$repeated_events" "3" "repeated denial aggregates to 3 events"
assert_equals "$repeated_sessions" "3" "repeated denial spans 3 distinct sessions"
oneoff_events=$(printf '%s' "$rep" | jq '.[] | select(.target=="#42") | .events')
assert_equals "$oneoff_events" "1" "one-off denial aggregates to 1 event"

# Out-of-window events excluded.
run record --repo o/r --kind console-action --target "console.cloud.google.com/auth/branding" \
  --denial-text "denied" --outcome handed-back --session sess-old --at "$(days_ago 30)"
events_7d=$(run report --repo o/r --window-days 7 | jq '.[] | select(.target=="console.cloud.google.com/auth/branding") | .events')
assert_equals "$events_7d" "3" "30-day-old event excluded from 7-day window"
events_60d=$(run report --repo o/r --window-days 60 | jq '.[] | select(.target=="console.cloud.google.com/auth/branding") | .events')
assert_equals "$events_60d" "4" "30-day-old event included in 60-day window"

# window-days 0 (default) means "report everything" — no cutoff filter.
events_all=$(run report --repo o/r | jq '.[] | select(.target=="console.cloud.google.com/auth/branding") | .events')
assert_equals "$events_all" "4" "default (no --window-days) reports the full history"

# Repo filter isolates.
run record --repo other/repo --kind console-action --target y --denial-text "denied" \
  --outcome handed-back --session sess-z --at "$(days_ago 1)"
rows_or=$(run report --repo o/r --window-days 7 | jq 'length')
assert_equals "$rows_or" "2" "repo filter keeps only o/r rows"

# Kind filter isolates.
rows_kind=$(run report --repo o/r --kind merge-pr --window-days 7 | jq 'length')
assert_equals "$rows_kind" "1" "kind filter keeps only merge-pr rows"

echo "== prune =="

rm -f "$TMPHOME/operator-denials.jsonl"
run record --repo o/r --kind console-action --target KEEP --denial-text d --outcome handed-back --at "$(days_ago 1)"
run record --repo o/r --kind console-action --target DROP --denial-text d --outcome handed-back --at "$(days_ago 200)"
run prune --window-days 180
remaining=$(run read)
assert_contains "$remaining" "KEEP" "prune keeps in-window event"
assert_equals "$(printf '%s' "$remaining" | grep -c DROP)" "0" "prune drops out-of-window event"

echo "== reset =="

run reset --yes
assert_exit 3 "$(run read >/dev/null 2>&1; echo $?)" "read exits 3 after reset"
bak_count=$(find "$TMPHOME" -name 'operator-denials.jsonl.bak.*' | wc -l | tr -d ' ')
assert_equals "$bak_count" "1" "reset moves file to a .bak (recoverable)"

echo
echo "operator-denial-registry.test.sh: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]

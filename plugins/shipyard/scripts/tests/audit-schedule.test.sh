#!/usr/bin/env bash
# Test suite for scripts/audit-schedule.sh — the cadence-gating helper
# backing /shipyard:audit-scheduled (issue #975).
#
# Covers:
#   - state-path / state-init: deterministic path under $SHIPYARD_HOME
#   - state-read: empty-default behaviour for both whole-file and per-repo
#   - record: atomic write + per-(repo,dimension) entry shape, overwrite
#   - cadence-seconds: m/h/d/w unit parsing, invalid-cadence exit 64
#   - due: never-run-before -> due; freshly-recorded -> not due;
#          elapsed-past-cadence -> due again; enabled:false -> always
#          skipped (including the jq `//`-vs-`false` footgun this guards
#          against); absent/null schedule config -> empty output, not an
#          error; stdin (`-`) and file-path input both work; missing
#          --schedule-json file -> exit 5
#
# Pure bash + jq — no network, no `gh`, no real repo.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/audit-schedule.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../audit-schedule.sh"

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
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'; fail=$((fail+1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    unexpectedly contained: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'; fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"; fail=$((fail+1))
  fi
}

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file not found: %s\n' "$path"; fail=$((fail+1))
  fi
}

assert_line_count() {
  local haystack="$1" expected="$2" label="$3"
  local actual
  if [[ -z "$haystack" ]]; then
    actual=0
  else
    actual=$(printf '%s\n' "$haystack" | wc -l | tr -d ' ')
  fi
  assert_equals "$actual" "$expected" "$label"
}

mktmphome() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# --------------------------------------------------------------------------
echo "== state-path"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-path)
assert_equals "$out" "$tmphome/audit-schedule-state.json" "state-path returns \$SHIPYARD_HOME/audit-schedule-state.json"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== state-init"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" state-init
state_file="$tmphome/audit-schedule-state.json"
assert_file_exists "$state_file" "state-init creates the file under \$SHIPYARD_HOME"
content=$(cat "$state_file")
assert_contains "$content" '"version":1' "state-init writes version: 1"
assert_contains "$content" '"repos":{}' "state-init initialises empty repos map"

# Idempotent — second call doesn't clobber existing content.
SHIPYARD_HOME="$tmphome" bash "$helper" record --repo "acme/widgets" --dimension "testing" >/dev/null
before=$(cat "$state_file")
SHIPYARD_HOME="$tmphome" bash "$helper" state-init
after=$(cat "$state_file")
assert_equals "$after" "$before" "state-init is idempotent — does not clobber existing content"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== state-read"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-read)
assert_contains "$out" '"version":1' "state-read before init returns empty default shape"
assert_contains "$out" '"repos":{}' "state-read before init returns empty repos map"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-read --repo "acme/widgets")
assert_equals "$(echo "$out" | jq -c '.')" "{}" "state-read --repo before init returns {}"

SHIPYARD_HOME="$tmphome" bash "$helper" record \
  --repo "acme/widgets" --dimension "testing" --at "2026-05-23T18:00:00Z" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-read --repo "acme/widgets")
assert_contains "$out" '"testing"' "state-read --repo returns the recorded dimension"
assert_contains "$out" '"2026-05-23T18:00:00Z"' "state-read --repo preserves last_run_at"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-read --repo "other/repo")
assert_equals "$(echo "$out" | jq -c '.')" "{}" "state-read --repo for untracked repo returns {}"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== record"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" record \
  --repo "acme/widgets" --dimension "testing" >/dev/null
state_file="$tmphome/audit-schedule-state.json"
assert_file_exists "$state_file" "record auto-initialises the file when missing"
content=$(cat "$state_file")
assert_contains "$content" '"testing"' "record persists the dimension key"
assert_contains "$content" '"acme/widgets"' "record keys by owner/repo"

# A second dimension for the SAME repo is additive, not a clobber.
SHIPYARD_HOME="$tmphome" bash "$helper" record \
  --repo "acme/widgets" --dimension "functional-qa" --at "2026-01-01T00:00:00Z" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-read --repo "acme/widgets")
assert_contains "$out" '"testing"' "record for a second dimension preserves the first"
assert_contains "$out" '"functional-qa"' "record for a second dimension adds the second"

# Re-recording the SAME dimension overwrites its timestamp.
SHIPYARD_HOME="$tmphome" bash "$helper" record \
  --repo "acme/widgets" --dimension "testing" --at "2026-02-02T00:00:00Z" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" state-read --repo "acme/widgets")
assert_contains "$out" '"2026-02-02T00:00:00Z"' "re-recording the same dimension overwrites last_run_at"
assert_not_contains "$(echo "$out" | jq -r '.testing.last_run_at')" "2026-05-23" "old timestamp is gone after overwrite"

# Missing required flags.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record --dimension "testing" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record without --repo exits 64"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" record --repo "acme/widgets" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "record without --dimension exits 64"
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== cadence-seconds"
# --------------------------------------------------------------------------

out=$(bash "$helper" cadence-seconds "30m")
assert_equals "$out" "1800" "cadence-seconds parses minutes (30m -> 1800)"

out=$(bash "$helper" cadence-seconds "24h")
assert_equals "$out" "86400" "cadence-seconds parses hours (24h -> 86400)"

out=$(bash "$helper" cadence-seconds "7d")
assert_equals "$out" "604800" "cadence-seconds parses days (7d -> 604800)"

out=$(bash "$helper" cadence-seconds "2w")
assert_equals "$out" "1209600" "cadence-seconds parses weeks (2w -> 1209600)"

out=$(bash "$helper" cadence-seconds "bogus" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "cadence-seconds rejects an unparseable cadence"
assert_contains "$out" "invalid cadence" "cadence-seconds error names the bad value"

out=$(bash "$helper" cadence-seconds 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "cadence-seconds with no argument exits 64"

# --------------------------------------------------------------------------
echo "== due"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
schedule_file="$tmphome/schedule.json"
cat > "$schedule_file" <<'JSON'
[
  {"dimension": "testing", "cadence": "7d"},
  {"dimension": "functional-qa", "cadence": "7d", "url": "https://example.com"},
  {"dimension": "security", "cadence": "7d", "enabled": false}
]
JSON

# Never run before -> testing and functional-qa are due; security (disabled)
# is never due regardless of last-run state. This is also the regression
# test for the jq `//`-vs-`false` footgun: `.enabled // true` would
# incorrectly re-include a `"enabled": false` entry, since jq's `//`
# treats `false` (not just `null`) as the "use the fallback" case.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" due --repo "acme/widgets" --schedule-json "$schedule_file")
assert_contains "$out" '"dimension":"testing"' "due (never run): testing is due"
assert_contains "$out" '"dimension":"functional-qa"' "due (never run): functional-qa is due"
assert_not_contains "$out" '"dimension":"security"' "due (never run): disabled dimension is never due"
assert_line_count "$out" 2 "due (never run): exactly 2 due entries"

# functional-qa's url is carried through; testing's null url comes back as JSON null.
assert_contains "$out" '"url":"https://example.com"' "due: url is carried through for the entry that has one"

# Record testing as just-run -> testing drops out, functional-qa remains due.
SHIPYARD_HOME="$tmphome" bash "$helper" record --repo "acme/widgets" --dimension "testing" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" due --repo "acme/widgets" --schedule-json "$schedule_file")
assert_not_contains "$out" '"dimension":"testing"' "due (freshly recorded): testing is NOT due"
assert_contains "$out" '"dimension":"functional-qa"' "due (freshly recorded): functional-qa still due (never recorded)"
assert_line_count "$out" 1 "due (freshly recorded): exactly 1 due entry"

# Record testing far enough in the past that its 7d cadence has elapsed ->
# due again.
SHIPYARD_HOME="$tmphome" bash "$helper" record \
  --repo "acme/widgets" --dimension "testing" --at "2020-01-01T00:00:00Z" >/dev/null
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" due --repo "acme/widgets" --schedule-json "$schedule_file")
assert_contains "$out" '"dimension":"testing"' "due (cadence elapsed): testing is due again"
assert_contains "$out" '"last_run_at":"2020-01-01T00:00:00Z"' "due (cadence elapsed): last_run_at is reported"
assert_line_count "$out" 2 "due (cadence elapsed): both entries due again"

# A DIFFERENT repo's due computation is unaffected by acme/widgets' state.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" due --repo "other/repo" --schedule-json "$schedule_file")
assert_line_count "$out" 2 "due: a different, untracked repo sees both entries as due"

# Absent / null schedule config -> empty output, not an error.
out=$(printf 'null' | SHIPYARD_HOME="$tmphome" bash "$helper" due --repo "brand-new/repo" --schedule-json -)
rc=$?
assert_equals "$out" "" "due: null schedule config produces empty output"
assert_equals "$rc" "0" "due: null schedule config exits 0, not an error"

out=$(printf '[]' | SHIPYARD_HOME="$tmphome" bash "$helper" due --repo "brand-new/repo" --schedule-json -)
assert_equals "$out" "" "due: empty-array schedule config produces empty output"

# stdin (-) input works identically to a file path.
via_file=$(SHIPYARD_HOME="$tmphome" bash "$helper" due --repo "yet-another/repo" --schedule-json "$schedule_file")
via_stdin=$(SHIPYARD_HOME="$tmphome" bash "$helper" due --repo "yet-another/repo" --schedule-json - < "$schedule_file")
assert_equals "$via_stdin" "$via_file" "due: stdin (-) input matches file-path input"

# Missing --schedule-json file -> exit 5.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" due --repo "acme/widgets" --schedule-json "$tmphome/does-not-exist.json" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=5" "due: missing --schedule-json file exits 5"

# Missing required flags.
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" due --schedule-json "$schedule_file" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "due without --repo exits 64"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" due --repo "acme/widgets" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "due without --schedule-json exits 64"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== usage / unknown subcommand"
# --------------------------------------------------------------------------

out=$(bash "$helper" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "no-args invocation exits 64"
assert_contains "$out" "Usage:" "no-args invocation prints usage"

out=$(bash "$helper" not-a-real-subcommand 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "unknown subcommand exits 64"

# --------------------------------------------------------------------------
echo "== summary"
# --------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]

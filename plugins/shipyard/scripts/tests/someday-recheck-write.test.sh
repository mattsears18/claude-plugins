#!/usr/bin/env bash
# Test suite for scripts/backlog-filter.sh's `someday-recheck-write`
# subcommand (issue #1422, follow-up to #1406) -- the I/O half of the
# slow-cadence re-scope mechanism. `classify`'s pure `someday_recheck_state`
# decision is covered in backlog-filter.test.sh; this suite covers the write
# side: which `someday_recheck_action` values trigger a `gh issue edit`, the
# idempotent marker-replace-vs-prepend shape, and bad-usage/disabled paths.
#
# Mirrors classify-backlog.test.sh's PATH-prepended `gh` stub pattern, since
# `someday-recheck-write` calls the literal `gh` binary directly (not an
# overridable $GH variable), same as `closed-by-healthy-pr`/`closed-by-open-pr`.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/someday-recheck-write.test.sh

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
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
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
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400; printf '\n'
    fail=$((fail+1))
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TMP_BIN="${WORK}/bin"
mkdir -p "$TMP_BIN"
EDIT_LOG="${WORK}/edits.log"

# Mock gh: `issue view <N> ... --jq .body` returns a body keyed by issue
# number (so different fixtures can carry an existing marker or not); `issue
# edit <N> ... --body <text>` appends a record to EDIT_LOG instead of
# actually mutating anything.
cat > "${TMP_BIN}/gh" <<MOCK
#!/usr/bin/env bash
if [ "\$1 \$2" = "issue view" ]; then
  case "\$3" in
    10) echo "plain body, no marker" ;;
    11) printf '%s\n\n%s' "<!-- do-work-someday-recheck: 2026-07-01 -->" "existing body" ;;
    99) exit 1 ;;
    *) echo "body for #\$3" ;;
  esac
  exit 0
fi
if [ "\$1 \$2" = "issue edit" ]; then
  printf 'EDIT #%s: %s\n' "\$3" "\$*" >> "$EDIT_LOG"
  exit 0
fi
exit 0
MOCK
chmod +x "${TMP_BIN}/gh"

run_write() {
  PATH="${TMP_BIN}:${PATH}" bash "$helper" someday-recheck-write "$@"
}

echo "someday-recheck-write test suite (issue #1422)"
echo "================================================"

# --------------------------------------------------------------------------
echo
echo "bad usage"
# --------------------------------------------------------------------------
out=$(run_write --someday-recheck-days 30 </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(1) missing --repo exits 64"
assert_contains "$out" "--repo is required" "(1) missing --repo explains why"

out=$(run_write --repo o/r </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(2) missing --someday-recheck-days exits 64"

out=$(run_write --repo o/r --someday-recheck-days not-a-number </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(3) non-numeric --someday-recheck-days exits 64"

out=$(run_write --repo o/r --someday-recheck-days 30 --today bogus </dev/null 2>&1); rc=$?
assert_equals "$rc" "64" "(4) invalid --today exits 64"

# --------------------------------------------------------------------------
echo
echo "--someday-recheck-days 0 disables the mechanism entirely"
# --------------------------------------------------------------------------
rm -f "$EDIT_LOG"
printf '%s\n' '{"number":10,"someday_recheck_action":"first-park"}' | run_write --repo o/r --someday-recheck-days 0 >/dev/null 2>&1
if [[ ! -f "$EDIT_LOG" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(5) 0 cadence: no gh issue edit call at all"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(5) 0 cadence: no gh issue edit call at all"
  cat "$EDIT_LOG"; fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo
echo "first-park / cheap-reset trigger a write; not-due / eligible do not"
# --------------------------------------------------------------------------
rm -f "$EDIT_LOG"
printf '%s\n' \
  '{"number":10,"verdict":"drop","reason":"someday-milestone","someday_recheck_action":"first-park"}' \
  '{"number":20,"verdict":"drop","reason":"someday-milestone","someday_recheck_action":"not-due"}' \
  '{"number":30,"verdict":"drop","reason":"someday-milestone","someday_recheck_action":"cheap-reset"}' \
  '{"number":40,"verdict":"eligible"}' \
  | run_write --repo o/r --someday-recheck-days 30 --today 2026-08-16

log_contents="$(cat "$EDIT_LOG" 2>/dev/null)"
assert_contains "$log_contents" "EDIT #10:" "(6) first-park issue #10 gets an edit call"
assert_contains "$log_contents" "EDIT #30:" "(7) cheap-reset issue #30 gets an edit call"
if [[ "$log_contents" != *"EDIT #20:"* ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(8) not-due issue #20 gets NO edit call"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(8) not-due issue #20 gets NO edit call"; fail=$((fail+1))
fi
if [[ "$log_contents" != *"EDIT #40:"* ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(9) eligible (escalated) issue #40 gets NO edit call -- it is not a someday-recheck-action line"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(9) eligible (escalated) issue #40 gets NO edit call"; fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo
echo "the written marker date is today + --someday-recheck-days"
# --------------------------------------------------------------------------
assert_contains "$log_contents" "do-work-someday-recheck: 2026-09-15" "(10) new marker date is 2026-08-16 + 30 days = 2026-09-15"

# --------------------------------------------------------------------------
echo
echo "an existing marker is replaced in place, not stacked (issue #11 fixture carries one)"
# --------------------------------------------------------------------------
rm -f "$EDIT_LOG"
printf '%s\n' '{"number":11,"someday_recheck_action":"cheap-reset"}' | run_write --repo o/r --someday-recheck-days 30 --today 2026-08-16
log_contents="$(cat "$EDIT_LOG" 2>/dev/null)"
# Exactly one marker line in the new body -- not two.
marker_count=$(printf '%s' "$log_contents" | grep -o 'do-work-someday-recheck:' | wc -l | tr -d ' ')
assert_equals "$marker_count" "1" "(11) replacing an existing marker leaves exactly one marker line, never stacks a second"
assert_contains "$log_contents" "existing body" "(12) the rest of the body is preserved verbatim"

# --------------------------------------------------------------------------
echo
echo "a per-issue gh read failure warns and continues, does not abort the whole call"
# --------------------------------------------------------------------------
rm -f "$EDIT_LOG"
out=$(printf '%s\n' \
  '{"number":99,"someday_recheck_action":"first-park"}' \
  '{"number":10,"someday_recheck_action":"first-park"}' \
  | run_write --repo o/r --someday-recheck-days 30 --today 2026-08-16 2>&1)
rc=$?
assert_equals "$rc" "0" "(13) a read failure on #99 does not make the whole call exit non-zero"
assert_contains "$out" "WARNING" "(13) ...and logs a warning"
log_contents="$(cat "$EDIT_LOG" 2>/dev/null)"
assert_contains "$log_contents" "EDIT #10:" "(14) ...but #10 still gets processed"

# --------------------------------------------------------------------------
echo
echo "empty / no-matching input is a silent no-op"
# --------------------------------------------------------------------------
rm -f "$EDIT_LOG"
out=$(printf '' | run_write --repo o/r --someday-recheck-days 30 --today 2026-08-16 2>&1); rc=$?
assert_equals "$rc" "0" "(15) empty stdin exits 0"
if [[ ! -f "$EDIT_LOG" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(15) ...with no edit calls"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(15) ...with no edit calls"; fail=$((fail+1))
fi

rm -f "$EDIT_LOG"
out=$(printf '%s\n' '{"number":100,"verdict":"eligible"}' | run_write --repo o/r --someday-recheck-days 30 --today 2026-08-16 2>&1); rc=$?
assert_equals "$rc" "0" "(16) NDJSON with no someday_recheck_action field exits 0"
if [[ ! -f "$EDIT_LOG" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "(16) ...with no edit calls"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "(16) ...with no edit calls"; fail=$((fail+1))
fi

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

#!/usr/bin/env bash
# Test suite: backlog bucket-ownership coverage (issue #1076).
#
# /shipyard:do-work and /shipyard:my-turn are supposed to jointly partition
# the open-issue backlog with no gap and no overlap. Before #1076 there was
# no artifact that said who owned what: `01b-backlog-overview.md`'s bucket
# table and `04-backlog-divert.md`'s client-side dispatch filter each
# independently described the same routing, nothing cross-checked them, and
# they silently drifted apart — the maintainer's own correction on #1076
# found that `01b`'s wording for bucket 5 disagreed with what `04` actually
# does, and this suite's authoring pass separately found that `04` drops
# `agent-console` issues from dispatch while `01b`'s bucket table never
# mentioned that bucket at all (an issue carrying `agent-console` would have
# rendered as "Workable" in the overview while the dispatcher silently
# skipped it).
#
# `backlog-ownership.md` (plugins/shipyard/commands/do-work/setup/) is the
# fix: a single canonical bucket->owner table that `01b`'s bucket table and
# `04`'s dispatch filter are both checked against, rather than a third
# independently-authored description of the same routing. This suite is
# that check. It asserts:
#
#   1. COVERAGE — every bucket row in the canonical table has a non-empty
#      Owner, and every `nobody`-owned row has a stated reason in Notes.
#      A bucket added without an owner fails the suite (acceptance
#      criterion 4 of #1076).
#
#   2. STRUCTURAL AGREEMENT WITH THE OVERVIEW — the set of bucket numbers in
#      the canonical table equals the set of bucket numbers in `01b`'s own
#      bucket table. A bucket present in one but not the other is exactly
#      the drift class #1076 describes.
#
#   3. STRUCTURAL AGREEMENT WITH THE DISPATCHER — every label token cited in
#      a canonical "carries `<label>`" criteria cell is textually present in
#      `04-backlog-divert.md`. A label renamed or dropped from the
#      dispatcher's filter without updating the canonical table fails here.
#
#   4. NAMED ASSERTIONS for the two cells this issue explicitly assigned an
#      owner to (buckets 1 and 4), so a regression on those two specific
#      rows fails with a readable label rather than only the generic sweep.
#
# This is a STRUCTURAL check, not a full semantic-equivalence check — it
# does not compare prose descriptions of a bucket's disposition word for
# word. Bucket 5's `01b`-vs-`04` wording mismatch was exactly that kind of
# gap — issue #1077 reconciled it by hand (see backlog-ownership.md's own
# notes on that row). Structural drift (a missing bucket, a missing owner,
# an unmentioned label) is exactly the failure mode a mechanical check can
# catch cheaply and reliably; deep semantic reconciliation of routing prose
# stays a judgment call outside this suite's scope.
#
# Run with:
#
#   bash plugins/shipyard/scripts/tests/backlog-ownership-coverage.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup_dir="${here}/../../commands/do-work/setup"
canonical="${setup_dir}/backlog-ownership.md"
overview="${setup_dir}/01b-backlog-overview.md"
dispatcher="${setup_dir}/04-backlog-divert.md"

for required in "$canonical" "$overview" "$dispatcher"; do
  if [[ ! -f "$required" ]]; then
    echo "FAIL: required file not found at $required" >&2
    exit 1
  fi
done

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_true() {
  local condition="$1"
  local label="$2"
  local detail="${3:-}"
  if [[ "$condition" == "true" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    [[ -n "$detail" ]] && printf '    %s\n' "$detail"
    fail=$((fail+1))
  fi
}

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

# Extract raw bucket-numbered table rows from a markdown table — every line
# starting with `| <number-or-decimal> |`. This matches both the canonical
# table's 6-column rows and the overview's 4-column rows since the bucket
# number is always the first cell after the leading pipe.
extract_bucket_rows() {
  grep -E '^\| *[0-9]+(\.[0-9]+)? *\|' "$1"
}

# Trim leading/trailing whitespace from a string.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

echo "== backlog bucket-ownership coverage (#1076)"
echo

# ---------------------------------------------------------------------------
# 1. COVERAGE — every canonical row has a non-empty Owner; every `nobody`
#    row states a reason in Notes.
# ---------------------------------------------------------------------------
echo "-- coverage: every bucket has an owner, every 'nobody' states why"

missing_owner=""
nobody_no_reason=""
canonical_buckets=""

# shellcheck disable=SC2034  # bucket/disposition unused — only num/owner/notes drive this pass
while IFS='|' read -r _lead num bucket criteria disposition owner notes _trail; do
  num="$(trim "$num")"
  owner="$(trim "$owner")"
  notes="$(trim "$notes")"
  [[ -z "$num" ]] && continue

  canonical_buckets="${canonical_buckets}${num}"$'\n'

  if [[ -z "$owner" ]]; then
    missing_owner="${missing_owner}#${num} "
  fi

  if [[ "$owner" == *nobody* && -z "$notes" ]]; then
    nobody_no_reason="${nobody_no_reason}#${num} "
  fi
done < <(extract_bucket_rows "$canonical")

assert_true \
  "$([[ -z "$missing_owner" ]] && echo true || echo false)" \
  "every canonical bucket row has a non-empty Owner" \
  "bucket(s) with empty Owner: ${missing_owner}"

assert_true \
  "$([[ -z "$nobody_no_reason" ]] && echo true || echo false)" \
  "every 'nobody'-owned bucket states a reason in Notes" \
  "bucket(s) owned by 'nobody' with empty Notes: ${nobody_no_reason}"

canonical_bucket_count=$(printf '%s' "$canonical_buckets" | grep -c . || true)
assert_true \
  "$([[ "$canonical_bucket_count" -ge 10 ]] && echo true || echo false)" \
  "canonical table has a plausible bucket count (>=10, got ${canonical_bucket_count})" \
  "sanity check — the table shouldn't have silently lost rows"

echo

# ---------------------------------------------------------------------------
# 2. STRUCTURAL AGREEMENT WITH THE OVERVIEW — same bucket-number set.
# ---------------------------------------------------------------------------
echo "-- structural agreement: canonical table <-> 01b-backlog-overview.md"

overview_buckets=""
while IFS='|' read -r _lead num _rest; do
  num="$(trim "$num")"
  [[ -z "$num" ]] && continue
  overview_buckets="${overview_buckets}${num}"$'\n'
done < <(extract_bucket_rows "$overview")

canonical_sorted="$(printf '%s' "$canonical_buckets" | grep . | sort -V)"
overview_sorted="$(printf '%s' "$overview_buckets" | grep . | sort -V)"

diff_output="$(diff <(printf '%s\n' "$canonical_sorted") <(printf '%s\n' "$overview_sorted") 2>&1 || true)"

assert_true \
  "$([[ -z "$diff_output" ]] && echo true || echo false)" \
  "canonical table and 01b's bucket table cover the identical bucket set" \
  "diff (canonical vs 01b):
${diff_output}"

echo

# ---------------------------------------------------------------------------
# 3. STRUCTURAL AGREEMENT WITH THE DISPATCHER — every 'carries `<label>`'
#    token in the canonical table is textually present in 04's filter.
# ---------------------------------------------------------------------------
echo "-- structural agreement: canonical table's labels <-> 04-backlog-divert.md"

unmatched_labels=""
checked_labels=0

while IFS='|' read -r _lead num _bucket criteria _disposition _owner _notes _trail; do
  num="$(trim "$num")"
  criteria="$(trim "$criteria")"
  [[ -z "$num" ]] && continue
  [[ "$criteria" != carries\ * ]] && continue

  # Extract every backtick-quoted token in this row's criteria cell.
  # shellcheck disable=SC2016  # literal backtick-token pattern — must NOT expand as a command substitution
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    checked_labels=$((checked_labels+1))
    if ! grep -qF -- "$label" "$dispatcher"; then
      unmatched_labels="${unmatched_labels}#${num}:\`${label}\` "
    fi
  done < <(printf '%s' "$criteria" | grep -oE '`[a-zA-Z0-9:_-]+`' | tr -d '`')
done < <(extract_bucket_rows "$canonical")

assert_true \
  "$([[ "$checked_labels" -ge 5 ]] && echo true || echo false)" \
  "extracted a plausible number of label tokens from 'carries' rows (>=5, got ${checked_labels})" \
  "sanity check — the extraction regex shouldn't silently match nothing"

assert_true \
  "$([[ -z "$unmatched_labels" ]] && echo true || echo false)" \
  "every label cited in a canonical 'carries' row appears in 04's dispatch filter" \
  "label(s) not found in 04-backlog-divert.md: ${unmatched_labels}"

echo

# ---------------------------------------------------------------------------
# 4. NAMED ASSERTIONS — buckets 1 and 4, this issue's two assigned cells.
# ---------------------------------------------------------------------------
echo "-- named assertions: buckets 1 and 4 (#1076's assigned cells)"

bucket1_owner=""
bucket4_owner=""
while IFS='|' read -r _lead num _bucket _criteria _disposition owner _notes _trail; do
  num="$(trim "$num")"
  owner="$(trim "$owner")"
  [[ "$num" == "1" ]] && bucket1_owner="$owner"
  [[ "$num" == "4" ]] && bucket4_owner="$owner"
done < <(extract_bucket_rows "$canonical")

assert_true \
  "$([[ "$bucket1_owner" == *"/my-turn"* ]] && echo true || echo false)" \
  "bucket 1 (assigned to others) is owned by /my-turn" \
  "actual Owner cell: ${bucket1_owner}"

assert_true \
  "$([[ "$bucket4_owner" == *"nobody (by design)"* ]] && echo true || echo false)" \
  "bucket 4 (discussion) is explicitly 'nobody (by design)'" \
  "actual Owner cell: ${bucket4_owner}"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]

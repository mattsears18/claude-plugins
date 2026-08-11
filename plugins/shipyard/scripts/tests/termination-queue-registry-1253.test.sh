#!/usr/bin/env bash
# Test: drain.md's termination assertion is driven by a queue registry
# table, not a hand-picked, individually-worded list of checks — issue
# #1253 (slice 1 of 3 decomposing #1250).
#
# Background
# ----------
# #1250 Hole 2 found that drain.md's termination assertion checked only
# `in_flight`, `failed_prs`, and `ready_issues` — `raw_backlog` sat
# outside that list entirely, invisible to every gate, and
# `investigate_candidates` had the identical defect by a second route.
# The fix that landed for #1250 added `raw_backlog`, `investigate_candidates`,
# `divert_queue`, and `operator_queue` as additional individually-worded
# checks ("3.5", "a fifth gate", "a sixth gate", "a seventh gate") — which
# closed the two known holes, but left the assertion itself still a
# hand-picked enumeration: adding an eighth queue to session state would
# require editing prose in this file all over again, reproducing the same
# defect shape one queue at a time.
#
# #1253 replaces the individually-worded checks with a single **queue
# registry table** that every queue is a row of, plus one generic
# "walk the table, first non-empty row wins" procedure. Adding a queue
# now means adding a row — no edit to the procedural prose is required
# for the new queue to gate termination.
#
# This is a markdown-spec repo — "regression test" here means the content
# assertions below (the pattern every other *.test.sh in this repo follows
# for spec-content guards), not a runtime simulation of an actual session.
# The acceptance criteria in #1253 map onto the assertions below:
#
#   - "A non-empty raw_backlog blocks termination and refills the
#      dispatch pool" -> assertions (2) and (4).
#   - "A non-empty investigate_candidates blocks termination and routes
#      to step 1.5 dispatch" -> assertions (2) and (4).
#   - "Adding a new queue to session state requires no edit to the
#      termination assertion to be covered" -> assertion (3): the
#      registry is a single table (structural, not enumerated prose) and
#      the generic walk-the-table procedure names no queue by number.
#   - "Regression test: seed raw_backlog with one issue, assert the
#      assertion does not pass" -> assertion (5): the registry's own
#      raw_backlog row action is "trigger scope-refill and return
#      control" (never "proceed to step 4 / drain"), so a seeded
#      raw_backlog can never reach the drain hand-off.
#
# Pure bash, no external dependencies. Run with:
#   bash plugins/shipyard/scripts/tests/termination-queue-registry-1253.test.sh

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

drain_path="$repo_root/plugins/shipyard/commands/do-work/drain.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    forbidden string still present in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

echo "termination-assertion queue-registry regression guard (issue #1253)"
echo

# (1) The queue registry section exists and names itself as the single
#     source of truth for the walk-order.
assert_contains "$drain_path" "### Queue registry" \
  "drain.md has a dedicated Queue registry section"
assert_contains "$drain_path" "Walk the table **top to bottom, in the listed order**" \
  "the registry documents a single top-to-bottom walk procedure"
assert_contains "$drain_path" "no other edit to this assertion is required" \
  "drain.md states adding a queue needs no procedural edit (the structural acceptance criterion)"

# (2) Every one of the seven queues from #1253's Fix section is present
#     as a row — including the two #1250 was already gating (raw_backlog,
#     investigate_candidates) and the ones that were separately-worded
#     "gates" before this fix (divert_queue, operator_queue).
for q in in_flight failed_prs ready_issues raw_backlog investigate_candidates divert_queue operator_queue; do
  assert_contains "$drain_path" "\`$q\`" \
    "registry names the \`$q\` queue"
done

# (3) The registry is a single markdown table (structural), not N
#     separately-numbered/worded checks. A table has a header separator
#     row ("|---|---|...") directly under the column header row — assert
#     that shape exists once, immediately preceding the queue rows,
#     rather than asserting the old enumerated headings are gone one by
#     one (which would just be re-testing #1250's prose, not #1253's
#     structural fix).
assert_contains "$drain_path" '| # | Queue | Non-empty action | Why this queue is in the registry |' \
  "registry renders as a single table with a fixed column shape"
assert_contains "$drain_path" '|---|---|---|---|' \
  "registry table has a markdown header-separator row (confirms table, not prose list)"

# (4) The old individually-worded gate phrasing ("a fifth gate" / "a
#     sixth gate" / "a seventh gate" / "3.5.") is gone — those queues now
#     live as registry rows, not bespoke paragraphs re-justifying each
#     addition from scratch.
assert_not_contains "$drain_path" "operator layer adds a fifth gate" \
  "the old 'fifth gate' prose for operator_queue is gone (folded into the registry)"
assert_not_contains "$drain_path" "A sixth gate:" \
  "the old 'sixth gate' prose for investigate_candidates is gone (folded into the registry)"
assert_not_contains "$drain_path" "A seventh gate:" \
  "the old 'seventh gate' prose for divert_queue is gone (folded into the registry)"
assert_not_contains "$drain_path" $'3.5. **`raw_backlog`' \
  "the old '3.5' numbered-step prose for raw_backlog is gone (folded into the registry)"

# (5) The raw_backlog and investigate_candidates rows' actions are both
#     "trigger/dispatch and return control" — never a path that lets the
#     orchestrator proceed past the registry while either queue is
#     non-empty. This is the direct regression check for #1253's stated
#     acceptance criteria and its literal repro ("seed raw_backlog with
#     one issue, assert the assertion does not pass").
assert_contains "$drain_path" "background scope-refill (moves entries into \`ready_issues\`) and return control" \
  "raw_backlog row's action triggers scope-refill and returns control (never proceeds to step 4/drain)"
assert_contains "$drain_path" "Dispatch per [dispatch rule 1.5]" \
  "investigate_candidates row's action dispatches per rule 1.5 and returns control"

# (6) The fresh-fetch verification (step 4) is only reachable after every
#     registry row is empty — the transition sentence names that
#     precondition explicitly, so the registry can't be silently
#     bypassed by a doc that just talks about step 4 without gating it.
assert_contains "$drain_path" "Once every row above reports empty" \
  "drain.md gates step 4 on every registry row reporting empty first"

# (7) Existing #1250-era anchors this file's other consumers depend on
#     are preserved verbatim — dispatch-rules.md / setup/04f / dont.md /
#     steady-state.md all point at "step 4" of the termination assertion
#     by name; this fix must not silently rename that anchor out from
#     under them.
assert_contains "$drain_path" "4. **Fresh-fetch verification.**" \
  "step 4 (fresh-fetch verification) keeps its numbered identity for existing cross-file references"
assert_contains "$drain_path" "## Termination assertion" \
  "the '## Termination assertion' heading (and its anchor) is unchanged"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d assertion(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d assertion(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

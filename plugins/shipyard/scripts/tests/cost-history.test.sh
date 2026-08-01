#!/usr/bin/env bash
# Test suite for scripts/cost-history.sh.
#
# Covers the five subcommands the orchestrator and the /shipyard:cost
# command drive:
#
#   flush   — read a session-state.sh session file and append to
#             $SHIPYARD_HOME/cost-history.jsonl plus one record per
#             touched issue to cost-history-issues.jsonl. Idempotent.
#   report  — aggregate the ledgers and project markdown / csv / json.
#   reset   — destructively move ledger files to .bak.<ts>.
#   export  — bundle ledger files into a tarball.
#   read    — emit raw jsonl on stdout (for tests + downstream tools).
#
# Pure bash + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/cost-history.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../cost-history.sh"
session_helper="${here}/../session-state.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi
if [[ ! -f "$session_helper" ]]; then
  echo "FAIL: session-state.sh not found at $session_helper" >&2
  exit 1
fi

# As of issue #855, `flush` shells out to shipyard-config.sh to read
# cost_tracking.enabled before writing the ledger. shipyard-config.sh
# resolves the repo root from cwd unless SHIPYARD_REPO_ROOT is set — pin
# it here, suite-wide, to a config-free temp dir so every test below
# resolves the built-in default (enabled: true) hermetically, regardless
# of what cwd this script happens to be invoked from or what this
# checkout's own committed shipyard.config.json currently says.
_hermetic_repo_root=$(mktemp -d)
export SHIPYARD_REPO_ROOT="$_hermetic_repo_root"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
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

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
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

assert_file_exists() {
  local path="$1"
  local label="$2"
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
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file still present: %s\n' "$path"
    fail=$((fail+1))
  fi
}

# Each test gets a private SHIPYARD_HOME so the suite never touches the
# real ~/.shipyard.
mktmphome() {
  mktemp -d
}

# Helper: seed a session file with realistic per-issue / per-mode tokens.
# Returns the SHIPYARD_HOME path on stdout.
seed_session() {
  local home="$1"
  local session_id="$2"
  local repo="${3:-owner/repo}"

  SHIPYARD_HOME="$home" bash "$session_helper" init \
    --session-id "$session_id" --repo "$repo" >/dev/null
  SHIPYARD_HOME="$home" bash "$session_helper" bump-tokens \
    --session-id "$session_id" \
    --issue 142 --pr 200 \
    --input 10000 --output 2000 --cache-read 5000 \
    --mode issue-work --model claude-opus-4-7 >/dev/null
  SHIPYARD_HOME="$home" bash "$session_helper" bump-tokens \
    --session-id "$session_id" \
    --issue 143 \
    --input 5000 --output 1000 \
    --mode fix-checks-only --model claude-haiku-4-5 >/dev/null
}

# --------------------------------------------------------------------------
echo "== flush — append session + issue records"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "s1"

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "s1" >/dev/null

assert_file_exists "$tmphome/cost-history.jsonl" \
  "flush creates cost-history.jsonl"
assert_file_exists "$tmphome/cost-history-issues.jsonl" \
  "flush creates cost-history-issues.jsonl"

# One session line.
lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "1" "flush writes exactly one session record"

# Two issue lines (issues 142 and 143).
lines=$(wc -l < "$tmphome/cost-history-issues.jsonl" | tr -d ' ')
assert_equals "$lines" "2" "flush writes one issue record per touched issue"

# Session record carries the expected fields.
content=$(cat "$tmphome/cost-history.jsonl")
assert_contains "$content" '"session_id":"s1"' \
  "session record carries session_id"
assert_contains "$content" '"repo":"owner/repo"' \
  "session record carries repo"
assert_contains "$content" '"issues_worked":[142,143]' \
  "session record carries issues_worked (sorted)"
assert_contains "$content" '"prs_created":[200]' \
  "session record carries prs_created"
assert_contains "$content" '"by_model"' \
  "session record carries by_model rollup"
assert_contains "$content" '"by_mode"' \
  "session record carries by_mode rollup"

# Issue record carries the expected fields.
content=$(cat "$tmphome/cost-history-issues.jsonl")
assert_contains "$content" '"issue_number":142' \
  "issue ledger carries issue 142"
assert_contains "$content" '"issue_number":143' \
  "issue ledger carries issue 143"
assert_contains "$content" '"pr":200' \
  "issue ledger carries linked PR for issue 142"
assert_contains "$content" '"modes_used":["issue-work"]' \
  "issue ledger carries modes_used"
assert_contains "$content" '"models_used":["claude-opus-4-7"]' \
  "issue ledger carries models_used"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — idempotent (same session id is not double-appended)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "idem"

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "idem" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "idem" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "idem" >/dev/null

lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "1" "re-flushing the same session id is idempotent"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush --reconcile — merges in an existing session record (#743)"
# --------------------------------------------------------------------------
# Simulates the re-entrant-dispatch safety net: cleanup flushes once, a
# worker dispatches again (bump-tokens --allow-degraded-init reconstructs
# the same session id with fresh cumulative totals), and a second flush
# must land the update rather than being silently skipped by the dedupe
# gate that a plain (non-reconcile) flush would hit. As of #745 the
# reconciled write is a MERGE (element-wise max / union) rather than a
# blind replace — since the fresh projection here is a superset of the
# original (bump-tokens only adds), the merge result is identical to what
# a replace would have produced, so this test's assertions are unchanged.

tmphome=$(mktmphome)
seed_session "$tmphome" "recon"

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "recon" >/dev/null

lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "1" "reconcile setup: first flush writes one session record"

# A plain re-flush (no --reconcile) is still a silent skip — unchanged
# behavior for the routine, non-reconcile caller.
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "recon" >/dev/null
content_before=$(cat "$tmphome/cost-history.jsonl")
assert_contains "$content_before" '"prs_created":[200]' \
  "plain re-flush leaves the original record untouched"

# Re-entrant dispatch: bump more tokens into the SAME session id (mirrors
# --allow-degraded-init reconstructing the file with the same id after
# cleanup already deleted it), then flush --reconcile.
SHIPYARD_HOME="$tmphome" bash "$session_helper" bump-tokens \
  --session-id "recon" \
  --issue 144 --pr 201 \
  --input 3000 --output 500 \
  --mode issue-work --model claude-opus-4-7 >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "recon" --reconcile >/dev/null

lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "1" "reconcile replaces in place — still exactly one session record"

content_after=$(cat "$tmphome/cost-history.jsonl")
assert_contains "$content_after" '"session_id":"recon"' \
  "reconciled record still carries the same session_id"
assert_contains "$content_after" '"issues_worked":[142,143,144]' \
  "reconciled record picks up the re-entrant dispatch's issue"
assert_contains "$content_after" '"prs_created":[200,201]' \
  "reconciled record picks up the re-entrant dispatch's PR"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush --reconcile against a degraded/empty session file must not zero a populated record (#745)"
# --------------------------------------------------------------------------
# Regression test for the data-loss repro in #745: a re-entrant dispatch's
# flush --reconcile is supposed to ADD the missing dispatch's tokens to the
# ledger. If the session file backing the reconcile is degraded (freshly
# re-`init`'d, corrupted, mid-repopulation) instead of carrying forward the
# original cumulative totals, the old unconditional-replace implementation
# overwrote a complete, correct ledger record with zeros. The fix makes
# --reconcile merge instead of replace, so a degraded incoming projection
# can never shrink the existing record.

tmphome=$(mktmphome)
seed_session "$tmphome" "degraded"

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "degraded" >/dev/null

lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "1" "degraded-reconcile setup: first flush writes one populated session record"

before=$(cat "$tmphome/cost-history.jsonl")
assert_contains "$before" '"issues_worked":[142,143]' \
  "degraded-reconcile setup: populated record carries the seeded issues"
assert_contains "$before" '"prs_created":[200]' \
  "degraded-reconcile setup: populated record carries the seeded PR"

# Simulate the #745 corruption: re-`init` the session file (same session
# id) to a fresh, all-empty state — mirrors a freshly re-`init`'d or
# mid-repopulation session file at reconcile time. `--force` is required
# because the file already exists from seed_session.
SHIPYARD_HOME="$tmphome" bash "$session_helper" init \
  --session-id "degraded" --repo "owner/repo" --force --pid 0 >/dev/null

# The (now-empty) session file's projection has zero tokens and empty
# issues_worked / prs_created. A plain --reconcile flush against it must
# NOT zero out the existing populated ledger record.
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "degraded" --reconcile >/dev/null

lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "1" "degraded reconcile — still exactly one session record"

after=$(cat "$tmphome/cost-history.jsonl")
assert_contains "$after" '"issues_worked":[142,143]' \
  "degraded reconcile preserves the existing issues_worked — NOT zeroed"
assert_contains "$after" '"prs_created":[200]' \
  "degraded reconcile preserves the existing prs_created — NOT zeroed"
if [[ "$after" == *'"issues_worked":[]'* ]] || [[ "$after" == *'"prs_created":[]'* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "degraded reconcile must not shrink issues_worked/prs_created to empty"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "degraded reconcile does not shrink issues_worked/prs_created to empty"
  pass=$((pass+1))
fi

# Token totals: the pre-corruption record had non-zero input tokens; the
# merge must preserve that (max(existing, 0) == existing), never write 0.
input_tokens=$(printf '%s' "$after" | jq -r 'select(.session_id=="degraded") | .tokens.input')
if [[ "$input_tokens" -gt 0 ]]; then
  printf '  %sPASS%s  %s (input=%s)\n' "$GREEN" "$RESET" "degraded reconcile preserves non-zero token totals" "$input_tokens"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (input=%s)\n' "$RED" "$RESET" "degraded reconcile preserves non-zero token totals" "$input_tokens"
  fail=$((fail+1))
fi

# Advisory: the degraded-incoming-vs-populated-existing case should be
# surfaced on stderr (loud, not silent) even though the write itself
# succeeds via merge. Re-run the same scenario fresh to capture stderr
# cleanly (the flush above redirected stderr along with stdout).
tmphome2=$(mktmphome)
seed_session "$tmphome2" "degraded-advisory"
SHIPYARD_HOME="$tmphome2" bash "$helper" flush --session-id "degraded-advisory" >/dev/null
SHIPYARD_HOME="$tmphome2" bash "$session_helper" init \
  --session-id "degraded-advisory" --repo "owner/repo" --force --pid 0 >/dev/null
advisory_stderr=$(SHIPYARD_HOME="$tmphome2" bash "$helper" flush --session-id "degraded-advisory" --reconcile 2>&1 >/dev/null)
assert_contains "$advisory_stderr" "merging rather than replacing" \
  "degraded reconcile emits a loud stderr advisory naming the empty-vs-populated conflict"
rm -rf "$tmphome2"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush --reconcile — jq failure during the rewrite must NOT truncate the ledger (#869)"
# --------------------------------------------------------------------------
# Regression test for the silent-truncation bug: the reconcile rewrite's
# `jq -c ... > $tmp 2>/dev/null || true` used to discard both jq's stderr
# and its exit code, so ANY jq failure while filtering out the old
# record(s) — e.g. hitting a partial/malformed trailing line left by a
# concurrent writer's `>>` append still in flight — produced a 0-byte
# $tmp that the unchecked `mv` then rendered permanent, wiping the ENTIRE
# cross-session ledger (every session ever recorded, not just this one).
#
# Simulate that exact race: seed a real, valid record for the session
# under test, then hand-append an incomplete/truncated JSON fragment to
# the ledger — the shape a concurrent `>>` append looks like mid-write,
# before the writer has flushed its closing brace + newline. jq's default
# parser fails on that malformed trailing content (verified empirically:
# exit 5, "Unfinished JSON term at EOF", zero stdout) regardless of the
# valid record earlier in the file.

tmphome=$(mktmphome)
seed_session "$tmphome" "trunc-guard"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "trunc-guard" >/dev/null

ledger="$tmphome/cost-history.jsonl"
before_content=$(cat "$ledger")
assert_contains "$before_content" '"session_id":"trunc-guard"' \
  "truncation-guard setup: first flush writes the trunc-guard session record"

# Hand-append a malformed, unterminated JSON fragment — mimics a
# concurrent writer's `>>` append caught mid-flight.
printf '{"session_id":"concurrent-writer","in_flight": ' >> "$ledger"
before_bytes=$(wc -c < "$ledger" | tr -d ' ')

# Bump more tokens into the same session id so the reconcile branch has a
# fresh projection to merge in (mirrors the "recon" test above), then
# flush --reconcile — this is the call whose rewrite must now refuse to
# clobber the ledger given the malformed trailing content.
SHIPYARD_HOME="$tmphome" bash "$session_helper" bump-tokens \
  --session-id "trunc-guard" \
  --issue 145 --pr 202 \
  --input 1000 --output 200 \
  --mode issue-work --model claude-opus-4-7 >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "trunc-guard" --reconcile 2>&1)
rc=$?

assert_equals "$rc" "68" \
  "flush --reconcile against a corrupted ledger exits non-zero instead of silently succeeding"
assert_contains "$out" "refusing to overwrite" \
  "failed reconcile-rewrite prints a stderr diagnostic identifying the cause"
assert_contains "$out" "trunc-guard" \
  "stderr diagnostic names the session id whose rewrite failed"

# The ledger must be byte-for-byte untouched — NOT replaced with an empty
# file, and NOT missing the malformed-but-preexisting trailing content
# (the rewrite must be all-or-nothing, never a partial clobber).
assert_file_exists "$ledger" "ledger file still exists after a failed reconcile-rewrite"
after_bytes=$(wc -c < "$ledger" | tr -d ' ')
assert_equals "$after_bytes" "$before_bytes" \
  "ledger is byte-for-byte unchanged after a failed reconcile-rewrite (no truncation)"
after_content=$(cat "$ledger")
assert_contains "$after_content" '"session_id":"trunc-guard"' \
  "ledger still carries the original trunc-guard record after a failed reconcile-rewrite"

# No leaked tempfiles from the failed rewrite.
leftover=""
shopt -s nullglob
for f in "$tmphome/"cost-history.jsonl.*; do
  leftover="$leftover $(basename "$f")"
done
shopt -u nullglob
assert_equals "${leftover# }" "" \
  "failed reconcile-rewrite does not leak tempfiles"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush --reconcile --force-replace — genuine destructive replace, backed up (#745)"
# --------------------------------------------------------------------------
# --force-replace is the explicit opt-in for a real destructive replace.
# It must (a) require --reconcile, (b) back up the ledger file first, and
# (c) actually discard the existing record's data (unlike the default
# merge path above).

tmphome=$(mktmphome)

# --force-replace without --reconcile is a usage error.
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "x" --force-replace >/dev/null 2>/dev/null
rc=$?
assert_equals "$rc" "64" "--force-replace without --reconcile is a usage error"

seed_session "$tmphome" "forcerepl"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "forcerepl" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$session_helper" init \
  --session-id "forcerepl" --repo "owner/repo" --force --pid 0 >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "forcerepl" \
  --reconcile --force-replace >/dev/null

lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "1" "force-replace — still exactly one session record"

after_force=$(cat "$tmphome/cost-history.jsonl")
assert_contains "$after_force" '"issues_worked":[]' \
  "force-replace genuinely discards the existing record (empty issues_worked)"

backup_count=$(find "$tmphome" -maxdepth 1 -name 'cost-history.jsonl.bak.*' | wc -l | tr -d ' ')
assert_equals "$backup_count" "1" "force-replace backs up the ledger before replacing"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — missing session file is a no-op (exit 0)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "missing" >/dev/null
rc=$?
assert_equals "$rc" "0" "flush of missing session exits 0 (no-op)"
assert_file_missing "$tmphome/cost-history.jsonl" \
  "flush of missing session does not create the ledger"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush --dry-run prints records but does not append"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "dry"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "dry" --dry-run)

assert_contains "$out" '"session_id":"dry"' \
  "--dry-run emits the session record on stdout"
assert_contains "$out" '"issue_number":142' \
  "--dry-run emits the issue records on stdout"
assert_file_missing "$tmphome/cost-history.jsonl" \
  "--dry-run does not create cost-history.jsonl"
assert_file_missing "$tmphome/cost-history-issues.jsonl" \
  "--dry-run does not create cost-history-issues.jsonl"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — multiple sessions accumulate"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "ma" "owner/repo-a"
seed_session "$tmphome" "mb" "owner/repo-b"

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "ma" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "mb" >/dev/null

lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "2" "two distinct sessions = two ledger lines"

lines=$(wc -l < "$tmphome/cost-history-issues.jsonl" | tr -d ' ')
assert_equals "$lines" "4" "two sessions with 2 issues each = 4 issue lines"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — empty ledger short-circuits gracefully"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report)
assert_contains "$out" "No shipyard sessions recorded" \
  "empty-ledger report prints the empty-state helper line"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --format csv)
assert_contains "$out" "session_id,repo,started_at" \
  "empty-ledger csv emits the header row"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --format json)
assert_contains "$out" '"sessions": []' \
  "empty-ledger json emits an empty sessions array"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — markdown TOTALS"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "rpt1"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rpt1" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all)

assert_contains "$out" "Shipyard cost" \
  "report markdown header present"
assert_contains "$out" "TOTALS" \
  "report markdown TOTALS section present"
assert_contains "$out" "Sessions:        1" \
  "TOTALS shows 1 session"
assert_contains "$out" "Issues worked:   2" \
  "TOTALS shows 2 issues worked"
assert_contains "$out" "PRs created:     1" \
  "TOTALS shows 1 PR created"
assert_contains "$out" "Want more detail" \
  "report footer hint present"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — by-model + by-mode + by-issue + trend"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "rpt2"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rpt2" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report \
  --last all --by-model --by-mode --by-issue --trend --top 5)

assert_contains "$out" "BY MODEL" \
  "--by-model emits BY MODEL section"
assert_contains "$out" "claude-opus-4-7" \
  "BY MODEL shows opus rollup"
assert_contains "$out" "BY MODE" \
  "--by-mode emits BY MODE section"
assert_contains "$out" "issue-work" \
  "BY MODE shows issue-work bucket"
assert_contains "$out" "TOP 5 MOST EXPENSIVE ISSUES" \
  "--top emits TOP N MOST EXPENSIVE ISSUES section"
assert_contains "$out" "#142" \
  "TOP N section lists issue 142"
assert_contains "$out" "TREND (weekly)" \
  "--trend emits TREND section"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — --repo filters"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "rf-a" "owner/repo-a"
seed_session "$tmphome" "rf-b" "owner/repo-b"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rf-a" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rf-b" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all --repo "owner/repo-a" --format json)
sessions=$(printf '%s' "$out" | jq -r '.rollup.sessions')
assert_equals "$sessions" "1" "--repo filter narrows to one session"

repos_in_out=$(printf '%s' "$out" | jq -r '.sessions[].repo' | sort | uniq | tr '\n' ',')
assert_equals "$repos_in_out" "owner/repo-a," "--repo filter excludes other repos"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — --format csv"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "csv1"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "csv1" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all --format csv)

assert_contains "$out" "session_id,repo,started_at,ended_at,duration_seconds,total_tokens,estimated_usd" \
  "csv emits the header row"
assert_contains "$out" '"csv1"' \
  "csv body contains the session id"
assert_contains "$out" '"owner/repo"' \
  "csv body contains the repo"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — --format json"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "j1"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "j1" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all --format json)

# Valid JSON.
echo "$out" | jq empty 2>/dev/null
rc=$?
assert_equals "$rc" "0" "json report is valid JSON"

# Shape checks.
range=$(echo "$out" | jq -r '.range.last')
assert_equals "$range" "all" "json carries range.last"

sessions=$(echo "$out" | jq -r '.rollup.sessions')
assert_equals "$sessions" "1" "json rollup.sessions = 1"

estimated_usd=$(echo "$out" | jq -r '.rollup.estimated_usd > 0')
assert_equals "$estimated_usd" "true" "json rollup.estimated_usd > 0"

issues=$(echo "$out" | jq -r '.issues | length')
assert_equals "$issues" "2" "json issues array has 2 entries"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — --last cutoff filters old sessions"
# --------------------------------------------------------------------------
# Construct a ledger with one old session (1970 timestamp) and one fresh
# session; verify --last 30d drops the old one and --last all keeps both.

tmphome=$(mktmphome)
mkdir -p "$tmphome"
# Hand-write a fake old session line (the flush path always uses `now`
# for ended_at; for this test we need a controllable started_at).
cat > "$tmphome/cost-history.jsonl" <<'EOF'
{"session_id":"old-1970","repo":"owner/old","started_at":"1970-06-01T00:00:00Z","ended_at":"1970-06-01T00:01:00Z","duration_seconds":60,"issues_worked":[1],"prs_created":[],"tokens":{"input":100,"output":50,"cache_read":0,"cache_creation":0},"estimated_usd":0.001,"by_model":{},"by_mode":{}}
EOF
seed_session "$tmphome" "fresh"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "fresh" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last 30d --format json)
n=$(echo "$out" | jq -r '.rollup.sessions')
assert_equals "$n" "1" "--last 30d filters out 1970 sessions"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all --format json)
n=$(echo "$out" | jq -r '.rollup.sessions')
assert_equals "$n" "2" "--last all keeps both sessions"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== read — emit raw jsonl"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "rd"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rd" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read)
assert_contains "$out" '"session_id":"rd"' "read --ledger sessions (default) emits jsonl"

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read --ledger issues)
assert_contains "$out" '"issue_number":142' "read --ledger issues emits issues jsonl"

# Missing ledger → exit 3.
rm "$tmphome/cost-history.jsonl"
out=$(SHIPYARD_HOME="$tmphome" bash "$helper" read 2>/dev/null; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=3" "read of missing ledger exits 3"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== reset — moves files to .bak.<ts>"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "rst"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "rst" >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" reset --yes 2>/dev/null

assert_file_missing "$tmphome/cost-history.jsonl" \
  "reset removes cost-history.jsonl"
assert_file_missing "$tmphome/cost-history-issues.jsonl" \
  "reset removes cost-history-issues.jsonl"

# .bak.<ts> files exist.
bak_count=0
shopt -s nullglob
# shellcheck disable=SC2034
# rationale: `f` is the loop variable; only the count of iterations
# matters here, not the value. The `# shellcheck` comment is the
# documented suppression for SC2034 in this idiom.
for f in "$tmphome/"cost-history*.bak.*; do
  bak_count=$((bak_count + 1))
done
shopt -u nullglob
assert_equals "$bak_count" "2" "reset moves both files to .bak.<ts>"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== reset — without --yes prompts (decline = exit 70)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "noyes"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "noyes" >/dev/null

# Pipe "n" to reject the prompt.
out=$(printf 'n\n' | SHIPYARD_HOME="$tmphome" bash "$helper" reset 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=70" "reset declined at prompt exits 70"
assert_file_exists "$tmphome/cost-history.jsonl" \
  "reset declined leaves cost-history.jsonl in place"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== export — tarball both ledger files"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "ex"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "ex" >/dev/null

target="$tmphome/backup.tar.gz"
SHIPYARD_HOME="$tmphome" bash "$helper" export --to "$target" 2>/dev/null

assert_file_exists "$target" "export writes the tarball"

# Inspect the tarball — both ledger files inside.
contents=$(tar -tzf "$target" | sort | tr '\n' ',')
assert_equals "$contents" "cost-history-issues.jsonl,cost-history.jsonl," \
  "tarball contains both ledger files"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — auto-flushes pending setup-timing sidecar (issue #283)"
# --------------------------------------------------------------------------
# Regression test for the bug described in #283: the orchestrator records
# per-phase timing data into a sidecar (`<session>.timing.json`) but the
# explicit `setup-timing.sh flush` at step 6.8 is structurally easy to
# skip (long-step embedding, fire-and-forget posture, C=1 skip-list
# misread). When skipped, the session-state file's `.setup` block stays
# null and the cross-session ledger record we write here loses the data.
# The fix: `cost-history.sh flush` opportunistically calls
# `setup-timing.sh flush` BEFORE reading `.setup`, so a pending sidecar
# is always materialized before the ledger record snapshots it.

tmphome=$(mktemp -d)
sid="autoflush-${BASHPID:-$$}"

# 1. Init session, record phase timing into the sidecar, but DELIBERATELY
#    do NOT call `setup-timing.sh flush` — this is the bug scenario.
SHIPYARD_HOME="$tmphome" bash "$session_helper" init \
  --session-id "$sid" --repo "test/repo" >/dev/null

setup_timing_helper="${here}/../setup-timing.sh"
SHIPYARD_HOME="$tmphome" bash "$setup_timing_helper" start \
  --session-id "$sid" --phase step_0_5_worktree 2>/dev/null
sleep 1
SHIPYARD_HOME="$tmphome" bash "$setup_timing_helper" end \
  --session-id "$sid" --phase step_0_5_worktree 2>/dev/null

# Pre-flush sanity: the sidecar exists, but .setup is still null.
sidecar="${tmphome}/sessions/${sid}.timing.json"
assert_file_exists "$sidecar" "autoflush: sidecar present before cost-history flush"

pre_setup=$(SHIPYARD_HOME="$tmphome" bash "$session_helper" read \
  --session-id "$sid" --path '.setup')
assert_equals "$pre_setup" "null" \
  "autoflush: .setup is null in session state before cost-history flush"

# 2. Run cost-history flush. Auto-flush hook should materialize .setup.
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "$sid"
assert_equals "$?" "0" "autoflush: cost-history flush exits 0"

# 3. The ledger record must carry the per-phase setup data — NOT null.
ledger="${tmphome}/cost-history.jsonl"
assert_file_exists "$ledger" "autoflush: ledger file written"

setup_in_record=$(jq -c '.setup' "$ledger")
if [[ "$setup_in_record" != "null" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
    "autoflush: ledger record .setup is NOT null after cost-history flush"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
    "autoflush: ledger record .setup is NOT null after cost-history flush"
  printf '    actual: %s\n' "$setup_in_record"
  fail=$((fail+1))
fi

# Must carry the phase we recorded.
phase_seconds=$(jq -r '.setup.phases.step_0_5_worktree' "$ledger")
if [[ "$phase_seconds" =~ ^[0-9]+$ ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
    "autoflush: ledger record carries step_0_5_worktree phase duration"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
    "autoflush: ledger record carries step_0_5_worktree phase duration"
  printf '    actual: %s\n' "$phase_seconds"
  fail=$((fail+1))
fi

# 4. Sidecar should be cleaned up by the auto-flush.
if [[ ! -e "$sidecar" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
    "autoflush: sidecar cleaned up after cost-history flush"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
    "autoflush: sidecar cleaned up after cost-history flush"
  fail=$((fail+1))
fi

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — no sidecar present is still a clean no-op"
# --------------------------------------------------------------------------
# Make sure the auto-flush hook doesn't error when there's nothing to
# flush. Normal sessions where the explicit flush DID run reach
# cost-history flush with no sidecar present — the auto-flush call must
# be a clean no-op in that case.

tmphome=$(mktemp -d)
sid="autoflush-nosidecar-${BASHPID:-$$}"

SHIPYARD_HOME="$tmphome" bash "$session_helper" init \
  --session-id "$sid" --repo "test/repo" >/dev/null

# Run cost-history flush with no sidecar — should succeed cleanly.
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "$sid"
assert_equals "$?" "0" \
  "autoflush: cost-history flush exits 0 when no sidecar present"

# Ledger record should still be written (with .setup as null since
# nothing was ever recorded).
ledger="${tmphome}/cost-history.jsonl"
assert_file_exists "$ledger" \
  "autoflush: ledger record written even with no sidecar"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== usage — unknown subcommand / missing args"
# --------------------------------------------------------------------------

out=$(bash "$helper" 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "no subcommand exits 64"

out=$(bash "$helper" frobnicate 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "unknown subcommand exits 64"

out=$(bash "$helper" flush 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "flush without --session-id exits 64"

out=$(bash "$helper" export 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "export without --to exits 64"

out=$(bash "$helper" report --format yaml 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "report with unsupported format exits 64"

out=$(bash "$helper" report --last 5x 2>&1; echo "rc=$?")
rc=$(printf '%s' "$out" | tail -1)
assert_equals "$rc" "rc=64" "report --last with bad value exits 64"

# --------------------------------------------------------------------------
echo
echo "== flush — 0-byte session file guard (issue #357)"
# --------------------------------------------------------------------------
# Defense-in-depth: legacy 0-byte session files (from prior shipyard
# versions where atomic_write could silently truncate on jq failure, or
# from external truncation) MUST NOT produce a zero-cost stub line in
# the session ledger. flush should detect, log a clear message, and
# exit 0 without writing — the cleanup chain stays unbroken, the
# operator can see the data loss, and `/shipyard:cost report` doesn't
# mistake the truncation for a real $0 session.

tmphome=$(mktemp -d)
export SHIPYARD_HOME="$tmphome"

# Create an init'd session, then truncate it to 0 bytes (simulating the
# prior bug).
bash "$session_helper" init --session-id "zero-flush" --repo "owner/repo" >/dev/null
sf="$tmphome/sessions/zero-flush.json"
: > "$sf"
zsize=$(wc -c < "$sf" | tr -d ' ')
assert_equals "$zsize" "0" "test setup: session file is 0 bytes"

out=$(bash "$helper" flush --session-id "zero-flush" 2>&1; echo "rc=$?")
rc=$(printf '%s\n' "$out" | tail -1)
assert_equals "$rc" "rc=0" "flush against 0-byte session file exits 0 (cleanup chain unbroken)"
assert_contains "$out" "session file 0-byte at flush" "flush against 0-byte file surfaces clear log message"
assert_contains "$out" "cost data unrecoverable" "flush against 0-byte file flags data as unrecoverable"
assert_contains "$out" "zero-flush" "flush against 0-byte file names the session id in the log"

# Ledger MUST NOT have been written.
session_ledger="$tmphome/cost-history.jsonl"
issue_ledger="$tmphome/cost-history-issues.jsonl"
assert_file_missing "$session_ledger" "no session ledger line written for 0-byte source"
assert_file_missing "$issue_ledger" "no issue ledger line written for 0-byte source"

unset SHIPYARD_HOME
rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — cost_tracking.enabled: false suppresses the ledger write (#855)"
# --------------------------------------------------------------------------
# Prior to #855, cost_tracking.enabled validated and landed at the right
# effective-config path but nothing ever read it — a user who set it to
# false still got a fresh cost-history.jsonl / cost-history-issues.jsonl
# line on every session. This asserts the opt-out is now actually honored
# by the one script that writes those two files.

tmphome=$(mktmphome)
disabled_repo=$(mktemp -d)
echo '{"version":1,"cost_tracking":{"enabled":false}}' > "$disabled_repo/shipyard.config.json"
seed_session "$tmphome" "cost-off"

out=$(SHIPYARD_REPO_ROOT="$disabled_repo" SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "cost-off" 2>&1; echo "rc=$?")
rc=$(printf '%s\n' "$out" | tail -1)
assert_equals "$rc" "rc=0" "flush with cost_tracking.enabled=false still exits 0 (cleanup chain unbroken)"
assert_contains "$out" "cost_tracking.enabled=false" "flush with cost_tracking.enabled=false surfaces a clear log message"
assert_contains "$out" "cost-off" "flush with cost_tracking.enabled=false names the session id in the log"

assert_file_missing "$tmphome/cost-history.jsonl" \
  "cost_tracking.enabled=false: no session ledger line written"
assert_file_missing "$tmphome/cost-history-issues.jsonl" \
  "cost_tracking.enabled=false: no issue ledger line written"

rm -rf "$tmphome" "$disabled_repo"

# --------------------------------------------------------------------------
echo "== flush — cost_tracking.enabled: true (explicit) still flushes normally (#855)"
# --------------------------------------------------------------------------
# Regression guard for the gate added above: an explicit `true` (not just
# the unset/default case every earlier test in this suite already covers
# via the suite-wide SHIPYARD_REPO_ROOT pin) must not accidentally trip
# the skip branch.

tmphome=$(mktmphome)
enabled_repo=$(mktemp -d)
echo '{"version":1,"cost_tracking":{"enabled":true}}' > "$enabled_repo/shipyard.config.json"
seed_session "$tmphome" "cost-on"

SHIPYARD_REPO_ROOT="$enabled_repo" SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "cost-on" >/dev/null

assert_file_exists "$tmphome/cost-history.jsonl" \
  "cost_tracking.enabled=true (explicit): session ledger line written"
assert_file_exists "$tmphome/cost-history-issues.jsonl" \
  "cost_tracking.enabled=true (explicit): issue ledger line written"

rm -rf "$tmphome" "$enabled_repo"

# --------------------------------------------------------------------------
echo "== flush — concurrent flush of the SAME session id never double-appends (#861)"
# --------------------------------------------------------------------------
# Regression test for the TOCTOU race: cmd_flush's dedupe check ("does the
# ledger already have a record for this session_id?") and its append used
# to be two separate, unlocked steps. Two independent /do-work
# orchestrators racing to flush the same dead orphan session (the
# `do-work/setup/01-repo-recovery.md` orphan-sweep scenario from the issue
# body) could both observe "no existing record" before either appended,
# landing two session records for the same session_id and silently
# double-counting that session's tokens in every subsequent
# `/shipyard:cost report`.
#
# Fire a stack of concurrent `flush --session-id` calls against the SAME
# session id and SAME ledger, all backgrounded together so their process
# startup genuinely overlaps, then wait for all of them. With the
# cross-process lock in place, exactly one of them must win the
# dedupe-check-then-append race and every other one must observe the
# freshly-written record and skip — regardless of scheduling order. Before
# the fix this reliably produced more than one line for N=8 concurrent
# racers on every run of this suite.

tmphome=$(mktmphome)
seed_session "$tmphome" "concurrent-race"

n_racers=8
pids=()
for _ in $(seq 1 "$n_racers"); do
  SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "concurrent-race" >/dev/null 2>>"$tmphome/racer-stderr.log" &
  pids+=("$!")
done
race_failures=0
for pid in "${pids[@]}"; do
  wait "$pid"
  pid_rc=$?
  if [[ $pid_rc -ne 0 ]]; then
    race_failures=$((race_failures + 1))
    echo "  racer pid $pid exited $pid_rc" >&2
  fi
done

if [[ $race_failures -ne 0 ]]; then
  echo "  -- racer stderr (diagnostic; see below) --" >&2
  cat "$tmphome/racer-stderr.log" >&2
fi

assert_equals "$race_failures" "0" \
  "all $n_racers concurrent flush invocations exit 0 (none time out waiting for the lock)"

session_lines=$(grep -c '"session_id":"concurrent-race"' "$tmphome/cost-history.jsonl" 2>/dev/null || echo 0)
assert_equals "$session_lines" "1" \
  "concurrent flush of the same session id never double-appends the session record"

issue_lines_142=$(grep -c '"issue_number":142' "$tmphome/cost-history-issues.jsonl" 2>/dev/null || echo 0)
assert_equals "$issue_lines_142" "1" \
  "concurrent flush of the same session id never double-appends per-issue records either"

# No leaked lock directory after every racer has exited. A plain `-d`
# check (not a glob loop) — "cost-history.jsonl.lock" has no wildcard
# characters, so a glob loop over it iterates once with the literal
# string regardless of whether the path exists; nullglob only suppresses
# a non-matching *pattern* (one containing actual glob metacharacters)
# and has no effect on a plain literal.
if [[ -d "$tmphome/cost-history.jsonl.lock" ]]; then
  leftover_lock="cost-history.jsonl.lock"
else
  leftover_lock=""
fi
assert_equals "$leftover_lock" "" \
  "no leaked lock directory after all concurrent racers exit"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — propagates degraded_attribution_count into the session record (#1035)"
# --------------------------------------------------------------------------
# A session that used bump-tokens --degraded-total-only marks the affected
# invocation(s) `degraded: true` and increments the session-level
# .tokens.degraded_attribution_count counter. Before #1035 that counter
# never made it past the session-state file — cost-history.sh flush
# projected a session record with no field for it at all, so
# /shipyard:cost report (which only ever reads the persistent ledger, never
# the transient per-session file) had no way to know the ledger's
# estimated_usd for that session was unreliable.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$session_helper" init \
  --session-id "deg1" --repo "owner/repo" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$session_helper" bump-tokens \
  --session-id "deg1" --issue 5 \
  --input 40000 --mode issue-work --model claude-sonnet-5 \
  --degraded-total-only >/dev/null
SHIPYARD_HOME="$tmphome" bash "$session_helper" bump-tokens \
  --session-id "deg1" --issue 5 \
  --input 10000 --output 2000 --cache-read 1000 \
  --mode issue-work --model claude-sonnet-5 >/dev/null

SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "deg1" >/dev/null

content=$(cat "$tmphome/cost-history.jsonl")
assert_contains "$content" '"degraded_attribution_count":1' \
  "session record carries degraded_attribution_count from the one degraded bump"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush — a session with no degraded bumps carries degraded_attribution_count:0 (#1035)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
seed_session "$tmphome" "clean1"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "clean1" >/dev/null

content=$(cat "$tmphome/cost-history.jsonl")
assert_contains "$content" '"degraded_attribution_count":0' \
  "session record with no degraded bumps carries degraded_attribution_count:0, not a missing field"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== flush --reconcile — merges degraded_attribution_count by max, not sum (#1035)"
# --------------------------------------------------------------------------
# Same merge-safety contract as every other tokens.* counter (#745): a
# --reconcile re-flush against a session whose file already reflects both
# bumps must not double-count by summing the existing ledger row's count
# against the fresh projection's count.

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$session_helper" init \
  --session-id "deg2" --repo "owner/repo" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$session_helper" bump-tokens \
  --session-id "deg2" --issue 5 \
  --input 40000 --mode issue-work --model claude-sonnet-5 \
  --degraded-total-only >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "deg2" >/dev/null

# A second degraded bump lands in the SAME session file (simulating a
# re-entrant dispatch after a mid-session flush), then --reconcile merges.
SHIPYARD_HOME="$tmphome" bash "$session_helper" bump-tokens \
  --session-id "deg2" --issue 5 \
  --input 5000 --mode issue-work --model claude-sonnet-5 \
  --degraded-total-only >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "deg2" --reconcile >/dev/null

lines=$(wc -l < "$tmphome/cost-history.jsonl" | tr -d ' ')
assert_equals "$lines" "1" "reconcile still writes exactly one session record"

content=$(cat "$tmphome/cost-history.jsonl")
assert_contains "$content" '"degraded_attribution_count":2' \
  "reconcile merge carries forward both degraded bumps (fresh projection is a superset, so max == 2, not sum == 3+)"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — degraded session tags Spend [UNRELIABLE] and prints the advisory (#1035)"
# --------------------------------------------------------------------------

tmphome=$(mktmphome)
SHIPYARD_HOME="$tmphome" bash "$session_helper" init \
  --session-id "deg-rpt" --repo "owner/repo" >/dev/null
SHIPYARD_HOME="$tmphome" bash "$session_helper" bump-tokens \
  --session-id "deg-rpt" --issue 5 \
  --input 40000 --mode issue-work --model claude-sonnet-5 \
  --degraded-total-only >/dev/null
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "deg-rpt" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all)
assert_contains "$out" "[UNRELIABLE]" \
  "report markdown tags the Spend line [UNRELIABLE] when a degraded session is in range"
assert_contains "$out" "DEGRADED COST ATTRIBUTION" \
  "report markdown prints the DEGRADED COST ATTRIBUTION advisory block"
assert_contains "$out" "1 session(s), 1 dispatch(es)" \
  "advisory names the degraded session/dispatch counts"

out_json=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all --format json)
degraded_count=$(printf '%s' "$out_json" | jq -r '.rollup.degraded_attribution_count')
degraded_sessions=$(printf '%s' "$out_json" | jq -r '.rollup.degraded_sessions')
assert_equals "$degraded_count" "1" "report json rollup carries degraded_attribution_count"
assert_equals "$degraded_sessions" "1" "report json rollup carries degraded_sessions"

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo "== report — a clean (non-degraded) window prints no UNRELIABLE tag or advisory (#1035)"
# --------------------------------------------------------------------------
# Silence-is-the-default check, same posture as the unpriced-models banner:
# a session that never used --degraded-total-only must not trigger either
# the [UNRELIABLE] tag or the advisory block.

tmphome=$(mktmphome)
seed_session "$tmphome" "clean-rpt"
SHIPYARD_HOME="$tmphome" bash "$helper" flush --session-id "clean-rpt" >/dev/null

out=$(SHIPYARD_HOME="$tmphome" bash "$helper" report --last all)
if [[ "$out" == *"[UNRELIABLE]"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "clean session does NOT tag Spend [UNRELIABLE]"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "clean session does NOT tag Spend [UNRELIABLE]"
  pass=$((pass+1))
fi
if [[ "$out" == *"DEGRADED COST ATTRIBUTION"* ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "clean session does NOT print the DEGRADED COST ATTRIBUTION advisory"
  fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "clean session does NOT print the DEGRADED COST ATTRIBUTION advisory"
  pass=$((pass+1))
fi

rm -rf "$tmphome"

# --------------------------------------------------------------------------
echo
echo "== Summary"
echo "  $pass passed, $fail failed"

if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0

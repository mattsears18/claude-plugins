#!/usr/bin/env bash
# Test: the completion-ledger fix for the "backlog empty with a dozen open
# issues" failure mode landed at both exit points — issue #1250.
#
# Background
# ----------
# `/do-work` could finish a session, report "nothing left to do," and the
# maintainer would then find a dozen or more open issues — the loop's worst
# failure mode, because it looks exactly like success. Three independent
# structural holes produced it:
#
#   Hole 1 — setup/04-backlog-divert.md's early exit asserted "backlog
#            empty" from the post-filter raw_backlog count alone, with no
#            comparison against the pre-filter fetch.
#   Hole 2 — drain.md's four-step termination assertion checked in_flight,
#            failed_prs, and ready_issues, but never raw_backlog — an issue
#            fetched and ranked but never promoted to ready_issues was
#            simultaneously "already known" (subtracted in step 4's
#            net-new diff) and "not ready" (invisible to step 3), and
#            therefore invisible to every gate. investigate_candidates had
#            the identical defect by a second route.
#   Hole 3 — termination reasoned purely over internal queues, never over
#            the world, so "queues empty" and "the filter erased the work"
#            were indistinguishable in the output.
#
# The fix replaces the bare "backlog empty" claim with a completion ledger
# (setup/04f-completion-ledger.md) that every open issue must land in
# exactly one bucket of before either exit point may claim completion — an
# issue matching no bucket is a filter defect, reported loudly, that blocks
# termination rather than being silently absorbed. drain.md's termination
# assertion also gained explicit raw_backlog / investigate_candidates /
# divert_queue gates so no queue is invisible to every check the way
# raw_backlog was before this fix.
#
# This is a markdown-spec repo — "regression test" here means the content
# assertions below (the pattern every other *.test.sh in this repo follows
# for spec-content guards), not a runtime simulation of an actual session.
#
# Pure bash, no external dependencies. Run with:
#   bash plugins/shipyard/scripts/tests/completion-ledger-1250.test.sh

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

ledger_path="$repo_root/plugins/shipyard/commands/do-work/setup/04f-completion-ledger.md"
backlog_divert_path="$repo_root/plugins/shipyard/commands/do-work/setup/04-backlog-divert.md"
drain_path="$repo_root/plugins/shipyard/commands/do-work/drain.md"
cleanup_path="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
dont_path="$repo_root/plugins/shipyard/commands/do-work/dont.md"
setup_router_path="$repo_root/plugins/shipyard/commands/do-work/setup.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
  fi
}

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

echo "completion-ledger regression guard (issue #1250)"
echo

# (1) The ledger file itself exists and is registered in setup.md's router.
assert_file_exists "$ledger_path" "setup/04f-completion-ledger.md exists"
assert_contains "$setup_router_path" "setup/04f-completion-ledger.md" \
  "setup.md router table lists 04f-completion-ledger.md"

# (2) The ledger defines the load-bearing "unaccounted blocks termination"
#     rule and the eleven-bucket taxonomy, including both corrections
#     called out in the issue (agent-console is dispatchable, not
#     human-gated; time-gated is its own bucket).
assert_contains "$ledger_path" "always a defect" \
  "ledger states unaccounted is always a defect"
assert_contains "$ledger_path" "do NOT terminate" \
  "ledger states unaccounted blocks termination"
assert_contains "$ledger_path" "Unaccounted" \
  "ledger names the Unaccounted bucket"
assert_contains "$ledger_path" "agent-console" \
  "ledger addresses the agent-console bucket correction"
assert_contains "$ledger_path" "Time-gated" \
  "ledger names the Time-gated bucket"

# (3) Hole 1 — the setup early exit no longer asserts "backlog empty" from
#     raw_backlog emptiness alone; it routes through the ledger first.
assert_contains "$backlog_divert_path" "04f-completion-ledger.md" \
  "setup/04-backlog-divert.md's early exit references the completion ledger"
assert_not_contains "$backlog_divert_path" \
  'loop ends immediately; report "backlog empty" and stop' \
  "setup/04-backlog-divert.md no longer asserts bare 'backlog empty' from raw_backlog alone"

# (4) Hole 2 — drain.md's termination assertion explicitly gates on
#     raw_backlog (previously invisible to every check) and on
#     investigate_candidates / divert_queue (the "hand-picked subset"
#     defect the issue's addendum calls out).
assert_contains "$drain_path" "raw_backlog\` is empty" \
  "drain.md termination assertion explicitly checks raw_backlog"
assert_contains "$drain_path" "investigate_candidates\` must be empty" \
  "drain.md termination assertion explicitly checks investigate_candidates"
assert_contains "$drain_path" "divert_queue\` must be empty" \
  "drain.md termination assertion explicitly checks divert_queue"
assert_contains "$drain_path" "04f-completion-ledger.md" \
  "drain.md termination assertion references the completion ledger"

# (5) Hole 3 — drain.md's fresh-fetch verification gates proceeding to
#     drain on the ledger reporting zero unaccounted issues, and the
#     terminal message is honest (never a bare queue-emptiness claim).
assert_contains "$drain_path" "that is a filter defect" \
  "drain.md refuses to proceed to drain on an unaccounted issue"
assert_contains "$drain_path" "dispatchable of <total> open" \
  "drain.md documents the honest terminal-message shape"

# (6) The end-of-session summary (the actual end-of-drain report a human
#     reads) surfaces the Unaccounted bucket and gates the "clean board"
#     zero-row rendering on it being zero too.
assert_contains "$cleanup_path" "Unaccounted" \
  "cleanup-summary.md's end-of-session summary carries an Unaccounted row"
assert_contains "$cleanup_path" "04f-completion-ledger.md" \
  "cleanup-summary.md references the completion ledger"
assert_contains "$cleanup_path" "gates the \"zero-row / clean board\" rendering off" \
  "cleanup-summary.md gates the clean-board rendering on Unaccounted == 0"

# (7) dont.md carries the corresponding prohibition so the rule is
#     reachable from the orchestrator's rule-list sidebar too.
assert_contains "$dont_path" "backlog empty" \
  "dont.md's new bullet names the backlog-empty prohibition"
assert_contains "$dont_path" "1250" \
  "dont.md's new bullet cites issue #1250"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d assertion(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d assertion(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

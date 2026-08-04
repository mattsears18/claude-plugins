#!/usr/bin/env bash
# Test: DIRTY-AND-red PRs are routed to fix-rebase, not fix-checks, during drain.
#
# Background — issue #1060, superseding #577: the end-of-session drain used
# to route a DIRTY-and-red PR (D_dirty_red) to fix-checks, on the theory that
# fix-checks would rebase the branch as part of getting it green. Issue #1015
# added a DIRTY-PR short-circuit to fix-checks-only that made it bail
# immediately (`dirty #<M>`) instead of ever attempting a fix — which quietly
# invalidated #577's premise. Meanwhile fix-rebase.md's own precondition bail
# ("PR has failing checks — needs fix-checks, not rebase") fired on ANY hard
# failure, DIRTY or not. The result: a PR that was both DIRTY and red got
# bounced between fix-checks (bails `dirty`, routes to fix-rebase) and
# fix-rebase (bails on the failing check, routes to fix-checks) forever, with
# no worker ever able to act on it — and it counted as "settled" the whole
# time via rebase_blocked_prs membership, so a session could report it done
# when it was actually wedged.
#
# The fix (#1060) inverts both ends of the #577 rule in the same change:
#   - fix-rebase.md step 2's hard-failure bail is now gated on
#     mergeStateStatus != "DIRTY" — a DIRTY PR skips the bail and rebases
#     regardless of check state, because a red check on a DIRTY PR is a
#     frozen fossil (no merge ref exists, so nothing can refresh it).
#   - drain.md's D_dirty_red set is no longer a distinct dispatch target
#     routed to fix-checks — it's an informational subset of D_dirty (same
#     membership plus a hard-failure check), dispatched to fix-rebase exactly
#     like any other D_dirty member. R_new (which DOES route to fix-checks)
#     gained an explicit mergeStateStatus != "DIRTY" exclusion so a
#     DIRTY-and-red PR is never double-counted into it.
#
# This regression guard asserts the fix:
#   1. drain.md's D_dirty_red is defined as an informational subset of
#      D_dirty and references #1060.
#   2. drain.md's D_dirty does NOT exclude D_dirty_red members (D_dirty_red
#      is a subset, not a disjoint set).
#   3. drain.md's R_new explicitly excludes DIRTY PRs.
#   4. Per-poll action 1 (fix-checks) does NOT dispatch D_dirty_red.
#   5. Per-poll action 2 (fix-rebase) routes D_dirty (including D_dirty_red)
#      to fix-rebase, and the drain log names the DIRTY+failing routing as
#      "fix-rebase (not fix-checks)".
#   6. The drain status line still includes the dirty_red= token (now purely
#      informational).
#   7. fix-rebase.md's hard-failure bail is gated on mergeStateStatus !=
#      "DIRTY", and explicitly skips the bail while DIRTY.
#   8. The old #577-only routing language ("fix-checks (not fix-rebase)" for
#      D_dirty_red, and the "Never dispatch a fix-rebase worker against a PR
#      in D_dirty_red" prohibition) is gone.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/drain-dirty-red-routing.test.sh

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
fix_rebase_path="$repo_root/plugins/shipyard/agents/issue-worker/fix-rebase.md"

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
    printf '    expected to find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to NOT find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

echo ""
echo "Test: drain DIRTY-AND-red routing to fix-rebase (#1060 regression guard, supersedes #577)"
echo ""

assert_file_exists "$drain_path" "drain.md exists"
assert_file_exists "$fix_rebase_path" "fix-rebase.md exists"

echo ""
echo "D_dirty_red set — informational subset of D_dirty, references #1060"
echo ""

assert_contains "$drain_path" \
  "D_dirty_red" \
  "drain.md defines D_dirty_red set"

assert_contains "$drain_path" \
  "#1060" \
  "drain.md D_dirty_red definition references issue #1060"

assert_contains "$drain_path" \
  "informational subset" \
  "drain.md describes D_dirty_red as an informational subset of D_dirty"

echo ""
echo "D_dirty set — does NOT exclude D_dirty_red members; R_new excludes DIRTY"
echo ""

# D_dirty must NOT explicitly exclude D_dirty_red members anymore — the old
# "AND are NOT in D_dirty_red" guard was the #577-era disjoint-set shape.
assert_not_contains "$drain_path" \
  "NOT in \`D_dirty_red\`" \
  "drain.md D_dirty no longer excludes D_dirty_red members (they're a subset now)"

# R_new must explicitly exclude DIRTY PRs so a DIRTY-and-red PR is never
# double-counted into the fix-checks routing.
assert_contains "$drain_path" \
  "mergeStateStatus != \"DIRTY\"" \
  "drain.md R_new excludes mergeStateStatus == DIRTY"

echo ""
echo "Per-poll actions — D_dirty_red routes to fix-rebase, not fix-checks"
echo ""

# Action 1 (fix-checks) must explicitly say D_dirty_red is NOT dispatched here.
assert_contains "$drain_path" \
  "D_dirty_red\` PRs are NOT dispatched here" \
  "drain.md action 1 explicitly excludes D_dirty_red from fix-checks dispatch"

# Action 2 (fix-rebase) must say D_dirty includes D_dirty_red members.
assert_contains "$drain_path" \
  "D_dirty\` includes every \`D_dirty_red\` member" \
  "drain.md action 2 confirms D_dirty includes D_dirty_red"

# The drain log line must now route D_dirty_red to fix-rebase, not fix-checks.
assert_contains "$drain_path" \
  "fix-rebase (not fix-checks); routing via D_dirty_red (#1060, supersedes #577)" \
  "drain.md log line routes D_dirty_red to fix-rebase, citing #1060 supersedes #577"

echo ""
echo "Drain status line — dirty_red= token still present (now purely informational)"
echo ""

assert_contains "$drain_path" \
  "dirty_red=<D_dirty_red>" \
  "drain.md status line includes dirty_red= token"

echo ""
echo "fix-rebase.md — hard-failure bail gated on mergeStateStatus != DIRTY"
echo ""

assert_contains "$fix_rebase_path" \
  'mergeStateStatus != "DIRTY"' \
  "fix-rebase.md hard-failure bail description names mergeStateStatus != DIRTY"

assert_contains "$fix_rebase_path" \
  'skip the failing-check bail entirely' \
  "fix-rebase.md documents skipping the failing-check bail while DIRTY"

assert_contains "$fix_rebase_path" \
  "#1060" \
  "fix-rebase.md references issue #1060"

echo ""
echo "Negative assertions — old #577-only single-direction routing language is gone"
echo ""

# The old rule said D_dirty_red routes to fix-checks and must NEVER go to
# fix-rebase. Both framings are now backwards and must not survive.
assert_not_contains "$drain_path" \
  "Never dispatch a fix-rebase worker against a PR in \`D_dirty_red\`" \
  "drain.md no longer forbids dispatching fix-rebase against D_dirty_red"

assert_not_contains "$drain_path" \
  "fix-checks rebases as part of getting green" \
  "drain.md no longer claims fix-checks rebases as part of getting green"

echo ""
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
exit 0

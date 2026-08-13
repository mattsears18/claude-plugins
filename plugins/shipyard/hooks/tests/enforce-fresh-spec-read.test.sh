#!/usr/bin/env bash
# Test suite for hooks/enforce-fresh-spec-read.sh.
#
# Run with:
#   bash plugins/shipyard/hooks/tests/enforce-fresh-spec-read.test.sh
#
# Each test crafts a PreToolUse JSON payload, pipes it to the hook, and
# asserts on stderr + exit code. Exit 2 == blocked (redirected to the
# worktree-local equivalent). Exit 0 == allowed (transparent).
#
# The hook decides whether a `Read` call targeting a plugins/shipyard/**
# spec file OUTSIDE the agent's own isolated worktree should be blocked and
# redirected to the worktree-local copy — see
# plugins/shipyard/hooks/enforce-fresh-spec-read.sh for the decision rules
# (issue #1320).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/../enforce-fresh-spec-read.sh"

if [[ ! -f "$hook" ]]; then
  echo "FAIL: hook not found at $hook" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

# Build an isolated workspace tree that mirrors the real dogfooding layout:
#
#   $TMP/primary/plugins/shipyard/...                       ← primary checkout's spec copy
#   $TMP/primary/.claude/worktrees/agent-deadbeef/plugins/shipyard/...  ← worker's own fresh copy
#
# Hook is invoked with cwd = the worktree path (matching how the harness runs
# the agent), and file_path points at either the worktree-local copy, the
# primary-checkout copy, or something unrelated entirely.
TMP=$(mktemp -d -t shipyard-fresh-spec-read-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PRIMARY="$TMP/primary"
WT="$PRIMARY/.claude/worktrees/agent-deadbeef"
OTHER_WT="$PRIMARY/.claude/worktrees/agent-cafef00d"
ORCH="$PRIMARY/.claude/worktrees/orchestrator-20260520-061027"

mkdir -p "$WT/plugins/shipyard/agents/issue-worker"
mkdir -p "$PRIMARY/plugins/shipyard/agents/issue-worker"
mkdir -p "$OTHER_WT/plugins/shipyard/agents/issue-worker"
mkdir -p "$ORCH/plugins/shipyard/agents/issue-worker"
mkdir -p "$PRIMARY/src"

# The SAME relative spec file exists in both the worktree and the primary —
# the worktree copy is the "fresh" one the hook should redirect to.
echo "worktree-local (fresh)" >"$WT/plugins/shipyard/agents/issue-worker/issue-work.md"
echo "primary checkout (possibly stale)" >"$PRIMARY/plugins/shipyard/agents/issue-worker/issue-work.md"
echo "primary checkout (possibly stale)" >"$OTHER_WT/plugins/shipyard/agents/issue-worker/issue-work.md"

# A spec file that exists ONLY in the primary checkout — no worktree-local
# equivalent (simulates a brand-new file the worktree's stale checkout
# predates, or a consumer-install layout with no local copy at all).
echo "primary-only file" >"$PRIMARY/plugins/shipyard/agents/issue-worker/brand-new.md"

echo "not a spec file" >"$PRIMARY/src/code.ts"

# Helper — invoke hook with payload on stdin. Returns: "<exit_code>::<stderr>"
run_hook() {
  local payload="$1"
  local stderr exit_code
  stderr=$(printf '%s' "$payload" | bash "$hook" 2>&1 >/dev/null)
  exit_code=$?
  printf '%s::%s' "$exit_code" "$stderr"
}

assert_exit() {
  local result="$1" want="$2" label="$3"
  local got="${result%%::*}"
  if [[ "$got" == "$want" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (want exit %s, got %s)\n' "$RED" "$RESET" "$label" "$want" "$got"
    printf '    stderr: %s\n' "${result#*::}"
    fail=$((fail+1))
  fi
}

assert_blocked_with() {
  local result="$1" needle="$2" label="$3"
  local got="${result%%::*}"
  local stderr="${result#*::}"
  if [[ "$got" == "2" && "$stderr" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    want exit 2 and stderr containing %q\n' "$needle"
    printf '    got exit %s, stderr: %s\n' "$got" "$stderr"
    fail=$((fail+1))
  fi
}

mkpayload() {
  # Args: tool_name, file_path, cwd
  local tool="$1" fp="$2" cwd="$3"
  python3 -c "
import json
print(json.dumps({
    'tool_name': '$tool',
    'cwd': '$cwd',
    'tool_input': {'file_path': '$fp'},
}))"
}

# -----------------------------------------------------------------------------
echo "== Reading the primary checkout's spec copy from inside a worker's worktree is blocked, when a fresher copy exists"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Read "$PRIMARY/plugins/shipyard/agents/issue-worker/issue-work.md" "$WT")")
assert_blocked_with "$out" "BLOCKED by shipyard/hooks/enforce-fresh-spec-read.sh" \
  "Read of primary-checkout spec file from worker worktree → blocked"
assert_blocked_with "$out" "$WT/plugins/shipyard/agents/issue-worker/issue-work.md" \
  "block message names the worktree-local re-issue target"

# -----------------------------------------------------------------------------
echo "== Reading the worktree's own copy is always allowed"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Read "$WT/plugins/shipyard/agents/issue-worker/issue-work.md" "$WT")")
assert_exit "$out" "0" "Read of worktree-local spec file → allowed"

# -----------------------------------------------------------------------------
echo "== No worktree-local equivalent on disk → falls through (issue #969 fallback)"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Read "$PRIMARY/plugins/shipyard/agents/issue-worker/brand-new.md" "$WT")")
assert_exit "$out" "0" "Read of primary-only file (no worktree copy to redirect to) → allowed"

# -----------------------------------------------------------------------------
echo "== Reading a non-spec file is never blocked"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Read "$PRIMARY/src/code.ts" "$WT")")
assert_exit "$out" "0" "Read of a file outside plugins/shipyard/ → allowed"

# -----------------------------------------------------------------------------
echo "== Reading a sibling worker's worktree copy is also blocked"
# -----------------------------------------------------------------------------
# A worker reading a DIFFERENT worktree's copy isn't its own fresh copy
# either — same redirect applies, worktree discipline says stay out of
# another worker's worktree entirely.

out=$(run_hook "$(mkpayload Read "$OTHER_WT/plugins/shipyard/agents/issue-worker/issue-work.md" "$WT")")
assert_blocked_with "$out" "BLOCKED by shipyard/hooks/enforce-fresh-spec-read.sh" \
  "Read of sibling worker's worktree copy → blocked"

# -----------------------------------------------------------------------------
echo "== Non-Read tools pass through unaffected"
# -----------------------------------------------------------------------------

for tool in Edit Write Bash Grep; do
  out=$(run_hook "$(mkpayload "$tool" "$PRIMARY/plugins/shipyard/agents/issue-worker/issue-work.md" "$WT")")
  assert_exit "$out" "0" "$tool tool → not blocked (only Read is guarded)"
done

# -----------------------------------------------------------------------------
echo "== Hook is a no-op when not running inside a worker's worktree"
# -----------------------------------------------------------------------------
# The orchestrator's own worktree, or a bare primary-checkout session, has no
# basis for this redirect — the orchestrator legitimately reads the primary
# checkout directly (this guard is scoped to dispatched WORKER sessions).

out=$(run_hook "$(mkpayload Read "$PRIMARY/plugins/shipyard/agents/issue-worker/issue-work.md" "$PRIMARY")")
assert_exit "$out" "0" "cwd is primary checkout (no agent worktree) → allowed"

out=$(run_hook "$(mkpayload Read "$PRIMARY/plugins/shipyard/agents/issue-worker/issue-work.md" "$ORCH")")
assert_exit "$out" "0" "cwd is orchestrator worktree → allowed (orchestrator may read the primary directly)"

# -----------------------------------------------------------------------------
echo "== Relative file_path is resolved against cwd"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Read "plugins/shipyard/agents/issue-worker/issue-work.md" "$WT")")
assert_exit "$out" "0" "relative path already resolving inside the worktree → allowed"

out=$(run_hook "$(mkpayload Read "../../../plugins/shipyard/agents/issue-worker/issue-work.md" "$WT")")
assert_blocked_with "$out" "BLOCKED by shipyard/hooks/enforce-fresh-spec-read.sh" \
  "relative path escaping into the primary checkout's spec tree → blocked"

# -----------------------------------------------------------------------------
echo "== Malformed payloads exit 0 (don't break the session)"
# -----------------------------------------------------------------------------

out=$(run_hook "not-json-at-all")
assert_exit "$out" "0" "malformed JSON → allowed (no false block)"

out=$(run_hook "{}")
assert_exit "$out" "0" "empty object → allowed"

out=$(run_hook '{"tool_name":"Read"}')
assert_exit "$out" "0" "missing tool_input → allowed"

out=$(run_hook '{"tool_name":"Read","tool_input":{}}')
assert_exit "$out" "0" "missing file_path → allowed"

# -----------------------------------------------------------------------------
echo "== Summary"
# -----------------------------------------------------------------------------

total=$((pass+fail))
if (( fail == 0 )); then
  printf '%s%d/%d tests pass.%s\n' "$GREEN" "$pass" "$total" "$RESET"
  exit 0
else
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$total" "$fail" "$RESET"
  exit 1
fi

#!/usr/bin/env bash
# Test suite for the four worktree-lock-reap scripts extracted from
# dispatch-rules.md / drain.md / steady-state.md by issue #1289:
#   - concurrent-session-guard.sh   (dispatch-rules.md's concurrent-session guard)
#   - pre-dispatch-branch-reap.sh   (dispatch-rules.md §2d)
#   - drain-pre-dispatch-branch-reap.sh (drain.md's pre-dispatch head-branch reap)
#   - shipped-immediate-branch-reap.sh  (steady-state.md's A.1 shipped-immediate reap)
#
# Covers, per script: usage/arg validation, "no matching worktree" behavior,
# and a real reap/classification against a `dead` lock (a lock file naming a
# PID that cannot possibly be alive) — the one classification every script's
# force-reap logic agrees is always safe, so it doesn't require mocking
# process liveness or the orchestrator-PID ancestor walk.
#
# Uses REAL git worktrees (mirrors worktree-reap.test.sh's fixture
# convention) — no gh/network dependency. Run with:
#   bash plugins/shipyard/scripts/tests/branch-reap-scripts-1289.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts_dir="$(cd "$here/.." && pwd)"

concurrent_guard="${scripts_dir}/concurrent-session-guard.sh"
pre_dispatch_reap="${scripts_dir}/pre-dispatch-branch-reap.sh"
drain_reap="${scripts_dir}/drain-pre-dispatch-branch-reap.sh"
shipped_reap="${scripts_dir}/shipped-immediate-branch-reap.sh"

for s in "$concurrent_guard" "$pre_dispatch_reap" "$drain_reap" "$shipped_reap"; do
  if [[ ! -f "$s" ]]; then
    echo "FAIL: helper not found at $s" >&2
    exit 1
  fi
done

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
    printf '    actual: %s\n' "$haystack"
    fail=$((fail+1))
  fi
}

assert_exit() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (exit %s, want %s)\n' "$RED" "$RESET" "$label" "$got" "$want"
    fail=$((fail+1))
  fi
}

TMPDIR_ROOT="$(mktemp -d -t branch-reap-scripts-1289.XXXXXX)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

repo="$TMPDIR_ROOT/repo"
home="$TMPDIR_ROOT/home"

reset_repo() {
  rm -rf "$repo" "$home"
  mkdir -p "$repo" "$home"
  (
    cd "$repo" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
  ) >/dev/null 2>&1
}

# A PID astronomically unlikely to be alive on any real system, and never
# our own PID or an ancestor of it — classify-lock reports this as `dead`.
DEAD_PID=999999999

# add_worktree <branch> — registers a real agent-<branch>-suffix worktree
# checked out on <branch>, with a dead-PID lock file.
add_worktree() {
  local branch="$1" name="$2"
  (
    cd "$repo" || exit 1
    git branch "$branch" >/dev/null 2>&1
    git worktree add -q ".claude/worktrees/${name}" "$branch"
    mkdir -p ".git/worktrees/${name}"
    printf 'claude agent %s (pid %s)\n' "$name" "$DEAD_PID" > ".git/worktrees/${name}/locked"
  ) >/dev/null 2>&1
}

echo "branch-reap scripts test suite (issue #1289)"
echo "=============================================="

# ==========================================================================
echo
echo "concurrent-session-guard.sh"
# ==========================================================================
out="$(bash "$concurrent_guard" check 2>&1)"; rc=$?
assert_contains "$out" "required" "check without --issue errors"
assert_exit "$rc" "64" "missing required args exits 64"

reset_repo
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$concurrent_guard" check --issue 42 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/guard-noop.out"
)
out="$(cat "$TMPDIR_ROOT/guard-noop.out")"
assert_contains "$out" "peer_locked=false" "no matching do-work/issue-42 worktree -> peer_locked=false"

reset_repo
add_worktree "do-work/issue-42" "agent-guardtest"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$concurrent_guard" check --issue 42 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/guard-dead.out"
)
out="$(cat "$TMPDIR_ROOT/guard-dead.out")"
# A `dead` lock is NOT peer-alive/unknown, so the guard reports the issue as
# unlocked (a dead lock never blocks dispatch — only peer-alive/unknown do).
assert_contains "$out" "peer_locked=false" "a dead-PID lock on the matching branch does not block dispatch"

# ==========================================================================
echo
echo "pre-dispatch-branch-reap.sh"
# ==========================================================================
out="$(bash "$pre_dispatch_reap" reap --head-ref foo 2>&1)"; rc=$?
assert_contains "$out" "required" "reap without --session-id errors"
assert_exit "$rc" "64" "missing required args exits 64"

reset_repo
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$pre_dispatch_reap" reap --head-ref do-work/issue-1 --session-id test-session 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/predispatch-noop.out"
)
out="$(tail -1 "$TMPDIR_ROOT/predispatch-noop.out")"
assert_contains "$out" "reaped=false" "no matching worktree -> reaped=false"

reset_repo
add_worktree "do-work/issue-1" "agent-predispatch1"
wt_path="$repo/.claude/worktrees/agent-predispatch1"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$pre_dispatch_reap" reap --head-ref do-work/issue-1 --session-id test-session 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/predispatch-reap.out"
)
out="$(tail -1 "$TMPDIR_ROOT/predispatch-reap.out")"
assert_contains "$out" "reaped=true" "a dead-PID lock on the matching branch is reaped"
assert_contains "$out" "classification=dead" "dead classification reported (not relabeled — only peer-alive is)"
if [[ ! -e "$wt_path" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "reaped worktree is gone from disk"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "reaped worktree is gone from disk"; fail=$((fail+1))
fi
if (cd "$repo" && git rev-parse --verify "do-work/issue-1" >/dev/null 2>&1); then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "local branch ref is dropped after reap"; fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "local branch ref is dropped after reap"; pass=$((pass+1))
fi

# ==========================================================================
echo
echo "shipped-immediate-branch-reap.sh"
# ==========================================================================
out="$(bash "$shipped_reap" reap 2>&1)"; rc=$?
assert_contains "$out" "required" "reap without --issue errors"
assert_exit "$rc" "64" "missing required args exits 64"

reset_repo
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$shipped_reap" reap --issue 7 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/shipped-noop.out"
)
out="$(tail -1 "$TMPDIR_ROOT/shipped-noop.out")"
assert_contains "$out" "reaped=false" "no matching do-work/issue-7 worktree -> reaped=false"

reset_repo
add_worktree "do-work/issue-7" "agent-shipped7"
wt_path2="$repo/.claude/worktrees/agent-shipped7"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" bash "$shipped_reap" reap --issue 7 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/shipped-reap.out"
)
out="$(tail -1 "$TMPDIR_ROOT/shipped-reap.out")"
assert_contains "$out" "reaped=true" "a dead-PID lock on do-work/issue-7 is reaped"
if [[ ! -e "$wt_path2" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "reaped worktree is gone from disk"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "reaped worktree is gone from disk"; fail=$((fail+1))
fi

# ==========================================================================
echo
echo "drain-pre-dispatch-branch-reap.sh"
# ==========================================================================
out="$(bash "$drain_reap" reap --head-ref foo --repo o/r 2>&1)"; rc=$?
assert_contains "$out" "required" "reap without --session-id errors"
assert_exit "$rc" "64" "missing required args exits 64"

reset_repo
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" GH="$(command -v true)" bash "$drain_reap" reap \
    --head-ref do-work/issue-3 --repo o/r --session-id test-session 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/drain-noop.out"
)
out="$(cat "$TMPDIR_ROOT/drain-noop.out")"
assert_contains "$out" "reap_outcome=none" "no matching worktree -> reap_outcome=none"
assert_contains "$out" "primary_leak_restored=false" "no primary-checkout leak -> primary_leak_restored=false"

reset_repo
add_worktree "do-work/issue-3" "agent-drain3"
wt_path3="$repo/.claude/worktrees/agent-drain3"
(
  cd "$repo" || exit 1
  out="$(SHIPYARD_HOME="$home" GH="$(command -v true)" bash "$drain_reap" reap \
    --head-ref do-work/issue-3 --repo o/r --session-id test-session 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/drain-reap.out"
)
out="$(cat "$TMPDIR_ROOT/drain-reap.out")"
# do-work/issue-* branch pattern -> force-reap applies even before considering
# peer-alive/unknown; a plain `dead` classification is reaped unconditionally.
assert_contains "$out" "reap_outcome=reaped" "a dead-PID lock on a do-work/issue-* branch is reaped"
if [[ ! -e "$wt_path3" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "reaped worktree is gone from disk"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "reaped worktree is gone from disk"; fail=$((fail+1))
fi

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

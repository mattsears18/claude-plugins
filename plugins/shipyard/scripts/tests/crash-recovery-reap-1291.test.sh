#!/usr/bin/env bash
# Test suite for scripts/crash-recovery-reap.sh — the A.0.5 crash-recovery
# reap logic extracted from steady-state.md by issue #1291 (the
# deliberately-deferred follow-up to #1289's sweep of the other 17
# compound-shell blocks).
#
# Covers, with REAL git worktrees (mirrors worktree-reap.test.sh's and
# branch-reap-scripts-1289.test.sh's fixture convention — no gh/network
# dependency, gh calls stubbed via the $GH env var):
#
#   - terminal=true short-circuit: a clean terminal return does NOTHING —
#     no reap, no recovery, no side effect (the is_terminal gate is a
#     genuine no-op path, not a shortcut).
#   - harness-status=failed treated as non-terminal UNCONDITIONALLY, even
#     when the return text itself looks terminal (the #833 stall-watchdog
#     trigger).
#   - non-terminal + no matching worktree on disk: still prints a result
#     line (fire-and-forget — nothing to reap, nothing crashes).
#   - non-terminal + a dead-PID lock on the target worktree: force-reaps it
#     (issue #771 — every classification including peer-alive reaps here).
#   - non-terminal + slot-kind=issue + committed-but-unpushed work (#493):
#     pushes the branch, and (with gh stubbed) attempts PR create.
#   - non-terminal + slot-kind=issue + dirty working tree, no commits
#     (#495): auto-commits with --no-verify, pushes, and (with gh stubbed)
#     attempts PR create.
#   - non-terminal + slot-kind != issue: recovery is skipped entirely (only
#     the reap fires) — the scope guard from issue #493/#495's own spec.
#   - genuinely clean worktree (no commits ahead, no dirty files): recovery
#     finds nothing to salvage; the reap still fires.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/crash-recovery-reap-1291.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts_dir="$(cd "$here/.." && pwd)"

crash_reap="${scripts_dir}/crash-recovery-reap.sh"

if [[ ! -f "$crash_reap" ]]; then
  echo "FAIL: helper not found at $crash_reap" >&2
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
    printf '    actual: %s\n' "$haystack"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to contain: %s\n' "$needle"
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

# assert_branch_log_contains <repo-dir> <branch> <needle> <label> — runs
# `git log` in the CURRENT shell (no subshell) so pass/fail mutations aren't
# lost once the check completes (shellcheck SC2030/SC2031 — a `(...)`
# subshell's variable writes don't propagate to the parent shell).
assert_branch_log_contains() {
  local repo_dir="$1" branch="$2" needle="$3" label="$4"
  if git -C "$repo_dir" log "$branch" --oneline 2>/dev/null | grep -qF -- "$needle"; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    fail=$((fail+1))
  fi
}

# assert_branch_log_not_contains <repo-dir> <branch> <needle> <label> — the
# negated counterpart, same no-subshell rationale as assert_branch_log_contains.
assert_branch_log_not_contains() {
  local repo_dir="$1" branch="$2" needle="$3" label="$4"
  if git -C "$repo_dir" log "$branch" --oneline 2>/dev/null | grep -qF -- "$needle"; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  fi
}

TMPDIR_ROOT="$(mktemp -d -t crash-recovery-reap-1291.XXXXXX)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

repo="$TMPDIR_ROOT/repo"
home="$TMPDIR_ROOT/home"

# A minimal gh stub covering exactly the subcommands crash-recovery-reap.sh
# calls during the #493/#495 recovery paths — a bare `/usr/bin/true` isn't
# enough because `gh repo view ... -q .defaultBranchRef.name` needs to
# actually print "main" (an empty stdout with exit 0 leaves DEFAULT_BRANCH
# empty, corrupting every downstream `origin/${DEFAULT_BRANCH}..HEAD` ref).
#
# Also stubs the two calls a05_version_bump makes when
# version_coordination.enabled=true (issue #1298's regression fixture):
# `gh issue view ... -q .title/.body` (bump-level inference) and
# `gh api repos/.../contents/plugin.json?ref=main --jq .content` (reads the
# origin manifest version). Both are no-ops for every OTHER test in this
# suite, which never enables version_coordination.
gh_stub="$TMPDIR_ROOT/gh-stub.sh"
cat > "$gh_stub" << 'STUBEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "main" ;;
  "pr list") ;; # empty — no existing PR, forces the create path
  "pr create") echo "999" ;; # a fake recovered PR number
  "pr merge") ;; # succeed silently, no output
  "pr view") echo '{"state":"OPEN","autoMerge":false}' ;;
  "issue view")
    all_args="$*"
    if [[ "$all_args" == *".title"* ]]; then
      echo "fix: recovered issue title"
    elif [[ "$all_args" == *".body"* ]]; then
      echo "recovered issue body"
    fi
    ;;
  *) ;;
esac
if [[ "$1" == "api" ]]; then
  case "${2%%\?*}" in
    repos/o/r/contents/plugin.json)
      # Base64 of {"version": "1.0.0"} — must match the worktree-side
      # plugin.json version the "bump applied" test writes below, since
      # a05_version_bump only bumps when wt_version == origin_version.
      printf '{"version": "1.0.0"}' | base64
      ;;
  esac
fi
exit 0
STUBEOF
chmod +x "$gh_stub"

reset_repo() {
  rm -rf "$repo" "$home"
  mkdir -p "$repo" "$home"
  (
    cd "$repo" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
    # A local "origin" remote pointing at this same repo, so `git push
    # origin <branch>` inside the script has somewhere real to push.
    git remote add origin "$repo"
  ) >/dev/null 2>&1
}

# A PID astronomically unlikely to be alive on any real system, and never
# our own PID or an ancestor of it — classify-lock reports this as `dead`.
DEAD_PID=999999999

# add_worktree <branch> <name> — registers a real agent-<name> worktree
# checked out on <branch>, with a dead-PID lock file (mirrors
# branch-reap-scripts-1289.test.sh's fixture convention).
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

run_reap() {
  # Runs crash-recovery-reap.sh reap with cwd anchored at $repo (mirrors
  # how the orchestrator invokes it — from its own worktree root, where
  # the .git/worktrees layout and any .shipyard-primary-root stash live).
  (
    cd "$repo" || exit 1
    SHIPYARD_HOME="$home" bash "$crash_reap" reap "$@" 2>&1
  )
}

echo "crash-recovery-reap.sh test suite (issue #1291)"
echo "================================================="

# ==========================================================================
echo
echo "usage / arg validation"
# ==========================================================================
out="$(bash "$crash_reap" reap 2>&1)"; rc=$?
assert_contains "$out" "required" "reap without required args errors"
assert_exit "$rc" "64" "missing required args exits 64"

out="$(bash "$crash_reap" bogus-subcommand 2>&1)"; rc=$?
assert_exit "$rc" "64" "unknown subcommand exits 64"

# ==========================================================================
echo
echo "terminal=true short-circuit"
# ==========================================================================
reset_repo
out="$(run_reap --repo o/r --slot-id s1 --agent-id nonexistent1 --return-text "shipped #5 via PR #9" --harness-status completed)"
assert_contains "$out" "terminal=true" "a clean 'shipped' return short-circuits to terminal=true"
assert_not_contains "$out" "reconcile-A.0.5" "terminal=true path logs NOTHING — no reap, no recovery attempted"

reset_repo
out="$(run_reap --repo o/r --slot-id s1b --agent-id nonexistent1b --return-text "blocked #7 at implement: ambiguous" --harness-status completed)"
assert_contains "$out" "terminal=true" "a clean 'blocked' return also short-circuits to terminal=true"

reset_repo
out="$(run_reap --repo o/r --slot-id s1c --agent-id nonexistent1c --return-text "reaped: my worktree was reaped" --harness-status completed)"
assert_contains "$out" "terminal=true" "a clean 'reaped:' return also short-circuits to terminal=true"

# ==========================================================================
echo
echo "harness-status=failed overrides a terminal-looking return text (#833)"
# ==========================================================================
reset_repo
out="$(run_reap --repo o/r --slot-id s2 --agent-id nonexistent2 --return-text "shipped #5 via PR #9" --harness-status failed)"
last_line="$(printf '%s\n' "$out" | tail -1)"
assert_contains "$last_line" "terminal=false" "harness-status=failed treats a terminal-looking text as non-terminal"

# ==========================================================================
echo
echo "non-terminal, no matching worktree on disk"
# ==========================================================================
reset_repo
out="$(run_reap --repo o/r --slot-id s3 --agent-id doesnotexist456 --return-text "API Error: socket closed" --harness-status completed)"
last_line="$(printf '%s\n' "$out" | tail -1)"
assert_contains "$last_line" "terminal=false" "a crash-like return with no matching worktree is still non-terminal"
assert_contains "$last_line" "worktree_name=agent-doesnotexist456" "result line names the (nonexistent) worktree"
assert_contains "$last_line" "classification=" "result line has an (empty) classification field when wt_dir never existed"

# ==========================================================================
echo
echo "non-terminal, dead-PID lock, slot-kind != issue (recovery skipped, still reaps)"
# ==========================================================================
reset_repo
add_worktree "some-other-branch" "agent-deadtest"
wt_path="$repo/.claude/worktrees/agent-deadtest"
out="$(run_reap --repo o/r --slot-id s4 --agent-id deadtest --return-text "" --harness-status completed)"
last_line="$(printf '%s\n' "$out" | tail -1)"
assert_contains "$last_line" "terminal=false" "empty return text is non-terminal"
assert_contains "$last_line" "classification=dead" "a dead-PID lock classifies as dead"
if [[ ! -e "$wt_path" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "reaped worktree is gone from disk"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "reaped worktree is gone from disk"; fail=$((fail+1))
fi
assert_not_contains "$out" "pre-reap recovery" "no slot-kind means no recovery attempt logged"

# ==========================================================================
echo
echo "non-terminal, slot-kind=issue, committed-but-unpushed work (#493)"
# ==========================================================================
reset_repo
add_worktree "do-work/issue-42" "agent-committed42"
wt_path="$repo/.claude/worktrees/agent-committed42"
(
  cd "$wt_path" || exit 1
  git config user.email "worker@example.com"
  git config user.name "Worker"
  echo "fix content" > fix.txt
  git add fix.txt
  git commit -q -m "fix: the actual change"
) >/dev/null 2>&1
out="$(GH="$gh_stub" run_reap --repo o/r --slot-id s5 --agent-id committed42 --slot-kind issue --slot-issue 42 --return-text "" --harness-status completed)"
assert_contains "$out" "committed-but-unpushed commit(s); attempting pre-reap recovery (#493)" "committed-but-unpushed work triggers #493 recovery"
assert_contains "$out" "push do-work/issue-42: ok=true" "the committed branch pushes successfully to the local origin remote"
if [[ ! -e "$wt_path" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "worktree reaped after #493 recovery"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "worktree reaped after #493 recovery"; fail=$((fail+1))
fi
# Confirm the pushed commit actually landed on the local "origin" remote —
# not just that the push command reported success.
assert_branch_log_contains "$repo" "do-work/issue-42" "the actual change" \
  "the salvaged commit is present on origin's do-work/issue-42 branch"

# ==========================================================================
echo
echo "non-terminal, slot-kind=issue, dirty working tree, no commits (#495)"
# ==========================================================================
reset_repo
add_worktree "do-work/issue-43" "agent-dirty43"
wt_path="$repo/.claude/worktrees/agent-dirty43"
echo "uncommitted edit" > "$wt_path/newfile.txt"
out="$(GH="$gh_stub" run_reap --repo o/r --slot-id s6 --agent-id dirty43 --slot-kind issue --slot-issue 43 --return-text "" --harness-status completed)"
assert_contains "$out" "dirty working tree but no commits; attempting dirty-worktree auto-commit recovery (#495)" "dirty working tree with no commits triggers #495 recovery"
assert_contains "$out" "dirty-worktree auto-commit: ok=true" "the dirty-worktree auto-commit succeeds"
assert_contains "$out" "push do-work/issue-43: ok=true" "the auto-committed branch pushes successfully"
assert_branch_log_contains "$repo" "do-work/issue-43" "crash-recovery auto-commit" \
  "the auto-commit is present on origin's do-work/issue-43 branch"

# ==========================================================================
echo
echo "non-terminal, slot-kind=issue, genuinely clean worktree (nothing to recover)"
# ==========================================================================
reset_repo
add_worktree "do-work/issue-44" "agent-clean44"
wt_path="$repo/.claude/worktrees/agent-clean44"
out="$(GH="$gh_stub" run_reap --repo o/r --slot-id s7 --agent-id clean44 --slot-kind issue --slot-issue 44 --return-text "" --harness-status completed)"
last_line="$(printf '%s\n' "$out" | tail -1)"
assert_not_contains "$out" "attempting pre-reap recovery" "a genuinely clean worktree triggers no #493 recovery"
assert_not_contains "$out" "attempting dirty-worktree auto-commit recovery" "a genuinely clean worktree triggers no #495 recovery"
assert_contains "$last_line" "recovered_pr=" "recovered_pr is empty when nothing was salvaged"
if [[ ! -e "$wt_path" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "clean worktree is still reaped"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "clean worktree is still reaped"; fail=$((fail+1))
fi

# ==========================================================================
echo
echo "release-bump commit-message clause tracks a05_bump_applied's VALUE, not its emptiness (#1298)"
# ==========================================================================
# a05_version_bump always sets a05_bump_applied to the literal string "true"
# or "false" — never empty. The old \${a05_bump_applied:+...} form tests for
# non-emptiness, so it emitted the "release bump" clause even when the value
# was "false". Both branches below exercise the dirty-worktree (#495)
# auto-commit path, which is where the buggy interpolation lived.

echo
echo "  bump NOT applied (version_coordination disabled — the default)"
reset_repo
add_worktree "do-work/issue-45" "agent-nobump45"
wt_path="$repo/.claude/worktrees/agent-nobump45"
echo "uncommitted edit" > "$wt_path/newfile.txt"
# No shipyard.config.json written — version_coordination.enabled falls back
# to the built-in default (false), so a05_version_bump returns early with
# a05_bump_applied="false" (a non-empty string — the exact case the bug
# mishandled).
out="$(GH="$gh_stub" run_reap --repo o/r --slot-id s8 --agent-id nobump45 --slot-kind issue --slot-issue 45 --return-text "" --harness-status completed)"
assert_contains "$out" "dirty-worktree auto-commit: ok=true" "the dirty-worktree auto-commit succeeds (bump disabled)"
assert_branch_log_not_contains "$repo" "do-work/issue-45" "release bump" \
  "auto-commit message has NO release-bump clause when a05_bump_applied=false (the #1298 bug, fixed)"
assert_branch_log_contains "$repo" "do-work/issue-45" "orchestrator A.0.5 #495)" \
  "auto-commit message closes cleanly with no trailing bump clause"

echo
echo "  bump APPLIED (version_coordination enabled, worktree matches origin version)"
reset_repo
add_worktree "do-work/issue-46" "agent-bump46"
wt_path="$repo/.claude/worktrees/agent-bump46"
# Repo-level config, read from cwd ($repo) by shipyard-config.sh — enables
# version_coordination with a manifest_path matching the gh-stub's
# `api .../contents/plugin.json` fixture content (both at version 1.0.0, so
# a05_version_bump's wt_version==origin_version gate lets the bump proceed).
cat > "$repo/shipyard.config.json" << 'CONFEOF'
{
  "version": 1,
  "version_coordination": {
    "enabled": true,
    "manifest_path": "plugin.json",
    "manifest_version_jq": ".version",
    "changelog_path": ""
  }
}
CONFEOF
echo '{"version": "1.0.0"}' > "$wt_path/plugin.json"
echo "uncommitted edit" > "$wt_path/newfile.txt"
out="$(GH="$gh_stub" run_reap --repo o/r --slot-id s9 --agent-id bump46 --slot-kind issue --slot-issue 46 --return-text "" --harness-status completed)"
assert_contains "$out" "version-bump: applied 1.0.0 → 1.0.1" "the version bump applies when worktree matches origin (patch level, no feat/breaking signal)"
assert_contains "$out" "dirty-worktree auto-commit: ok=true" "the dirty-worktree auto-commit succeeds (bump applied)"
assert_branch_log_contains "$repo" "do-work/issue-46" "release bump 1.0.1 #575" \
  "auto-commit message HAS the release-bump clause when a05_bump_applied=true"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

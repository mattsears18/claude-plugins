#!/usr/bin/env bash
# Test suite for scripts/primary-leak-guard.sh — steady-state.md's A.0.6
# "primary-checkout branch-leak guard" extracted to a script by issue
# #1323 (the remaining, unconverted work in the #1316/#1317 family).
#
# Covers, with REAL git repos/worktrees (mirrors branch-reap-scripts-1289
# .test.sh's fixture convention — no network dependency, gh stubbed via a
# fake executable passed through the $GH env var):
#
#   - usage/arg validation (missing --repo, unknown subcommand).
#   - primary already on the default branch -> verdict=clean, no writes.
#   - primary off-default AND working tree clean -> verdict=restored, and
#     the primary is ACTUALLY checked out onto the default branch
#     afterward (not just claimed).
#   - primary off-default AND working tree dirty -> verdict=dirty-skip,
#     and the primary is left exactly where it was (no write at all) —
#     the one hard precondition from `dont.md` this guard must preserve.
#   - gh failing to resolve a default branch -> verdict=error (the
#     "could not check" case must be surfaced distinctly, never silently
#     folded into "clean" the way the old inline block's `2>/dev/null ||
#     true` posture did).
#   - the script's own stdout is pure key=value lines even on the
#     checkout+pull path — no git progress text ("Already up to date.")
#     leaking into the parseable contract.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/primary-leak-guard.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts_dir="$(cd "$here/.." && pwd)"

guard="${scripts_dir}/primary-leak-guard.sh"

if [[ ! -f "$guard" ]]; then
  echo "FAIL: helper not found at $guard" >&2
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

TMPDIR_ROOT="$(mktemp -d -t primary-leak-guard.XXXXXX)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# The repo lives one level below TMPDIR_ROOT so fixture-only files (fake gh
# executables, the bare remote) never land inside the working tree and
# pollute `git status --porcelain` with spurious untracked entries.
repo="$TMPDIR_ROOT/repo"
bare="$TMPDIR_ROOT/bare.git"

reset_repo() {
  rm -rf "$repo" "$bare"
  mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
  ) >/dev/null 2>&1
  git init -q --bare "$bare" >/dev/null 2>&1
  (
    cd "$repo" || exit 1
    git remote add origin "$bare"
    git push -q origin main
    git branch -q --set-upstream-to=origin/main main
  ) >/dev/null 2>&1
}

# fake_gh <default-branch> — writes an executable at $TMPDIR_ROOT/fake-gh
# that answers `repo view --json defaultBranchRef -q .defaultBranchRef.name`
# with the given branch name, and fails on any other invocation.
fake_gh() {
  local branch="$1"
  cat > "$TMPDIR_ROOT/fake-gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "repo" ] && [ "\$2" = "view" ]; then
  echo "$branch"
  exit 0
fi
exit 1
EOF
  chmod +x "$TMPDIR_ROOT/fake-gh"
}

echo "primary-leak-guard.sh test suite (issue #1323)"
echo "================================================"

# ==========================================================================
echo
echo "usage / arg validation"
# ==========================================================================
out="$(bash "$guard" run 2>&1)"; rc=$?
assert_contains "$out" "required" "run without --repo errors"
assert_exit "$rc" "64" "missing required args exits 64"

out="$(bash "$guard" bogus 2>&1)"; rc=$?
assert_contains "$out" "unknown subcommand" "unknown subcommand errors"
assert_exit "$rc" "64" "unknown subcommand exits 64"

# ==========================================================================
echo
echo "primary already on default branch -> clean"
# ==========================================================================
reset_repo
fake_gh "main"
(
  cd "$repo" || exit 1
  out="$(GH="$TMPDIR_ROOT/fake-gh" bash "$guard" run --repo o/r 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/clean.out"
)
out="$(cat "$TMPDIR_ROOT/clean.out")"
assert_contains "$out" "verdict=clean" "on-default -> verdict=clean"
assert_contains "$out" "primary_branch=main" "reports the observed primary branch"
assert_contains "$out" "default_branch=main" "reports the resolved default branch"

# ==========================================================================
echo
echo "primary off-default, CLEAN tree -> restored"
# ==========================================================================
reset_repo
fake_gh "main"
(
  cd "$repo" || exit 1
  git checkout -q -b do-work/issue-1
  out="$(GH="$TMPDIR_ROOT/fake-gh" bash "$guard" run --repo o/r 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/restored.out"
)
out="$(cat "$TMPDIR_ROOT/restored.out")"
assert_contains "$out" "verdict=restored" "off-default + clean -> verdict=restored"
assert_contains "$out" "primary_branch=do-work/issue-1" "reports the pre-restore branch as primary_branch"
assert_not_contains "$out" "Already up to date" "no git progress text leaks into stdout"
assert_not_contains "$out" "Switched to branch" "no git progress text leaks into stdout (checkout)"
current_branch="$(git -C "$repo" branch --show-current)"
if [[ "$current_branch" == "main" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "primary is ACTUALLY on main after restore, not just claimed"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" "primary is ACTUALLY on main after restore, not just claimed" "$current_branch"; fail=$((fail+1))
fi

# ==========================================================================
echo
echo "primary off-default, DIRTY tree -> dirty-skip, never writes"
# ==========================================================================
reset_repo
fake_gh "main"
(
  cd "$repo" || exit 1
  git checkout -q -b do-work/issue-2
  echo "uncommitted edit" > tracked-edit.txt
  git add tracked-edit.txt
  out="$(GH="$TMPDIR_ROOT/fake-gh" bash "$guard" run --repo o/r 2>&1)"
  echo "$out" > "$TMPDIR_ROOT/dirty.out"
)
out="$(cat "$TMPDIR_ROOT/dirty.out")"
assert_contains "$out" "verdict=dirty-skip" "off-default + dirty -> verdict=dirty-skip"
assert_contains "$out" "NOT auto-restoring" "dirty-skip reason names the non-restore precondition"
current_branch="$(git -C "$repo" branch --show-current)"
if [[ "$current_branch" == "do-work/issue-2" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "primary is left EXACTLY where it was — no checkout attempted on dirty tree"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" "primary is left EXACTLY where it was — no checkout attempted on dirty tree" "$current_branch"; fail=$((fail+1))
fi
staged_edit="$(git -C "$repo" status --porcelain)"
if [[ -n "$staged_edit" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "the uncommitted edit is still there, untouched"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "the uncommitted edit is still there, untouched"; fail=$((fail+1))
fi

# ==========================================================================
echo
echo "gh cannot resolve a default branch -> error (never silently 'clean')"
# ==========================================================================
reset_repo
(
  cd "$repo" || exit 1
  # A stubbed `gh` that always fails, e.g. GH="$(command -v true)" would
  # never emit anything on stdout for `repo view`, so DEFAULT_BRANCH comes
  # back empty — this is the #1323 swallow this script closes: the old
  # inline block's empty-string comparison would have miscompared this as
  # "primary is on some other branch than ''" (a leak) rather than
  # surfacing "could not check" at all.
  out="$(GH="$(command -v true)" bash "$guard" run --repo o/r 2>&1)"; rc=$?
  echo "$out" > "$TMPDIR_ROOT/error.out"
  echo "$rc" > "$TMPDIR_ROOT/error.rc"
)
out="$(cat "$TMPDIR_ROOT/error.out")"
rc="$(cat "$TMPDIR_ROOT/error.rc")"
assert_contains "$out" "verdict=error" "gh failure -> verdict=error, not silently clean"
assert_contains "$out" "could not resolve default branch" "error reason names the actual cause"
assert_exit "$rc" "2" "error verdict exits non-zero (2) so a caller can distinguish it from a real check"
current_branch="$(git -C "$repo" branch --show-current)"
if [[ "$current_branch" == "main" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "no spurious write attempted when the default branch could not be resolved"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s (got: %s)\n' "$RED" "$RESET" "no spurious write attempted when the default branch could not be resolved" "$current_branch"; fail=$((fail+1))
fi

# ==========================================================================
echo
echo "summary"
echo "======="
echo "pass=$pass fail=$fail"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0

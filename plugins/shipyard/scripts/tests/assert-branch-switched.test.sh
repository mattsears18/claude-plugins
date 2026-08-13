#!/usr/bin/env bash
# Test: scripts/assert-branch-switched.sh — the "has this worker actually
# switched off the harness placeholder branch onto the branch its dispatch
# requires" predicate (issue #1258).
#
# Mirrors assert-worktree-cwd.test.sh's fixture shape and stdout/stderr
# contract-testing style. Pure bash + git, no network, no external deps.
# Run with:
#
#   bash plugins/shipyard/scripts/tests/assert-branch-switched.test.sh

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0
fail=0

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../assert-branch-switched.sh"

echo "assert-branch-switched.sh tests (issue #1258)"
echo

if [[ ! -x "$script" ]]; then
  bad "script exists and is executable ($script)"
  echo
  printf '%sFAIL%s  1 test(s) failed (0 passed)\n' "$RED" "$RESET" >&2
  exit 1
fi
ok "script exists and is executable"

# Build a throwaway repo + a linked worktree that starts on a
# harness-placeholder-shaped branch name, mirroring the real shape
# worktree-reap.sh documents (`worktree-agent-<id>`). Pin the default branch
# (worker-preamble § "Pin the default branch in git-using test fixtures",
# issue #475) so the fixture is deterministic regardless of the host's
# init.defaultBranch.
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

primary="$tmproot/primary"
git init -q -b main "$primary"
(
  cd "$primary" || exit 1
  git config user.email test@example.com
  git config user.name 'Test User'
  echo "seed" > seed.txt
  git add seed.txt
  git commit -q -m "seed"
)

worktree="$primary/.claude/worktrees/agent-deadbeef"
(
  cd "$primary" || exit 1
  git worktree add -q -b worktree-agent-deadbeef "$worktree" >/dev/null 2>&1
)

if [[ ! -d "$worktree" ]]; then
  bad "could not create linked worktree fixture (git worktree add failed)"
else
  # --- (1) still on the placeholder branch, expecting the real one -> mismatch
  out="$(bash "$script" "$worktree" "do-work/issue-1258" 2>/tmp/assert-branch-switched-test-stderr.$$)"
  code=$?
  if [[ "$out" == "mismatch" && "$code" -eq 1 ]]; then
    ok "still on placeholder branch, expected do-work/issue-1258: stdout='mismatch', exit=1"
  else
    bad "placeholder-vs-expected: got stdout='$out' exit=$code (expected 'mismatch'/1)"
  fi
  if grep -qF "harness-provided placeholder branch" "/tmp/assert-branch-switched-test-stderr.$$" 2>/dev/null; then
    ok "mismatch diagnostic names the harness-placeholder pattern by name"
  else
    bad "mismatch diagnostic did not call out the placeholder pattern"
  fi
  rm -f "/tmp/assert-branch-switched-test-stderr.$$"

  # --- (1a) a COMMIT landed on the placeholder branch (issue #1334's repro:
  # a worker drifted straight into implementation and committed before ever
  # running the checkout) -> still mismatch, not silently swallowed by the
  # presence of a commit. The predicate only looks at the current branch
  # name, never at whether history has diverged, so this must report
  # identically to (1) above.
  (
    cd "$worktree" || exit 1
    git config user.email test@example.com
    git config user.name 'Test User'
    echo "drifted edit" > drifted.txt
    git add drifted.txt
    git commit -q -m "wip: drifted onto placeholder branch"
  ) >/dev/null 2>&1
  out="$(bash "$script" "$worktree" "do-work/issue-1258" 2>/dev/null)"
  code=$?
  if [[ "$out" == "mismatch" && "$code" -eq 1 ]]; then
    ok "commit landed on placeholder branch (#1334 repro): stdout='mismatch', exit=1"
  else
    bad "commit-on-placeholder: got stdout='$out' exit=$code (expected 'mismatch'/1)"
  fi

  # --- (2) switch onto the branch this dispatch actually requires -> match ---
  (cd "$worktree" && git checkout -q -B do-work/issue-1258 >/dev/null 2>&1)
  out="$(bash "$script" "$worktree" "do-work/issue-1258" 2>/dev/null)"
  code=$?
  if [[ "$out" == "match" && "$code" -eq 0 ]]; then
    ok "on the expected branch: stdout='match', exit=0"
  else
    bad "on expected branch: got stdout='$out' exit=$code (expected 'match'/0)"
  fi

  # --- (3) on a named (non-placeholder) branch, but --detached expected ------
  out="$(bash "$script" "$worktree" "--detached" 2>/dev/null)"
  code=$?
  if [[ "$out" == "mismatch" && "$code" -eq 1 ]]; then
    ok "named branch checked out but --detached expected: stdout='mismatch', exit=1"
  else
    bad "named-branch-vs-detached: got stdout='$out' exit=$code (expected 'mismatch'/1)"
  fi

  # --- (4) genuinely detached HEAD, --detached expected -> match -------------
  (cd "$worktree" && git checkout -q --detach HEAD >/dev/null 2>&1)
  out="$(bash "$script" "$worktree" "--detached" 2>/dev/null)"
  code=$?
  if [[ "$out" == "match" && "$code" -eq 0 ]]; then
    ok "detached HEAD, --detached expected: stdout='match', exit=0"
  else
    bad "detached-vs-detached: got stdout='$out' exit=$code (expected 'match'/0)"
  fi

  # --- (5) subdirectory of the worktree — path-independent -------------------
  (cd "$worktree" && git checkout -q -B do-work/issue-1258 >/dev/null 2>&1)
  subdir="$worktree/plugins/shipyard"
  mkdir -p "$subdir"
  out="$(bash "$script" "$subdir" "do-work/issue-1258" 2>/dev/null)"
  code=$?
  if [[ "$out" == "match" && "$code" -eq 0 ]]; then
    ok "subdir of the worktree: stdout='match', exit=0 (path-independent detection)"
  else
    bad "subdir of worktree: got stdout='$out' exit=$code (expected 'match'/0)"
  fi
fi

# --- (6) DIR outside any git repo -> `error` on stdout, exit 2 -------------
non_git_dir="$tmproot/not-a-repo"
mkdir -p "$non_git_dir"
out="$(bash "$script" "$non_git_dir" "do-work/issue-1258" 2>/dev/null)"
code=$?
if [[ "$out" == "error" && "$code" -eq 2 ]]; then
  ok "non-git directory: stdout='error', exit=2"
else
  bad "non-git directory: got stdout='$out' exit=$code (expected 'error'/2)"
fi

# --- (7) missing arguments prints usage on stderr and exits 2 --------------
out_stderr="$(bash "$script" 2>&1 1>/dev/null)"
code=$?
if [[ "$code" -eq 2 ]] && grep -qF "usage: assert-branch-switched.sh" <<<"$out_stderr"; then
  ok "no arguments: prints usage on stderr and exits 2"
else
  bad "no arguments: got exit=$code stderr='$out_stderr' (expected exit 2 + usage text)"
fi

out_stderr="$(bash "$script" "$tmproot" 2>&1 1>/dev/null)"
code=$?
if [[ "$code" -eq 2 ]] && grep -qF "usage: assert-branch-switched.sh" <<<"$out_stderr"; then
  ok "missing EXPECTED_BRANCH: prints usage on stderr and exits 2"
else
  bad "missing EXPECTED_BRANCH: got exit=$code stderr='$out_stderr' (expected exit 2 + usage text)"
fi

# --- (8) -h / --help prints usage on stderr and exits 2 --------------------
out_stderr="$(bash "$script" --help 2>&1 1>/dev/null)"
code=$?
if [[ "$code" -eq 2 ]] && grep -qF "usage: assert-branch-switched.sh" <<<"$out_stderr"; then
  ok "--help prints usage on stderr and exits 2"
else
  bad "--help: got exit=$code stderr='$out_stderr' (expected exit 2 + usage text)"
fi

# --- (9) shellcheck-clean (belt-and-suspenders; shellcheck.test.sh also
# discovers this file, but a direct check here fails fast in this suite too).
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$script" >/tmp/assert-branch-switched-shellcheck.$$ 2>&1; then
    ok "shellcheck clean"
  else
    bad "shellcheck reported issues: $(cat "/tmp/assert-branch-switched-shellcheck.$$")"
  fi
  rm -f "/tmp/assert-branch-switched-shellcheck.$$"
else
  echo "  (shellcheck not installed locally — skipping; CI's shellcheck.yml still gates this)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

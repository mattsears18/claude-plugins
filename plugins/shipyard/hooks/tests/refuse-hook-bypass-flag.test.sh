#!/usr/bin/env bash
# Test suite for hooks/refuse-hook-bypass-flag.sh.
#
# Run with:
#   bash plugins/shipyard/hooks/tests/refuse-hook-bypass-flag.test.sh
#
# Each test crafts a PreToolUse JSON payload for a Bash tool call, pipes it to
# the hook, and asserts on stderr + exit code. Exit 2 == blocked, exit 0 ==
# allowed (transparent).
#
# The hook blocks the flags that bypass git's commit/push hooks —
# `--no-verify` (and its `-n` short form on `git commit`), `--no-gpg-sign`,
# `--no-commit-hooks` — on `git commit` and `git push`, and nothing else. See
# plugins/shipyard/hooks/refuse-hook-bypass-flag.sh for the decision rules and
# issue #1511 for why the prohibition needed a mechanism that demonstrably
# fires: the `permissions.deny` block in the plugin manifest that two specs
# described as harness-level enforcement sits at a tier the documented rule
# sources do not include.
#
# The load-bearing assertion in this file is the "legitimate forms stay
# reachable" section: `git push -n` is `--dry-run`, not `--no-verify`, and a
# guard that also blocked ordinary `git commit -m "…"` / `git push -u …`
# would break the worker's normal path — far worse than the status quo.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/../refuse-hook-bypass-flag.sh"

if [[ ! -f "$hook" ]]; then
  echo "FAIL: hook not found at $hook" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

# Helper — invoke hook with payload on stdin.
# Returns: "<exit_code>::<stderr>"
run_hook() {
  local payload="$1"
  local stderr exit_code
  stderr=$(printf '%s' "$payload" | bash "$hook" 2>&1 >/dev/null)
  exit_code=$?
  printf '%s::%s' "$exit_code" "$stderr"
}

assert_exit() {
  local result="$1"
  local want="$2"
  local label="$3"
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
  local result="$1"
  local needle="$2"
  local label="$3"
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
  local tool="$1" cmd="$2"
  TOOL="$tool" CMD="$cmd" python3 -c '
import json, os
print(json.dumps({
    "tool_name": os.environ["TOOL"],
    "cwd": "/tmp",
    "tool_input": {"command": os.environ["CMD"]},
}))'
}

# -----------------------------------------------------------------------------
echo "== Non-Bash tools pass through transparently"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Edit 'git commit --no-verify')")
assert_exit "$out" "0" "Edit tool with a bypass-shaped string → not blocked"

out=$(run_hook "$(mkpayload Read 'git push --no-verify')")
assert_exit "$out" "0" "Read tool → not blocked"

# -----------------------------------------------------------------------------
echo "== The three named flags are blocked on git commit"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git commit --no-verify')")
assert_blocked_with "$out" "no-verify" "'git commit --no-verify' → blocked"

out=$(run_hook "$(mkpayload Bash 'git commit -m "fix: thing" --no-verify')")
assert_blocked_with "$out" "no-verify" "'--no-verify' after a -m message → blocked"

out=$(run_hook "$(mkpayload Bash 'git commit --amend --no-verify')")
assert_blocked_with "$out" "no-verify" "'git commit --amend --no-verify' → blocked"

out=$(run_hook "$(mkpayload Bash 'git commit --no-gpg-sign -m "x"')")
assert_blocked_with "$out" "no-gpg-sign" "'git commit --no-gpg-sign' → blocked"

out=$(run_hook "$(mkpayload Bash 'git commit --no-commit-hooks -m "x"')")
assert_blocked_with "$out" "no-commit-hooks" "'git commit --no-commit-hooks' → blocked"

# -----------------------------------------------------------------------------
echo "== The named flags are blocked on git push"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git push --no-verify')")
assert_blocked_with "$out" "no-verify" "'git push --no-verify' → blocked"

out=$(run_hook "$(mkpayload Bash 'git push -u origin HEAD:refs/heads/do-work/issue-1511 --no-verify')")
assert_blocked_with "$out" "no-verify" "'--no-verify' on a full push invocation → blocked"

# -----------------------------------------------------------------------------
echo "== -n is --no-verify on commit, but --dry-run on push"
# -----------------------------------------------------------------------------
# The asymmetry is the whole point: a deny pattern anchored on the literal
# string `--no-verify` catches neither `git commit -n` nor `git commit -nm`,
# and a naive short-flag scan would wrongly refuse the read-only
# `git push --dry-run` rehearsal.

out=$(run_hook "$(mkpayload Bash 'git commit -n -m "x"')")
assert_blocked_with "$out" "short-n-no-verify" "'git commit -n' (short --no-verify) → blocked"

out=$(run_hook "$(mkpayload Bash 'git commit -nm "x"')")
assert_blocked_with "$out" "short-n-no-verify" "'git commit -nm' (clustered) → blocked"

out=$(run_hook "$(mkpayload Bash 'git commit -an -m "x"')")
assert_blocked_with "$out" "short-n-no-verify" "'git commit -an' (n after a non-value flag) → blocked"

out=$(run_hook "$(mkpayload Bash 'git push -n')")
assert_exit "$out" "0" "'git push -n' (--dry-run) → ALLOWED"

out=$(run_hook "$(mkpayload Bash 'git push --dry-run origin main')")
assert_exit "$out" "0" "'git push --dry-run' → allowed"

out=$(run_hook "$(mkpayload Bash 'git commit -mn')")
assert_exit "$out" "0" "'git commit -mn' (n is the MESSAGE, not a flag) → allowed"

out=$(run_hook "$(mkpayload Bash 'git commit -Sn -m "x"')")
assert_exit "$out" "0" "'git commit -Sn' (n is a gpg keyid) → allowed"

# -----------------------------------------------------------------------------
echo "== THE ESCAPE HATCH: legitimate commit/push forms stay reachable"
# -----------------------------------------------------------------------------
# These are the exact shapes issue-work.md § 5 tells every worker to run. A
# guard that caught any of them would break the normal path on every dispatch.

out=$(run_hook "$(mkpayload Bash 'git commit -m "fix(hooks): refuse hook-bypass flags (refs #1511)"')")
assert_exit "$out" "0" "the standard 'git commit -m \"…\"' → ALLOWED"

out=$(run_hook "$(mkpayload Bash 'git commit -am "wip: mid-rebase"')")
assert_exit "$out" "0" "'git commit -am \"…\"' → allowed"

out=$(run_hook "$(mkpayload Bash 'git commit --amend --no-edit')")
assert_exit "$out" "0" "'git commit --amend --no-edit' → allowed"

out=$(run_hook "$(mkpayload Bash 'git push -u origin HEAD:refs/heads/do-work/issue-1511')")
assert_exit "$out" "0" "the standard worker push → ALLOWED"

out=$(run_hook "$(mkpayload Bash 'git push --force-with-lease origin do-work/issue-1511')")
assert_exit "$out" "0" "'git push --force-with-lease' → allowed"

out=$(run_hook "$(mkpayload Bash 'git commit --gpg-sign=ABC123 -m "x"')")
assert_exit "$out" "0" "'--gpg-sign' (the POSITIVE flag) → allowed"

out=$(run_hook "$(mkpayload Bash 'git pull --no-verify-signatures')")
assert_exit "$out" "0" "'--no-verify-signatures' (a different flag, not a substring match) → allowed"

out=$(run_hook "$(mkpayload Bash 'git commit --verify -m "x"')")
assert_exit "$out" "0" "'--verify' (the POSITIVE flag) → allowed"

# -----------------------------------------------------------------------------
echo "== A flag name passed as a VALUE is not an invocation of that flag"
# -----------------------------------------------------------------------------
# Editing this repo's own docs means writing the literal flag names into
# commit messages constantly; a value consumed by -m / -F / --author must
# never read as the flag itself.

out=$(run_hook "$(mkpayload Bash 'git commit -m "--no-verify"')")
assert_exit "$out" "0" "'--no-verify' as the -m VALUE → allowed"

out=$(run_hook "$(mkpayload Bash 'git commit -m "docs: forbid --no-verify in workers"')")
assert_exit "$out" "0" "flag name inside a longer commit message → allowed"

out=$(run_hook "$(mkpayload Bash 'git commit --message "--no-gpg-sign"')")
assert_exit "$out" "0" "'--no-gpg-sign' as the --message VALUE → allowed"

out=$(run_hook "$(mkpayload Bash 'git commit -- --no-verify')")
assert_exit "$out" "0" "after a bare '--' the token is a pathspec → allowed"

# -----------------------------------------------------------------------------
echo "== Only git commit and git push are in scope"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git merge --no-verify origin/main')")
assert_exit "$out" "0" "'git merge --no-verify' (out of the named scope) → allowed"

out=$(run_hook "$(mkpayload Bash 'git status --porcelain')")
assert_exit "$out" "0" "'git status' → allowed"

out=$(run_hook "$(mkpayload Bash 'git diff -- plugins/shipyard/hooks/hooks.json')")
assert_exit "$out" "0" "'git diff' → allowed"

out=$(run_hook "$(mkpayload Bash 'git rev-parse --show-toplevel')")
assert_exit "$out" "0" "'git rev-parse' → allowed"

# -----------------------------------------------------------------------------
echo "== A command-rewriting PreToolUse hook cannot launder the bypass"
# -----------------------------------------------------------------------------
# A token-proxying hook can rewrite `git commit …` to `<proxy> git commit …`
# before the permission layer ever sees it, which is precisely what defeats a
# deny pattern anchored at `git`. This hook matches the `git` token wherever
# it sits in the clause, so a wrapper prefix changes nothing (#1506, #1511).

out=$(run_hook "$(mkpayload Bash 'rtk git commit --no-verify')")
assert_blocked_with "$out" "no-verify" "proxy-prefixed 'rtk git commit --no-verify' → blocked"

out=$(run_hook "$(mkpayload Bash 'rtk git push --no-verify')")
assert_blocked_with "$out" "no-verify" "proxy-prefixed 'rtk git push --no-verify' → blocked"

out=$(run_hook "$(mkpayload Bash 'sudo git commit -n -m "x"')")
assert_blocked_with "$out" "short-n-no-verify" "'sudo git commit -n' → blocked"

out=$(run_hook "$(mkpayload Bash 'env GIT_AUTHOR_NAME=x git commit --no-verify')")
assert_blocked_with "$out" "no-verify" "'env … git commit --no-verify' → blocked"

out=$(run_hook "$(mkpayload Bash 'rtk git commit -m "ordinary"')")
assert_exit "$out" "0" "proxy-prefixed ordinary commit → still allowed"

# -----------------------------------------------------------------------------
echo "== git global options between 'git' and the subcommand are skipped"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git -C /some/worktree commit --no-verify -m "x"')")
assert_blocked_with "$out" "no-verify" "'git -C <path> commit --no-verify' → blocked"

out=$(run_hook "$(mkpayload Bash 'git --no-pager push --no-verify')")
assert_blocked_with "$out" "no-verify" "'git --no-pager push --no-verify' → blocked"

out=$(run_hook "$(mkpayload Bash 'git -C /some/worktree commit -m "x"')")
assert_exit "$out" "0" "'git -C <path> commit -m' → allowed"

# -----------------------------------------------------------------------------
echo "== Compound commands are inspected clause by clause"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git add -p && git commit --no-verify -m "x"')")
assert_blocked_with "$out" "no-verify" "bypass in the SECOND clause of a && chain → blocked"

out=$(run_hook "$(mkpayload Bash 'git commit --no-verify -m "x"; git push')")
assert_blocked_with "$out" "no-verify" "bypass in the FIRST clause before a ';' → blocked"

# shellcheck disable=SC2016
# The single quotes are deliberate: the payload must carry the literal text
# `echo $(git push --no-verify)` so the hook sees a command substitution.
out=$(run_hook "$(mkpayload Bash 'echo $(git push --no-verify)')")
assert_blocked_with "$out" "no-verify" "bypass inside a command substitution → blocked"

out=$(run_hook "$(mkpayload Bash 'git add plugins/ && git commit -m "x" && git push -u origin HEAD')")
assert_exit "$out" "0" "the ordinary three-clause worker chain → allowed"

# -----------------------------------------------------------------------------
echo "== Quoted mentions are not invocations"
# -----------------------------------------------------------------------------
# This repo documents the prohibition in a dozen files; grepping for it must
# never be mistaken for reaching for it.

out=$(run_hook "$(mkpayload Bash 'grep -rn "git commit --no-verify" plugins/shipyard/skills/')")
assert_exit "$out" "0" "grep for the literal string → allowed"

out=$(run_hook "$(mkpayload Bash 'echo "never pass git commit --no-verify in a worker"')")
assert_exit "$out" "0" "echo of a quoted mention → allowed"

out=$(run_hook "$(mkpayload Bash 'bash plugins/shipyard/hooks/tests/refuse-hook-bypass-flag.test.sh')")
assert_exit "$out" "0" "running this very suite → allowed"

# -----------------------------------------------------------------------------
echo "== Commands with no git commit/push invocation at all"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'ls -la')")
assert_exit "$out" "0" "unrelated command → allowed"

out=$(run_hook "$(mkpayload Bash 'npm run test:unit')")
assert_exit "$out" "0" "test runner → allowed"

out=$(run_hook "$(mkpayload Bash 'gh pr view 1514 --json state')")
assert_exit "$out" "0" "gh call → allowed"

# -----------------------------------------------------------------------------
echo "== A '#' in the command does not truncate the scan"
# -----------------------------------------------------------------------------
# The tokenizer must not treat '#' as a comment introducer — a shell command
# is not a config file, and swallowing the rest of the line would hide a
# trailing bypass.

out=$(run_hook "$(mkpayload Bash 'gh issue view 1511 && git commit --no-verify -m "x"')")
assert_blocked_with "$out" "no-verify" "issue-number-bearing command followed by a bypass → blocked"

out=$(run_hook "$(mkpayload Bash 'echo fix#1511 && git push --no-verify')")
assert_blocked_with "$out" "no-verify" "'#' mid-token does not hide a following bypass"

# -----------------------------------------------------------------------------
echo "== Malformed / degenerate input falls through to allowed"
# -----------------------------------------------------------------------------
# A buggy hook that blocked every Bash call would be far worse than one that
# occasionally misses a bypass — same defensive posture as the sibling hooks.

out=$(run_hook 'not json at all')
assert_exit "$out" "0" "malformed JSON → allowed"

out=$(run_hook '{"tool_name":"Bash"}')
assert_exit "$out" "0" "missing tool_input → allowed"

out=$(run_hook '{"tool_name":"Bash","tool_input":{"command":""}}')
assert_exit "$out" "0" "empty command → allowed"

out=$(run_hook "$(mkpayload Bash "git commit --no-verify 'unbalanced")")
assert_exit "$out" "0" "untokenizable command (unbalanced quote) → allowed, not guessed at"

out=$(run_hook "")
assert_exit "$out" "0" "empty stdin → allowed"

# -----------------------------------------------------------------------------
echo "== The block message names the substitute, not just the refusal"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git commit --no-verify')")
assert_blocked_with "$out" "blocked: pre-commit hook" \
  "block message names the 'blocked:' return as the sanctioned alternative"

out=$(run_hook "$(mkpayload Bash 'git commit --no-verify')")
assert_blocked_with "$out" "no bypass flag" \
  "block message states there is no bypass flag"

out=$(run_hook "$(mkpayload Bash 'git commit --no-verify')")
assert_blocked_with "$out" "#1511" \
  "block message cites the issue that made the prohibition mechanical"

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

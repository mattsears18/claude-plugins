#!/usr/bin/env bash
# Test suite for hooks/refuse-unsafe-git-stash.sh.
#
# Run with:
#   bash plugins/shipyard/hooks/tests/refuse-unsafe-git-stash.test.sh
#
# Each test crafts a PreToolUse JSON payload for a Bash tool call, pipes it to
# the hook, and asserts on stderr + exit code. Exit 2 == blocked, exit 0 ==
# allowed (transparent).
#
# The hook blocks the `git stash` forms that mutate — or read by POSITION
# from — the repo-global `refs/stash` stack, while leaving the sanctioned
# tagged procedure from skills/worker-preamble/git-stash-prohibition.md fully
# reachable. See plugins/shipyard/hooks/refuse-unsafe-git-stash.sh for the
# decision rules and issue #1506 for the third-recurrence repro that motivated
# making the prohibition mechanical instead of documentary.
#
# The load-bearing assertion in this file is the "sanctioned procedure is
# still reachable" section: a guard that also blocked
# `git stash push -u -m "<tag>"` would break the documented escape hatch,
# which is worse than the status quo.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/../refuse-unsafe-git-stash.sh"

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

out=$(run_hook "$(mkpayload Edit 'git stash pop')")
assert_exit "$out" "0" "Edit tool with a stash-shaped string → not blocked"

out=$(run_hook "$(mkpayload Read 'git stash')")
assert_exit "$out" "0" "Read tool → not blocked"

# -----------------------------------------------------------------------------
echo "== The bare reflex is blocked (the #1224 / #1506 repro)"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git stash')")
assert_blocked_with "$out" "bare-stash" "bare 'git stash' → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash -u')")
assert_blocked_with "$out" "untagged-implicit-push" "'git stash -u' (implicit push, no -m) → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash --include-untracked')")
assert_blocked_with "$out" "untagged-implicit-push" "'git stash --include-untracked' → blocked"

# -----------------------------------------------------------------------------
echo "== Untagged explicit push/save is blocked"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git stash push')")
assert_blocked_with "$out" "untagged-push" "'git stash push' with no -m → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash push -u')")
assert_blocked_with "$out" "untagged-push" "'git stash push -u' with no -m → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash push --patch')")
assert_blocked_with "$out" "untagged-push" "'git stash push --patch' with no -m → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash save')")
assert_blocked_with "$out" "untagged-push" "'git stash save' (deprecated spelling) with no -m → blocked"

# -----------------------------------------------------------------------------
echo "== pop and clear are blocked unconditionally"
# -----------------------------------------------------------------------------
# A bare pop takes stash@{0} regardless of who pushed it; clear destroys every
# concurrent worker's entries, not just this worker's.

out=$(run_hook "$(mkpayload Bash 'git stash pop')")
assert_blocked_with "$out" "pop" "'git stash pop' → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash pop stash@{0}')")
assert_blocked_with "$out" "pop" "'git stash pop stash@{0}' → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash pop --index')")
assert_blocked_with "$out" "pop" "'git stash pop --index' → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash clear')")
assert_blocked_with "$out" "clear" "'git stash clear' → blocked"

# -----------------------------------------------------------------------------
echo "== apply/drop BY POSITION is blocked; by identity is allowed"
# -----------------------------------------------------------------------------
# git-stash-prohibition.md's sanctioned procedure matches the entry by SHA/tag
# and never by stash@{n}, because positions shift as peers push and drop.

out=$(run_hook "$(mkpayload Bash 'git stash apply')")
assert_blocked_with "$out" "positional-apply" "bare 'git stash apply' (implicit stash@{0}) → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash apply stash@{0}')")
assert_blocked_with "$out" "positional-apply" "'git stash apply stash@{0}' → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash drop')")
assert_blocked_with "$out" "positional-drop" "bare 'git stash drop' → blocked"

out=$(run_hook "$(mkpayload Bash 'git stash drop stash@{1}')")
assert_blocked_with "$out" "positional-drop" "'git stash drop stash@{1}' → blocked"

# -----------------------------------------------------------------------------
echo "== THE ESCAPE HATCH: the sanctioned tagged procedure stays reachable"
# -----------------------------------------------------------------------------
# This is the section that would have failed under the `permissions.deny`
# pattern shapes issue #1506 originally proposed — the Bash rule matcher has
# no negation operator, so any pattern broad enough to catch `git stash push`
# also catches `git stash push -u -m "<tag>"`. Breaking the documented escape
# hatch is worse than the status quo, so each line below MUST stay allowed.

out=$(run_hook "$(mkpayload Bash 'git stash push -u -m "issue-1506: rebase mid-run"')")
assert_exit "$out" "0" "'git stash push -u -m \"<tag>\"' → ALLOWED (the sanctioned form)"

out=$(run_hook "$(mkpayload Bash 'git stash push -m "tag"')")
assert_exit "$out" "0" "'git stash push -m \"tag\"' → allowed"

out=$(run_hook "$(mkpayload Bash 'git stash push -um "tag"')")
assert_exit "$out" "0" "'git stash push -um \"tag\"' (clustered short flags) → allowed"

out=$(run_hook "$(mkpayload Bash 'git stash push --message "tag"')")
assert_exit "$out" "0" "'git stash push --message \"tag\"' → allowed"

out=$(run_hook "$(mkpayload Bash 'git stash push --message=tag')")
assert_exit "$out" "0" "'git stash push --message=tag' → allowed"

out=$(run_hook "$(mkpayload Bash 'git stash -u -m "tag"')")
assert_exit "$out" "0" "'git stash -u -m \"tag\"' (implicit push, tagged) → allowed"

out=$(run_hook "$(mkpayload Bash "git stash list --format='%H %gs'")")
assert_exit "$out" "0" "'git stash list' (read-only) → allowed"

out=$(run_hook "$(mkpayload Bash 'git stash show stash@{0}')")
assert_exit "$out" "0" "'git stash show' (read-only) → allowed"

out=$(run_hook "$(mkpayload Bash 'git stash apply 6f1c2ab')")
assert_exit "$out" "0" "'git stash apply <sha>' (by identity) → allowed"

out=$(run_hook "$(mkpayload Bash 'git stash drop 6f1c2ab')")
assert_exit "$out" "0" "'git stash drop <sha>' (by identity) → allowed"

# -----------------------------------------------------------------------------
echo "== The documented substitutes are never blocked"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git commit -m "wip: mid-rebase, restoring after fetch"')")
assert_exit "$out" "0" "the wip-commit substitute → allowed"

out=$(run_hook "$(mkpayload Bash 'git reset --soft HEAD~1')")
assert_exit "$out" "0" "'git reset --soft HEAD~1' (undo the wip commit) → allowed"

out=$(run_hook "$(mkpayload Bash 'git diff -- plugins/shipyard/hooks/hooks.json')")
assert_exit "$out" "0" "'git diff' → allowed"

out=$(run_hook "$(mkpayload Bash 'git status --porcelain')")
assert_exit "$out" "0" "'git status' → allowed"

# -----------------------------------------------------------------------------
echo "== A command-rewriting PreToolUse hook cannot launder the reflex"
# -----------------------------------------------------------------------------
# A token-proxying hook can rewrite `git stash …` to `<proxy> git stash …`
# before the permission layer ever sees it, which is precisely what defeats a
# deny pattern anchored at `git`. This hook matches the `git` token wherever
# it sits in the clause, so a wrapper prefix changes nothing (#1506).

out=$(run_hook "$(mkpayload Bash 'rtk git stash pop')")
assert_blocked_with "$out" "pop" "proxy-prefixed 'rtk git stash pop' → blocked"

out=$(run_hook "$(mkpayload Bash 'rtk git stash')")
assert_blocked_with "$out" "bare-stash" "proxy-prefixed 'rtk git stash' → blocked"

out=$(run_hook "$(mkpayload Bash 'sudo git stash pop')")
assert_blocked_with "$out" "pop" "'sudo git stash pop' → blocked"

out=$(run_hook "$(mkpayload Bash 'env GIT_DIR=/x git stash')")
assert_blocked_with "$out" "bare-stash" "'env … git stash' → blocked"

out=$(run_hook "$(mkpayload Bash 'rtk git stash push -u -m "tag"')")
assert_exit "$out" "0" "proxy-prefixed sanctioned form → still allowed"

# -----------------------------------------------------------------------------
echo "== git global options between 'git' and 'stash' are skipped"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git -C /some/worktree stash pop')")
assert_blocked_with "$out" "pop" "'git -C <path> stash pop' (value-taking global option) → blocked"

out=$(run_hook "$(mkpayload Bash 'git --no-pager stash')")
assert_blocked_with "$out" "bare-stash" "'git --no-pager stash' → blocked"

out=$(run_hook "$(mkpayload Bash 'git -C /some/worktree stash push -u -m "tag"')")
assert_exit "$out" "0" "'git -C <path> stash push -u -m' → allowed"

# -----------------------------------------------------------------------------
echo "== Compound commands are inspected clause by clause"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git stash && git checkout main')")
assert_blocked_with "$out" "bare-stash" "stash in the FIRST clause of a && chain → blocked"

out=$(run_hook "$(mkpayload Bash 'git fetch origin && git stash pop')")
assert_blocked_with "$out" "pop" "stash in the SECOND clause of a && chain → blocked"

out=$(run_hook "$(mkpayload Bash 'git fetch origin; git stash')")
assert_blocked_with "$out" "bare-stash" "stash after a ';' separator → blocked"

# shellcheck disable=SC2016
# The single quotes are deliberate: the payload must carry the literal text
# `echo $(git stash pop)` so the hook sees a command substitution to parse.
out=$(run_hook "$(mkpayload Bash 'echo $(git stash pop)')")
assert_blocked_with "$out" "pop" "stash inside a command substitution → blocked"

out=$(run_hook "$(mkpayload Bash 'git fetch origin && git stash push -u -m "tag"')")
assert_exit "$out" "0" "sanctioned form in a && chain → allowed"

# -----------------------------------------------------------------------------
echo "== Quoted mentions are not invocations"
# -----------------------------------------------------------------------------
# Editing and grepping this repo's own docs means handling the literal string
# constantly; a quoted mention resolves to one opaque token whose basename is
# not `git`, so it is never mistaken for a call.

out=$(run_hook "$(mkpayload Bash 'grep -rn "git stash pop" plugins/shipyard/skills/')")
assert_exit "$out" "0" "grep for the literal string 'git stash pop' → allowed"

out=$(run_hook "$(mkpayload Bash 'echo "never run git stash pop in a worker"')")
assert_exit "$out" "0" "echo of a quoted mention → allowed"

# -----------------------------------------------------------------------------
echo "== Commands with no git-stash invocation at all"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'ls -la')")
assert_exit "$out" "0" "unrelated command → allowed"

out=$(run_hook "$(mkpayload Bash 'npm run test:unit')")
assert_exit "$out" "0" "test runner → allowed"

out=$(run_hook "$(mkpayload Bash 'gh pr view 1510 --json state')")
assert_exit "$out" "0" "gh call → allowed"

# -----------------------------------------------------------------------------
echo "== A '#' in the command does not truncate the scan"
# -----------------------------------------------------------------------------
# The tokenizer must not treat '#' as a comment introducer — a shell command
# is not a config file, and swallowing the rest of the line would hide a
# trailing stash.

out=$(run_hook "$(mkpayload Bash 'gh issue view 1506 && git stash pop')")
assert_blocked_with "$out" "pop" "issue-number-bearing command followed by a pop → blocked"

out=$(run_hook "$(mkpayload Bash 'echo fix#1506 && git stash')")
assert_blocked_with "$out" "bare-stash" "'#' mid-token does not hide a following stash"

# -----------------------------------------------------------------------------
echo "== Malformed / degenerate input falls through to allowed"
# -----------------------------------------------------------------------------
# A buggy hook that blocked every Bash call would be far worse than one that
# occasionally misses a stash — same defensive posture as the sibling hooks.

out=$(run_hook 'not json at all')
assert_exit "$out" "0" "malformed JSON → allowed"

out=$(run_hook '{"tool_name":"Bash"}')
assert_exit "$out" "0" "missing tool_input → allowed"

out=$(run_hook '{"tool_name":"Bash","tool_input":{"command":""}}')
assert_exit "$out" "0" "empty command → allowed"

out=$(run_hook "$(mkpayload Bash "git stash pop 'unbalanced")")
assert_exit "$out" "0" "untokenizable command (unbalanced quote) → allowed, not guessed at"

out=$(run_hook "")
assert_exit "$out" "0" "empty stdin → allowed"

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

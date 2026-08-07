#!/usr/bin/env bash
# Test suite for scripts/draft-pr-recovery.sh (issue #1069 — inherited draft
# PRs are invisible to every /shipyard:do-work sweep).
#
# Covers:
#   classify-one          — the pure decision matrix, all eight dispositions.
#   agent-authored-check  — Co-Authored-By:/Claude-Session: trailer detection,
#                            including the load-bearing case: the branch
#                            prefix is NOT the signal (issue body notes the
#                            repro PR's branch was fix/android-sdk-root-3461,
#                            not do-work/*).
#   gated-label-check     — exact + blocked:* wildcard match, no false
#                            positive on an unrelated label.
#   is-body-empty / has-wip-marker / has-unchecked-tasks — body signal
#                            extraction, including a false-positive guard on
#                            a word merely containing "wip".
#   enforce (dry-run)     — plans actions, no gh mutations.
#   enforce (real)        — the two named test cases from issue #1069:
#     - lightwork#3465-shaped PR (agent-authored, no gate label, open
#       closing ref, complete body) -> readied + auto-merge armed.
#     - shipyard#1100-shaped PR (agent-authored, closingIssuesReferences
#       present, BUT already carries needs-human-review) -> handed back,
#       NEVER auto-readied.
#   enforce (ungated shape) — readied but left for manual merge, never
#                            silently direct-merged.
#   enforce (idempotent)  — an already-gated PR is not re-labeled/re-commented.
#
# The gh-dependent paths are exercised against a mock `gh` binary injected
# via $GH, so the suite needs no network and is CI-safe. detect-ungated-
# admin-direct-merge.sh itself calls the literal `gh` binary (not $GH), so
# the ungated-shape test uses the script's own
# DRAFT_PR_RECOVERY_VERDICT_OVERRIDE test seam instead of mocking that
# sub-script's gh calls.
#
# Pure bash + jq. Run with:
#   bash plugins/shipyard/scripts/tests/draft-pr-recovery.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../draft-pr-recovery.sh"

if [[ ! -f "$script" ]]; then
  echo "FAIL: helper not found at $script" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 600; printf '\n'
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
    printf '    actual: %s\n' "$haystack" | head -c 600; printf '\n'
    fail=$((fail+1))
  fi
}

echo "draft-pr-recovery.sh test suite"
echo "================================"

# --------------------------------------------------------------------------
echo
echo "classify-one — decision matrix"
# --------------------------------------------------------------------------
out="$(bash "$script" classify-one true false 1 false false false false)"
assert_equals "$out" "ready" "agent-authored, no gate label, one open closing ref, complete body -> ready (lightwork#3465 shape)"

out="$(bash "$script" classify-one true true 1 false false false false)"
assert_equals "$out" "hand-back:gated-label" "gated label present overrides everything else -> hand-back:gated-label (shipyard#1100 shape)"

out="$(bash "$script" classify-one true false 0 false false false false)"
assert_equals "$out" "hand-back:no-closing-ref" "no closing-issue reference -> hand-back:no-closing-ref"

out="$(bash "$script" classify-one true false 1 true false false false)"
assert_equals "$out" "hand-back:stale-closing-issue" "closing-referenced issue already CLOSED -> hand-back:stale-closing-issue"

out="$(bash "$script" classify-one true false 1 false true false false)"
assert_equals "$out" "hand-back:empty-body" "empty body -> hand-back:empty-body"

out="$(bash "$script" classify-one true false 1 false false true false)"
assert_equals "$out" "hand-back:wip-marker" "WIP marker in title/body -> hand-back:wip-marker"

out="$(bash "$script" classify-one true false 1 false false false true)"
assert_equals "$out" "hand-back:unchecked-tasks" "unchecked task list item -> hand-back:unchecked-tasks"

out="$(bash "$script" classify-one false false 1 false false false false)"
assert_equals "$out" "skip:not-agent-authored" "not agent-authored -> skip:not-agent-authored (never touch a stranger's / human's draft)"

# --------------------------------------------------------------------------
echo
echo "classify-one — usage error"
# --------------------------------------------------------------------------
bash "$script" classify-one true false 1 >/dev/null 2>&1
assert_equals "$?" "64" "wrong argument count exits 64"

# --------------------------------------------------------------------------
echo
echo "agent-authored-check — commit trailer detection"
# --------------------------------------------------------------------------
out="$(printf 'Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_xyz\n' | bash "$script" agent-authored-check)"
assert_equals "$out" "true" "Co-Authored-By + Claude-Session trailer -> true"

out="$(printf 'Claude-Session: https://claude.ai/code/session_abc\n' | bash "$script" agent-authored-check)"
assert_equals "$out" "true" "Claude-Session trailer alone -> true"

out="$(printf 'Signed-off-by: Jane Human <jane@example.com>\n' | bash "$script" agent-authored-check)"
assert_equals "$out" "false" "an unrelated trailer -> false (a human's own draft must never look agent-authored)"

out="$(printf '' | bash "$script" agent-authored-check)"
assert_equals "$out" "false" "empty commit text -> false"

# --------------------------------------------------------------------------
echo
echo "gated-label-check — exact + wildcard match"
# --------------------------------------------------------------------------
out="$(printf 'needs-human-review\nshipyard\n' | bash "$script" gated-label-check)"
assert_equals "$out" "true" "needs-human-review present -> true"

out="$(printf 'blocked:ci\n' | bash "$script" gated-label-check)"
assert_equals "$out" "true" "blocked:* wildcard matches blocked:ci -> true"

out="$(printf 'shipyard\nbug\n' | bash "$script" gated-label-check)"
assert_equals "$out" "false" "no gate label present -> false"

out="$(printf '' | bash "$script" gated-label-check)"
assert_equals "$out" "false" "no labels at all -> false"

# --------------------------------------------------------------------------
echo
echo "is-body-empty / has-wip-marker / has-unchecked-tasks — body signals"
# --------------------------------------------------------------------------
out="$(printf '' | bash "$script" is-body-empty)"
assert_equals "$out" "true" "truly empty body -> true"

out="$(printf '   \n\n  \n' | bash "$script" is-body-empty)"
assert_equals "$out" "true" "whitespace-only body -> true"

out="$(printf 'This PR fixes the thing.\n\n## Verification\n- Ran tests\n' | bash "$script" is-body-empty)"
assert_equals "$out" "false" "a real body -> false"

out="$(printf 'WIP: fix the thing\n' | bash "$script" has-wip-marker)"
assert_equals "$out" "true" "standalone WIP token -> true"

out="$(printf 'DO NOT MERGE until review\n' | bash "$script" has-wip-marker)"
assert_equals "$out" "true" "DO NOT MERGE marker -> true"

out="$(printf 'fix(android): swipe gesture wiped state\n' | bash "$script" has-wip-marker)"
assert_equals "$out" "false" "a word merely containing wip ('wiped') -> false (no false positive)"

out="$(printf 'fix(ci): pin android sdk root\n\n## Verification\n- Ran tests\n' | bash "$script" has-wip-marker)"
assert_equals "$out" "false" "a clean, complete body -> false"

out="$(printf '## Test plan\n- [ ] verify X\n- [x] verify Y\n' | bash "$script" has-unchecked-tasks)"
assert_equals "$out" "true" "one unchecked task among checked ones -> true"

out="$(printf '## Test plan\n- [x] verify X\n- [x] verify Y\n' | bash "$script" has-unchecked-tasks)"
assert_equals "$out" "false" "every task checked -> false"

# --------------------------------------------------------------------------
# Mock gh scaffolding for the live `enforce` tests.
# --------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# make_gh writes a mock `gh` that:
#   - `pr list ... --search is:draft` returns $1 (newline-separated numbers)
#   - `pr view <n> ...` returns the pre-projected JSON at fixtures/pr-<n>.json
#   - `api graphql ...` returns the pre-projected states at fixtures/pr-<n>-closing.txt
#     (the PR number is read off the -F n=<val> argument)
#   - `pr ready` / `pr merge` / `pr edit` / `pr comment` / `label create` are
#     recorded to $GH_LOG and otherwise no-ops (exit 0).
make_gh() {
  local path="$1" list="$2" fixtures="$3"
  cat > "$path" <<MOCK
#!/usr/bin/env bash
echo "GH-CALL: \$*" >> "\$GH_LOG"
case "\$1 \$2" in
  "pr list")
    printf '%s\n' "${list}"
    ;;
  "pr view")
    n="\$3"
    cat "${fixtures}/pr-\${n}.json" 2>/dev/null
    ;;
  "api graphql")
    n=""
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "-F" ] && [[ "\$a" == n=* ]]; then
        n="\${a#n=}"
      fi
      prev="\$a"
    done
    cat "${fixtures}/pr-\${n}-closing.txt" 2>/dev/null
    ;;
  "pr ready"|"pr merge"|"pr edit"|"pr comment"|"label create")
    exit 0
    ;;
  *) : ;;
esac
MOCK
  chmod +x "$path"
}

write_fixture() {
  # write_fixture <dir> <number> <json-body> <closing-states-newline-separated>
  local dir="$1" n="$2" body="$3" closing="$4"
  mkdir -p "$dir"
  printf '%s' "$body" > "${dir}/pr-${n}.json"
  printf '%s\n' "$closing" > "${dir}/pr-${n}-closing.txt"
}

# --------------------------------------------------------------------------
echo
echo "enforce --dry-run — plans actions, no gh mutations"
# --------------------------------------------------------------------------
T="${WORK}/dry"; mkdir -p "$T/fixtures"
write_fixture "$T/fixtures" 3465 \
  '{"number":3465,"url":"https://github.com/o/r/pull/3465","title":"fix(android): pin sdk root","body":"Fixes the CI runner disk usage.\n\n## Verification\n- Ran tests","labels":["shipyard"],"closing":[3461],"commits":["Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_x"]}' \
  "OPEN"
make_gh "$T/gh" "3465" "$T/fixtures"
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
out="$(GH="$T/gh" bash "$script" enforce --repo o/r --dry-run 2>&1)"
assert_contains "$out" '"number":3465' "dry-run reports PR 3465"
assert_contains "$out" '"disposition":"ready"' "dry-run classifies 3465 as ready"
assert_contains "$out" '"action":"would-ready-and-arm-auto-merge"' "dry-run action is prefixed would-"
ghlog="$(cat "$GH_LOG")"
assert_not_contains "$ghlog" "pr ready" "dry-run makes NO pr ready call"
assert_not_contains "$ghlog" "pr merge" "dry-run makes NO pr merge call"
assert_not_contains "$ghlog" "pr edit" "dry-run makes NO pr edit call"

# --------------------------------------------------------------------------
echo
echo "enforce (real) — lightwork#3465 shape auto-readies + arms auto-merge"
# --------------------------------------------------------------------------
T="${WORK}/ready"; mkdir -p "$T/fixtures"
write_fixture "$T/fixtures" 3465 \
  '{"number":3465,"url":"https://github.com/o/r/pull/3465","title":"fix(android): pin sdk root","body":"Fixes the CI runner disk usage.\n\n## Verification\n- Ran tests","labels":["shipyard"],"closing":[3461],"commits":["Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_x"]}' \
  "OPEN"
make_gh "$T/gh" "3465" "$T/fixtures"
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
out="$(GH="$T/gh" DRAFT_PR_RECOVERY_VERDICT_OVERRIDE="gated" bash "$script" enforce --repo o/r 2>&1)"
ghlog="$(cat "$GH_LOG")"
assert_contains "$ghlog" "pr ready 3465 --repo o/r" "readies pr 3465"
assert_contains "$ghlog" "pr merge 3465 --repo o/r --auto" "arms auto-merge on pr 3465"
assert_not_contains "$ghlog" "pr edit" "never applies needs-human-review to the ready candidate"
assert_contains "$out" '"action":"readied-and-auto-merge-armed"' "reports the readied-and-auto-merge-armed action"

# --------------------------------------------------------------------------
echo
echo "enforce (real) — shipyard#1100 shape (needs-human-review already present) hands back, NEVER auto-readies"
# --------------------------------------------------------------------------
T="${WORK}/handback"; mkdir -p "$T/fixtures"
write_fixture "$T/fixtures" 1100 \
  '{"number":1100,"url":"https://github.com/o/r/pull/1100","title":"fix(do-work): abandoned approach","body":"Superseded — see issue discussion.","labels":["shipyard","needs-human-review"],"closing":[1096],"commits":["Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_y"]}' \
  "CLOSED"
make_gh "$T/gh" "1100" "$T/fixtures"
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
out="$(GH="$T/gh" bash "$script" enforce --repo o/r 2>&1)"
ghlog="$(cat "$GH_LOG")"
assert_not_contains "$ghlog" "pr ready" "NEVER calls pr ready on the shipyard#1100 shape"
assert_not_contains "$ghlog" "pr merge" "NEVER calls pr merge on the shipyard#1100 shape"
assert_contains "$out" '"disposition":"hand-back:gated-label"' "classifies as hand-back:gated-label (the label alone is sufficient, even though the closing issue is also CLOSED)"
assert_contains "$out" '"action":"handed-back"' "reports handed-back action"
# Idempotent: the PR already carries needs-human-review — don't re-label/re-comment.
assert_not_contains "$ghlog" "pr edit 1100" "does not re-apply needs-human-review (already gated -> idempotent no-op)"
assert_not_contains "$ghlog" "pr comment 1100" "does not re-comment on an already-gated PR"

# --------------------------------------------------------------------------
echo
echo "enforce (real) — WIP draft hands back and IS labeled (not yet gated)"
# --------------------------------------------------------------------------
T="${WORK}/wip"; mkdir -p "$T/fixtures"
write_fixture "$T/fixtures" 42 \
  '{"number":42,"url":"https://github.com/o/r/pull/42","title":"WIP: exploring an approach","body":"WIP: exploring an approach\n\n- [ ] figure out the API","labels":["shipyard"],"closing":[40],"commits":["Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"]}' \
  "OPEN"
make_gh "$T/gh" "42" "$T/fixtures"
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
out="$(GH="$T/gh" bash "$script" enforce --repo o/r 2>&1)"
ghlog="$(cat "$GH_LOG")"
assert_not_contains "$ghlog" "pr ready" "a genuine WIP draft is never readied"
assert_contains "$ghlog" "label create needs-human-review" "ensures the needs-human-review label exists"
assert_contains "$ghlog" "pr edit 42 --repo o/r --add-label needs-human-review" "labels the WIP draft needs-human-review"
assert_contains "$ghlog" "pr comment 42" "comments explaining the hand-back"
assert_contains "$out" '"disposition":"hand-back:wip-marker"' "classifies as hand-back:wip-marker"

# --------------------------------------------------------------------------
echo
echo "enforce (real) — a non-agent-authored draft is skipped entirely (no output line, no gh mutation)"
# --------------------------------------------------------------------------
T="${WORK}/human"; mkdir -p "$T/fixtures"
write_fixture "$T/fixtures" 7 \
  '{"number":7,"url":"https://github.com/o/r/pull/7","title":"human WIP experiment","body":"still exploring","labels":[],"closing":[5],"commits":["Signed-off-by: A Human <human@example.com>"]}' \
  "OPEN"
make_gh "$T/gh" "7" "$T/fixtures"
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
out="$(GH="$T/gh" bash "$script" enforce --repo o/r 2>&1)"
ghlog="$(cat "$GH_LOG")"
assert_equals "$out" "" "a human-authored draft produces no output line"
assert_not_contains "$ghlog" "pr ready" "never readies a human's own draft"
assert_not_contains "$ghlog" "pr edit" "never labels a human's own draft"
assert_not_contains "$ghlog" "pr comment" "never comments on a human's own draft"

# --------------------------------------------------------------------------
echo
echo "enforce — ungated admin-direct-merge shape: readies but does NOT arm --auto"
# --------------------------------------------------------------------------
T="${WORK}/ungated"; mkdir -p "$T/fixtures"
write_fixture "$T/fixtures" 99 \
  '{"number":99,"url":"https://github.com/o/r/pull/99","title":"fix: something","body":"Fixes the thing.\n\n## Verification\n- Ran tests","labels":["shipyard"],"closing":[90],"commits":["Claude-Session: https://claude.ai/code/session_z"]}' \
  "OPEN"
make_gh "$T/gh" "99" "$T/fixtures"
export GH_LOG="$T/gh.log"; : > "$GH_LOG"
out="$(GH="$T/gh" DRAFT_PR_RECOVERY_VERDICT_OVERRIDE="ungated" bash "$script" enforce --repo o/r 2>&1)"
ghlog="$(cat "$GH_LOG")"
assert_contains "$ghlog" "pr ready 99 --repo o/r" "readies pr 99 even on the ungated shape"
assert_not_contains "$ghlog" "pr merge" "never calls pr merge --auto on the ungated shape (would bypass CI)"
assert_contains "$ghlog" "pr comment 99" "leaves an advisory comment that manual merge is needed"
assert_contains "$out" '"action":"readied-manual-merge-needed"' "reports readied-manual-merge-needed"

echo
echo "================================"
if (( fail > 0 )); then
  printf '%sFAIL%s  %d passed, %d failed\n' "$RED" "$RESET" "$pass" "$fail" >&2
  exit 1
else
  printf '%sPASS%s  all %d assertions passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

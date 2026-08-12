#!/usr/bin/env bash
# Test suite for scripts/stale-check-refresh.sh (issue #993's post-main-CI-fix
# branch-refresh, extracted to a script by issue #1277).
#
# Covers:
#   usage / arg validation    — missing --repo/--fix-commit-sha/--fix-commit-date
#   stale-red PR              — gets `gh pr update-branch` + a state-file entry
#   genuinely-red PR          — failure postdates the fix; NOT refreshed
#   DIRTY PR                  — skipped regardless of check state (fix-rebase's territory)
#   non-OPEN PR                — skipped
#   healthy PR                — no failing check at all; nothing to refresh
#   dedup                     — a second run against the same fix commit does not re-refresh
#   comma- and space-separated --session-prs both accepted
#
# The `gh` dependency is mocked via the $GH env var (mirrors
# flake-enforce.test.sh's own mocking convention) so this suite needs no
# network access and is CI-safe.
#
# Pure bash + jq. Run with:
#   bash plugins/shipyard/scripts/tests/stale-check-refresh.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../stale-check-refresh.sh"

if [[ ! -f "$script" ]]; then
  echo "FAIL: helper not found at $script" >&2
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

assert_exit() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (exit %s, want %s)\n' "$RED" "$RESET" "$label" "$got" "$want"
    fail=$((fail+1))
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# make_gh <path> <fixtures-dir> — a mock gh that:
#   - `pr view <N> ...` prints the canned snapshot JSON from
#     <fixtures-dir>/<N>.json (a pre-shaped {state, mergeStateStatus, checks}
#     object — the mock does not actually run the real --jq filter, mirroring
#     flake-enforce.test.sh's own canned-response mocking convention).
#   - `pr update-branch <N> ...` logs the call to $GH_LOG and succeeds.
make_gh() {
  local path="$1" fixtures="$2"
  cat > "$path" <<MOCK
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr view" ]; then
  pr="\$3"
  cat "${fixtures}/\${pr}.json" 2>/dev/null
  exit 0
fi
if [ "\$1 \$2" = "pr update-branch" ]; then
  echo "UPDATE-BRANCH: \$3" >> "\$GH_LOG"
  exit 0
fi
exit 0
MOCK
  chmod +x "$path"
}

FIXTURES="${WORK}/fixtures"
mkdir -p "$FIXTURES"

# PR 1 — OPEN, not DIRTY, one FAILURE that completed BEFORE the fix commit
# date → stale-red, should be refreshed.
cat > "${FIXTURES}/1.json" <<'EOF'
{"state":"OPEN","mergeStateStatus":"CLEAN","checks":[{"name":"tests","conclusion":"FAILURE","completedAt":"2026-01-01T00:00:00Z"}]}
EOF

# PR 2 — OPEN, not DIRTY, one FAILURE that completed AFTER the fix commit
# date → genuinely red against the fixed base, must NOT be refreshed.
cat > "${FIXTURES}/2.json" <<'EOF'
{"state":"OPEN","mergeStateStatus":"CLEAN","checks":[{"name":"tests","conclusion":"FAILURE","completedAt":"2026-06-01T00:00:00Z"}]}
EOF

# PR 3 — DIRTY, even with a pre-fix FAILURE → skipped (fix-rebase's territory).
cat > "${FIXTURES}/3.json" <<'EOF'
{"state":"OPEN","mergeStateStatus":"DIRTY","checks":[{"name":"tests","conclusion":"FAILURE","completedAt":"2026-01-01T00:00:00Z"}]}
EOF

# PR 4 — MERGED (not OPEN) → skipped.
cat > "${FIXTURES}/4.json" <<'EOF'
{"state":"MERGED","mergeStateStatus":"CLEAN","checks":[{"name":"tests","conclusion":"FAILURE","completedAt":"2026-01-01T00:00:00Z"}]}
EOF

# PR 5 — OPEN, not DIRTY, all checks green → nothing stale, skipped.
cat > "${FIXTURES}/5.json" <<'EOF'
{"state":"OPEN","mergeStateStatus":"CLEAN","checks":[{"name":"tests","conclusion":"SUCCESS","completedAt":"2026-01-01T00:00:00Z"}]}
EOF

GH_MOCK="${WORK}/gh"
make_gh "$GH_MOCK" "$FIXTURES"
export GH_LOG="${WORK}/gh.log"
: > "$GH_LOG"

echo "stale-check-refresh.sh test suite"
echo "=================================="

# --------------------------------------------------------------------------
echo
echo "usage / arg validation"
# --------------------------------------------------------------------------
out="$(bash "$script" run --repo o/r 2>&1)"; rc=$?
assert_contains "$out" "required" "run without --fix-commit-sha/--fix-commit-date errors"
assert_exit "$rc" "64" "missing required args exits 64"

out="$(bash "$script" bogus-subcommand 2>&1)"; rc=$?
assert_contains "$out" "unknown subcommand" "unknown subcommand is rejected"
assert_exit "$rc" "64" "unknown subcommand exits 64"

# --------------------------------------------------------------------------
echo
echo "run — mixed batch of PRs (stale-red, genuinely-red, DIRTY, merged, healthy)"
# --------------------------------------------------------------------------
STATE_FILE="${WORK}/state1"
out="$(GH="$GH_MOCK" bash "$script" run \
  --repo o/r \
  --fix-commit-sha fixsha1 \
  --fix-commit-date "2026-03-01T00:00:00Z" \
  --session-prs "1,2,3,4,5" \
  --state-file "$STATE_FILE" 2>&1)"

assert_contains "$out" "PR #1 carried a required-check FAILURE" "PR 1 (stale-red) gets refreshed"
assert_not_contains "$out" "PR #2 carried" "PR 2 (genuinely red, postdates fix) is NOT refreshed"
assert_not_contains "$out" "PR #3 carried" "PR 3 (DIRTY) is NOT refreshed"
assert_not_contains "$out" "PR #4 carried" "PR 4 (not OPEN) is NOT refreshed"
assert_not_contains "$out" "PR #5 carried" "PR 5 (healthy) is NOT refreshed"

ghlog="$(cat "$GH_LOG")"
assert_contains "$ghlog" "UPDATE-BRANCH: 1" "gh pr update-branch called for PR 1"
assert_not_contains "$ghlog" "UPDATE-BRANCH: 2" "gh pr update-branch NOT called for PR 2"
assert_not_contains "$ghlog" "UPDATE-BRANCH: 3" "gh pr update-branch NOT called for PR 3"

if grep -qF "1 fixsha1" "$STATE_FILE" 2>/dev/null; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "state file records PR 1 against fixsha1"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "state file records PR 1 against fixsha1"; fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo
echo "run — dedup: a second run against the SAME fix commit does not re-refresh"
# --------------------------------------------------------------------------
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" run \
  --repo o/r \
  --fix-commit-sha fixsha1 \
  --fix-commit-date "2026-03-01T00:00:00Z" \
  --session-prs "1" \
  --state-file "$STATE_FILE" 2>&1)"
assert_not_contains "$out" "PR #1 carried" "second run against same fix commit skips PR 1 (already refreshed)"
ghlog="$(cat "$GH_LOG")"
assert_not_contains "$ghlog" "UPDATE-BRANCH" "second run makes no gh pr update-branch call at all"

# --------------------------------------------------------------------------
echo
echo "run — space-separated --session-prs is accepted identically to comma-separated"
# --------------------------------------------------------------------------
STATE_FILE2="${WORK}/state2"
: > "$GH_LOG"
out="$(GH="$GH_MOCK" bash "$script" run \
  --repo o/r \
  --fix-commit-sha fixsha2 \
  --fix-commit-date "2026-03-01T00:00:00Z" \
  --session-prs "1 2 3" \
  --state-file "$STATE_FILE2" 2>&1)"
assert_contains "$out" "PR #1 carried a required-check FAILURE" "space-separated --session-prs still refreshes PR 1"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

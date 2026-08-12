#!/usr/bin/env bash
# Test suite for scripts/stale-failure-check.sh (dispatch-rules.md §2a's
# stale-failure check, extracted to a script by issue #1289).
#
# Covers:
#   usage / arg validation      — missing --repo/--pr
#   fetch failure                — empty rollup -> stale=false, reason=fetch-failed
#   all failing checks stale     — every failing check's run predates the head -> stale=true
#   one failing check is live    — a failing check's run matches current head -> stale=false
#   unresolvable run id          — a detailsUrl the scanner can't parse -> stale=false
#   no failing checks at all     — empty `failing` array -> stale=true (matches original
#                                  loop-never-executes semantics)
#
# The `gh` dependency is mocked via the $GH env var (mirrors
# stale-check-refresh.test.sh's own mocking convention) so this suite needs
# no network access and is CI-safe.
#
# Pure bash + jq. Run with:
#   bash plugins/shipyard/scripts/tests/stale-failure-check.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../stale-failure-check.sh"

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# make_gh <path> <fixture> — a mock gh that:
#   - `pr view <M> --repo ... --json headRefOid,statusCheckRollup --jq ...`
#     prints the canned rollup-projection JSON from <fixture> (the mock
#     ignores the actual --jq expression and returns the pre-shaped
#     {head, failing} object directly, mirroring stale-check-refresh.test.sh's
#     canned-response convention).
#   - `api repos/.../actions/runs/<id> --jq .head_sha` prints the run's head
#     sha from a companion file <fixture>.runs/<id> (one sha per file).
make_gh() {
  local path="$1" fixture="$2" runs_dir="$3"
  cat > "$path" <<MOCK
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr view" ]; then
  cat "${fixture}" 2>/dev/null
  exit 0
fi
if [ "\$1" = "api" ]; then
  run_id="\$(basename "\$2")"
  cat "${runs_dir}/\${run_id}" 2>/dev/null
  exit 0
fi
exit 0
MOCK
  chmod +x "$path"
}

echo "stale-failure-check.sh test suite"
echo "=================================="

# --------------------------------------------------------------------------
echo
echo "usage / arg validation"
# --------------------------------------------------------------------------
out="$(bash "$script" check --repo o/r 2>&1)"; rc=$?
assert_contains "$out" "required" "check without --pr errors"
assert_exit "$rc" "64" "missing required args exits 64"

out="$(bash "$script" bogus-subcommand 2>&1)"; rc=$?
assert_contains "$out" "unknown subcommand" "unknown subcommand is rejected"
assert_exit "$rc" "64" "unknown subcommand exits 64"

RUNS_DIR="${WORK}/runs"
mkdir -p "$RUNS_DIR"

# --------------------------------------------------------------------------
echo
echo "check — every failing check's run predates the current head (stale=true)"
# --------------------------------------------------------------------------
cat > "${WORK}/stale.json" <<'EOF'
{"head":"headsha123","failing":[{"name":"tests","detailsUrl":"https://github.com/o/r/actions/runs/111"}]}
EOF
echo "oldsha000" > "${RUNS_DIR}/111"
GH_MOCK="${WORK}/gh1"
make_gh "$GH_MOCK" "${WORK}/stale.json" "$RUNS_DIR"
out="$(GH="$GH_MOCK" bash "$script" check --repo o/r --pr 1 2>&1)"
assert_contains "$out" "stale=true" "all-stale failing checks report stale=true"
assert_contains "$out" "head_sha=headsha123" "stale result carries the current head sha"

# --------------------------------------------------------------------------
echo
echo "check — a failing check's run matches the current head (stale=false, live failure)"
# --------------------------------------------------------------------------
cat > "${WORK}/live.json" <<'EOF'
{"head":"headsha123","failing":[{"name":"tests","detailsUrl":"https://github.com/o/r/actions/runs/222"}]}
EOF
echo "headsha123" > "${RUNS_DIR}/222"
GH_MOCK2="${WORK}/gh2"
make_gh "$GH_MOCK2" "${WORK}/live.json" "$RUNS_DIR"
out="$(GH="$GH_MOCK2" bash "$script" check --repo o/r --pr 2 2>&1)"
assert_contains "$out" "stale=false" "a failing check matching the current head reports stale=false"
assert_contains "$out" "reason=current-head" "live-failure reason is current-head"

# --------------------------------------------------------------------------
echo
echo "check — unresolvable run id (malformed detailsUrl) -> stale=false, fail-safe"
# --------------------------------------------------------------------------
cat > "${WORK}/malformed.json" <<'EOF'
{"head":"headsha123","failing":[{"name":"tests","detailsUrl":"https://github.com/o/r/actions/not-a-run-url"}]}
EOF
GH_MOCK3="${WORK}/gh3"
make_gh "$GH_MOCK3" "${WORK}/malformed.json" "$RUNS_DIR"
out="$(GH="$GH_MOCK3" bash "$script" check --repo o/r --pr 3 2>&1)"
assert_contains "$out" "stale=false" "an unresolvable run id fails safe to stale=false"
assert_contains "$out" "reason=unresolvable-run-id" "unresolvable-run-id reason is reported"

# --------------------------------------------------------------------------
echo
echo "check — no failing checks at all (empty failing array) -> stale=true"
# --------------------------------------------------------------------------
cat > "${WORK}/empty.json" <<'EOF'
{"head":"headsha123","failing":[]}
EOF
GH_MOCK4="${WORK}/gh4"
make_gh "$GH_MOCK4" "${WORK}/empty.json" "$RUNS_DIR"
out="$(GH="$GH_MOCK4" bash "$script" check --repo o/r --pr 4 2>&1)"
assert_contains "$out" "stale=true" "an empty failing array reports stale=true (loop never executes)"

# --------------------------------------------------------------------------
echo
echo "check — gh fetch failure (empty rollup) -> stale=false, fail-safe"
# --------------------------------------------------------------------------
GH_MOCK5="${WORK}/gh5"
cat > "$GH_MOCK5" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "$GH_MOCK5"
out="$(GH="$GH_MOCK5" bash "$script" check --repo o/r --pr 5 2>&1)"
assert_contains "$out" "stale=false" "a gh fetch failure fails safe to stale=false"
assert_contains "$out" "reason=fetch-failed" "fetch-failed reason is reported"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

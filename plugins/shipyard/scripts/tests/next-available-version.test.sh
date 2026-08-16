#!/usr/bin/env bash
# Test suite for scripts/next-available-version.sh (dispatch-rules.md's
# next-available-version computation, extracted to a script by issue #1289).
#
# Covers:
#   usage / arg validation     — missing required flags
#   floor from origin only     — no session_prs, no cursor -> patch bump off origin
#   in-flight PR raises floor  — an OPEN PR touching the manifest with a higher
#                                 version wins over origin's value
#   non-OPEN / non-touching PR is ignored
#   bump level inference       — feat: -> minor, feat!:/BREAKING CHANGE -> major,
#                                 default -> patch
#   cursor-file persistence    — a second invocation reads the prior cursor and
#                                 advances past it (batch-monotonicity)
#
# The `gh` dependency is mocked via the $GH env var so this suite needs no
# network access and is CI-safe.
#
# Pure bash + jq. Run with:
#   bash plugins/shipyard/scripts/tests/next-available-version.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../next-available-version.sh"

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

# make_gh <path> — a mock gh dispatching on subcommand:
#   api repos/<repo>/contents/<manifest>?ref=<ref>   -> base64 of {"version": "<x.y.z>"}
#     from $WORK/manifest.<ref>.b64 (a per-ref fixture file the test writes)
#   pr view <N> --json state -q .state               -> from $WORK/pr.<N>.state
#   pr view <N> --json files --jq ...                 -> from $WORK/pr.<N>.touches (0 or a count)
#   pr view <N> --json headRefName -q .headRefName    -> "pr<N>-branch"
#   issue view <N> --json title -q .title             -> from $WORK/issue.<N>.title
#   issue view <N> --json body -q .body               -> from $WORK/issue.<N>.body
make_gh() {
  local path="$1"
  cat > "$path" <<MOCK
#!/usr/bin/env bash
work="${WORK}"
if [ "\$1" = "api" ]; then
  ref="\${2##*ref=}"
  manifest_file="\$(echo "\$2" | sed -E 's#repos/[^/]+/[^/]+/contents/##; s#\\?ref=.*##')"
  cat "\${work}/manifest.\${ref}.b64" 2>/dev/null
  exit 0
fi
if [ "\$1 \$2" = "pr view" ]; then
  pr="\$3"
  if [ "\$4 \$5" = "--repo o/r" ] && [ "\$6" = "--json" ] && [ "\$7" = "state" ]; then
    cat "\${work}/pr.\${pr}.state" 2>/dev/null
    exit 0
  fi
  if [ "\$6" = "--json" ] && [ "\$7" = "files" ]; then
    cat "\${work}/pr.\${pr}.touches" 2>/dev/null
    exit 0
  fi
  if [ "\$6" = "--json" ] && [ "\$7" = "headRefName" ]; then
    echo "pr\${pr}-branch"
    exit 0
  fi
fi
if [ "\$1 \$2" = "issue view" ]; then
  issue="\$3"
  if [ "\$7" = "title" ]; then
    cat "\${work}/issue.\${issue}.title" 2>/dev/null
    exit 0
  fi
  if [ "\$7" = "body" ]; then
    cat "\${work}/issue.\${issue}.body" 2>/dev/null
    exit 0
  fi
fi
exit 0
MOCK
  chmod +x "$path"
}

GH_MOCK="${WORK}/gh"
make_gh "$GH_MOCK"

b64_version() {
  printf '{"version":"%s"}' "$1" | base64
}

echo "next-available-version.sh test suite"
echo "====================================="

# --------------------------------------------------------------------------
echo
echo "usage / arg validation"
# --------------------------------------------------------------------------
out="$(bash "$script" compute --repo o/r 2>&1)"; rc=$?
assert_contains "$out" "required" "compute without required flags errors"
assert_exit "$rc" "64" "missing required args exits 64"

out="$(bash "$script" bogus 2>&1)"; rc=$?
assert_contains "$out" "unknown subcommand" "unknown subcommand is rejected"
assert_exit "$rc" "64" "unknown subcommand exits 64"

# --------------------------------------------------------------------------
echo
echo "compute — floor from origin only (no session_prs, no cursor), patch-default issue"
# --------------------------------------------------------------------------
b64_version "1.5.0" > "${WORK}/manifest.main.b64"
echo "fix: correct a typo" > "${WORK}/issue.10.title"
echo "" > "${WORK}/issue.10.body"
CURSOR1="${WORK}/cursor1"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 10 --cursor-file "$CURSOR1" 2>&1)"
assert_contains "$out" "max_inflight_version=1.5.0" "floor is origin's version when no in-flight PRs"
assert_contains "$out" "bump_level=patch" "no recognizable prefix defaults to patch"
assert_contains "$out" "next_available_version=1.5.1" "patch-only floor bumps the patch component"

if [[ -f "$CURSOR1" ]] && [[ "$(cat "$CURSOR1")" == "1.5.1" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "cursor file persists the computed value"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "cursor file persists the computed value"; fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo
echo "compute — an in-flight OPEN PR touching the manifest raises the floor"
# --------------------------------------------------------------------------
echo "OPEN" > "${WORK}/pr.20.state"
echo "1" > "${WORK}/pr.20.touches"
b64_version "1.6.0" > "${WORK}/manifest.pr20-branch.b64"
echo "feat: add a widget" > "${WORK}/issue.11.title"
echo "" > "${WORK}/issue.11.body"
CURSOR2="${WORK}/cursor2"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 11 --session-prs "20" --cursor-file "$CURSOR2" 2>&1)"
assert_contains "$out" "max_inflight_version=1.6.0" "in-flight PR's higher version wins over origin's floor"
assert_contains "$out" "bump_level=minor" "feat: title infers minor"
assert_contains "$out" "next_available_version=1.7.0" "minor bump zeroes the patch component"

# --------------------------------------------------------------------------
echo
echo "compute — a non-OPEN PR is ignored even though it touches the manifest"
# --------------------------------------------------------------------------
echo "MERGED" > "${WORK}/pr.21.state"
echo "1" > "${WORK}/pr.21.touches"
echo "chore: cleanup" > "${WORK}/issue.12.title"
echo "" > "${WORK}/issue.12.body"
CURSOR3="${WORK}/cursor3"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 12 --session-prs "21" --cursor-file "$CURSOR3" 2>&1)"
assert_contains "$out" "max_inflight_version=1.5.0" "a MERGED PR does not raise the floor"

# --------------------------------------------------------------------------
echo
echo "compute — bump level: feat! / BREAKING CHANGE -> major"
# --------------------------------------------------------------------------
echo "feat!: drop legacy config format" > "${WORK}/issue.13.title"
echo "" > "${WORK}/issue.13.body"
CURSOR4="${WORK}/cursor4"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 13 --cursor-file "$CURSOR4" 2>&1)"
assert_contains "$out" "bump_level=major" "feat!: title infers major"
assert_contains "$out" "next_available_version=2.0.0" "major bump zeroes minor+patch"

# --------------------------------------------------------------------------
echo
echo "compute — cursor-file persistence: a second call reads the prior cursor"
# --------------------------------------------------------------------------
echo "fix: another fix" > "${WORK}/issue.14.title"
echo "" > "${WORK}/issue.14.body"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 14 --cursor-file "$CURSOR1" 2>&1)"
# CURSOR1 already holds 1.5.1 from the first test — a second patch-level
# compute against the same (unchanged) origin floor must bump PAST the
# cursor, not re-derive 1.5.1 from origin again (batch monotonicity, #437).
assert_contains "$out" "max_inflight_version=1.5.1" "second call folds in the persisted cursor as the new floor"
assert_contains "$out" "next_available_version=1.5.2" "second call bumps past the persisted cursor, not from origin again"

# --------------------------------------------------------------------------
echo
echo "reseed-if-idle — issue #1417 self-heal (caller-side, session_prs has no OPEN member)"
# --------------------------------------------------------------------------

# A stale cursor left over from a divergence (compute computed a value the
# worker never actually claimed) is discarded when nothing in session_prs
# is currently OPEN — the #1417 repro.
CURSOR_STALE="${WORK}/cursor-stale"
printf '%s' "4.37.0" > "$CURSOR_STALE"
echo "MERGED" > "${WORK}/pr.30.state"
out="$(GH="$GH_MOCK" bash "$script" reseed-if-idle \
  --repo o/r --session-prs "30" --cursor-file "$CURSOR_STALE" 2>&1)"
assert_contains "$out" "reseed=reset" "stale cursor is reset when session_prs has no OPEN member"
if [[ -f "$CURSOR_STALE" ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "cursor file removed on reset"; fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "cursor file removed on reset"; pass=$((pass+1))
fi

# A cursor is preserved when session_prs has at least one genuinely OPEN
# member — this is the batch-monotonicity-preserving case: reseed-if-idle
# must be a no-op whenever something might still be relying on the cursor.
CURSOR_LIVE="${WORK}/cursor-live"
printf '%s' "4.37.0" > "$CURSOR_LIVE"
echo "OPEN" > "${WORK}/pr.31.state"
out="$(GH="$GH_MOCK" bash "$script" reseed-if-idle \
  --repo o/r --session-prs "31" --cursor-file "$CURSOR_LIVE" 2>&1)"
assert_contains "$out" "reseed=skipped-open-pr-found" "cursor is preserved when session_prs has an OPEN member"
if [[ -f "$CURSOR_LIVE" ]] && [[ "$(cat "$CURSOR_LIVE")" == "4.37.0" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "cursor file untouched when preserved"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "cursor file untouched when preserved"; fail=$((fail+1))
fi

# Mixed session_prs: one MERGED, one OPEN — the OPEN member alone is enough
# to preserve the cursor (any_open_session_pr, not all-open).
CURSOR_MIXED="${WORK}/cursor-mixed"
printf '%s' "4.38.0" > "$CURSOR_MIXED"
echo "MERGED" > "${WORK}/pr.32.state"
echo "OPEN" > "${WORK}/pr.33.state"
out="$(GH="$GH_MOCK" bash "$script" reseed-if-idle \
  --repo o/r --session-prs "32,33" --cursor-file "$CURSOR_MIXED" 2>&1)"
assert_contains "$out" "reseed=skipped-open-pr-found" "one OPEN member among several is enough to preserve the cursor"

# No cursor file at all and no session_prs — a genuine no-op, not an error.
CURSOR_NONE="${WORK}/cursor-none-does-not-exist"
out="$(GH="$GH_MOCK" bash "$script" reseed-if-idle \
  --repo o/r --cursor-file "$CURSOR_NONE" 2>&1)"
assert_contains "$out" "reseed=noop-no-cursor" "empty session_prs and no cursor file is a clean no-op"

# --repo is required.
out="$(bash "$script" reseed-if-idle 2>&1)"; rc=$?
assert_contains "$out" "required" "reseed-if-idle without --repo errors"
assert_exit "$rc" "64" "reseed-if-idle missing --repo exits 64"

# --------------------------------------------------------------------------
echo
echo "reseed-if-idle composes with compute — the #1417 repro end-to-end"
# --------------------------------------------------------------------------
# Reproduces the issue body's repro: a divergence left the cursor holding a
# computed-but-never-claimed value (4.37.0), origin is still at 4.35.19,
# and by the time of the next dispatch every session PR has merged.
# reseed-if-idle must clear the stale cursor BEFORE compute runs, so
# compute re-derives the correct floor from origin alone.
b64_version "4.35.19" > "${WORK}/manifest.main.b64"
CURSOR_E2E="${WORK}/cursor-e2e"
printf '%s' "4.37.0" > "$CURSOR_E2E"
echo "MERGED" > "${WORK}/pr.40.state"

RESEED_OUT="$(GH="$GH_MOCK" bash "$script" reseed-if-idle \
  --repo o/r --session-prs "40" --cursor-file "$CURSOR_E2E" 2>&1)"
assert_contains "$RESEED_OUT" "reseed=reset" "e2e: stale cursor reset before the next dispatch's compute"

echo "fix(do-work): the next dispatch after full drain" > "${WORK}/issue.15.title"
echo "" > "${WORK}/issue.15.body"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 15 --session-prs "40" --cursor-file "$CURSOR_E2E" 2>&1)"
assert_contains "$out" "max_inflight_version=4.35.19" "e2e: compute re-derives the correct floor from origin, not the stale 4.37.0"
assert_contains "$out" "next_available_version=4.35.20" "e2e: compute's patch bump lands one past the real floor, not the phantom cursor"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

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
#   reseed-if-idle             — the #1417 caller-side self-heal
#   release + hole reclaim     — the #1420 release-on-non-claim hook: a
#                                 released slot is recorded as a hole (never a
#                                 cursor rollback), reclaimed by the next
#                                 compute, consumed at most once, pruned when
#                                 ground truth claims it, and byte-for-byte
#                                 inert when no holes file exists
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

# --------------------------------------------------------------------------
echo
echo "release — issue #1420 arg validation and no-op shapes"
# --------------------------------------------------------------------------

# No --version at all: the "caller had no recorded slot" case. A soft no-op
# (exit 0), NOT an error — it degrades to the status quo (the slot stays
# leaked) and is what the orchestrator surfaces as version_release=skipped.
CURSOR_R="${WORK}/cursor-release"
printf '%s' "4.40.0" > "$CURSOR_R"
out="$(bash "$script" release --cursor-file "$CURSOR_R" 2>&1)"; rc=$?
assert_contains "$out" "release=noop-no-version" "release with no --version is a named no-op"
assert_exit "$rc" "0" "release with no --version still exits 0 (best-effort posture)"

out="$(bash "$script" release --version "not-a-version" --cursor-file "$CURSOR_R" 2>&1)"
assert_contains "$out" "release=noop-bad-version" "release rejects a non-semver --version as a named no-op"

# No cursor file: reseed-if-idle already discarded it, so there is no
# phantom left to reclaim and nothing to record.
out="$(bash "$script" release --version "4.40.0" \
  --cursor-file "${WORK}/cursor-release-absent" 2>&1)"
assert_contains "$out" "release=noop-no-cursor" "release is a no-op when the cursor file is already gone"

# A version ABOVE the cursor cannot have come from this cursor's own compute
# run — refuse rather than record a slot ground truth never accounted for.
out="$(bash "$script" release --version "4.41.0" --cursor-file "$CURSOR_R" 2>&1)"
assert_contains "$out" "release=noop-above-cursor" "release refuses a version above the cursor"

# Unknown argument is a hard usage error.
out="$(bash "$script" release --bogus x 2>&1)"; rc=$?
assert_contains "$out" "unknown argument" "release rejects an unknown argument"
assert_exit "$rc" "64" "release unknown argument exits 64"

# --------------------------------------------------------------------------
echo
echo "release — records a hole and NEVER lowers the cursor (#1420)"
# --------------------------------------------------------------------------
HOLES_R="${CURSOR_R}.holes"
rm -f "$HOLES_R"
out="$(bash "$script" release --version "4.40.0" --cursor-file "$CURSOR_R" 2>&1)"
assert_contains "$out" "release=recorded-hole" "releasing the current top records a hole"
assert_contains "$(cat "$HOLES_R" 2>/dev/null)" "4.40.0" "the released version lands in the default <cursor>.holes file"
assert_contains "$(cat "$CURSOR_R")" "4.40.0" "release does NOT lower the cursor — a rollback would reintroduce #437"

# Idempotent: a re-fired reconcile must not double-record the same hole.
out="$(bash "$script" release --version "4.40.0" --cursor-file "$CURSOR_R" 2>&1)"
assert_contains "$out" "release=already-recorded" "a second release of the same version is idempotent"
if [[ "$(grep -c . "$HOLES_R")" == "1" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "holes file still holds exactly one entry after a duplicate release"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "holes file still holds exactly one entry after a duplicate release"; fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo
echo "release + compute — the #1420 declined-dispatch repro, end-to-end"
# --------------------------------------------------------------------------
# The repro from issue #1420's own comment thread: compute inferred `minor`
# and handed 4.39.0 to a dispatch that then DECLINED (no branch, no commit,
# no PR), so nothing ever claimed it. Pre-#1420 the next compute floored on
# the phantom cursor and handed out 4.40.0 while the true highest claim
# across all open PRs was only 4.38.0. With the release hook the released
# slot is reclaimed instead of leaked.
b64_version "4.37.0" > "${WORK}/manifest.main.b64"
b64_version "4.38.0" > "${WORK}/manifest.pr50-branch.b64"
echo "OPEN" > "${WORK}/pr.50.state"
echo "1" > "${WORK}/pr.50.touches"

CURSOR_1420="${WORK}/cursor-1420"
rm -f "$CURSOR_1420" "${CURSOR_1420}.holes"
echo "feat(do-work): the dispatch that declined" > "${WORK}/issue.20.title"
echo "" > "${WORK}/issue.20.body"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 20 --session-prs "50" --cursor-file "$CURSOR_1420" 2>&1)"
assert_contains "$out" "next_available_version=4.39.0" "repro: the declined dispatch was handed 4.39.0"
assert_contains "$out" "reclaimed_slot=" "repro: nothing to reclaim on the first compute"

# The dispatch terminates without opening a PR -> release its slot.
out="$(bash "$script" release --version "4.39.0" --cursor-file "$CURSOR_1420" 2>&1)"
assert_contains "$out" "release=recorded-hole" "repro: the declined slot is released at reconcile"

# The next dispatch must get 4.39.0 back, NOT 4.40.0.
echo "feat(do-work): the next dispatch" > "${WORK}/issue.21.title"
echo "" > "${WORK}/issue.21.body"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 21 --session-prs "50" --cursor-file "$CURSOR_1420" 2>&1)"
assert_contains "$out" "next_available_version=4.39.0" "repro: the next dispatch reclaims 4.39.0 instead of leaking to 4.40.0"
assert_contains "$out" "reclaimed_slot=4.39.0" "repro: the reclaim is reported on its own output line"
assert_contains "$(cat "$CURSOR_1420")" "4.39.0" "repro: the cursor is never lowered by the reclaim"

# The hole is consumed — a third dispatch advances normally rather than
# handing 4.39.0 out twice.
echo "feat(do-work): the third dispatch" > "${WORK}/issue.22.title"
echo "" > "${WORK}/issue.22.body"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 22 --session-prs "50" --cursor-file "$CURSOR_1420" 2>&1)"
assert_contains "$out" "next_available_version=4.40.0" "a consumed hole is never handed out twice"
assert_contains "$out" "reclaimed_slot=" "no reclaim reported once the hole is consumed"

# --------------------------------------------------------------------------
echo
echo "release + compute — a NON-top release does not disturb batch monotonicity (#437/#1420)"
# --------------------------------------------------------------------------
# The general case the decision comment calls out: slot 4.48.0 is declined
# while 4.49.0 / 4.50.0 are already promised to later batch members whose
# PRs do not exist yet. Naively decrementing the cursor would hand 4.49.0
# back out and collide with a live promise; recording the hole cannot.
b64_version "4.47.0" > "${WORK}/manifest.main.b64"
CURSOR_BATCH="${WORK}/cursor-batch"
rm -f "$CURSOR_BATCH" "${CURSOR_BATCH}.holes"
for slot in 60 61 62; do
  echo "feat(do-work): batch slot $slot" > "${WORK}/issue.${slot}.title"
  echo "" > "${WORK}/issue.${slot}.body"
  GH="$GH_MOCK" bash "$script" compute \
    --repo o/r --manifest plugin.json --version-jq .version \
    --default-branch main --issue "$slot" --cursor-file "$CURSOR_BATCH" >/dev/null 2>&1
done
assert_contains "$(cat "$CURSOR_BATCH")" "4.50.0" "batch of 3 hands out 4.48.0 / 4.49.0 / 4.50.0 monotonically"

# The FIRST batch member (4.48.0 — not the top) declines.
out="$(bash "$script" release --version "4.48.0" --cursor-file "$CURSOR_BATCH" 2>&1)"
assert_contains "$out" "release=recorded-hole" "a non-top release is recorded as a hole"
assert_contains "$(cat "$CURSOR_BATCH")" "4.50.0" "a non-top release leaves the cursor at the batch top — 4.49.0/4.50.0 stay promised"

# The replacement dispatch reclaims 4.48.0 — never 4.49.0 or 4.51.0.
echo "feat(do-work): the replacement dispatch" > "${WORK}/issue.63.title"
echo "" > "${WORK}/issue.63.body"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 63 --cursor-file "$CURSOR_BATCH" 2>&1)"
assert_contains "$out" "next_available_version=4.48.0" "the replacement dispatch reclaims the declined 4.48.0 slot"
assert_contains "$(cat "$CURSOR_BATCH")" "4.50.0" "reclaiming a non-top hole still leaves the cursor at 4.50.0"

# --------------------------------------------------------------------------
echo
echo "compute — a hole already claimed by ground truth is pruned, never reused (#1420)"
# --------------------------------------------------------------------------
# Safety bound: a hole at or below the floor derived from origin's manifest
# plus the open-PR walk has been claimed in the meantime and must never be
# handed back out.
b64_version "4.52.0" > "${WORK}/manifest.main.b64"
CURSOR_STALEHOLE="${WORK}/cursor-stalehole"
printf '%s' "4.52.0" > "$CURSOR_STALEHOLE"
printf '%s\n' "4.48.0" > "${CURSOR_STALEHOLE}.holes"
echo "fix(do-work): after the hole was claimed on main" > "${WORK}/issue.70.title"
echo "" > "${WORK}/issue.70.body"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 70 --cursor-file "$CURSOR_STALEHOLE" 2>&1)"
assert_contains "$out" "next_available_version=4.52.1" "a hole below the ground-truth floor is never reused"
assert_contains "$out" "reclaimed_slot=" "no reclaim reported for a stale hole"
if [[ -f "${CURSOR_STALEHOLE}.holes" ]]; then
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "the stale hole is pruned from the holes file"; fail=$((fail+1))
else
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "the stale hole is pruned from the holes file"; pass=$((pass+1))
fi

# --------------------------------------------------------------------------
echo
echo "compute — a hole ABOVE the slot we would otherwise hand out is never used (#1420)"
# --------------------------------------------------------------------------
# Reclaiming may only ever LOWER the number compute emits, never inflate it
# past the raise-only contract's own prediction. `release` already refuses to
# record a version above the cursor, so this bound is defensive — it only
# matters for a hand-edited holes file — but it is what guarantees the
# reclaim path can never hand out a slot the base computation wouldn't have
# reached. A below-floor hole is pruned; an above-base one is RETAINED.
b64_version "1.0.0" > "${WORK}/manifest.main.b64"
CURSOR_HIGH="${WORK}/cursor-high"
printf '%s' "1.5.0" > "$CURSOR_HIGH"
printf '%s\n' "2.0.0" > "${CURSOR_HIGH}.holes"
echo "fix: a patch-level issue" > "${WORK}/issue.80.title"
echo "" > "${WORK}/issue.80.body"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 80 --cursor-file "$CURSOR_HIGH" 2>&1)"
assert_contains "$out" "next_available_version=1.5.1" "a hole above the base bump does not inflate this call"
assert_contains "$out" "reclaimed_slot=" "no reclaim reported when the only hole is above the base bump"
assert_contains "$(cat "${CURSOR_HIGH}.holes" 2>/dev/null)" "2.0.0" "an above-base hole is retained, not pruned"

# --------------------------------------------------------------------------
echo
echo "compute — holes file absent: byte-for-byte pre-#1420 behavior"
# --------------------------------------------------------------------------
# The overwhelmingly common case, and the one that keeps every pinned
# cursor/batch-monotonicity assertion above meaningful: with no holes file,
# the reclaim path is inert and the cursor write is the same unconditional
# advance it always was.
b64_version "3.1.0" > "${WORK}/manifest.main.b64"
CURSOR_INERT="${WORK}/cursor-inert"
rm -f "$CURSOR_INERT" "${CURSOR_INERT}.holes"
echo "feat: no holes anywhere" > "${WORK}/issue.90.title"
echo "" > "${WORK}/issue.90.body"
out="$(GH="$GH_MOCK" bash "$script" compute \
  --repo o/r --manifest plugin.json --version-jq .version \
  --default-branch main --issue 90 --cursor-file "$CURSOR_INERT" 2>&1)"
assert_contains "$out" "next_available_version=3.2.0" "no holes file: the base bump is handed out unchanged"
assert_contains "$out" "reclaimed_slot=" "no holes file: reclaimed_slot is empty"
assert_contains "$(cat "$CURSOR_INERT")" "3.2.0" "no holes file: the cursor advances to the value handed out"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

#!/usr/bin/env bash
# Test: scripts/watch-resume-probe.sh — poll the environmental condition
# behind a `paused_on_environment` session-wide pause to a terminal state
# (resumed / held-timeout / error) and emit exactly one stdout line
# describing it (issue #1402).
#
# Background
# ----------
# steady-state.md's "Session-wide environmental pause" section arms a
# background `Monitor` watch instead of ending a turn with nothing further
# scheduled, whenever CI queue-depth backpressure holds a slot AND no
# worker remains in flight to trigger a future retry. A maintainer applying
# this issue found that the worktree-isolation guard refuses a `Monitor`
# command carrying an inline poll loop on the identical grounds it refuses
# an equivalent `Bash` block — this script is the extract-to-a-script fix,
# mirroring watch-pr-terminal.sh's precedent for the identical refusal
# class (issue #1326).
#
# This test exercises the script directly against a fully mocked `gh`
# binary on PATH — no network, no real repo. Run with:
#
#   bash plugins/shipyard/scripts/tests/watch-resume-probe.test.sh

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
pass=0
fail=0

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../watch-resume-probe.sh"

echo "watch-resume-probe.sh tests (issue #1402)"
echo

if [[ ! -x "$script" ]]; then
  bad "script exists and is executable ($script)"
  echo
  printf '%sFAIL%s  1 test(s) failed (0 passed)\n' "$RED" "$RESET" >&2
  exit 1
fi
ok "script exists and is executable"

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$label (got [$actual])"
  else
    bad "$label (expected [$expected], got [$actual])"
  fi
}

assert_contains_line() {
  local label="$1" haystack="$2" needle="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    ok "$label"
  else
    bad "$label"
    printf '    expected stdout to contain: %s\n    got: %s\n' "$needle" "$haystack"
  fi
}

# Matches the stdout line's fixed structure while tolerating the `elapsed=Ns`
# field varying by a second or two, same rationale as watch-pr-terminal's
# own assert_matches (process-spawn overhead across the gh/jq/detector calls
# makes an exact `elapsed=0s` match flaky on a loaded CI runner).
assert_matches() {
  local label="$1" expected_pattern="$2" actual="$3"
  if [[ "$actual" =~ $expected_pattern ]]; then
    ok "$label (got [$actual])"
  else
    bad "$label (expected to match [$expected_pattern], got [$actual])"
  fi
}

# ---------------------------------------------------------------------------
# (A) --help — prints usage, exit 4, no gh required.
# ---------------------------------------------------------------------------
echo "(A) --help"
help_out="$(PATH="/usr/bin:/bin" bash "$script" --help 2>&1)"
help_exit=$?
assert_equals "--help exit code" "4" "$help_exit"
assert_contains_line "--help documents --repo/--pool-total as required" "$help_out" "--pool-total <N>"
echo

# ---------------------------------------------------------------------------
# (B) Usage errors — missing/invalid arguments never touch gh at all.
# ---------------------------------------------------------------------------
echo "(B) usage errors (no PATH tools needed — argument parsing fails first)"

out="$(PATH="/usr/bin:/bin" bash "$script" --pool-total 4 2>&1)"
code=$?
assert_equals "missing --repo: exit code" "4" "$code"
assert_contains_line "missing --repo: names the missing flags" "$out" "--repo and --pool-total are both required"

out="$(PATH="/usr/bin:/bin" bash "$script" --repo owner/repo 2>&1)"
code=$?
assert_equals "missing --pool-total: exit code" "4" "$code"

out="$(PATH="/usr/bin:/bin" bash "$script" --repo owner/repo --pool-total abc 2>&1)"
code=$?
assert_equals "non-numeric --pool-total: exit code" "4" "$code"
assert_contains_line "non-numeric --pool-total: diagnostic names the bad value" "$out" "must be a positive integer"

out="$(PATH="/usr/bin:/bin" bash "$script" --repo owner/repo --pool-total 0 2>&1)"
code=$?
assert_equals "zero --pool-total: exit code" "4" "$code"
assert_contains_line "zero --pool-total: diagnostic explains why" "$out" "must be > 0"

out="$(PATH="/usr/bin:/bin" bash "$script" --repo owner/repo --pool-total 4 --multiplier nope 2>&1)"
code=$?
assert_equals "non-numeric --multiplier: exit code" "4" "$code"

out="$(PATH="/usr/bin:/bin" bash "$script" --repo owner/repo --pool-total 4 --interval nope 2>&1)"
code=$?
assert_equals "non-numeric --interval: exit code" "4" "$code"

out="$(PATH="/usr/bin:/bin" bash "$script" --repo owner/repo --pool-total 4 --max-wait -1 2>&1)"
code=$?
assert_equals "negative --max-wait: exit code" "4" "$code"
echo

# ---------------------------------------------------------------------------
# (C) gh CLI missing from PATH -> error terminal state, not a crash.
#
# Same portability caveat as watch-pr-terminal.test.sh's identical section:
# build the test PATH from the REAL $PATH with every gh-containing directory
# filtered out, so standard utilities stay reachable but gh specifically
# never resolves — a hardcoded "/usr/bin:/bin" is not portable across hosts
# that ship gh there already (e.g. some GitHub Actions runner images).
# ---------------------------------------------------------------------------
echo "(C) gh CLI not on PATH"
bash_path="$(command -v bash)"
emptybin="$(mktemp -d)"
no_gh_path="$emptybin"
IFS=':' read -r -a path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  [[ -n "$d" && -x "$d/gh" ]] && continue
  no_gh_path="$no_gh_path:$d"
done
out="$(PATH="$no_gh_path" "$bash_path" "$script" --repo owner/repo --pool-total 4 2>&1)"
code=$?
rm -rf "$emptybin"
assert_equals "gh missing: exit code" "4" "$code"
assert_contains_line "gh missing: stdout names the reason" "$out" 'watch-resume-probe: error pool_total=4 reason="gh CLI not found on PATH"'
echo

# ---------------------------------------------------------------------------
# Helper: build a fake `gh` on a throwaway PATH directory that always
# returns a fixed `gh run list --status queued` JSON payload (an array of N
# entries — this script only counts them via jq, never reads their fields).
# ---------------------------------------------------------------------------
make_fake_gh_queued() {
  local dir="$1" count="$2"
  local json
  json="$(awk -v n="$count" 'BEGIN{printf "["; for(i=0;i<n;i++){printf "%s{\"databaseId\":%d}", (i>0?",":""), i}; print "]"}')"
  cat > "$dir/gh" <<FAKEGH
#!/usr/bin/env bash
if [[ "\$1" == "run" && "\$2" == "list" ]]; then
  cat <<'QUEUEDJSON'
$json
QUEUEDJSON
  exit 0
fi
exit 1
FAKEGH
  chmod +x "$dir/gh"
}

# ---------------------------------------------------------------------------
# (D) Resumed — queued count under threshold -> exit 0, one "resumed" line.
#     pool_total=4, multiplier=5 -> threshold=20; queued=2 is well under it.
# ---------------------------------------------------------------------------
echo "(D) resumed (queued under threshold)"
fakebin="$(mktemp -d)"
make_fake_gh_queued "$fakebin" 2
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --repo owner/repo --pool-total 4 --multiplier 5 --interval 1 --max-wait 5 2>/dev/null)"
code=$?
rm -rf "$fakebin"
assert_equals "resumed: exit code" "0" "$code"
assert_matches "resumed: stdout" '^watch-resume-probe: resumed pool_total=4 queued=2 threshold=20 elapsed=[0-9]+s$' "$out"
echo

# ---------------------------------------------------------------------------
# (E) Held-timeout — queued count over threshold, max-wait 0 forces exactly
#     one poll then a timeout line. pool_total=4, multiplier=5 -> threshold
#     20; queued=100 is well over it.
# ---------------------------------------------------------------------------
echo "(E) held-timeout (queued over threshold, max-wait 0 — exactly one poll)"
fakebin="$(mktemp -d)"
make_fake_gh_queued "$fakebin" 100
start_ts=$(date +%s)
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --repo owner/repo --pool-total 4 --multiplier 5 --interval 60 --max-wait 0 2>/dev/null)"
code=$?
end_ts=$(date +%s)
rm -rf "$fakebin"
assert_equals "held-timeout: exit code" "1" "$code"
assert_matches "held-timeout: stdout" '^watch-resume-probe: held-timeout pool_total=4 queued=100 threshold=20 elapsed=[0-9]+s max_wait=0s$' "$out"
elapsed_wall=$((end_ts - start_ts))
if [[ "$elapsed_wall" -lt 5 ]]; then
  ok "held-timeout: returned quickly (${elapsed_wall}s) — never slept despite --interval 60"
else
  bad "held-timeout: took ${elapsed_wall}s — should return near-instantly with max-wait 0"
fi
echo

# ---------------------------------------------------------------------------
# (F) gh transient failure then recovery — a single failed poll is retried,
#     not treated as terminal (mirrors watch-pr-terminal's identical case).
# ---------------------------------------------------------------------------
echo "(F) gh fails once, then succeeds — retried, not fatal"
fakebin="$(mktemp -d)"
counter_file="$fakebin/count"
echo 0 > "$counter_file"
cat > "$fakebin/gh" <<FAKEGH
#!/usr/bin/env bash
if [[ "\$1" == "run" && "\$2" == "list" ]]; then
  n=\$(cat "$counter_file")
  n=\$((n + 1))
  echo "\$n" > "$counter_file"
  if [[ "\$n" -eq 1 ]]; then
    echo "some transient API error" >&2
    exit 1
  fi
  echo '[{"databaseId":1}]'
  exit 0
fi
exit 1
FAKEGH
chmod +x "$fakebin/gh"
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --repo owner/repo --pool-total 4 --multiplier 5 --interval 1 --max-wait 10 2>/dev/null)"
code=$?
rm -rf "$fakebin"
assert_equals "transient-then-recover: exit code" "0" "$code"
assert_matches "transient-then-recover: stdout" '^watch-resume-probe: resumed pool_total=4 queued=1 threshold=20 elapsed=[0-9]+s$' "$out"
echo

# ---------------------------------------------------------------------------
# (G) gh fails 3 consecutive times -> error terminal state (exit 4).
# ---------------------------------------------------------------------------
echo "(G) gh fails 3 consecutive times — error terminal state"
fakebin="$(mktemp -d)"
cat > "$fakebin/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [[ "$1" == "run" && "$2" == "list" ]]; then
  echo "persistent API failure" >&2
  exit 1
fi
exit 1
FAKEGH
chmod +x "$fakebin/gh"
out="$(PATH="$fakebin:/usr/bin:/bin" bash "$script" --repo owner/repo --pool-total 4 --multiplier 5 --interval 0 --max-wait 60 2>/dev/null)"
code=$?
rm -rf "$fakebin"
assert_equals "3x-fail: exit code" "4" "$code"
assert_contains_line "3x-fail: stdout names the error reason" "$out" 'watch-resume-probe: error pool_total=4 reason='
assert_contains_line "3x-fail: never silent — a terminal line is always emitted, per the header comment's contract" "$out" "watch-resume-probe:"
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1

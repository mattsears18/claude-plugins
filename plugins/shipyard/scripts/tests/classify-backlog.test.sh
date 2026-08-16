#!/usr/bin/env bash
# Test suite for scripts/classify-backlog.sh (issue #1398) — the extraction
# of setup/04-backlog-divert.md step 4's classify invocation into a single
# plain command, mirroring the stale-check-refresh.sh / next-available-
# version.sh / pre-dispatch-branch-reap.sh / concurrent-session-guard.sh
# extraction precedent (#1289).
#
# Covers:
#   usage / arg validation      — missing --repo/--me/--trusted-authors/
#                                  --issues-file; unknown subcommand
#   --issues-file missing       — exits 66
#   run — end to end            — config reads resolve to their documented
#                                  defaults/fallbacks with no repo config
#                                  present; the classify NDJSON reflects an
#                                  eligible issue and an untrusted-author
#                                  drop; --out writes to a file instead of
#                                  stdout
#
# `backlog-filter.sh`'s own `closed-by-healthy-pr` / `closed-by-open-pr`
# subcommands call the literal `gh` binary directly (not an overridable $GH
# variable), so this suite mocks `gh` via a PATH-prepended stub directory —
# the same pattern eval-recheck-probe.test.sh uses for its own live-`gh`
# coverage — rather than the $GH-env-var mocking stale-check-refresh.test.sh
# uses for a script that reads $GH itself. `SHIPYARD_REPO_ROOT` is pinned to
# an empty tmp dir for every invocation so the five internal config reads
# resolve against shipyard-config.sh's built-in defaults only, never this
# repo's own committed shipyard.config.json.
#
# Pure bash + jq + a stub gh. Run with:
#   bash plugins/shipyard/scripts/tests/classify-backlog.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../classify-backlog.sh"

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

# Empty repo-config root — no shipyard.config.json exists here, so every
# internal shipyard-config.sh read resolves to its built-in default (or, for
# the one key with no built-in default at all — triage.investigate_dispatch
# — this script's own documented fallback).
CONFIG_ROOT="${WORK}/config-root"
mkdir -p "$CONFIG_ROOT"

# --- Mock gh: both backlog-filter.sh subcommands classify-backlog.sh
# delegates to (closed-by-healthy-pr, closed-by-open-pr) call the literal
# `gh` binary directly, so this must be a PATH-prepended stub, not a $GH
# override.
TMP_BIN="${WORK}/bin"
mkdir -p "$TMP_BIN"
cat > "${TMP_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
# Both closed-by-healthy-pr and closed-by-open-pr call `gh pr list --repo
# ... --state open --author ... --limit 200 --json ...` — an empty PR list
# is a valid, realistic response (no open PRs authored by --me) and keeps
# both subcommands' downstream jq producing an empty CSV / {} respectively.
if [ "$1 $2" = "pr list" ]; then
  echo "[]"
  exit 0
fi
exit 0
MOCK
chmod +x "${TMP_BIN}/gh"

FIXTURES="${WORK}/fixtures.json"
cat > "$FIXTURES" <<'EOF'
[
  {"number": 100, "title": "fix: tighten the widget", "body": "no do-work-recheck marker here", "labels": [], "assignees": [], "author": {"login": "alice"}, "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "milestone": null},
  {"number": 101, "title": "fix: from a stranger", "body": "plain body", "labels": [], "assignees": [], "author": {"login": "mallory"}, "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "milestone": null}
]
EOF

run_script() {
  SHIPYARD_REPO_ROOT="$CONFIG_ROOT" PATH="${TMP_BIN}:${PATH}" bash "$script" "$@"
}

echo "classify-backlog.sh test suite"
echo "==============================="

# --------------------------------------------------------------------------
echo
echo "usage / arg validation"
# --------------------------------------------------------------------------
out="$(run_script run --repo o/r 2>&1)"; rc=$?
assert_contains "$out" "required" "run without --me/--trusted-authors/--issues-file errors"
assert_exit "$rc" "64" "missing required args exits 64"

out="$(run_script bogus-subcommand 2>&1)"; rc=$?
assert_contains "$out" "unknown subcommand" "unknown subcommand is rejected"
assert_exit "$rc" "64" "unknown subcommand exits 64"

out="$(run_script run --repo o/r --me alice --trusted-authors alice --issues-file "${WORK}/does-not-exist.json" 2>&1)"; rc=$?
assert_contains "$out" "not found or unreadable" "missing --issues-file errors"
assert_exit "$rc" "66" "missing --issues-file exits 66"

# --------------------------------------------------------------------------
echo
echo "run — end to end (no repo config present; defaults/fallbacks apply)"
# --------------------------------------------------------------------------
out="$(run_script run --repo o/r --me alice --trusted-authors alice --issues-file "$FIXTURES" 2>&1)"
rc=$?
assert_exit "$rc" "0" "run against the fixture exits 0"

eligible_100=$(printf '%s' "$out" | jq -c 'select(.number == 100)')
assert_contains "$eligible_100" '"verdict":"eligible"' "trusted-author issue #100 is eligible"

drop_101=$(printf '%s' "$out" | jq -c 'select(.number == 101)')
assert_contains "$drop_101" '"reason":"untrusted-author"' "untrusted-author issue #101 is dropped"

# --------------------------------------------------------------------------
echo
echo "run — --out writes the NDJSON to a file instead of stdout"
# --------------------------------------------------------------------------
OUT_FILE="${WORK}/classified.ndjson"
stdout_capture="$(run_script run --repo o/r --me alice --trusted-authors alice --issues-file "$FIXTURES" --out "$OUT_FILE" 2>&1)"
rc=$?
assert_exit "$rc" "0" "run with --out exits 0"
if [[ -s "$OUT_FILE" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "--out file is non-empty"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "--out file is non-empty"; fail=$((fail+1))
fi
file_contents="$(cat "$OUT_FILE" 2>/dev/null)"
assert_contains "$file_contents" '"number":100' "--out file carries the classify NDJSON"
if [[ -z "$stdout_capture" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "--out suppresses stdout output"; pass=$((pass+1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "--out suppresses stdout output"
  printf '    unexpected stdout: %s\n' "$stdout_capture" | head -c 300; printf '\n'
  fail=$((fail+1))
fi

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

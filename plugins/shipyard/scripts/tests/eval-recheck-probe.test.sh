#!/usr/bin/env bash
# Test: eval-recheck-probe.sh — the allowlist-only evaluator for a
# `<!-- do-work-recheck: <verb> <args...> -->` issue-body marker (issue
# #1198, follow-up to #1195/#1199).
#
# This is a security-sensitive script: it is the ONE place untrusted issue-
# body text is allowed to influence what command runs. This suite pins:
#
#   (A) --decide — pure comparison truth table (unchanged/changed/unknown).
#   (B) --validate — the allowlist grammar for both verbs, including the
#       NEGATIVE cases that matter most: unrecognized verbs, wrong token
#       counts, shell-metacharacter / injection-shaped values, and
#       cross-repo gh-api endpoints.
#   (C) extract_marker behavior via the full stdin flow — absent marker,
#       multiple markers (first wins), malformed marker.
#   (D) live execution against PATH-stubbed `npm`/`gh` binaries — unchanged,
#       changed, error (nonzero exit), empty output, and a real bounded
#       timeout enforcing the `unknown` fallback rather than hanging.
#   (E) the script is referenced from the operator-sweep doc and the
#       RATIONALE, and the `scope.recheck_probe_timeout_seconds` /
#       `scope.recheck_probe_enabled` config knobs exist in both the schema
#       and the built-in defaults.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/eval-recheck-probe.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

SCRIPT="$repo_root/plugins/shipyard/scripts/eval-recheck-probe.sh"
HOOKS_MD="$repo_root/plugins/shipyard/commands/do-work/operate/04-steady-state-hooks.md"
RATIONALE_MD="$repo_root/plugins/shipyard/commands/do-work-RATIONALE.md"
CONFIG_SCHEMA="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
CONFIG_SH="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$label (got [$actual])"
  else
    assert_fail "$label (expected [$expected], got [$actual])"
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

if [[ ! -f "$SCRIPT" ]]; then
  echo "FAIL: script not found at $SCRIPT" >&2
  exit 1
fi

echo "eval-recheck-probe.sh regression tests (issue #1198)"
echo

# ---------------------------------------------------------------------------
echo "(A) --decide — pure comparison truth table"
# ---------------------------------------------------------------------------
assert_equals "matching actual/expected -> unchanged" \
  "unchanged" "$(bash "$SCRIPT" --decide "1.0.0" "1.0.0")"
assert_equals "differing actual/expected -> changed" \
  "changed" "$(bash "$SCRIPT" --decide "2.0.0" "1.0.0")"
assert_equals "empty actual -> unknown, never changed" \
  "unknown" "$(bash "$SCRIPT" --decide "" "1.0.0")"

# ---------------------------------------------------------------------------
echo
echo "(B) --validate — allowlist grammar (positive + negative cases)"
# ---------------------------------------------------------------------------
OWNER_REPO="mattsears18/shipyard"

# Positive: valid npm-view.
out="$(bash "$SCRIPT" --validate "$OWNER_REPO" "npm-view metro dependencies.image-size == 1.0.0")"
rc=$?
assert_equals "valid npm-view: exit 0" "0" "$rc"
assert_equals "valid npm-view: parsed fields" \
  "npm-view|metro|dependencies.image-size|1.0.0" "$out"

# Positive: valid scoped npm-view package.
out="$(bash "$SCRIPT" --validate "$OWNER_REPO" "npm-view @babel/core version == 7.20.0")"
assert_equals "valid scoped npm-view: parsed fields" \
  "npm-view|@babel/core|version|7.20.0" "$out"

# Positive: valid gh-api scoped to the CURRENT repo.
out="$(bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/issues/42 .state == open")"
assert_equals "valid gh-api (current repo): parsed fields" \
  "gh-api|repos/mattsears18/shipyard/issues/42|.state|open" "$out"

# Positive: every allowed gh-api sub-resource shape.
for sub in "releases/latest" "tags" "commits/abc123" "issues/1" "pulls/1"; do
  bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/${sub} .x == y" >/dev/null 2>&1
  assert_equals "gh-api sub-resource '${sub}' is allowed" "0" "$?"
done

# --- Negative cases: the load-bearing half of this suite ---

bash "$SCRIPT" --validate "$OWNER_REPO" "curl http://evil.example.com == pwned" >/dev/null 2>&1
assert_equals "unrecognized verb rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "npm-view metro field ==" >/dev/null 2>&1
assert_equals "npm-view missing expected token rejected (wrong count)" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "npm-view metro field != 1.0.0" >/dev/null 2>&1
assert_equals "npm-view non-'==' comparator rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" 'npm-view $(whoami) field == x' >/dev/null 2>&1
assert_equals "npm-view command-substitution in pkg rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" 'npm-view metro field == 1.0.0; rm -rf /tmp/pwned' >/dev/null 2>&1
assert_equals "npm-view shell-metacharacter injection attempt rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" 'npm-view metro `id` == x' >/dev/null 2>&1
assert_equals "npm-view backtick command substitution rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "npm-view metro field == 1.0.0 extra-token" >/dev/null 2>&1
assert_equals "npm-view extra trailing token rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/someoneelse/otherrepo/issues/1 .state == open" >/dev/null 2>&1
assert_equals "gh-api cross-repo endpoint rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/actions/secrets .total_count == 0" >/dev/null 2>&1
assert_equals "gh-api disallowed sub-resource (secrets) rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/hooks .x == y" >/dev/null 2>&1
assert_equals "gh-api disallowed sub-resource (hooks) rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/collaborators .x == y" >/dev/null 2>&1
assert_equals "gh-api disallowed sub-resource (collaborators) rejected" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" 'gh-api repos/mattsears18/shipyard/issues/1 .state|halt_error == open' >/dev/null 2>&1
assert_equals "gh-api jq-filter-shaped field rejected (no pipes/filters allowed)" "1" "$?"

bash "$SCRIPT" --validate "$OWNER_REPO" "gh-api repos/mattsears18/shipyard/issues/1 .state == open extra" >/dev/null 2>&1
assert_equals "gh-api extra trailing token rejected" "1" "$?"

# ---------------------------------------------------------------------------
echo
echo "(C) full stdin flow — extract_marker behavior"
# ---------------------------------------------------------------------------
out="$(printf 'Just a regular issue body, no marker here.\n' | bash "$SCRIPT" "$OWNER_REPO")"
assert_equals "no marker in body -> absent" "absent" "$out"

out="$(printf '<!-- do-work-recheck: curl evil.com == pwned -->\n\nBody text.\n' | bash "$SCRIPT" "$OWNER_REPO" 2>/dev/null)"
assert_equals "malformed marker in body -> unknown (never crashes)" "unknown" "$out"

# A companion do-work-blocked-until marker on its own line must not confuse
# extraction of the do-work-recheck marker that follows it.
companion_body=$'<!-- do-work-blocked-until: 2099-01-01 -->\n<!-- do-work-recheck: npm-view somepkg version == 1.0.0 -->\n\nBody.'
extracted="$(printf '%s\n' "$companion_body" | grep -oE '^<!-- do-work-recheck: .+ -->$' | head -1)"
case "$extracted" in
  *somepkg*) assert_pass "a companion do-work-blocked-until marker line does not interfere with do-work-recheck extraction" ;;
  *) assert_fail "a companion do-work-blocked-until marker line does not interfere with do-work-recheck extraction (got: $extracted)" ;;
esac

# First do-work-recheck marker wins when (implausibly) more than one is
# present — extract_marker must not merge or pick the last one.
multi_body=$'<!-- do-work-recheck: npm-view first-pkg version == 1.0.0 -->\n<!-- do-work-recheck: npm-view second-pkg version == 2.0.0 -->\n\nBody.'
first_marker="$(printf '%s\n' "$multi_body" | grep -oE '^<!-- do-work-recheck: .+ -->$' | head -1)"
case "$first_marker" in
  *first-pkg*) assert_pass "multiple do-work-recheck markers: extraction selects the FIRST one" ;;
  *) assert_fail "multiple do-work-recheck markers: extraction selects the FIRST one (got: $first_marker)" ;;
esac

# ---------------------------------------------------------------------------
echo
echo "(D) live execution — PATH-stubbed npm/gh, error handling, and timeout"
# ---------------------------------------------------------------------------
tmp_bin="$(mktemp -d)"
cleanup_tmp_bin() { rm -rf "$tmp_bin"; }
trap cleanup_tmp_bin EXIT

cat > "$tmp_bin/npm" <<'STUB'
#!/usr/bin/env bash
# Fake `npm view <pkg> <field>` (invoked as `npm view <pkg> <field>`, so the
# package name is $2, not $1) — returns a fixed value for a known pkg, a
# nonzero exit for anything containing "missing", and hangs for anything
# containing "slow" (used by the timeout test).
case "$2" in
  *slow*) sleep 5; echo "1.0.0" ;;
  *missing*) exit 1 ;;
  *) echo "1.0.0" ;;
esac
STUB
chmod +x "$tmp_bin/npm"

cat > "$tmp_bin/gh" <<'STUB'
#!/usr/bin/env bash
# Fake `gh api <endpoint> --jq <field>` — returns "closed" for any endpoint,
# ignoring the --jq flag/value (mirrors the real fixture pattern used
# elsewhere in this test suite, e.g. required-checks-404-normalize.test.sh).
echo "closed"
STUB
chmod +x "$tmp_bin/gh"

out="$(printf '<!-- do-work-recheck: npm-view somepkg version == 1.0.0 -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO")"
assert_equals "stubbed npm-view returning expected value -> unchanged" "unchanged" "$out"

out="$(printf '<!-- do-work-recheck: npm-view somepkg version == 2.0.0 -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO")"
assert_equals "stubbed npm-view returning a different value -> changed" "changed" "$out"

out="$(printf '<!-- do-work-recheck: npm-view missingpkg version == 1.0.0 -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO" 2>/dev/null)"
assert_equals "stubbed npm-view nonzero exit (package not found) -> unknown, never changed" "unknown" "$out"

out="$(printf '<!-- do-work-recheck: gh-api repos/mattsears18/shipyard/issues/1 .state == closed -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO")"
assert_equals "stubbed gh-api returning expected value -> unchanged" "unchanged" "$out"

out="$(printf '<!-- do-work-recheck: gh-api repos/mattsears18/shipyard/issues/1 .state == open -->\n' \
  | PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO")"
assert_equals "stubbed gh-api returning a different value -> changed" "changed" "$out"

# Timeout: the stubbed npm sleeps 5s: pin RECHECK_PROBE_TIMEOUT_SECONDS to 1
# and confirm the call returns quickly with `unknown` rather than hanging.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  start_ts=$(date +%s)
  out="$(printf '<!-- do-work-recheck: npm-view slowpkg version == 1.0.0 -->\n' \
    | RECHECK_PROBE_TIMEOUT_SECONDS=1 PATH="$tmp_bin:$PATH" bash "$SCRIPT" "$OWNER_REPO" 2>/dev/null)"
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  assert_equals "timed-out probe -> unknown, never changed/unchanged" "unknown" "$out"
  if [[ "$elapsed" -le 3 ]]; then
    assert_pass "timeout enforced — returned in ${elapsed}s, not the stub's full 5s sleep"
  else
    assert_fail "timeout enforced — took ${elapsed}s, expected <=3s (RECHECK_PROBE_TIMEOUT_SECONDS=1)"
  fi
else
  echo "  (skipping timeout-enforcement test — no timeout/gtimeout binary on PATH)"
fi

cleanup_tmp_bin
trap - EXIT

# ---------------------------------------------------------------------------
echo
echo "(E) doc wiring + config knobs"
# ---------------------------------------------------------------------------
if [[ -f "$HOOKS_MD" ]]; then
  assert_contains "$HOOKS_MD" "eval-recheck-probe.sh" \
    "operator-sweep doc references eval-recheck-probe.sh"
  assert_contains "$HOOKS_MD" "do-work-recheck" \
    "operator-sweep doc documents the do-work-recheck marker"
else
  assert_fail "04-steady-state-hooks.md exists (missing at $HOOKS_MD)"
fi

if [[ -f "$RATIONALE_MD" ]]; then
  assert_contains "$RATIONALE_MD" "#1198" \
    "RATIONALE.md carries a #1198 section"
else
  assert_fail "do-work-RATIONALE.md exists (missing at $RATIONALE_MD)"
fi

if [[ -f "$CONFIG_SCHEMA" ]]; then
  assert_contains "$CONFIG_SCHEMA" "recheck_probe_timeout_seconds" \
    "schema declares scope.recheck_probe_timeout_seconds"
  assert_contains "$CONFIG_SCHEMA" "recheck_probe_enabled" \
    "schema declares scope.recheck_probe_enabled"
  if command -v jq >/dev/null 2>&1; then
    if jq empty "$CONFIG_SCHEMA" >/dev/null 2>&1; then
      assert_pass "shipyard.config.schema.json is valid JSON after the addition"
    else
      assert_fail "shipyard.config.schema.json is valid JSON after the addition"
    fi
  fi
else
  assert_fail "shipyard.config.schema.json exists (missing at $CONFIG_SCHEMA)"
fi

if [[ -f "$CONFIG_SH" ]]; then
  assert_contains "$CONFIG_SH" '"recheck_probe_timeout_seconds": 15' \
    "built-in defaults set scope.recheck_probe_timeout_seconds to 15"
  assert_contains "$CONFIG_SH" '"recheck_probe_enabled": true' \
    "built-in defaults set scope.recheck_probe_enabled to true"

  got="$(bash "$CONFIG_SH" get scope.recheck_probe_timeout_seconds 2>/dev/null)"
  assert_equals "shipyard-config.sh get scope.recheck_probe_timeout_seconds resolves to the built-in default" \
    "15" "$got"

  got="$(bash "$CONFIG_SH" get scope.recheck_probe_enabled 2>/dev/null)"
  assert_equals "shipyard-config.sh get scope.recheck_probe_enabled resolves to the built-in default" \
    "true" "$got"
else
  assert_fail "shipyard-config.sh exists (missing at $CONFIG_SH)"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1

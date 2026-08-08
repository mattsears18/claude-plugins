#!/usr/bin/env bash
# Test: the CI-gate-narrowing detector — refuse to leave auto-merge armed on
# a PR that narrows a required CI gate rather than fixing the underlying
# cause (issue #1139).
#
# Background — issue #1139
# -------------------------
# A `fix-main-ci` worker restored green `main` by adding a self-authored
# allowlist that permanently exempts three high-severity `npm audit`
# advisories from ever failing the gate, then armed auto-merge on that PR.
# The engineering was sound (fails closed on unknown shapes, justified
# per-GHSA) — the gap was that nothing in the spec required disarming
# auto-merge before a permanent, repo-wide weakening of a security gate
# landed with no human in the loop.
#
# This is a DIFFERENT risk class from the existing "Never disable a committed
# security or supply-chain control" rule (#1088): that rule catches a PR that
# had to disable/bypass an EXISTING control to pass CI. This one catches a PR
# that leaves the control nominally in place but narrows what it considers a
# failure — a self-authored allowlist, a raised severity threshold, a
# `continue-on-error: true`, a deleted gate step, or a narrowed trigger
# filter. Fixed the same way #1088/#598/#716 were: ONE executable detector
# script (`scripts/detect-ci-gate-narrowing.sh`), wired into the shared
# auto-merge fragment so every mode gets it for free, with an explicit
# `auto_merge: "unarmed-gate-narrowing"` structured outcome.
#
# This test pins:
#   (A) the detector script's decision truth table (pure `--decide` mode);
#   (B) the detector's diff-based signal extraction behaves correctly on
#       representative synthetic diffs (allowlist add, continue-on-error,
#       raised --audit-level, deleted step, narrowed paths-ignore, and a
#       negative control that must NOT trip);
#   (C) auto-merge.md wires the check in BEFORE any merge call, as its own
#       named step, distinct from the #1088 policy-override step;
#   (D) issue-work.md, fix-main-ci.md, and fix-failing-prs-batch.md all
#       reference the check and offer the `unarmed — gate-narrowing` return
#       line in their step-8 vocabulary;
#   (E) the schema carries the new `unarmed-gate-narrowing` auto_merge value
#       and the `gate_narrowing` field, with the required-when conditional;
#   (F) SKILL.md documents the rule as its own section, distinct from #1088.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/detect-ci-gate-narrowing.test.sh

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

DETECTOR="$repo_root/plugins/shipyard/scripts/detect-ci-gate-narrowing.sh"
AUTO_MERGE_MD="$repo_root/plugins/shipyard/skills/worker-preamble/auto-merge.md"
SKILL_MD="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"
ISSUE_WORK_MD="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
FIX_MAIN_CI_MD="$repo_root/plugins/shipyard/agents/issue-worker/fix-main-ci.md"
FIX_PR_BATCH_MD="$repo_root/plugins/shipyard/agents/issue-worker/fix-failing-prs-batch.md"
SCHEMA="$repo_root/plugins/shipyard/schemas/worker-return.schema.json"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

assert_equals() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$label (got [$actual])"
  else
    assert_fail "$label (expected [$expected], got [$actual])"
  fi
}

echo "CI-gate-narrowing detector regression tests (issue #1139)"
echo

# ---------------------------------------------------------------------------
# (A) decide() — pure decision truth table.
# ---------------------------------------------------------------------------
echo "(A) detector script — decision truth table"
if [[ -f "$DETECTOR" ]]; then
  assert_pass "detect-ci-gate-narrowing.sh exists"

  # decide <touches_workflow> <new_gate_file> <continue_on_error_added> <audit_level_lowered> <gate_step_deleted> <path_filter_narrowed> <expected> <label>
  assert_verdict() {
    local got
    got="$(bash "$DETECTOR" --decide "$1" "$2" "$3" "$4" "$5" "$6" 2>/dev/null)"
    assert_equals "$8" "$7" "$got"
  }

  # Nothing touches a gate surface at all => clean.
  assert_verdict 0 0 0 0 0 0 clean "no signals at all is clean"

  # Touches a workflow file but nothing permissive changed => clean (the
  # two-part test is load-bearing — an ordinary workflow tweak must not trip).
  assert_verdict 1 0 0 0 0 0 clean "workflow touched with no permissive signal is clean"

  # A brand-new allowlist file alone is both the gate surface AND the
  # permissive signal — the exact #1139 repro shape.
  assert_verdict 0 1 0 0 0 0 narrowing "new gate-file alone is narrowing (#1139 repro shape)"

  # continue-on-error added, but with no gate-surface touch recorded => clean
  # (should not happen in practice — continue-on-error only appears inside a
  # workflow file — but the two-part AND must hold regardless).
  assert_verdict 0 0 1 0 0 0 clean "permissive signal alone, no gate-surface touch, is clean"

  # Each permissive signal combined with a workflow touch => narrowing.
  assert_verdict 1 0 1 0 0 0 narrowing "workflow touch + continue-on-error added is narrowing"
  assert_verdict 1 0 0 1 0 0 narrowing "workflow touch + raised audit-level is narrowing"
  assert_verdict 1 0 0 0 1 0 narrowing "workflow touch + deleted gate step is narrowing"
  assert_verdict 1 0 0 0 0 1 narrowing "workflow touch + narrowed path filter is narrowing"

  # All signals firing at once is still just narrowing (no crash / no
  # unexpected third state).
  assert_verdict 1 1 1 1 1 1 narrowing "every signal firing at once is narrowing"
else
  assert_fail "detect-ci-gate-narrowing.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (B) Live signal-extraction functions against representative synthetic
#     diffs, sourced with the trailing `main "$@"` stripped off.
# ---------------------------------------------------------------------------
echo "(B) signal extraction — representative diffs"
if [[ -f "$DETECTOR" ]]; then
  tmp_src="$(mktemp)"
  sed '$d' "$DETECTOR" > "$tmp_src"
  # shellcheck disable=SC1090
  source "$tmp_src"
  rm -f "$tmp_src"

  diff_new_allowlist=$'diff --git a/.github/security/audit-allowlist.json b/.github/security/audit-allowlist.json\nnew file mode 100644\nindex 0000000..1234567\n--- /dev/null\n+++ b/.github/security/audit-allowlist.json\n@@ -0,0 +1,3 @@\n+{\n+  "GHSA-xxxx": "unfixable today"\n+}\n'
  diff_continue_on_error=$'diff --git a/.github/workflows/audit.yml b/.github/workflows/audit.yml\nindex abc..def 100644\n--- a/.github/workflows/audit.yml\n+++ b/.github/workflows/audit.yml\n@@ -10,6 +10,7 @@\n       - name: npm audit\n         run: npm audit --audit-level=high\n+        continue-on-error: true\n'
  diff_audit_level=$'diff --git a/.github/workflows/audit.yml b/.github/workflows/audit.yml\nindex abc..def 100644\n--- a/.github/workflows/audit.yml\n+++ b/.github/workflows/audit.yml\n@@ -10,1 +10,1 @@\n-        run: npm audit --audit-level=high\n+        run: npm audit --audit-level=low\n'
  diff_deleted_step=$'diff --git a/.github/workflows/audit.yml b/.github/workflows/audit.yml\nindex abc..def 100644\n--- a/.github/workflows/audit.yml\n+++ b/.github/workflows/audit.yml\n@@ -8,7 +8,3 @@\n-      - name: npm audit\n-        run: npm audit --audit-level=high\n'
  diff_path_filter=$'diff --git a/.github/workflows/audit.yml b/.github/workflows/audit.yml\nindex abc..def 100644\n--- a/.github/workflows/audit.yml\n+++ b/.github/workflows/audit.yml\n@@ -1,4 +1,6 @@\n on:\n   pull_request:\n+    paths-ignore:\n+      - "docs/**"\n'
  diff_unrelated=$'diff --git a/README.md b/README.md\nindex abc..def 100644\n--- a/README.md\n+++ b/README.md\n@@ -1,1 +1,1 @@\n-old\n+new\n'

  assert_equals "new-allowlist diff: new_gate_file=1" "1" "$(sig_new_gate_file "$diff_new_allowlist")"
  assert_equals "continue-on-error diff: touches_workflow=1" "1" "$(sig_touches_workflow "$diff_continue_on_error")"
  assert_equals "continue-on-error diff: continue_on_error_added=1" "1" "$(sig_continue_on_error_added "$diff_continue_on_error")"
  assert_equals "audit-level diff: audit_level_lowered=1 (high->low)" "1" "$(sig_audit_level_lowered "$diff_audit_level")"
  assert_equals "deleted-step diff: gate_step_deleted=1" "1" "$(sig_gate_step_deleted "$diff_deleted_step")"
  assert_equals "path-filter diff: path_filter_narrowed=1" "1" "$(sig_path_filter_narrowed "$diff_path_filter")"

  # Negative control: an unrelated README edit must not trip ANY signal.
  assert_equals "unrelated diff: touches_workflow=0" "0" "$(sig_touches_workflow "$diff_unrelated")"
  assert_equals "unrelated diff: new_gate_file=0" "0" "$(sig_new_gate_file "$diff_unrelated")"
  assert_equals "unrelated diff: continue_on_error_added=0" "0" "$(sig_continue_on_error_added "$diff_unrelated")"
  assert_equals "unrelated diff: audit_level_lowered=0" "0" "$(sig_audit_level_lowered "$diff_unrelated")"
  assert_equals "unrelated diff: gate_step_deleted=0" "0" "$(sig_gate_step_deleted "$diff_unrelated")"
  assert_equals "unrelated diff: path_filter_narrowed=0" "0" "$(sig_path_filter_narrowed "$diff_unrelated")"

  # End-to-end: each representative diff resolves to `narrowing` through decide().
  assert_equals "end-to-end: new-allowlist diff resolves narrowing" "narrowing" \
    "$(decide "$(sig_touches_workflow "$diff_new_allowlist")" "$(sig_new_gate_file "$diff_new_allowlist")" 0 0 0 0)"
  assert_equals "end-to-end: unrelated diff resolves clean" "clean" \
    "$(decide "$(sig_touches_workflow "$diff_unrelated")" "$(sig_new_gate_file "$diff_unrelated")" 0 0 0 0)"
else
  assert_fail "signal extraction tests skipped — detector script missing"
fi
echo

# ---------------------------------------------------------------------------
# (C) auto-merge.md — the check is wired in as its own step, BEFORE any
#     merge call, distinct from the #1088 policy-override step.
# ---------------------------------------------------------------------------
echo "(C) auto-merge.md — wiring and ordering"
if [[ -f "$AUTO_MERGE_MD" ]]; then
  assert_pass "auto-merge.md exists"
  assert_contains "$AUTO_MERGE_MD" 'detect-ci-gate-narrowing.sh' \
    "auto-merge.md invokes the detector script"
  assert_contains "$AUTO_MERGE_MD" 'unarmed-gate-narrowing' \
    "auto-merge.md names the structured unarmed-gate-narrowing outcome"
  assert_contains "$AUTO_MERGE_MD" 'issues/1139' \
    "auto-merge.md cites issue #1139"
  assert_contains "$AUTO_MERGE_MD" 'DIFFERENT risk class from step 0.3' \
    "auto-merge.md explicitly distinguishes the new step from the #1088 policy-override step"

  detector_line=$(grep -n 'detect-ci-gate-narrowing.sh' "$AUTO_MERGE_MD" | head -1 | cut -d: -f1)
  ungated_line=$(grep -n 'detect-ungated-admin-direct-merge.sh' "$AUTO_MERGE_MD" | head -1 | cut -d: -f1)

  if [[ -n "$detector_line" && -n "$ungated_line" && "$detector_line" -lt "$ungated_line" ]]; then
    assert_pass "auto-merge.md wires the gate-narrowing check BEFORE the ungated-admin-direct-merge check (L$detector_line < L$ungated_line)"
  else
    assert_fail "auto-merge.md wires the gate-narrowing check BEFORE the ungated-admin-direct-merge check (gate-narrowing=L${detector_line:-absent}, ungated=L${ungated_line:-absent})"
  fi
else
  assert_fail "auto-merge.md exists (missing at $AUTO_MERGE_MD)"
fi
echo

# ---------------------------------------------------------------------------
# (D) Per-mode wiring — issue-work.md, fix-main-ci.md, fix-failing-prs-batch.md
#     all reference the check and offer its return line.
# ---------------------------------------------------------------------------
echo "(D) per-mode wiring — return vocabulary"
for entry in \
  "$ISSUE_WORK_MD|issue-work.md" \
  "$FIX_MAIN_CI_MD|fix-main-ci.md" \
  "$FIX_PR_BATCH_MD|fix-failing-prs-batch.md"
do
  file="${entry%%|*}"; label="${entry##*|}"
  assert_contains "$file" 'gate-narrowing' \
    "$label mentions the gate-narrowing check"
  assert_contains "$file" 'unarmed — gate-narrowing' \
    "$label offers the unarmed — gate-narrowing return line"
  assert_contains "$file" 'issues/1139' \
    "$label cites issue #1139"
done
echo

# ---------------------------------------------------------------------------
# (E) Schema — new enum value, new field, required-when conditional.
# ---------------------------------------------------------------------------
echo "(E) worker-return.schema.json"
if [[ -f "$SCHEMA" ]]; then
  assert_pass "worker-return.schema.json exists"
  assert_contains "$SCHEMA" 'unarmed-gate-narrowing' \
    "schema's auto_merge enum includes unarmed-gate-narrowing"
  assert_contains "$SCHEMA" '"gate_narrowing"' \
    "schema defines a gate_narrowing field"

  if command -v jq >/dev/null 2>&1; then
    valid_json=$(jq empty "$SCHEMA" 2>&1 && echo ok || echo fail)
    assert_equals "schema is valid JSON" "ok" "$valid_json"

    has_conditional=$(jq '[.allOf[] | select(.if.properties.auto_merge.const == "unarmed-gate-narrowing")] | length' "$SCHEMA" 2>/dev/null)
    assert_equals "schema has an allOf conditional requiring gate_narrowing" "1" "${has_conditional:-0}"
  fi
else
  assert_fail "worker-return.schema.json exists (missing at $SCHEMA)"
fi
echo

# ---------------------------------------------------------------------------
# (F) SKILL.md carries a short pointer to the rule (extending the existing
#     PR-creation-contract sentence that already names what the auto-merge.md
#     fragment carries, rather than a new dedicated section) and stays under
#     its per-file size budget (issue #980 — this is the always-loaded core;
#     the full explanation lives in the on-demand auto-merge.md fragment).
# ---------------------------------------------------------------------------
echo "(F) SKILL.md — pointer present, budget respected"
if [[ -f "$SKILL_MD" ]]; then
  assert_pass "SKILL.md exists"
  assert_contains "$SKILL_MD" 'the gate-narrowing pre-check' \
    "SKILL.md's PR-creation-contract sentence names the gate-narrowing pre-check"
  assert_contains "$SKILL_MD" 'issues/1139' \
    "SKILL.md cites issue #1139"

  # This literal mirrors spec-size-budget.test.sh's own assert_under_budget
  # call — that file is the canonical source for the ceiling value and its
  # raise history (most recently 59000 -> 60000 by #1135); keep this in sync
  # with it whenever a ceiling changes there.
  skill_bytes=$(wc -c < "$SKILL_MD" | tr -d ' ')
  if [[ "$skill_bytes" -lt 60000 ]]; then
    assert_pass "SKILL.md stays under the #980 60000-byte ceiling ($skill_bytes bytes)"
  else
    assert_fail "SKILL.md stays under the #980 60000-byte ceiling ($skill_bytes bytes exceeds 60000)"
  fi
else
  assert_fail "SKILL.md exists (missing at $SKILL_MD)"
fi
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1

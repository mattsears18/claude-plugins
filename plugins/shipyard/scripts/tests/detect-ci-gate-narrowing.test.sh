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
#   (B2) `continue-on-error: true` is attributed PER STEP (issue #1494) — it
#       counts only when the enclosing step existed on the base branch, with
#       every unattributable shape still failing toward `narrowing`, plus a
#       mutation-style negative control proving the guard is load-bearing;
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
# (B2) `continue-on-error: true` — per-step attribution (issue #1494).
#
# The flag narrows a gate only when the step it belongs to ALREADY EXISTED on
# the base branch: the gate stays nominally in place while ceasing to fail.
# The same flag on a step the PR is itself ADDING relaxes nothing that existed
# before, and gate strength on the default branch after the merge is identical
# to before it.
#
# Repro that motivated this: `mattsears18/lightwork` PR #4382 — two purely
# additive trailing steps that extract per-run Lighthouse metrics and upload a
# ~3 KB JSON artifact, with the `Run Lighthouse CI` step and every threshold
# byte-identical. The pre-#1494 detector keyed on the flag appearing anywhere
# in the added lines and returned `narrowing`. That repo *mandates* the flag on
# every reporting-only upload (`.claude/rules/ci-artifact-uploads.md`, after a
# quota-exhausted upload step turned an all-green run red across two required
# checks), so the false positive was structural and recurring — every future
# artifact-upload PR would have cost a `needs-human-review` plus a human clear,
# which is how a gate that is wrong often enough gets waved through by reflex.
#
# The fail-safe direction is unchanged: anything that cannot be attributed to a
# demonstrably-new step still counts as narrowing.
# ---------------------------------------------------------------------------
echo "(B2) continue-on-error — per-step attribution (issue #1494)"
if [[ -f "$DETECTOR" ]]; then
  tmp_src="$(mktemp)"
  sed '$d' "$DETECTOR" > "$tmp_src"
  # shellcheck disable=SC1090
  source "$tmp_src"
  rm -f "$tmp_src"

  # NEW reporting-only steps, modeled on lightwork #4382. Both step entries are
  # themselves added lines => not narrowing.
  diff_coe_new_step=$'diff --git a/.github/workflows/lighthouse.yml b/.github/workflows/lighthouse.yml\nindex abc..def 100644\n--- a/.github/workflows/lighthouse.yml\n+++ b/.github/workflows/lighthouse.yml\n@@ -109,3 +109,12 @@ jobs:\n         run: npx lhci autorun\n+\n+      # Reporting only — see .claude/rules/ci-artifact-uploads.md.\n+      - name: Summarize per-run metrics\n+        if: always()\n+        continue-on-error: true\n+        run: node scripts/summarize-runs.mjs\n+\n+      - name: Upload per-run metrics\n+        if: always()\n+        continue-on-error: true\n+        uses: actions/upload-artifact@v7\n'

  # A brand-new workflow FILE is the degenerate case of the same thing: every
  # step in it is new, so nothing that existed before was relaxed.
  diff_coe_new_file=$'diff --git a/.github/workflows/report.yml b/.github/workflows/report.yml\nnew file mode 100644\nindex 0000000..abc1234\n--- /dev/null\n+++ b/.github/workflows/report.yml\n@@ -0,0 +1,9 @@\n+name: report\n+on: [pull_request]\n+jobs:\n+  report:\n+    runs-on: ubuntu-latest\n+    steps:\n+      - name: Upload\n+        continue-on-error: true\n+        uses: actions/upload-artifact@v7\n'

  # A nested sequence item under `with:` is NOT a step marker — the enclosing
  # step must be resolved by indent, not by "nearest preceding dash".
  diff_coe_new_step_nested=$'diff --git a/.github/workflows/audit.yml b/.github/workflows/audit.yml\nindex abc..def 100644\n--- a/.github/workflows/audit.yml\n+++ b/.github/workflows/audit.yml\n@@ -20,1 +20,8 @@\n+      - name: Upload audit report\n+        uses: actions/upload-artifact@v7\n+        with:\n+          path: |\n+            - not-a-step\n+        continue-on-error: true\n'

  # Mirror image: the flag lands on a PRE-EXISTING step whose own body happens
  # to contain a nested list. Still narrowing.
  diff_coe_existing_nested=$'diff --git a/.github/workflows/audit.yml b/.github/workflows/audit.yml\nindex abc..def 100644\n--- a/.github/workflows/audit.yml\n+++ b/.github/workflows/audit.yml\n@@ -10,6 +10,7 @@\n       - name: Scan\n         with:\n           paths:\n             - src\n+        continue-on-error: true\n'

  # One clean new step must not mask a dirty edit to an existing one in the
  # same hunk — the signal is per-occurrence, not per-diff.
  diff_coe_mixed=$'diff --git a/.github/workflows/audit.yml b/.github/workflows/audit.yml\nindex abc..def 100644\n--- a/.github/workflows/audit.yml\n+++ b/.github/workflows/audit.yml\n@@ -10,6 +10,12 @@\n       - name: npm audit\n         run: npm audit --audit-level=high\n+        continue-on-error: true\n+\n+      - name: Upload audit report\n+        continue-on-error: true\n+        uses: actions/upload-artifact@v7\n'

  # Renaming an existing gate step is not "adding a new step" — the added
  # marker replaces a removed marker at the same indent in the same change
  # block, so the conservative reading holds.
  diff_coe_renamed=$'diff --git a/.github/workflows/audit.yml b/.github/workflows/audit.yml\nindex abc..def 100644\n--- a/.github/workflows/audit.yml\n+++ b/.github/workflows/audit.yml\n@@ -10,4 +10,5 @@\n-      - name: npm audit\n+      - name: npm audit (advisory)\n+        continue-on-error: true\n         run: npm audit --audit-level=high\n'

  # A hunk that begins mid-step carries no enclosing marker at all. Cannot
  # attribute => must fail toward narrowing.
  diff_coe_indeterminate=$'diff --git a/.github/workflows/audit.yml b/.github/workflows/audit.yml\nindex abc..def 100644\n--- a/.github/workflows/audit.yml\n+++ b/.github/workflows/audit.yml\n@@ -12,2 +12,3 @@\n         run: npm audit --audit-level=high\n+        continue-on-error: true\n'

  assert_equals "new reporting-only steps (lightwork #4382 shape): continue_on_error_added=0" \
    "0" "$(sig_continue_on_error_added "$diff_coe_new_step")"
  assert_equals "brand-new workflow file: continue_on_error_added=0" \
    "0" "$(sig_continue_on_error_added "$diff_coe_new_file")"
  assert_equals "new step with a nested list before the flag: continue_on_error_added=0" \
    "0" "$(sig_continue_on_error_added "$diff_coe_new_step_nested")"
  assert_equals "existing step with a nested list: continue_on_error_added=1" \
    "1" "$(sig_continue_on_error_added "$diff_coe_existing_nested")"
  assert_equals "existing step + new step in one hunk: continue_on_error_added=1" \
    "1" "$(sig_continue_on_error_added "$diff_coe_mixed")"
  assert_equals "renamed existing gate step: continue_on_error_added=1" \
    "1" "$(sig_continue_on_error_added "$diff_coe_renamed")"
  assert_equals "unattributable hunk (starts mid-step): continue_on_error_added=1 (fail-safe)" \
    "1" "$(sig_continue_on_error_added "$diff_coe_indeterminate")"
  assert_equals "the original existing-gate-step diff still trips: continue_on_error_added=1" \
    "1" "$(sig_continue_on_error_added "$diff_continue_on_error")"

  # End-to-end through decide(): the additive-reporting PR resolves `clean`
  # even though it plainly touches a workflow file.
  assert_equals "end-to-end: new reporting-only steps resolve clean" "clean" \
    "$(decide "$(sig_touches_workflow "$diff_coe_new_step")" \
              "$(sig_new_gate_file "$diff_coe_new_step")" \
              "$(sig_continue_on_error_added "$diff_coe_new_step")" 0 0 0)"
  assert_equals "end-to-end: existing gate step resolves narrowing" "narrowing" \
    "$(decide "$(sig_touches_workflow "$diff_continue_on_error")" \
              "$(sig_new_gate_file "$diff_continue_on_error")" \
              "$(sig_continue_on_error_added "$diff_continue_on_error")" 0 0 0)"

  # -------------------------------------------------------------------------
  # Mutation-style negative control. Delete the one line carrying the
  # step-attribution guard and assert the mutant REPRODUCES the #1494 bug. A
  # test that passes against both the fixed script and the broken one proves
  # nothing; this pins that the assertions above are actually load-bearing.
  # -------------------------------------------------------------------------
  mutant_src="$(mktemp)"
  sed '$d' "$DETECTOR" | sed '/MUTATION-ANCHOR-1494/d' > "$mutant_src"
  orig_lines=$(sed '$d' "$DETECTOR" | wc -l | tr -d ' ')
  mutant_lines=$(wc -l < "$mutant_src" | tr -d ' ')
  if [[ "$mutant_lines" -lt "$orig_lines" ]]; then
    assert_pass "mutation applied — the MUTATION-ANCHOR-1494 guard line was removed"
  else
    assert_fail "mutation applied — the MUTATION-ANCHOR-1494 guard line was removed (anchor not found in $DETECTOR)"
  fi

  mutant_verdict="$(
    # shellcheck disable=SC1090
    source "$mutant_src"
    sig_continue_on_error_added "$diff_coe_new_step"
  )"
  rm -f "$mutant_src"
  assert_equals "negative control: guard-removed mutant reproduces the #1494 false positive" \
    "1" "$mutant_verdict"

  # -------------------------------------------------------------------------
  # End-to-end through main(), with `gh pr diff` stubbed on PATH — this is the
  # surface the acceptance criteria are written against (verdict on stdout,
  # exit code, and the `unknown` fail-safe on an unreadable diff).
  # -------------------------------------------------------------------------
  run_detector_with_stub() {
    local diff_text="$1" stub_dir out
    stub_dir="$(mktemp -d)"
    printf '%s' "$diff_text" > "$stub_dir/diff.txt"
    {
      printf '#!/usr/bin/env bash\n'
      if [[ -n "$diff_text" ]]; then
        printf 'cat %q\n' "$stub_dir/diff.txt"
      else
        printf 'exit 1\n'
      fi
    } > "$stub_dir/gh"
    chmod +x "$stub_dir/gh"
    out="$(PATH="$stub_dir:$PATH" bash "$DETECTOR" owner/repo 1 2>/dev/null)"
    printf '%s|%s' "$out" "$?"
    rm -rf "$stub_dir"
  }

  assert_equals "main(): new reporting-only steps => clean, exit 0" \
    "clean|0" "$(run_detector_with_stub "$diff_coe_new_step")"
  assert_equals "main(): existing gate step => narrowing, exit 0" \
    "narrowing|0" "$(run_detector_with_stub "$diff_continue_on_error")"
  assert_equals "main(): unreadable diff => unknown, exit 2 (still blocking)" \
    "unknown|2" "$(run_detector_with_stub "")"
else
  assert_fail "step-attribution tests skipped — detector script missing"
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
#     fragment carries, rather than a new dedicated section). Its per-file
#     size budget (issue #980 — this is the always-loaded core) is enforced
#     solely by spec-size-budget.test.sh, not duplicated here (issue #1177).
# ---------------------------------------------------------------------------
echo "(F) SKILL.md — pointer present"
if [[ -f "$SKILL_MD" ]]; then
  assert_pass "SKILL.md exists"
  assert_contains "$SKILL_MD" 'the gate-narrowing pre-check' \
    "SKILL.md's PR-creation-contract sentence names the gate-narrowing pre-check"
  assert_contains "$SKILL_MD" 'issues/1139' \
    "SKILL.md cites issue #1139"

  # No ceiling assertion here (issue #1177) — spec-size-budget.test.sh is the
  # sole owner of SKILL.md's size-ceiling enforcement and already runs in the
  # same CI job on every PR (tests.yml discovers every *.test.sh under
  # plugins/). This suite tests that the gate-narrowing pointer text is
  # present, not file size; a second copy of the literal ceiling here would
  # be exactly the kind of duplicate that has already drifted twice.
else
  assert_fail "SKILL.md exists (missing at $SKILL_MD)"
fi
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1

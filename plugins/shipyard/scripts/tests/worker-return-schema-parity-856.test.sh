#!/usr/bin/env bash
# Test: the workflow's hand-copied `workerReturnSchema` literal stays in sync
# with the canonical `schemas/worker-return.schema.json` — issue #856.
#
# Background
# ----------
# `schemas/worker-return.schema.json` is the canonical, schema-validated
# contract every `mode:`-driven `/shipyard:do-work` worker must return. The
# `Workflow` runtime that dispatches those workers
# (`workflows/do-work-dispatch.workflow.js`) executes in an isolated
# environment with no filesystem access, so it can't `require`/`import` the
# JSON file — it carries a literal hand-copied duplicate
# (`workerReturnSchema`) instead. That copy's own comment used to say
# "review both files together on any return-contract change," and nothing
# enforced that: an audit found the copy had silently drifted from the
# canonical schema in two ways — the `allOf` conditional-required block
# (blocked outcomes must carry `blocked_reason`; disposition outcomes must
# carry `disposition`) was missing entirely, and `issue`/`pr` were missing
# `minimum: 1`. Both omissions made the workflow's embedded validator
# silently ACCEPT malformed returns the canonical schema would reject —
# exactly the "fail loudly at the stage boundary" guarantee the
# schema-validation layer exists to provide.
#
# #856 fixed both drifts AND added
# `scripts/check-worker-return-schema-parity.mjs`, a dependency-free checker
# that diffs the two schemas field-for-field (type/enum/minimum per
# property, required, additionalProperties, allOf) so a future drift is
# caught mechanically instead of relying on a human to "review both files
# together." This suite is the regression guard for both halves: the fix
# itself (the real repo files now match) and the checker (it actually fails
# on the #856 regression, and on other drift shapes it never triggered on
# before this issue).
#
# Pure bash + node, no other external dependencies. Run with:
#   bash plugins/shipyard/scripts/tests/worker-return-schema-parity-856.test.sh

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

checker="$repo_root/plugins/shipyard/scripts/check-worker-return-schema-parity.mjs"
schema_path="$repo_root/plugins/shipyard/schemas/worker-return.schema.json"
workflow_js_path="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    missing: %s\n' "$path"
  fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not on PATH — this suite cannot verify schema parity" >&2
  exit 1
fi

for f in "$checker" "$schema_path" "$workflow_js_path"; do
  assert_file_exists "$f" "$(basename "$f") exists"
done

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# Assert the checker PASSES (schemas match on every validation-relevant facet).
assert_parity_ok() {
  local schema="$1" js="$2" label="$3" out rc
  out=$(node "$checker" "$schema" "$js" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    checker reported a drift:\n'
    printf '    %s\n' "$out"
  fi
}

# Assert the checker FAILS (a real drift exists), optionally requiring the
# diagnostic output to mention a specific substring.
assert_parity_drift() {
  local schema="$1" js="$2" label="$3" expect="${4:-}" out rc
  out=$(node "$checker" "$schema" "$js" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    assert_fail "$label"
    printf '    checker ACCEPTED a drifted schema — the guard is not working\n'
    return
  fi
  if [[ -n "$expect" ]] && ! grep -qF -- "$expect" <<<"$out"; then
    assert_fail "$label"
    printf '    expected the diagnostic to mention: %s\n    got:\n    %s\n' "$expect" "$out"
    return
  fi
  assert_pass "$label"
}

# ==========================================================================
echo "== (A) the checker's own syntax and a bare run against the real repo files"
# ==========================================================================

if node --check "$checker" >/dev/null 2>&1; then
  assert_pass "check-worker-return-schema-parity.mjs has valid JS syntax (node --check)"
else
  assert_fail "check-worker-return-schema-parity.mjs has valid JS syntax (node --check)"
fi

if node --check "$workflow_js_path" >/dev/null 2>&1; then
  assert_pass "do-work-dispatch.workflow.js has valid JS syntax (node --check)"
else
  assert_fail "do-work-dispatch.workflow.js has valid JS syntax (node --check)"
fi

# ==========================================================================
echo
echo "== (B) POSITIVE — the real repo files match today (the #856 fix itself)"
# ==========================================================================

# This is the assertion that would have been RED before #856's fix landed.
assert_parity_ok "$schema_path" "$workflow_js_path" \
  "workflows/do-work-dispatch.workflow.js's workerReturnSchema matches schemas/worker-return.schema.json"

assert_file_exists "$schema_path" "canonical schema still declares allOf" # sanity re-check below
if grep -q '"allOf"' "$schema_path"; then
  assert_pass "canonical schema still declares an allOf block (sanity check for (C) below)"
else
  assert_fail "canonical schema still declares an allOf block (sanity check for (C) below)"
fi

if grep -q "allOf:" "$workflow_js_path"; then
  assert_pass "workflow .js literal now declares an allOf block (issue #856 fix)"
else
  assert_fail "workflow .js literal now declares an allOf block (issue #856 fix)"
fi

if grep -q "minimum: 1" "$workflow_js_path"; then
  assert_pass "workflow .js literal now declares minimum: 1 (issue #856 fix)"
else
  assert_fail "workflow .js literal now declares minimum: 1 (issue #856 fix)"
fi

# ==========================================================================
echo
echo "== (C) NEGATIVE — the checker catches the EXACT #856 regression"
# ==========================================================================

# Byte-for-byte reproduction of the workerReturnSchema literal as it stood
# BEFORE #856 — no allOf block, issue/pr missing minimum: 1. If this fixture
# ever starts PASSING, the guard has been broken and #856 can silently ship
# again.
f="$tmp/pre-856-regression.js"
cat > "$f" <<'EOF'
const workerReturnSchema = {
  type: 'object',
  required: ['mode', 'outcome'],
  additionalProperties: false,
  properties: {
    mode: {
      type: 'string',
      enum: [
        'issue-work',
        'fix-checks-only',
        'fix-rebase',
        'fix-main-ci',
        'fix-failing-prs-batch',
        'investigate',
        'spike',
      ],
    },
    outcome: {
      type: 'string',
      enum: ['shipped', 'green', 'rebased', 'noop', 'blocked', 'reaped', 'disposition'],
    },
    issue: { type: ['integer', 'null'] },
    pr: { type: ['integer', 'null'] },
    auto_merge: {
      type: ['string', 'null'],
      enum: [
        'enabled',
        'gated-manual',
        'merged-direct',
        'merged-direct-ungated',
        'unavailable',
        'unavailable-workflow-scope',
        'gated-external',
        null,
      ],
    },
    checks: { type: ['string', 'null'], enum: ['green', 'pending', 'failing', null] },
    disposition: {
      type: ['string', 'null'],
      enum: ['fix', 'needs-human-review', 'auto-close-noise', 'duplicate', 'decomposed', 'designed', null],
    },
    blocked_reason: { type: ['string', 'null'] },
    blocked_stage: { type: ['string', 'null'] },
    last_push: { type: ['string', 'null'] },
    summary: { type: ['string', 'null'] },
  },
}
EOF

assert_parity_drift "$schema_path" "$f" \
  "the pre-#856 regression fixture is REJECTED (missing allOf + minimum)" \
  '"allOf":'

out=$(node "$checker" "$schema_path" "$f" 2>&1)
if grep -qF 'property "issue".minimum: canonical=1 js=undefined' <<<"$out"; then
  assert_pass "diagnostic names the missing issue.minimum:1"
else
  assert_fail "diagnostic names the missing issue.minimum:1"
  printf '    got:\n    %s\n' "$out"
fi
if grep -qF 'property "pr".minimum: canonical=1 js=undefined' <<<"$out"; then
  assert_pass "diagnostic names the missing pr.minimum:1"
else
  assert_fail "diagnostic names the missing pr.minimum:1"
  printf '    got:\n    %s\n' "$out"
fi
if grep -qF 'blocked_reason' <<<"$out" && grep -qF 'disposition' <<<"$out"; then
  assert_pass "diagnostic surfaces the missing allOf rules (blocked_reason / disposition required-when)"
else
  assert_fail "diagnostic surfaces the missing allOf rules (blocked_reason / disposition required-when)"
  printf '    got:\n    %s\n' "$out"
fi

# node --check must still pass on the regression fixture — it's valid JS, the
# same "node --check is insufficient" property #809's fixture pins.
if node --check "$f" >/dev/null 2>&1; then
  assert_pass "the pre-#856 regression fixture PASSES 'node --check' (proving syntax checks alone can't catch this)"
else
  assert_fail "the pre-#856 regression fixture PASSES 'node --check' (proving syntax checks alone can't catch this)"
fi

# ==========================================================================
echo
echo "== (D) NEGATIVE — other drift shapes the checker must also catch"
# ==========================================================================

# A minimal but otherwise-valid canonical schema fixture pair for the
# fine-grained drift shapes below — isolates each assertion from the real
# schema's full field set so a diagnostic can be pinned exactly.
canon_min="$tmp/canon-min.json"
cat > "$canon_min" <<'EOF'
{
  "type": "object",
  "required": ["mode", "outcome"],
  "additionalProperties": false,
  "properties": {
    "mode": { "type": "string", "enum": ["issue-work", "spike"] },
    "outcome": { "type": "string", "enum": ["shipped", "blocked"] }
  },
  "allOf": [
    { "if": { "properties": { "outcome": { "const": "blocked" } } }, "then": { "required": ["blocked_reason"] } }
  ]
}
EOF

# (D.1) enum drift on a property both sides declare.
js_enum_drift="$tmp/enum-drift.js"
cat > "$js_enum_drift" <<'EOF'
const workerReturnSchema = {
  type: 'object',
  required: ['mode', 'outcome'],
  additionalProperties: false,
  properties: {
    mode: { type: 'string', enum: ['issue-work'] },
    outcome: { type: 'string', enum: ['shipped', 'blocked'] },
  },
  allOf: [
    { if: { properties: { outcome: { const: 'blocked' } } }, then: { required: ['blocked_reason'] } },
  ],
}
EOF
assert_parity_drift "$canon_min" "$js_enum_drift" \
  "an enum drift (mode missing 'spike') is REJECTED" \
  'mode".enum'

# (D.2) required array drift.
js_required_drift="$tmp/required-drift.js"
cat > "$js_required_drift" <<'EOF'
const workerReturnSchema = {
  type: 'object',
  required: ['mode'],
  additionalProperties: false,
  properties: {
    mode: { type: 'string', enum: ['issue-work', 'spike'] },
    outcome: { type: 'string', enum: ['shipped', 'blocked'] },
  },
  allOf: [
    { if: { properties: { outcome: { const: 'blocked' } } }, then: { required: ['blocked_reason'] } },
  ],
}
EOF
assert_parity_drift "$canon_min" "$js_required_drift" \
  "a top-level required-array drift (missing 'outcome') is REJECTED" \
  '"required"'

# (D.3) additionalProperties drift.
js_additional_drift="$tmp/additional-drift.js"
cat > "$js_additional_drift" <<'EOF'
const workerReturnSchema = {
  type: 'object',
  required: ['mode', 'outcome'],
  additionalProperties: true,
  properties: {
    mode: { type: 'string', enum: ['issue-work', 'spike'] },
    outcome: { type: 'string', enum: ['shipped', 'blocked'] },
  },
  allOf: [
    { if: { properties: { outcome: { const: 'blocked' } } }, then: { required: ['blocked_reason'] } },
  ],
}
EOF
assert_parity_drift "$canon_min" "$js_additional_drift" \
  "an additionalProperties drift (true vs false) is REJECTED" \
  'additionalProperties'

# (D.4) a property entirely missing from the .js copy.
js_missing_prop="$tmp/missing-prop.js"
cat > "$js_missing_prop" <<'EOF'
const workerReturnSchema = {
  type: 'object',
  required: ['mode', 'outcome'],
  additionalProperties: false,
  properties: {
    mode: { type: 'string', enum: ['issue-work', 'spike'] },
  },
  allOf: [
    { if: { properties: { outcome: { const: 'blocked' } } }, then: { required: ['blocked_reason'] } },
  ],
}
EOF
assert_parity_drift "$canon_min" "$js_missing_prop" \
  "a property present in the canonical schema but missing from the .js copy is REJECTED" \
  'MISSING from .js copy'

# (D.5) allOf's then.required drift (right outcome, wrong required field).
js_allof_drift="$tmp/allof-drift.js"
cat > "$js_allof_drift" <<'EOF'
const workerReturnSchema = {
  type: 'object',
  required: ['mode', 'outcome'],
  additionalProperties: false,
  properties: {
    mode: { type: 'string', enum: ['issue-work', 'spike'] },
    outcome: { type: 'string', enum: ['shipped', 'blocked'] },
  },
  allOf: [
    { if: { properties: { outcome: { const: 'blocked' } } }, then: { required: ['blocked_stage'] } },
  ],
}
EOF
assert_parity_drift "$canon_min" "$js_allof_drift" \
  "an allOf then.required drift (blocked_stage instead of blocked_reason) is REJECTED" \
  '"allOf"'

# ==========================================================================
echo
echo "== (E) POSITIVE-but-tricky — description text is NOT a parity requirement"
# ==========================================================================

# The canonical schema carries verbose "description" fields the .js copy
# deliberately omits (they carry no validation weight) — that must NOT be
# reported as a drift. This is exactly the real-world shape of (B) above,
# isolated here with a minimal fixture pair so the assertion is pinned to
# this one property rather than riding on the full real schema.
canon_with_desc="$tmp/canon-with-desc.json"
cat > "$canon_with_desc" <<'EOF'
{
  "type": "object",
  "required": ["mode", "outcome"],
  "additionalProperties": false,
  "properties": {
    "mode": { "type": "string", "enum": ["issue-work", "spike"], "description": "verbose prose here" },
    "outcome": { "type": "string", "enum": ["shipped", "blocked"], "description": "more verbose prose" }
  },
  "allOf": [
    { "if": { "properties": { "outcome": { "const": "blocked" } } }, "then": { "required": ["blocked_reason"] } }
  ]
}
EOF
js_no_desc="$tmp/js-no-desc.js"
cat > "$js_no_desc" <<'EOF'
const workerReturnSchema = {
  type: 'object',
  required: ['mode', 'outcome'],
  additionalProperties: false,
  properties: {
    mode: { type: 'string', enum: ['issue-work', 'spike'] },
    outcome: { type: 'string', enum: ['shipped', 'blocked'] },
  },
  allOf: [
    { if: { properties: { outcome: { const: 'blocked' } } }, then: { required: ['blocked_reason'] } },
  ],
}
EOF
assert_parity_ok "$canon_with_desc" "$js_no_desc" \
  "a .js copy omitting 'description' entirely is NOT reported as a drift"

# ==========================================================================
echo
echo "== (F) the checker is wired into this repo's CI discovery"
# ==========================================================================

if [[ -x "$checker" || -f "$checker" ]]; then
  assert_pass "check-worker-return-schema-parity.mjs is present at the expected path"
else
  assert_fail "check-worker-return-schema-parity.mjs is present at the expected path"
fi

# This suite lives under plugins/ and matches *.test.sh, so tests.yml's
# `find plugins -type f -name '*.test.sh'` discovery picks it up with no
# workflow edit. Pin that self-referential fact so a rename can't silently
# drop the guard out of CI.
if [[ "$(basename "${BASH_SOURCE[0]}")" == *.test.sh ]]; then
  assert_pass "this suite is named *.test.sh so tests.yml's find-based discovery runs it"
else
  assert_fail "this suite is named *.test.sh so tests.yml's find-based discovery runs it"
fi

# ==========================================================================
echo
printf 'worker-return-schema-parity-856: %s%d passed%s, %s%d failed%s\n' \
  "$GREEN" "$pass" "$RESET" "$([[ $fail -gt 0 ]] && printf '%s' "$RED" || printf '%s' "$GREEN")" "$fail" "$RESET"

[[ $fail -eq 0 ]]

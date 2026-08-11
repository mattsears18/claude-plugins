#!/usr/bin/env bash
# Test: the `milestones` top-level config block (issue #1239) — schema shape,
# accessor defaults, live validation of good/bad configs, and the
# /shipyard:init offering.
#
# Background — #1239 is the foundation issue of a five-issue milestones/
# roadmap sequence (#1239-#1244). Scope is config-surface only: schema +
# accessors + /shipyard:init wiring. NO consuming behavior (dispatch
# ranking, filing-time assignment, the loop-end sweep) is implemented here
# — those are #1240-#1244, each reading exactly one key this schema defines.
#
# This suite pins:
#   1. Schema shape — the block exists, additionalProperties:false, each
#      key's type/default/enum.
#   2. Accessor defaults — `shipyard-config.sh get milestones.<key>` returns
#      the documented default when the block is absent entirely.
#   3. Live validation — a full valid block passes; an unknown field and a
#      wrong-typed field both fail with exit 70.
#   4. Inertness — a repo config with milestones.enabled:false (or the
#      block absent) merges identically either way.
#   5. /shipyard:init offers the block (step 9.8 documented).
#
# Pure bash + jq, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/milestones-config.test.sh

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

schema="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"
config_sh="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"
init_md="$repo_root/plugins/shipyard/commands/init.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_jq() {
  local file="$1" jq_expr="$2" expected="$3" label="$4"
  if [[ ! -f "$file" ]]; then
    printf '  %sFAIL%s  %s — file missing: %s\n' "$RED" "$RESET" "$label" "$file"
    fail=$((fail+1))
    return
  fi
  local actual
  actual=$(jq -r "$jq_expr" "$file" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    jq expr: %s\n' "$jq_expr"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected %q, got %q)\n' "$RED" "$RESET" "$label" "$expected" "$actual"
    fail=$((fail+1))
  fi
}

assert_exit_code() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected exit %s, got %s)\n' "$RED" "$RESET" "$label" "$expected" "$actual"
    fail=$((fail+1))
  fi
}

assert_file_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s — file missing: %s\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
    return
  fi
  if grep -qF -- "$needle" "$path"; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected %s to contain: %s\n' "$path" "$needle"
    fail=$((fail+1))
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# --------------------------------------------------------------------------
echo "== Schema shape"

assert_jq "$schema" '.properties.milestones.type' "object" "milestones block is an object"
assert_jq "$schema" '.properties.milestones.additionalProperties' "false" "milestones rejects unknown fields"
assert_jq "$schema" '.properties.milestones.properties.enabled.type' "boolean" "enabled is boolean"
assert_jq "$schema" '.properties.milestones.properties.enabled.default' "false" "enabled defaults false"
assert_jq "$schema" '.properties.milestones.properties.fallback.type' "string" "fallback is string"
assert_jq "$schema" '.properties.milestones.properties.fallback.default' "Ongoing maintenance" "fallback defaults 'Ongoing maintenance'"
assert_jq "$schema" '.properties.milestones.properties.assign_on_file.type' "boolean" "assign_on_file is boolean"
assert_jq "$schema" '.properties.milestones.properties.assign_on_file.default' "true" "assign_on_file defaults true"
assert_jq "$schema" '.properties.milestones.properties.prioritize_dispatch.type' "boolean" "prioritize_dispatch is boolean"
assert_jq "$schema" '.properties.milestones.properties.prioritize_dispatch.default' "true" "prioritize_dispatch defaults true"
assert_jq "$schema" '.properties.milestones.properties.sweep_on_loop_end.type' "boolean" "sweep_on_loop_end is boolean"
assert_jq "$schema" '.properties.milestones.properties.sweep_on_loop_end.default' "true" "sweep_on_loop_end defaults true"

# Numbering-contract documentation lives in the block's own description, per
# the issue's "Document the numbering contract" acceptance item.
desc="$(jq -r '.properties.milestones.description' "$schema" 2>/dev/null)"
if [[ "$desc" == *"N · Title"* || "$desc" == *"N ·"* ]]; then
  printf '  %sPASS%s  description documents the N · Title numbering contract\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  description documents the N · Title numbering contract\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo
echo "== Accessor defaults (block absent entirely)"

got_enabled=$(SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" get milestones.enabled 2>/dev/null)
assert_equals "$got_enabled" "false" "get milestones.enabled returns false when block absent"

got_fallback=$(SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" get milestones.fallback 2>/dev/null)
assert_equals "$got_fallback" "Ongoing maintenance" "get milestones.fallback returns 'Ongoing maintenance' when block absent"

got_assign=$(SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" get milestones.assign_on_file 2>/dev/null)
assert_equals "$got_assign" "true" "get milestones.assign_on_file returns true when block absent"

got_prioritize=$(SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" get milestones.prioritize_dispatch 2>/dev/null)
assert_equals "$got_prioritize" "true" "get milestones.prioritize_dispatch returns true when block absent"

got_sweep=$(SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" get milestones.sweep_on_loop_end 2>/dev/null)
assert_equals "$got_sweep" "true" "get milestones.sweep_on_loop_end returns true when block absent"

# --------------------------------------------------------------------------
echo
echo "== Live validation — good and bad configs"

echo '{"version":1,"milestones":{"enabled":true,"fallback":"Backlog","assign_on_file":true,"prioritize_dispatch":false,"sweep_on_loop_end":true}}' > "$tmpdir/shipyard.config.json"
SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" validate --layer repo >/dev/null 2>&1
assert_exit_code "$?" "0" "a full valid milestones block passes validation"

echo '{"version":1,"milestones":{"enabled":true,"banana":true}}' > "$tmpdir/shipyard.config.json"
SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" validate --layer repo >/dev/null 2>&1
assert_exit_code "$?" "70" "an unknown milestones field is rejected (additionalProperties:false)"

echo '{"version":1,"milestones":{"fallback":123}}' > "$tmpdir/shipyard.config.json"
SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" validate --layer repo >/dev/null 2>&1
assert_exit_code "$?" "70" "a wrong-typed fallback (number, not string) is rejected"

echo '{"version":1,"milestones":{"enabled":"yes"}}' > "$tmpdir/shipyard.config.json"
SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" validate --layer repo >/dev/null 2>&1
assert_exit_code "$?" "70" "a wrong-typed enabled (string, not boolean) is rejected"

# --------------------------------------------------------------------------
echo
echo "== Inertness — absent block vs. explicit enabled:false"

rm -f "$tmpdir/shipyard.config.json"

echo '{"version":1,"milestones":{"enabled":false}}' > "$tmpdir/shipyard.config.json"
explicit_get=$(SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" get milestones.enabled 2>/dev/null)
assert_equals "$explicit_get" "false" "explicit milestones.enabled:false reads back false"

rm -f "$tmpdir/shipyard.config.json"
absent_enabled=$(SHIPYARD_REPO_ROOT="$tmpdir" bash "$config_sh" get milestones.enabled 2>/dev/null)
assert_equals "$absent_enabled" "$explicit_get" "absent block and explicit enabled:false resolve to the same value"

# --------------------------------------------------------------------------
echo
echo "== /shipyard:init offers the block"

assert_file_contains "$init_md" "milestones" "init.md mentions milestones"
assert_file_contains "$init_md" "--milestones" "init.md documents a --milestones flag"
assert_file_contains "$init_md" "milestones.enabled" "init.md's install logic writes milestones.enabled"
assert_file_contains "$init_md" "9.8" "init.md has a dedicated step for the milestones offering"

# --------------------------------------------------------------------------
echo
total=$((pass + fail))
if [[ $fail -eq 0 ]]; then
  printf '%sPASS%s  %d/%d assertions passed\n' "$GREEN" "$RESET" "$pass" "$total"
  exit 0
else
  printf '%sFAIL%s  %d/%d assertions failed\n' "$RED" "$RESET" "$fail" "$total"
  exit 1
fi

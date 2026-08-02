#!/usr/bin/env bash
# Test: /shipyard:init step 9.7 — optionally emit the adding-dependencies
# convention into a consuming repo's own CLAUDE.md (issue #1048).
#
# Background — issue #1048: #1045 shipped the standalone
# `shipyard:adding-dependencies` skill and made it reachable from any Claude
# Code session, but nothing yet emits that convention into a *consuming*
# repo's own CLAUDE.md, so a plain interactive session with no shipyard
# skills loaded never inherits the rule. This follow-up extends the existing
# step 9.5 CLAUDE.md-emission mechanism in commands/init.md with a new,
# opt-in (default off) step 9.7, gated on --dep-rule <off|pointer|inline>.
#
# This test guards the *spec* surface — if anyone deletes step 9.7, drops
# the --dep-rule / --dep-rule-scope flags, backs out the default-off gate,
# removes the sentinel-pair idempotency convention, or forgets to prune the
# now-closed "out of scope" bullet from the adding-dependencies skill, this
# test fails.
#
# Pure bash, no external dependencies beyond jq for the plugin.json version
# check (already required across shipyard). Run with:
#
#   bash plugins/shipyard/scripts/tests/init-claude-md-dep-rule-1048.test.sh

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

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_contains() {
  local path="$1"
  local needle="$2"
  local label="$3"
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

assert_file_not_contains() {
  local path="$1"
  local needle="$2"
  local label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s — file missing: %s\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
    return
  fi
  if grep -qF -- "$needle" "$path"; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected %s to NOT contain: %s\n' "$path" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

init_md="$repo_root/plugins/shipyard/commands/init.md"
skill_md="$repo_root/plugins/shipyard/skills/adding-dependencies/SKILL.md"

# --------------------------------------------------------------------------
echo "== /shipyard:init step 9.7 exists and is wired into the flow (#1048)"

assert_file_contains "$init_md" '### 9.7 Optionally append the adding-dependencies rule to CLAUDE.md' "init.md has a step 9.7 heading"
assert_file_contains "$init_md" '#97-optionally-append-the-adding-dependencies-rule-to-claudemd' "step 3 prompt list links to step 9.7"
assert_file_contains "$init_md" "Adding-dependencies \`CLAUDE.md\` rule (default \`off\`)." "step 3 documents the adding-dependencies prompt bullet"

# --------------------------------------------------------------------------
echo "== --dep-rule / --dep-rule-scope flags (#1048)"

assert_file_contains "$init_md" '--dep-rule <off|pointer|inline>' "init.md documents --dep-rule flag with its enum"
assert_file_contains "$init_md" '--dep-rule-scope <global|repo>' "init.md documents --dep-rule-scope flag"
assert_file_contains "$init_md" "Default \`off\` (nothing written)." "init.md pins --dep-rule default to off (opt-in, per parent issue's attribution requirement)"

# --------------------------------------------------------------------------
echo "== pointer vs inline mode content (#1048)"

assert_file_contains "$init_md" 'Skill("shipyard:adding-dependencies")' "step 9.7 pointer mode points at the skill"
assert_file_contains "$init_md" 'self-contained ~6-line summary' "step 9.7 documents the inline-mode self-contained summary"
assert_file_contains "$init_md" 'look up the current stable version from the authoritative registry first' "step 9.7 inline content carries the core rule"
assert_file_contains "$init_md" 'framework-required version, not "latest"' "step 9.7 inline content carries the peer/SDK carve-out"

# --------------------------------------------------------------------------
echo "== sentinel-pair idempotency convention — new vs step 9.5 (#1048)"

assert_file_contains "$init_md" '<!-- shipyard:adding-dependencies:start -->' "step 9.7 documents the start sentinel"
assert_file_contains "$init_md" '<!-- shipyard:adding-dependencies:end -->' "step 9.7 documents the end sentinel"
assert_file_contains "$init_md" 'replace everything between the sentinels' "step 9.7 documents replace-in-place idempotency"
assert_file_contains "$init_md" 'this is a NEW convention step 9.7 introduces, which step 9.5 does NOT already have' "step 9.7 explicitly disclaims step 9.5 already having markdown-level idempotency"

# --------------------------------------------------------------------------
echo "== step 9.7 reuses step 9.5's scope-resolution + append discipline (#1048)"

assert_file_contains "$init_md" "Reuses [step 9.5](#95-optionally-install-the-primary-checkout-guard)'s repo-vs-global scope resolution" "step 9.7 states it reuses step 9.5's scope resolution"

# --------------------------------------------------------------------------
echo "== Related section cites #1048 (#1048)"

assert_file_contains "$init_md" 'Issue [#1048](https://github.com/mattsears18/shipyard/issues/1048)' "init.md Related section cites #1048"

# --------------------------------------------------------------------------
echo "== adding-dependencies skill's out-of-scope bullet retired (#1048)"

assert_file_contains "$skill_md" '## Out of scope for this skill' "adding-dependencies SKILL.md still has the out-of-scope section"
assert_file_not_contains "$skill_md" "Emitting this convention into a *consuming* repo's own \`CLAUDE.md\`" "adding-dependencies SKILL.md's out-of-scope list no longer names the now-shipped CLAUDE.md-emission gap"

# --------------------------------------------------------------------------
echo "== issue-work.md untouched (size-budget carve-out, #1048)"

issue_work_md="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
assert_file_not_contains "$issue_work_md" '--dep-rule' "issue-work.md was not touched by this change (near its own byte ceiling, unrelated to this issue)"

# --------------------------------------------------------------------------
echo "== Plugin version bump"

plugin_json="$repo_root/plugins/shipyard/.claude-plugin/plugin.json"
current_version=$(jq -r '.version' "$plugin_json" 2>/dev/null)
if [[ -n "$current_version" ]]; then
  IFS='.' read -r v_major v_minor v_patch <<< "${current_version%%[-+]*}"
  if [[ "$v_major" =~ ^[0-9]+$ ]] && [[ "$v_minor" =~ ^[0-9]+$ ]] && [[ "$v_patch" =~ ^[0-9]+$ ]] \
       && (( v_major > 4 \
             || (v_major == 4 && v_minor >= 8) )); then
    printf '  %sPASS%s  plugin.json at or past 4.8.0 (actual: %s)\n' \
      "$GREEN" "$RESET" "$current_version"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  plugin.json at or past 4.8.0 (actual: %s)\n' \
      "$RED" "$RESET" "$current_version"
    fail=$((fail+1))
  fi
else
  printf '  %sFAIL%s  plugin.json at or past 4.8.0 — .version missing\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

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

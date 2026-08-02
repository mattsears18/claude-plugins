#!/usr/bin/env bash
# Test: tech-debt-auditor's "Outdated direct dependencies" pass is rewritten
# to surface the drift-detection counterpart to shipyard:adding-dependencies'
# introduction-time rule (#1047).
#
# Background: #1045 shipped a standalone shipyard:adding-dependencies skill
# covering dependency *introduction* — look up the current version before
# adding a new dependency, across every manifest class (npm/pnpm/yarn,
# pip, go, cargo, gem, GitHub Actions `uses:`, Dockerfile FROM,
# .nvmrc/.tool-versions, Gradle, CocoaPods, inline npx <tool>@<version>).
# That rule is introduction-time only — it can't catch drift that
# accumulates on dependencies that were already current when introduced,
# or that predate the rule entirely. #1045's own measurement showed why
# this matters: 46 of 117 Dependabot PRs on mattsears18/lightwork were
# major-version bumps, 30 opened after the original #694 rule landed.
#
# This issue rewrites tech-debt-auditor.md's existing "### 6. Outdated
# direct dependencies" pass in place (not a new audit dimension, not a new
# agent):
#   - threshold: >= 2 major versions behind -> >= 1 major
#   - detection breadth: npm-only -> every manifest class
#     shipyard:adding-dependencies covers, reusing that skill's own
#     per-ecosystem lookup commands
#   - carve-outs: the peer/SDK carve-out (react/react-native,
#     @react-native-firebase/*, expo-*) and the
#     dependencies.new_dep_version: "conservative" opt-out, plus a
#     supply-chain cooldown (min-release-age / cooldown.default-days) as a
#     valid explanation rather than a finding
#   - the Return-summary "Outdated direct deps:" line updated to match
#
# Out of scope for this issue (not asserted here): no new audit dimension
# (tech-debt is already registered in commands/audit.md), no
# pricing-coverage.test.sh entry (no new agent-shim model: frontmatter), no
# auditor-preamble change.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/dep-freshness-audit-1047.test.sh

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

auditor_path="$repo_root/plugins/shipyard/agents/tech-debt-auditor.md"
skill_path="$repo_root/plugins/shipyard/skills/adding-dependencies/SKILL.md"
audit_command_path="$repo_root/plugins/shipyard/commands/audit.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s (file missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail + 1))
    return
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s (did not find %q in %s)\n' "$RED" "$RESET" "$label" "$needle" "$path"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local path="$1" needle="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    printf '  %sFAIL%s  %s (file missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail + 1))
    return
  fi
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    printf '  %sFAIL%s  %s (unexpectedly found %q in %s)\n' "$RED" "$RESET" "$label" "$needle" "$path"
    fail=$((fail + 1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  fi
}

echo "== dep-freshness-audit-1047.test.sh =="

assert_file_exists "$auditor_path" "plugins/shipyard/agents/tech-debt-auditor.md exists"

# --- Threshold changed from >= 2 major to >= 1 major ---
assert_contains "$auditor_path" "A direct dep ≥ 1 major version behind the registry's current stable → P2" \
  "auditor's finding threshold is now >= 1 major version behind"
assert_not_contains "$auditor_path" "A direct dep ≥ 2 major versions behind → P2" \
  "auditor no longer states the old >= 2 major threshold"

# --- Detection breadth: every manifest class shipyard:adding-dependencies covers ---
assert_contains "$auditor_path" "shipyard:adding-dependencies" \
  "auditor cross-references the shipyard:adding-dependencies skill by name"
assert_contains "$auditor_path" "npm outdated --json" \
  "auditor still covers the npm/yarn/pnpm path"
assert_contains "$auditor_path" "pip index versions <pkg>" \
  "auditor covers the Python lookup"
assert_contains "$auditor_path" "go list -m -versions <pkg>" \
  "auditor covers the Go lookup"
assert_contains "$auditor_path" "cargo search <pkg>" \
  "auditor covers the Rust lookup"
assert_contains "$auditor_path" "gem list -r -e <pkg>" \
  "auditor covers the Ruby lookup"
assert_contains "$auditor_path" "gh api repos/<owner>/<action>/releases/latest --jq .tag_name" \
  "auditor covers the GitHub Actions uses: pin lookup"
assert_contains "$auditor_path" "Dockerfile" \
  "auditor covers Dockerfile FROM base images"
assert_contains "$auditor_path" ".nvmrc" \
  "auditor covers .nvmrc"
assert_contains "$auditor_path" ".tool-versions" \
  "auditor covers .tool-versions"
assert_contains "$auditor_path" "Gradle" \
  "auditor covers Gradle coordinates"
assert_contains "$auditor_path" "CocoaPods" \
  "auditor covers CocoaPods pods"
assert_contains "$auditor_path" "pod trunk info <pod>" \
  "auditor gives the CocoaPods lookup command"

# --- Carve-outs added to the "Don't file" list ---
assert_contains "$auditor_path" "Peer/SDK-constrained packages sitting \"behind\" registry latest by design" \
  "auditor's Don't-file list carries the peer/SDK carve-out"
assert_contains "$auditor_path" "\`react\`/\`react-native\`" \
  "auditor's peer/SDK carve-out names react/react-native"
assert_contains "$auditor_path" "@react-native-firebase/*\` set" \
  "auditor's peer/SDK carve-out names the coordinated @react-native-firebase/* set"
assert_contains "$auditor_path" "every \`expo-*\` package" \
  "auditor's peer/SDK carve-out names expo-* packages"
assert_contains "$auditor_path" "dependencies.new_dep_version: \"conservative\"" \
  "auditor's Don't-file list carries the conservative-mode opt-out"
assert_contains "$auditor_path" "supply-chain cooldown" \
  "auditor's Don't-file list treats a supply-chain cooldown as a valid explanation"
assert_contains "$auditor_path" "min-release-age" \
  "auditor names min-release-age as a cooldown signal"
assert_contains "$auditor_path" "cooldown.default-days" \
  "auditor names cooldown.default-days as a cooldown signal"

# --- Return-summary line updated to match the new threshold and breadth ---
assert_contains "$auditor_path" "Outdated direct deps: <N >= 1 major behind" \
  "auditor's Return-summary Outdated-direct-deps line reflects the new >= 1 major threshold"
assert_not_contains "$auditor_path" "Outdated direct deps: <N >= 2 major behind>" \
  "auditor's Return-summary no longer states the old >= 2 major threshold"

# --- This is an in-place rewrite of the existing pass, not a new sub-check heading ---
assert_contains "$auditor_path" "### 6. Outdated direct dependencies" \
  "auditor keeps the existing '### 6. Outdated direct dependencies' heading (in-place rewrite, not a new pass)"

# --- Shared-file caution: only THIS issue's out-of-scope bullet removed from the skill ---
assert_file_exists "$skill_path" "plugins/shipyard/skills/adding-dependencies/SKILL.md exists"
assert_not_contains "$skill_path" "A \`tech-debt-auditor\` sub-check that flags dependencies already sitting ≥1 major behind." \
  "adding-dependencies skill's out-of-scope list no longer names the tech-debt-auditor sub-check (now implemented)"
# The other out-of-scope bullets (unrelated to this issue) must survive untouched.
assert_contains "$skill_path" "Emitting this convention into a *consuming* repo's own" \
  "adding-dependencies skill still names the CLAUDE.md-emission follow-up (#1048, untouched by this issue)"

# --- No new audit dimension: tech-debt is already registered in commands/audit.md ---
assert_file_exists "$audit_command_path" "plugins/shipyard/commands/audit.md exists"
assert_contains "$audit_command_path" "| \`tech-debt\` | \`shipyard:tech-debt-auditor\` | no |" \
  "commands/audit.md already registers tech-debt -> shipyard:tech-debt-auditor (no new dimension added)"

printf '\n'
if [[ "$fail" -eq 0 ]]; then
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
else
  printf '%sFAIL%s  %d passed, %d failed\n' "$RED" "$RESET" "$pass" "$fail"
  exit 1
fi

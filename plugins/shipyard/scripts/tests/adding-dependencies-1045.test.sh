#!/usr/bin/env bash
# Test: the "adding a NEW dependency" rule lives in a standalone
# shipyard:adding-dependencies skill, broadened past package-manager
# manifests and reachable outside /shipyard:do-work worker dispatch (#1045).
#
# Background: issue #694 established "install the latest stable version when
# introducing a new dependency" as a fragment of worker-preamble
# (node-bootstrap.md), scoped to package-manager manifests only
# (package.json / requirements.txt / go.mod / Cargo.toml / Gemfile) and
# reachable only from a /shipyard:do-work worker dispatch. Neither
# restriction held: mattsears18/lightwork accumulated 30 more major-version
# Dependabot PRs after #694 landed, including two 3-major GitHub Actions
# drags (actions/checkout v4->v7, actions/upload-artifact v4->v7) in a
# manifest class (.github/workflows `uses:` pins) the original rule never
# covered, because it isn't a package-manager manifest.
#
# This is the phase-1 slice of #1045: a standalone
# plugins/shipyard/skills/adding-dependencies/SKILL.md skill holding the
# rule, with an explicit numbered "look up the current stable version from
# the authoritative registry first" step and per-ecosystem lookup commands
# broadened to cover .github/workflows `uses:`, Dockerfile FROM tags,
# .nvmrc/.tool-versions, Gradle, and CocoaPods, alongside the package-manager
# path #694 already covered — with the peer/SDK carve-out and the
# dependencies.new_dep_version config knob preserved verbatim.
# node-bootstrap.md keeps a short hot-path pointer to the new skill, and the
# worker-preamble fragment index + issue-work.md are re-pointed at it.
#
# Out of scope for this issue (filed as follow-ups, not asserted here):
# item 4 (a pre-PR written-version-vs-registry verification check), item 5
# (a tech-debt-auditor >=1-major-behind sub-check), and gap 5's emission of
# the rule into a consuming repo's own CLAUDE.md.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/adding-dependencies-1045.test.sh

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

skill_path="$repo_root/plugins/shipyard/skills/adding-dependencies/SKILL.md"
node_bootstrap_path="$repo_root/plugins/shipyard/skills/worker-preamble/node-bootstrap.md"
worker_preamble_skill_path="$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"
issue_work_path="$repo_root/plugins/shipyard/agents/issue-worker/issue-work.md"
config_schema_path="$repo_root/plugins/shipyard/schemas/shipyard.config.schema.json"

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

echo "== adding-dependencies-1045.test.sh =="

# --- The standalone skill exists, with proper frontmatter ---
assert_file_exists "$skill_path" "plugins/shipyard/skills/adding-dependencies/SKILL.md exists"
assert_contains "$skill_path" "name: adding-dependencies" \
  "SKILL.md declares its skill name in frontmatter"
if [[ -f "$skill_path" ]] && [[ "$(head -n1 "$skill_path")" == "---" ]]; then
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "SKILL.md opens with a frontmatter block"
  pass=$((pass + 1))
else
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "SKILL.md opens with a frontmatter block"
  fail=$((fail + 1))
fi

# --- Item 1+2: explicit numbered lookup-first step, ecosystem-independent ---
assert_contains "$skill_path" "look up the current stable version from the authoritative registry" \
  "skill promotes 'look up the current version' to an explicit, ecosystem-independent step"
assert_contains "$skill_path" "## Step 1" \
  "skill numbers the lookup-first step"
assert_contains "$skill_path" "Never hand-write a version from memory or training data" \
  "skill states the never-hand-write-from-memory rule"

# --- Item 1: broadened per-ecosystem lookup commands, past package managers ---
assert_contains "$skill_path" "uses:" \
  "skill covers GitHub Actions uses: pins"
assert_contains "$skill_path" "gh api repos/<owner>/<action>/releases/latest --jq .tag_name" \
  "skill gives the GitHub Actions release lookup command"
assert_contains "$skill_path" "Dockerfile" \
  "skill covers Dockerfile FROM tags"
assert_contains "$skill_path" "FROM <image>:<tag>" \
  "skill names the Dockerfile FROM pin target"
assert_contains "$skill_path" ".nvmrc" \
  "skill covers .nvmrc"
assert_contains "$skill_path" ".tool-versions" \
  "skill covers .tool-versions"
assert_contains "$skill_path" "Gradle" \
  "skill covers Gradle coordinates"
assert_contains "$skill_path" "CocoaPods" \
  "skill covers CocoaPods pods"
assert_contains "$skill_path" "npx <tool>@<version>" \
  "skill covers inline npx <tool>@<version> invocations"
# Package-manager path from #694 must still be present (broadened, not replaced).
assert_contains "$skill_path" "npm install <pkg>@latest" \
  "skill still covers the npm/yarn/pnpm package-manager path from #694"
assert_contains "$skill_path" "go get <pkg>@latest" \
  "skill still covers the Go package-manager path"
assert_contains "$skill_path" "cargo add <pkg>" \
  "skill still covers the Rust package-manager path"
assert_contains "$skill_path" "bundle add <pkg>" \
  "skill still covers the Ruby package-manager path"

# --- Peer/SDK carve-out preserved verbatim ---
assert_contains "$skill_path" "The load-bearing carve-out — peer/SDK-constrained packages use the framework-required version, NOT \"latest\"" \
  "skill preserves the peer/SDK carve-out heading verbatim"
assert_contains "$skill_path" "React / React Native:" \
  "skill preserves the React/React Native carve-out bullet"
assert_contains "$skill_path" "@react-native-firebase/*" \
  "skill preserves the @react-native-firebase/* carve-out bullet"
assert_contains "$skill_path" "expo-*\` / many \`react-native-*" \
  "skill preserves the expo-* carve-out bullet"
assert_contains "$skill_path" "npx expo install <pkg>" \
  "skill preserves the expo install preference for Expo repos"
assert_contains "$skill_path" "**unconditional**" \
  "skill states the carve-out is unconditional"

# --- dependencies.new_dep_version config knob preserved verbatim, incl. conservative mode ---
assert_contains "$skill_path" "dependencies.new_dep_version" \
  "skill references the dependencies.new_dep_version config knob"
assert_contains "$skill_path" "\"conservative\"" \
  "skill preserves the conservative mode of the config knob"
assert_contains "$skill_path" "introduction only" \
  "skill scopes the rule to dependency introduction, not upgrades"

# --- Supply-chain-cooldown interaction documented ---
assert_contains "$skill_path" "min-release-age" \
  "skill documents the supply-chain-cooldown interaction (min-release-age)"
assert_contains "$skill_path" "cooldown" \
  "skill names the cooldown interaction by name"

# --- Out-of-scope items (4, 5, and gap 5's CLAUDE.md emission) named as follow-ups, not implemented here ---
assert_contains "$skill_path" "Out of scope for this skill" \
  "skill names its own out-of-scope items rather than silently omitting them"

# --- node-bootstrap.md keeps a short hot-path pointer, not the full section ---
assert_contains "$node_bootstrap_path" "shipyard:adding-dependencies" \
  "node-bootstrap.md points to the relocated shipyard:adding-dependencies skill"
assert_not_contains "$node_bootstrap_path" "## Adding a NEW dependency — default to the latest stable version" \
  "node-bootstrap.md no longer carries the old #694-era section heading"
assert_not_contains "$node_bootstrap_path" "\"conservative\" for a repo that wants introductions pinned" \
  "node-bootstrap.md no longer duplicates the full policy-knob paragraph (moved to the new skill)"

# --- worker-preamble fragment index (SKILL.md) re-pointed ---
assert_contains "$worker_preamble_skill_path" "adding-dependencies/SKILL.md" \
  "worker-preamble SKILL.md's fragment index links to the relocated skill"
assert_contains "$worker_preamble_skill_path" "shipyard:adding-dependencies" \
  "worker-preamble SKILL.md's fragment index names shipyard:adding-dependencies"

# --- issue-work.md re-pointed ---
assert_contains "$issue_work_path" "shipyard:adding-dependencies" \
  "issue-work.md step 4 points workers at the shipyard:adding-dependencies skill"
assert_not_contains "$issue_work_path" "Adding a NEW dependency — default to the latest stable version" \
  "issue-work.md no longer cites the old worker-preamble section title"

# --- The config schema knob itself is untouched (preserved verbatim, per dispatch instructions) ---
assert_contains "$config_schema_path" "\"new_dep_version\"" \
  "shipyard.config.schema.json still declares the new_dep_version knob"
assert_contains "$config_schema_path" "\"latest-stable\", \"conservative\"" \
  "shipyard.config.schema.json still declares both new_dep_version enum values"

printf '\n'
if [[ "$fail" -eq 0 ]]; then
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
else
  printf '%sFAIL%s  %d passed, %d failed\n' "$RED" "$RESET" "$pass" "$fail"
  exit 1
fi

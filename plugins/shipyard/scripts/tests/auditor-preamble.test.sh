#!/usr/bin/env bash
# Test: the auditor-preamble skill exists and every *-auditor agent references
# it instead of re-inlining the same generic scaffold, while each agent keeps
# its own dispatchable identity (frontmatter) and domain-specific content.
#
# Background — issue #886: all 18 auditor agents (agents/*-auditor.md,
# dispatched by name from commands/audit.md) already deferred to
# shipyard:filing-github-issues and shipyard:audit-rubrics for filing
# mechanics and severity/grouping rules, but each ALSO re-inlined the same
# generic "no approval gates" / "no git writes" bullets verbatim. This test is
# the regression guard: if anyone deletes the auditor-preamble skill, drops an
# auditor's reference to it, re-duplicates the generic Don't bullets, or
# accidentally strips an auditor's frontmatter identity while doing so, the
# test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/auditor-preamble.test.sh

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

skill_path="$repo_root/plugins/shipyard/skills/auditor-preamble/SKILL.md"
agents_dir="$repo_root/plugins/shipyard/agents"

# Every *-auditor.md agent file that should reference the shared skill.
# (dx-auditor, lighthouse-auditor, etc. are already *-auditor-suffixed; the
# glob below is the same enumeration commands/audit.md's dispatch table uses.)
# Built with a plain while/read loop rather than `mapfile`/`readarray` — this
# suite runs under macOS's bundled bash 3.2, which has neither (see the same
# constraint documented in release-bump-required.test.sh / shellcheck.test.sh).
auditor_files=()
while IFS= read -r f; do
  auditor_files+=("$(basename "$f")")
done < <(find "$agents_dir" -maxdepth 1 -type f -name '*-auditor.md' 2>/dev/null | sort)

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    did NOT expect to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

echo "auditor-preamble regression tests (issue #886)"
echo

# (0) The corpus enumeration itself must have found all 18 known auditors —
# guards against the glob silently matching zero files if the agents/
# directory layout ever changes.
if [[ "${#auditor_files[@]}" -ge 18 ]]; then
  printf '  %sPASS%s  found %d *-auditor.md agent files (expected >= 18)\n' "$GREEN" "$RESET" "${#auditor_files[@]}"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  found only %d *-auditor.md agent files (expected >= 18)\n' "$RED" "$RESET" "${#auditor_files[@]}"
  fail=$((fail+1))
fi

# (1) The skill file itself exists with proper frontmatter and documents the
# scaffold it owns.
assert_file_exists "$skill_path" "auditor-preamble skill file exists"

if [[ -f "$skill_path" ]]; then
  assert_contains "$skill_path" "name: auditor-preamble" \
    "skill frontmatter declares name: auditor-preamble"
  assert_contains "$skill_path" "description:" \
    "skill frontmatter has a description field"
  assert_contains "$skill_path" "Don't ask for approval before filing" \
    "skill documents the no-approval-gates convention"
  assert_contains "$skill_path" "git add" \
    "skill documents the no-git-writes convention"
  assert_contains "$skill_path" "Return-summary generic shape" \
    "skill documents the generic Return-summary shape"
  assert_contains "$skill_path" "Required-inputs convention" \
    "skill documents the required-inputs convention"
  assert_contains "$skill_path" "Audit-label convention" \
    "skill documents the audit-label convention"
  assert_contains "$skill_path" "shipyard:audit-rubrics" \
    "skill cross-references audit-rubrics"
  assert_contains "$skill_path" "shipyard:filing-github-issues" \
    "skill cross-references filing-github-issues"
  # Frontmatter identity is explicitly out of scope for this skill — it must
  # never be the thing consolidated, since each auditor is a dispatchable
  # subagent_type keyed on its own frontmatter.
  assert_contains "$skill_path" "Never move this into a skill" \
    "skill explicitly disclaims owning agent frontmatter identity"
fi

echo

# (2) Every *-auditor.md file references the shared skill by name, and still
# carries its own frontmatter identity (name / model / description) — the
# consolidation must not have collapsed or renamed any agent.
for f in "${auditor_files[@]}"; do
  path="$agents_dir/$f"
  expected_name="${f%.md}"

  assert_contains "$path" "shipyard:auditor-preamble" \
    "$f references the shipyard:auditor-preamble skill"
  assert_contains "$path" "name: $expected_name" \
    "$f keeps its own frontmatter name: $expected_name"
  assert_contains "$path" "description:" \
    "$f keeps its own frontmatter description"
  assert_contains "$path" "model:" \
    "$f keeps its own frontmatter model pin"

  # Regression guard: the generic bullets this refactor extracted must not
  # be re-duplicated verbatim. (security-auditor's customized variant —
  # "Don't ask for approval before filing — P0/P1 security issues especially
  # want to land fast." — does not match this literal, period-terminated
  # string, so it correctly stays untouched and unflagged.)
  assert_not_contains "$path" "- Don't ask for approval before filing." \
    "$f does not re-duplicate the generic no-approval-gates bullet"
  assert_not_contains "$path" "- Don't \`git add\` or commit anything." \
    "$f does not re-duplicate the generic no-git-writes bullet"
done

echo

# (3) commands/audit.md's dispatch table is untouched by this refactor —
# sanity check that every auditor is still wired in.
audit_cmd_path="$repo_root/plugins/shipyard/commands/audit.md"
assert_file_exists "$audit_cmd_path" "commands/audit.md exists"

if [[ -f "$audit_cmd_path" ]]; then
  for f in "${auditor_files[@]}"; do
    expected_name="${f%.md}"
    assert_contains "$audit_cmd_path" "shipyard:$expected_name" \
      "audit.md dispatch table still references shipyard:$expected_name"
  done
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

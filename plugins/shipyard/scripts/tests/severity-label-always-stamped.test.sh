#!/usr/bin/env bash
# Test: the shared filing-github-issues skill documents an explicit,
# auto-create-and-apply P0/P1/P2 severity-label convention (#889).
#
# Background — issue #889: a `/shipyard:audit all` run filed 6 of 24
# issues with a P0/P1/P2 severity clearly stated in the title/body but
# with NO matching GitHub label. The data-lifecycle and release-readiness
# auditors omitted the label on every issue they filed that run; the
# security auditor missed it on one of two. `is:open label:P1`-style
# triage filters silently miss a severity that only exists as prose.
#
# Root cause: none of the 18 auditor agent files, nor the shared
# `shipyard:filing-github-issues` / `shipyard:audit-rubrics` skills they
# all load, ever instructed a `gh issue create` call to pass `--label
# "P<n>"`. The fix lives in the shared filing skill (single source of
# truth every auditor already references) rather than duplicated across
# auditors — see `shipyard-label-always-stamped.test.sh` for the
# precedent this test follows for the `shipyard` provenance label.
#
# This test is the regression guard. It asserts:
# 1. filing-github-issues SKILL.md has a "Severity label" section with
#    the ensure-then-label pattern (idempotent create for P0/P1/P2 +
#    --label "P<n>").
# 2. The SKILL.md filing command examples include --label "P1" alongside
#    --label shipyard.
# 3. audit-rubrics SKILL.md's severity-bucket section points at the
#    filing skill and states the bucket is a filing requirement, not
#    just body prose.
# 4. Every *-auditor.md agent file references both shared skills (so the
#    single-source-of-truth fix actually reaches every auditor) — this
#    is a structural check, not a per-agent duplication of the rule.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/severity-label-always-stamped.test.sh

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

filing_skill="$repo_root/plugins/shipyard/skills/filing-github-issues/SKILL.md"
rubrics_skill="$repo_root/plugins/shipyard/skills/audit-rubrics/SKILL.md"
agents_dir="$repo_root/plugins/shipyard/agents"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s:\n      %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

echo "severity-label-always-stamped regression tests (issue #889)"
echo

# ── 1. filing-github-issues SKILL.md ──────────────────────────────────────────
echo "1. filing-github-issues SKILL.md"

assert_contains "$filing_skill" \
  "## Severity label" \
  "SKILL.md has a '## Severity label' section"

assert_contains "$filing_skill" \
  "gh label create P0 --repo <owner/repo>" \
  "SKILL.md contains the idempotent P0 label-create command"

assert_contains "$filing_skill" \
  "gh label create P1 --repo <owner/repo>" \
  "SKILL.md contains the idempotent P1 label-create command"

assert_contains "$filing_skill" \
  "gh label create P2 --repo <owner/repo>" \
  "SKILL.md contains the idempotent P2 label-create command"

assert_contains "$filing_skill" \
  '--label "P0"' \
  "SKILL.md instructs --label \"P0\"/\"P1\"/\"P2\" on gh issue create"

assert_contains "$filing_skill" \
  "is not optional" \
  "SKILL.md states the severity label is not optional"

# ── 2. Filing command examples include the severity label ─────────────────────
echo
echo "2. filing-github-issues SKILL.md filing command examples"

assert_contains "$filing_skill" \
  $'--label shipyard \\\n  --label "P1" \\' \
  "SKILL.md filing-command HEREDOC example includes --label \"P1\" alongside --label shipyard"

# ── 3. audit-rubrics SKILL.md cross-reference ──────────────────────────────────
echo
echo "3. audit-rubrics SKILL.md"

assert_contains "$rubrics_skill" \
  "filing requirement, not just body prose" \
  "SKILL.md states the severity bucket is a filing requirement, not just body prose"

assert_contains "$rubrics_skill" \
  "shipyard:filing-github-issues" \
  "SKILL.md cross-references the filing skill for how the bucket becomes a label"

# ── 4. Every auditor agent references both shared skills ──────────────────────
echo
echo "4. Every *-auditor.md agent references both shared skills"

shopt -s nullglob
auditor_files=("$agents_dir"/*-auditor.md)
shopt -u nullglob

if [[ ${#auditor_files[@]} -eq 0 ]]; then
  printf '  %sFAIL%s  no *-auditor.md files found under %s\n' "$RED" "$RESET" "$agents_dir"
  fail=$((fail+1))
else
  for f in "${auditor_files[@]}"; do
    base="$(basename "$f")"
    assert_contains "$f" "shipyard:filing-github-issues" \
      "$base references shipyard:filing-github-issues"
    assert_contains "$f" "shipyard:audit-rubrics" \
      "$base references shipyard:audit-rubrics"
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

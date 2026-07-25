#!/usr/bin/env bash
# Test: security-auditor.md gates branch-ruleset / CODEOWNERS remediation
# advice on live bypass_actors + collaborator-count evidence (issue #938).
#
# Background — issue #938: the security-auditor agent emitted branch-ruleset
# remediation advice (issue #867's "Suggested approach") without reading the
# target repo's `bypass_actors` or push-capable collaborator count. Applied
# as written to a single-maintainer repo with an empty bypass_actors list,
# the suggested `required_approving_review_count: 1` would have deadlocked
# every future PR — including every /shipyard:do-work auto-merge PR — because
# GitHub does not let a PR author approve their own PR.
#
# This test pins the new pass-8 guardrail language in security-auditor.md:
# the auditor must gather bypass_actors + collaborator-count evidence before
# recommending a review-count bump or CODEOWNERS enforcement, must refuse to
# recommend the change when the repo shape would deadlock, and must
# scope-check any CODEOWNERS pattern against routine automated-PR paths.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/security-auditor.test.sh

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

agent_path="$repo_root/plugins/shipyard/agents/security-auditor.md"

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

echo "security-auditor branch-ruleset remediation gate regression tests (issue #938)"
echo

assert_file_exists "$agent_path" "security-auditor agent file exists"

if [[ -f "$agent_path" ]]; then
  assert_contains "$agent_path" "name: security-auditor" \
    "frontmatter declares name: security-auditor"

  # The new pass must exist and be named clearly enough to survive a future
  # renumbering of the earlier passes.
  assert_contains "$agent_path" "Branch-ruleset / CODEOWNERS remediation gate" \
    "agent documents the branch-ruleset/CODEOWNERS remediation gate pass"

  # Evidence-gathering commands — the two live signals the gate depends on.
  assert_contains "$agent_path" "bypass_actors" \
    "agent reads bypass_actors before recommending a ruleset change"
  assert_contains "$agent_path" "collaborators" \
    "agent reads the collaborator set before recommending a ruleset change"
  # shellcheck disable=SC2016
  assert_contains "$agent_path" 'select(.permissions.push == true)' \
    "agent scopes the collaborator count to push-capable roles"

  # The core guardrail: never recommend required_approving_review_count > 0
  # on a single-maintainer / no-bypass-actor shape.
  assert_contains "$agent_path" "Never recommend raising \`required_approving_review_count\` above 0" \
    "agent states the review-count deadlock guardrail"
  assert_contains "$agent_path" "fewer than 2" \
    "agent's guardrail names the <2-collaborator deadlock condition"
  assert_contains "$agent_path" "bypass_actors" \
    "agent's guardrail references bypass_actors as the second deadlock condition"

  # The CODEOWNERS self-lock check.
  assert_contains "$agent_path" "require_code_owner_review" \
    "agent covers the require_code_owner_review recommendation case"
  assert_contains "$agent_path" "subset of \`{sole maintainer}\`" \
    "agent checks whether the CODEOWNERS owner set is a self-lock"

  # The CODEOWNERS-breadth scope-check.
  assert_contains "$agent_path" "routine automated PRs" \
    "agent scope-checks CODEOWNERS pattern breadth against routine automated PRs"

  # Never apply the change itself — read-only auditor discipline.
  assert_contains "$agent_path" "never call \`gh api -X PUT\`/\`PATCH\`/\`-X POST\` yourself" \
    "agent states it never applies the ruleset change itself"

  # Don't-list reinforcement, cross-referencing the pass and the issue.
  assert_contains "$agent_path" "see pass 8" \
    "Don't section cross-references pass 8"
  assert_contains "$agent_path" "issue #938" \
    "agent cites issue #938 as the regression this guards against"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

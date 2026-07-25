#!/usr/bin/env bash
# Test: the operator layer classifies a console action as an access-control
# hand-back by its EFFECT, not by keyword or provider-console location, and
# does not pre-emptively hand back an out-of-category action.
#
# Background — issue #936: the pre-#936 rule defined the security carve-out
# as "any 'security' toggle" plus a keyword list, and stated that the
# boundary "outranks explicit user authorization". Two defects followed:
#
#   1. Over-broad classification. `vercel env rm` of 6 provably-dead,
#      zero-consumer `EXPO_PUBLIC_FIREBASE_*` env vars was handed back as
#      "security/access-control" even though it grants and revokes nobody's
#      access — it is dead-config cleanup that happens to be reached
#      through a hosting provider's project-settings console.
#   2. Wrong ordering. The hand-back fired BEFORE the harness permission
#      classifier was ever consulted, so the maintainer was never offered
#      the scoped allow-rule (e.g. `Bash(vercel env rm:*)`) that would have
#      unblocked the work. The layer that actually owns the permission
#      decision never got asked.
#
# #936 narrows the category to an effect-based test — "changes who can
# access what, or the strength of an authentication/authorization control"
# — and routes everything outside it through attempt-then-degrade via the
# existing two-denials branch.
#
# What #936 deliberately did NOT change, and what this guard pins:
#   - The untrusted-author block still applies in BOTH columns. That is the
#     defense against a prompt-injected issue body manufacturing apparent
#     authorization; removing it alongside the redundancy was declined.
#   - A genuine in-category access-control mutation is still an
#     unconditional hand-back that outranks standing authorization.
#
# This is the regression guard: if the classification reverts to keyword
# matching, if pre-emptive hand-back returns for out-of-category actions,
# or if the untrusted-author carve-out is dropped, the test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/operator-security-classification-936.test.sh

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

operate_dir="$repo_root/plugins/shipyard/commands/do-work/operate"
safety_path="$operate_dir/03-error-handling-and-safety.md"
playbooks_path="$operate_dir/02-execution-and-playbooks.md"
queue_path="$operate_dir/01-queue-and-authorization.md"

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
    printf '    expected to find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to NOT find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

echo ""
echo "Test: effect-based operator security classification (#936 regression guard)"
echo ""

assert_file_exists "$safety_path"    "operate/03-error-handling-and-safety.md exists"
assert_file_exists "$playbooks_path" "operate/02-execution-and-playbooks.md exists"
assert_file_exists "$queue_path"     "operate/01-queue-and-authorization.md exists"

echo ""
echo "The effect-based definition is present and load-bearing"
echo ""

# The definition itself must appear in BOTH the boundary statement and the
# playbook that implements it — a definition in only one place drifts.
assert_contains "$safety_path" \
  "changes **who can access what**" \
  "safety boundary defines the category by effect"

assert_contains "$playbooks_path" \
  "changes **who can access what**" \
  "playbook carries the same effect-based definition"

assert_contains "$safety_path" \
  "Classify by effect, not by keyword or console location" \
  "safety boundary states the classify-by-effect rule explicitly"

# Both files must cite #936 so the narrowing is traceable.
assert_contains "$safety_path"    "issues/936" "safety boundary references issue #936"
assert_contains "$playbooks_path" "issues/936" "playbook references issue #936"
assert_contains "$queue_path"     "issues/936" "queue expectation note references issue #936"

echo ""
echo "Keyword-based classification is gone"
echo ""

# The pre-#936 catch-all is the exact defect: it swept in anything a
# provider filed under a "Security" heading regardless of effect.
assert_not_contains "$safety_path" \
  'any "security" toggle' \
  "safety boundary no longer classifies on the catch-all 'any security toggle'"

assert_not_contains "$playbooks_path" \
  'any "security" toggle' \
  "playbook no longer classifies on the catch-all 'any security toggle'"

echo ""
echo "Out-of-category actions are attempted, not pre-empted"
echo ""

assert_contains "$safety_path" \
  "Out-of-category actions are NOT pre-empted — attempt, then degrade" \
  "safety boundary mandates attempt-then-degrade for out-of-category actions"

# The degrade path must route through the EXISTING two-denials machinery
# rather than inventing a parallel one.
assert_contains "$safety_path" \
  "denied-by-classifier" \
  "safety boundary routes the degrade through the two-denials branch"

assert_contains "$playbooks_path" \
  "denied-by-classifier" \
  "playbook routes the degrade through the two-denials branch"

# The worked example from the issue must survive as a concrete anchor —
# this is the case that motivated the narrowing.
assert_contains "$safety_path" \
  "EXPO_PUBLIC_" \
  "safety boundary carries the dead-config worked example"

assert_contains "$playbooks_path" \
  "zero-consumer non-secret config" \
  "attempt column names zero-consumer non-secret config removal"

echo ""
echo "What #936 deliberately preserved"
echo ""

# The injection defense must NOT have been dropped along with the
# redundancy — this was explicitly declined when #936 was re-scoped.
assert_contains "$safety_path" \
  "does not scope down for untrusted-derived actions" \
  "untrusted-derived actions still hand back regardless of category"

assert_contains "$playbooks_path" \
  "Untrusted-derived actions are unaffected by this narrowing" \
  "playbook preserves the untrusted-author block in both columns"

# A genuine in-category mutation is still unconditional.
assert_contains "$safety_path" \
  "outranks explicit user authorization" \
  "in-category mutations still outrank explicit user authorization"

# The conservative default survives, scoped to genuine ambiguity.
assert_contains "$playbooks_path" \
  "hand it back" \
  "conservative default on genuine ambiguity is retained"

echo ""
if [[ $fail -eq 0 ]]; then
  printf '%sAll %d checks passed.%s\n\n' "$GREEN" "$pass" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n\n' "$RED" "$pass" "$fail" "$RESET"
  exit 1
fi

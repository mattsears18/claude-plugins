#!/usr/bin/env bash
# Test: the operator layer's access-control carve-out further splits by
# DIRECTION, not just by effect — a mutation that NARROWS access, REVOKES a
# grant, or DELETES a value a merged change made redundant is attempted
# (not a category hand-back); only a mutation that WIDENS/GRANTS access or
# CREATES a new credential is a hand-back. Read-only verification stays
# unconditionally inside the boundary either way.
#
# Background — issue #970: #936 narrowed the carve-out to an effect-based
# test ("changes who can access what") but did not ask WHICH WAY the change
# moves exposure. On a real `agent-console` queue this meant an action that
# genuinely tightens security — e.g. adding an HTTP-referrer restriction to
# a Maps API key — was handed back exactly like one that loosens it. The
# sharpest example: refusing to add the referrer restriction leaves the key
# MORE exposed, not less, so the pre-#970 rule produced the less-safe
# outcome. #970 also asks the spec to say plainly that a credential-rotation
# task stays partly blocked by the separate, harness-level prohibition on
# creating/entering a new credential, not because rotation is a "security
# setting."
#
# What #970 deliberately did NOT change:
#   - The #936 effect-based test and its exact wording (a regression here
#     would also fail the #936 guard — this file only pins the ADDITIONAL
#     direction split layered on top).
#   - The untrusted-author carve-out — still applies regardless of
#     direction or category.
#   - The read-only `verify` outcome's unconditional pass — direction is
#     irrelevant to something that never mutates.
#
# This is the regression guard: if the direction split is removed, if
# narrowing/deleting actions revert to being classified as hand-backs on
# category alone, or if the harness-level credential-creation boundary gets
# conflated back into "security setting" language, this test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/operator-security-classification-970.test.sh

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
thin_entry_path="$repo_root/plugins/shipyard/commands/do-work.md"

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

echo ""
echo "Test: direction-based operator access-control classification (#970 regression guard)"
echo ""

assert_file_exists "$safety_path"     "operate/03-error-handling-and-safety.md exists"
assert_file_exists "$playbooks_path"  "operate/02-execution-and-playbooks.md exists"
assert_file_exists "$queue_path"      "operate/01-queue-and-authorization.md exists"
assert_file_exists "$thin_entry_path" "do-work.md thin entry exists"

echo ""
echo "The prior #936 effect-based test survives unchanged (direction layers on top, doesn't replace it)"
echo ""

assert_contains "$safety_path" \
  "changes **who can access what**" \
  "safety boundary still defines in-category by effect (#936 wording intact)"

assert_contains "$playbooks_path" \
  "changes **who can access what**" \
  "playbook still carries the #936 effect-based definition"

echo ""
echo "The direction split is present and load-bearing"
echo ""

assert_contains "$safety_path" \
  "issues/970" \
  "safety boundary references issue #970"

assert_contains "$playbooks_path" \
  "issues/970" \
  "playbook references issue #970"

assert_contains "$queue_path" \
  "issues/970" \
  "queue expectation note references issue #970"

assert_contains "$thin_entry_path" \
  "issues/970" \
  "thin entry references issue #970"

# The narrowing-is-attempted direction must be stated explicitly, not just
# implied by omission.
assert_contains "$safety_path" \
  "narrows" \
  "safety boundary names narrowing as the safe direction"

assert_contains "$playbooks_path" \
  "narrows" \
  "playbook names narrowing as the safe direction"

# The widening/credential-creation direction must be stated as the one that
# still hand-backs.
assert_contains "$safety_path" \
  "creates a new credential" \
  "safety boundary names credential-creation as a hand-back trigger"

assert_contains "$playbooks_path" \
  "creates a new credential" \
  "playbook names credential-creation as a hand-back trigger"

# The worked example from the issue (#2850 — HTTP-referrer restriction on an
# API key) must survive as a concrete anchor for the narrowing direction.
assert_contains "$safety_path" \
  "HTTP-referrer restriction" \
  "safety boundary carries the API-key referrer-restriction worked example"

assert_contains "$playbooks_path" \
  "HTTP-referrer" \
  "playbook's classification table carries the referrer-restriction example"

echo ""
echo "The harness-level credential-creation boundary is distinguished from the access-control carve-out"
echo ""

assert_contains "$safety_path" \
  "harness-level" \
  "safety boundary names the credential-handling rule as harness-level, distinct from this spec's carve-out"

assert_contains "$playbooks_path" \
  "harness-level" \
  "playbook names the credential-handling rule as harness-level, distinct from this spec's carve-out"

echo ""
echo "Read-only verification remains unconditional regardless of direction"
echo ""

assert_contains "$safety_path" \
  "never a hand-back on its own" \
  "safety boundary states read-only verification is never a hand-back on its own"

echo ""
echo "What #970 deliberately preserved"
echo ""

# The untrusted-author defense must still apply in every column, not just
# the original two.
assert_contains "$safety_path" \
  "does not scope down for untrusted-derived actions" \
  "untrusted-derived actions still hand back regardless of category or direction"

assert_contains "$playbooks_path" \
  "stays a hand-back in *any* column" \
  "playbook states untrusted-derived actions hand back in any column"

echo ""
if [[ $fail -eq 0 ]]; then
  printf '%sAll %d checks passed.%s\n\n' "$GREEN" "$pass" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n\n' "$RED" "$pass" "$fail" "$RESET"
  exit 1
fi

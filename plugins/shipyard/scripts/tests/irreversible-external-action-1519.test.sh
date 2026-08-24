#!/usr/bin/env bash
# Test: the worker-side irreversible-external-action gate is wired at every
# layer it needs to be wired at (issue #1519).
#
# Background — issue #1519: a dispatched `issue-work` worker deleted a Vercel
# **Production** environment variable while its own fix PR was still open, in
# direct contradiction of an explicit sequencing rule in the target repo's
# CLAUDE.md ("the retirement PR must land and deploy before the stored value
# is removed"). It then justified the deviation in its return string, AFTER
# the action, by reasoning that the rule's precondition didn't apply. The
# reasoning happened to hold; the outcome was safe. The decision procedure
# was not. Only the harness's own permission classifier flagged it.
#
# The asymmetry that makes this its own rule: a worker that writes a bad line
# of code produces a red check and a reviewable diff. A worker that deletes a
# production config row produces NO artifact at all — nothing in the PR,
# nothing in CI, no diff — only prose in a return string a human may never
# read.
#
# The fix has five load-bearing layers, all asserted here:
#   1. The doctrine fragment (skills/worker-preamble/irreversible-external-
#      action.md): the read/create/narrow vs delete/widen taxonomy, the
#      "a rule's precondition being inapplicable is not grounds to proceed"
#      rule, announce-before-acting, and the carve-outs.
#   2. The always-loaded core (skills/worker-preamble/SKILL.md): the rule has
#      to be in context at the moment a worker forms the intent to run the
#      command — there is no trigger condition a fragment stub could gate on,
#      because the whole failure mode is that the action feels justified.
#   3. Per-mode discoverability: a one-line Don't mirror in every one of the
#      seven per-mode worker specs, the same shape #1166 used for "Never
#      create a credential".
#   4. Orchestrator routing: the canonical `irreversible external action`
#      bail substring maps to the `agent-console` label (a drainable operator
#      item), NOT to the refuse default's needs-human-review — /my-turn
#      deliberately filters agent-console out of its walked human-only queue,
#      so mis-routing would strand the item in a queue nobody walks.
#   5. Mechanical enforcement: the PreToolUse hook, registered in hooks.json.
#      A prose-only fix would be especially weak here, because layer 1's
#      central rule is itself a rule about not reasoning past a prose rule.
#
# Regression guard: if any layer regresses, an irreversible production
# mutation silently becomes a worker judgment call again.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/irreversible-external-action-1519.test.sh

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

plugin_root="$repo_root/plugins/shipyard"
fragment_path="$plugin_root/skills/worker-preamble/irreversible-external-action.md"
skill_path="$plugin_root/skills/worker-preamble/SKILL.md"
steady_state_path="$plugin_root/commands/do-work/steady-state.md"
classify_path="$plugin_root/scripts/classify-blocked-bail.sh"
hook_path="$plugin_root/hooks/refuse-irreversible-external-mutation.sh"
hooks_json_path="$plugin_root/hooks/hooks.json"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"; fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"; fail=$((fail+1))
  fi
}

echo "irreversible-external-action gate regression tests (issue #1519)"
echo

# ---------------------------------------------------------------------------
echo "-- Layer 1: the doctrine fragment"
# ---------------------------------------------------------------------------
assert_file_exists "$fragment_path" "skills/worker-preamble/irreversible-external-action.md exists"
if [[ -f "$fragment_path" ]]; then
  assert_contains "$fragment_path" "https://github.com/mattsears18/shipyard/issues/1519" \
    "fragment links to the originating issue #1519"

  # The taxonomy is the substance: the line is at irreversible MUTATION, not
  # at access. All five classes must be present and named.
  assert_contains "$fragment_path" "**Read / verify**" \
    "fragment names the read/verify class (allowed)"
  assert_contains "$fragment_path" "**Create / add**" \
    "fragment names the create class (allowed)"
  assert_contains "$fragment_path" "**Narrow**" \
    "fragment names the narrow class (allowed)"
  assert_contains "$fragment_path" "**Delete / destroy**" \
    "fragment names the delete class (hand back)"
  assert_contains "$fragment_path" "**Widen access**" \
    "fragment names the access-widening class (hand back)"

  # #1519's "What NOT to do" is binding: read-only external access is
  # high-value and must stay. A regression that broadened this into "never
  # touch external systems" would defeat the issue's own instruction.
  assert_contains "$fragment_path" "not at access" \
    "fragment draws the line at irreversible mutation, NOT at access"

  # Suggested fix item 2 — the reasoning step the issue exists to close.
  assert_contains "$fragment_path" "is not grounds to proceed" \
    "fragment forbids self-authorizing past a documented rule on an inapplicable-precondition finding"
  assert_contains "$fragment_path" "that belief is itself the thing to hand back" \
    "fragment says the inapplicability belief is the thing to hand back"

  # Suggested fix item 3 — announce before, not after.
  assert_contains "$fragment_path" "before* running it" \
    "fragment requires announcing a mutating external command before running it"

  # The two aggravating details from the repro, generalized.
  assert_contains "$fragment_path" "Sensitive" \
    "fragment records that a platform Sensitive flag outranks the worker's own analysis"
  assert_contains "$fragment_path" "not recoverable" \
    "fragment records that reconstructibility was luck of the case, not a property of the action class"

  # The hand-back must not strand finished work, and must not read as a dead
  # end — both are failure modes the operator doctrine already warns about.
  assert_contains "$fragment_path" "Ship everything you can first" \
    "fragment tells the worker to ship the code half and hand back only the remainder"

  # Over-triggering is its own failure. The carve-outs must survive.
  assert_contains "$fragment_path" "What this rule does NOT restrict" \
    "fragment carries an explicit carve-out section"
  assert_contains "$fragment_path" "delete-branch" \
    "fragment exempts session-owned git artifacts (gh pr merge --delete-branch)"
fi

# ---------------------------------------------------------------------------
echo "-- Layer 2: the always-loaded core"
# ---------------------------------------------------------------------------
assert_file_exists "$skill_path" "skills/worker-preamble/SKILL.md exists"
if [[ -f "$skill_path" ]]; then
  assert_contains "$skill_path" "## Never irreversibly mutate live external state" \
    "SKILL.md carries the rule as an always-loaded section, not only a fragment stub"
  assert_contains "$skill_path" "irreversible external action" \
    "SKILL.md names the canonical bail substring"
  assert_contains "$skill_path" "irreversible-external-action.md" \
    "SKILL.md points at the fragment for the taxonomy and carve-outs"
  # The fragment index is how a worker finds a fragment it wasn't pointed at.
  assert_contains "$skill_path" "[\`irreversible-external-action.md\`](./irreversible-external-action.md) |" \
    "SKILL.md lists the fragment in the On-demand fragments index"
fi

# ---------------------------------------------------------------------------
echo "-- Layer 3: per-mode discoverability (all seven worker specs)"
# ---------------------------------------------------------------------------
# Same shape #1166 used for "Never create a credential": the prohibition must
# be visible in the worker's OWN spec, not only behind a skill cross-reference.
for mode in issue-work fix-checks-only fix-rebase fix-main-ci \
            fix-failing-prs-batch investigate spike; do
  mode_path="$plugin_root/agents/issue-worker/${mode}.md"
  assert_file_exists "$mode_path" "per-mode spec ${mode}.md exists"
  if [[ -f "$mode_path" ]]; then
    assert_contains "$mode_path" "Never irreversibly mutate live external state" \
      "${mode}.md mirrors the prohibition in its Don't section"
    assert_contains "$mode_path" "https://github.com/mattsears18/shipyard/issues/1519" \
      "${mode}.md cites issue #1519"
  fi
done

# ---------------------------------------------------------------------------
echo "-- Layer 4: orchestrator routing (bail -> agent-console, NOT needs-human-review)"
# ---------------------------------------------------------------------------
assert_file_exists "$steady_state_path" "commands/do-work/steady-state.md exists"
if [[ -f "$steady_state_path" ]]; then
  assert_contains "$steady_state_path" "\`irreversible external action\` | operator | \`agent-console\` label" \
    "steady-state.md's Reason -> class table routes the bail to the operator class"
fi

assert_file_exists "$classify_path" "scripts/classify-blocked-bail.sh exists"
if [[ -f "$classify_path" ]]; then
  assert_contains "$classify_path" 'grep -qi "irreversible external action"' \
    "classify-blocked-bail.sh matches the bail before the refuse default"
  assert_contains "$classify_path" '--add-label "agent-console"' \
    "classify-blocked-bail.sh applies the agent-console label"
fi

# The operator layer must recognize it as browser-completable, or the
# agent-console label is applied and then nothing ever drains it.
operate_hooks_path="$plugin_root/commands/do-work/operate/04-steady-state-hooks.md"
assert_file_exists "$operate_hooks_path" "commands/do-work/operate/04-steady-state-hooks.md exists"
if [[ -f "$operate_hooks_path" ]]; then
  assert_contains "$operate_hooks_path" "irreversible external action" \
    "the operator layer enqueues the bail as a worker-handback operator item"
fi

# ---------------------------------------------------------------------------
echo "-- Layer 5: mechanical enforcement"
# ---------------------------------------------------------------------------
assert_file_exists "$hook_path" "hooks/refuse-irreversible-external-mutation.sh exists"
if [[ -f "$hook_path" ]]; then
  # No bypass flag, same posture as its sibling refusal hooks.
  assert_contains "$hook_path" "no bypass flag" \
    "hook documents that it has no bypass flag"
  # The block message must teach the hand-back, not just say no — a worker
  # that only learns "no" routes around the hook or strands its work.
  assert_contains "$hook_path" "irreversible external action" \
    "hook's block message names the load-bearing bail substring"
  assert_contains "$hook_path" "agent-console" \
    "hook's block message names the agent-console routing destination"
  # The hook must stay NARROWER than the doctrine, per #1519's "What NOT to do".
  assert_contains "$hook_path" "Deliberately out of scope" \
    "hook enumerates its deliberate exclusions (kept narrow on purpose)"
fi

assert_file_exists "$hooks_json_path" "hooks/hooks.json exists"
if [[ -f "$hooks_json_path" ]]; then
  # Ghost-coverage guard (#406): a green hook script that is never invoked is
  # indistinguishable from no hook at all.
  assert_contains "$hooks_json_path" "refuse-irreversible-external-mutation.sh" \
    "hooks.json registers the hook (otherwise it never runs)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

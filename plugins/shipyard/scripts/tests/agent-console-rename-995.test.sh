#!/usr/bin/env bash
# Test: the `needs-operator` → `agent-console` label rename (#995) landed
# consistently — the new name is what CLAUDE.md defines and what every
# label-creation site now creates, while the load-bearing MATCHING sites
# (the dispatch-exclusion set, the operator proactive sweep, and
# `/my-turn`'s human-only-queue filter) still recognize the legacy
# `needs-operator` name during the migration window, per the issue's
# documented sequence: ship dual-recognition first, THEN let consuming
# repos rename their live GitHub label object, THEN drop legacy
# recognition in a later release.
#
# Background — issue #995: `needs-operator` read as "needs a human
# operator," the opposite of what it means (the label marks work an AGENT
# can drive outside the build, not work that requires a human). This
# caused a real `/do-work` session to mislabel four genuinely agent-barred
# items, and because `/do-work` drives `needs-operator` while `/my-turn`
# filters it OUT of the human queue, a genuinely-blocked issue wearing the
# old name was reachable by neither loop. `agent-console` was chosen
# (over `agent-ops` / `agent-external`) because the `agent-` prefix makes
# ownership unmistakable.
#
# This is the regression guard: if a label-creation site starts
# (re-)creating the legacy `needs-operator` label, if a matching site
# drops legacy recognition before the migration window closes, or if
# CLAUDE.md's canonical definition / decision rule / migration note
# regresses, this test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/agent-console-rename-995.test.sh

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

claude_md="$repo_root/CLAUDE.md"
label_recovery_path="$repo_root/plugins/shipyard/commands/do-work/setup/01c-label-recovery-refine.md"
backlog_divert_path="$repo_root/plugins/shipyard/commands/do-work/setup/04-backlog-divert.md"
scope_handling_path="$repo_root/plugins/shipyard/commands/do-work/setup/06c-scope-handling-ui.md"
steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
operator_sweep_path="$repo_root/plugins/shipyard/commands/do-work/operate/04-steady-state-hooks.md"
my_turn_path="$repo_root/plugins/shipyard/commands/my-turn.md"

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
    printf '    expected NOT to find in %s:\n    %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

echo ""
echo "Test: needs-operator -> agent-console label rename (#995 regression guard)"
echo ""

assert_file_exists "$claude_md"            "CLAUDE.md exists"
assert_file_exists "$label_recovery_path"  "setup/01c-label-recovery-refine.md exists"
assert_file_exists "$backlog_divert_path"  "setup/04-backlog-divert.md exists"
assert_file_exists "$scope_handling_path"  "setup/06c-scope-handling-ui.md exists"
assert_file_exists "$steady_state_path"    "steady-state.md exists"
assert_file_exists "$operator_sweep_path"  "operate/04-steady-state-hooks.md exists"
assert_file_exists "$my_turn_path"         "my-turn.md exists"

echo ""
echo "CLAUDE.md defines agent-console as the canonical name, with the decision rule and rename provenance"
echo ""

# shellcheck disable=SC2016  # literal needle — must NOT expand as command substitution
assert_contains "$claude_md" \
  '<a id="agent-console"></a>`agent-console`' \
  "CLAUDE.md anchors the agent-console gate label definition"

assert_contains "$claude_md" \
  "renamed from \`needs-operator\` in #995" \
  "CLAUDE.md's agent-console entry cites the #995 rename"

assert_contains "$claude_md" \
  "Can an agent perform this action?" \
  "CLAUDE.md states the agent-vs-human decision rule"

assert_contains "$claude_md" \
  "Renamed: \`needs-operator\` → \`agent-console\` (#995)" \
  "CLAUDE.md carries a dedicated rename/migration subsection"

assert_contains "$claude_md" \
  "zero open or closed issues in \`mattsears18/shipyard\` carried \`needs-operator\`" \
  "CLAUDE.md documents this repo had no live data to migrate"

assert_contains "$claude_md" \
  "Only **after** upgrading, rename the repo's actual GitHub label object" \
  "CLAUDE.md documents the upgrade-then-rename migration order"

echo ""
echo "Label-creation sites create ONLY agent-console going forward — never (re-)create the legacy needs-operator label"
echo ""

assert_contains "$label_recovery_path" \
  "gh label create agent-console --repo" \
  "setup/01c-label-recovery-refine.md creates agent-console"

assert_not_contains "$label_recovery_path" \
  "gh label create needs-operator --repo" \
  "setup/01c-label-recovery-refine.md does NOT (re-)create the legacy needs-operator label"

assert_contains "$scope_handling_path" \
  "gh label create agent-console --repo" \
  "setup/06c-scope-handling-ui.md's GATE_LABEL branch creates agent-console"

assert_not_contains "$scope_handling_path" \
  "gh label create needs-operator --repo" \
  "setup/06c-scope-handling-ui.md does NOT (re-)create the legacy needs-operator label"

assert_contains "$scope_handling_path" \
  'GATE_LABEL="agent-console"' \
  "setup/06c-scope-handling-ui.md's external-dependency branch applies agent-console"

assert_contains "$steady_state_path" \
  "gh label create agent-console --repo" \
  "steady-state.md's provisioning-bail branch creates agent-console"

assert_not_contains "$steady_state_path" \
  "gh label create needs-operator --repo" \
  "steady-state.md does NOT (re-)create the legacy needs-operator label"

assert_contains "$steady_state_path" \
  '--add-label "agent-console"' \
  "steady-state.md applies the agent-console label to the provisioning bail"

echo ""
echo "Matching / filtering sites recognize BOTH agent-console and the legacy needs-operator name during the #995 migration window"
echo ""

assert_contains "$backlog_divert_path" \
  "or the legacy \`needs-operator\` name" \
  "setup/04-backlog-divert.md's dispatch-exclusion set recognizes the legacy needs-operator alias"

assert_contains "$operator_sweep_path" \
  "or the legacy \`needs-operator\` name" \
  "operate/04-steady-state-hooks.md's proactive sweep recognizes the legacy needs-operator alias"

assert_contains "$my_turn_path" \
  "renamed from \`needs-operator\` in" \
  "my-turn.md's human-only queue filter cites the #995 rename"

assert_contains "$my_turn_path" \
  "treat an issue still carrying the legacy \`needs-operator\` name identically" \
  "my-turn.md's filter recognizes the legacy needs-operator alias"

echo ""
if [[ $fail -eq 0 ]]; then
  printf '%sAll %d checks passed.%s\n\n' "$GREEN" "$pass" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n\n' "$RED" "$pass" "$fail" "$RESET"
  exit 1
fi

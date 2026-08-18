#!/usr/bin/env bash
# Test: the `needs-operator` → `agent-console` label rename (#995) landed
# consistently — the new name is what CLAUDE.md defines and what every
# label-creation site now creates. The load-bearing MATCHING sites (the
# dispatch-exclusion set, the operator proactive sweep, and `/my-turn`'s
# human-only-queue filter) recognized the legacy `needs-operator` name
# too, for a migration window, per the issue's documented sequence: ship
# dual-recognition first, THEN let consuming repos rename their live
# GitHub label object, THEN drop legacy recognition in a later release.
#
# That window is now CLOSED (#1082) — zero issues in this repo ever
# carried `needs-operator`, so there was no live data left to migrate.
# The matching sites no longer recognize the legacy name; this test
# guards that closure instead of the dual-recognition window it replaced.
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
# reintroduces legacy-name recognition now that the window is closed, or
# if CLAUDE.md's canonical definition / decision rule / migration note
# regresses, this test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/agent-console-rename-995.test.sh

# setup-fragment-content-scan: allow-file
# This suite regression-tests a SPECIFIC historical migration (#995) landing
# in the exact fragment files the migration touched — its purpose IS to
# verify those particular files, not generic step content that happens to
# live there today (issue #1453).
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
classify_blocked_bail_path="$repo_root/plugins/shipyard/scripts/classify-blocked-bail.sh"
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
assert_file_exists "$classify_blocked_bail_path" "classify-blocked-bail.sh exists"
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

# The provisioning-bail (operator) branch was extracted from steady-state.md
# to classify-blocked-bail.sh, issue #1289 — the agent-console label-create
# and --add-label calls now live in the script, not the .md prose.
assert_contains "$classify_blocked_bail_path" \
  'label create agent-console --repo' \
  "classify-blocked-bail.sh's provisioning-bail branch creates agent-console"

assert_not_contains "$classify_blocked_bail_path" \
  "label create needs-operator --repo" \
  "classify-blocked-bail.sh does NOT (re-)create the legacy needs-operator label"

assert_contains "$classify_blocked_bail_path" \
  '--add-label "agent-console"' \
  "classify-blocked-bail.sh applies the agent-console label to the provisioning bail"

echo ""
echo "Matching / filtering sites recognize ONLY agent-console now that the #995 migration window is closed (#1082)"
echo ""

assert_not_contains "$backlog_divert_path" \
  "or the legacy \`needs-operator\` name" \
  "setup/04-backlog-divert.md's dispatch-exclusion set no longer recognizes the legacy needs-operator alias"

assert_contains "$backlog_divert_path" \
  "legacy-name back-compat window is closed" \
  "setup/04-backlog-divert.md documents the closed migration window"

assert_not_contains "$operator_sweep_path" \
  "or the legacy \`needs-operator\` name" \
  "operate/04-steady-state-hooks.md's proactive sweep no longer recognizes the legacy needs-operator alias"

assert_contains "$operator_sweep_path" \
  "legacy-name back-compat window is closed" \
  "operate/04-steady-state-hooks.md documents the closed migration window"

assert_contains "$my_turn_path" \
  "renamed from \`needs-operator\` in" \
  "my-turn.md's human-only queue filter cites the #995 rename"

assert_not_contains "$my_turn_path" \
  "treat an issue still carrying the legacy \`needs-operator\` name identically" \
  "my-turn.md's filter no longer recognizes the legacy needs-operator alias"

assert_contains "$my_turn_path" \
  "legacy-name back-compat window is closed" \
  "my-turn.md documents the closed migration window"

echo ""
if [[ $fail -eq 0 ]]; then
  printf '%sAll %d checks passed.%s\n\n' "$GREEN" "$pass" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n\n' "$RED" "$pass" "$fail" "$RESET"
  exit 1
fi

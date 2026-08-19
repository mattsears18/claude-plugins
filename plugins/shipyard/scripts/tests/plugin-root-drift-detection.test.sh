#!/usr/bin/env bash
# Test: mid-session plugin-root drift is stashed at session start and
# detected at session end (issue #1304).
#
# Background
# ----------
# `/shipyard:do-work` resolves CLAUDE_PLUGIN_ROOT once, at setup step 0.5,
# and stashes it at `.shipyard-plugin-root` for the rest of the session —
# every later orchestrator bash block reads that stash instead of
# re-resolving. On a consumer install (the installed_plugins.json-resolved
# layer), the harness's own plugin manager can silently update the
# installed version mid-session: the orchestrator keeps invoking
# scripts/*.sh from whichever version it stashed at startup, while the
# `shipyard:worker-preamble` skill text a dispatched worker reads resolves
# LIVE against the current install — splitting "which spec ran" from
# "which scripts ran" for the rest of the session, with nothing surfacing
# it. A real session (do-work-20260812T023612Z-34142 against
# mattsears18/lightwork) observed exactly this: the plugin updated twice
# (4.29.2 -> 4.30.8 -> 4.31.1) over a 9-hour run with no warning anywhere.
#
# The fix (the smaller, explicitly-acceptable slice from issue #1304, not
# the full re-resolve-at-every-checkpoint option): step 0.5 additionally
# stashes the resolved plugin's own VERSION to
# `.shipyard-plugin-root-version`; end-of-session cleanup (step 8.6) then
# re-resolves the CURRENT installed_plugins.json path fresh, diffs its
# version against the stashed one, and — only when they disagree — prints
# a `Plugin root moved: <start> -> <end>` line in the end-of-session
# summary. This is advisory-only: it does NOT re-point CLAUDE_PLUGIN_ROOT
# mid-session (that risks a live spec/script mismatch worse than the
# stale-but-INTERNALLY-CONSISTENT one the session already ran on) and does
# not retry anything — it just makes the drift visible instead of silent.
#
# This test has two halves:
#   1. Static assertions that the two spec files actually wire the feature
#      together (the stash write, the re-resolution + diff, the summary
#      line, its per-line omission rule).
#   2. A FUNCTIONAL re-implementation of the exact re-resolution + diff
#      logic documented in cleanup-summary.md's step 8.6, exercised against
#      three fixture scenarios (drift / no-drift / repo-local-skip) so the
#      documented shell logic is verified to actually behave correctly, not
#      merely present.

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

cleanup_file="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
# The three static assertions below scan across every setup/*.md fragment
# rather than hardcoding one file, since a future split could move step
# 0.5's content elsewhere without warning (issue #1453; mirrors the fix in
# shipyard-repo-root-preamble.test.sh check (4)).
setup_dir="$repo_root/plugins/shipyard/commands/do-work/setup"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

check() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "0" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$desc"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$desc"
    fail=$((fail + 1))
  fi
}

# Compares two strings directly (no `[[ ]]; ... "$?"` — shellcheck SC2319
# flags $? read after a `[[ ]]` test as likely-confusing) and reports
# through `check` above.
assert_streq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    check "$desc" 0
  else
    check "$desc" 1
  fi
}

echo "plugin-root mid-session drift detection regression tests (issue #1304)"
echo

# --- Static assertions -------------------------------------------------

grep -ql '\.shipyard-plugin-root-version' "$setup_dir"/*.md 2>/dev/null
check "setup/*.md step 0.5 writes .shipyard-plugin-root-version" "$?"

# Assert the MECHANISM, not a shell variable name (issue #1471). This check
# previously grepped for the literal `SHIPYARD_PLUGIN_ROOT_VERSION`, the name
# step 0.5 used to assign the resolved version to before writing the stash.
# #1471 measured that block refused verbatim by the worktree-isolation guard
# and re-rendered it to substitute the plugin-root literal, which removed the
# intermediate variable entirely — the version is now read straight out of
# plugin.json and written to the stash with the `Write` tool. The drift
# signal this suite guards is unchanged; only the spelling was. Keying the
# assertion to the plugin.json read keeps it pinned to what actually has to
# hold, and survives the next re-rendering of the same block.
grep -ql '\.claude-plugin/plugin\.json' "$setup_dir"/*.md 2>/dev/null
check "setup/*.md resolves the plugin version from .claude-plugin/plugin.json" "$?"

grep -ql '#1304' "$setup_dir"/*.md 2>/dev/null
check "setup/*.md cites issue #1304" "$?"

grep -q 'SHIPYARD_PLUGIN_ROOT_DRIFT' "$cleanup_file"
check "cleanup-summary.md computes SHIPYARD_PLUGIN_ROOT_DRIFT" "$?"

grep -q '\.shipyard-plugin-root-version' "$cleanup_file"
check "cleanup-summary.md reads back the .shipyard-plugin-root-version stash" "$?"

grep -q 'installed_plugins\.json' "$cleanup_file"
check "cleanup-summary.md re-resolves against installed_plugins.json at session end" "$?"

grep -q 'Plugin root moved:' "$cleanup_file"
check "cleanup-summary.md's summary shape includes a 'Plugin root moved:' line" "$?"

grep -q 'omit entirely unless the session-local .SHIPYARD_PLUGIN_ROOT_DRIFT. was set' "$cleanup_file"
check "cleanup-summary.md documents the omit-unless-set rule for the new line" "$?"

grep -q '#1304' "$cleanup_file"
check "cleanup-summary.md cites issue #1304" "$?"

# --- Functional re-implementation ---------------------------------------
#
# Mirrors cleanup-summary.md step 8.6's documented shell logic exactly:
# given a start path/version and a fresh installed_plugins.json + its
# plugin.json, compute SHIPYARD_PLUGIN_ROOT_DRIFT the same way the spec
# does.

compute_drift() {
  local start_path="$1" start_version="$2" toplevel="$3" home_dir="$4"
  local drift=""
  if [[ "$start_path" != "$toplevel/plugins/shipyard" ]]; then
    local installed_now
    installed_now=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$home_dir/.claude/plugins/installed_plugins.json" 2>/dev/null)
    if [[ -n "$installed_now" && -d "$installed_now/scripts" && "$installed_now" != "$start_path" ]]; then
      local version_now
      version_now=$(jq -r '.version // empty' "$installed_now/.claude-plugin/plugin.json" 2>/dev/null)
      [[ -z "$version_now" ]] && version_now="unknown"
      drift="$start_version -> $version_now"
    fi
  fi
  printf '%s' "$drift"
}

tmp_home="$(mktemp -d)"
tmp_installed="$(mktemp -d)"
trap 'rm -rf "$tmp_home" "$tmp_installed"' EXIT

mkdir -p "$tmp_home/.claude/plugins" "$tmp_installed/scripts" "$tmp_installed/.claude-plugin"
printf '{"plugins":{"shipyard@shipyard":[{"installPath":"%s"}]}}\n' "$tmp_installed" \
  > "$tmp_home/.claude/plugins/installed_plugins.json"
printf '{"version":"4.31.9"}\n' > "$tmp_installed/.claude-plugin/plugin.json"

# Scenario 1: plugin updated mid-session (start != current installed path).
result=$(compute_drift "/old/install/path" "4.29.2" "/not-a-repo" "$tmp_home")
assert_streq "drift detected when installed_plugins.json now points elsewhere (got: ${result:-<empty>})" \
  "4.29.2 -> 4.31.9" "$result"

# Scenario 2: no drift — start path IS the current installed path.
result=$(compute_drift "$tmp_installed" "4.31.9" "/not-a-repo" "$tmp_home")
assert_streq "no drift when start path matches the current installed path" "" "$result"

# Scenario 3: repo-local (dogfooding) layer never checked, regardless of
# installed_plugins.json content — it isn't the harness-managed install.
result=$(compute_drift "/some/repo/plugins/shipyard" "4.29.2" "/some/repo" "$tmp_home")
assert_streq "repo-local layer is skipped entirely (dogfooding case can't drift mid-session)" "" "$result"

# Scenario 4: installed_plugins.json entry present but its scripts/ dir is
# missing (malformed/partial entry) — degrade to no-drift rather than a
# false positive.
tmp_installed_broken="$(mktemp -d)"
tmp_home_broken="$(mktemp -d)"
mkdir -p "$tmp_home_broken/.claude/plugins"
printf '{"plugins":{"shipyard@shipyard"[{"installPath":"%s"}]}}\n' "$tmp_installed_broken" \
  > "$tmp_home_broken/.claude/plugins/installed_plugins.json" 2>/dev/null || true
# (deliberately malformed JSON above is fine — jq -r with `// empty` and
# 2>/dev/null just returns empty, matching the fallback-to-no-drift path)
result=$(compute_drift "/old/install/path" "4.29.2" "/not-a-repo" "$tmp_home_broken")
assert_streq "malformed/unreadable installed_plugins.json degrades to no-drift, not a crash" "" "$result"
rm -rf "$tmp_installed_broken" "$tmp_home_broken"

echo
if [[ "$fail" -gt 0 ]]; then
  printf '%sFAIL%s  %d passed, %d failed\n' "$RED" "$RESET" "$pass" "$fail" >&2
  exit 1
else
  printf '%sPASS%s  %d passed, %d failed\n' "$GREEN" "$RESET" "$pass" "$fail"
  exit 0
fi

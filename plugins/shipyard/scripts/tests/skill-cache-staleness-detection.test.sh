#!/usr/bin/env bash
# Test: dispatched workers get no staleness warning and no structural
# guarantee of a fresh spec read (issue #1319).
#
# Background
# ----------
# `/shipyard:do-work` step 0.4 already warns the ORCHESTRATOR when the
# dogfooding-case `CLAUDE_PLUGIN_ROOT` (this repo's own primary checkout)
# is measurably behind `origin/<default-branch>` (issue #907). But a
# dispatched WORKER's `Skill` tool loads `shipyard:worker-preamble` (and
# every fragment) by NAME — resolved by the harness against
# `installed_plugins.json`'s cache path, entirely independent of
# `CLAUDE_PLUGIN_ROOT`. A real session (do-work-20260813T000122Z-77192
# against mattsears18/shipyard) observed the installed cache pinned to
# 4.32.5 while origin/main was already at 4.32.7 — two releases of drift,
# with nothing anywhere surfacing it.
#
# The fix (suggestions 1 and 3 from issue #1319 — the mechanical,
# self-contained slice; suggestion 2's deeper structural fix is tracked
# separately): step 0.4 now ALSO resolves the installed skill cache's own
# version, compares it against origin/<default-branch>'s, and — when they
# differ — sets SHIPYARD_SKILL_CACHE_STALE, echoes the resolved version
# unconditionally (mirrors the #681 "echo once" discipline), and warns
# loudly. cleanup-summary.md re-surfaces it in the end-of-session summary
# (mirrors the existing "Plugin root:" line's #907 pattern). dispatch-rules.md
# additionally threads BOTH staleness signals (primary-checkout AND
# skill-cache) into the per-dispatch Context paragraph every Agent-tool
# worker reads, so the warning reaches the worker itself, not just the
# orchestrator's own log.
#
# This test has two halves:
#   1. Static assertions that the three spec files actually wire the
#      feature together.
#   2. A FUNCTIONAL re-implementation of the exact resolution + comparison
#      logic documented in 00-config-worktree.md's step 0.4, exercised
#      against fixture scenarios so the documented shell logic is verified
#      to actually behave correctly, not merely present.

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

setup_file="$repo_root/plugins/shipyard/commands/do-work/setup/00-config-worktree.md"
cleanup_file="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
dispatch_file="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
detector_script="$repo_root/plugins/shipyard/scripts/detect-skill-cache-staleness.sh"

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

echo "worker skill-cache staleness detection regression tests (issue #1319)"
echo

# --- Static assertions -------------------------------------------------

detector_executable=1
[ -x "$detector_script" ] && detector_executable=0
check "detect-skill-cache-staleness.sh exists and is executable" "$detector_executable"

grep -q 'installed_plugins.json' "$detector_script"
check "detect-skill-cache-staleness.sh resolves installed_plugins.json's shipyard@shipyard installPath" "$?"

grep -q 'resolved skill-cache version=' "$detector_script"
check "detect-skill-cache-staleness.sh echoes the resolved skill-cache version unconditionally (mirrors #681)" "$?"

grep -q '#1319' "$detector_script"
check "detect-skill-cache-staleness.sh cites issue #1319" "$?"

grep -q 'SHIPYARD_SKILL_CACHE_STALE' "$setup_file"
check "00-config-worktree.md computes SHIPYARD_SKILL_CACHE_STALE from the detector script's output" "$?"

grep -q 'detect-skill-cache-staleness.sh' "$setup_file"
check "00-config-worktree.md step 0.4 calls detect-skill-cache-staleness.sh" "$?"

grep -q '#1319' "$setup_file"
check "00-config-worktree.md cites issue #1319" "$?"

grep -q 'SHIPYARD_SKILL_CACHE_STALE' "$cleanup_file"
check "cleanup-summary.md re-surfaces SHIPYARD_SKILL_CACHE_STALE" "$?"

grep -q 'Skill cache:' "$cleanup_file"
check "cleanup-summary.md's summary shape includes a 'Skill cache:' line" "$?"

grep -q 'omit entirely unless the session-local .SHIPYARD_SKILL_CACHE_STALE. was set' "$cleanup_file"
check "cleanup-summary.md documents the omit-unless-set rule for the new line" "$?"

grep -q '#1319' "$cleanup_file"
check "cleanup-summary.md cites issue #1319" "$?"

grep -q 'SHIPYARD_SKILL_CACHE_STALE' "$dispatch_file"
check "dispatch-rules.md threads SHIPYARD_SKILL_CACHE_STALE into the worker dispatch prompt" "$?"

grep -q 'SHIPYARD_PLUGIN_ROOT_STALE' "$dispatch_file"
check "dispatch-rules.md threads SHIPYARD_PLUGIN_ROOT_STALE into the worker dispatch prompt" "$?"

grep -q 'Skill-cache warning (#1319)' "$dispatch_file"
check "dispatch-rules.md's Context-paragraph addendum names the skill-cache warning" "$?"

grep -q 'Staleness warning (#1319)' "$dispatch_file"
check "dispatch-rules.md's Context-paragraph addendum names the primary-checkout warning" "$?"

grep -q '#1319' "$dispatch_file"
check "dispatch-rules.md cites issue #1319" "$?"

# --- Functional: exercise the REAL script end-to-end -------------------
#
# A git fixture stands in for origin/<default-branch> (a source repo cloned
# once so the clone gets a real `origin` remote to `git show` against); a
# fake $HOME stands in for the installed skill cache. The real script is
# invoked via HOME= override — not a shell re-implementation — so this
# proves the actual shipped logic, not a parallel copy of it.

tmp_home="$(mktemp -d)"
tmp_installed="$(mktemp -d)"
tmp_origin_src="$(mktemp -d)"
tmp_worktree="$(mktemp -d)"
trap 'rm -rf "$tmp_home" "$tmp_installed" "$tmp_origin_src" "$tmp_worktree"' EXIT

mkdir -p "$tmp_home/.claude/plugins" "$tmp_installed/scripts" "$tmp_installed/.claude-plugin"
printf '{"plugins":{"shipyard@shipyard":[{"installPath":"%s"}]}}\n' "$tmp_installed" \
  > "$tmp_home/.claude/plugins/installed_plugins.json"
printf '{"version":"4.32.5"}\n' > "$tmp_installed/.claude-plugin/plugin.json"

mkdir -p "$tmp_origin_src/plugins/shipyard/.claude-plugin"
printf '{"version":"4.32.7"}\n' > "$tmp_origin_src/plugins/shipyard/.claude-plugin/plugin.json"
git -C "$tmp_origin_src" init -q
git -C "$tmp_origin_src" checkout -q -b main
git -C "$tmp_origin_src" -c user.email=t@t -c user.name=t add -A
git -C "$tmp_origin_src" -c user.email=t@t -c user.name=t commit -q -m init
git clone -q "$tmp_origin_src" "$tmp_worktree"

# Scenario 1: the actual repro — installed cache (4.32.5) behind origin/main
# (4.32.7).
result=$(cd "$tmp_worktree" && HOME="$tmp_home" bash "$detector_script" main 2>/dev/null)
assert_streq "real script reports stale when installed cache trails origin/main (got: ${result:-<empty>})" \
  "stale:4.32.5 (installed cache) vs 4.32.7 (origin/main)" "$result"

# Scenario 2: no drift — installed cache already matches origin's version.
printf '{"version":"4.32.7"}\n' > "$tmp_installed/.claude-plugin/plugin.json"
result=$(cd "$tmp_worktree" && HOME="$tmp_home" bash "$detector_script" main 2>/dev/null)
assert_streq "real script reports fresh when installed cache matches origin/main" "fresh" "$result"

# Scenario 3: installed_plugins.json has no shipyard@shipyard entry at all
# (malformed/partial install) — degrades to fresh, not a crash.
tmp_home_missing="$(mktemp -d)"
mkdir -p "$tmp_home_missing/.claude/plugins"
printf '{"plugins":{}}\n' > "$tmp_home_missing/.claude/plugins/installed_plugins.json"
result=$(cd "$tmp_worktree" && HOME="$tmp_home_missing" bash "$detector_script" main 2>/dev/null)
assert_streq "missing installed_plugins.json entry degrades to fresh, not a crash" "fresh" "$result"
rm -rf "$tmp_home_missing"

# Scenario 4: installPath resolves but its plugin.json is missing (partial
# install) — degrades to fresh rather than fabricating a version.
tmp_home_nopluginjson="$(mktemp -d)"
tmp_installed_nopluginjson="$(mktemp -d)"
mkdir -p "$tmp_home_nopluginjson/.claude/plugins" "$tmp_installed_nopluginjson/scripts"
printf '{"plugins":{"shipyard@shipyard":[{"installPath":"%s"}]}}\n' "$tmp_installed_nopluginjson" \
  > "$tmp_home_nopluginjson/.claude/plugins/installed_plugins.json"
result=$(cd "$tmp_worktree" && HOME="$tmp_home_nopluginjson" bash "$detector_script" main 2>/dev/null)
assert_streq "installPath with no .claude-plugin/plugin.json degrades to fresh, not a crash" "fresh" "$result"
rm -rf "$tmp_home_nopluginjson" "$tmp_installed_nopluginjson"

# Scenario 5: no default-branch argument given (e.g. gh repo view failed
# upstream) — degrades to fresh rather than a false positive off a
# one-sided empty comparison.
printf '{"version":"4.32.5"}\n' > "$tmp_installed/.claude-plugin/plugin.json"
result=$(cd "$tmp_worktree" && HOME="$tmp_home" bash "$detector_script" "" 2>/dev/null)
assert_streq "empty default-branch argument never produces a false-positive stale verdict" "fresh" "$result"

# Scenario 6: the resolved skill-cache version is echoed to stderr
# unconditionally, even on the fresh (matching-versions) path (#681 "echo
# once" discipline — answerable from the transcript even on a clean run).
printf '{"version":"4.32.7"}\n' > "$tmp_installed/.claude-plugin/plugin.json"
stderr_out=$(cd "$tmp_worktree" && HOME="$tmp_home" bash "$detector_script" main 2>&1 >/dev/null)
case "$stderr_out" in
  *"resolved skill-cache version=4.32.7"*) check "stderr echoes resolved skill-cache version unconditionally" 0 ;;
  *) check "stderr echoes resolved skill-cache version unconditionally (got: $stderr_out)" 1 ;;
esac

echo
if [[ "$fail" -gt 0 ]]; then
  printf '%sFAIL%s  %d passed, %d failed\n' "$RED" "$RESET" "$pass" "$fail" >&2
  exit 1
else
  printf '%sPASS%s  %d passed, %d failed\n' "$GREEN" "$RESET" "$pass" "$fail"
  exit 0
fi

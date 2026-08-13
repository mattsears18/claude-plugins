#!/usr/bin/env bash
# Test: the orchestrator-context inline-`git -C` gate (issue #1323).
#
# Background — #1316 established that a worktree-isolated orchestrator's
# harness guard unconditionally refuses `git -C <other-path>` issued
# directly from its own Bash tool call, read-only or not. #1317 converted
# A.0.5's two inspection sites to a helper-script call; #1323 converted
# A.0.6's primary-checkout branch-leak guard the same way.
# scripts/orchestrator-git-dash-c-scan.sh is the cheap structural guard
# that keeps a future edit from reintroducing this refused shape into a
# post-relocation fenced ```bash block, mirroring compound-block-scan.sh /
# claude-plugin-root-preamble.test.sh.
#
# Pure bash + awk. Run with:
#   bash plugins/shipyard/scripts/tests/orchestrator-git-dash-c-scan.test.sh

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

scanner="$repo_root/plugins/shipyard/scripts/orchestrator-git-dash-c-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

echo "orchestrator-git-dash-c-scan gate regression tests (issue #1323)"
echo

# (1) The scanner exists.
assert_file_exists "$scanner" "scripts/orchestrator-git-dash-c-scan.sh exists"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# (2) A block with plain sequential statements and NO `git -C` passes
# clean, even with a `git` invocation that doesn't use `-C`.
clean_md="$work/clean.md"
cat > "$clean_md" <<'FIXTURE'
```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
git fetch origin
git worktree list --porcelain
```
FIXTURE
if bash "$scanner" "$clean_md" >/dev/null 2>&1; then
  ok "scanner exits 0 on a block with a plain 'git' call (no -C)"
else
  bad "scanner FALSE-POSITIVED on a block with a plain 'git' call (no -C)"
fi

# (3) An inline `git -C <other-path>` invocation is flagged, and the
# finding names the offending file:line.
inline_md="$work/inline.md"
cat > "$inline_md" <<'FIXTURE'
```bash
PRIMARY_BRANCH=$(git -C "$PRIMARY_CHECKOUT" symbolic-ref --short -q HEAD)
```
FIXTURE
if bash "$scanner" "$inline_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect an inline 'git -C' call (exited 0)"
else
  out="$(bash "$scanner" "$inline_md" 2>&1)"
  if [[ "$out" == *"$inline_md:2:"* ]]; then
    ok "scanner detects an inline 'git -C' call and names the line"
  else
    bad "scanner exited non-zero but did not cite the offending line ($out)"
  fi
fi

# (4) A `git -C` mention INSIDE a `#` comment (prose, not a real
# invocation) is NOT flagged.
comment_md="$work/comment.md"
cat > "$comment_md" <<'FIXTURE'
```bash
# Never issue git -C "$OTHER_WORKTREE" directly here — use the helper script.
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
```
FIXTURE
if bash "$scanner" "$comment_md" >/dev/null 2>&1; then
  ok "scanner does NOT flag 'git -C' mentioned inside a # comment"
else
  bad "scanner FALSE-POSITIVED on 'git -C' mentioned inside a # comment"
fi

# (5) An explicit `<!-- orchestrator-git-dash-c-scan: allow -->` directive
# immediately before a fence exempts that one block.
allow_md="$work/allow.md"
cat > "$allow_md" <<'FIXTURE'
<!-- orchestrator-git-dash-c-scan: allow -->
```bash
ORCH_WT_ABS="$(git -C "<repo-root>/.claude/worktrees/orchestrator-<session-id>" rev-parse --show-toplevel)"
```
FIXTURE
if bash "$scanner" "$allow_md" >/dev/null 2>&1; then
  ok "an allow directive exempts the following block"
else
  bad "an allow directive should have exempted the following block"
fi

# (6) A single-backtick, non-fenced mention of `git -C` in ordinary prose
# (outside any ```bash block) is NOT flagged — the scanner only looks
# inside fenced blocks, matching compound-block-scan.sh's own scope.
prose_md="$work/prose.md"
cat > "$prose_md" <<'FIXTURE'
Run this via the `inspect-unpushed` subcommand, not an inline `git -C
<other-worktree>` — the guard refuses it.
FIXTURE
if bash "$scanner" "$prose_md" >/dev/null 2>&1; then
  ok "scanner does NOT flag a 'git -C' mention in prose outside a fenced block"
else
  bad "scanner FALSE-POSITIVED on a 'git -C' mention in prose outside a fenced block"
fi

# (7) A nonexistent path errors with usage exit code 2, not a silent pass.
if bash "$scanner" "$work/does-not-exist.md" >/dev/null 2>&1; then
  bad "scanner should error (not silently pass) on a nonexistent file"
else
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    ok "scanner exits 2 on a nonexistent file argument"
  else
    bad "scanner exited $rc (expected 2) on a nonexistent file argument"
  fi
fi

# (8) Regression: the real corpus's four curated files (steady-state.md,
# drain.md, dispatch-rules.md, cleanup-summary.md) stay clean. A future
# edit that reintroduces an inline `git -C` in any of them — without either
# routing it through a helper script or adding a reviewed allow marker —
# fails this assertion.
for f in steady-state.md drain.md dispatch-rules.md cleanup-summary.md; do
  target="$repo_root/plugins/shipyard/commands/do-work/$f"
  if [[ -f "$target" ]]; then
    if bash "$scanner" "$target" >/dev/null 2>&1; then
      ok "scanner reports $f as clean of inline 'git -C' (#1323)"
    else
      bad "scanner found an inline 'git -C' in $f — see script output for the offending line"
    fi
  fi
done

# (9) Regression: the built-in FILES list (no args) also reports clean,
# exercising the default (no-args) invocation path end-to-end.
if bash "$scanner" >/dev/null 2>&1; then
  ok "scanner's built-in FILES list (default invocation, no args) reports clean"
else
  bad "scanner's built-in FILES list (default invocation, no args) found an inline 'git -C'"
fi

# (10) Regression: cleanup-summary.md's one deliberately-reviewed exception
# (the orchestrator's own end-of-session worktree reap, which targets its
# OWN current worktree rather than redirecting to another) carries the
# allow marker, and A.0.6's primary-leak guard site in steady-state.md does
# NOT carry one (it's clean on its own merits, routed through
# primary-leak-guard.sh) — guards against the marker becoming a silent
# escape hatch for a future regression instead of a reviewed exception.
cleanup_real="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
steady_state_real="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
if [[ -f "$cleanup_real" ]]; then
  if grep -qF -- '<!-- orchestrator-git-dash-c-scan: allow -->' "$cleanup_real"; then
    ok "cleanup-summary.md carries its one reviewed allow marker (self-targeting -C)"
  else
    bad "cleanup-summary.md is missing its expected allow marker — either the exception was fixed (update this test) or the marker was accidentally dropped"
  fi
fi
if [[ -f "$steady_state_real" ]]; then
  if grep -qF -- '<!-- orchestrator-git-dash-c-scan: allow -->' "$steady_state_real"; then
    bad "steady-state.md carries an orchestrator-git-dash-c-scan allow marker — A.0.6 should be clean on its own merits via primary-leak-guard.sh, not an exemption"
  else
    ok "steady-state.md carries no orchestrator-git-dash-c-scan allow marker — A.0.6 is clean on its own merits"
  fi
fi

# (11) Regression: scripts/primary-leak-guard.sh and
# scripts/crash-recovery-reap.sh both exist — the two script call sites
# steady-state.md now routes its `git -C` through instead of inlining it.
primary_leak_guard_real="$repo_root/plugins/shipyard/scripts/primary-leak-guard.sh"
crash_recovery_reap_real="$repo_root/plugins/shipyard/scripts/crash-recovery-reap.sh"
assert_file_exists "$primary_leak_guard_real" "scripts/primary-leak-guard.sh exists — the #1323 extraction target for A.0.6's primary-leak guard"
assert_file_exists "$crash_recovery_reap_real" "scripts/crash-recovery-reap.sh exists — the pre-existing (#1291) extraction target A.0.5's recovery path already routes through"

echo
echo "orchestrator-git-dash-c-scan.sh test suite: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0

#!/usr/bin/env bash
# Test: the post-relocation compound-block gate (issue #1277).
#
# Background — issue #1277: #1181 decomposed ONE post-relocation compound
# shape (the `CLAUDE_PLUGIN_ROOT` preamble) after the worktree-isolation
# guard refused it ("this command is too complex to verify that it stays
# inside the worktree"). Every OTHER post-relocation multi-statement block
# in the orchestrator spec was still templated the same refused way —
# scripts/compound-block-scan.sh is the cheap structural guard this issue's
# fix introduced: a scanner that flags a fenced ```bash block containing an
# unquoted shell pipe (spanning a tool boundary) or a for/while loop wrapping
# gh/git calls, mirroring the fence-balance-scan.sh / conflict-marker-scan.sh
# family.
#
# Pure bash + awk. Run with:
#   bash plugins/shipyard/scripts/tests/compound-block-scan.test.sh

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

scanner="$repo_root/plugins/shipyard/scripts/compound-block-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

echo "compound-block-scan gate regression tests (issue #1277)"
echo

# (1) The scanner exists.
assert_file_exists "$scanner" "scripts/compound-block-scan.sh exists"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# (2) A block with only plain sequential statements — no loop, no pipe —
# passes clean, even with several lines and command substitutions.
clean_md="$work/clean.md"
cat > "$clean_md" <<'FIXTURE'
# Heading

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
ME_LOGIN=$(gh api user --jq '.login')
INVESTIGATE_DISPATCH=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get triage.investigate_dispatch 2>/dev/null || echo "true")
```
FIXTURE
if bash "$scanner" "$clean_md" >/dev/null 2>&1; then
  ok "scanner exits 0 on a block of plain sequential statements"
else
  bad "scanner FALSE-POSITIVED on a block of plain sequential statements"
fi

# (3) A for-loop wrapping a gh call is flagged.
loop_md="$work/loop.md"
cat > "$loop_md" <<'FIXTURE'
```bash
for pr in $session_prs; do
  gh pr view "$pr" --repo <owner/repo>
done
```
FIXTURE
if bash "$scanner" "$loop_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect a for-loop wrapping a gh call (exited 0)"
else
  out="$(bash "$scanner" "$loop_md" 2>&1)"
  if [[ "$out" == *"for/while-loop-wraps-gh-or-git"* ]]; then
    ok "scanner detects a for-loop wrapping a gh call"
  else
    bad "scanner exited non-zero but did not name the for/while-loop shape"
  fi
fi

# (4) A while-loop wrapping a git call is flagged.
while_md="$work/while.md"
cat > "$while_md" <<'FIXTURE'
```bash
while [ -n "$x" ]; do
  git branch -D "$x"
done
```
FIXTURE
if bash "$scanner" "$while_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect a while-loop wrapping a git call (exited 0)"
else
  ok "scanner detects a while-loop wrapping a git call"
fi

# (5) A pipe spanning a shell command boundary (echo | jq) is flagged.
pipe_md="$work/pipe.md"
cat > "$pipe_md" <<'FIXTURE'
```bash
failing_pr_count_all=$(echo "$failing_pr_numbers" | jq 'length')
```
FIXTURE
if bash "$scanner" "$pipe_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect an echo | jq pipe (exited 0)"
else
  out="$(bash "$scanner" "$pipe_md" 2>&1)"
  if [[ "$out" == *"unquoted-pipe"* ]]; then
    ok "scanner detects an echo | jq pipe"
  else
    bad "scanner exited non-zero but did not name the unquoted-pipe shape"
  fi
fi

# (6) A pipe INSIDE a quoted --jq filter (jq's own `|` operator) is NOT
# flagged — this is the false-positive case the quote-stripping exists to
# avoid, and it is the single most common shape in the real corpus.
jqfilter_md="$work/jqfilter.md"
cat > "$jqfilter_md" <<'FIXTURE'
```bash
gh pr list --repo <owner/repo> --json number,statusCheckRollup \
  --jq '[.[] | select(
    [.statusCheckRollup
     | group_by(.name)
     | map(sort_by(.completedAt // .startedAt // "") | last)
     | .[]
     | select((.conclusion // .state // .status // "") | test("FAILURE"))]
    | length > 0) | .number]'
```
FIXTURE
if bash "$scanner" "$jqfilter_md" >/dev/null 2>&1; then
  ok "scanner does NOT flag a pipe inside a quoted --jq filter"
else
  bad "scanner FALSE-POSITIVED on a pipe inside a quoted --jq filter"
fi

# (7) A case statement's pattern-alternation `|` (word|word) form) is NOT
# flagged, including the single-line `case ... in pattern) action ;; esac`
# idiom this corpus uses for merge-method / retry-count validation.
case_md="$work/case.md"
cat > "$case_md" <<'FIXTURE'
```bash
case "$AUTO_MERGE_METHOD" in squash|merge|rebase) ;; *) AUTO_MERGE_METHOD=squash ;; esac
case "$PRUNE_WINDOW_DAYS" in ''|*[!0-9]*) PRUNE_WINDOW_DAYS=90 ;; esac
```
FIXTURE
if bash "$scanner" "$case_md" >/dev/null 2>&1; then
  ok "scanner does NOT flag a case statement's pattern-alternation pipe"
else
  bad "scanner FALSE-POSITIVED on a case statement's pattern-alternation pipe"
fi

# (8) An apostrophe inside a `#` comment (a contraction like "it's") does
# NOT desync the quote-stripper and swallow real code on a later line —
# the false positive this scanner's own #1277 development hit and fixed.
comment_md="$work/comment.md"
cat > "$comment_md" <<'FIXTURE'
```bash
# The fix's merge commit — main's current HEAD, now that it's green.
fix_commit_sha=$(gh api "repos/<owner/repo>/commits/<default-branch>" --jq '.sha')
CLASSIFIED=$("${CLAUDE_PLUGIN_ROOT}/scripts/backlog-filter.sh" classify --me "$ME_LOGIN" < input.json > output.json)
```
FIXTURE
if bash "$scanner" "$comment_md" >/dev/null 2>&1; then
  ok "scanner does NOT desync on apostrophes inside a # comment"
else
  bad "scanner FALSE-POSITIVED after apostrophes inside a # comment (quote-stripper desync)"
fi

# (9) An explicit `<!-- compound-block-scan: allow -->` directive immediately
# before a fence exempts that one block, even though it contains a real
# for-loop-wraps-gh shape — for the rare case a block intentionally shows
# the refused shape as a documented bad example.
allow_md="$work/allow.md"
cat > "$allow_md" <<'FIXTURE'
<!-- compound-block-scan: allow -->
```bash
for pr in $session_prs; do
  gh pr view "$pr" --repo <owner/repo>
done
```
FIXTURE
if bash "$scanner" "$allow_md" >/dev/null 2>&1; then
  ok "an allow directive exempts the following block"
else
  bad "an allow directive should have exempted the following block"
fi

# (10) A directory argument is walked... actually the scanner takes explicit
# file paths only (no directory-walk) — confirm a nonexistent path errors
# with usage exit code 2, not a silent pass.
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

# (11) Regression: the real repo's setup/04-backlog-divert.md — the file
# this issue's own fix swept clean — stays clean. A future edit that
# reintroduces a compound shape there fails this assertion.
real_target="$repo_root/plugins/shipyard/commands/do-work/setup/04-backlog-divert.md"
if [[ -f "$real_target" ]]; then
  if bash "$scanner" "$real_target" >/dev/null 2>&1; then
    ok "scanner reports setup/04-backlog-divert.md as clean of the known-refused compound shapes"
  else
    bad "scanner found a compound shape in setup/04-backlog-divert.md — see script output for the offending block"
  fi
fi

# (12) Regression: the built-in FILES list (no args) also reports clean,
# exercising the default (no-args) invocation path end-to-end.
if bash "$scanner" >/dev/null 2>&1; then
  ok "scanner's built-in FILES list (default invocation, no args) reports clean"
else
  bad "scanner's built-in FILES list (default invocation, no args) found a compound shape"
fi

# (13) Regression (issue #1289): dispatch-rules.md / drain.md /
# inline-trivial.md / steady-state.md — the four files #1289 swept 17 of
# their 18 flagged blocks from — stay clean. A future edit that
# reintroduces a compound shape in any of them fails this assertion.
# steady-state.md's one deliberately-deferred block (issue #1291) is exempt
# via its own `<!-- compound-block-scan: allow -->` marker, so this
# assertion still expects a clean exit for the file as a whole.
for f in dispatch-rules.md drain.md inline-trivial.md steady-state.md; do
  target="$repo_root/plugins/shipyard/commands/do-work/$f"
  if [[ -f "$target" ]]; then
    if bash "$scanner" "$target" >/dev/null 2>&1; then
      ok "scanner reports $f as clean of the known-refused compound shapes (#1289)"
    else
      bad "scanner found a compound shape in $f — see script output for the offending block"
    fi
  fi
done

# (14) Regression: the built-in FILES list now includes all five swept
# files (setup/04-backlog-divert.md + the four from #1289) — count-based
# proxy so a future accidental removal from FILES is caught even though the
# scanner's own output doesn't name which files it scanned.
# shellcheck disable=SC2016  # literal grep needle — matched verbatim in the script, not expanded
files_count=$(grep -cE '^\s*"\$repo_root/plugins/shipyard/commands/do-work/' "$scanner" 2>/dev/null || echo 0)
if [[ "$files_count" -ge 5 ]]; then
  ok "scanner's built-in FILES array lists at least 5 files (found $files_count)"
else
  bad "scanner's built-in FILES array lists fewer than 5 files (found $files_count) — #1289's additions may have regressed"
fi

# (15) Regression: steady-state.md's formerly-deferred A.0.5 block (issue
# #1291) has been extracted to scripts/crash-recovery-reap.sh, and the
# `<!-- compound-block-scan: allow -->` marker that exempted it has been
# removed — steady-state.md is now clean on its own merits, the same as
# the other three #1289 files (test 13 already covers that). This
# assertion guards the OTHER direction: a future edit must not reintroduce
# the marker as a shortcut around a NEW compound shape rather than fixing
# it. If this ever legitimately needs re-exempting, update this assertion
# alongside the marker, not silently.
steady_state_real="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
crash_recovery_reap_real="$repo_root/plugins/shipyard/scripts/crash-recovery-reap.sh"
if [[ -f "$steady_state_real" ]]; then
  if grep -qF -- '<!-- compound-block-scan: allow -->' "$steady_state_real"; then
    bad "steady-state.md still carries a compound-block-scan allow marker — #1291's extraction should have removed it entirely (no exemption should remain)"
  else
    ok "steady-state.md carries no compound-block-scan allow marker — #1291's A.0.5 extraction removed the exemption entirely"
  fi
  if grep -qF -- 'issues/1291' "$steady_state_real"; then
    ok "steady-state.md cites the #1291 extraction near its (now-extracted) A.0.5 block"
  else
    bad "steady-state.md does not cite issue #1291 near its A.0.5 block"
  fi
fi
if [[ -f "$crash_recovery_reap_real" ]]; then
  ok "scripts/crash-recovery-reap.sh exists — the #1291 extraction target for A.0.5's crash-recovery reap logic"
else
  bad "scripts/crash-recovery-reap.sh is missing — #1291's A.0.5 extraction target should exist"
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

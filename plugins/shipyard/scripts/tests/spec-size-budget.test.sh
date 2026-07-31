#!/usr/bin/env bash
# Test: per-file byte-size ceiling on the ALWAYS-loaded issue-work worker
# spec — issue #980.
#
# Background
# ----------
# Every `mode: issue-work` dispatch unconditionally reads three files before
# it looks at a single line of the repo it's working on:
#
#   agents/issue-worker/issue-work.md   the full step-by-step worker spec
#   skills/worker-preamble/SKILL.md     the shared worktree/return-contract rules
#   agents/issue-worker.md              the thin mode router
#
# #980 measured this "mandatory floor" at 187 KB (~53k tokens) and found it
# had grown 2.3x since 1.9.4 with nothing in the release process budgeting
# for the growth — each individually-reasonable addition compounded
# silently. The fix for the *existing* bloat was a one-time thin-router
# split of issue-work.md's rare/opt-in sections (§5.85, §5.9, §6.5, §6.6)
# into on-demand fragments loaded only when their trigger condition fires
# (mirroring the worker-preamble fragment split from #617/#808).
#
# That one-time cut doesn't stop the NEXT 2.3x drift. This suite is the
# durable fix #980 asked for: a per-file ceiling on the always-loaded
# files, checked in CI, so a future addition that meaningfully grows one of
# these files fails the build instead of silently compounding. Ceilings
# carry ~10-12% headroom over the size at the time this suite was added
# (2026-07-31, right after the #980 split) — enough for normal editing, not
# enough to silently re-absorb a whole section's worth of prose.
#
# Raising a ceiling is a valid fix when growth is deliberate and reviewed —
# just bump the number in this file and say why in the PR. The point isn't
# "these files may never grow," it's "growth is a decision someone makes on
# purpose," per #980's ask.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/spec-size-budget.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd "$here/../.." && pwd)"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_under_budget() {
  local file="$1"
  local ceiling="$2"
  local label="$3"

  if [[ ! -f "$file" ]]; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    file not found: %s\n' "$file"
    fail=$((fail+1))
    return
  fi

  local size
  size=$(wc -c < "$file" | tr -d ' ')

  if (( size <= ceiling )); then
    printf '  %sPASS%s  %s (%d bytes, ceiling %d)\n' "$GREEN" "$RESET" "$label" "$size" "$ceiling"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    %d bytes exceeds the %d-byte ceiling (issue #980 — mandatory-load worker spec)\n' "$size" "$ceiling"
    printf '    this file loads on EVERY issue-work dispatch, unconditionally\n'
    printf '    fix: split the growth into an on-demand fragment (see issue-work-*.md for the pattern),\n'
    printf '         or if the growth is deliberate and reviewed, raise the ceiling in this test and say why\n'
    fail=$((fail+1))
  fi
}

echo "== always-loaded issue-work worker spec — per-file size budget (#980)"

assert_under_budget \
  "$plugin_root/agents/issue-worker/issue-work.md" \
  112000 \
  "agents/issue-worker/issue-work.md"

assert_under_budget \
  "$plugin_root/skills/worker-preamble/SKILL.md" \
  68000 \
  "skills/worker-preamble/SKILL.md"

assert_under_budget \
  "$plugin_root/agents/issue-worker.md" \
  12000 \
  "agents/issue-worker.md (mode router)"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]

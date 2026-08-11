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
# issue-work.md's ceiling was raised 112000 -> 116000 by #986 (2026-07-31):
# a new §6.7 deferred-slice disposition shape (mirroring §6.5/§6.6's already-
# budgeted stub pattern) needed touchpoints at five spots — Inputs, a second
# §5 non-closing exception, a fifth §5.85 leak-verification trigger shape,
# the §6.7 stub itself, a step-8 return line, and a Don't bullet — all
# genuinely necessary for a worker to find and use the new on-demand
# fragment (issue-work-deferred-slice-dispatch.md, itself uncapped). Trimmed
# every addition to the terseness of the existing #851/#852 stubs first;
# what's left is the deliberate, reviewed growth this ceiling exists to
# gate, not silent compounding.
#
# issue-work.md's ceiling was raised 116000 -> 120000 by #1088 (2026-08-07):
# a new mandatory (not opt-in-gated) §4.45 self-check — never disable a
# committed security/supply-chain control to make CI pass — needed
# touchpoints at four spots: the §4.45 section itself, a step-6 pointer run
# before either trust branch, a step-8 return line for the new
# `auto-merge: unarmed — policy-override` outcome, and a Don't bullet.
# Because the check applies on every dispatch (unlike §6.5/§6.6/§6.7, which
# open with "skip unless this Context paragraph is present"), it couldn't be
# reduced to a trigger-and-pointer stub the way those were — the rule itself
# has to be inline for a worker to internalize it during implementation, not
# just discoverable when a rare condition fires. The repro and the narrow
# override carve-out moved to issue-work-RATIONALE.md (uncapped); what's
# left here is already trimmed to the terseness of the #851/#852/#986 stubs.
#
# skills/worker-preamble/SKILL.md's ceiling was LOWERED 68000 -> 57000 by
# #1012 (2026-07-31), the follow-on tail to #980/#1011: the same thin-core +
# on-demand-fragments pattern applied to issue-work.md by #1011 was applied
# to SKILL.md itself. Six rare/opt-in sections moved out to new or existing
# fragments — Never `git stash`'s mechanism + unavoidable-stash procedure
# (git-stash-prohibition.md), the broad-process-kill repro + host-detection
# check (process-kill-detail.md), the step-0/mid-session cwd-check's
# pre-#826 fallback form (consolidated once instead of duplicated twice,
# assert-worktree-cwd-fallback.md), the harness's 600s auto-background
# re-block pattern (folded into the existing ci-pitfalls.md, fixing a
# cross-reference from fix-checks-only.md that already assumed it lived
# there), and the background-process-cleanup mechanism table
# (stop-background-processes.md) — with trigger-and-pointer stubs left
# behind so no anchor reference broke and no rule lost reachability. Actual
# size dropped 61394 -> ~51555 bytes (-16%); the new ceiling carries the
# same ~10-12% headroom convention as every other row in this file.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 57000 -> 58000 by
# #1088 (2026-08-07): a new "Never disable a committed security or
# supply-chain control" prohibition, always-loaded so it reaches all seven
# worker modes per the originating issue's own ask — the reason it can't be
# pushed to an on-demand fragment the way most growth here is. Trimmed twice
# (once to the terseness of the "Never `--no-verify`" section immediately
# above it, once more after that still didn't fit) before touching this
# ceiling at all; the repro and full mechanism live in auto-merge.md and
# issue-work-RATIONALE.md (both uncapped), not duplicated here.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 58000 -> 59000 by
# #1113 (2026-08-07): a new "Auto-backgrounded verification must be awaited
# to a terminal result" bullet, sited directly next to the #1054
# commit-before-yield invariant it's the same family as ("don't yield in a
# state the orchestrator can't act on") — five workers in one session ended
# their dispatch on a non-terminal narrative ("I'll resume once it reports
# back") instead of awaiting an auto-backgrounded test run, and a prompt-
# level instruction telling a worker not to do this was not sufficient (one
# worker did it anyway with that exact instruction in its own dispatch
# prompt) — so the rule has to live in the always-loaded contract every mode
# reads, not per-dispatch prose. Kept to one bullet, matching the terseness
# of its four siblings in the same list; the repro detail (which issues, what
# the workers actually returned) stays in issue #1113 rather than duplicated
# here.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 59000 -> 60000 by
# #1135 (2026-08-08), a follow-up to #1115's declined `verifying` token: the
# "Auto-backgrounded verification must be awaited" bullet (#1113, above)
# told a worker to bail with `blocked:` when it genuinely can't finish
# verification within budget, but named no canonical phrase — so
# steady-state.md's Reason -> class table had nothing reliable to match,
# and such a bail fell through to the table's conservative `refuse` default
# (needs-human-review) instead of the `soft` (blocked:agent-soft,
# auto-retried next session) treatment it actually deserves — an
# environmental/transient condition, not a human judgment call. Extended
# the existing sentence in place (no new heading) to name the canonical
# phrase `verification did not complete within budget`; the file was
# already 22 bytes under the prior ceiling, so even this one-sentence
# extension needed the bump.
#
# skills/worker-preamble/SKILL.md did NOT need a ceiling raise for #1166
# (2026-08-09) — the new "Never create a credential" section (569 bytes) fit
# inside the ~864 bytes of headroom left after #1135's last raise.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 60000 -> 61000 by
# #1220 (2026-08-11): a new "File-path form" bullet in "Return-contract
# discipline" states the expected path form (repo-relative, never
# worktree- or primary-checkout-absolute) for any file paths a worker
# names in its return — always-loaded because the ambiguity it closes
# (a correct worker's return reading identically to an actual primary-
# checkout isolation violation) can arise on any dispatch, in any mode,
# not behind a rare/opt-in condition a fragment stub could gate on.
# Trimmed twice (once to the terseness of the "Never create a credential"
# section, once more after that still didn't fit) before touching this
# ceiling; the file had only 39 bytes of headroom left after #1135's raise,
# so even the trimmed ~700-byte bullet needed the bump.
#
# issue-work.md's ceiling was raised 120000 -> 121000 by #1166 (2026-08-09):
# a P0 security-boundary fix — a worker minted a live GCP service-account key
# to work around a missing credential rather than handing back — added a
# "Never create a credential" prohibition to the always-loaded
# skills/worker-preamble/SKILL.md core, plus a one-line Don't-section mirror
# in every per-mode file (this one included) so the prohibition is
# discoverable directly in the worker's own spec, not only via a skill
# cross-reference. issue-work.md was already 60 bytes under its prior
# ceiling; the new bullet needed the bump.
#
# issue-work.md's ceiling was raised 121000 -> 123000 by #1248 (2026-08-11):
# the backlog.self_assign config option (defaulting false) gates the
# self-assignment step in step 1 of every dispatch — a ~300-byte
# CLAUDE_PLUGIN_ROOT + SHIPYARD_REPO_ROOT preamble is now required before the
# bash block that reads the config (same preamble pattern already used in
# dispatch-rules.md, inline-trivial.md, and worker-preamble fragments), so
# the step can execute reliably. The preamble is load-bearing for the new
# feature and cannot be reasonably shortened without compromising the
# multi-layer config resolution it performs.
#
# skills/worker-preamble/SKILL.md's ceiling was raised 61000 -> 62000 by
# #1240 (2026-08-11): a new fragments-table row for milestone-prohibition.md
# (the worker-side half of shipyard:update-roadmap's orchestrator-only
# boundary — a worker must never create/rename/renumber/reassign a
# milestone) needed adding to the always-loaded fragments index. The file
# had only 28 bytes of headroom left after #1220's last raise, so even the
# row's terseness-trimmed shape (three trims, down from a fuller
# trigger/scope description) needed the bump.
#
# This file became the SOLE owner of these ceiling assertions by #1177
# (2026-08-09): commit-before-yield-1054.test.sh and
# detect-ci-gate-narrowing.test.sh had each grown their own mirrored copy of
# a subset of these same literals (with their own drifting raise-history
# comments), and the two copies had already gone out of sync once — the
# issue-work.md ceiling was raised to 121000 here but commit-before-
# yield-1054.test.sh's mirror still read 120000, costing a full fix-checks
# dispatch to diagnose on a P0 security PR. Both mirrors were pure defensive
# duplication (neither suite's own subject — the #1054 commit-before-yield
# invariant's content, the #1139 gate-narrowing pointer's content — has
# anything to do with file size) and were removed rather than reconciled via
# a shared constant: this suite already runs in the same CI job as every
# other `*.test.sh` on every PR (tests.yml's glob discovery), so there was
# never a coverage gap to fill, only a second place for the number to drift.
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
  123000 \
  "agents/issue-worker/issue-work.md"

assert_under_budget \
  "$plugin_root/skills/worker-preamble/SKILL.md" \
  62000 \
  "skills/worker-preamble/SKILL.md"

assert_under_budget \
  "$plugin_root/agents/issue-worker.md" \
  12000 \
  "agents/issue-worker.md (mode router)"

echo
echo "Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]

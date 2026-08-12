#!/usr/bin/env bash
# stale-check-refresh.sh — the post-main-CI-fix branch-refresh helper
# (issue #993), extracted to a script per issue #1277.
#
# Background
# ----------
# GitHub does NOT re-run a PR's already-completed required check just
# because the PR's base branch went from red to green — without a new
# commit or an explicit branch update, a PR that recorded a FAILURE while
# `main` was broken keeps that stale conclusion forever, even though the
# underlying cause is now fixed and a fresh run would pass. Left unhandled,
# this permanently strands every in-flight PR that happened to run its
# required checks during the main-red window: `mergeStateStatus` reads
# MERGEABLE and auto-merge is armed, but the stale check never re-runs on
# its own, so the PR sits BLOCKED indefinitely (issue #993's repro: a 7-PR
# merge train left BLOCKED forever after the fix that unblocked it had
# already merged).
#
# `setup/04-backlog-divert.md`'s "Post-main-CI-fix branch-refresh" section
# (and `drain.md`'s corresponding drain-phase health read) used to inline
# this whole check as a `for pr in $session_prs; do ... done` loop with
# three internal `gh pr view <pr> | jq ...` pipes. Both shapes — a `for`
# loop wrapping `gh` calls, and a pipe spanning a shell command boundary —
# are exactly what the worktree-isolation guard refuses post-relocation:
# "this command is too complex to verify that it stays inside the
# worktree." Extracting the loop to a script turns the orchestrator's own
# call into one plain command (`bash stale-check-refresh.sh run ...`),
# passing the guard the same way `backlog-filter.sh` / `worktree-reap.sh` /
# `flake-enforce.sh` already do for their own loop-shaped logic.
#
# As a side benefit, this also gives the "once per PR per fix, never twice"
# dedup guard a REAL persistence mechanism: the original inline loop kept
# `stale_check_refresh_done` as a bash associative array, which cannot
# actually survive between separate Bash tool calls (each is a fresh
# subshell) — so across the two call sites that run this check (session
# setup, and step D's periodic refresh), the in-memory array was reset
# every single invocation and the "once per fix" guarantee never actually
# held. The `--state-file` here is a real file, so it persists correctly
# across repeated calls within the same session.
#
# Subcommands
# -----------
#
#   run --repo <owner/repo> --fix-commit-sha <sha> --fix-commit-date <ISO8601>
#       --session-prs <space-or-comma-separated PR numbers> [--state-file <path>]
#     For each PR number in --session-prs: fetch its state/mergeStateStatus/
#     statusCheckRollup, skip non-OPEN and DIRTY PRs, skip PRs with no
#     hard-failing check that predates --fix-commit-date (i.e. not
#     stale-red), skip PRs already refreshed against this exact
#     --fix-commit-sha (per --state-file), then run `gh pr update-branch`
#     and record the refresh in --state-file. Prints one
#     `[stale-check-refresh] ...` line per PR actually refreshed.
#     --state-file defaults to `.shipyard-stale-refresh-done` in the
#     current directory (plain text, one `<pr> <sha>` line per refreshed
#     PR — append-only, deduped by the caller reading it before appending).
#     Exit 0 always (best-effort — an individual PR's `gh` failure is
#     logged and skipped, never aborts the rest of the batch, matching the
#     `|| true` posture the original inline loop had on its
#     `gh pr update-branch` call).
#
# Exit codes: 0 success (even when zero PRs needed a refresh); 64 bad
# usage; 65 missing dependency (jq/gh).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${here}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  stale-check-refresh.sh run --repo <owner/repo> --fix-commit-sha <sha>
      --fix-commit-date <ISO8601> --session-prs <PR numbers, space or comma separated>
      [--state-file <path>]
EOF
}

require_jq "stale-check-refresh.sh"
# GH is overridable (mirrors flake-enforce.sh's own GH="${GH:-gh}" convention)
# so the test suite can inject a mock gh binary and run with zero network
# access.
GH="${GH:-gh}"
if ! command -v "$GH" >/dev/null 2>&1; then
  echo "stale-check-refresh.sh: gh is required but not installed" >&2
  exit 65
fi

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  run)
    repo=""
    fix_commit_sha=""
    fix_commit_date=""
    session_prs_raw=""
    state_file=".shipyard-stale-refresh-done"

    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --fix-commit-sha) fix_commit_sha="${2:-}"; shift 2 ;;
        --fix-commit-date) fix_commit_date="${2:-}"; shift 2 ;;
        --session-prs) session_prs_raw="${2:-}"; shift 2 ;;
        --state-file) state_file="${2:-}"; shift 2 ;;
        *) echo "stale-check-refresh.sh run: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$repo" ] || [ -z "$fix_commit_sha" ] || [ -z "$fix_commit_date" ]; then
      echo "stale-check-refresh.sh run: --repo, --fix-commit-sha, and --fix-commit-date are required" >&2
      usage >&2
      exit 64
    fi

    touch "$state_file" 2>/dev/null || true

    # Normalize --session-prs: accept comma- or space-separated input.
    session_prs_normalized="${session_prs_raw//,/ }"

    # shellcheck disable=SC2086
    set -- $session_prs_normalized
    for pr in "$@"; do
      [ -z "$pr" ] && continue

      # Already refreshed against this exact fix commit? Skip without a
      # network call.
      if grep -qF "${pr} ${fix_commit_sha}" "$state_file" 2>/dev/null; then
        continue
      fi

      pr_snapshot=$("$GH" pr view "$pr" --repo "$repo" \
        --json state,mergeStateStatus,statusCheckRollup --jq '
          {state, mergeStateStatus,
           checks: [.statusCheckRollup | group_by(.name) | map(sort_by(.completedAt // .startedAt // "") | last) | .[]]}' \
        2>/dev/null)
      if [ -z "$pr_snapshot" ]; then
        echo "[stale-check-refresh] advisory: could not fetch PR #${pr} snapshot; skipping" >&2
        continue
      fi

      state=$(jq -r '.state' <<< "$pr_snapshot")
      merge_state=$(jq -r '.mergeStateStatus' <<< "$pr_snapshot")

      # Skip merged/closed PRs, and skip DIRTY — that's fix-rebase's
      # territory, not this gate's.
      [ "$state" != "OPEN" ] && continue
      [ "$merge_state" = "DIRTY" ] && continue

      # Any latest-per-name check that's a hard failure AND completed
      # BEFORE the fix landed is a stale-red carried over from the broken
      # main — not a genuine failure against the current (fixed) base.
      has_stale_red=$(jq --arg cutoff "$fix_commit_date" '
          [.checks[] | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
                      | select((.completedAt // .startedAt // "9999") < $cutoff)] | length > 0' \
        <<< "$pr_snapshot")
      [ "$has_stale_red" != "true" ] && continue

      "$GH" pr update-branch "$pr" --repo "$repo" || true
      printf '%s %s\n' "$pr" "$fix_commit_sha" >> "$state_file"
      echo "[stale-check-refresh] PR #${pr} carried a required-check FAILURE that predates ${repo}'s fix commit ${fix_commit_sha} (fixed at ${fix_commit_date}) — ran gh pr update-branch to re-trigger checks against the fixed base (#993)"
    done
    exit 0
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "stale-check-refresh.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac

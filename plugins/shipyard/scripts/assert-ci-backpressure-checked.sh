#!/usr/bin/env bash
# assert-ci-backpressure-checked.sh — mechanical backstop for issue #1141's
# CI queue-depth backpressure hold (issue #1156) having ACTUALLY RUN this
# turn, not merely existing as prose the orchestrating model is expected to
# execute every turn.
#
# Background (issue #1414, follow-up to #1399)
# ----------------------------------------------
# steady-state.md's queue-depth backpressure check (the block guarded by
# `.ci_capacity.shape == "self-hosted" && .ci_capacity.pool_total > 0`) is a
# prose instruction with no hook, wrapper, or assertion that fails when a
# dispatch happens without it having run — contrast
# hooks/enforce-worktree-isolation.sh, which hard-fails a dispatch missing
# its isolation signal. #1399 made a systematically-skipping session
# VISIBLE (the `ci_backpressure=<n/a|skipped-hosted|checked|held>`
# invariant-line token) but did not PREVENT the skip. This script is the
# decision layer for a mechanical gate that prevents it: called from
# hooks/enforce-worktree-isolation.sh immediately before a backlog-slot-
# filling worker dispatch is allowed to proceed.
#
# Two usages
# ----------
#
#   assert-ci-backpressure-checked.sh --decide \
#     <SHAPE> <POOL_TOTAL> <MARKER_VERDICT> <MARKER_AGE_SECONDS> \
#     <FRESHNESS_WINDOW_SECONDS> <BACKPRESSURE_VERDICT>
#     -> prints "allow" or "block" on stdout. Pure / hermetic, no I/O — this
#        is the decision this file's test suite exercises directly with
#        fixture inputs (never live session state or a live `gh` call).
#
#       SHAPE                    — `.ci_capacity.shape` ("self-hosted" is
#                                   the only value that can ever trigger a
#                                   block; anything else — "hosted",
#                                   "unknown", "", or a typo — always
#                                   "allow"s, matching steady-state.md's own
#                                   no-op guard).
#       POOL_TOTAL                — `.ci_capacity.pool_total`. A zero or
#                                   non-numeric value always "allow"s — same
#                                   defensive default detect-ci-runner-
#                                   capacity.sh's own decide_backpressure()
#                                   uses (never gate on a signal that
#                                   couldn't actually be read).
#       MARKER_VERDICT             — the persisted `.last_backpressure_check
#                                   .verdict` this session's steady-state.md
#                                   check block writes every time it runs
#                                   the self-hosted branch (see that file's
#                                   "Queue-depth backpressure check"
#                                   section). One of "checked" / "held" /
#                                   "" (no marker) / anything else.
#       MARKER_AGE_SECONDS          — wall-clock seconds between the
#                                   marker's `.at` timestamp and now. A
#                                   non-numeric value (unparseable
#                                   timestamp, or no marker at all) is
#                                   treated as "very old" — never treated as
#                                   fresh.
#       FRESHNESS_WINDOW_SECONDS    — how recent the marker must be to count
#                                   as "this turn's check ran". A
#                                   non-numeric value degrades to the
#                                   built-in default (300s / 5 minutes) —
#                                   generous enough to absorb ordinary
#                                   harness/tool-call latency between the
#                                   check block's Bash call and the
#                                   following dispatch call, tight enough to
#                                   catch a session that skips the check for
#                                   many consecutive turns (the #1399 repro
#                                   was an entire 11-PR session).
#       BACKPRESSURE_VERDICT        — "hold" / "dispatch" / "" (unknown).
#                                   Only consulted when the marker above is
#                                   absent or stale — see decide()'s
#                                   comment for why a positive live
#                                   confirmation is required before ever
#                                   blocking.
#
#   assert-ci-backpressure-checked.sh --live
#     -> resolves the running /shipyard:do-work session from disk, reads
#        its persisted state, and — ONLY when the marker above is absent or
#        stale — does a bounded live `gh run list` re-read before calling
#        decide(). Always prints "allow" or "block" on stdout; ALWAYS exits
#        0 regardless of the printed verdict (the caller — the hook —
#        decides what to do with it; this script's own exit code is never
#        the block signal, so a caller that mishandles/ignores the exit
#        code still can't accidentally treat a crash as "allow" or "block").
#
# Fail-open posture (issue #938's precedent — a plausible-looking mechanical
# gate that bricked the dispatch loop). EVERY ambiguity in the --live path —
# an unresolvable session id, an unreadable session-state field, a missing
# sibling script, a failed or timed-out `gh` call, non-numeric threshold
# inputs — degrades to "allow", never "block". A missed block is
# recoverable: the `ci_backpressure=` invariant-line token (#1399) still
# surfaces the skip after the fact. A wrong block is a hung dispatch slot
# with no way forward, which is strictly worse. Only a POSITIVE chain of
# evidence — self-hosted pool, pool_total > 0, no fresh evidence the check
# ran, AND an independent live re-read confirming the queue is actually
# over threshold right now — ever produces "block". decide() below has
# exactly two possible outputs ("allow" / "block") by design, not three —
# unlike some of this plugin's other pure-decision scripts (e.g.
# assert-worktree-cwd.sh's worktree/primary/error), there is no separate
# "error" verdict to potentially mishandle: every failure path folds into
# "allow" directly, so a caller checking `== "block"` cannot be fooled by
# an unexpected third string.
#
# Scope note — this gate only fires for BACKLOG-SLOT-FILLING dispatches
# (the 7 mode-driven workers), never for shipyard:verify-worker. Verify-
# worker is a nested, read-only sub-dispatch from WITHIN an already-running
# issue-work worker — it doesn't fill a step-C backlog slot and generates
# no new CI load, so gating it here would be pure friction with no benefit.
# That exclusion lives in the calling hook (enforce-worktree-isolation.sh),
# not in this script.

set -uo pipefail

# --------------------------------------------------------------------------
# decide — the pure, hermetic decision. See usage header above for the
# full parameter semantics.
# --------------------------------------------------------------------------
decide() {
  local shape="$1" pool_total="$2" marker_verdict="$3" marker_age="$4" \
        freshness_window="$5" backpressure_verdict="$6"

  # Not self-hosted -> nothing to protect. Matches steady-state.md's own
  # no-op guard exactly.
  if [ "$shape" != "self-hosted" ]; then
    printf 'allow\n'
    return 0
  fi

  case "$pool_total" in ''|*[!0-9]*) pool_total=0 ;; esac
  if [ "$pool_total" -eq 0 ]; then
    printf 'allow\n'
    return 0
  fi

  case "$marker_age" in ''|*[!0-9]*) marker_age=999999999 ;; esac
  case "$freshness_window" in ''|*[!0-9]*) freshness_window=300 ;; esac

  # Fresh evidence the check block genuinely ran THIS turn (or recently
  # enough to count) -- allow regardless of the verdict it recorded. A
  # "held" marker still means the check ran; a downstream CI-cheap-bias
  # dispatch under that hold is a legitimate, already-accounted-for policy
  # choice this gate must not second-guess.
  if { [ "$marker_verdict" = "checked" ] || [ "$marker_verdict" = "held" ]; } \
     && [ "$marker_age" -le "$freshness_window" ]; then
    printf 'allow\n'
    return 0
  fi

  # No fresh evidence the check ran. Only block when an INDEPENDENT live
  # re-read positively confirms the pool is over threshold right now --
  # never block on staleness alone, which would fire on a self-hosted repo
  # that simply isn't backpressured at the moment (a false positive with no
  # corresponding real risk).
  if [ "$backpressure_verdict" = "hold" ]; then
    printf 'block\n'
    return 0
  fi

  printf 'allow\n'
  return 0
}

# --------------------------------------------------------------------------
# live — resolve the running session from disk and decide. Every step fails
# open; see the header comment for the full posture.
# --------------------------------------------------------------------------
live() {
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "${self_dir}/.." && pwd)}"

  # 1. Resolve the primary repo root (the one holding
  #    .claude/worktrees/orchestrator-*). Prefer the per-worktree stash an
  #    orchestrator session writes at setup (00-config-worktree.md step
  #    0.56); fall back to the cwd's own toplevel.
  local primary_root=""
  if [ -f ".shipyard-primary-root" ]; then
    primary_root=$(cat .shipyard-primary-root 2>/dev/null)
  fi
  if [ -z "$primary_root" ]; then
    primary_root=$(git rev-parse --show-toplevel 2>/dev/null)
  fi
  if [ -z "$primary_root" ] || [ ! -d "$primary_root" ]; then
    printf 'allow\n'
    return 0
  fi

  # 2. Resolve the live session id. Prefer the per-worktree stash
  #    (00f-session-id-storage.md); fall back to the newest-by-mtime
  #    orchestrator worktree's own stash via session-identity.sh.
  local session_id=""
  if [ -f ".shipyard-session-id" ]; then
    session_id=$(tr -d '[:space:]' < .shipyard-session-id 2>/dev/null)
  fi
  if [ -z "$session_id" ]; then
    local identity_sh="${plugin_root}/scripts/session-identity.sh"
    if [ -f "$identity_sh" ]; then
      session_id=$(bash "$identity_sh" derive-session-id --repo-root "$primary_root" 2>/dev/null)
    fi
  fi
  if [ -z "$session_id" ]; then
    printf 'allow\n'
    return 0
  fi

  local session_state_sh="${plugin_root}/scripts/session-state.sh"
  if [ ! -f "$session_state_sh" ]; then
    printf 'allow\n'
    return 0
  fi

  # 3. Cheap fast path -- most repos (including this one) are `hosted`, so
  #    this is the common exit: no further reads, no network calls.
  local shape pool_total
  shape=$(bash "$session_state_sh" read --session-id "$session_id" \
    --path '.ci_capacity.shape // ""' 2>/dev/null)
  pool_total=$(bash "$session_state_sh" read --session-id "$session_id" \
    --path '.ci_capacity.pool_total // 0' 2>/dev/null)
  case "$pool_total" in ''|*[!0-9]*) pool_total=0 ;; esac
  if [ "$shape" != "self-hosted" ] || [ "$pool_total" -eq 0 ]; then
    printf 'allow\n'
    return 0
  fi

  # 4. Read the persisted evidence marker steady-state.md's check block
  #    writes every time it runs the self-hosted branch.
  local marker_verdict marker_at
  marker_verdict=$(bash "$session_state_sh" read --session-id "$session_id" \
    --path '.last_backpressure_check.verdict // ""' 2>/dev/null)
  marker_at=$(bash "$session_state_sh" read --session-id "$session_id" \
    --path '.last_backpressure_check.at // ""' 2>/dev/null)

  local common_sh="${self_dir}/lib/common.sh"
  local marker_epoch=0 now_epoch marker_age
  if [ -f "$common_sh" ]; then
    # shellcheck source=lib/common.sh disable=SC1091
    source "$common_sh"
    marker_epoch=$(iso_to_epoch "$marker_at")
  fi
  now_epoch=$(date -u +%s 2>/dev/null || echo 0)
  case "$marker_epoch" in ''|*[!0-9]*) marker_epoch=0 ;; esac
  if [ "$marker_epoch" -gt 0 ] && [ "$now_epoch" -gt 0 ] 2>/dev/null; then
    marker_age=$((now_epoch - marker_epoch))
    [ "$marker_age" -lt 0 ] && marker_age=999999999
  else
    marker_age=999999999
  fi

  local freshness_window="${ASSERT_CI_BACKPRESSURE_FRESHNESS_SECONDS:-300}"

  # Fast allow: fresh evidence, no network call needed at all.
  if { [ "$marker_verdict" = "checked" ] || [ "$marker_verdict" = "held" ]; } \
     && [ "$marker_age" -le "$freshness_window" ] 2>/dev/null; then
    printf 'allow\n'
    return 0
  fi

  # 5. Evidence missing/stale -- confirm independently before ever
  #    blocking. Needs the repo (for the live gh call), the current
  #    in-flight count (for the escape valve), and config thresholds.
  local repo
  repo=$(bash "$session_state_sh" read --session-id "$session_id" \
    --path '.repo // ""' 2>/dev/null)
  if [ -z "$repo" ]; then
    printf 'allow\n'
    return 0
  fi

  local capacity_sh="${plugin_root}/scripts/detect-ci-runner-capacity.sh"
  if [ ! -f "$capacity_sh" ]; then
    printf 'allow\n'
    return 0
  fi

  local config_sh="${plugin_root}/scripts/shipyard-config.sh"
  local multiplier="" min_in_flight=""
  if [ -f "$config_sh" ]; then
    multiplier=$(bash "$config_sh" get ci.backpressure_multiplier 2>/dev/null)
    min_in_flight=$(bash "$config_sh" get ci.backpressure_min_in_flight 2>/dev/null)
  fi

  local in_flight
  in_flight=$(bash "$session_state_sh" read --session-id "$session_id" \
    --path '.in_flight | length' 2>/dev/null)
  case "$in_flight" in ''|*[!0-9]*) in_flight=0 ;; esac

  # Bounded live re-read -- never let a slow/hanging `gh` call stall a
  # dispatch. A failed or timed-out read is indistinguishable from "no
  # evidence" here and always allows.
  local queued
  if command -v timeout >/dev/null 2>&1; then
    queued=$(timeout 10 gh run list --repo "$repo" --status queued --limit 100 \
      --json databaseId --jq 'length' 2>/dev/null)
  else
    queued=$(gh run list --repo "$repo" --status queued --limit 100 \
      --json databaseId --jq 'length' 2>/dev/null)
  fi
  case "$queued" in
    ''|*[!0-9]*)
      printf 'allow\n'
      return 0
      ;;
  esac

  local backpressure_verdict
  backpressure_verdict=$(bash "$capacity_sh" --decide-backpressure \
    "$pool_total" "$queued" "$in_flight" "${multiplier:-5}" "${min_in_flight:-1}" 2>/dev/null)

  decide "$shape" "$pool_total" "$marker_verdict" "$marker_age" \
    "$freshness_window" "$backpressure_verdict"
}

main() {
  case "${1:-}" in
    --decide)
      if [ "$#" -ne 7 ]; then
        echo "usage: $0 --decide <SHAPE> <POOL_TOTAL> <MARKER_VERDICT> <MARKER_AGE_SECONDS> <FRESHNESS_WINDOW_SECONDS> <BACKPRESSURE_VERDICT>" >&2
        exit 64
      fi
      decide "$2" "$3" "$4" "$5" "$6" "$7"
      exit 0
      ;;
    --live)
      live
      exit 0
      ;;
    *)
      echo "usage: $0 --decide <SHAPE> <POOL_TOTAL> <MARKER_VERDICT> <MARKER_AGE_SECONDS> <FRESHNESS_WINDOW_SECONDS> <BACKPRESSURE_VERDICT>" >&2
      echo "       $0 --live" >&2
      exit 64
      ;;
  esac
}

main "$@"

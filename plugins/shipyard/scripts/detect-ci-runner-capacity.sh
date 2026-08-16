#!/usr/bin/env bash
# detect-ci-runner-capacity.sh — read this repo's CI executor capacity: is it
# backed by a self-hosted runner pool (fixed, small), and if so, how many
# runners are online/idle right now, and how deep is the queued-run backlog.
#
# Background (issue #1141)
# -------------------------
# `--concurrency N` bounds how many WORKERS `/shipyard:do-work` runs at once.
# It says nothing about how many CI RUNS those workers generate, or whether
# the repo's CI executor can absorb them. On a repo whose CI runs on a small,
# fixed self-hosted runner pool, worker throughput and CI-landing throughput
# can decouple: the session dispatches happily while the queue behind the
# runners grows without bound. This script is the single executable read of
# that pool's shape, so a session can (a) clamp its effective concurrency
# toward the pool size at startup when it was only asking for the built-in/
# config default, and (b) surface a "queue depth far exceeds pool capacity"
# observation in the end-of-session summary instead of leaving the operator
# to notice N open PRs and guess why they haven't landed.
#
# Usage — live detection (the normal path):
#   bash detect-ci-runner-capacity.sh <owner/repo>
#     -> prints one of, on stdout (single line):
#          hosted
#          self-hosted pool_total=<N> pool_idle=<M> queued=<Q>
#          unknown
#        diagnostics on stderr. ALWAYS exits 0 — this is an advisory read,
#        never a hard failure. An unreadable signal degrades to `unknown`;
#        it never blocks or fails the caller's setup flow.
#
#   `hosted`       => no self-hosted runners are registered for this repo.
#                     GitHub-hosted runners are elastic, not a fixed-pool
#                     constraint — nothing to clamp toward.
#   `self-hosted`  => a registered self-hosted runner pool exists.
#                     pool_total = ONLINE runner count (the realistic ceiling
#                     on concurrent CI runs right now); pool_idle = online
#                     AND NOT busy; queued = runs currently queued repo-wide
#                     (an approximate depth signal, not exact — see below).
#   `unknown`      => the runner-pool signal could not be read at all. The
#                     most common cause is that the `gh` token lacks repo
#                     ADMIN on `repos/{owner}/{repo}/actions/runners` (that
#                     endpoint 404s/403s for anything less). Callers MUST NOT
#                     clamp on `unknown` — an unreadable signal is not
#                     evidence of a small pool, only evidence we couldn't look.
#
# Usage — pure decision (hermetic, for tests and for callers that already
# hold the three runner-count signals):
#   bash detect-ci-runner-capacity.sh --decide <RUNNER_COUNT> <ONLINE_COUNT> <BUSY_COUNT>
#     -> prints the same `hosted` / `self-hosted pool_total=... pool_idle=...`
#        token shape (never `unknown` — a failed API read is a live-path-only
#        concern, out of scope for the pure decision; queued depth is also
#        live-path-only and is not part of this pure decision).
#
# Usage — pure dispatch-time backpressure decision (issue #1156, hermetic,
# no network calls):
#   bash detect-ci-runner-capacity.sh --decide-backpressure \
#     <POOL_TOTAL> <QUEUED> <IN_FLIGHT> <MULTIPLIER> <MIN_IN_FLIGHT>
#     -> prints "hold" or "dispatch" on stdout (single line).
#
#   This is a SEPARATE decision from `decide()` above: `decide()` answers
#   "what shape is this repo's CI pool" (a one-time, session-start read);
#   `decide_backpressure()` answers "should THIS dispatch turn fill a freed
#   slot, or hold it" against a LIVE queued-run count re-read every dispatch
#   turn (`/shipyard:do-work` steady-state.md step C). Kept in this same
#   script because both consume the same pool-shape signal and this keeps a
#   single executable source of truth for CI-capacity decisions rather than
#   splitting the logic across two scripts.
#
#   - POOL_TOTAL     — `.ci_capacity.pool_total` from session state (the
#                       session-start online-runner count; 0 disables the
#                       check entirely — always "dispatch").
#   - QUEUED          — a LIVE re-read of `gh run list --status queued`
#                       (never the stale `queued_at_start` snapshot).
#   - IN_FLIGHT       — count of workers currently in `.in_flight` BEFORE
#                       this slot is filled.
#   - MULTIPLIER      — `ci.backpressure_multiplier` config value (default 5).
#                       Threshold = POOL_TOTAL × MULTIPLIER.
#   - MIN_IN_FLIGHT   — `ci.backpressure_min_in_flight` config value
#                       (default 1). Escape valve: if IN_FLIGHT is already
#                       below this floor, always "dispatch" regardless of
#                       queue depth, so a saturated pool can never fully
#                       stall the session with backlog work still waiting.
#
#   All five inputs degrade to a safe default on non-numeric input rather
#   than erroring (POOL_TOTAL/QUEUED/IN_FLIGHT -> 0, MULTIPLIER -> 5,
#   MIN_IN_FLIGHT -> 1) — this is an advisory throughput check, not a
#   security gate, so a malformed input should never crash the dispatch
#   loop; it degrades toward "dispatch" (POOL_TOTAL=0) or toward the
#   documented default threshold.
#
# Fail-safe posture: this is advisory-only, unlike the ungated-merge and
# gate-narrowing detectors (which gate a security-relevant merge decision).
# A false `unknown` costs nothing but a missed clamp/hint; a false
# `self-hosted` on a repo that's actually GitHub-hosted would wrongly clamp
# concurrency for no reason, so `unknown` is the safe default whenever the
# runners endpoint itself cannot be read cleanly — never guess `hosted` or
# fabricate a pool size. Likewise, `decide_backpressure()` fails toward
# "dispatch" on a zero/unreadable pool size — never toward holding every
# slot on a signal we couldn't actually read.
#
# Queue-depth caveat: `gh run list --status queued` is a repo-wide, all-
# workflow count — it does not distinguish which queued runs are actually
# waiting on THIS pool of self-hosted runners vs. a GitHub-hosted runner
# label that has effectively-unlimited capacity. On a repo that mixes both
# (some jobs `runs-on: self-hosted`, others `runs-on: ubuntu-latest`), the
# queued count is an upper bound on self-hosted contention, not an exact
# count. Callers treat it as a coarse "is the backlog roughly in proportion
# to the pool" signal, not a precise scheduling input.
#
# Usage — pure resume decision (issue #1402, hermetic, no network calls):
#   bash detect-ci-runner-capacity.sh --decide-resume \
#     <POOL_TOTAL> <QUEUED> <MULTIPLIER>
#     -> prints "resume" or "held" on stdout (single line).
#
#   A THIRD decision, alongside `decide()` and `decide_backpressure()`:
#   `decide_backpressure()` answers "should THIS turn fill a freed slot",
#   gated by an escape valve that guarantees at least `MIN_IN_FLIGHT` workers
#   stay dispatched — a guarantee that only holds while some worker IS in
#   flight. `decide_resume()` answers the inverse question asked from a
#   `paused_on_environment` pause, where by construction NO worker is in
#   flight (that's the deadlock condition that caused the pause in the first
#   place, see steady-state.md's "Session-wide environmental pause" section)
#   — so there is no in-flight count for an escape valve to protect, and this
#   function deliberately has none. Same threshold shape as
#   `decide_backpressure()` (`queued > pool_total * multiplier`), inverted:
#   "held" means the condition that caused the pause hasn't cleared yet;
#   "resume" means it has (or POOL_TOTAL is unreadable/zero, same defensive
#   default `decide_backpressure()` uses — never hold on a signal that
#   couldn't actually be read).
#
#   - POOL_TOTAL   — the pool size recorded when the pause was armed
#                     (`paused_on_environment.resume_probe_pool_total`).
#   - QUEUED        — a LIVE re-read of `gh run list --status queued`.
#   - MULTIPLIER    — `ci.backpressure_multiplier` config value (default 5),
#                      the SAME threshold multiplier that triggered the
#                      original hold — resume uses the same bar the hold did,
#                      not a separate hysteresis band.
#
#   Both numeric inputs degrade to 0 on non-numeric input (never crash);
#   MULTIPLIER degrades to 5. A zero/unreadable POOL_TOTAL always "resume"s
#   — an unreadable signal is not evidence the environment is still
#   saturated, only evidence the watcher couldn't check.

set -uo pipefail

decide() {
  local runner_count="$1" online_count="$2" busy_count="$3" idle

  case "$runner_count" in ''|*[!0-9]*) runner_count=0 ;; esac
  case "$online_count" in ''|*[!0-9]*) online_count=0 ;; esac
  case "$busy_count" in ''|*[!0-9]*) busy_count=0 ;; esac

  if [ "$runner_count" -eq 0 ]; then
    printf 'hosted\n'
    return 0
  fi

  idle=$((online_count - busy_count))
  [ "$idle" -lt 0 ] && idle=0
  printf 'self-hosted pool_total=%d pool_idle=%d\n' "$online_count" "$idle"
}

decide_backpressure() {
  local pool_total="$1" queued="$2" in_flight="$3" multiplier="$4" min_in_flight="$5"

  case "$pool_total" in ''|*[!0-9]*) pool_total=0 ;; esac
  case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  case "$in_flight" in ''|*[!0-9]*) in_flight=0 ;; esac
  case "$multiplier" in ''|*[!0-9.]*) multiplier=5 ;; esac
  case "$min_in_flight" in ''|*[!0-9]*) min_in_flight=1 ;; esac

  # A zero/unreadable pool size disables the check entirely — never gate
  # dispatch on a signal we couldn't actually read.
  if [ "$pool_total" -eq 0 ]; then
    printf 'dispatch\n'
    return 0
  fi

  # Escape valve — never let backpressure hold every slot on a saturated
  # pool. At least MIN_IN_FLIGHT workers stay dispatched regardless of
  # queue depth, so a heavily-backpressured session can't go fully idle
  # with backlog work still waiting and nothing ever filling a slot.
  if [ "$in_flight" -lt "$min_in_flight" ]; then
    printf 'dispatch\n'
    return 0
  fi

  awk -v q="$queued" -v p="$pool_total" -v m="$multiplier" \
    'BEGIN { print (q > p * m) ? "hold" : "dispatch" }'
}

decide_resume() {
  local pool_total="$1" queued="$2" multiplier="$3"

  case "$pool_total" in ''|*[!0-9]*) pool_total=0 ;; esac
  case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  case "$multiplier" in ''|*[!0-9.]*) multiplier=5 ;; esac

  # A zero/unreadable pool size always resumes — never hold a pause open on
  # a signal we couldn't actually read (same defensive posture as
  # decide_backpressure's zero-pool "dispatch" default).
  if [ "$pool_total" -eq 0 ]; then
    printf 'resume\n'
    return 0
  fi

  # Deliberately NO escape valve here — decide_backpressure's IN_FLIGHT
  # escape valve exists to guarantee forward progress while other workers
  # are running; a paused_on_environment pause exists precisely because NO
  # worker is in flight, so there is nothing for an escape valve to protect.
  awk -v q="$queued" -v p="$pool_total" -v m="$multiplier" \
    'BEGIN { print (q > p * m) ? "held" : "resume" }'
}

main() {
  if [ "${1:-}" = "--decide" ]; then
    if [ "$#" -ne 4 ]; then
      echo "usage: $0 --decide <RUNNER_COUNT> <ONLINE_COUNT> <BUSY_COUNT>" >&2
      exit 1
    fi
    decide "$2" "$3" "$4"
    exit 0
  fi

  if [ "${1:-}" = "--decide-backpressure" ]; then
    if [ "$#" -ne 6 ]; then
      echo "usage: $0 --decide-backpressure <POOL_TOTAL> <QUEUED> <IN_FLIGHT> <MULTIPLIER> <MIN_IN_FLIGHT>" >&2
      exit 1
    fi
    decide_backpressure "$2" "$3" "$4" "$5" "$6"
    exit 0
  fi

  if [ "${1:-}" = "--decide-resume" ]; then
    if [ "$#" -ne 4 ]; then
      echo "usage: $0 --decide-resume <POOL_TOTAL> <QUEUED> <MULTIPLIER>" >&2
      exit 1
    fi
    decide_resume "$2" "$3" "$4"
    exit 0
  fi

  local repo="${1:-}"
  if [ -z "$repo" ]; then
    echo "usage: $0 <owner/repo>" >&2
    echo "       $0 --decide <RUNNER_COUNT> <ONLINE_COUNT> <BUSY_COUNT>" >&2
    echo "       $0 --decide-backpressure <POOL_TOTAL> <QUEUED> <IN_FLIGHT> <MULTIPLIER> <MIN_IN_FLIGHT>" >&2
    echo "       $0 --decide-resume <POOL_TOTAL> <QUEUED> <MULTIPLIER>" >&2
    exit 1
  fi

  local runners_json runner_count online_count busy_count queued decision

  # Requires repo ADMIN — fails closed (empty body) for anything less. That's
  # fine: this is an advisory read, and `unknown` is the correct, safe
  # response to "I couldn't check."
  runners_json="$(gh api "repos/${repo}/actions/runners" 2>/dev/null)"
  if [ -z "$runners_json" ]; then
    echo "detect-ci-runner-capacity: could not read repos/${repo}/actions/runners (needs repo admin, or a transient API error) -- treating as unknown" >&2
    printf 'unknown\n'
    exit 0
  fi

  runner_count="$(printf '%s' "$runners_json" | jq -r '.runners | length' 2>/dev/null)"
  case "$runner_count" in
    ''|*[!0-9]*)
      echo "detect-ci-runner-capacity: runners response for '${repo}' was unparseable -- treating as unknown" >&2
      printf 'unknown\n'
      exit 0
      ;;
  esac

  online_count="$(printf '%s' "$runners_json" | jq -r '[.runners[] | select(.status=="online")] | length' 2>/dev/null)"
  busy_count="$(printf '%s' "$runners_json" | jq -r '[.runners[] | select(.busy==true)] | length' 2>/dev/null)"

  decision="$(decide "$runner_count" "$online_count" "$busy_count")"

  queued=0
  if [ "$runner_count" -gt 0 ]; then
    queued="$(gh run list --repo "$repo" --status queued --limit 100 --json databaseId --jq 'length' 2>/dev/null)"
    case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  fi

  printf 'repo=%s runner_count=%s online_count=%s busy_count=%s queued=%s\n' \
    "$repo" "$runner_count" "$online_count" "$busy_count" "$queued" >&2

  if [ "$decision" = "hosted" ]; then
    printf 'hosted\n'
  else
    printf '%s queued=%d\n' "$decision" "$queued"
  fi
}

main "$@"

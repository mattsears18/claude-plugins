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
# Fail-safe posture: this is advisory-only, unlike the ungated-merge and
# gate-narrowing detectors (which gate a security-relevant merge decision).
# A false `unknown` costs nothing but a missed clamp/hint; a false
# `self-hosted` on a repo that's actually GitHub-hosted would wrongly clamp
# concurrency for no reason, so `unknown` is the safe default whenever the
# runners endpoint itself cannot be read cleanly — never guess `hosted` or
# fabricate a pool size.
#
# Queue-depth caveat: `gh run list --status queued` is a repo-wide, all-
# workflow count — it does not distinguish which queued runs are actually
# waiting on THIS pool of self-hosted runners vs. a GitHub-hosted runner
# label that has effectively-unlimited capacity. On a repo that mixes both
# (some jobs `runs-on: self-hosted`, others `runs-on: ubuntu-latest`), the
# queued count is an upper bound on self-hosted contention, not an exact
# count. Callers treat it as a coarse "is the backlog roughly in proportion
# to the pool" signal, not a precise scheduling input.

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

main() {
  if [ "${1:-}" = "--decide" ]; then
    if [ "$#" -ne 4 ]; then
      echo "usage: $0 --decide <RUNNER_COUNT> <ONLINE_COUNT> <BUSY_COUNT>" >&2
      exit 1
    fi
    decide "$2" "$3" "$4"
    exit 0
  fi

  local repo="${1:-}"
  if [ -z "$repo" ]; then
    echo "usage: $0 <owner/repo>" >&2
    echo "       $0 --decide <RUNNER_COUNT> <ONLINE_COUNT> <BUSY_COUNT>" >&2
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

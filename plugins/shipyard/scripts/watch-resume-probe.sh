#!/usr/bin/env bash
# watch-resume-probe.sh — poll the environmental condition behind a
# `paused_on_environment` session-wide pause (issue #1402) until it clears,
# times out, or the probe itself stops answering, then emit exactly one line
# on stdout describing that outcome and exit with a status code reflecting
# which one fired.
#
# Background (issue #1402)
# -------------------------
# When `/do-work`'s dispatch loop holds every freed slot for CI queue-depth
# backpressure (issues #1156/#1399) AND, after that hold, no worker remains
# in flight, the loop has no future agent-completion notification to wake it
# up again — the turn just ends, and a transient, self-clearing condition
# (a saturated self-hosted runner pool draining on its own — the #1402
# repro observed real recovery in 45 idle minutes) silently strands the
# session exactly as if it had genuinely finished, with a human needing to
# notice and re-invoke `/do-work`.
#
# The fix is a bounded `Monitor` watch that re-arms the wake source: instead
# of ending the turn with nothing further to happen, the orchestrator arms
# `Monitor({ command: "bash watch-resume-probe.sh ...", persistent: true })`
# before ending its turn, and the Monitor's own terminal-line notification
# is what wakes the orchestrator back up. But per a maintainer's finding
# while applying this issue in the session that filed it, the
# worktree-isolation guard refuses a `Monitor` command on the same grounds
# it refuses an inline `Bash` poll loop — "too complex to verify that it
# stays inside the worktree" (see dont.md's "Post-relocation Bash blocks
# must be plain, single-purpose commands", issue #1277, and
# drain.md's "Worktree-safe polling pattern", issue #1326, which documents
# the identical extract-to-a-script remedy for watch-pr-terminal.sh's
# single-PR case). This script IS that extraction for the resume-probe
# case: the loop lives once, in this file, and the orchestrator's `Monitor`
# call invokes it as ONE plain command.
#
# What this watches (issue #1402, scope note)
# ---------------------------------------------
# Currently CI-queue-depth-specific — the only environmental-halt detector
# this repo has wired (issues #1156/#1399). It re-reads the LIVE queued-run
# count and re-runs `detect-ci-runner-capacity.sh --decide-resume` (the
# SAME threshold multiplier that caused the original hold — resume clears
# at the same bar the hold set, not a separate hysteresis band) each poll.
# A broader environmental cause (host load, a provider outage) is explicitly
# out of scope for this first cut — see steady-state.md's "Session-wide
# environmental pause" section for the full trigger condition and how a
# future broader detector could extend this script (or a sibling) without
# changing the `paused_on_environment` state shape.
#
# Usage:
#   watch-resume-probe.sh --repo <owner/repo> --pool-total <N> \
#     [--multiplier <M>] [--interval <secs>] [--max-wait <secs>]
#   watch-resume-probe.sh --help
#
#   --repo <owner/repo>  target repo (required).
#   --pool-total <N>     the self-hosted runner pool size recorded when the
#                         pause was armed (`paused_on_environment
#                         .resume_probe_pool_total`; required, must be > 0 —
#                         a 0 pool means there was nothing to pause for, and
#                         the caller should not have armed this watch).
#   --multiplier <M>     ci.backpressure_multiplier config value (default 5)
#                         — must match the multiplier that triggered the
#                         original hold.
#   --interval <secs>    seconds to sleep between polls (default 300 = 5min,
#                         matching paused_on_environment.poll_interval_seconds
#                         — deliberately coarser than step C's own live
#                         per-dispatch re-read; see that config knob's
#                         schema description for why).
#   --max-wait <secs>    maximum total wall-clock seconds to poll before
#                         giving up and emitting a `held-timeout` line
#                         (default 14400 = 4h, matching
#                         paused_on_environment.max_hours's default —
#                         override with the actual seconds remaining to the
#                         pause's own anchored deadline_at, never a fresh
#                         4h window, so a re-armed watch cannot roll the
#                         bound forward).
#
# Terminal states — exactly ONE line is printed to stdout, then the process
# exits. Per-poll diagnostics (a heartbeat every interval, and any `gh`
# error text) go to stderr only, so a caller parsing stdout (or a `Monitor`
# watching it) sees exactly one notification-worthy line for the whole run:
#
#   resumed pool_total=<N> queued=<Q> threshold=<T> elapsed=<S>s
#     -> exit 0
#   held-timeout pool_total=<N> queued=<Q> threshold=<T> elapsed=<S>s max_wait=<S>s
#     -> exit 1
#   error pool_total=<N> reason="<msg>" elapsed=<S>s
#     -> exit 4
#
# Every stdout line above is prefixed with `watch-resume-probe: `. Silence
# is never the outcome — every terminal state above emits a line, including
# both failure transitions (`held-timeout`, `error`), not just the happy
# path (`resumed`) — a watcher that only reported recovery would stay
# silent through a pool that never recovers or a `gh` outage, and silence
# is indistinguishable from "still waiting", which is the exact failure
# mode issue #1402 is about, one level down.
#
# `gh` failures (network blip, rate limit) are retried up to 3 consecutive
# times before the run gives up with the `error` terminal state — a single
# transient failure does not end the watch.
#
# Where to invoke this from: steady-state.md's "Session-wide environmental
# pause" section (step C) arms the pause and the `Monitor` call; step D's
# periodic refresh handles the resulting notification. Always invoke as one
# plain `bash "$CLAUDE_PLUGIN_ROOT/scripts/watch-resume-probe.sh" ...`
# command inside a `Monitor` call, never wrapped in a shell loop of its own.

set -u

usage() {
  cat >&2 <<'EOF'
usage: watch-resume-probe.sh --repo <owner/repo> --pool-total <N> [--multiplier <M>] [--interval <secs>] [--max-wait <secs>]
       watch-resume-probe.sh --help

  --repo <owner/repo>  target repo (required).
  --pool-total <N>     self-hosted runner pool size recorded when the pause
                        was armed (required, must be > 0).
  --multiplier <M>     ci.backpressure_multiplier value (default 5) — must
                        match the multiplier that triggered the original
                        hold.
  --interval <secs>    seconds to sleep between polls (default 300).
  --max-wait <secs>    max total wall-clock seconds before giving up and
                        emitting a `held-timeout` line (default 14400 = 4h).

  Polls the environmental condition behind a paused_on_environment pause
  (issue #1402) to a terminal state and prints exactly one line on stdout,
  then exits:

    watch-resume-probe: resumed pool_total=<N> queued=<Q> threshold=<T> elapsed=<S>s
      -> exit 0
    watch-resume-probe: held-timeout pool_total=<N> queued=<Q> threshold=<T> elapsed=<S>s max_wait=<S>s
      -> exit 1
    watch-resume-probe: error pool_total=<N> reason="<msg>" elapsed=<S>s
      -> exit 4

  Per-poll heartbeats and `gh` error text go to stderr only. See the header
  comment in this file for the #1402 background and how this composes with
  steady-state.md's session-wide pause and the `Monitor` tool.

  --help itself always exits 0, distinct from every other usage error above
  (issue #1550) — print-only usage() lets callers pick the exit code.
EOF
}

repo=""
pool_total=""
multiplier=5
interval=300
max_wait=14400

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --pool-total)
      pool_total="${2:-}"
      shift 2
      ;;
    --multiplier)
      multiplier="${2:-}"
      shift 2
      ;;
    --interval)
      interval="${2:-}"
      shift 2
      ;;
    --max-wait)
      max_wait="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "watch-resume-probe: unknown argument: $1" >&2
      usage
      exit 4
      ;;
  esac
done

if [ -z "$repo" ] || [ -z "$pool_total" ]; then
  echo "watch-resume-probe: --repo and --pool-total are both required" >&2
  usage
  exit 4
fi

case "$pool_total" in
  ''|*[!0-9]*)
    echo "watch-resume-probe: --pool-total must be a positive integer, got '$pool_total'" >&2
    usage
    exit 4
    ;;
esac
if [ "$pool_total" -eq 0 ]; then
  echo "watch-resume-probe: --pool-total must be > 0 (a 0 pool has nothing to pause for)" >&2
  usage
  exit 4
fi

case "$multiplier" in
  ''|*[!0-9.]*)
    echo "watch-resume-probe: --multiplier must be numeric, got '$multiplier'" >&2
    usage
    exit 4
    ;;
esac

case "$interval" in
  ''|*[!0-9]*)
    echo "watch-resume-probe: --interval must be a non-negative integer, got '$interval'" >&2
    usage
    exit 4
    ;;
esac

case "$max_wait" in
  ''|*[!0-9]*)
    echo "watch-resume-probe: --max-wait must be a non-negative integer, got '$max_wait'" >&2
    usage
    exit 4
    ;;
esac

if ! command -v gh >/dev/null 2>&1; then
  printf 'watch-resume-probe: error pool_total=%s reason="gh CLI not found on PATH" elapsed=0s\n' "$pool_total"
  exit 4
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
detector="$here/detect-ci-runner-capacity.sh"
if [ ! -f "$detector" ]; then
  printf 'watch-resume-probe: error pool_total=%s reason="detect-ci-runner-capacity.sh not found at %s" elapsed=0s\n' "$pool_total" "$detector"
  exit 4
fi

consecutive_errors=0
max_consecutive_errors=3
threshold="$(awk -v p="$pool_total" -v m="$multiplier" 'BEGIN { printf "%d", p * m }')"

SECONDS=0
while :; do
  queued_raw="$(gh run list --repo "$repo" --status queued --json databaseId 2>&1)"
  gh_exit=$?

  if [ "$gh_exit" -ne 0 ]; then
    consecutive_errors=$((consecutive_errors + 1))
    reason_line="$(printf '%s' "$queued_raw" | tr '\n' ' ' | cut -c1-200)"
    echo "watch-resume-probe: gh run list failed (attempt $consecutive_errors/$max_consecutive_errors): $reason_line" >&2
    if [ "$consecutive_errors" -ge "$max_consecutive_errors" ]; then
      printf 'watch-resume-probe: error pool_total=%s reason="gh run list failed %s consecutive times: %s" elapsed=%ss\n' \
        "$pool_total" "$consecutive_errors" "$reason_line" "$SECONDS"
      exit 4
    fi
  else
    consecutive_errors=0
    queued="$(printf '%s' "$queued_raw" | jq -r 'length' 2>/dev/null)"
    case "$queued" in ''|*[!0-9]*) queued=0 ;; esac

    verdict="$(bash "$detector" --decide-resume "$pool_total" "$queued" "$multiplier")"

    if [ "$verdict" = "resume" ]; then
      printf 'watch-resume-probe: resumed pool_total=%s queued=%s threshold=%s elapsed=%ss\n' \
        "$pool_total" "$queued" "$threshold" "$SECONDS"
      exit 0
    fi

    echo "watch-resume-probe: heartbeat pool_total=$pool_total queued=$queued threshold=$threshold elapsed=${SECONDS}s verdict=$verdict" >&2
  fi

  if [ "$SECONDS" -ge "$max_wait" ]; then
    printf 'watch-resume-probe: held-timeout pool_total=%s queued=%s threshold=%s elapsed=%ss max_wait=%ss\n' \
      "$pool_total" "${queued:-unknown}" "$threshold" "$SECONDS" "$max_wait"
    exit 1
  fi

  sleep "$interval"
done

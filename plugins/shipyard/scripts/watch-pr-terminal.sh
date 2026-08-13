#!/usr/bin/env bash
# watch-pr-terminal.sh — poll a SINGLE PR to a terminal state (merged /
# closed / a failing check) and emit exactly one line on stdout describing
# that state, then exit with a status code reflecting which one fired.
#
# Background (issue #1326)
# -------------------------
# drain.md's end-of-session drain is specified as a poll loop over
# `session_prs` ("Every 60s, snapshot the open PRs and compute ..."), but the
# orchestrator cannot express a literal `while true; do ... done` poll loop as
# an inline post-relocation Bash command — the worktree-isolation guard
# refuses it as "too complex to verify that it stays inside the worktree"
# (see dont.md's "Post-relocation Bash blocks must be plain, single-purpose
# commands" rule, issue #1277). The guard's own remedy in the refusal message
# — "break it into plain, separate commands" — doesn't work for a poll loop:
# its whole point is repeating a `gh` call an unbounded, data-dependent
# number of times, which can't be pre-decomposed into a fixed sequence of
# tool calls the way a short, bounded block can.
#
# The working pattern is dont.md's "extract to a script" branch, applied to
# polling specifically: write the loop body once, as a script, and invoke it
# as a single plain command (`bash watch-pr-terminal.sh --pr <N> --repo
# <owner/repo>`). This script IS that extraction for the single-PR case —
# see drain.md's "Worktree-safe polling pattern" section for how it composes
# with the drain's own multi-PR batched bookkeeping (which this script does
# NOT replace — it reads one PR at a time; the drain's per-poll snapshot
# reads `session_prs` in one batched query) and with the `Monitor` tool
# (which streams a background command's stdout as notifications — the
# natural way to watch this script's terminal line without blocking the
# caller's own turn).
#
# Usage:
#   watch-pr-terminal.sh --pr <N> --repo <owner/repo> [--interval <secs>] [--max-wait <secs>]
#   watch-pr-terminal.sh --help
#
#   --pr <N>            PR number to watch (required).
#   --repo <owner/repo> target repo (required).
#   --interval <secs>   seconds to sleep between polls (default 60 — matches
#                        the drain's own per-poll cadence).
#   --max-wait <secs>   maximum total wall-clock seconds to poll before
#                        giving up and emitting a `timeout` line (default
#                        7200 = 2h — a sane bounded ceiling, not open-ended;
#                        override for a PR you know needs longer, e.g. a
#                        slow release-deploy watch).
#
# Terminal states — exactly ONE line is printed to stdout, then the process
# exits. Per-poll diagnostics (a heartbeat every interval, and any `gh`
# error text) go to stderr only, so a caller parsing stdout (or a `Monitor`
# watching it) sees exactly one notification-worthy line for the whole run:
#
#   merged pr=<N> repo=<owner/repo> elapsed=<S>s              -> exit 0
#   closed pr=<N> repo=<owner/repo> elapsed=<S>s               -> exit 3
#   failing pr=<N> repo=<owner/repo> check="<name>" \
#     conclusion=<CONCLUSION> elapsed=<S>s                     -> exit 2
#   timeout pr=<N> repo=<owner/repo> elapsed=<S>s max_wait=<S>s -> exit 1
#   error pr=<N> repo=<owner/repo> reason="<msg>"               -> exit 4
#
# Every stdout line above is prefixed with `watch-pr-terminal: `.
#
# "failing" fires the FIRST time the PR's latest-per-check-name rollup shows
# a hard failure (FAILURE/ERROR/TIMED_OUT/CANCELLED/ACTION_REQUIRED) — the
# same latest-per-name de-duplication drain.md's own R_new/D_dirty_red
# classification uses (issue #333), so a stale FAILURE entry superseded by a
# later SUCCESS never falsely trips this. A PR that goes DIRTY is NOT its own
# terminal state here — `gh pr view`'s `state` field only ever reports
# OPEN/CLOSED/MERGED, and a DIRTY-but-still-open PR keeps polling normally
# until it merges, closes, or a check fails.
#
# `gh` failures (network blip, rate limit) are retried up to 3 consecutive
# times before the run gives up with the `error` terminal state — a single
# transient failure does not end the watch.
#
# Where to invoke this from: see drain.md's "Worktree-safe polling pattern"
# section for the canonical call — always as one plain `bash
# "$CLAUDE_PLUGIN_ROOT/scripts/watch-pr-terminal.sh" ...` command, never
# wrapped in a shell loop of its own.

set -u

usage() {
  cat >&2 <<'EOF'
usage: watch-pr-terminal.sh --pr <N> --repo <owner/repo> [--interval <secs>] [--max-wait <secs>]
       watch-pr-terminal.sh --help

  --pr <N>             PR number to watch (required).
  --repo <owner/repo>  target repo (required).
  --interval <secs>    seconds to sleep between polls (default 60).
  --max-wait <secs>    max total wall-clock seconds before giving up and
                        emitting a `timeout` line (default 7200 = 2h).

  Polls a SINGLE PR to a terminal state and prints exactly one line on
  stdout, then exits:

    watch-pr-terminal: merged pr=<N> repo=<owner/repo> elapsed=<S>s
      -> exit 0
    watch-pr-terminal: closed pr=<N> repo=<owner/repo> elapsed=<S>s
      -> exit 3
    watch-pr-terminal: failing pr=<N> repo=<owner/repo> check="<name>" conclusion=<C> elapsed=<S>s
      -> exit 2
    watch-pr-terminal: timeout pr=<N> repo=<owner/repo> elapsed=<S>s max_wait=<S>s
      -> exit 1
    watch-pr-terminal: error pr=<N> repo=<owner/repo> reason="<msg>"
      -> exit 4

  Per-poll heartbeats and `gh` error text go to stderr only. See the header
  comment in this file for the #1326 background and how this composes with
  drain.md's own multi-PR batched bookkeeping and the `Monitor` tool.
EOF
  exit 4
}

pr=""
repo=""
interval=60
max_wait=7200

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)
      pr="${2:-}"
      shift 2
      ;;
    --repo)
      repo="${2:-}"
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
      ;;
    *)
      echo "watch-pr-terminal: unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [ -z "$pr" ] || [ -z "$repo" ]; then
  echo "watch-pr-terminal: --pr and --repo are both required" >&2
  usage
fi

case "$pr" in
  ''|*[!0-9]*)
    echo "watch-pr-terminal: --pr must be a positive integer, got '$pr'" >&2
    usage
    ;;
esac

case "$interval" in
  ''|*[!0-9]*)
    echo "watch-pr-terminal: --interval must be a non-negative integer, got '$interval'" >&2
    usage
    ;;
esac

case "$max_wait" in
  ''|*[!0-9]*)
    echo "watch-pr-terminal: --max-wait must be a non-negative integer, got '$max_wait'" >&2
    usage
    ;;
esac

if ! command -v gh >/dev/null 2>&1; then
  printf 'watch-pr-terminal: error pr=%s repo=%s reason="gh CLI not found on PATH"\n' "$pr" "$repo"
  exit 4
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'watch-pr-terminal: error pr=%s repo=%s reason="jq not found on PATH"\n' "$pr" "$repo"
  exit 4
fi

consecutive_errors=0
max_consecutive_errors=3
state=""

SECONDS=0
while :; do
  raw="$(gh pr view "$pr" --repo "$repo" --json state,statusCheckRollup 2>&1)"
  gh_exit=$?

  if [ "$gh_exit" -ne 0 ]; then
    consecutive_errors=$((consecutive_errors + 1))
    reason_line="$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-200)"
    echo "watch-pr-terminal: gh pr view failed (attempt $consecutive_errors/$max_consecutive_errors): $reason_line" >&2
    if [ "$consecutive_errors" -ge "$max_consecutive_errors" ]; then
      printf 'watch-pr-terminal: error pr=%s repo=%s reason="gh pr view failed %s consecutive times: %s"\n' \
        "$pr" "$repo" "$consecutive_errors" "$reason_line"
      exit 4
    fi
  else
    consecutive_errors=0
    state="$(printf '%s' "$raw" | jq -r '.state // "unknown"')"

    if [ "$state" = "MERGED" ]; then
      printf 'watch-pr-terminal: merged pr=%s repo=%s elapsed=%ss\n' "$pr" "$repo" "$SECONDS"
      exit 0
    fi

    if [ "$state" = "CLOSED" ]; then
      printf 'watch-pr-terminal: closed pr=%s repo=%s elapsed=%ss\n' "$pr" "$repo" "$SECONDS"
      exit 3
    fi

    # Latest-per-check-name hard-failure detection — mirrors drain.md's own
    # R_new / D_dirty_red rollup de-duplication (issue #333): collapse every
    # check name to its most-recently-completed run before testing for a
    # hard failure, so a stale FAILURE entry superseded by a later SUCCESS
    # never falsely trips this.
    fail_line="$(printf '%s' "$raw" | jq -r '
      [.statusCheckRollup
       | group_by(.name)
       | map(sort_by(.completedAt // .startedAt // "") | last)
       | .[]
       | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
      | first // empty
      | if . == null then empty else "\(.name)\t\(.conclusion // .status)" end
    ')"
    if [ -n "$fail_line" ]; then
      check_name="$(printf '%s' "$fail_line" | cut -f1)"
      conclusion="$(printf '%s' "$fail_line" | cut -f2)"
      printf 'watch-pr-terminal: failing pr=%s repo=%s check="%s" conclusion=%s elapsed=%ss\n' \
        "$pr" "$repo" "$check_name" "$conclusion" "$SECONDS"
      exit 2
    fi
  fi

  echo "watch-pr-terminal: heartbeat pr=$pr repo=$repo elapsed=${SECONDS}s state=${state:-unknown}" >&2

  if [ "$SECONDS" -ge "$max_wait" ]; then
    printf 'watch-pr-terminal: timeout pr=%s repo=%s elapsed=%ss max_wait=%ss\n' "$pr" "$repo" "$SECONDS" "$max_wait"
    exit 1
  fi

  sleep "$interval"
done

#!/usr/bin/env bash
# stale-failure-check.sh — dispatch-rules.md §2a's stale-failure check
# (issue #323's `ci.verify_check_failing_on_head_before_dispatch` gate),
# extracted to a script per issue #1289 (the follow-up to #1277/#1288).
#
# Background
# ----------
# Before dispatching a fix-checks-only worker against a red PR, the
# orchestrator can optionally verify the failing check is still LIVE against
# the PR's current head — not a fossil of an earlier push that's since been
# superseded. `dispatch-rules.md`'s §2a inlined this as a `for url in $(...)`
# loop with three internal pipes (`echo "$rollup" | jq ...` x2, `echo "$url"
# | grep ... | grep ... | head -1`) — exactly the two shapes the
# worktree-isolation guard refuses post-relocation: a for/while loop wrapping
# gh calls, and a pipe spanning a shell command boundary. See
# `plugins/shipyard/commands/do-work/dont.md`'s "Post-relocation Bash blocks
# must be plain, single-purpose commands" section for the general rule.
#
# What "stale" means here: EVERY failing check in the rollup ran against a
# SHA older than the PR's current head — i.e. the failure has been
# superseded by a later push and a fresh dispatch would just re-discover the
# same "nothing to fix, already fixed" outcome fix-checks-only would report
# anyway, at the cost of one wasted CI-minute-consuming dispatch. A failing
# check whose run DOES match the current head (or whose run can't be
# resolved at all) means the failure is live — dispatch normally.
#
# Subcommand
# ----------
#
#   check --repo <owner/repo> --pr <M>
#     Fetches the PR's headRefOid + latest-per-name failing-check rollup,
#     then walks each failing check's `detailsUrl` to resolve the run's own
#     head SHA and compares it against the PR's current head. Prints exactly
#     one line to stdout:
#
#       stale=true head_sha=<sha>
#       stale=false head_sha=<sha> reason=<current-head|unresolvable-run-id|fetch-failed>
#
#     `stale=false` is the fail-safe default — a fetch failure, an
#     unparseable `detailsUrl`, or any failing check that DOES match the
#     current head all resolve to `stale=false` (never silently treat a
#     dispatch-worthy failure as safe to skip). Exit 0 always — this is a
#     read-only classification, not a mutation, so there's nothing to make
#     best-effort about; a `gh` failure still produces a printed line via
#     the fail-safe default above rather than a bare non-zero exit the
#     caller would have to special-case.
#
# Exit codes: 0 always (see above); 64 bad usage; 65 missing dependency
# (jq/gh).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${here}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  stale-failure-check.sh check --repo <owner/repo> --pr <M>
EOF
}

require_jq "stale-failure-check.sh"
GH="${GH:-gh}"
if ! command -v "$GH" >/dev/null 2>&1; then
  echo "stale-failure-check.sh: gh is required but not installed" >&2
  exit 65
fi

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  check)
    repo=""
    pr=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --pr) pr="${2:-}"; shift 2 ;;
        *) echo "stale-failure-check.sh check: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$repo" ] || [ -z "$pr" ]; then
      echo "stale-failure-check.sh check: --repo and --pr are required" >&2
      usage >&2
      exit 64
    fi

    # Latest-per-name projection (issue #333) — without it a stale FAILURE
    # superseded by a later SUCCESS would still count as "failing".
    rollup=$("$GH" pr view "$pr" --repo "$repo" \
      --json headRefOid,statusCheckRollup \
      --jq '{head: .headRefOid, failing: [
        .statusCheckRollup
        | group_by(.name)
        | map(sort_by(.completedAt // .startedAt // "") | last)
        | .[]
        | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
        | {name, detailsUrl}]}' 2>/dev/null)
    if [ -z "$rollup" ]; then
      echo "stale=false head_sha= reason=fetch-failed"
      exit 0
    fi

    head_sha=$(jq -r '.head' <<< "$rollup")
    stale=true
    reason="current-head"

    while IFS= read -r url; do
      [ -z "$url" ] && continue
      # Extract the numeric run id from .../runs/<id> — a single grep -oE
      # (no `| grep | head` chain): the pattern itself already anchors on
      # the /runs/ prefix, so the first (and only) match IS the run id.
      run_id_match=$(grep -oE '/runs/[0-9]+' <<< "$url" 2>/dev/null)
      run_id="${run_id_match##*/}"
      if [ -z "$run_id" ]; then
        stale=false
        reason="unresolvable-run-id"
        break
      fi
      run_sha=$("$GH" api "repos/${repo}/actions/runs/${run_id}" --jq '.head_sha' 2>/dev/null)
      if [ "$run_sha" = "$head_sha" ]; then
        stale=false
        reason="current-head"
        break
      fi
    done < <(jq -r '.failing[].detailsUrl // empty' <<< "$rollup")

    echo "stale=${stale} head_sha=${head_sha} reason=${reason}"
    exit 0
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "stale-failure-check.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac

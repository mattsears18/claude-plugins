#!/usr/bin/env bash
# pre-dispatch-branch-reap.sh — the pre-dispatch head-branch reap
# (self-PID lock release) inlined in dispatch-rules.md §2d, extracted to a
# script per issue #1289 (the follow-up to #1277/#1288).
#
# *** LOAD-BEARING WORKTREE-LOCK-REAPING LOGIC — READ BEFORE EDITING ***
#
# This is exactly the block #1277's worker deliberately deferred rewriting
# under a rushed dispatch: "dedicated pass ... given the concurrency-safety
# history" (issues #368, #576, #771, #832, #1206, #1274). This extraction
# preserves the ORIGINAL block's control flow byte-for-byte in translation —
# every ordering decision, every guard, every classification branch is
# unchanged; only the shell SHAPE changed (loop + pipes -> a script the
# spec invokes as one plain command). Two hard prohibitions govern any
# future edit here (see `dont.md`):
#
#   - #832: `.in_flight` membership is authoritative liveness and MUST be
#     checked BEFORE classify-lock, not after. See the `in_flight_agent_ids`
#     snapshot below (taken once, before the loop starts) and the `case`
#     skip inside the loop (checked before `classify-lock` is ever called
#     for that worktree).
#   - #836: never infer liveness or reap-eligibility from a worktree's
#     branch name alone. The `$head_ref` match below only SELECTS which
#     worktree is a *candidate* for this reap (there is exactly one PR's
#     head branch we're trying to free) — the actual reap-safety decision
#     is still made by `classify-lock`, never by the branch-name match
#     itself.
#
# Why it's safe to reap (unchanged from the original block's rationale):
# the lock holds OUR ORCHESTRATOR's PID, so `classify-lock` short-circuits
# it to `self-ancestor` once SHIPYARD_ORCHESTRATOR_PID is declared. This
# dispatch site only ever fires against a PR already in `failed_prs` /
# `D_dirty` — i.e. its ORIGINATING worker has already returned and been
# reconciled at step A, so ANY worktree still holding `$head_ref` is
# logically done by definition. Every classification (no-lock / dead /
# self-ancestor / peer-alive / unknown) is therefore safe to force-reap
# here — `peer-alive` is specifically relabeled to `peer-alive-force` for
# audit-trail visibility (issue #771; the #576 gap this closes: force-reap
# closes the residual gap #576 left open when this site was "intentionally
# conservative" and deferred peer-alive unconditionally with no override —
# the exact failure #2598 repro hit).
#
# Subcommand
# ----------
#
#   reap --head-ref <branch> --session-id <session-id> [--phase <phase>]
#     Anchors cwd to a stable directory (issue #497 — before ANY
#     git-worktree-mutating call, so a harness cwd-leak into the very
#     worktree this reaps can't strand a later `git worktree prune`),
#     derives the primary checkout path (cwd-independent, #477 porcelain
#     idiom), exports SHIPYARD_ORCHESTRATOR_PID (#263), snapshots this
#     session's in-flight agent-ids (#832 — BEFORE the loop), walks
#     `agent-*` worktrees under the primary's `.git/worktrees` for the
#     FIRST one whose HEAD matches --head-ref, skips it if its agent-id is
#     in-flight (#832 — before classify-lock), classifies its lock,
#     relabels `peer-alive` -> `peer-alive-force`, reaps it via
#     `worktree-reap.sh reap` with `--phase <phase>` (default
#     `steady-state-pre-dispatch`), drops the local branch ref so the fresh
#     worker's `git switch <head>` recreates it cleanly, stops after the
#     first match (`break` — at most one worktree per head branch), then
#     runs `git worktree prune`.
#
#     Every mutating step is fire-and-forget (`2>/dev/null` and/or
#     `|| true`), matching the original block's posture — a filesystem race
#     (the worktree was already reaped by a concurrent path) must not abort
#     the caller's dispatch turn.
#
#     Prints exactly one line to stdout so the caller's SEPARATE, later
#     verify-the-reap-happened call (issue #1274 — a classifier denial of
#     THIS call kills the whole tool call before any code in it can run, so
#     the verify has to be a genuinely separate Bash call, and shell
#     variables don't survive across those — the caller substitutes these
#     literal values into that next call):
#
#       reaped=false
#     or
#       reaped=true worktree_path=<path> worktree_name=<name> classification=<local_classification> lock_pid=<pid-or-null>
#
# Exit codes: 0 always (fire-and-forget, matches the original block); 64 bad
# usage; 65 missing dependency (jq).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${here}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  pre-dispatch-branch-reap.sh reap --head-ref <branch> --session-id <session-id>
      [--phase <phase>]
EOF
}

require_jq "pre-dispatch-branch-reap.sh"

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  reap)
    head_ref=""
    session_id=""
    phase="steady-state-pre-dispatch"

    while [ $# -gt 0 ]; do
      case "$1" in
        --head-ref) head_ref="${2:-}"; shift 2 ;;
        --session-id) session_id="${2:-}"; shift 2 ;;
        --phase) phase="${2:-}"; shift 2 ;;
        *) echo "pre-dispatch-branch-reap.sh reap: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$head_ref" ] || [ -z "$session_id" ]; then
      echo "pre-dispatch-branch-reap.sh reap: --head-ref and --session-id are required" >&2
      usage >&2
      exit 64
    fi

    # Anchor cwd to a stable directory BEFORE the reap (issue #497) — a
    # harness cwd-leak into the very agent-* worktree this block later
    # `git worktree remove --force`s would otherwise strand the closing
    # `git worktree prune` with "fatal: Unable to read current working
    # directory". Derive the anchor cwd-independently via the #477
    # porcelain idiom (orchestrator worktree first, primary as fallback)
    # while cwd is still valid, then cd to it.
    STABLE_DIR=$(awk '/^worktree /{p=substr($0,10)} p ~ /\/\.claude\/worktrees\/orchestrator-/{print p; exit}' \
      <(git worktree list --porcelain 2>/dev/null))
    [ -z "$STABLE_DIR" ] && STABLE_DIR=$(awk '/^worktree /{print substr($0,10); exit}' \
      <(git worktree list --porcelain 2>/dev/null))
    cd "${STABLE_DIR:-/}" 2>/dev/null || cd /

    # Walk the primary's .git/worktrees (porcelain-derived, cwd-independent).
    PRIMARY_CHECKOUT=$(awk '/^worktree /{print substr($0,10); exit}' \
      <(git worktree list --porcelain 2>/dev/null))

    # Declare the orchestrator PID once so classify-lock short-circuits
    # self-locks to `self-ancestor` (issue #263) regardless of process-tree
    # shape.
    export SHIPYARD_ORCHESTRATOR_PID
    SHIPYARD_ORCHESTRATOR_PID=$("${here}/session-identity.sh" detect-orchestrator-pid)

    # In-flight guard (issue #832) — snapshot this session's currently
    # in-flight agent-ids BEFORE the loop below ever consults classify-lock.
    # In-flight membership is authoritative liveness; the lock file's
    # classification is only a fallback. Belt-and-braces here alongside the
    # $head_ref branch-match filter below (which already narrows this walk
    # to a PR whose originating worker has, per this dispatch site's own
    # precondition, already returned).
    in_flight_agent_ids=$("${here}/session-state.sh" read \
      --session-id "$session_id" --path .in_flight 2>/dev/null | jq -r '.[]?.agent_id // empty' 2>/dev/null)

    reaped=false
    worktree_path=""
    name=""
    local_classification=""
    lock_pid=""

    # while-read fed by process substitution, not `for x in $(find ...)`
    # (shellcheck SC2044 — word-splitting on find's output is fragile).
    # Process substitution keeps the loop in the main shell (unlike
    # `find ... | while read`), so `break` and every variable set inside
    # still take effect after the loop ends.
    while IFS= read -r wt_dir; do
      [ -d "$wt_dir" ] || continue
      branch_ref=$(sed 's|ref: refs/heads/||' "$wt_dir/HEAD" 2>/dev/null)
      [ "$branch_ref" = "$head_ref" ] || continue

      name=$(basename "$wt_dir")
      # In-flight guard (issue #832) — skip BEFORE classify-lock, not after.
      case $'\n'"$in_flight_agent_ids"$'\n' in
        *$'\n'"${name#agent-}"$'\n'*) continue ;;
      esac
      worktree_path=$(git worktree list | awk -v n="$name" '$0 ~ n {print $1; exit}')
      [ -z "$worktree_path" ] && continue

      classification=$("${here}/worktree-reap.sh" classify-lock "$wt_dir/locked")
      # Anchor on the literal `pid` keyword, not "first digit-run before a
      # close-paren" — the latter misparses a real `(pid <N> start <ctime>)`
      # lock as the ctime's trailing year (issue #1206). Same fix as
      # `worktree-reap.sh`'s own `extract_lock_pid` helper.
      lock_pid_match=$(grep -m1 -oE '\(pid[[:space:]]+[0-9]+' "$wt_dir/locked" 2>/dev/null)
      lock_pid="${lock_pid_match//[!0-9]/}"
      [ -z "$lock_pid" ] && lock_pid="null"

      # no-lock / dead / self-ancestor / peer-alive — all safe to reap here
      # (issue #771). Force-reaping closes the residual gap #576 left open.
      # Audit with classification "peer-alive-force" so the override stays
      # traceable in ~/.shipyard/reap-audit.jsonl.
      local_classification="$classification"
      [ "$classification" = "peer-alive" ] && local_classification="peer-alive-force"
      "${here}/worktree-reap.sh" reap \
        --action reaped \
        --worktree-path "$worktree_path" \
        --worktree-name "$name" \
        --session-id "$session_id" \
        --classification "$local_classification" \
        --lock-pid "$lock_pid" \
        --phase "$phase" 2>/dev/null || true

      # Drop the local branch ref so the fresh worker's `git switch <head>`
      # recreates it cleanly without the "already checked out" collision.
      git branch -D "$head_ref" 2>/dev/null || true
      reaped=true
      break   # at most one worktree per head branch
    done < <(find "${PRIMARY_CHECKOUT}/.git/worktrees" -maxdepth 1 -type d -name 'agent-*' 2>/dev/null)
    git worktree prune 2>/dev/null || true

    if [ "$reaped" = "true" ]; then
      echo "reaped=true worktree_path=${worktree_path} worktree_name=${name} classification=${local_classification} lock_pid=${lock_pid}"
    else
      echo "reaped=false"
    fi
    exit 0
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "pre-dispatch-branch-reap.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac

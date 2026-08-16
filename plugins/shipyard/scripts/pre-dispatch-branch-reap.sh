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
# --bypass-return-check threaded internally (issues #1237/#1274). The
# reconciled-return gate (`worktree-reap.sh` reap --action reaped on an
# `agent-*` worktree) refuses unless THIS --session-id's persisted state
# recorded the target agent's own return. This call site's target can be
# INHERITED from a prior session — `failed_prs` comes from an `--author @me`
# scan (setup/04-backlog-divert.md step 5), not from this session's own
# `session_prs`, and step 5.7's "inherited DIRTY PR" seeding is the spec's
# own precedent for the same cross-session-PR fact. An inherited PR's
# originating agent's `.returned_agent_ids` entry lives in a DIFFERENT
# session-state file this session can never read, so the gate would refuse
# forever with no way to satisfy it. Reproduced live (issue #1274): the
# gate wrote a "reap-refused"/"no-recorded-return" audit line while this
# script still reported reaped=true and the worktree stayed on disk —
# looking, from the caller's side, exactly like the "reap silently doesn't
# succeed" symptom #1274 investigates. Bypassing is safe: this call site's
# own precondition (a PR already exists in `failed_prs`) proves the
# worker's deliverable already landed on the remote, so nothing is lost by
# reaping the local leftover lock regardless of which session dispatched
# it.
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
#     `steady-state-pre-dispatch`). On a VERIFIED successful removal (see
#     #1407 below), drops the local branch ref so the fresh worker's
#     `git switch <head>` recreates it cleanly. Stops after the first match
#     (`break` — at most one worktree per head branch), then runs
#     `git worktree prune`.
#
#     Every mutating step is fire-and-forget (`2>/dev/null` and/or
#     `|| true`), matching the original block's posture — a filesystem race
#     (the worktree was already reaped by a concurrent path) must not abort
#     the caller's dispatch turn.
#
#     Issue #1407 (sibling of #1404) — the delegated `worktree-reap.sh reap
#     --action reaped` call's own exit status is NOT a trustworthy success
#     signal: its `reap_action()` (for the `reaped` action) `return`s 0
#     unconditionally regardless of whether the underlying removal actually
#     happened — it only varies which action string ("reaped" vs
#     "reaped-failed") lands in the AUDIT LOG (see #712) — and this caller's
#     own `2>/dev/null || true` additionally discards stderr and any
#     non-reap_action exit (e.g. the delegated process crashing before
#     reaching that branch at all). Before ever reporting success, this
#     script re-checks the filesystem itself: did `$worktree_path` actually
#     disappear? If it did not, this script records the failure via
#     `worktree-reap.sh reap --action reaped-failed` itself (the #1274
#     directly-invocable failure-log path) — so the audit trail is correct
#     even when the delegated call never wrote its own "reaped-failed"
#     line — and reports the distinct `reaped=failed` token below rather
#     than `reaped=true`. It also does NOT drop the local branch ref in this
#     case, since the worktree still holds it checked out.
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
#     or (#1407 — a genuine match was found but the delegated removal did
#     not actually take)
#       reaped=failed worktree_path=<path> worktree_name=<name> classification=<local_classification> lock_pid=<pid-or-null> reason=delegated-reap-did-not-remove-worktree
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
    reap_failed=false
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
      # --bypass-return-check (issue #1237/#1274): this call site's own
      # precondition (dispatch-rules.md §2d only fires against a PR already
      # present in `failed_prs`) proves a PR already exists on GitHub for
      # this worktree's branch — the originating worker's deliverable is
      # already safely on the remote. The `failed_prs` scan is an
      # `--author @me` query (setup/04-backlog-divert.md step 5), NOT scoped
      # to this session's own `session_prs` — step 5.7's own "inherited"
      # DIRTY-PR seeding is the spec's own acknowledgment that a PR (and
      # therefore the local worktree that opened it) can be inherited from a
      # PRIOR session. That prior session's `.returned_agent_ids` record
      # lives in a DIFFERENT session-state file this `--session-id` can
      # never read, so the reconciled-return gate would refuse forever on an
      # inherited PR's worktree with no way to satisfy it — reproduced live
      # (issue #1274): the gate wrote "reap-refused"/"no-recorded-return"
      # while this script still reported reaped=true and the worktree
      # stayed on disk. Bypassing here cannot lose the worker's own work
      # (it's already on the remote as the PR this call site requires to
      # exist); it only frees the local leftover lock.
      "${here}/worktree-reap.sh" reap \
        --action reaped \
        --worktree-path "$worktree_path" \
        --worktree-name "$name" \
        --session-id "$session_id" \
        --classification "$local_classification" \
        --lock-pid "$lock_pid" \
        --phase "$phase" \
        --bypass-return-check "pre-dispatch head-branch reap (#1237/#1274) — target's PR already exists on GitHub (dispatch-rules.md §2d precondition); may be inherited from a prior session whose .returned_agent_ids this session can't read" \
        2>/dev/null || true

      # Issue #1407 (sibling of #1404) — verify the delegated removal
      # actually happened before ever reporting success. The delegated
      # call's own exit status is not a trustworthy signal (see the header
      # comment above): re-check the filesystem itself.
      if [ -e "$worktree_path" ]; then
        # The worktree survived — whether because the removal failed
        # cleanly (worktree-reap.sh's own reap_action already logged
        # "reaped-failed" internally, per #712) or because the delegated
        # call crashed before ever reaching that branch (nothing logged at
        # all). Record the failure here too, via the #1274
        # directly-invocable failure-log action, so the audit trail is
        # correct in BOTH cases rather than depending on every caller to
        # notice and backfill it.
        "${here}/worktree-reap.sh" reap \
          --action reaped-failed \
          --worktree-path "$worktree_path" \
          --worktree-name "$name" \
          --session-id "$session_id" \
          --classification "$local_classification" \
          --reason "delegated-reap-did-not-remove-worktree" \
          --lock-pid "$lock_pid" \
          --phase "$phase" 2>/dev/null || true
        reap_failed=true
        break   # at most one worktree per head branch — nothing else to try
      fi

      # Drop the local branch ref so the fresh worker's `git switch <head>`
      # recreates it cleanly without the "already checked out" collision.
      # `-D` (force) rather than `-d` because the branch may have unmerged
      # commits relative to current local main — the canonical record is
      # on origin, not this branch. Only reached when the removal above was
      # actually verified (worktree_path no longer exists) — dropping the
      # branch ref while a still-present worktree holds it checked out
      # would be wrong (#1404/#1407).
      git branch -D "$head_ref" 2>/dev/null || true
      reaped=true
      break   # at most one worktree per head branch
    done < <(find "${PRIMARY_CHECKOUT}/.git/worktrees" -maxdepth 1 -type d -name 'agent-*' 2>/dev/null)
    git worktree prune 2>/dev/null || true

    if [ "$reaped" = "true" ]; then
      echo "reaped=true worktree_path=${worktree_path} worktree_name=${name} classification=${local_classification} lock_pid=${lock_pid}"
    elif [ "$reap_failed" = "true" ]; then
      echo "reaped=failed worktree_path=${worktree_path} worktree_name=${name} classification=${local_classification} lock_pid=${lock_pid} reason=delegated-reap-did-not-remove-worktree"
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

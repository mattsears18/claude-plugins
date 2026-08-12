#!/usr/bin/env bash
# drain-pre-dispatch-branch-reap.sh — drain.md's "Pre-dispatch head-branch
# reap (self-PID lock release)" (closes #370, #387, #832), extracted to a
# script per issue #1289 (the follow-up to #1277/#1288).
#
# *** LOAD-BEARING WORKTREE-LOCK-REAPING LOGIC — READ BEFORE EDITING ***
#
# This is the drain-phase sibling of `pre-dispatch-branch-reap.sh` (the
# steady-state dispatch-rules.md §2d version) — same family, same
# concurrency-safety history (#368/#576/#771/#832/#1206), but a MATERIALLY
# DIFFERENT reap policy, so it is intentionally its own script rather than
# a shared abstraction with that one:
#
#   - It ALSO handles the primary-checkout leak case (#387): before
#     scanning agent-* worktrees, check whether the PRIMARY checkout itself
#     is parked on the PR's head branch (a harness cwd-leak artifact) and
#     restore it to the default branch iff its tree is clean — NEVER reap
#     the primary; it's the user's checkout.
#   - Its peer-alive/unknown handling is CONDITIONAL on branch pattern,
#     not unconditional like dispatch-rules.md §2d's force-reap: a
#     `do-work/issue-*` branch means the originating issue-work worker has
#     already returned its terminal string (logically done, safe to
#     force-reap even on peer-alive/unknown) — but any OTHER branch pattern
#     (a live fix-checks or fix-rebase worker's own worktree) is NOT
#     force-reaped; a genuinely-live peer's lock must not be yanked, so
#     drain defers instead.
#
# Same two hard prohibitions as the steady-state sibling govern any future
# edit here (see `dont.md`):
#
#   - #832: `.in_flight` membership is authoritative liveness and MUST be
#     checked BEFORE classify-lock — the `in_flight_agent_ids` snapshot is
#     taken once, before the loop, and checked inside the loop before
#     `classify-lock` is ever called for that worktree.
#   - #836: never infer liveness or reap-eligibility from a worktree's
#     branch name ALONE. The `do-work/issue-*` branch-pattern check below
#     is used only to decide whether a peer-alive/unknown classification is
#     safe to override — it never substitutes for classify-lock itself,
#     and every OTHER classification (no-lock/dead/self-ancestor) still
#     reaps purely on classify-lock's own verdict, branch pattern aside.
#
# Subcommand
# ----------
#
#   reap --head-ref <branch> --repo <owner/repo> --session-id <session-id>
#     1. `cd`s to the current checkout's toplevel (unchanged from the
#        original inline block — this reap site does NOT use the #497
#        STABLE_DIR anchor dance the steady-state sibling scripts do;
#        preserved as-is, not "fixed", per this script's own preservation
#        mandate).
#     2. Exports SHIPYARD_ORCHESTRATOR_PID (#263).
#     3. Primary-checkout holder check (#387): if the PRIMARY checkout
#        (porcelain-derived, cwd-independent per #452) is itself parked on
#        --head-ref, restore it to the repo's default branch iff its tree
#        is clean; warn-and-skip (never auto-restore) if dirty.
#     4. In-flight guard snapshot (#832) — BEFORE the loop.
#     5. Walks `.git/worktrees/agent-*` for the first one whose HEAD
#        matches --head-ref (skipping in-flight agent-ids), classifies its
#        lock, and either force-reaps (no-lock/dead/self-ancestor always;
#        peer-alive/unknown ONLY when --head-ref matches `do-work/issue-*`)
#        or defers (peer-alive/unknown on any other branch pattern) —
#        exactly the branching the header above describes.
#     6. `git worktree prune`.
#
#     Every mutating step is fire-and-forget (`2>/dev/null` and/or
#     `|| true`), matching the original block's posture.
#
#     Prints `key=value` lines to stdout (the caller increments its own
#     session-local counters and logs from these — the script cannot touch
#     the orchestrator's session state itself):
#
#       primary_leak_restored=<true|false>
#       primary_leak_dirty_skip=<true|false>
#       reap_outcome=<none|reaped|deferred>
#       worktree_path=<path-or-empty>
#       worktree_name=<name-or-empty>
#       classification=<classification-or-empty>
#       lock_pid=<pid-or-empty>
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
  drain-pre-dispatch-branch-reap.sh reap --head-ref <branch> --repo <owner/repo>
      --session-id <session-id>
EOF
}

require_jq "drain-pre-dispatch-branch-reap.sh"
GH="${GH:-gh}"

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  reap)
    head_ref=""
    repo=""
    session_id=""

    while [ $# -gt 0 ]; do
      case "$1" in
        --head-ref) head_ref="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --session-id) session_id="${2:-}"; shift 2 ;;
        *) echo "drain-pre-dispatch-branch-reap.sh reap: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$head_ref" ] || [ -z "$repo" ] || [ -z "$session_id" ]; then
      echo "drain-pre-dispatch-branch-reap.sh reap: --head-ref, --repo, and --session-id are required" >&2
      usage >&2
      exit 64
    fi

    cd "$(git rev-parse --show-toplevel)" || exit 0

    # Declare the orchestrator PID once so classify-lock short-circuits
    # self-locks to `self-ancestor` (issue #263) regardless of process-tree
    # shape.
    export SHIPYARD_ORCHESTRATOR_PID
    SHIPYARD_ORCHESTRATOR_PID=$("${here}/session-identity.sh" detect-orchestrator-pid)

    primary_leak_restored=false
    primary_leak_dirty_skip=false

    # --- Primary-checkout holder (issue #387) -------------------------------
    # Derive PRIMARY_CHECKOUT independent of cwd (issue #452) — the harness
    # can leak the orchestrator's cwd into a dispatched agent-* worktree.
    # `git worktree list --porcelain`'s first `worktree ` entry is always
    # the primary, whatever the cwd. Fall back to the cwd-strip (covering
    # agent-* too) only if the porcelain read is empty.
    PRIMARY_CHECKOUT=$(awk '/^worktree /{print substr($0,10); exit}' <(git worktree list --porcelain 2>/dev/null))
    if [ -z "$PRIMARY_CHECKOUT" ]; then
      PRIMARY_CHECKOUT="$(git rev-parse --show-toplevel)"
      case "$PRIMARY_CHECKOUT" in
        */.claude/worktrees/orchestrator-*) PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/orchestrator-*}" ;;
        */.claude/worktrees/agent-*)        PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/agent-*}" ;;
      esac
    fi
    PRIMARY_BRANCH=$(git -C "$PRIMARY_CHECKOUT" symbolic-ref --short -q HEAD 2>/dev/null || echo "<detached>")
    if [ "$PRIMARY_BRANCH" = "$head_ref" ]; then
      DEFAULT_BRANCH=$("$GH" repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
      if [ -z "$(git -C "$PRIMARY_CHECKOUT" status --porcelain 2>/dev/null)" ]; then
        if git -C "$PRIMARY_CHECKOUT" checkout "$DEFAULT_BRANCH" 2>/dev/null; then
          git -C "$PRIMARY_CHECKOUT" pull --ff-only 2>/dev/null || true
        fi
        echo "[primary-leak] restored primary from $head_ref to $DEFAULT_BRANCH before fix-rebase dispatch (#387)"
        primary_leak_restored=true
      else
        echo "[primary-leak] WARNING: primary checkout holds head branch $head_ref AND has uncommitted changes; NOT auto-restoring (possible real edits). fix-rebase for this PR will bail until you restore manually: git -C \"$PRIMARY_CHECKOUT\" checkout $DEFAULT_BRANCH (#387)"
        primary_leak_dirty_skip=true
      fi
    fi
    # -------------------------------------------------------------------------

    # In-flight guard (issue #832) — snapshot this session's currently
    # in-flight agent-ids BEFORE the loop below ever consults classify-lock.
    # Drain can run concurrent fix-checks-only / fix-rebase workers against
    # OTHER PRs while this per-PR reap fires — in-flight membership is
    # authoritative liveness; the lock file's classification is only a
    # fallback for a worktree this session doesn't currently own.
    in_flight_agent_ids=$("${here}/session-state.sh" read \
      --session-id "$session_id" --path .in_flight 2>/dev/null | jq -r '.[]?.agent_id // empty' 2>/dev/null)

    reap_outcome="none"
    worktree_path=""
    name=""
    reported_classification=""
    lock_pid=""

    # while-read fed by process substitution, not `for x in $(find ...)`
    # (shellcheck SC2044 — word-splitting on find's output is fragile).
    # Process substitution keeps the loop in the main shell, so `break` and
    # every variable set inside still take effect after the loop ends.
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
      # lock as the ctime's trailing year (issue #1206).
      lock_pid_match=$(grep -m1 -oE '\(pid[[:space:]]+[0-9]+' "$wt_dir/locked" 2>/dev/null)
      lock_pid="${lock_pid_match//[!0-9]/}"
      [ -z "$lock_pid" ] && lock_pid="null"

      deferred=false
      if [ "$classification" = "peer-alive" ] || [ "$classification" = "unknown" ]; then
        # Check whether this is a completed issue-work worktree (i.e., the
        # branch follows the do-work/issue-<N> pattern). If so, the
        # originating worker has already returned its terminal string — the
        # worktree is logically done and the peer-alive PID is a transient
        # harness artifact. Force-reap it so the drain worker can claim the
        # branch (issue #576). For any other branch pattern (e.g., a live
        # fix-checks or fix-rebase worker), preserve the conservative defer.
        case "$branch_ref" in
          do-work/issue-*)
            : # completed issue-work worktree — fall through to force-reap
            ;;
          *)
            # A genuinely-live non-orchestrator PID holds the lock (or its
            # lock couldn't be parsed at all). Don't yank it. Defer; the
            # fresh worker will bail with `blocked rebase` and the PR is
            # surfaced in the summary.
            "${here}/worktree-reap.sh" reap \
              --action deferred \
              --worktree-path "$worktree_path" \
              --worktree-name "$name" \
              --session-id "$session_id" \
              --reason "$classification" \
              --lock-pid "$lock_pid" \
              --phase "drain-pre-dispatch" 2>/dev/null || true
            reap_outcome="deferred"
            reported_classification="$classification"
            deferred=true
            ;;
        esac
      fi
      [ "$deferred" = "true" ] && break

      # no-lock / dead / self-ancestor / peer-alive-force-drain /
      # unknown-force-drain (for completed issue-work worktrees) — safe to
      # reap.
      drain_classification="$classification"
      [ "$classification" = "peer-alive" ] && drain_classification="peer-alive-force-drain"
      [ "$classification" = "unknown" ] && drain_classification="unknown-force-drain"
      "${here}/worktree-reap.sh" reap \
        --action reaped \
        --worktree-path "$worktree_path" \
        --worktree-name "$name" \
        --session-id "$session_id" \
        --classification "$drain_classification" \
        --lock-pid "$lock_pid" \
        --phase "drain-pre-dispatch" 2>/dev/null || true

      # Drop the local branch ref so the fresh worker's `git switch <head>`
      # recreates it cleanly without the "already checked out" collision.
      git branch -D "$head_ref" 2>/dev/null || true
      reap_outcome="reaped"
      reported_classification="$drain_classification"
      break   # at most one worktree per head branch
    done < <(find .git/worktrees -maxdepth 1 -type d -name 'agent-*' 2>/dev/null)
    git worktree prune 2>/dev/null || true

    echo "primary_leak_restored=${primary_leak_restored}"
    echo "primary_leak_dirty_skip=${primary_leak_dirty_skip}"
    echo "reap_outcome=${reap_outcome}"
    echo "worktree_path=${worktree_path}"
    echo "worktree_name=${name}"
    echo "classification=${reported_classification}"
    echo "lock_pid=${lock_pid}"
    exit 0
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "drain-pre-dispatch-branch-reap.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac

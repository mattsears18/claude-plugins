#!/usr/bin/env bash
# session-identity.sh — orchestrator-PID / session-identity forensics.
#
# Background (issue #941): this is the deferred, optional split from #887
# (which shipped the mandatory scripts/lib/common.sh dedup in #940). These
# three subcommands — detect-orchestrator-pid, derive-session-id, and
# find-orphan-orchestrators — used to live inside worktree-reap.sh, but they
# have nothing to do with reaping: they answer "what is the orchestrator's
# PID" and "what session am I" questions, not "is this worktree safe to
# remove" ones. `derive-session-id` in particular sits on the cwd-leak hot
# path (steady-state.md's A.0 required preamble) and is called far more
# often, by far more call sites, than anything reap-related.
#
# worktree-reap.sh keeps its own reaping-scoped helpers (classify-lock,
# classify-all, reap-stale, reap-orphan-branches, reap-session-worktrees,
# reap, report-unreaped) — those still need the ancestor-walk primitives
# (self_ancestor_pids / is_self_ancestor / pid_alive / extract_lock_pid)
# for lock-PID liveness classification, which is a genuinely different
# question from "which PID is the orchestrator" — so those primitives stay
# put and are NOT duplicated here. This file's three subcommands are
# self-contained: none of them call into worktree-reap.sh's lock-liveness
# helpers, and worktree-reap.sh's classify-lock/classify-all do not call
# into this file. The two scripts are siblings, not layered on each other.
#
# This is a pure relocation, not a redesign — every function below is
# byte-for-byte identical to its former home in worktree-reap.sh (same
# argv parsing, same stdout/exit-code contracts, same env-var names). See
# each function's own comment for the issue that originally introduced it.
#
# Subcommands:
#
#   detect-orchestrator-pid [<comm-name>]
#     Walks the process-ancestor chain and prints the PID of the nearest
#     ancestor whose `comm` matches <comm-name> (default `claude`). Empty
#     stdout if no match. Used to bootstrap SHIPYARD_ORCHESTRATOR_PID for
#     worktree-reap.sh's classify-lock self-ancestor short-circuit.
#
#   derive-session-id --repo-root <path>
#     Issue #513 — recover THIS session's id from disk when the per-call
#     env var doesn't persist (each Bash tool call is hermetic — see
#     setup.md step 0.55). Reads `.shipyard-session-id` from the orchestrator
#     worktree under <repo-root>/.claude/worktrees/orchestrator-*.
#
#     The naive `git worktree list --porcelain | awk '...; exit'` derive
#     picked the FIRST orchestrator-* worktree in listing order, which is
#     the OLDEST orphan when prior crashed sessions left their
#     `orchestrator-<dead-id>` worktrees un-reaped. That misattributed every
#     `session-state.sh` write to a dead orphan's session file (same-repo, so
#     the --expected-repo guard did not catch it).
#
#     This subcommand instead selects the NEWEST `orchestrator-*` worktree by
#     directory mtime — the live session's worktree was just created in
#     setup.md step 0.5, so among coexisting orchestrator worktrees it is the
#     most recently created. Strictly better than first-by-listing-order: it
#     resolves to the live session even when orphans accumulate.
#
#     Stdout: the session id (contents of the chosen worktree's
#       `.shipyard-session-id`, trailing newline stripped). Empty stdout when
#       no orchestrator worktree exists or none carries a readable stash.
#     Exit codes:
#       0  a session id was printed, OR no candidate was found (empty stdout —
#          the caller decides what an empty result means)
#       64 bad usage (missing required flag, unknown flag)
#
#   find-orphan-orchestrators --repo-root <path> --current-session-id <id>
#     Issue #280 — companion to step 1.6's orphan session-file sweep, but
#     for the orchestrator worktrees themselves. If a prior /do-work
#     session crashed before reaching cleanup-summary.md step 6, its
#     `.claude/worktrees/orchestrator-<dead-session-id>` directory is
#     never reaped — step 1.6 only reaps session FILES, and setup.md
#     step 3b only reaps `agent-*` worktrees. The session file might also
#     be gone (its prior cleanup got far enough to flush + delete it,
#     just not far enough to reap its own worktree). Either way, the
#     worktree dir lingers indefinitely.
#
#     Issue #1232 — the id this subcommand tests for liveness is the
#     OCCUPANT of the candidate directory, read from
#     `<candidate>/.shipyard-session-id`, NOT the id embedded in the
#     directory NAME. A directory's name only records who created it; a
#     later session can be live inside it (EnterWorktree refuses to
#     create a second isolated worktree for an already-isolated session,
#     so a second /do-work in one already-isolated context must reuse the
#     existing worktree under a fresh session id — the name and the
#     occupant diverge for the rest of that session's life). Trusting the
#     name alone reaped a LIVE session's own cwd out from under it. This
#     mirrors the convention `derive-session-id` above already depends on
#     (#365/#513) — it never trusted the name either.
#
#     This subcommand emits one line per orphan orchestrator worktree
#     path, where "orphan" means:
#       (a) name matches `.claude/worktrees/orchestrator-*`, AND
#       (b) the id to test — the candidate's `.shipyard-session-id`
#           stash when it's present and readable, else (only when the
#           directory is otherwise empty — see the fail-closed rule
#           below) the id embedded in the directory name — is NOT the
#           current session id, AND
#       (c) the owning session (per that same id) is INACTIVE — either
#           the session file is missing from
#           $SHIPYARD_HOME/sessions/<id>.json, OR `session-state.sh
#           is-active` returns non-zero (PID dead, unparseable, or null).
#
#     Fail-closed on ambiguity (#1232): when the stash is missing,
#     unreadable, or empty AND the directory contains anything else, the
#     candidate is skipped outright — never emitted — rather than falling
#     back to the (possibly-stale) name-embedded id. This mirrors the
#     fail-closed `unknown` verdict #1206 gave `classify-lock`: a missed
#     reap only costs disk; a wrong reap destroys a running session's
#     uncommitted work. The name-embedded-id fallback only fires for a
#     candidate that is ALSO genuinely empty (no stash and nothing else
#     in it) — a degenerate case with nothing to lose either way.
#
#     The caller is responsible for the actual `git worktree remove
#     --force` + audit-log write. This helper just enumerates candidates
#     so the discovery logic is testable in isolation.
#
#     Env vars:
#       SHIPYARD_HOME — override the session-file lookup root (defaults
#                       to `$HOME/.shipyard`). Mirrors session-state.sh.
#     Exit codes:
#       0  enumeration succeeded (output may be empty)
#       64 bad usage (missing required flag)
#
# Pure bash + `ps` + `git`. No jq, no python — same cheap-to-call posture as
# worktree-reap.sh, since detect-orchestrator-pid in particular gets called
# once per phase transition (setup, steady-state, cleanup-summary, drain).

set -u

# --------------------------------------------------------------------------
# Shared helpers (shipyard_home) — issue #887.
# --------------------------------------------------------------------------
# shellcheck source=lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  session-identity.sh detect-orchestrator-pid [<comm-name>]
  session-identity.sh derive-session-id --repo-root <path>
  session-identity.sh find-orphan-orchestrators --repo-root <path> \
                                                --current-session-id <id>

detect-orchestrator-pid — Walks the process-ancestor chain and prints the
                          PID of the nearest ancestor whose `comm` matches
                          <comm-name> (default `claude`). Empty stdout if
                          no match. Useful for bootstrapping
                          SHIPYARD_ORCHESTRATOR_PID in shell snippets that
                          want worktree-reap.sh's classify-lock to
                          short-circuit reliably.

derive-session-id       — Issue #513. Prints THIS session's id by reading
                          `.shipyard-session-id` from the NEWEST-by-mtime
                          `orchestrator-*` worktree under
                          <repo-root>/.claude/worktrees. Picking newest (not
                          first-in-listing-order) resolves to the live session
                          even when prior crashed sessions left orphan
                          orchestrator worktrees behind. Empty stdout (exit 0)
                          when no candidate carries a readable stash.

find-orphan-orchestrators — Emits one path per line for each orphan
                          orchestrator worktree under
                          <repo-root>/.claude/worktrees/orchestrator-*
                          whose OCCUPANT — the id in its
                          `.shipyard-session-id` stash, not the
                          directory name (#1232) — is NOT
                          <current-session-id> AND whose owning session
                          is inactive (session file missing OR PID dead).
                          Falls back to the name-embedded id only when
                          the stash is missing/unreadable AND the
                          directory is otherwise empty; any other
                          unreadable-stash candidate is skipped (fail
                          closed, never emitted). Empty stdout when there
                          are no orphans.

Env vars:
  SHIPYARD_HOME              Override session-file lookup root for
                             find-orphan-orchestrators (defaults to
                             $HOME/.shipyard).

Exit codes:
  0  PID printed or empty (detect-orchestrator-pid) / session id printed or
     empty (derive-session-id) / enumeration succeeded, output may be empty
     (find-orphan-orchestrators)
  64 usage error (missing required flag, unknown flag, unexpected positional)
EOF
}

# Walk our own ancestor chain looking for a process whose comm matches the
# Claude Code orchestrator (default: literal `claude`). Emits the matched PID
# on stdout (empty if no match found). Used by the `detect-orchestrator-pid`
# subcommand to bootstrap the `SHIPYARD_ORCHESTRATOR_PID` short-circuit for
# worktree-reap.sh's classify-lock, when callers haven't set it explicitly.
#
# The match is intentionally narrow: if the Claude Code binary is renamed,
# this detection returns empty and callers fall back to classify-lock's own
# ancestor-walk semantics. False matches (a foreign `claude` process in the
# chain) are extremely unlikely — process names in the ancestor chain of a
# bash spawned by Claude Code are bash, sh, claude, login, etc. The risk
# threshold is low because a detected PID only short-circuits to
# `self-ancestor` when it EXACTLY matches the lock PID; a wrong detection
# only matters if it coincidentally matches a foreign live PID (negligible
# probability).
detect_orchestrator_pid() {
  local match_comm="${1:-claude}"
  local pid=$$
  local guard=0
  local comm
  while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ]; do
    guard=$((guard + 1))
    [ "$guard" -gt 64 ] && return 0
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    # `comm` on macOS returns the full executable path; basename it for the match.
    comm=$(basename "$comm" 2>/dev/null)
    if [ "$comm" = "$match_comm" ]; then
      echo "$pid"
      return 0
    fi
    local parent
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$parent" ] && return 0
    [ "$parent" = "$pid" ] && return 0
    pid="$parent"
  done
}

derive_session_id() {
  local repo_root=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root)
        repo_root="${2:-}"
        shift 2
        ;;
      --repo-root=*)
        repo_root="${1#--repo-root=}"
        shift
        ;;
      --)
        shift
        ;;
      -*)
        echo "derive-session-id: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "derive-session-id: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$repo_root" ]; then
    echo "derive-session-id: --repo-root is required" >&2
    return 64
  fi

  local orch_root="$repo_root/.claude/worktrees"
  # No worktrees dir at all → nothing to derive. Empty stdout, exit 0.
  [ -d "$orch_root" ] || return 0

  # Walk every orchestrator-* worktree and keep the one with the newest
  # directory mtime that also carries a readable, non-empty stash. We require
  # the stash to be present so a candidate without one (a half-set-up or
  # already-cleaned worktree) never wins over an older worktree that DOES
  # have the id — correctness beats recency when recency has no id to offer.
  local entry newest_mtime="" newest_id="" mtime stash id
  for entry in "$orch_root"/orchestrator-*; do
    # No-glob-match fallthrough: bash leaves the literal pattern when nothing
    # matches. Guard with `-d` so we silently skip.
    [ -d "$entry" ] || continue

    stash="$entry/.shipyard-session-id"
    [ -f "$stash" ] || continue
    # Strip surrounding whitespace/newlines from the stash contents.
    id="$(tr -d '[:space:]' < "$stash" 2>/dev/null)"
    [ -n "$id" ] || continue

    # Portable mtime: GNU `stat -c %Y` and BSD/macOS `stat -f %m` differ, so
    # try both. Fall back to 0 (oldest) if neither works, so a stat-less
    # platform still picks *a* candidate deterministically (the last one
    # scanned among those tied at 0).
    mtime="$(stat -c %Y "$entry" 2>/dev/null || stat -f %m "$entry" 2>/dev/null || echo 0)"

    if [ -z "$newest_mtime" ] || [ "$mtime" -ge "$newest_mtime" ] 2>/dev/null; then
      newest_mtime="$mtime"
      newest_id="$id"
    fi
  done

  [ -n "$newest_id" ] && printf '%s\n' "$newest_id"
  return 0
}

# Issue #280 — discover orphan orchestrator worktrees from prior crashed
# sessions. Companion to setup.md step 1.6 (which reaps orphan session
# FILES) and step 3b (which reaps `agent-*` worktrees). Neither covers
# the `.claude/worktrees/orchestrator-<dead-session-id>` case.
#
# An orphan, for this helper's purposes, is a worktree directory whose
# basename matches `orchestrator-*` AND whose OCCUPANT id is NOT the
# current session AND whose owning session is inactive (file missing OR
# PID dead). The "or" branch matters: a prior session that crashed AFTER
# session-state cleanup but BEFORE worktree reap (step 7 → step 6
# reordering in cleanup-summary.md) leaves no session file behind, but
# the worktree dir still exists.
#
# Issue #1232 — "occupant id" means the candidate's own
# `.shipyard-session-id` stash, read fresh on every call, NOT the id
# embedded in its directory name. `EnterWorktree` refuses to create a
# second isolated worktree for an already-isolated session, so a second
# /do-work in one already-isolated Claude session reuses the existing
# `orchestrator-<old-id>` directory under a brand-new session id — from
# that moment the name and the live occupant are permanently out of
# sync. Trusting the name alone made this helper classify a LIVE
# session's own cwd as reap-eligible (verified repro: the sweep returned
# a running orchestrator's worktree while that session was still inside
# it). `derive-session-id` above never made this mistake — it has always
# read the stash exclusively (#365/#513); this subcommand now does too.
# When the stash is missing/unreadable/empty, fall back to the
# name-embedded id ONLY if the directory has nothing else in it either
# (a genuinely empty candidate has nothing to lose from the pre-#1232
# behavior); otherwise fail closed and skip the candidate rather than
# guess — a missed reap costs disk, a wrong reap costs a running
# session's uncommitted work (same posture as #1206's `unknown`
# verdict for `classify-lock`).
#
# We emit paths instead of reaping in-place so:
#   1. The caller controls the audit-log shape (the spec wants
#      action: "reaped-orphan-orchestrator" with phase: "setup-3b-orch").
#   2. The discovery logic is independently testable.
#   3. A dry-run mode comes for free — the caller can choose to log
#      candidates without acting on them.
#
# Output: one absolute path per line, no surrounding quoting. Paths
# always exist at emit time (we filter against `-d` before printing).
# Empty stdout when there are no orphans.
find_orphan_orchestrators() {
  local repo_root=""
  local current_session_id=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root)
        repo_root="${2:-}"
        shift 2
        ;;
      --repo-root=*)
        repo_root="${1#--repo-root=}"
        shift
        ;;
      --current-session-id)
        current_session_id="${2:-}"
        shift 2
        ;;
      --current-session-id=*)
        current_session_id="${1#--current-session-id=}"
        shift
        ;;
      --)
        shift
        ;;
      -*)
        echo "find-orphan-orchestrators: unknown flag: $1" >&2
        return 64
        ;;
      *)
        echo "find-orphan-orchestrators: unexpected positional arg: $1" >&2
        return 64
        ;;
    esac
  done

  if [ -z "$repo_root" ]; then
    echo "find-orphan-orchestrators: --repo-root is required" >&2
    return 64
  fi
  if [ -z "$current_session_id" ]; then
    echo "find-orphan-orchestrators: --current-session-id is required" >&2
    return 64
  fi

  local orch_root="$repo_root/.claude/worktrees"
  # No worktrees dir at all → no orphans. Exit cleanly with empty output
  # rather than erroring; a brand-new repo or one that's never run
  # /do-work has nothing to reap.
  [ -d "$orch_root" ] || return 0

  local shipyard_home
  shipyard_home=$(shipyard_home)
  local sessions_dir="$shipyard_home/sessions"

  # Resolve the helper script path so we can call `session-state.sh
  # is-active` against each candidate. This script lives alongside it.
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local session_state_sh="$self_dir/session-state.sh"

  local entry name name_embedded_id session_id session_file stash stash_id
  for entry in "$orch_root"/orchestrator-*; do
    # No-glob-match fallthrough: bash leaves the literal pattern when
    # nothing matches. Guard with `-d` so we silently skip.
    [ -d "$entry" ] || continue

    name=$(basename "$entry")
    # Strip the `orchestrator-` prefix to recover the NAME-embedded id —
    # who CREATED this worktree, not necessarily who's in it now.
    name_embedded_id="${name#orchestrator-}"

    # Issue #1232 — read the OCCUPANT, not the label. Prefer the
    # candidate's own `.shipyard-session-id` stash (the same convention
    # derive-session-id already trusts exclusively) over the
    # name-embedded id for BOTH the current-session exclusion below and
    # the liveness check that follows.
    stash="$entry/.shipyard-session-id"
    stash_id=""
    if [ -f "$stash" ] && [ -r "$stash" ]; then
      stash_id="$(tr -d '[:space:]' < "$stash" 2>/dev/null)"
    fi

    if [ -n "$stash_id" ]; then
      session_id="$stash_id"
    else
      # No readable/non-empty stash. Fail closed on ambiguity: only fall
      # back to the (possibly stale) name-embedded id when the directory
      # is otherwise completely empty — a candidate that never got a
      # stash written AND holds no other content has nothing to lose
      # either way. Any other non-empty candidate without a readable
      # stash is left alone rather than guessed at (#1232) — a missed
      # reap costs disk, a wrong reap costs a running session's
      # uncommitted work.
      if [ -n "$(ls -A "$entry" 2>/dev/null)" ]; then
        continue
      fi
      session_id="$name_embedded_id"
    fi

    # Skip our own worktree — never reap the running session out from
    # under itself. Compares against the OCCUPANT id resolved above, not
    # the raw directory name.
    [ "$session_id" = "$current_session_id" ] && continue

    session_file="$sessions_dir/$session_id.json"

    # Inactive ≡ (file missing) OR (file present AND is-active exits non-zero).
    # File-missing is the common case for the bug report (#280): the
    # prior session's step 7→8 cleanup ran before its step 6 worktree
    # reap, so its session file is gone but its worktree lingers.
    if [ ! -f "$session_file" ]; then
      printf '%s\n' "$entry"
      continue
    fi

    # File present — defer to session-state.sh is-active for the PID
    # liveness check. If is-active is unavailable (script missing,
    # somehow), fall back to "present file means active" — the
    # conservative choice that preserves a still-running peer.
    if [ ! -x "$session_state_sh" ] && [ ! -f "$session_state_sh" ]; then
      continue
    fi
    if bash "$session_state_sh" is-active --session-id "$session_id" 2>/dev/null; then
      # Owning process is alive — skip.
      continue
    fi
    # File present but PID dead/unparseable → orphan.
    printf '%s\n' "$entry"
  done

  return 0
}

main() {
  local sub="${1:-}"
  case "$sub" in
    detect-orchestrator-pid)
      # Emit the PID of the nearest ancestor whose `comm` is `claude` (or
      # the override passed as the first arg). Empty stdout on no match.
      # Exit 0 whether or not a match was found — the caller decides what
      # to do with an empty result.
      shift
      detect_orchestrator_pid "${1:-claude}"
      ;;
    derive-session-id)
      # Issue #513 — recover THIS session's id from the newest-by-mtime
      # orchestrator-* worktree's `.shipyard-session-id` stash, so the
      # derive resolves to the live session rather than the oldest orphan.
      # See the derive_session_id function's docstring for the algorithm.
      shift
      derive_session_id "$@"
      ;;
    find-orphan-orchestrators)
      # Issue #280 — enumerate orphan `orchestrator-*` worktrees from
      # prior crashed sessions. See the find_orphan_orchestrators
      # function's docstring for the orphan definition.
      shift
      find_orphan_orchestrators "$@"
      ;;
    -h|--help|help|"")
      usage
      [ -z "$sub" ] && return 64
      return 0
      ;;
    *)
      echo "session-identity.sh: unknown subcommand: $sub" >&2
      usage
      return 64
      ;;
  esac
}

main "$@"

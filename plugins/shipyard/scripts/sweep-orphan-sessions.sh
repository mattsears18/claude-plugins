#!/usr/bin/env bash
# sweep-orphan-sessions.sh — reap stale session-state JSON files under
# $SHIPYARD_HOME/sessions/ left behind by a crashed or abandoned prior
# /shipyard:do-work orchestrator session.
#
# Extracted from do-work/setup's step 1.6 inline `find | while read` loop
# (issue #1182). That loop is a multi-statement compound shape — a piped
# `find` feeding a `while read` subshell that calls two other scripts per
# iteration — living inside step 0.7's much larger `(...) &` background
# cleanup group. Auto Mode's classifier can refuse that whole group as ONE
# compound Bash call (see commands/do-work/setup/00b-parallelization-cache.md's
# "Classifier-denial fallback" section), and even short of an outright
# refusal, the inline loop has no test coverage of its own. Extracting it
# into its own script mirrors the sibling extraction sweep-orphan-tmp.sh
# already did for atomic-write .tmp leftovers (issue #858) — same
# age-floor-plus-liveness safety shape, same reason (a single, plain,
# testable script call instead of an inlined compound shape). It also
# means the step-0.7 background group's denial-recovery path can retry
# just this sweep as one plain call without needing the whole multi-step
# group to succeed atomically.
#
# Safety — the load-bearing property, not a convenience (issue #253). A
# session file only qualifies for reap once it's BOTH older than the
# stale floor (default 30 minutes) AND its owning process is confirmed
# dead via session-state.sh's own `is-active` (PID-liveness) check. Both
# gates must fail before a reap — protects against reaping a peer
# orchestrator that's gone quiet for a long drain or CI watch but is
# still alive and will write through again.
#
# Subcommands:
#
#   sweep --shipyard-home <dir> --current-session-id <id>
#         [--reaper-session-id <id>] [--stale-min <N>] [--dry-run]
#     Sweeps $SHIPYARD_HOME/sessions/*.json older than --stale-min minutes
#     (default 30, overridable via SHIPYARD_SESSION_SWEEP_STALE_MIN) whose
#     session id differs from --current-session-id and whose
#     session-state.sh `is-active` check reports dead. For each reap
#     candidate: best-effort `cost-history.sh flush` for that session,
#     then `session-state.sh cleanup --reap-audit` (audit-stamped with
#     --reaper-session-id, defaulting to --current-session-id when
#     unset). Stdout: one `reaped: <id> (age=<mins>m)` or
#     `reaped (dry-run): ...` line per session reaped, followed by
#     exactly one summary line: `summary: reaped=<R> skipped=<S>`. Skip
#     reasons are logged to stderr as `skip: <id> (<why>)`.
#     Exit codes:
#       0  sweep completed (even if nothing was reaped — always emits at
#          least the summary line)
#       64 bad usage (missing --shipyard-home / --current-session-id,
#          malformed --stale-min)
set -u

# Sibling scripts are resolved via BASH_SOURCE[0], not $CLAUDE_PLUGIN_ROOT —
# same convention every script under plugins/shipyard/scripts/*.sh follows
# (see commands/do-work/setup/00-config-worktree.md's "Defense in depth"
# note), so this script works regardless of how its own caller resolved
# CLAUDE_PLUGIN_ROOT.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_STATE_SH="$here/session-state.sh"
COST_HISTORY_SH="$here/cost-history.sh"

STALE_MIN_DEFAULT="${SHIPYARD_SESSION_SWEEP_STALE_MIN:-30}"

usage() {
  cat <<'EOF'
Usage: sweep-orphan-sessions.sh sweep --shipyard-home <dir> --current-session-id <id> [--reaper-session-id <id>] [--stale-min <N>] [--dry-run]
EOF
}

# Portable directory/file-mtime-in-seconds (epoch). GNU first, BSD/macOS
# fallback — same order as sweep-orphan-tmp.sh's _mtime_epoch, for the
# same cross-dialect reason.
_mtime_epoch() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

_age_minutes() {
  local m now
  m=$(_mtime_epoch "$1")
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  echo $(( (now - m) / 60 ))
}

sweep() {
  local shipyard_home="" current_session_id="" reaper_session_id="" \
        stale_min="$STALE_MIN_DEFAULT" dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shipyard-home) shipyard_home="${2:-}"; shift 2 ;;
      --current-session-id) current_session_id="${2:-}"; shift 2 ;;
      --reaper-session-id) reaper_session_id="${2:-}"; shift 2 ;;
      --stale-min) stale_min="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) echo "sweep: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done

  if [[ -z "$shipyard_home" ]]; then
    echo "sweep: --shipyard-home is required" >&2
    usage
    return 64
  fi
  if [[ -z "$current_session_id" ]]; then
    echo "sweep: --current-session-id is required" >&2
    usage
    return 64
  fi
  if [[ ! "$stale_min" =~ ^[0-9]+$ ]]; then
    echo "sweep: --stale-min must be a non-negative integer, got: $stale_min" >&2
    return 64
  fi
  [[ -z "$reaper_session_id" ]] && reaper_session_id="$current_session_id"

  # session-state.sh / cost-history.sh both resolve their own working
  # directory from $SHIPYARD_HOME (default $HOME/.shipyard) rather than
  # from a flag — export it so the sibling calls below operate against
  # the SAME directory --shipyard-home named, not whatever $SHIPYARD_HOME
  # happened to be in the caller's environment.
  export SHIPYARD_HOME="$shipyard_home"

  local sessions_dir="$shipyard_home/sessions"
  local reaped=0 skipped=0

  if [[ ! -d "$sessions_dir" ]]; then
    echo "summary: reaped=$reaped skipped=$skipped"
    return 0
  fi

  local orphan
  while IFS= read -r orphan; do
    [[ -z "$orphan" ]] && continue
    local orphan_id age
    orphan_id=$(basename "$orphan" .json)

    if [[ "$orphan_id" == "$current_session_id" ]]; then
      continue
    fi

    # PID-liveness gate: if the orchestrator that owns this file is still
    # alive, skip the reap regardless of mtime. `is-active` exits 0 when
    # the file's .pid is alive (per kill -0); exit 1 on missing file,
    # missing/null pid, or dead pid. A missing/non-executable
    # session-state.sh is treated as "can't confirm dead" — err toward
    # skipping rather than reaping on an unverifiable liveness check.
    if [[ -f "$SESSION_STATE_SH" ]]; then
      if "$SESSION_STATE_SH" is-active --session-id "$orphan_id" 2>/dev/null; then
        echo "skip: $orphan_id (owning process still alive)" >&2
        skipped=$((skipped+1))
        continue
      fi
    else
      echo "skip: $orphan_id (session-state.sh not found — cannot confirm liveness)" >&2
      skipped=$((skipped+1))
      continue
    fi

    age=$(_age_minutes "$orphan") || age="?"

    if [[ "$dry_run" -eq 1 ]]; then
      echo "reaped (dry-run): $orphan_id (age=${age}m)"
    else
      # --reap-audit (issue #281) writes one JSONL line to
      # ~/.shipyard/reap-audit.jsonl capturing the reaped session's
      # pid / repo / tokens / mtime, plus the reaper's session id and
      # pid — best-effort, never lets a reap-audit failure block the
      # reap itself.
      if [[ -x "$COST_HISTORY_SH" ]]; then
        "$COST_HISTORY_SH" flush --session-id "$orphan_id" 2>/dev/null || true
      fi
      if [[ -x "$SESSION_STATE_SH" ]]; then
        "$SESSION_STATE_SH" cleanup --session-id "$orphan_id" \
          --reap-audit \
          --reaper-session-id "$reaper_session_id" \
          --reason "orphan-sweep-step-1.6" \
          --phase "setup-1.6" 2>/dev/null || true
      fi
      echo "reaped: $orphan_id (age=${age}m)"
    fi
    reaped=$((reaped+1))
  done < <(find "$sessions_dir" -maxdepth 1 -type f -name '*.json' -mmin "+$stale_min" 2>/dev/null)

  echo "summary: reaped=$reaped skipped=$skipped"
  return 0
}

main() {
  local sub="${1:-}"
  case "$sub" in
    sweep)
      shift
      sweep "$@"
      ;;
    -h|--help|help|"")
      usage
      [ -z "$sub" ] && return 64
      return 0
      ;;
    *)
      echo "sweep-orphan-sessions.sh: unknown subcommand: $sub" >&2
      usage
      return 64
      ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# sweep-orphan-tmp.sh — reap stale atomic-write .tmp leftovers under
# $SHIPYARD_HOME that no other code path ever sweeps automatically.
#
# Background (issue #858). Every atomic-write helper in this repo writes
# to a sibling tmp file, then renames it into place:
#   - session-state.sh's atomic_write() writes "<target>.tmp.$$" for
#     sessions/<id>.json (session-state.sh:353-389).
#   - flake-registry.sh's prune rewrite writes "<path>.tmp.$$" for
#     flake-registry.jsonl (flake-registry.sh:450).
#   - cost-history.sh's reconcile-rewrite path writes
#     mktemp "${session_target}.XXXXXX" (and a sibling ".err.XXXXXX") for
#     cost-history.jsonl (cost-history.sh:794-802).
#
# Each of those already cleans up its OWN tmp file on every code path it
# controls — an EXIT trap for the two "*.tmp.$$" writers, and an explicit
# `rm -f` on cost-history.sh's jq-failure abort branch (issue #901). But a
# hard kill (SIGKILL, an auto-mode permission denial, an OOM) between the
# tmp-file write and that cleanup leaves the tmp file on disk with nothing
# that will ever rename it into place or remove it:
#   - session-state.sh's OWN sweep (`cleanup --session-id <id>`, line
#     ~1544) only fires for a KNOWN session id — a crash mid-`init` (before
#     any .json ever landed) leaves a .tmp.<pid> file with no session id
#     to hand it.
#   - the do-work orchestrator's step-1.6 orphan sweep discovers stale
#     sessions by globbing "*.json" — a bare ".tmp.<pid>" sibling never
#     matches that glob.
#   - cost-history.sh and flake-registry.sh have no sweep for their own
#     tmp leftovers at all, under any circumstance.
# This script is the missing sweep for all three.
#
# Safety — the load-bearing property, not a convenience. A .tmp file can
# be a LIVE in-progress atomic write by another concurrently-running
# /do-work session, not an orphan. Every category below is gated on BOTH:
#   1. An age floor (default 30 minutes; --stale-min / SHIPYARD_TMP_SWEEP_
#      STALE_MIN override) — mirrors the existing step-1.6 orphan-session
#      sweep's race-safety margin: a single atomic_write / reconcile-
#      rewrite call completes in well under a second, so anything older
#      than the floor was abandoned mid-write, not merely slow.
#   2. A liveness check specific to the category:
#      - sessions/*.json.tmp.<pid> and flake-registry.jsonl.tmp.<pid>
#        encode the writer's pid directly in the filename (the "$$"
#        atomic_write uses) — `kill -0 <pid>` gives a precise, per-file
#        liveness signal on top of the age floor, the same "age floor AND
#        liveness" shape issue #253 established for the *.json orphan
#        sweep and issue #755 established for worktree-lock reaping.
#      - cost-history.jsonl's mktemp-suffixed tmp files carry no pid in
#        their name (mktemp's XXXXXX is random, not pid-derived), so no
#        per-file liveness check is possible. Instead: while
#        cost-history.jsonl.lock (the mkdir-based flush lock cost-
#        history.sh acquires around its whole reconcile-rewrite critical
#        section, cost-history.sh:283-322) exists AND is fresher than its
#        own staleness floor, the ENTIRE cost-history category is skipped
#        for this pass — a flush may be actively mid-write. We never
#        sweep an active lock or race its critical section.
#
# Every reap is LOGGED, not silent — a .tmp left behind by cost-history.
# sh's #901 deliberate abort-on-jq-failure path is evidence of a real
# upstream failure, not garbage, and deserves a visible trace (consistent
# with the #871-#877 silent-failure-path sweep). One line per reaped file
# on stdout, plus a final summary line. --dry-run reports without removing
# anything.
#
# Deliberately NOT swept: reap-audit.jsonl and autoreport-failures.jsonl.
# Both are plain `>>` appends (session-state.sh:1536,
# report-plugin-error.sh:346) with no tmp-file step, so they have no
# atomic-write leftover to reap.
#
# Subcommands:
#
#   sweep --shipyard-home <dir> [--stale-min <N>] [--dry-run]
#     Sweeps all three categories under <dir> in one pass. Stdout: one
#     `reaped: <path> (age=<mins>m category=<cat> ...)` or
#     `reaped (dry-run): ...` line per file removed (or that would be
#     removed under --dry-run), followed by exactly one summary line:
#     `summary: reaped=<R> skipped=<S>`. Skip reasons (not-stale-enough,
#     pid-alive, lock-held) are logged to stderr as `skip: <path> (<why>)`.
#     Exit codes:
#       0  sweep completed (even if nothing was reaped — always emits at
#          least the summary line)
#       64 bad usage (missing --shipyard-home, malformed --stale-min)
set -u

STALE_MIN_DEFAULT="${SHIPYARD_TMP_SWEEP_STALE_MIN:-30}"
# Mirrors cost-history.sh's own FLUSH_LOCK_STALE_SECONDS default (30s) —
# a lock dir at least that fresh means a flush may genuinely be
# in-progress; older than that, cost-history.sh itself would steal it as
# a crashed owner's abandoned lock, so we treat it the same way here.
LOCK_STALE_SECONDS="${SHIPYARD_FLUSH_LOCK_STALE_SECONDS:-30}"

usage() {
  cat <<'EOF'
Usage: sweep-orphan-tmp.sh sweep --shipyard-home <dir> [--stale-min <N>] [--dry-run]
EOF
}

# Portable directory/file-mtime-in-seconds (epoch). GNU first, BSD/macOS
# fallback — see cost-history.sh's _dir_mtime_epoch for why this order
# (not the reverse) is the only safe one across both stat dialects.
_mtime_epoch() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Age of $1 in whole minutes. Empty stdout + non-zero exit if the mtime
# can't be read at all (file vanished between find and stat, etc.).
_age_minutes() {
  local m now
  m=$(_mtime_epoch "$1")
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  echo $(( (now - m) / 60 ))
}

# Reap $1 if it's older than $3 minutes AND (no pid suffix, or the
# suffixed pid is dead). Category label $2 is cosmetic (log output only).
# $4 is the dry-run flag (1/0). Prints one log line either way.
# Returns: 0 reaped (or would be, under --dry-run), 1 skipped.
_consider_pid_suffixed() {
  local f="$1" category="$2" stale_min="$3" dry_run="$4"
  local age
  age=$(_age_minutes "$f") || { echo "skip: $f (could not read mtime)" >&2; return 1; }
  if (( age < stale_min )); then
    echo "skip: $f (age=${age}m, below ${stale_min}m floor — may be in progress)" >&2
    return 1
  fi
  # Filenames are <target-basename>.tmp.<pid>; target-basename can itself
  # contain dots, so anchor on the LAST '.tmp.' occurrence.
  local pid="${f##*.tmp.}"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "skip: $f (age=${age}m but writer pid $pid is still alive — in-progress write)" >&2
    return 1
  fi
  if [[ "$dry_run" -eq 1 ]]; then
    echo "reaped (dry-run): $f (age=${age}m category=$category pid=${pid:-unknown})"
  else
    rm -f "$f" 2>/dev/null
    echo "reaped: $f (age=${age}m category=$category pid=${pid:-unknown})"
  fi
  return 0
}

# Same shape as above, but for mktemp-random-suffixed files that carry no
# embeddable liveness signal — age floor only (the lock-dir check at the
# call site is what stands in for per-file liveness in this category).
_consider_by_mtime_only() {
  local f="$1" category="$2" stale_min="$3" dry_run="$4"
  local age
  age=$(_age_minutes "$f") || { echo "skip: $f (could not read mtime)" >&2; return 1; }
  if (( age < stale_min )); then
    echo "skip: $f (age=${age}m, below ${stale_min}m floor — may be in progress)" >&2
    return 1
  fi
  if [[ "$dry_run" -eq 1 ]]; then
    echo "reaped (dry-run): $f (age=${age}m category=$category)"
  else
    rm -f "$f" 2>/dev/null
    echo "reaped: $f (age=${age}m category=$category)"
  fi
  return 0
}

sweep() {
  local shipyard_home="" stale_min="$STALE_MIN_DEFAULT" dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shipyard-home) shipyard_home="${2:-}"; shift 2 ;;
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
  if [[ ! "$stale_min" =~ ^[0-9]+$ ]]; then
    echo "sweep: --stale-min must be a non-negative integer, got: $stale_min" >&2
    return 64
  fi

  local reaped=0 skipped=0 rc

  # --- sessions/*.json.tmp.<pid> (session-state.sh atomic_write) ---
  local sessions_dir="$shipyard_home/sessions"
  if [[ -d "$sessions_dir" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      _consider_pid_suffixed "$f" "sessions" "$stale_min" "$dry_run"
      rc=$?
      if [[ $rc -eq 0 ]]; then reaped=$((reaped+1)); else skipped=$((skipped+1)); fi
    done < <(find "$sessions_dir" -maxdepth 1 -type f -name '*.json.tmp.*' 2>/dev/null)
  fi

  # --- flake-registry.jsonl.tmp.<pid> (flake-registry.sh prune rewrite) ---
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    _consider_pid_suffixed "$f" "flake-registry" "$stale_min" "$dry_run"
    rc=$?
    if [[ $rc -eq 0 ]]; then reaped=$((reaped+1)); else skipped=$((skipped+1)); fi
  done < <(find "$shipyard_home" -maxdepth 1 -type f -name 'flake-registry.jsonl.tmp.*' 2>/dev/null)

  # --- cost-history.jsonl.<6-char> / .err.<6-char> (cost-history.sh reconcile) ---
  local lockdir="$shipyard_home/cost-history.jsonl.lock"
  local lock_live=0
  if [[ -d "$lockdir" ]]; then
    local lm lnow
    lm=$(_mtime_epoch "$lockdir")
    if [[ "$lm" =~ ^[0-9]+$ ]]; then
      lnow=$(date +%s)
      if (( lnow - lm < LOCK_STALE_SECONDS )); then
        lock_live=1
      fi
    else
      # Couldn't read the lock dir's age — err toward "live" so we never
      # race a possibly-active flush.
      lock_live=1
    fi
  fi

  if [[ "$lock_live" -eq 1 ]]; then
    echo "skip: cost-history.jsonl.lock is held and fresh — a flush may be in progress, skipping cost-history tmp sweep this pass" >&2
  else
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      _consider_by_mtime_only "$f" "cost-history" "$stale_min" "$dry_run"
      rc=$?
      if [[ $rc -eq 0 ]]; then reaped=$((reaped+1)); else skipped=$((skipped+1)); fi
    done < <(find "$shipyard_home" -maxdepth 1 -type f \
               \( -name 'cost-history.jsonl.??????' -o -name 'cost-history.jsonl.err.??????' \) \
               2>/dev/null)
  fi

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
      echo "sweep-orphan-tmp.sh: unknown subcommand: $sub" >&2
      usage
      return 64
      ;;
  esac
}

main "$@"

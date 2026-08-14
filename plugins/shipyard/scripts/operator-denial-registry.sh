#!/usr/bin/env bash
# operator-denial-registry.sh — cross-session operator-denial ledger at
# $SHIPYARD_HOME/ (issue #1363).
#
# Background: `operator_denials` is a session-local orchestrator-state
# struct (see `commands/do-work/orchestrator-state-reference.md`) recording
# every operator-phase action (`gh pr close`/`gh pr merge`/a browser
# mutation) the Claude Code auto-mode permission classifier refused
# outright. It's already surfaced in the end-of-session summary's
# `Operator denied (#746)` block — but that struct lives only in working
# memory for the session that hit the denial, and is discarded the moment
# [cleanup-summary.md's step 8](../commands/do-work/cleanup-summary.md)
# removes the session-state file. A denial is not transient session noise:
# it's a durable statement about what this harness will and will not let an
# agent do on a given surface. Discarding it guarantees every future session
# rediscovers the same boundary by hitting it again.
#
# This helper is the session-spanning record that survives cleanup. Step
# 7.6 of cleanup-summary.md appends one line per denial to this registry,
# BEFORE the session-state file is retired in step 8 — mirroring how step 7
# flushes `cost-history.jsonl` before the same retirement. A future
# session's `Operator denied (#746)` render (or a human running `report`
# directly) can then see whether a given (kind, target) denial is a
# one-off or a repeated, standing constraint.
#
# Modeled directly on flake-registry.sh (issue #378) — same storage shape,
# same append-only-JSONL rationale, same subcommand surface reduced to what
# this ledger actually needs (no threshold-escalation `crossed` here; that
# judgment is left to a human reading `report`, not automated action).
#
# Storage layout:
#
#   $SHIPYARD_HOME/                        (default: ~/.shipyard/)
#     operator-denials.jsonl               # append-only; one line per denial
#
# One event line:
#
#   {"at":"2026-08-14T09:12:00Z","repo":"mattsears18/lightwork",
#    "kind":"console-action","target":"console.cloud.google.com/auth/branding?project=lightwork-zxasx7",
#    "denial_text":"Permission for this action was denied by the Claude Code auto mode classifier.",
#    "outcome":"handed-back","session":"<session-id>"}
#
# Append-only JSONL is intentional (same rationale as flake-registry.sh /
# cost-history.sh): safe under concurrent writes from parallel `/do-work`
# orchestrators (each `record` writes its line in one `>>` redirect, and the
# kernel guarantees atomicity for writes <= PIPE_BUF, which every event line
# fits comfortably under — no locks, no read-modify-write), easy to
# grep/jq from the shell, cheap to rotate.
#
# Privacy (same posture as flake-registry.sh's own notice, but a stricter
# default): operator-denials.jsonl lives entirely on the local filesystem at
# $SHIPYARD_HOME/ (default ~/.shipyard/) — it is NEVER uploaded anywhere by
# shipyard. The data recorded (repo, kind, target, denial text, session id,
# timestamp) can include the URL or field name of an admin console being
# mutated — potentially more identifying than flake-registry's CI test
# names — so collection defaults OFF. Opt in with
# `operator_denial_registry.enabled: true`. When disabled, cleanup-summary's
# step 7.6 records nothing; the session-local `Operator denied (#746)`
# rendering is entirely unaffected either way. The file is safe to `rm`;
# `reset` moves it to .bak.<ts> (recoverable, not rm'd).
#
# Subcommands:
#
#   record --kind <kind> --target <target> --denial-text <text>
#          --outcome <outcome> [--repo <owner/repo>] [--session <id>]
#          [--at <iso8601>] [--dry-run]
#     Append one denial event. `--kind` matches operator_denials' enum
#     (merge-pr|close-pr|paste-secret|toggle-setting|reply-comment|
#     console-action|upload-file). `--outcome` matches operator_denials' enum
#     (reframed|shipped-after-reframe|handed-back). --dry-run emits the line
#     to stdout instead of appending.
#
#   report [--repo <owner/repo>] [--kind <kind>] [--window-days N]
#          [--format json|table]
#     Read operator-denials.jsonl and aggregate events into per-(repo, kind,
#     target) rows. Each row carries the event count, the count of distinct
#     sessions, and the first/last event timestamps — this is what lets a
#     reader distinguish a one-off denial from a repeated, standing
#     constraint (a row with events > 1 is the repeat signal). --window-days
#     N (default 0 = no window, report everything) restricts to events
#     within the last N days. --format json (default) emits a JSON array;
#     table emits a human-readable summary.
#
#   read
#     Emit the raw jsonl on stdout. Exit 3 if the file is missing.
#
#   prune [--window-days N] [--dry-run]
#     Rewrite operator-denials.jsonl keeping only events within the last N
#     days (default 180 — this ledger's value is in a slow-forming pattern,
#     so it's kept longer than flake-registry's 90-day default).
#
#   reset [--yes]
#     Move operator-denials.jsonl to .bak.<ts> (recoverable, not rm'd).
#     Prompts on stdin unless --yes is passed.
#
# Environment variables:
#
#   SHIPYARD_HOME — base directory. Defaults to $HOME/.shipyard. Same env
#                   var used by session-state.sh, cost-history.sh,
#                   flake-registry.sh, and shipyard-config.sh; relocating it
#                   relocates all of them.
#
# Exit codes:
#
#   0   — success
#   3   — read of a missing registry file
#   64  — usage error (bad subcommand or missing required argument)
#   65+ — internal helper failure (jq missing, write failure, etc.)
#   70  — reset aborted by user

set -u

# --------------------------------------------------------------------------
# Shared helpers (shipyard_home, require_jq) — issue #887.
# --------------------------------------------------------------------------
# shellcheck source=lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_jq

usage() {
  cat <<'EOF' >&2
Usage:
  operator-denial-registry.sh record --kind <kind> --target <target>
                                     --denial-text <text> --outcome <outcome>
                                     [--repo <owner/repo>] [--session <id>]
                                     [--at <iso8601>] [--dry-run]
  operator-denial-registry.sh report [--repo <owner/repo>] [--kind <kind>]
                                     [--window-days N] [--format json|table]
  operator-denial-registry.sh read
  operator-denial-registry.sh prune  [--window-days N] [--dry-run]
  operator-denial-registry.sh reset  [--yes]

Environment:
  SHIPYARD_HOME  base dir for the registry (default: $HOME/.shipyard)

Exit codes:
  0    success
  3    read of a missing registry file
  64   usage error
  65+  internal helper failure
  70   reset aborted by user
EOF
}

registry_path() {
  printf '%s/operator-denials.jsonl\n' "$(shipyard_home)"
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Cutoff timestamp N days before now (UTC, ISO8601). GNU and BSD date take
# different relative-date flags; try GNU first, fall back to BSD.
cutoff_iso() {
  local days="$1"
  date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

VALID_KINDS="merge-pr close-pr paste-secret toggle-setting reply-comment console-action upload-file"
VALID_OUTCOMES="reframed shipped-after-reframe handed-back"

is_valid_kind() {
  local k="$1" v
  for v in $VALID_KINDS; do
    [[ "$k" == "$v" ]] && return 0
  done
  return 1
}

is_valid_outcome() {
  local o="$1" v
  for v in $VALID_OUTCOMES; do
    [[ "$o" == "$v" ]] && return 0
  done
  return 1
}

# --------------------------------------------------------------------------
# Aggregation core — shared by report.
#
# Reads the registry, optionally filters by repo/kind + window, and groups
# events by (repo, kind, target) into rows.
# --------------------------------------------------------------------------
aggregate() {
  local repo_filter="$1"   # "" => all repos
  local kind_filter="$2"   # "" => all kinds
  local cutoff="$3"        # "" => no window filter

  local path
  path=$(registry_path)
  if [[ ! -f "$path" ]]; then
    printf '[]\n'
    return 0
  fi

  # Read each JSONL line and parse defensively — `fromjson? // empty` drops
  # any corrupt line so one bad write doesn't sink the whole aggregation.
  jq -R 'fromjson? // empty' "$path" | jq -s \
    --arg repo "$repo_filter" \
    --arg kind "$kind_filter" \
    --arg cutoff "$cutoff" '
    map(
      select($repo == "" or .repo == $repo)
      | select($kind == "" or .kind == $kind)
      | select($cutoff == "" or (.at // "") >= $cutoff)
    )
    | group_by([.repo, .kind, .target])
    | map({
        repo:     .[0].repo,
        kind:     .[0].kind,
        target:   .[0].target,
        events:   length,
        distinct_sessions: ([.[].session // "" ] | map(select(length > 0)) | unique | length),
        last_denial_text: (sort_by(.at)[-1].denial_text // ""),
        first_at: ([.[].at] | min),
        last_at:  ([.[].at] | max)
      })
    | sort_by(-.events, -.distinct_sessions)
  '
}

# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------
cmd_record() {
  local kind="" target="" denial_text="" outcome=""
  local repo="" session="" at="" dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind)         kind="${2:-}"; shift 2 ;;
      --target)       target="${2:-}"; shift 2 ;;
      --denial-text)  denial_text="${2:-}"; shift 2 ;;
      --outcome)      outcome="${2:-}"; shift 2 ;;
      --repo)         repo="${2:-}"; shift 2 ;;
      --session)      session="${2:-}"; shift 2 ;;
      --at)           at="${2:-}"; shift 2 ;;
      --dry-run)      dry_run=1; shift ;;
      *) echo "record: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  if [[ -z "$kind" || -z "$target" || -z "$outcome" ]]; then
    echo "record: --kind, --target, --outcome are required" >&2
    usage
    exit 64
  fi
  if ! is_valid_kind "$kind"; then
    echo "record: --kind must be one of: $VALID_KINDS (got: $kind)" >&2
    exit 64
  fi
  if ! is_valid_outcome "$outcome"; then
    echo "record: --outcome must be one of: $VALID_OUTCOMES (got: $outcome)" >&2
    exit 64
  fi
  if [[ -z "$at" ]]; then
    at=$(now_iso)
  fi

  # denial_text and repo/session are optional-but-recommended; empty ones
  # are omitted from the written line so the on-disk shape stays clean.
  local line
  line=$(jq -c -n \
    --arg at "$at" \
    --arg repo "$repo" \
    --arg kind "$kind" \
    --arg target "$target" \
    --arg denial_text "$denial_text" \
    --arg outcome "$outcome" \
    --arg session "$session" '
    {at: $at, kind: $kind, target: $target, outcome: $outcome}
    | (if $repo        != "" then . + {repo: $repo}               else . end)
    | (if $denial_text != "" then . + {denial_text: $denial_text} else . end)
    | (if $session      != "" then . + {session: $session}         else . end)
  ') || { echo "record: failed to build event line" >&2; exit 65; }

  if [[ $dry_run -eq 1 ]]; then
    printf '%s\n' "$line"
    return 0
  fi

  local path
  path=$(registry_path)
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$line" >> "$path" || {
    echo "record: failed to append to $path" >&2
    exit 66
  }
}

cmd_report() {
  local repo="" kind="" window_days=0 format="json"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)        repo="${2:-}"; shift 2 ;;
      --kind)        kind="${2:-}"; shift 2 ;;
      --window-days) window_days="${2:-}"; shift 2 ;;
      --format)      format="${2:-}"; shift 2 ;;
      *) echo "report: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done
  if ! [[ "$window_days" =~ ^[0-9]+$ ]]; then
    echo "report: --window-days must be a non-negative integer" >&2
    exit 64
  fi

  local cutoff=""
  if [[ "$window_days" -gt 0 ]]; then
    cutoff=$(cutoff_iso "$window_days")
  fi

  local rows
  rows=$(aggregate "$repo" "$kind" "$cutoff") || exit $?

  if [[ "$format" == "table" ]]; then
    printf '%s\n' "$rows" | jq -r '
      if length == 0 then "no operator-denial events in window"
      else (
        ["EVENTS", "SESSIONS", "KIND", "TARGET", "LAST"],
        (.[] | [
          (.events | tostring),
          (.distinct_sessions | tostring),
          .kind,
          .target,
          .last_at
        ])
      ) | @tsv end'
  else
    printf '%s\n' "$rows"
  fi
}

cmd_read() {
  local path
  path=$(registry_path)
  if [[ ! -f "$path" ]]; then
    echo "read: registry not found at $path" >&2
    exit 3
  fi
  cat "$path"
}

cmd_prune() {
  local window_days=180 dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --window-days) window_days="${2:-}"; shift 2 ;;
      --dry-run)     dry_run=1; shift ;;
      *) echo "prune: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done
  if ! [[ "$window_days" =~ ^[0-9]+$ ]]; then
    echo "prune: --window-days must be a non-negative integer" >&2
    exit 64
  fi

  local path
  path=$(registry_path)
  if [[ ! -f "$path" ]]; then
    return 0
  fi

  local cutoff=""
  if [[ "$window_days" -gt 0 ]]; then
    cutoff=$(cutoff_iso "$window_days")
  fi

  local kept
  kept=$(jq -R 'fromjson? // empty' "$path" | jq -c \
    --arg cutoff "$cutoff" '
    select($cutoff == "" or (.at // "") >= $cutoff)')

  if [[ $dry_run -eq 1 ]]; then
    printf '%s\n' "$kept"
    return 0
  fi

  local tmp="${path}.tmp.$$"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  if [[ -n "$kept" ]]; then
    printf '%s\n' "$kept" > "$tmp"
  else
    : > "$tmp"
  fi
  mv -f "$tmp" "$path" || { echo "prune: failed to rewrite $path" >&2; exit 67; }
  trap - EXIT
}

cmd_reset() {
  local yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) yes=1; shift ;;
      *) echo "reset: unknown arg $1" >&2; usage; exit 64 ;;
    esac
  done

  local path
  path=$(registry_path)
  if [[ ! -f "$path" ]]; then
    return 0
  fi

  if [[ $yes -eq 0 ]]; then
    printf 'Move %s aside to a .bak file? [y/N] ' "$path" >&2
    local answer
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      echo "reset: aborted" >&2
      exit 70
    fi
  fi

  local ts
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  local bak="${path}.bak.${ts}"
  mv -f "$path" "$bak" || { echo "reset: failed to move $path" >&2; exit 67; }
  echo "reset: moved $path -> $bak" >&2
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  usage
  exit 64
fi

subcmd="$1"
shift

case "$subcmd" in
  record) cmd_record "$@" ;;
  report) cmd_report "$@" ;;
  read)   cmd_read "$@" ;;
  prune)  cmd_prune "$@" ;;
  reset)  cmd_reset "$@" ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "operator-denial-registry.sh: unknown subcommand $subcmd" >&2
    usage
    exit 64
    ;;
esac

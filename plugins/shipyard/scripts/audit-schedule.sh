#!/usr/bin/env bash
# audit-schedule.sh — cadence-gating helper backing /shipyard:audit-scheduled
# (issue #975).
#
# Background: shipyard ships two auditors well-suited to running on a
# recurring cadence rather than only on demand — `testing-auditor` (tests
# that lie, coverage holes, CI gate completeness) and `functional-qa-auditor`
# (signs in as a real user, exercises features end-to-end) — plus every
# other `/shipyard:audit` dimension. Before this script, the ONLY way to run
# any of them was an explicit `/audit <dimension>` invocation, so drift went
# unnoticed until a maintainer already suspected a problem (the exact case
# where an auditor adds the least value — see the issue's lightwork repro:
# native E2E disabled for 58 days across 45 releases before anyone looked).
#
# This helper answers exactly one question — "is this repo+dimension due to
# run again?" — by comparing a small persisted last-run timestamp against a
# configured cadence. It does NOT run auditors, file issues, or know
# anything about the `/audit` dispatch table; `/shipyard:audit-scheduled`
# (the command spec) owns dispatch and reuses `/shipyard:audit`'s existing
# machinery for that, including the existing `audit-key` fingerprint dedup
# in `filing-github-issues` — a scheduled run that finds nothing new
# produces no issue churn for free, because the underlying auditors already
# guarantee that on any re-run.
#
# Storage layout ($SHIPYARD_HOME/audit-schedule-state.json — same directory
# as eas-state.json / cost-history.jsonl / flake-registry.jsonl):
#
#   {
#     "version": 1,
#     "repos": {
#       "<owner/repo>": {
#         "<dimension>": { "last_run_at": "<ISO-8601 UTC>" }
#       }
#     }
#   }
#
# Cadence strings are `<integer><unit>` where unit is one of:
#   m = minutes, h = hours, d = days, w = weeks   (e.g. "7d", "24h", "30m")
#
# Subcommands:
#
#   state-path
#              Print the canonical state-file path
#              ($SHIPYARD_HOME/audit-schedule-state.json).
#
#   state-init
#              Create the state file with an empty repos map if missing.
#              Idempotent.
#
#   state-read [--repo <owner/repo>]
#              Emit the current state on stdout. Without --repo, prints the
#              whole file; with --repo, prints just that repo's per-
#              dimension map (empty JSON object if untracked).
#
#   record --repo <owner/repo> --dimension <dim> [--at <iso-8601>]
#              Atomically record that <dimension> was just run for <repo>.
#              --at defaults to now (UTC, second precision). Auto-
#              initializes the state file if missing.
#
#   cadence-seconds <cadence>
#              Parse a cadence string (e.g. "7d") to an integer number of
#              seconds and print it. Exits 64 on an unparseable cadence.
#              Exposed standalone mainly for tests / operator debugging —
#              `due` uses the same parsing internally.
#
#   due --repo <owner/repo> --schedule-json <file|->
#              Read a JSON array of schedule entries (the shape of the
#              `audits.schedule` config block — see
#              schemas/shipyard.config.schema.json) from <file>, or from
#              stdin when <file> is `-`. Compare each entry against the
#              recorded state for <repo> and emit one compact JSON line per
#              DUE entry (empty output = nothing due):
#                {dimension, cadence, url, last_run_at, seconds_since_last_run}
#              An entry is due when it has never run before (no recorded
#              last_run_at) OR the elapsed time since last_run_at is >= its
#              cadence, in seconds. An entry with `"enabled": false` is
#              always skipped. `url` is null when the schedule entry
#              doesn't carry one (codebase-only dimensions).
#
# Environment variables:
#
#   SHIPYARD_HOME   base dir (default: $HOME/.shipyard). Mirrors the
#                   session-state / cost-history / eas-watch convention.
#
# Exit codes:
#
#   0   success
#   5   due: --schedule-json file missing or unreadable
#   64  usage error (including an unparseable cadence string)
#   65+ internal helper failure (jq missing, write permission denied)

set -u

# --------------------------------------------------------------------------
# Shared helpers (shipyard_home, require_jq, atomic_write) — issue #887.
# --------------------------------------------------------------------------
# shellcheck source=lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_jq

usage() {
  cat <<'EOF' >&2
Usage:
  audit-schedule.sh state-path
  audit-schedule.sh state-init
  audit-schedule.sh state-read      [--repo <owner/repo>]
  audit-schedule.sh record          --repo <owner/repo> --dimension <dim>
                                     [--at <iso-8601>]
  audit-schedule.sh cadence-seconds <cadence>
  audit-schedule.sh due             --repo <owner/repo>
                                     --schedule-json <file|->

Environment:
  SHIPYARD_HOME   base dir for audit-schedule-state.json (default: $HOME/.shipyard)

Exit codes:
  0   success
  5   due: --schedule-json file missing
  64  usage error (including an unparseable cadence string)
  65+ internal helper failure
EOF
}

# ---------------------------------------------------------------------------
# jq fragment shared by `cadence-seconds` and `due` — the single source of
# truth for cadence-string parsing, so the two call sites can't drift.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
JQ_CADENCE_FN='
def cadence_seconds:
  if test("^[0-9]+[mhdw]$") then
    (capture("^(?<n>[0-9]+)(?<u>[mhdw])$")) as $c
    | ($c.n | tonumber) as $n
    | ($c.u) as $u
    | if $u == "m" then $n*60
      elif $u == "h" then $n*3600
      elif $u == "d" then $n*86400
      elif $u == "w" then $n*604800
      else null end
  else null end;
'

state_path() {
  local home
  home=$(shipyard_home)
  printf '%s/audit-schedule-state.json\n' "$home"
}

state_init() {
  local path
  path=$(state_path)
  if [[ -f "$path" ]]; then
    return 0
  fi
  printf '{"version":1,"repos":{}}\n' | atomic_write "$path"
}

state_read() {
  local repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      *)      echo "audit-schedule.sh: unknown flag for state-read: $1" >&2; exit 64 ;;
    esac
  done
  local path
  path=$(state_path)
  if [[ ! -f "$path" ]]; then
    if [[ -n "$repo" ]]; then
      printf '{}\n'
    else
      printf '{"version":1,"repos":{}}\n'
    fi
    return 0
  fi
  if [[ -n "$repo" ]]; then
    jq --arg r "$repo" '.repos[$r] // {}' "$path"
  else
    cat "$path"
  fi
}

record() {
  local repo="" dimension="" at=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)      repo="$2"; shift 2 ;;
      --dimension) dimension="$2"; shift 2 ;;
      --at)        at="$2"; shift 2 ;;
      *)           echo "audit-schedule.sh: unknown flag for record: $1" >&2; exit 64 ;;
    esac
  done
  if [[ -z "$repo" ]]; then
    echo "audit-schedule.sh: record requires --repo <owner/repo>" >&2; exit 64
  fi
  if [[ -z "$dimension" ]]; then
    echo "audit-schedule.sh: record requires --dimension <dim>" >&2; exit 64
  fi
  if [[ -z "$at" ]]; then
    at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  local path
  path=$(state_path)
  if [[ ! -f "$path" ]]; then
    state_init
  fi
  jq \
    --arg r "$repo" \
    --arg d "$dimension" \
    --arg ts "$at" \
    '.repos[$r] = ((.repos[$r] // {}) + {($d): {last_run_at: $ts}})' \
    "$path" | atomic_write "$path"
}

cadence_seconds_cmd() {
  local cadence="${1:-}"
  if [[ -z "$cadence" ]]; then
    echo "audit-schedule.sh: cadence-seconds requires a cadence string, e.g. 7d" >&2
    exit 64
  fi
  local v
  v=$(jq -n --arg c "$cadence" "${JQ_CADENCE_FN} (\$c | cadence_seconds)")
  if [[ -z "$v" || "$v" == "null" ]]; then
    echo "audit-schedule.sh: invalid cadence: $cadence (expected <int>[mhdw] — e.g. 7d, 24h, 30m, 2w)" >&2
    exit 64
  fi
  printf '%s\n' "$v"
}

due() {
  local repo="" schedule_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)          repo="$2"; shift 2 ;;
      --schedule-json) schedule_file="$2"; shift 2 ;;
      *)               echo "audit-schedule.sh: unknown flag for due: $1" >&2; exit 64 ;;
    esac
  done
  if [[ -z "$repo" ]]; then
    echo "audit-schedule.sh: due requires --repo <owner/repo>" >&2; exit 64
  fi
  if [[ -z "$schedule_file" ]]; then
    echo "audit-schedule.sh: due requires --schedule-json <file|->" >&2; exit 64
  fi
  local schedule_json
  if [[ "$schedule_file" == "-" ]]; then
    schedule_json=$(cat)
  else
    if [[ ! -f "$schedule_file" ]]; then
      echo "audit-schedule.sh: schedule file not found: $schedule_file" >&2
      exit 5
    fi
    schedule_json=$(cat "$schedule_file")
  fi
  # Absent / empty / null config (no audits.schedule block at all) is a
  # valid "nothing scheduled" state, not an error.
  if [[ -z "$schedule_json" || "$schedule_json" == "null" ]]; then
    schedule_json="[]"
  fi

  local path state
  path=$(state_path)
  if [[ -f "$path" ]]; then
    state=$(jq -c --arg r "$repo" '.repos[$r] // {}' "$path")
  else
    state="{}"
  fi

  jq -cn \
    --argjson schedule "$schedule_json" \
    --argjson state "$state" \
    "${JQ_CADENCE_FN}
     \$schedule[]?
     | select(.enabled != false)
     | .dimension as \$dim
     | (\$state[\$dim].last_run_at // null) as \$last
     | (.cadence | cadence_seconds) as \$cs
     | (if \$last == null then null else (now - (\$last | fromdateiso8601)) end) as \$elapsed
     | (if \$last == null then true else (\$cs != null and \$elapsed >= \$cs) end) as \$is_due
     | select(\$is_due)
     | {dimension: \$dim, cadence: .cadence, url: (.url // null), last_run_at: \$last,
        seconds_since_last_run: (if \$elapsed == null then null else (\$elapsed | floor) end)}"
}

# ---------------------------------------------------------------------------
# Subcommand dispatch
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then usage; exit 64; fi
sub="$1"; shift
case "$sub" in
  state-path)       state_path ;;
  state-init)       state_init ;;
  state-read)       state_read "$@" ;;
  record)           record "$@" ;;
  cadence-seconds)  cadence_seconds_cmd "$@" ;;
  due)              due "$@" ;;
  -h|--help)        usage; exit 0 ;;
  *)                echo "audit-schedule.sh: unknown subcommand: $sub" >&2; usage; exit 64 ;;
esac

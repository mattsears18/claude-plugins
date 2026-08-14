#!/usr/bin/env bash
# verify-config-labels.sh — verify every label named by the merged
# shipyard.config.json (the `labels` block) actually exists as a GitHub
# label in the target repo, and report any mismatch loudly rather than
# letting the session proceed on a routing label that was never created.
#
# Background (issue #1359)
# -------------------------
# Shipyard's config names labels BY STRING and nothing has ever verified
# those labels exist in the target repo. A consumer repo that declares no
# `labels` block at all inherits shipyard's built-in defaults wholesale —
# including label names that only ever held true of shipyard's OWN repo
# (`mattsears18/shipyard`, which happens to carry every legacy label object
# from its own history). The repro that motivated this script:
# `mattsears18/lightwork` declares no `labels` block, so its effective
# config named `blocked:agent` (key `blocked`) and `blocked:agent-hard`
# (key `blocked_hard`) — neither of which existed as a label object in that
# repo. Nothing anywhere detected the mismatch: not setup, not dispatch, not
# drain. A mislabeled/missing-label issue is invisible to BOTH `/do-work`
# (which never applies a label it can't find, or applies a bare, undescribed
# auto-created one) and `/my-turn` (which filters by label name to build its
# walked queue) — so an issue routed through a phantom label is unreachable
# by either loop. Issue #1360 retired the `blocked` / `blocked_hard` keys
# from the config defaults and schema entirely (both were vestigial —
# nothing has applied or read either label since #521's refuse/
# dependency-wait split), which closes this specific false-positive for
# good; the cross-reference itself stays general-purpose for whatever
# `labels` keys remain live or get added later.
#
# This script is the single executable source of truth for the
# cross-reference. It never blocks — a missing label is a loud advisory, not
# a session-ending failure — so every exit path still reports a verdict a
# caller can act on.
#
# Usage — live detection (the normal path, run from inside a shipyard
# checkout or a worktree of one; CLAUDE_PLUGIN_ROOT must be exported so this
# script can shell out to shipyard-config.sh):
#
#   bash verify-config-labels.sh <owner/repo>
#     -> prints `OK: ...` (exit 0), `MISSING: ...` (exit 1), or
#        `INDETERMINATE: ...` (exit 2) on stdout. Diagnostics on stderr.
#
# Usage — pure decision (hermetic, for tests and for callers that already
# hold both JSON blobs, e.g. a caller composing with gh-cached.sh):
#
#   bash verify-config-labels.sh --decide <config-labels-json> <existing-labels-json>
#     <config-labels-json>   compact JSON object, e.g. {"ci_blocked":"blocked:ci",...}
#                             — the merged config's `.labels` block
#                             (`shipyard-config.sh get labels`).
#     <existing-labels-json> compact JSON array of label name strings, e.g.
#                             ["bug","shipyard",...] — `gh label list --json name`.
#     -> same stdout/exit-code contract as live mode, no network I/O.
#
# Exit codes:
#   0 — every config-named label exists in the target repo.
#   1 — one or more config-named labels are missing. stdout: `MISSING: ...`
#       summary line, followed by one `MISSING_LABEL: <key>="<value>"` line
#       per absent label (machine-parseable, one per line).
#   2 — could not establish a trustworthy result (bad usage, an empty/
#       unparseable config-labels or existing-labels blob, or a live-mode
#       `gh`/`shipyard-config.sh` call that failed). Never treat this as a
#       pass — the point of the check is to be loud, and "couldn't check" is
#       itself something to surface, not something to swallow.

set -u
export LC_ALL=C

die_indeterminate() {
  echo "INDETERMINATE: $1" >&2
  echo "INDETERMINATE: $1"
  exit 2
}

command -v jq >/dev/null 2>&1 || die_indeterminate "jq not found on PATH"

# ---------------------------------------------------------------------------
# The decision. Pure function of two JSON blobs — no I/O, no network. This is
# the whole comparison; everything else in this file just feeds it.
#
# $1 — compact JSON object: config-named labels, key -> label-name string.
# $2 — compact JSON array: label names that actually exist in the repo.
#
# Prints the same OK:/MISSING:/MISSING_LABEL: shape live mode does, on
# stdout. Returns (not exits — callers in live mode still need to run
# cleanup) 0 when nothing is missing, 1 when something is.
# ---------------------------------------------------------------------------
decide() {
  local config_labels_json="$1" existing_labels_json="$2"

  if ! printf '%s' "$config_labels_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    die_indeterminate "config-labels input is not a JSON object: $config_labels_json"
  fi
  if ! printf '%s' "$existing_labels_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die_indeterminate "existing-labels input is not a JSON array: $existing_labels_json"
  fi

  local total
  total=$(printf '%s' "$config_labels_json" | jq -r 'keys | length')

  # jq does the whole cross-reference in one pass: for every key/value pair
  # in the config object, keep it iff the value is NOT a member of the
  # existing-labels array. Emit "<key>\t<value>" per missing entry.
  #
  # Deliberately `index(.value) == null`, NOT `inside`/`contains` — jq's
  # `contains`/`inside` recurse into elemental SUBSTRING matching for
  # strings, so `"blocked:ci" | inside(["blocked:ci-old"])` is true (a false
  # "exists" for a label that is actually absent). `index` does exact
  # equality on array elements, which is the comparison a label NAME needs.
  local missing
  missing=$(jq -nr \
    --argjson cfg "$config_labels_json" \
    --argjson existing "$existing_labels_json" \
    '$cfg | to_entries[] | select((.value as $v | ($existing | index($v))) == null) | "\(.key)\t\(.value)"')

  if [ -z "$missing" ]; then
    printf 'OK: %s label(s) named by config all exist\n' "$total"
    return 0
  fi

  local count
  count=$(printf '%s\n' "$missing" | grep -c . || true)
  printf 'MISSING: %s of %s label(s) named by config do not exist in the target repo\n' "$count" "$total"
  while IFS=$'\t' read -r key value; do
    [ -z "$key" ] && continue
    printf 'MISSING_LABEL: labels.%s="%s"\n' "$key" "$value"
  done <<< "$missing"
  return 1
}

main() {
  if [ "${1:-}" = "--decide" ]; then
    if [ "$#" -ne 3 ]; then
      echo "usage: $0 --decide <config-labels-json> <existing-labels-json>" >&2
      exit 2
    fi
    decide "$2" "$3"
    exit $?
  fi

  local repo="${1:-}"
  if [ -z "$repo" ]; then
    echo "usage: $0 <owner/repo>" >&2
    echo "       $0 --decide <config-labels-json> <existing-labels-json>" >&2
    exit 2
  fi

  local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
  if [ -z "$plugin_root" ] || [ ! -x "$plugin_root/scripts/shipyard-config.sh" ]; then
    die_indeterminate "CLAUDE_PLUGIN_ROOT not set (or shipyard-config.sh not found under it) — cannot resolve the merged config"
  fi

  local config_labels_json
  config_labels_json=$("$plugin_root/scripts/shipyard-config.sh" get labels 2>/dev/null)
  if [ -z "$config_labels_json" ]; then
    die_indeterminate "shipyard-config.sh get labels returned nothing — cannot resolve the merged config's labels block"
  fi

  local existing_labels_json
  existing_labels_json=$(gh label list --repo "$repo" --limit 300 --json name --jq '[.[].name]' 2>/dev/null)
  if [ -z "$existing_labels_json" ]; then
    die_indeterminate "gh label list --repo $repo failed or returned nothing"
  fi

  decide "$config_labels_json" "$existing_labels_json"
}

main "$@"

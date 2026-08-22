#!/usr/bin/env bash
# resolve-filing-milestone-gate.sh — resolve the filing-time milestone gate
# (`milestones.enabled` / `milestones.assign_on_file` / `milestones.fallback`)
# from the repo the issue is actually being FILED AGAINST, not from whatever
# repo the session happens to be running in.
#
# Background (issue #1498)
# -----------------------
# `shipyard:filing-github-issues` § "Milestone assignment" read the gate with
#
#     shipyard-config.sh get milestones.enabled
#
# and `shipyard-config.sh` resolves its repo layer from the CWD's git toplevel
# (see its `repo_root()`). That is correct for a same-repo filing and wrong for
# a cross-repo one: the standard "file the friction against the plugin repo"
# flow files `--repo mattsears18/shipyard` from a session whose working repo is
# something else entirely, so the gate came back from the WORKING repo's config.
#
# The observed failure: seven issues (#1490–#1496) were filed against
# `mattsears18/shipyard` — which sets `milestones.enabled: true` and
# `milestones.assign_on_file: true` — from a session running in
# `mattsears18/lightwork`, whose committed config carries no `milestones` block
# at all. `milestones.enabled` therefore resolved to the built-in `false` and
# the whole assignment step was skipped, silently. Because
# `milestones.prioritize_dispatch` makes the milestone a RANKING input, the
# result was an inverted dispatch queue: three fresh P1s sorted behind a P2,
# purely for want of a milestone.
#
# Note that only the GATE was misresolved. The candidate milestone list is
# fetched with `gh api repos/<owner>/<repo>/milestones`, where `<owner>/<repo>`
# is already the filing target — that half was never wrong.
#
# What this script reads on the cross-repo path
# ---------------------------------------------
# The target repo's COMMITTED repo layer (`shipyard.config.json` at the default
# branch head), and nothing else. The user-global layer (`~/.shipyard/config.json`)
# and the personal override (`.shipyard/config.local.json`) are deliberately not
# consulted: the former is scoped to the operator, not the repo being filed
# against, and the latter is gitignored and exists only inside a local checkout
# this session does not have. Committed repo policy is exactly the right layer
# for "does this repo want milestones stamped at filing time" — it is the layer
# a maintainer reviews in a PR.
#
# This script NEVER creates a milestone and never decides which milestone an
# issue belongs to. It only answers whether the caller is authorized to pick
# among the target repo's already-existing milestones — the "a filer never
# creates a milestone" rule (#1242) is untouched.
#
# Usage
#   resolve-filing-milestone-gate.sh <target-owner/repo> [session-owner/repo]
#
# <target-owner/repo>   the repo the issue will be filed against (the value
#                       passed to `gh issue create --repo`). Required.
# [session-owner/repo]  the repo this session is running in. Defaults to
#                       $SHIPYARD_SESSION_REPO, then `gh repo view` from the
#                       cwd. When it matches the target, the full 4-layer
#                       session config is used unchanged.
#
# $SHIPYARD_CONFIG_PATH overrides the repo-relative config path
# (default `shipyard.config.json`).
#
# Output (stdout, exactly four `key=value` lines, in this order)
#   enabled=<true|false>
#   assign_on_file=<true|false>
#   fallback=<milestone title>
#   source=<session-config
#          |target-repo-config
#          |target-repo-config-absent
#          |target-repo-config-unreadable
#          |target-repo-config-invalid>
#
# `source` is the visibility half of the fix: a caller that ends up skipping
# assignment can say WHY in its end-of-run summary instead of skipping in
# silence, which is what made #1498 invisible for three days.
#
# Diagnostics on stderr, unconditionally.
#
# Exit status is always 0. Milestone resolution must never fail a filing — a
# lost finding is a far worse outcome than an unmilestoned one — so every error
# path degrades to the built-in defaults with an explanatory `source`.
set -u

TARGET_REPO="${1:-}"
SESSION_REPO_ARG="${2:-}"
CONFIG_PATH="${SHIPYARD_CONFIG_PATH:-shipyard.config.json}"

# Built-in defaults — must stay in lockstep with the `milestones` block of
# DEFAULTS_JSON in shipyard-config.sh. `defaults-parity` in the test suite
# asserts they have not drifted.
DEFAULT_ENABLED="false"
DEFAULT_ASSIGN="true"
DEFAULT_FALLBACK="Ongoing maintenance"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_emit() {
  # _emit <enabled> <assign_on_file> <fallback> <source>
  printf 'enabled=%s\n' "$1"
  printf 'assign_on_file=%s\n' "$2"
  printf 'fallback=%s\n' "$3"
  printf 'source=%s\n' "$4"
}

_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Normalize anything that isn't a literal `true` to `false`. A config read that
# returns empty, `null`, or an error string must never read as "on".
_boolish() {
  case "$(_lower "${1:-}")" in
    true) printf 'true' ;;
    *)    printf 'false' ;;
  esac
}

_b64_decode() {
  # macOS shipped `-D` long before `-d`; GNU coreutils only knows `-d`. Buffer
  # stdin first so the fallback attempt still has input to read — a straight
  # `base64 -d || base64 -D` pipeline feeds the second invocation nothing.
  local data
  data=$(cat)
  printf '%s' "$data" | base64 -d 2>/dev/null \
    || printf '%s' "$data" | base64 -D 2>/dev/null \
    || true
}

if [ -z "$TARGET_REPO" ]; then
  echo "resolve-filing-milestone-gate: no target repo given; falling back to built-in defaults" >&2
  _emit "$DEFAULT_ENABLED" "$DEFAULT_ASSIGN" "$DEFAULT_FALLBACK" "target-repo-config-unreadable"
  exit 0
fi

SESSION_REPO="$SESSION_REPO_ARG"
if [ -z "$SESSION_REPO" ]; then
  SESSION_REPO="${SHIPYARD_SESSION_REPO:-}"
fi
if [ -z "$SESSION_REPO" ]; then
  SESSION_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
fi

echo "resolve-filing-milestone-gate: target=$TARGET_REPO session=${SESSION_REPO:-unknown} path=$CONFIG_PATH" >&2

# --------------------------------------------------------------------------
# Same-repo (the common case): the session's own effective config IS the
# target repo's config, all four layers included. Nothing changes.
# --------------------------------------------------------------------------
if [ -n "$SESSION_REPO" ] && [ "$(_lower "$TARGET_REPO")" = "$(_lower "$SESSION_REPO")" ]; then
  cfg="$SCRIPT_DIR/shipyard-config.sh"
  s_enabled=$(bash "$cfg" get milestones.enabled 2>/dev/null || true)
  s_assign=$(bash "$cfg" get milestones.assign_on_file 2>/dev/null || true)
  s_fallback=$(bash "$cfg" get milestones.fallback 2>/dev/null || true)
  [ -n "$s_fallback" ] || s_fallback="$DEFAULT_FALLBACK"
  _emit "$(_boolish "$s_enabled")" "$(_boolish "$s_assign")" "$s_fallback" "session-config"
  exit 0
fi

# --------------------------------------------------------------------------
# Cross-repo: read the TARGET repo's committed config layer over the API. No
# checkout of the target repo is needed or assumed.
# --------------------------------------------------------------------------
# Capture stdout ONLY on success. `gh api` prints the API's error body to
# stdout on a 404 and bypasses `--jq` entirely, so a `|| true` capture would
# hand the error JSON downstream and misreport a missing repo as a malformed
# config.
if ! RAW_B64=$(gh api "repos/$TARGET_REPO/contents/$CONFIG_PATH" --jq '.content' 2>/dev/null); then
  RAW_B64=""
fi

if [ -z "$RAW_B64" ]; then
  # Either the repo has no committed config (the ordinary "hasn't run
  # /shipyard:init" case) or the API call failed. Both mean the same thing for
  # the gate — no repo-level opt-in is visible — but they are worth
  # distinguishing in the caller's summary, so probe once for existence.
  if gh api "repos/$TARGET_REPO" --jq '.full_name' >/dev/null 2>&1; then
    echo "resolve-filing-milestone-gate: $TARGET_REPO has no committed $CONFIG_PATH" >&2
    _emit "$DEFAULT_ENABLED" "$DEFAULT_ASSIGN" "$DEFAULT_FALLBACK" "target-repo-config-absent"
  else
    echo "resolve-filing-milestone-gate: could not read $TARGET_REPO over the API" >&2
    _emit "$DEFAULT_ENABLED" "$DEFAULT_ASSIGN" "$DEFAULT_FALLBACK" "target-repo-config-unreadable"
  fi
  exit 0
fi

RAW=$(printf '%s' "$RAW_B64" | tr -d '\n' | _b64_decode)

if [ -z "$RAW" ] || ! printf '%s' "$RAW" | jq -e . >/dev/null 2>&1; then
  echo "resolve-filing-milestone-gate: $TARGET_REPO:$CONFIG_PATH is not valid JSON" >&2
  _emit "$DEFAULT_ENABLED" "$DEFAULT_ASSIGN" "$DEFAULT_FALLBACK" "target-repo-config-invalid"
  exit 0
fi

# `//` is the WRONG operator for a boolean key — jq's alternative operator
# treats `false` as absent, so an explicit `"assign_on_file": false` would
# silently read back as the `true` default. Branch on key presence instead.
t_enabled=$(printf '%s' "$RAW" | jq -r --arg d "$DEFAULT_ENABLED" \
  '(.milestones // {}) | (if has("enabled") then .enabled else $d end) | tostring' 2>/dev/null || true)
t_assign=$(printf '%s' "$RAW" | jq -r --arg d "$DEFAULT_ASSIGN" \
  '(.milestones // {}) | (if has("assign_on_file") then .assign_on_file else $d end) | tostring' 2>/dev/null || true)
t_fallback=$(printf '%s' "$RAW" | jq -r --arg d "$DEFAULT_FALLBACK" \
  '(.milestones // {}) | (.fallback // $d)' 2>/dev/null || true)
[ -n "$t_fallback" ] || t_fallback="$DEFAULT_FALLBACK"

_emit "$(_boolish "$t_enabled")" "$(_boolish "$t_assign")" "$t_fallback" "target-repo-config"
exit 0

#!/usr/bin/env bash
# detect-config-staleness.sh — decide whether the repo-layer config the
# CURRENT SESSION is reading (`shipyard.config.json` in the pinned primary
# checkout) has fallen behind the same file on `origin/<default-branch>`,
# and name the keys that differ.
#
# Background (issue #1493)
# ------------------------
# `SHIPYARD_REPO_ROOT` is pinned to the PRIMARY checkout by setup step 0.56
# (#1059) so that config reads still see the gitignored
# `.shipyard/config.local.json` layer. That pin is correct and load-bearing
# — but the primary checkout is strictly read-only for the session and
# nothing ever refreshes it, so it stays at whatever commit it sat on when
# the session began. When a session PR that edits `shipyard.config.json`
# merges MID-SESSION, every subsequent `shipyard-config.sh` read for the
# rest of the run therefore returns PRE-MERGE config.
#
# Two costs, and the second is the dangerous one:
#
#   1. The merged change silently doesn't take effect for the rest of the
#      session. Benign for `backlog.someday_milestone`; not benign for
#      `trust.authors`, `auto_merge.policy`, `concurrency.*`, `models.*`.
#   2. It MANUFACTURES FALSE EVIDENCE that a correct fix is broken. The
#      #1493 repro: a session merged lightwork#4372 (setting
#      `backlog.someday_milestone`), re-ran `classify-backlog.sh run` to
#      confirm the acceptance criterion, got `2691 eligible:` — the exact
#      output a BROKEN fix would produce — and very nearly recorded "the
#      Someday drop still doesn't fire after #4372" on the issue. The
#      shipping worker's own verification could not have caught it either:
#      it validated by passing `--someday-milestone` explicitly, which
#      bypasses config resolution entirely.
#
# This detector converts that silent wrong answer into a visible caveat.
# It is deliberately a DRIFT check, not a PR-diff check: comparing the
# session's live config against the default branch catches drift from any
# source (this session's own merged PR, a sibling session's, a hand merge)
# and needs no PR number, no merge event, and no diff plumbing.
#
# NOTE — `.shipyard/config.local.json` is NOT a staleness source. It is
# gitignored, lives only in the primary checkout, and is read live from
# disk on every config load. The step-0.56 pin exists precisely so that
# layer stays current. Only the COMMITTED repo layer
# (`shipyard.config.json`) can go stale mid-session, so that is the only
# file this script compares.
#
# Usage
#   detect-config-staleness.sh <default-branch> [repo-root]
#
# <default-branch> is the repo's default branch name (e.g. "main"); the
# comparison is against `origin/<default-branch>`, which the caller is
# expected to have already `git fetch`ed. Pass "" (or omit) when no default
# branch was resolved — the script degrades to "fresh" rather than
# erroring, since there is nothing to compare against.
#
# [repo-root] defaults, in order, to: $SHIPYARD_REPO_ROOT, the
# `.shipyard-primary-root` stash written by setup step 0.56, this git
# working tree's toplevel, then $PWD.
#
# $SHIPYARD_CONFIG_PATH overrides the repo-relative config path
# (default `shipyard.config.json`).
#
# Output (stdout, single line)
#   fresh                 no material difference, or a comparison side
#                          could not be resolved (never a false positive)
#   stale:<k1>, <k2>, …   the dotted key paths whose effective values
#                          differ between the session's live config and
#                          origin/<default-branch>
#
# Diagnostics (the resolved root/path/ref, unconditionally) on stderr.
#
# Exit status is always 0 — this is an advisory signal, not a gate. A
# caller that treats a non-zero exit as "stale" would misread every
# environment error as drift.
set -u

DEFAULT_BRANCH="${1:-}"
REPO_ROOT="${2:-}"
CONFIG_PATH="${SHIPYARD_CONFIG_PATH:-shipyard.config.json}"

# How many changed keys to name before summarizing the rest. Keeps the
# caller's one-line warning genuinely one line on a large config rewrite.
MAX_NAMED_KEYS=12

_resolve_repo_root() {
  if [ -n "$REPO_ROOT" ]; then
    printf '%s\n' "$REPO_ROOT"
    return
  fi
  if [ -n "${SHIPYARD_REPO_ROOT:-}" ]; then
    printf '%s\n' "$SHIPYARD_REPO_ROOT"
    return
  fi
  # The step-0.56 stash, written at the orchestrator worktree root.
  local stashed=""
  if [ -f ".shipyard-primary-root" ]; then
    stashed=$(cat ".shipyard-primary-root" 2>/dev/null)
  fi
  if [ -z "$stashed" ]; then
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$top" ] && [ -f "$top/.shipyard-primary-root" ]; then
      stashed=$(cat "$top/.shipyard-primary-root" 2>/dev/null)
    fi
  fi
  if [ -n "$stashed" ]; then
    printf '%s\n' "$stashed"
    return
  fi
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || true)
  printf '%s\n' "${toplevel:-$PWD}"
}

ROOT=$(_resolve_repo_root)

LIVE_RAW=""
LIVE_PRESENT="absent"
if [ -f "$ROOT/$CONFIG_PATH" ]; then
  LIVE_RAW=$(cat "$ROOT/$CONFIG_PATH" 2>/dev/null || true)
  [ -n "$LIVE_RAW" ] && LIVE_PRESENT="present"
fi

REF_RAW=""
REF_PRESENT="absent"
if [ -n "$DEFAULT_BRANCH" ]; then
  REF_RAW=$(git -C "$ROOT" show "origin/$DEFAULT_BRANCH:$CONFIG_PATH" 2>/dev/null || true)
  [ -n "$REF_RAW" ] && REF_PRESENT="present"
fi

echo "resolved config staleness: root=$ROOT path=$CONFIG_PATH ref=origin/${DEFAULT_BRANCH:-unknown} live=$LIVE_PRESENT ref-side=$REF_PRESENT" >&2

# No committed layer on the default branch => nothing this session's reads
# could be stale against. Also covers the no-default-branch-argument case.
if [ "$REF_PRESENT" = "absent" ]; then
  echo "fresh"
  exit 0
fi

# A side that is present but not valid JSON is INDETERMINATE, never stale —
# a mid-edit or conflicted file must not be reported as config drift.
if [ "$LIVE_PRESENT" = "present" ] && ! printf '%s' "$LIVE_RAW" | jq -e . >/dev/null 2>&1; then
  echo "live config at $ROOT/$CONFIG_PATH is not valid JSON; reporting fresh" >&2
  echo "fresh"
  exit 0
fi
if ! printf '%s' "$REF_RAW" | jq -e . >/dev/null 2>&1; then
  echo "origin/$DEFAULT_BRANCH:$CONFIG_PATH is not valid JSON; reporting fresh" >&2
  echo "fresh"
  exit 0
fi

# An absent live file compares as `{}` — a config file ADDED on the default
# branch mid-session is real drift, not a missing side to shrug off.
[ "$LIVE_PRESENT" = "present" ] || LIVE_RAW="{}"

# Union the scalar leaf paths of both sides and keep the ones whose values
# differ. Comparing leaf paths (rather than raw text) means a pure
# formatting/whitespace/key-order change correctly reports `fresh`.
#
# Known limitation, deliberately accepted: a leaf-path union cannot see a
# difference that has no scalar on EITHER side (e.g. `"backlog": {}` added,
# or an empty array appended). Such a change alters no effective value, so
# omitting it is the desired behavior rather than a gap to close.
CHANGED=$(jq -rn \
  --argjson live "$LIVE_RAW" \
  --argjson ref "$REF_RAW" \
  --argjson max "$MAX_NAMED_KEYS" '
    def at($p): try getpath($p) catch null;
    ( [$live | paths(scalars)] + [$ref | paths(scalars)] | unique ) as $all
    | [ $all[] as $p
        | select( ($live | at($p)) != ($ref | at($p)) )
        | ($p | map(tostring) | join(".")) ]
    | unique
    | if length == 0 then ""
      elif length <= $max then join(", ")
      else (.[0:$max] | join(", ")) + " (+" + ((length - $max) | tostring) + " more)"
      end
  ' || true)
# NOTE: jq's stderr is deliberately NOT suppressed here. Swallowing it is
# what let an early version of this expression fail silently and report
# every genuinely-stale config as `fresh` — the exact false-negative shape
# #1493 exists to eliminate, reproduced inside the detector itself.

if [ -z "$CHANGED" ]; then
  echo "fresh"
else
  echo "stale:$CHANGED"
fi
exit 0

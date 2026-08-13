#!/usr/bin/env bash
# detect-skill-cache-staleness.sh — decide whether the INSTALLED shipyard
# skill cache (installed_plugins.json's shipyard@shipyard installPath) is at
# a different .claude-plugin/plugin.json version than a given git ref.
#
# Background (issue #1319)
# -------------------------
# A dispatched worker's `Skill` tool loads `shipyard:worker-preamble` (and
# every fragment) by NAME — the harness resolves that against
# installed_plugins.json's cache path, entirely independent of
# CLAUDE_PLUGIN_ROOT. On the dogfooding repo (CLAUDE_PLUGIN_ROOT resolves
# repo-local), CLAUDE_PLUGIN_ROOT being fresh says nothing about whether
# this SEPARATE cache is also fresh — it has its own update cadence
# (`/shipyard:update`). A real session observed the cache pinned to 4.32.5
# while origin/main was already at 4.32.7, with nothing surfacing it.
#
# `00-config-worktree.md` step 0.4 calls this rather than inlining the
# check — same anti-drift rationale as `detect-ungated-admin-direct-merge.sh`
# (#716), plus it keeps the markdown file under its byte-budget cap
# (`setup-phase-file-token-budget.test.sh`).
#
# Usage
#   detect-skill-cache-staleness.sh <default-branch>
#
# <default-branch> is the repo's default branch name (e.g. "main"); the
# comparison is against `origin/<default-branch>`'s plugin.json, which the
# caller is expected to have already `git fetch`ed. Pass "" (or omit) when
# no default branch was resolved — the script degrades to "fresh" rather
# than erroring, since there's nothing to compare against.
#
# Output (stdout, single line)
#   fresh                        versions match, or a comparison side
#                                 couldn't be resolved (no false positive)
#   stale:<cache-ver> (installed cache) vs <repo-ver> (origin/<branch>)
#                                 versions differ
#
# Diagnostics (the resolved cache version, unconditionally) on stderr.
set -u

DEFAULT_BRANCH="${1:-}"

CACHE_PATH=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null)
CACHE_VERSION=""
if [ -n "$CACHE_PATH" ] && [ -f "$CACHE_PATH/.claude-plugin/plugin.json" ]; then
  CACHE_VERSION=$(jq -r '.version // empty' "$CACHE_PATH/.claude-plugin/plugin.json" 2>/dev/null)
fi

REPO_VERSION=""
if [ -n "$DEFAULT_BRANCH" ]; then
  REPO_VERSION=$(git show "origin/$DEFAULT_BRANCH:plugins/shipyard/.claude-plugin/plugin.json" 2>/dev/null | jq -r '.version // empty')
fi

echo "resolved skill-cache version=${CACHE_VERSION:-unknown} installPath=${CACHE_PATH:-none} vs origin/${DEFAULT_BRANCH:-unknown}=${REPO_VERSION:-unknown}" >&2

if [ -n "$CACHE_VERSION" ] && [ -n "$REPO_VERSION" ] && [ "$CACHE_VERSION" != "$REPO_VERSION" ]; then
  echo "stale:$CACHE_VERSION (installed cache) vs $REPO_VERSION (origin/$DEFAULT_BRANCH)"
else
  echo "fresh"
fi

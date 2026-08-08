#!/usr/bin/env bash
# detect-stale-node-modules.sh — decide whether a worker's Node checkout has
# a `node_modules/` that no longer satisfies the checked-out `package.json`
# (issue #1138 — a recycled worktree slot).
#
# Background (issue #1138)
# -------------------------
# `/shipyard:do-work` reuses worker worktree slots across dispatches. A
# recycled slot's checkout moves onto a new branch/commit via
# `git checkout -B`, but nothing re-installs `node_modules/` — it's whatever
# was there from the slot's PREVIOUS occupant. When the newly-checked-out
# `package.json` added, removed, or changed a dependency since that install,
# the worker starts in a tree whose installed deps don't satisfy its own
# manifest.
#
# This is a DIFFERENT failure from "node_modules is simply missing" (the
# existing check in worker-preamble's node-bootstrap.md fragment) — a stale
# `node_modules/` DOES exist, so a bare `[ -d node_modules ]` presence check
# passes cleanly and the gap goes undetected until a pre-push hook fails with
# a confusing "cannot resolve module" error that looks unrelated to the
# actual cause (confirmed repro: `mattsears18/lightwork` session
# `do-work-20260807T202400Z` — four independent agents hit the same
# `expo-location` unresolved-import failure and initially misdiagnosed it as
# a lint false positive, per the issue's repro section).
#
# Two independent concerns, split so the DECISION LOGIC is unit-testable
# without a live `npm` call — same shape as detect-ungated-admin-direct-merge.sh's
# and detect-missing-workflow-scope.sh's `--decide` mode:
#
#   --decide <package_json_exists:0|1> <node_modules_exists:0|1> <npm_ls_ok:0|1>
#       Pure decision: prints "noop", "missing", "fresh", or "stale". No
#       filesystem or process I/O. This is what the regression test drives.
#
#   <dir>
#       Live mode: checks for `<dir>/package.json` and `<dir>/node_modules`,
#       and — only when both are present — runs `npm ls --depth=0 --silent`
#       inside `<dir>` to decide whether the installed tree still satisfies
#       the manifest (a non-zero exit means a missing, extraneous, or
#       version-mismatched dependency). Prints the same four verdict words to
#       stdout; diagnostics go to stderr.
#
# Verdicts and what a caller should do with each:
#   noop    — no package.json at <dir>; not a Node project at this path.
#             Ecosystem-tolerant no-op — do nothing.
#   missing — package.json present, node_modules/ absent entirely. This is
#             the PRE-EXISTING gap worker-preamble's node-bootstrap.md
#             fragment already covers (symlink -> cp -al -> npm ci ladder).
#   fresh   — node_modules/ present and satisfies package.json. Proceed.
#   stale   — node_modules/ present but does NOT satisfy package.json (the
#             #1138 case). Caller should run a real install (`npm ci`) and
#             then clear the ESLint cache — see worker-preamble's
#             node-bootstrap.md "Stale node_modules on a recycled worktree
#             slot" section for why the cache clear matters (it keys on file
#             content/mtime, not dependency resolution, so it survives a
#             correct reinstall and can still report a stale error).
#
# Usage: `shipyard:worker-preamble`'s node-bootstrap.md fragment, invoked by
# every worker mode that bootstraps Node deps before testing/pushing.
set -u

decide() {
  local pkg="$1" nm="$2" npm_ls_ok="$3"
  if [[ "$pkg" != "1" ]]; then
    echo "noop"
    return
  fi
  if [[ "$nm" != "1" ]]; then
    echo "missing"
    return
  fi
  if [[ "$npm_ls_ok" == "1" ]]; then
    echo "fresh"
  else
    echo "stale"
  fi
}

if [[ "${1:-}" == "--decide" ]]; then
  decide "${2:-0}" "${3:-0}" "${4:-0}"
  exit 0
fi

DIR="${1:-.}"

if [[ ! -f "$DIR/package.json" ]]; then
  echo "package.json=absent dir=$DIR -> noop" >&2
  echo "noop"
  exit 0
fi

if [[ ! -d "$DIR/node_modules" ]]; then
  echo "package.json=present node_modules=absent dir=$DIR -> missing" >&2
  echo "missing"
  exit 0
fi

# Only run npm when both are present — this is the freshness check itself.
# `npm ls --depth=0` exits non-zero on a missing, extraneous, or
# version-mismatched direct dependency; --silent suppresses its (irrelevant
# to us) stdout tree output.
if (cd "$DIR" && npm ls --depth=0 --silent >/dev/null 2>&1); then
  echo "package.json=present node_modules=present npm_ls=ok dir=$DIR -> fresh" >&2
  echo "fresh"
else
  echo "package.json=present node_modules=present npm_ls=failed dir=$DIR -> stale" >&2
  echo "stale"
fi

#!/usr/bin/env bash
# lib/common.sh — shared helpers for plugins/shipyard/scripts/*.sh.
#
# Background (issue #887): three small pieces of logic were re-implemented,
# byte-for-byte identically, across a large fraction of this directory's
# scripts because there was nowhere shared to put them:
#
#   - `${SHIPYARD_HOME:-$HOME/.shipyard}` path resolution — open-coded in
#     session-state.sh, cost-history.sh, flake-registry.sh, gh-cached.sh,
#     eas-watch.sh, worktree-reap.sh (x3), status.sh, setup-timing.sh, and
#     report-plugin-error.sh.
#   - The `command -v jq` dependency guard — duplicated across 8 of the
#     scripts that shell out to jq.
#   - The mktemp-then-rename atomic-write helper (with the issue #357
#     empty-tempfile guard) — reimplemented, with drifting levels of
#     defensiveness, in session-state.sh, shipyard-config.sh, gh-cached.sh,
#     and eas-watch.sh.
#
# This file is a **library, not an entry point** — it defines functions only
# and is meant to be `source`d, never executed directly. A caller sources it
# like this, right after `set -u` (and before the first call to any of the
# three functions below):
#
#   set -u
#   # shellcheck source=lib/common.sh disable=SC1091
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
# Resolving the directory via `${BASH_SOURCE[0]}` (not a hardcoded path)
# means this works identically whether the caller is invoked from the
# installed plugin path, a test suite (`bash scripts/tests/foo.test.sh`
# invokes `scripts/foo.sh` directly, never a copy), or a dev checkout.
#
# No behavior change for any existing caller (see each function's own
# comment for the specific script(s) its logic was extracted from
# byte-for-byte) — this file only gives the already-identical logic one
# place to live.

# --------------------------------------------------------------------------
# shipyard_home — base directory for shipyard's per-user, cross-session
# state (session files, cost ledger, flake registry, gh-cached cache dirs,
# reap-audit log, EAS build-watch state, autoreport-failure log).
#
# Extracted byte-for-byte from cost-history.sh / flake-registry.sh /
# setup-timing.sh's identical `shipyard_home()` function (all three already
# used this exact name and body — see flake-registry.sh's own "mirrors
# cost-history.sh" comment). Every other caller open-coded the same
# expression inline (`${SHIPYARD_HOME:-$HOME/.shipyard}` or the
# `${SHIPYARD_HOME:-${HOME}/.shipyard}` brace-quoted variant — functionally
# identical) and is migrated to call this instead.
# --------------------------------------------------------------------------
shipyard_home() {
  printf '%s\n' "${SHIPYARD_HOME:-${HOME}/.shipyard}"
}

# --------------------------------------------------------------------------
# require_jq [script_name] — hard-fail if jq isn't on PATH.
#
# Extracted byte-for-byte from the identical `if ! command -v jq
# >/dev/null 2>&1; then echo "<script>: jq is required but not installed"
# >&2; exit 65; fi` block duplicated at the top of cost-history.sh,
# eas-watch.sh, flake-enforce.sh, flake-registry.sh, session-state.sh,
# setup-timing.sh, shipyard-config.sh, and status.sh.
#
# `script_name` defaults to `$(basename "$0")` — the invoking script's own
# name, NOT this library file's — so a caller can just write `require_jq`
# with no argument and get the exact same "<script>.sh: jq is required..."
# wording it always printed. Exits 65 (the plugin-wide "internal helper
# failure" band every one of these scripts already documents in its own
# usage/exit-codes header).
# --------------------------------------------------------------------------
require_jq() {
  local script_name="${1:-$(basename "$0")}"
  if ! command -v jq >/dev/null 2>&1; then
    echo "${script_name}: jq is required but not installed" >&2
    exit 65
  fi
}

# --------------------------------------------------------------------------
# atomic_write <target> — read content from stdin, write it to <target>
# atomically via a same-directory tempfile + rename.
#
# POSIX rename(2) is atomic on the same filesystem, which placing the
# tempfile alongside the target (`<target>.tmp.$$`) guarantees. A crash
# mid-write leaves only the tempfile behind; the previous target (if any)
# is untouched until the rename succeeds.
#
# Empty-write guard (issue #357, originally session-state.sh only). A
# producer upstream of a pipe — `jq ... | atomic_write "$target"` — can
# fail silently: no stdout, non-zero exit, but the pipeline's OWN exit
# status (absent `set -o pipefail`) is atomic_write's, which is 0 because
# `cat` happily reads EOF from a closed pipe. Without this guard, `cat >
# "$tmp"` would create a 0-byte tempfile and the unchecked `mv` would then
# rename it over the target, silently truncating whatever was there.
# Refuse that: a 0-byte tempfile is never a valid write for any of this
# plugin's persisted JSON, so leave the target untouched and return
# non-zero (the caller's `if ! jq ... | atomic_write` branch sees it).
#
# This is the most defensive of the four near-identical implementations
# this function replaces (session-state.sh had the 0-byte guard;
# shipyard-config.sh, gh-cached.sh, and eas-watch.sh's own copies did not,
# though the first two already used the identical 66/67 return-code split
# and shipyard-config.test.sh's issue-#871 regression test already locks
# that contract in). Adopting the strictly-more-defensive version
# everywhere is not a behavior change on the success path — it only adds a
# guard against a destructive failure mode the less-defensive copies were
# silently exposed to.
#
# Return codes (issue #871's shipyard-config.test.sh regression test pins
# these — do not renumber):
#   66  tempfile write failed, or upstream produced a 0-byte tempfile
#   67  rename (mv) failed
# --------------------------------------------------------------------------
atomic_write() {
  local target="$1"
  local script_name="${2:-$(basename "$0")}"
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir"
  local tmp="${target}.tmp.$$"
  # shellcheck disable=SC2064
  # rationale: capture the current $tmp value, not deferred expansion — the
  # variable is reused across calls in a long-running script.
  trap "rm -f '$tmp'" EXIT
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    trap - EXIT
    echo "${script_name}: failed to write tmp file $tmp" >&2
    return 66
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    trap - EXIT
    echo "${script_name}: refusing to rename empty tempfile over $target (upstream produced no content — likely jq error)" >&2
    return 66
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    trap - EXIT
    echo "${script_name}: failed to rename $tmp -> $target" >&2
    return 67
  fi
  trap - EXIT
}

# --------------------------------------------------------------------------
# sessions_dir — directory holding the per-session state files written by
# the `/do-work` orchestrator (`<session-id>.json`).
#
# Lives here rather than in status.sh (its current sole consumer) so any
# future reader of the session files resolves the path the same way instead
# of open-coding it a second time.
# --------------------------------------------------------------------------
sessions_dir() {
  local home
  home=$(shipyard_home)
  printf '%s/sessions\n' "$home"
}

# --------------------------------------------------------------------------
# iso_to_epoch <timestamp> — parse an ISO-8601 UTC timestamp into epoch
# seconds, printing `0` for empty / null / unparseable input.
#
# macOS BSD date and GNU date disagree on the input flag (`-j -f` vs `-d`),
# so both are tried in turn.
#
# Printing `0` rather than failing is deliberate and load-bearing: a session
# file with a malformed timestamp should degrade to "epoch zero, therefore
# very old" and stay visible, not abort the whole dashboard render.
# --------------------------------------------------------------------------
iso_to_epoch() {
  local ts="$1"
  if [[ -z "$ts" || "$ts" == "null" ]]; then
    printf '0\n'
    return
  fi
  # Strip the trailing Z so both `date` variants accept the format.
  local stripped="${ts%Z}"
  # GNU date (Linux).
  local epoch
  epoch=$(date -u -d "$stripped" +%s 2>/dev/null || true)
  if [[ -z "$epoch" ]]; then
    # BSD date (macOS).
    epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null || true)
  fi
  if [[ -z "$epoch" ]]; then
    printf '0\n'
  else
    printf '%s\n' "$epoch"
  fi
}

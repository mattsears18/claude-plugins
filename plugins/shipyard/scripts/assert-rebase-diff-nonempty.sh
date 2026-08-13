#!/usr/bin/env bash
# assert-rebase-diff-nonempty.sh — assert a rebase did not collapse a PR's net
# contribution to an empty diff vs base.
#
# This is the guard behind fix-rebase.md's step 5.7 (issue #646): a conflict
# resolution that silently discards the PR's entire substantive change leaves
# the branch with an empty diff vs base, and force-pushing that state makes
# GitHub auto-close the PR — with no error signal at all. The check compares
# the PR's net contribution vs base BEFORE the rebase (the pre-rebase head,
# still pointed at by `origin/<head-ref>` until the force-push) against the
# same net contribution AFTER (the rebased local HEAD). Non-empty before and
# empty after means the resolution dropped the change: bail, don't push.
#
# Extracted to a standalone, testable script (issue #1336) for two independent
# reasons, both reproduced firsthand in a worktree-isolated worker session:
#
#   1. THE PRESCRIBED INLINE FORM DOESN'T RUN. The original §5.7 snippet was
#      two `$(git diff ... | wc -l | tr -d ' ')` command substitutions plus an
#      inline `if` in a single Bash tool call. That exact shape — git command
#      substitutions combined with an inline `if` — is deterministically
#      REFUSED by the harness's worktree-isolation Bash guard in an isolated
#      worker session ("this command is too complex to verify that it stays
#      inside the worktree; break it into plain, separate commands"), the same
#      refusal class issue #802 documents. `fix-rebase` workers are ALWAYS
#      worktree-isolated (see hooks/enforce-worktree-isolation.sh's guarded
#      set), so the guard as written could not execute as prescribed.
#
#   2. THE REFUSAL'S OWN REMEDIATION IS THE VULNERABLE SHAPE. Splitting the
#      block into "plain, separate commands" — what the refusal message tells
#      the worker to do — yields a bare `git diff --name-only <refs> | wc -l`
#      as the entirety of one Bash call, which is exactly the invocation shape
#      a diff-rewriting shell proxy (e.g. `rtk`, "Rust Token Killer") rewrites
#      (issue #1333). Measured: against a genuinely-empty diff the rewritten
#      output is a single `\n` byte, so `wc -l` returns 1, not 0 — and the
#      `POST_FILES == 0` bail can then NEVER fire, silently disabling this
#      guard for precisely the case it exists to catch. Against a non-empty
#      diff the same shape returned 9 for a true count of 6 (the proxy appends
#      a blank line, a `Changes:` header, and another blank line).
#
# Running the comparison as one plain `bash <script>` invocation fixes both: a
# single script call is a plain command the isolation guard accepts, and the
# script's internal `git diff` calls run in a separate process that the proxy
# does not rewrite (measured: 0 lines / 0 bytes for an empty diff, 6 for a
# genuine 6-file diff, from inside a script — vs 1 and 9 for the same two
# comparisons issued as isolated top-level Bash calls).
#
# Belt-and-braces, this script additionally does NOT trust its own `git diff`
# output blindly (same posture as verify-added-lines-survived.sh, issue #1175):
#
#   * It writes each `git diff --name-only` result to a temp FILE rather than
#     capturing it through a pipeline or a `$(...)` substitution. A file
#     redirect preserves the exact bytes (a `$(...)` capture strips trailing
#     newlines, which would erase the very artifact that distinguishes a
#     rewritten empty result from a genuinely empty one) and was separately
#     observed not to be rewritten by the proxy.
#   * It shape-checks every result: genuine `git diff --name-only` output is a
#     newline-terminated list of non-empty path lines and NEVER contains a
#     blank or whitespace-only line. Any blank line means the output is not
#     real `--name-only` output — fail loud (exit 2) rather than count it.
#   * It runs an environment self-check first: `git diff --name-only <base>
#     <base>` (a ref against itself) MUST produce a zero-byte result. If this
#     environment can't even get that right, no verdict from it is trustworthy.
#
# Usage:
#   assert-rebase-diff-nonempty.sh <base-ref> <pre-rebase-head-ref> [post-rebase-rev]
#
# <base-ref>            the branch being rebased onto, e.g. `origin/main`.
# <pre-rebase-head-ref> the PR's pre-rebase head, e.g. `origin/<head-branch>`
#                       (untouched until the force-push, so it is the "before"
#                       baseline).
# [post-rebase-rev]     the rebased result to check; defaults to `HEAD`.
#
# Must be run with $PWD inside the git working tree holding the rebased result.
#
# Exit status:
#   0 — safe to push. stdout: `OK: pre=<n> post=<n> ...`
#   1 — the rebase collapsed the PR's change to an empty diff vs base. stdout:
#       `EMPTY_DIFF: ...`. The caller MUST `git rebase --abort` and bail
#       instead of force-pushing.
#   2 — could not establish a result (bad usage, unresolvable ref, a failed
#       `git diff`, the self-check failed, or output that doesn't look like
#       real `--name-only` output). stderr carries `INDETERMINATE: <reason>`.
#       Treat exactly like exit 1 — never treat a 2 as a clean pass.

set -u
export LC_ALL=C

die_indeterminate() {
  echo "INDETERMINATE: $1" >&2
  exit 2
}

for tool in git awk mktemp; do
  command -v "$tool" >/dev/null 2>&1 \
    || die_indeterminate "required tool '$tool' not found on PATH"
done

BASE_REF="${1:-}"
PRE_HEAD_REF="${2:-}"
POST_REV="${3:-HEAD}"

if [ -z "$BASE_REF" ] || [ -z "$PRE_HEAD_REF" ]; then
  die_indeterminate "usage: assert-rebase-diff-nonempty.sh <base-ref> <pre-rebase-head-ref> [post-rebase-rev]"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die_indeterminate "not inside a git working tree"

for ref in "$BASE_REF" "$PRE_HEAD_REF" "$POST_REV"; do
  git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null \
    || die_indeterminate "cannot resolve ref '$ref'"
done

TMPDIR_SELF=$(mktemp -d) || die_indeterminate "mktemp -d failed"
# shellcheck disable=SC2064  # expand TMPDIR_SELF now, not at trap time.
trap "rm -rf '$TMPDIR_SELF'" EXIT

# Write `git diff --name-only <args...>` to $1, byte-exact (a redirect, never a
# pipeline or a `$(...)` capture — see the file header for why both of those
# would destroy the evidence this script relies on).
diff_name_only_to() {
  local out="$1"; shift
  git diff --name-only "$@" >"$out" 2>/dev/null
}

# Genuine `git diff --name-only` output is a newline-terminated list of
# non-empty path lines. Exit 0 if $1 contains a blank/whitespace-only line
# (i.e. the output is NOT real --name-only output), 1 otherwise.
has_blank_line() {
  awk '!NF { found = 1 } END { exit(found ? 0 : 1) }' "$1"
}

# Number of path lines in a shape-verified --name-only result.
count_lines() {
  awk 'END { print NR + 0 }' "$1"
}

# --- Environment self-check: a ref diffed against ITSELF must produce a
# zero-byte result. This directly probes the corruption mode this script
# exists to be robust against (issue #1336): under a diff-rewriting proxy the
# same comparison comes back as a single newline, which any line-counting
# consumer reads as 1. Fail loud rather than emit a verdict from a `git diff`
# this environment demonstrably cannot be trusted to produce. ---
if ! diff_name_only_to "$TMPDIR_SELF/selfcheck" "$BASE_REF" "$BASE_REF"; then
  die_indeterminate "self-check: 'git diff --name-only $BASE_REF $BASE_REF' failed"
fi
if [ -s "$TMPDIR_SELF/selfcheck" ]; then
  die_indeterminate "self-check failed — 'git diff --name-only $BASE_REF $BASE_REF' (a ref against itself) produced non-empty output, so this environment's git diff cannot be trusted for an emptiness comparison; a diff-rewriting shell proxy (e.g. rtk) may be active (see https://github.com/mattsears18/shipyard/issues/1336)"
fi

# --- Real comparison ---
# Pre-rebase net contribution: the three-dot form asks "what did the PR's head
# add relative to where it diverged from base", which is the PR's own change
# even though origin/<head> has not yet been rebased onto the current base.
if ! diff_name_only_to "$TMPDIR_SELF/pre" "${BASE_REF}...${PRE_HEAD_REF}"; then
  die_indeterminate "'git diff --name-only ${BASE_REF}...${PRE_HEAD_REF}' failed"
fi
# Post-rebase net contribution: the rebased HEAD sits directly on base, so the
# two-dot form IS its net contribution.
if ! diff_name_only_to "$TMPDIR_SELF/post" "$BASE_REF" "$POST_REV"; then
  die_indeterminate "'git diff --name-only $BASE_REF $POST_REV' failed"
fi

for side in pre post; do
  if has_blank_line "$TMPDIR_SELF/$side"; then
    die_indeterminate "the ${side}-rebase 'git diff --name-only' output contains a blank line, so it is not real --name-only output (which is a list of non-empty path lines); a diff-rewriting shell proxy (e.g. rtk) may be active — bypass it (e.g. 'rtk proxy git diff ...') before retrying (see https://github.com/mattsears18/shipyard/issues/1336)"
  fi
done

PRE_FILES=$(count_lines "$TMPDIR_SELF/pre")
POST_FILES=$(count_lines "$TMPDIR_SELF/post")

if [ "$PRE_FILES" -gt 0 ] && [ "$POST_FILES" -eq 0 ]; then
  echo "EMPTY_DIFF: pre=$PRE_FILES post=0 — the rebase collapsed the PR's net contribution vs $BASE_REF to an empty diff; do NOT force-push (see https://github.com/mattsears18/shipyard/issues/646)"
  exit 1
fi

echo "OK: pre=$PRE_FILES post=$POST_FILES — net contribution vs $BASE_REF survived the rebase"
exit 0

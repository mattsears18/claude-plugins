#!/usr/bin/env bash
# assert-worktree-change-present.sh — assert an implementation actually
# produced a change, before a worker opens a PR that claims one.
#
# This is the guard behind issue-work.md's step 4.5 and spike.md's step 7.5
# (issue #356, the phantom-merge failure mode): a worker can reach the end of
# implementation with nothing to show for it and still proceed to open a PR
# whose body claims substantive scope. The PR merges, its `Closes #N` keyword
# closes the linked issue, and the backlog claims work shipped — but nothing
# landed. The check has two parts: (1) is there a committed diff vs the
# default branch, and if not, (2) is there at least uncommitted working-tree
# change (rare, but a worker might edit files without staging them). Only
# when BOTH are empty is the implementation genuinely a no-op.
#
# Extracted to a standalone, testable script (issue #1340, following the same
# extraction assert-rebase-diff-nonempty.sh did for issue #1336) for two
# independent, reproduced reasons — and a THIRD one specific to this guard's
# second check that #1336/#1341 didn't have to handle:
#
#   1. THE PRESCRIBED INLINE FORM DOESN'T RUN. The original snippet was two
#      `$(git ... | wc -l | tr -d ' ')` command substitutions plus a NESTED
#      inline `if` (this guard's block is even larger than fix-rebase's
#      §5.7 — it wraps both the reaped-escape-hatch preamble and two nested
#      ifs) in a single Bash tool call. That shape — git command
#      substitutions combined with an inline `if` — is deterministically
#      REFUSED by the harness's worktree-isolation Bash guard in an isolated
#      worker session ("too complex to verify that it stays inside the
#      worktree; break it into plain, separate commands"), the #802 refusal
#      class. `issue-work` and `spike` workers are ALWAYS worktree-isolated
#      (see hooks/enforce-worktree-isolation.sh's guarded set), so the guard
#      as written could not execute as prescribed. Reproduced firsthand
#      against the exact block in issue-work.md §4.5.
#
#   2. THE REFUSAL'S OWN REMEDIATION OVER-COUNTS THE FIRST CHECK. Splitting
#      into "plain, separate commands" yields a bare
#      `git diff --name-only <refs> | wc -l` as the entirety of one Bash
#      call — the shape a diff-rewriting shell proxy (e.g. `rtk`) rewrites
#      (issue #1333). Measured firsthand in this session: a genuinely-empty
#      diff comes back as a single `\n` byte, so `wc -l` returns 1, not 0 —
#      the `CHANGED_FILES == 0` bail can then never fire.
#
#   3. THE SAME REMEDIATION *UNDER*-COUNTS THE SECOND CHECK — THE OPPOSITE
#      DIRECTION. `git status --porcelain | wc -l` is corrupted the OTHER
#      way: measured firsthand in this session, the proxy strips the
#      trailing newline from the raw output (a 2-line dirty status came back
#      missing the final line's terminator), so `wc -l` UNDER-counts by one.
#      A single genuinely-dirty file reads as zero. This is NOT the same
#      correction as (2) — a fix that only guards against over-counting
#      would leave this direction wide open, and vice versa. Each of this
#      script's two checks needs its own, direction-specific defense.
#
# Running both comparisons as one plain `bash <script>` invocation fixes (1)
# and (2)/(3) together: a single script call is a plain command the isolation
# guard accepts, and the script's internal `git` calls run in a separate
# process the proxy does not rewrite (measured firsthand: correct counts on
# both `git diff --name-only` and `git status --porcelain` from inside a
# script, vs corrupted counts for the identical calls issued as isolated
# top-level Bash calls).
#
# Belt-and-braces, this script additionally does NOT trust its own git output
# blindly (same posture as assert-rebase-diff-nonempty.sh / issue #1175):
#
#   * Every result is written to a temp FILE rather than captured through a
#     pipeline or a `$(...)` substitution — a capture strips exactly the
#     trailing-newline evidence that distinguishes a rewritten result from a
#     genuine one.
#   * The `--name-only` check runs an environment self-check first
#     (`git diff --name-only <base> <base>`, a ref against itself, MUST be
#     zero bytes) and shape-checks its real result for a blank line (genuine
#     `--name-only` output is a list of non-empty path lines and never
#     contains one) — the over-counting direction (2).
#   * The `--porcelain` check verifies its result, when non-empty, ends in a
#     trailing newline — genuine `git status --porcelain` output always
#     newline-terminates every line including the last, so a non-empty
#     result NOT ending in a newline is exactly the corruption signature
#     measured in (3) and is never trusted as a real count.
#
# Usage:
#   assert-worktree-change-present.sh <base-ref> [post-rev]
#
# <base-ref>   the default branch to diff against, e.g. `origin/main`
#              (already fetched by the caller).
# [post-rev]   the revision to check for a committed diff vs <base-ref>;
#              defaults to `HEAD`.
#
# Must be run with $PWD inside the git working tree being checked.
#
# Exit status:
#   0 — a real change exists (committed and/or uncommitted). stdout:
#       `OK: committed=<n> working-tree-dirty=<n> ...`
#   1 — no change at all: the committed diff vs <base-ref> is empty AND the
#       working tree is clean. stdout: `EMPTY_DIFF: ...`. The caller MUST
#       bail (`blocked:`) rather than open a PR.
#   2 — could not establish a trustworthy result (bad usage, unresolvable
#       ref, a failed `git` call, the self-check failed, or output that
#       doesn't look like real output for its command). stderr carries
#       `INDETERMINATE: <reason>`. Treat exactly like exit 1 — never treat a
#       2 as a clean pass.

set -u
export LC_ALL=C

die_indeterminate() {
  echo "INDETERMINATE: $1" >&2
  exit 2
}

for tool in git awk mktemp tail; do
  command -v "$tool" >/dev/null 2>&1 \
    || die_indeterminate "required tool '$tool' not found on PATH"
done

BASE_REF="${1:-}"
POST_REV="${2:-HEAD}"

if [ -z "$BASE_REF" ]; then
  die_indeterminate "usage: assert-worktree-change-present.sh <base-ref> [post-rev]"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die_indeterminate "not inside a git working tree"

for ref in "$BASE_REF" "$POST_REV"; do
  git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null \
    || die_indeterminate "cannot resolve ref '$ref'"
done

TMPDIR_SELF=$(mktemp -d) || die_indeterminate "mktemp -d failed"
# shellcheck disable=SC2064  # expand TMPDIR_SELF now, not at trap time.
trap "rm -rf '$TMPDIR_SELF'" EXIT

# Write `git diff --name-only <arg>` to $2, byte-exact (a redirect, never a
# pipeline or a `$(...)` capture — see the file header for why).
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

# Number of path lines in a shape-verified result file.
count_lines() {
  awk 'END { print NR + 0 }' "$1"
}

# Exit 0 (true) if $1 is non-empty AND its last byte is NOT a newline — the
# exact corruption signature measured for `git status --porcelain` under a
# rewriting proxy (the trailing newline of the last line is stripped).
missing_trailing_newline() {
  [ -s "$1" ] || return 1
  last_byte="$(tail -c 1 "$1")"
  [ -n "$last_byte" ]
}

# --- Environment self-check for the --name-only comparison: a ref diffed
# against ITSELF must produce a zero-byte result. Directly probes the
# over-counting corruption mode (issue #1336/#1340): under a diff-rewriting
# proxy the same comparison comes back as a single newline, which any
# line-counting consumer reads as 1. Fail loud rather than emit a verdict
# from a `git diff` this environment demonstrably cannot be trusted for. ---
if ! diff_name_only_to "$TMPDIR_SELF/selfcheck" "${BASE_REF}...${BASE_REF}"; then
  die_indeterminate "self-check: 'git diff --name-only ${BASE_REF}...${BASE_REF}' failed"
fi
if [ -s "$TMPDIR_SELF/selfcheck" ]; then
  die_indeterminate "self-check failed — 'git diff --name-only ${BASE_REF}...${BASE_REF}' (a ref against itself) produced non-empty output, so this environment's git diff cannot be trusted for an emptiness comparison; a diff-rewriting shell proxy (e.g. rtk) may be active (see https://github.com/mattsears18/shipyard/issues/1336)"
fi

# --- Check 1: committed diff vs base ---
if ! diff_name_only_to "$TMPDIR_SELF/committed" "${BASE_REF}...${POST_REV}"; then
  die_indeterminate "'git diff --name-only ${BASE_REF}...${POST_REV}' failed"
fi
if has_blank_line "$TMPDIR_SELF/committed"; then
  die_indeterminate "'git diff --name-only ${BASE_REF}...${POST_REV}' output contains a blank line, so it is not real --name-only output (which is a list of non-empty path lines); a diff-rewriting shell proxy (e.g. rtk) may be active — bypass it (e.g. 'rtk proxy git diff ...') before retrying (see https://github.com/mattsears18/shipyard/issues/1336)"
fi
COMMITTED_FILES=$(count_lines "$TMPDIR_SELF/committed")

if [ "$COMMITTED_FILES" -gt 0 ]; then
  echo "OK: committed=$COMMITTED_FILES working-tree-dirty=(not checked — committed diff already non-empty) — a real change exists vs $BASE_REF"
  exit 0
fi

# --- Check 2: uncommitted working-tree change (only reached when the
# committed diff is empty) ---
if ! git status --porcelain >"$TMPDIR_SELF/status" 2>/dev/null; then
  die_indeterminate "'git status --porcelain' failed"
fi
if missing_trailing_newline "$TMPDIR_SELF/status"; then
  die_indeterminate "'git status --porcelain' output does not end in a newline despite being non-empty; genuine porcelain output always newline-terminates every line including the last, so this is the under-counting corruption signature — a rewriting shell proxy (e.g. rtk) may be active (see https://github.com/mattsears18/shipyard/issues/1340)"
fi
WORKING_TREE_DIRTY=$(count_lines "$TMPDIR_SELF/status")

if [ "$WORKING_TREE_DIRTY" -gt 0 ]; then
  echo "OK: committed=0 working-tree-dirty=$WORKING_TREE_DIRTY — no committed diff vs $BASE_REF, but uncommitted working-tree changes exist"
  exit 0
fi

echo "EMPTY_DIFF: committed=0 working-tree-dirty=0 — no committed diff vs $BASE_REF and a clean working tree; the implementation produced no changes"
exit 1

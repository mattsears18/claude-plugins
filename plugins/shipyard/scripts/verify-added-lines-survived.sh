#!/usr/bin/env bash
# verify-added-lines-survived.sh — assert every line a PR's own commit(s)
# added (relative to a merge-base ref) is still present verbatim, somewhere,
# in the current working tree's copy of each file the PR touched.
#
# This is the guard behind fix-rebase.md's step 5.8 (issue #983): a `git
# rebase` can report a clean "Auto-merging <file>" — zero conflict markers —
# while still silently splicing content from the wrong diff hunk. This
# happens most readily in a file with high internal repetition (many
# structurally-identical blocks) combined with a large line-offset shift on
# the branch being rebased onto: diff3/patience matching can mismatch
# context anchors and merge a hunk against the wrong twin. The result is a
# file that is textually well-formed (no markers, non-empty) but
# semantically wrong.
#
# Extracted to a standalone, testable script (issue #1175) because the
# original inline shell snippet (`grep -vFxf "$f" <<<"$ADDED_LINES"`,
# re-typed directly into the worker's own interactive Bash-tool shell) was
# found to silently false-negative in at least one live worker environment:
# that shell's `grep` is shadowed by a function wrapping `ugrep` (Claude
# Code's own read-tool integration), and the shadowed command reported "no
# missing lines" for files that a direct exact-line comparison showed DID
# have missing lines. A worker that trusted that verdict would have shipped
# corrupted content with no signal at all — the exact failure this guard
# exists to prevent. Invoking this logic as `bash <script>` (a genuinely
# separate process, not a function defined in the calling shell) already
# sidesteps that specific shadowing mechanism; this script additionally:
#
#   1. Never calls `grep` for the exact-line-survival comparison itself — it
#      uses `sort` + `comm` (a set difference over sorted, deduplicated line
#      sets) instead, so a verdict never depends on any `grep`
#      implementation's flag semantics. The trivial diff-marker stripping
#      ('+' prefix, drop the '+++' file-header line, drop blank lines) is
#      done with `awk`, not `grep`, for the same reason.
#   2. Fails LOUD, not open, when it cannot trust its own result. Before
#      scanning any real file, it runs a synthetic self-check that MUST
#      detect a deliberately-missing line and MUST NOT flag identical sets
#      as mismatched. If either assertion doesn't hold, the comparison
#      mechanism itself is untrustworthy in this environment and the script
#      exits 2 (indeterminate) rather than 0 (clean) — a clean verdict is
#      only ever returned once the self-check has proven the mechanism
#      actually works here.
#
# Usage:
#   verify-added-lines-survived.sh <merge-base-ref> <head-ref>
#
# Must be run with $PWD inside the git working tree whose CURRENT state (the
# post-rebase result being verified) is on disk — the "final" side of the
# comparison reads $PWD's on-disk files, not any git ref. <head-ref> is the
# PRE-rebase head (e.g. `origin/$HEAD_REF`, untouched until the force-push);
# <merge-base-ref> is typically `git merge-base <head-ref> <base-ref>`.
#
# Exit status:
#   0 — verified clean: every line <head-ref>'s own commits added (relative
#       to <merge-base-ref>) is present verbatim in the working tree.
#   1 — corruption detected: stdout is `CORRUPTED:<space-separated files>`
#       (a file suffixed `(missing)` was deleted entirely from the working
#       tree despite <head-ref> having kept/added it).
#   2 — could not establish a result — bad usage, an unresolvable ref, a
#       missing required tool, or the self-check failed. Treat exactly like
#       exit 1 (bail, do not push) — never treat a 2 as a clean pass. stderr
#       carries an `INDETERMINATE: <reason>` line.

set -u
export LC_ALL=C

die_indeterminate() {
  echo "INDETERMINATE: $1" >&2
  exit 2
}

for tool in git awk sort comm; do
  command -v "$tool" >/dev/null 2>&1 || die_indeterminate "required tool '$tool' not found on PATH"
done

MERGE_BASE="${1:-}"
HEAD_REF="${2:-}"

if [ -z "$MERGE_BASE" ] || [ -z "$HEAD_REF" ]; then
  die_indeterminate "usage: verify-added-lines-survived.sh <merge-base-ref> <head-ref>"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die_indeterminate "not inside a git working tree"
git rev-parse --verify --quiet "${MERGE_BASE}^{commit}" >/dev/null \
  || die_indeterminate "cannot resolve merge-base ref '$MERGE_BASE'"
git rev-parse --verify --quiet "${HEAD_REF}^{commit}" >/dev/null \
  || die_indeterminate "cannot resolve head ref '$HEAD_REF'"

# Set-membership test: which lines of $1 (newline-delimited string) are
# ABSENT, as a whole line, from $2 (newline-delimited string)? Prints the
# missing lines (possibly empty). Pure sort+comm — no grep, no per-line loop.
missing_lines() {
  local needles="$1" haystack="$2"
  comm -23 \
    <(printf '%s' "$needles" | sort -u) \
    <(printf '%s' "$haystack" | sort -u)
}

# --- Self-check: prove the comparison mechanism actually works in THIS
# environment before trusting any verdict it produces on real files. This is
# the "fail loud, not open" half of the fix (issue #1175) — a broken/shadowed
# sort or comm here would otherwise be indistinguishable from a genuinely
# clean file, exactly the failure mode that made the original grep-based
# check dangerous. ---
self_check() {
  local m
  m="$(missing_lines "$(printf 'alpha\nbravo\ncharlie\n')" "$(printf 'alpha\ncharlie\n')")"
  if [ -z "$m" ]; then
    return 1 # should have flagged 'bravo' as missing — did not.
  fi
  m="$(missing_lines "$(printf 'alpha\nbravo\n')" "$(printf 'alpha\nbravo\n')")"
  if [ -n "$m" ]; then
    return 1 # identical sets were false-flagged as mismatched.
  fi
  return 0
}

self_check || die_indeterminate "self-check failed — sort/comm did not correctly detect a synthetic missing line in this environment; refusing to trust a verdict on real files (see https://github.com/mattsears18/shipyard/issues/1175)"

# --- Real comparison ---
PR_TOUCHED_FILES=$(git diff --name-only "$MERGE_BASE" "$HEAD_REF") \
  || die_indeterminate "git diff --name-only $MERGE_BASE $HEAD_REF failed"

CORRUPTED=""

while IFS= read -r f; do
  [ -n "$f" ] || continue

  # The PR itself deleted this file — nothing to verify survived.
  git cat-file -e "${HEAD_REF}:${f}" 2>/dev/null || continue

  # The file no longer exists in the working tree at all — a red flag (the
  # PR kept/added it; the rebase shouldn't have removed it).
  if [ ! -f "$f" ]; then
    CORRUPTED="$CORRUPTED $f(missing)"
    continue
  fi

  # Lines the PR's own commit(s) added, verbatim — strip the diff '+'
  # marker, drop the '+++' file-header line, and skip blank/whitespace-only
  # lines (noise). awk, not grep/sed, for the extraction — see file header.
  ADDED_LINES=$(git diff "$MERGE_BASE" "$HEAD_REF" -- "$f" | awk '
    /^\+\+\+/ { next }
    /^\+/ {
      line = substr($0, 2)
      if (line ~ /[^ \t]/) print line
    }
  ')
  [ -n "$ADDED_LINES" ] || continue

  MISSING=$(missing_lines "$ADDED_LINES" "$(cat -- "$f")")
  if [ -n "$MISSING" ]; then
    CORRUPTED="$CORRUPTED $f"
  fi
done <<<"$PR_TOUCHED_FILES"

if [ -n "$CORRUPTED" ]; then
  echo "CORRUPTED:$CORRUPTED"
  exit 1
fi

FILE_COUNT=$(printf '%s\n' "$PR_TOUCHED_FILES" | awk 'NF{c++} END{print c+0}')
echo "OK: every added line verified present, verbatim, across ${FILE_COUNT} touched file(s)"
exit 0

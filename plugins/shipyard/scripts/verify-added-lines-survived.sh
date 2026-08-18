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
#   verify-added-lines-survived.sh <merge-base-ref> <head-ref> [known-rewrites-file]
#
# Must be run with $PWD inside the git working tree whose CURRENT state (the
# post-rebase result being verified) is on disk — the "final" side of the
# comparison reads $PWD's on-disk files, not any git ref. <head-ref> is the
# PRE-rebase head (e.g. `origin/$HEAD_REF`, untouched until the force-push);
# <merge-base-ref> is typically `git merge-base <head-ref> <base-ref>`.
#
# [known-rewrites-file] (optional, issue #1215; extended #1445): a narrow,
# explicit exemption for content the CALLER already knows it deliberately
# rewrote. Format: TSV, one entry per line, in one of two shapes:
#
#   <path>\t<exact-added-line-text>            (2 fields — "line" exemption)
#   <path>\tFILE\t<free-text reason>           (3 fields — "file" exemption)
#
# Line exemption (2 fields, the original #1215 shape): e.g. fix-rebase.md's
# §4.6 version-coordination carve-out, which intentionally renumbers a
# version-coordinated manifest's `.version` row and the PR's own CHANGELOG
# heading as part of a sanctioned, deterministic conflict resolution. Without
# this, those two lines would ALWAYS read as "corrupted" (they are, by
# construction, no longer verbatim-present) even though the caller can prove
# exactly why. Each entry names one specific line — not a whole file — that
# is exempted from the survival check for that path. This is deliberately
# narrower than exempting the whole file: every OTHER line the PR added to
# that same file (e.g. a CHANGELOG entry's own body lines, left untouched by
# the caller's rewrite) is still checked normally, so real corruption
# elsewhere in a coordinated file is still caught. A path/line pair with no
# matching entry in ADDED_LINES is a harmless no-op (the caller named
# something this script never saw as added) — never a way to loosen the
# check beyond exactly the lines named.
#
# File exemption (3 fields, literal middle field `FILE`, issue #1445): for a
# file whose content is a pure function of the tree — a content-hash
# manifest, a lockfile, a generated type/directory module — a rebase
# conflict on it is correctly resolved by RE-RUNNING THE GENERATOR, not by
# hand-merging (fix-rebase.md step 4's lockfile-and-generated-files bullet).
# Regeneration necessarily replaces the PR's originally-added lines with
# freshly computed ones, which the line-level exemption above cannot express
# (there's no fixed, enumerable "the one line that changed" — potentially
# every line did). A `FILE`-kind entry exempts the WHOLE named path from the
# added-line survival comparison; the third field is a free-text audit
# reason (e.g. "regenerated via node scripts/generate-x.mjs"), never matched
# against anything. This is deliberately still a per-PATH allowlist, not a
# glob or a heuristic: the caller earns the exemption only by having actually
# run the regeneration for that exact path this rebase, so a file the worker
# hand-edited is never silently exempted just because its name looks
# generated. The existence check (a file the PR kept/added must still exist
# post-rebase) still applies to a FILE-exempted path — only the added-line
# content comparison is skipped.
#
# Exit status:
#   0 — verified clean: every line <head-ref>'s own commits added (relative
#       to <merge-base-ref>) is present verbatim in the working tree.
#   1 — corruption detected: stdout is `CORRUPTED:<space-separated files>`
#       (a file suffixed `(missing)` was deleted entirely from the working
#       tree despite <head-ref> having kept/added it).
#   2 — could not establish a result — bad usage, an unresolvable ref, the
#       self-check failed, or a `git diff` invocation's output didn't look
#       like real git-diff output (e.g. a diff-rewriting shell proxy such as
#       `rtk` silently replaced it with a non-standard summary — issue
#       #1333), or a missing required tool. Treat exactly like exit 1 (bail,
#       do not push) — never treat a 2 as a clean pass. stderr carries an
#       `INDETERMINATE: <reason>` line.

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
KNOWN_REWRITES_FILE="${3:-}"

if [ -z "$MERGE_BASE" ] || [ -z "$HEAD_REF" ]; then
  die_indeterminate "usage: verify-added-lines-survived.sh <merge-base-ref> <head-ref> [known-rewrites-file]"
fi

if [ -n "$KNOWN_REWRITES_FILE" ] && [ ! -f "$KNOWN_REWRITES_FILE" ]; then
  die_indeterminate "known-rewrites file '$KNOWN_REWRITES_FILE' was named but does not exist"
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

# Known-rewrites lookup (issue #1215): return the exact added-line text the
# caller pre-declared as an intentional, sanctioned rewrite for path $1 —
# empty when no known-rewrites file was given, or when it has no entry for
# this path. Uses awk's field-length arithmetic (not a naive `cut -f2-`) so
# an entry whose rewritten line text itself contains a literal tab survives
# intact rather than being truncated at the first embedded tab. Only
# considers 2-field (line-exemption) entries — a 3-field FILE-kind entry
# (see known_file_exempt below) is deliberately excluded here so its
# free-text reason field is never mistaken for a line to exempt.
known_rewrites_for() {
  local path="$1"
  [ -n "$KNOWN_REWRITES_FILE" ] || return 0
  awk -F'\t' -v p="$path" 'NF == 2 && $1 == p { print substr($0, length($1) + 2) }' "$KNOWN_REWRITES_FILE"
}

# Whole-file exemption lookup (issue #1445): true (exit 0) when the
# known-rewrites file carries a 3-field `<path>\tFILE\t<reason>` entry for
# path $1 — see the file-header comment above for the full rationale. False
# (exit 1) when no known-rewrites file was given or it has no FILE-kind
# entry for this path.
known_file_exempt() {
  local path="$1"
  [ -n "$KNOWN_REWRITES_FILE" ] || return 1
  awk -F'\t' -v p="$path" 'NF >= 3 && $1 == p && $2 == "FILE" { found=1 } END { exit !found }' "$KNOWN_REWRITES_FILE"
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

  # Whole-file exemption (issue #1445): the caller pre-declared this exact
  # path as regenerated-not-hand-merged this rebase (see the file-header
  # comment). Skip the added-line content comparison entirely for it — the
  # existence check above still applies, only the semantic-content check is
  # exempted, and only for a path the caller explicitly earned by acting on
  # it, never by pattern-matching the filename.
  if known_file_exempt "$f"; then
    continue
  fi

  # Capture the raw diff BEFORE parsing it, so the shape can be verified
  # independently of the awk extraction below.
  RAW_DIFF=$(git diff "$MERGE_BASE" "$HEAD_REF" -- "$f") \
    || die_indeterminate "git diff $MERGE_BASE $HEAD_REF -- $f failed"

  # Fail LOUD, not open, if this doesn't look like real `git diff` output
  # (issue #1333). A `git diff`-rewriting shell proxy some environments run
  # (e.g. the `rtk` "Rust Token Killer" hook) can silently replace a bare or
  # singly-piped `git diff` invocation's stdout with a non-standard,
  # stat-like summary — no `---`/`+++` headers, no `@@` hunks, and critically
  # no leading `diff --git a/<path> b/<path>` line, which every genuine `git
  # diff` invocation emits first regardless of content shape (a text hunk, a
  # binary-file notice, a mode-only change, or a rename). The awk parse below
  # only recognizes lines starting with a bare `+` — fed a rewritten summary
  # instead, it would silently compute an empty ADDED_LINES set, which reads
  # as "this file added nothing" and inverts this guard's entire purpose
  # (proving added lines survived a rebase). Detect the mismatch instead of
  # trusting a silently-empty parse: a non-empty diff MUST start with the
  # `diff --git` header.
  case "$RAW_DIFF" in
    "" | "diff --git "*) : ;;
    *)
      die_indeterminate "git diff output for '$f' does not look like real git-diff output (missing the leading 'diff --git' header) — a diff-rewriting shell proxy (e.g. rtk) may be active in this environment; bypass it (e.g. run 'rtk proxy git diff ...' directly, or invoke this comparison from inside a script rather than a bare/piped shell command) before retrying (see https://github.com/mattsears18/shipyard/issues/1333)"
      ;;
  esac

  # Lines the PR's own commit(s) added, verbatim — strip the diff '+'
  # marker, drop the '+++' file-header line, and skip blank/whitespace-only
  # lines (noise). awk, not grep/sed, for the extraction — see file header.
  ADDED_LINES=$(printf '%s\n' "$RAW_DIFF" | awk '
    /^\+\+\+/ { next }
    /^\+/ {
      line = substr($0, 2)
      if (line ~ /[^ \t]/) print line
    }
  ')
  [ -n "$ADDED_LINES" ] || continue

  # Narrow the required set to exclude only the specific lines the caller
  # pre-declared as an intentional, sanctioned rewrite for this exact path
  # (issue #1215) — every OTHER line this PR added to the same file is still
  # required to survive verbatim below. This is a per-LINE exemption, not a
  # per-FILE one: a known-rewrites entry can only ever narrow ADDED_LINES,
  # never the haystack it's checked against, so it cannot mask corruption
  # elsewhere in the same file.
  REWRITES=$(known_rewrites_for "$f")
  if [ -n "$REWRITES" ]; then
    ADDED_LINES=$(missing_lines "$ADDED_LINES" "$REWRITES")
    [ -n "$ADDED_LINES" ] || continue
  fi

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

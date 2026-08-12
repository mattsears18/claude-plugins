#!/usr/bin/env bash
# resolve-append-only-conflict.sh — mechanically resolve a git rebase/merge
# conflict in a config-declared append-only doc, by concatenating both
# sides' content, IF AND ONLY IF every conflict hunk in the file is a pure
# addition (no shared base content was touched by both sides).
#
# Backs fix-rebase.md's append-only-doc carve-out (issue #1309): a
# config-declared list (version_coordination.append_only_paths) of doc paths
# whose typical conflict shape is "both sides appended a new, independent
# section" — structurally identical to the CHANGELOG top-of-file-insert case
# §4.6 already resolves deterministically, but for a config-declared path
# instead of a single hardcoded file.
#
# "The conflict regions don't overlap" is the criterion from the issue —
# this script makes that mechanical rather than a judgment call, using
# git's own three-way diff3 conflict markers: regenerate the file's markers
# in diff3 style (`git checkout --conflict=diff3`), which adds a THIRD
# section per hunk showing the common-ancestor ("base") text for that
# region. If every hunk's base section is empty, neither side edited
# pre-existing shared content — both sides purely APPENDED new content at
# that point, so concatenating both (in the order git's own markers present
# them) is safe and loses nothing. If any hunk's base section is non-empty,
# both sides touched real shared content differently — a genuine semantic
# conflict, not a pure-append shape — and this script refuses to resolve it.
#
# Usage:
#   resolve-append-only-conflict.sh <file>
#
# Must be run with $PWD inside a git working tree where <file> is currently
# an unmerged (conflicted) path — i.e. listed by
# `git diff --name-only --diff-filter=U`.
#
# Exit status:
#   0 — resolved: <file> was rewritten in the working tree with every
#       conflict hunk replaced by both sides' content concatenated (in
#       marker order) and all conflict markers removed. Caller must `git
#       add` it — this script never stages or commits.
#   1 — OVERLAP:<file> printed to stdout — at least one conflict hunk has
#       non-empty base content (both sides touched pre-existing shared
#       text). The working tree copy of <file> is left in diff3-marker
#       form (NOT its original two-way-marker form) — caller must NOT
#       `git add` it; abort the rebase/merge instead (which discards this
#       on-disk rewrite along with everything else).
#   2 — INDETERMINATE: <reason> printed to stderr — could not establish a
#       trustworthy result (bad usage, not a conflicted path, `git checkout
#       --conflict=diff3` failed, no conflict markers found, or this
#       script's own parsing self-check failed in this environment). Treat
#       exactly like exit 1 — never treat a 2 as safe to resolve.

set -u
export LC_ALL=C

die_indeterminate() {
  echo "INDETERMINATE: $1" >&2
  exit 2
}

for tool in git awk grep; do
  command -v "$tool" >/dev/null 2>&1 || die_indeterminate "required tool '$tool' not found on PATH"
done

# --- Core parser, shared verbatim between the self-check and the real run
# (mirrors verify-added-lines-survived.sh's precedent, issue #1175 — never
# let the tested logic diverge from the logic that actually runs on real
# files). Reads diff3-marker text on stdin, writes the resolved content to
# stdout, and communicates the verdict via a trailing summary line on
# stderr: `nhunks=<N> overlap=<0|1>`.
resolve_diff3_stream() {
  awk '
    /^<<<<<<< / { hunk=1; section="ours"; ours=""; base=""; theirs=""; next }
    hunk && /^\|\|\|\|\|\|\| / { section="base"; next }
    hunk && /^=======$/ { section="theirs"; next }
    hunk && /^>>>>>>> / {
      nhunks++
      if (base ~ /[^ \t\r\n]/) { overlap=1 }
      printf "%s", ours
      printf "%s", theirs
      hunk=0; section=""
      next
    }
    hunk && section=="ours"   { ours = ours $0 "\n"; next }
    hunk && section=="base"   { base = base $0 "\n"; next }
    hunk && section=="theirs" { theirs = theirs $0 "\n"; next }
    { print }
    END { printf "nhunks=%d overlap=%d\n", nhunks+0, overlap+0 > "/dev/stderr" }
  '
}

# --- Self-check: prove resolve_diff3_stream actually behaves correctly in
# THIS environment (a broken/nonstandard awk would otherwise be
# indistinguishable from a genuinely pure-append conflict) before trusting
# any verdict it produces on a real file. Mirrors verify-added-lines-
# survived.sh's fail-loud-not-open self-check (issue #1175).
self_check() {
  local pure_append overlapping out summary nhunks overlap

  pure_append=$(printf '%s\n' \
    'intro line' \
    '<<<<<<< HEAD' \
    'ours-added line' \
    '||||||| base' \
    '=======' \
    'theirs-added line' \
    '>>>>>>> branch' \
    'outro line')
  summary=$(mktemp)
  out=$(printf '%s\n' "$pure_append" | resolve_diff3_stream 2>"$summary")
  nhunks=$(grep -oE 'nhunks=[0-9]+' "$summary" | cut -d= -f2)
  overlap=$(grep -oE 'overlap=[0-9]+' "$summary" | cut -d= -f2)
  rm -f "$summary"
  [ "${nhunks:-0}" = "1" ] && [ "${overlap:-1}" = "0" ] || return 1 # exactly 1 hunk, no overlap expected
  case "$out" in
    *"ours-added line"*"theirs-added line"*) : ;;
    *) return 1 ;; # should have concatenated both, ours-block before theirs-block
  esac

  overlapping=$(printf '%s\n' \
    'intro line' \
    '<<<<<<< HEAD' \
    'ours-edited line' \
    '||||||| base' \
    'shared original line' \
    '=======' \
    'theirs-edited line' \
    '>>>>>>> branch' \
    'outro line')
  summary=$(mktemp)
  printf '%s\n' "$overlapping" | resolve_diff3_stream >/dev/null 2>"$summary"
  overlap=$(grep -oE 'overlap=[0-9]+' "$summary" | cut -d= -f2)
  rm -f "$summary"
  [ "${overlap:-0}" = "1" ] || return 1 # should have flagged the shared-content edit as overlap

  return 0
}

self_check || die_indeterminate "self-check failed — diff3 conflict parsing did not correctly distinguish a pure-append hunk from an overlapping-edit hunk in this environment; refusing to trust a verdict on a real file (see https://github.com/mattsears18/shipyard/issues/1309)"

# --- Real run ---
FILE="${1:-}"
[ -n "$FILE" ] || die_indeterminate "usage: resolve-append-only-conflict.sh <file>"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die_indeterminate "not inside a git working tree"

git diff --name-only --diff-filter=U -- "$FILE" 2>/dev/null | grep -qxF -- "$FILE" \
  || die_indeterminate "$FILE is not an unmerged (conflicted) path"

git checkout --conflict=diff3 -- "$FILE" 2>/dev/null \
  || die_indeterminate "git checkout --conflict=diff3 failed for $FILE"

RESOLVED=$(mktemp)
SUMMARY=$(mktemp)
resolve_diff3_stream < "$FILE" > "$RESOLVED" 2> "$SUMMARY"

NHUNKS=$(grep -oE 'nhunks=[0-9]+' "$SUMMARY" | cut -d= -f2)
OVERLAP=$(grep -oE 'overlap=[0-9]+' "$SUMMARY" | cut -d= -f2)
rm -f "$SUMMARY"

if [ -z "${NHUNKS:-}" ] || [ "$NHUNKS" -eq 0 ]; then
  rm -f "$RESOLVED"
  die_indeterminate "no conflict markers found in $FILE after regenerating diff3 style"
fi

if [ "${OVERLAP:-0}" -ne 0 ]; then
  rm -f "$RESOLVED"
  echo "OVERLAP:$FILE"
  exit 1
fi

mv "$RESOLVED" "$FILE"
echo "RESOLVED:$FILE ($NHUNKS hunk(s) concatenated)"
exit 0

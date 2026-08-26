#!/usr/bin/env bash
# fence-balance-scan.sh — fail if any markdown file carries an unbalanced
# (odd) count of fenced-code-block marker lines.
#
# Background (issue #1271): plugins/shipyard/commands/do-work/cleanup-summary.md
# carried a stray, unmatched closing ``` fence with no matching opener.
# GitHub's renderer treats fenced code blocks the same naive open/close-toggle
# way this repo's own scripts/check-anchor-links.mjs does (see that script's
# `isFenceLine` / `inFence` logic — no fence-length or nesting awareness). An
# unbalanced fence doesn't just mis-render the page: it desyncs every
# SUBSEQUENT real fence in the file by one, which makes check-anchor-links.mjs
# believe later headings and links live inside a code fence and silently
# excludes them from checking. That's exactly how #1271's file hid a second,
# genuinely broken relative link (`./do-work/drain.md` instead of
# `./drain.md`) from the checker for as long as the fence stayed
# unbalanced — a link-integrity bug wearing a formatting bug's clothes,
# invisible to CI because the gate that would have caught the link was
# itself blinded by the same defect.
#
# This scanner mirrors check-anchor-links.mjs's own naive fence-toggle rule
# exactly (any line matching `^\s{0,3}(```+|~~~+)` toggles fence state,
# regardless of fence character or length) so "this scanner reports clean"
# and "check-anchor-links.mjs sees every heading/link in the file" agree —
# an odd total count of fence-marker lines in a file is the same condition
# either way. It does NOT understand nested/differently-fenced blocks any
# more precisely than that naive toggle does; it exists to catch the cheap,
# common case (a lost or duplicated fence line), not to be a full CommonMark
# parser.
#
# Usage:
#   bash plugins/shipyard/scripts/fence-balance-scan.sh            # scan tracked *.md files
#   bash plugins/shipyard/scripts/fence-balance-scan.sh <path>...  # scan explicit files/dirs
#
# Exit status: 0 = every scanned file has a balanced (even) fence-marker
# line count, 1 = at least one file is unbalanced (prints file + count),
# 2 = usage / environment error (not in a git repo, etc.).

set -u

# Mirrors check-anchor-links.mjs's `isFenceLine` regex exactly.
FENCE_RE='^[[:space:]]{0,3}(```+|~~~+)'

usage() {
  cat >&2 <<'EOF'
usage: fence-balance-scan.sh [path ...]
  With no args, scans every tracked *.md file in the current git repo.
  With paths, scans the given files, or every *.md file under a given
  directory (recursively).
  --help itself always exits 0, distinct from the usage/environment-error
  exit 2 (#1550).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "fence-balance-scan: not inside a git work tree" >&2
  exit 2
fi

candidates=()
if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    if [[ -d "$arg" ]]; then
      while IFS= read -r -d '' f; do
        candidates+=("$f")
      done < <(find "$arg" -type f -name '*.md' -print0)
    elif [[ -f "$arg" ]]; then
      candidates+=("$arg")
    else
      echo "fence-balance-scan: no such file or directory: $arg" >&2
      exit 2
    fi
  done
else
  while IFS= read -r -d '' f; do
    candidates+=("$f")
  done < <(git ls-files -z -- '*.md')
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "fence-balance-scan: no markdown files to scan" >&2
  exit 0
fi

found=0
for f in "${candidates[@]}"; do
  [[ -f "$f" ]] || continue
  count=$(grep -cE -- "$FENCE_RE" "$f" 2>/dev/null || true)
  count=${count:-0}
  if (( count % 2 != 0 )); then
    printf '%s: %d fence-marker line(s) — odd count, at least one fence is unclosed\n' "$f" "$count"
    found=1
  fi
done

if [[ "$found" -eq 1 ]]; then
  echo >&2
  echo "fence-balance-scan: unbalanced fenced-code-block marker(s) found (issue #1271)." >&2
  echo "An odd fence-marker count means a fence opens without closing (or vice versa)," >&2
  echo "which both mis-renders on GitHub and can hide later headings/links from" >&2
  echo "check-anchor-links.mjs's own naive fence-toggle parser." >&2
  exit 1
fi

echo "fence-balance-scan: all scanned markdown file(s) have balanced fence-marker counts."
exit 0

#!/usr/bin/env bash
# Test: the fence-balance gate (issue #1271).
#
# Background — issue #1271: plugins/shipyard/commands/do-work/cleanup-summary.md
# carried a stray, unmatched closing ``` fence with no matching opener. This
# is a real markdown bug (GitHub's renderer treats fenced code blocks the
# same naive open/close-toggle way scripts/check-anchor-links.mjs does — no
# fence-length/nesting awareness), and the unbalanced fence desynced every
# SUBSEQUENT real fence in the file by one — which made check-anchor-links.mjs
# believe a later heading and a later link both lived inside a code fence,
# silently excluding both from checking. The excluded link was itself
# broken (`./do-work/drain.md` instead of `./drain.md`), so the fence bug
# was masking a second, genuine link-integrity bug from the very checker
# that exists to catch it.
#
# scripts/fence-balance-scan.sh is the cheap structural guard this repro
# motivated: a single grep-based count of fence-marker lines per file,
# mirroring check-anchor-links.mjs's own naive `isFenceLine` regex, that
# fails loudly on an odd count instead of silently mis-rendering and
# blinding the link checker.
#
# Pure bash + git. Run with:
#
#   bash plugins/shipyard/scripts/tests/fence-balance-scan.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

scanner="$repo_root/plugins/shipyard/scripts/fence-balance-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()   { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

echo "fence-balance gate regression tests (issue #1271)"
echo

# (1) The scanner exists.
assert_file_exists "$scanner" "scripts/fence-balance-scan.sh exists"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# (2) Behavioral: a file with a balanced (even) fence-marker count passes.
balanced="$work/balanced.md"
cat > "$balanced" <<'FIXTURE'
# Heading

Some prose.

```
example one
```

More prose.

```bash
echo example two
```
FIXTURE
if bash "$scanner" "$balanced" >/dev/null 2>&1; then
  ok "scanner exits 0 on a file with balanced fences"
else
  bad "scanner FALSE-POSITIVED on a file with balanced fences"
fi

# (3) Behavioral: a file with an unbalanced (odd) fence-marker count fails —
# the exact shape issue #1271 found live on main (a lone extra closing
# fence with no matching opener).
unbalanced="$work/unbalanced.md"
cat > "$unbalanced" <<'FIXTURE'
# Heading

```
example one
```

Stray closer below, no opener:
```

## This heading is now hidden from a naive fence-toggle parser
FIXTURE
if bash "$scanner" "$unbalanced" >/dev/null 2>&1; then
  bad "scanner FAILED to detect an unbalanced (odd) fence count (exited 0)"
else
  rc=$?
  if [[ "$rc" -eq 1 ]]; then
    ok "scanner exits 1 on a file with an unbalanced fence count"
  else
    bad "scanner exited $rc (expected 1) on an unbalanced file"
  fi
fi

# (4) Behavioral: an empty file (no fences at all) is balanced (0 is even).
no_fences="$work/no-fences.md"
printf '# Heading\n\nJust prose, no code fences at all.\n' > "$no_fences"
if bash "$scanner" "$no_fences" >/dev/null 2>&1; then
  ok "scanner exits 0 on a file with no fences at all"
else
  bad "scanner FALSE-POSITIVED on a file with no fences"
fi

# (5) Behavioral: a directory argument is walked recursively for *.md files,
# mirroring how check-anchor-links.mjs is invoked with a directory arg.
subdir="$work/nested/deeper"
mkdir -p "$subdir"
cp "$unbalanced" "$subdir/bad.md"
if bash "$scanner" "$work/nested" >/dev/null 2>&1; then
  bad "scanner FAILED to walk a directory argument and find the unbalanced file inside it"
else
  ok "scanner walks a directory argument recursively and finds an unbalanced file inside it"
fi

# (6) Regression: the real repo, scanned the same way check-anchor-links.mjs
# is invoked (plugins/shipyard + the three root docs), is currently clean.
# This is the ongoing CI enforcement — a future PR that reintroduces an
# unbalanced fence anywhere in this set fails this assertion.
if [[ -x "$scanner" || -f "$scanner" ]]; then
  if (
    cd "$repo_root" && bash "$scanner" plugins/shipyard CLAUDE.md README.md CHANGELOG.md
  ) >/dev/null 2>&1; then
    ok "scanner reports the current repo's runtime-loaded markdown as balanced"
  else
    bad "scanner found an unbalanced fence in the current repo — see script output for the offending file"
  fi
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

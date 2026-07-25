#!/usr/bin/env bash
# Test: every bare (no `#anchor`) relative-path `[label](path)` link in
# plugins/shipyard/**/*.md (+ root CLAUDE.md) resolves to a real file or
# directory on disk — issue #929.
#
# Background
# ----------
# check-anchor-links.mjs (issue #866) only ever validated links carrying a
# `#anchor` fragment. #929 found the sibling drift class: a BARE
# `[label](path)` link with no anchor at all — e.g. a stale
# `../../../../agents/...` that's one `../` too deep after a file move —
# was explicitly out of that checker's declared scope. Rather than fix the
# one reported link and leave the class unguarded, #929 extended
# check-anchor-links.mjs itself to also validate bare relative-path link
# targets exist on disk (the `broken-path` problem kind), reusing the same
# file-walking + link-extraction machinery already built for the anchor
# check so the two validations can't drift out of sync.
#
# While building the extension, the checker's own inline-code masking was
# found to have a latent bug: a naive `` `[^`]*` `` regex mis-pairs
# multi-backtick code spans (CommonMark lets a run of N backticks wrap
# literal content containing FEWER backticks, e.g. `` ```` ```yaml ...
# ```` ``), and on a line using that pattern the naive mask silently
# swallowed real markdown links that followed — including #929's own
# repro line (`06-scope-preflight.md:56`). That's fixed by a proper
# backtick-run-aware `maskCodeSpans()`; section (C) below is the
# regression fixture proving link extraction survives a multi-backtick
# line, using the literal repro shape.
#
# Pure bash + node, no other external dependencies. Run with:
#   bash plugins/shipyard/scripts/tests/relative-links-929.test.sh

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

checker="$repo_root/plugins/shipyard/scripts/check-anchor-links.mjs"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not on PATH — this suite cannot verify relative-path links" >&2
  exit 1
fi

if [[ -f "$checker" ]]; then
  assert_pass "check-anchor-links.mjs exists"
else
  assert_fail "check-anchor-links.mjs exists"
  echo "FAIL: cannot continue without the checker" >&2
  exit 1
fi

tmp="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# Assert the checker exits 0 (no broken links found).
assert_ok() {
  local dir="$1" label="$2" out rc
  out=$(node "$checker" "$dir" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    checker reported a break where none was expected:\n'
    printf '    %s\n' "$out"
  fi
}

# Assert the checker exits 1 (a broken link found), optionally requiring
# the diagnostic output to mention a specific substring.
assert_broken() {
  local dir="$1" label="$2" expect="${3:-}" out rc
  out=$(node "$checker" "$dir" 2>&1); rc=$?
  if [[ $rc -ne 1 ]]; then
    assert_fail "$label"
    printf '    expected exit 1 (broken link found), got exit %s:\n' "$rc"
    printf '    %s\n' "$out"
    return
  fi
  if [[ -n "$expect" ]] && ! grep -qF -- "$expect" <<<"$out"; then
    assert_fail "$label"
    printf '    expected the diagnostic to mention: %s\n    got:\n    %s\n' "$expect" "$out"
    return
  fi
  assert_pass "$label"
}

# ==========================================================================
echo "== (A) bare relative-path links — basic pass/fail"

mkdir -p "$tmp/a1"
cat > "$tmp/a1/target.md" <<'EOF'
# Target
EOF
cat > "$tmp/a1/caller.md" <<'EOF'
# Caller

See [the target](target.md) for details.
EOF
assert_ok "$tmp/a1" "a bare relative-path link to an existing sibling file resolves"

mkdir -p "$tmp/a2"
cat > "$tmp/a2/caller.md" <<'EOF'
# Caller

See [the target](does-not-exist.md) for details.
EOF
assert_broken "$tmp/a2" "a bare relative-path link to a nonexistent file is caught" "target path does not exist"

# ==========================================================================
echo "== (B) directories are legitimate bare-path targets"

mkdir -p "$tmp/b1/sub"
cat > "$tmp/b1/sub/inner.md" <<'EOF'
# Inner
EOF
cat > "$tmp/b1/caller.md" <<'EOF'
# Caller

See the [sub/ folder](./sub/) for details.
EOF
assert_ok "$tmp/b1" "a bare relative-path link to an existing DIRECTORY (trailing slash) resolves"

mkdir -p "$tmp/b2"
cat > "$tmp/b2/caller.md" <<'EOF'
# Caller

See the [missing/ folder](./missing/) for details.
EOF
assert_broken "$tmp/b2" "a bare relative-path link to a nonexistent directory is caught" "target path does not exist"

# ==========================================================================
echo "== (C) regression: multi-backtick code span no longer swallows a real link"

# The literal #929 repro shape from 06-scope-preflight.md:56 — a 4-backtick
# inline code span wrapping a literal 3-backtick fence example, followed on
# the SAME line by a real bare-path link. Before the maskCodeSpans() fix,
# the checker's naive single-backtick masking mis-paired this line's
# backtick runs and silently ate the link, so it was never checked at all
# (a false negative, not a false positive) — this fixture pins the fix.
mkdir -p "$tmp/c1"
cat > "$tmp/c1/other.md" <<'EOF'
# Other
EOF
cat > "$tmp/c1/caller.md" <<'EOF'
# Caller

Detector 1 — `.github/workflows/` change proposal. Covers code-fence
headers like ```` ```yaml .github/workflows/ci.yml ```` — see
[the other doc](other.md) for the full rule.
EOF
assert_ok "$tmp/c1" "a real link after a multi-backtick inline code span is extracted and resolves"

# Same shape, but the link after the multi-backtick span is genuinely
# broken — must be CAUGHT, not silently skipped the way the pre-fix
# masking bug would have (which would report a false 0-broken OK).
mkdir -p "$tmp/c2"
cat > "$tmp/c2/caller.md" <<'EOF'
# Caller

Detector 1 — `.github/workflows/` change proposal. Covers code-fence
headers like ```` ```yaml .github/workflows/ci.yml ```` — see
[the other doc](does-not-exist.md) for the full rule.
EOF
assert_broken "$tmp/c2" "a broken link after a multi-backtick inline code span is still caught, not silently skipped" "target path does not exist"

# ==========================================================================
echo "== (D) external / non-repo-relative targets are never checked against disk"

mkdir -p "$tmp/d1"
cat > "$tmp/d1/caller.md" <<'EOF'
# Caller

[external](https://example.com/does/not/exist/on/disk)
[email](mailto:nobody@example.com)
[phone](tel:+15555550100)
EOF
assert_ok "$tmp/d1" "https:/mailto:/tel: bare targets are treated as external and never disk-checked"

# ==========================================================================
echo "== (E) bare-path and #anchor checks compose on the same file without interference"

mkdir -p "$tmp/e1"
cat > "$tmp/e1/target.md" <<'EOF'
# Target

## Real heading
EOF
cat > "$tmp/e1/caller.md" <<'EOF'
# Caller

[good anchor link](target.md#real-heading)
[good bare-path link](target.md)
[broken anchor link](target.md#nonexistent-heading)
[broken bare-path link](missing.md)
EOF
out=$(node "$checker" "$tmp/e1" 2>&1); rc=$?
if [[ $rc -eq 1 ]] \
  && grep -qF "does not match any heading" <<<"$out" \
  && grep -qF "target path does not exist" <<<"$out"; then
  assert_pass "a mixed file reports BOTH a broken anchor link and a broken bare-path link, distinctly"
else
  assert_fail "a mixed file reports BOTH a broken anchor link and a broken bare-path link, distinctly"
  printf '    %s\n' "$out"
fi

# ==========================================================================
echo "== (F) real repo — the actual regression guard for issue #929"

# This is the check that matters: every bare relative-path link under the
# real plugins/shipyard/**/*.md tree plus the root CLAUDE.md must resolve
# on disk, AND every #anchor link must still resolve (issue #866's own
# guard must not regress from the maskCodeSpans() rewrite). #929 itself
# named 1 broken link; the mechanical checker (once the masking bug that
# was hiding #929's own repro line was also fixed) found 2 more of the
# same class in the same doc-restructuring pass — all 3 fixed in the PR
# that added this suite.
real_out=$(node "$checker" "$repo_root/plugins/shipyard" "$repo_root/CLAUDE.md" 2>&1)
real_rc=$?
if [[ $real_rc -eq 0 ]]; then
  assert_pass "real plugins/shipyard/**/*.md + root CLAUDE.md tree has 0 broken bare relative-path links (and 0 broken anchor links)"
else
  assert_fail "real plugins/shipyard/**/*.md + root CLAUDE.md tree has 0 broken bare relative-path links (and 0 broken anchor links)"
  printf '    %s\n' "$real_out"
fi

# ==========================================================================
echo ""
echo "Results: $pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0

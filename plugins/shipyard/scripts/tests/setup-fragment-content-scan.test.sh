#!/usr/bin/env bash
# Test: the setup-fragment-content-scan.sh gate (issue #1453).
#
# Background — issue #1453: the router/fragment pattern (#611 / #994 /
# #1233) exists so a step's content can move to a new fragment file once its
# parent crosses the token-budget cap — shipyard now does this routinely. A
# test that greps a HARDCODED setup/*.md fragment path for a piece of step
# content breaks in CI, after push, the moment that content relocates, with
# no local warning the dispatching worker could have caught first. PR #1447
# hit this for shipyard-repo-root-preamble.test.sh check (4) (step 0.56's
# content moved from 00-config-worktree.md to the new 00k-repo-root-pin.md);
# scripts/setup-fragment-content-scan.sh is the pre-push structural guard
# this issue's fix introduced, mirroring the compound-block-scan.sh /
# brace-expansion-scan.sh / command-substitution-scan.sh family.
#
# This test constructs synthetic fixtures to exercise the scanner's
# detection + exemption logic, then runs the scanner against the REAL repo
# corpus as a regression guard (the scanner must currently report clean —
# every genuine hit found during #1453's own development was either fixed
# to scan across setup/*.md, or annotated with an explicit allow-file
# marker and a citation).
#
# Pure bash + awk. Run with:
#   bash plugins/shipyard/scripts/tests/setup-fragment-content-scan.test.sh

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

scanner="$repo_root/plugins/shipyard/scripts/setup-fragment-content-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

echo "setup-fragment-content-scan.sh regression tests (issue #1453)"
echo

assert_file_exists "$scanner" "scripts/setup-fragment-content-scan.sh exists"
if [[ -x "$scanner" ]]; then
  ok "scripts/setup-fragment-content-scan.sh is executable"
else
  bad "scripts/setup-fragment-content-scan.sh is executable"
fi

# ---------------------------------------------------------------------------
# Synthetic fixtures — exercise detection + exemption logic in isolation.
# ---------------------------------------------------------------------------
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

# (1) A genuine hit: a content-read (grep) against a variable assigned a
# hardcoded fragment path.
cat > "$fixture_dir/hit.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"
if grep -qF "some content" "$SETUP_MD"; then
  echo pass
fi
FIXTURE
if bash "$scanner" "$fixture_dir/hit.test.sh" >/dev/null 2>&1; then
  bad "scanner flags a grep against a hardcoded fragment-path variable"
else
  ok "scanner flags a grep against a hardcoded fragment-path variable"
fi

# (2) An existence check against the SAME kind of variable must NOT be
# flagged — the file itself isn't relocation-prone even when its content is.
cat > "$fixture_dir/exists-ok.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"
if [[ -f "$SETUP_MD" ]]; then
  assert_file_exists "$SETUP_MD" "exists"
fi
FIXTURE
if bash "$scanner" "$fixture_dir/exists-ok.test.sh" >/dev/null 2>&1; then
  ok "scanner does NOT flag a bare existence check ([[ -f ]] / assert_file_exists)"
else
  bad "scanner does NOT flag a bare existence check ([[ -f ]] / assert_file_exists)"
fi

# (3) A router-table NEEDLE check — asserting that setup.md's own router
# table mentions a fragment file by its short label — must NOT be flagged.
# The target being read is setup.md (no do-work/setup/ path segment), and
# the fragment-shaped text is the NEEDLE, not the file operand.
cat > "$fixture_dir/router-needle-ok.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
setup_router_path="$repo_root/plugins/shipyard/commands/do-work/setup.md"
assert_contains "$setup_router_path" "setup/04f-completion-ledger.md" \
  "router table lists the fragment"
FIXTURE
if bash "$scanner" "$fixture_dir/router-needle-ok.test.sh" >/dev/null 2>&1; then
  ok "scanner does NOT flag a router-table needle check (setup.md itself, fragment text as needle)"
else
  bad "scanner does NOT flag a router-table needle check (setup.md itself, fragment text as needle)"
fi

# (4) The router+fragments concat-then-grep pattern — including the
# multi-line backslash-continuation shape this corpus actually uses — must
# NOT be flagged. This is the sanctioned "scan across setup/*.md" pattern,
# not the anti-pattern.
cat > "$fixture_dir/concat-ok.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
router_path="$repo_root/plugins/shipyard/commands/do-work/setup/06-scope-preflight.md"
tmp_path="$(mktemp)"
cat "$router_path" \
  "$repo_root/plugins/shipyard/commands/do-work/setup/06b-scope-carveouts.md" \
  > "$tmp_path" 2>/dev/null
grep -qF "needle" "$tmp_path"
FIXTURE
if bash "$scanner" "$fixture_dir/concat-ok.test.sh" >/dev/null 2>&1; then
  ok "scanner does NOT flag the multi-line router+fragments concat-then-grep pattern"
else
  bad "scanner does NOT flag the multi-line router+fragments concat-then-grep pattern"
fi

# (5) Inline single-site opt-out marker.
cat > "$fixture_dir/allow-line.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"
# setup-fragment-content-scan: allow
if grep -qF "some content" "$SETUP_MD"; then
  echo pass
fi
FIXTURE
if bash "$scanner" "$fixture_dir/allow-line.test.sh" >/dev/null 2>&1; then
  ok "'# setup-fragment-content-scan: allow' opts a single site out"
else
  bad "'# setup-fragment-content-scan: allow' opts a single site out"
fi

# (6) Whole-file opt-out marker, AND it must suppress the finding lines from
# stdout entirely (not merely flip the exit code) — a noisy "clean" pass
# would be confusing and would mask a genuine unrelated finding later in the
# same output stream.
cat > "$fixture_dir/allow-file.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
# setup-fragment-content-scan: allow-file
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"
if grep -qF "some content" "$SETUP_MD"; then
  echo pass
fi
FIXTURE
allow_file_out="$(bash "$scanner" "$fixture_dir/allow-file.test.sh" 2>&1)"
allow_file_status=$?
if [[ "$allow_file_status" -eq 0 ]]; then
  ok "'# setup-fragment-content-scan: allow-file' exits clean for the whole file"
else
  bad "'# setup-fragment-content-scan: allow-file' exits clean for the whole file (status=$allow_file_status)"
fi
if [[ "$allow_file_out" != *"setup-fragment-hardcode"* ]]; then
  ok "'# setup-fragment-content-scan: allow-file' suppresses the finding line(s) from stdout"
else
  bad "'# setup-fragment-content-scan: allow-file' suppresses the finding line(s) from stdout"
  printf '    got: %s\n' "$allow_file_out"
fi

# (7) A negative existence-derived pattern (assert_contains against a
# NON-tracked var, e.g. a $cleanup_file or $dispatch_file that never held a
# setup/*.md path) must not be flagged — the tracking is per-variable, not
# blanket.
cat > "$fixture_dir/unrelated-var-ok.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
cleanup_file="$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
assert_contains "$cleanup_file" "some needle" "label"
FIXTURE
if bash "$scanner" "$fixture_dir/unrelated-var-ok.test.sh" >/dev/null 2>&1; then
  ok "scanner does NOT flag a content-read against a variable never assigned a setup/*.md fragment path"
else
  bad "scanner does NOT flag a content-read against a variable never assigned a setup/*.md fragment path"
fi

echo

# ---------------------------------------------------------------------------
# CLI surface: --list, usage error, missing-file error.
# ---------------------------------------------------------------------------
list_count="$(bash "$scanner" --list 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$list_count" -gt 50 ]]; then
  ok "--list discovers a non-trivial number of *.test.sh files (got $list_count)"
else
  bad "--list discovers a non-trivial number of *.test.sh files (got $list_count, expected > 50)"
fi

if bash "$scanner" "/no/such/file.test.sh" >/dev/null 2>&1; then
  bad "scanner exits non-zero on a nonexistent explicit path"
else
  status=$?
  if [[ "$status" -eq 2 ]]; then
    ok "scanner exits 2 (usage/env error) on a nonexistent explicit path"
  else
    bad "scanner exits 2 (usage/env error) on a nonexistent explicit path (got $status)"
  fi
fi

echo

# ---------------------------------------------------------------------------
# Real-repo regression: the actual corpus, as of this PR, must be clean.
# Every genuine hit found during #1453's development was either fixed to
# scan across setup/*.md, or annotated with an explicit allow-file marker.
# ---------------------------------------------------------------------------
real_out="$(mktemp)"
if bash "$scanner" >"$real_out" 2>&1; then
  ok "scanner reports the real repo corpus clean of hardcoded setup/*.md content-reads (#1453)"
else
  bad "scanner found hardcoded setup/*.md content-read(s) in the real repo corpus — see output below"
  cat "$real_out"
fi
rm -f "$real_out"

echo
echo "passed: $pass, failed: $fail"
if (( fail > 0 )); then
  exit 1
fi
exit 0

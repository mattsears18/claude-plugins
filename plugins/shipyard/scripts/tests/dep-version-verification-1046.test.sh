#!/usr/bin/env bash
# Test suite for scripts/verify-new-dep-versions.sh — the pre-PR-create
# check that verifies a newly-added dependency's written version against
# the authoritative registry (issue #1046, a follow-up to #1045's
# shipyard:adding-dependencies skill).
#
# Strategy: stand up fake `npm` / `gh` binaries in a per-test tmpdir, point
# PATH at them, and feed the script fixture unified diffs (and, where
# relevant, a fixture PR-body file) via its --diff-file / --pr-body-file
# flags — never a real git repo, never the real network. This matches the
# repro-style hermetic pattern already used by
# plugins/shipyard/scripts/tests/gh-cached.test.sh.
#
# Covers:
#   - npm (package.json) hard-online path: same-major pass, unexplained
#     major-behind fail, peer/SDK carve-out skip, PR-body cooldown-note
#     explanation skip, npm CLI unavailable -> offline fallback (note only)
#   - GitHub Actions `uses:` hard-online path: same shape via a fake `gh`
#   - Every other manifest class (pip requirements.txt here, representative
#     of the offline-only classes) -- always skip-with-note, never fails
#   - Newly-ADDED vs bumped-existing distinction (a version bump of an
#     existing dependency is not flagged at all)
#   - The npm reserved-key guard (a top-level "version" bump is not
#     mistaken for a new dependency)
#   - No newly-added dependency lines at all -> clean pass
#   - Usage errors (missing base-ref/--diff-file) -> exit 2
#
# Pure bash. Run with:
#   bash plugins/shipyard/scripts/tests/dep-version-verification-1046.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../verify-new-dep-versions.sh"

if [[ ! -f "$script" ]]; then
  echo "FAIL: script not found at $script" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 600
    printf '\n'
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    did not expect to contain: %s\n' "$needle"
    fail=$((fail + 1))
  fi
}

# --- Isolated tmp environment: a bin/ dir for fake npm+gh, a fixtures/ dir
# for diffs and PR bodies. Removed on exit regardless of outcome.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/fixtures"

# Fake npm: `npm view <pkg> version` returns a canned "latest" per package.
cat > "$tmpdir/bin/npm" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "view" && "$3" == "version" ]]; then
  case "$2" in
    left-pad) echo "1.3.0" ;;
    stale-pkg) echo "5.0.0" ;;
    *) echo "" ;;
  esac
fi
SH
chmod +x "$tmpdir/bin/npm"

# Fake gh: `gh api repos/<owner>/<action>/releases/latest --jq .tag_name`
cat > "$tmpdir/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
  case "$2" in
    repos/actions/checkout/releases/latest) echo "v7.0.1" ;;
    repos/actions/old-action/releases/latest) echo "v9.0.0" ;;
    *) echo "" ;;
  esac
fi
SH
chmod +x "$tmpdir/bin/gh"

with_fakes_path="$tmpdir/bin:$PATH"
# A PATH with neither fake binary present, to exercise the
# CLI-unavailable -> offline fallback branch without touching real npm/gh
# on the host running the suite.
no_cli_path="/usr/bin:/bin"

# --- Fixture diffs -------------------------------------------------------

cat > "$tmpdir/fixtures/diff-npm-same-major.txt" <<'EOF'
diff --git a/package.json b/package.json
index abc..def 100644
--- a/package.json
+++ b/package.json
@@ -10,6 +10,7 @@
   "dependencies": {
     "express": "^4.18.0",
+    "left-pad": "^1.2.0",
     "lodash": "^4.17.21"
   },
EOF

cat > "$tmpdir/fixtures/diff-npm-stale.txt" <<'EOF'
diff --git a/package.json b/package.json
index abc..def 100644
--- a/package.json
+++ b/package.json
@@ -10,6 +10,7 @@
   "dependencies": {
     "express": "^4.18.0",
+    "stale-pkg": "^1.0.0",
     "lodash": "^4.17.21"
   },
EOF

cat > "$tmpdir/fixtures/diff-npm-carveout.txt" <<'EOF'
diff --git a/package.json b/package.json
index abc..def 100644
--- a/package.json
+++ b/package.json
@@ -10,6 +10,7 @@
   "dependencies": {
     "express": "^4.18.0",
+    "react": "18.2.0",
     "lodash": "^4.17.21"
   },
EOF

cat > "$tmpdir/fixtures/diff-npm-firebase-carveout.txt" <<'EOF'
diff --git a/package.json b/package.json
index abc..def 100644
--- a/package.json
+++ b/package.json
@@ -10,6 +10,7 @@
   "dependencies": {
     "express": "^4.18.0",
+    "@react-native-firebase/app": "18.0.0",
     "lodash": "^4.17.21"
   },
EOF

cat > "$tmpdir/fixtures/diff-npm-bump.txt" <<'EOF'
diff --git a/package.json b/package.json
index abc..def 100644
--- a/package.json
+++ b/package.json
@@ -10,6 +10,7 @@
   "dependencies": {
-    "stale-pkg": "^0.9.0",
+    "stale-pkg": "^1.0.0",
     "lodash": "^4.17.21"
   },
EOF

cat > "$tmpdir/fixtures/diff-npm-own-version-bump.txt" <<'EOF'
diff --git a/package.json b/package.json
index abc..def 100644
--- a/package.json
+++ b/package.json
@@ -1,6 +1,6 @@
 {
   "name": "shipyard",
-  "version": "4.5.1",
+  "version": "4.6.0",
   "dependencies": {
EOF

cat > "$tmpdir/fixtures/diff-actions-stale.txt" <<'EOF'
diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
index abc..def 100644
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -5,6 +5,7 @@ jobs:
     steps:
       - uses: actions/checkout@v7.0.1
+      - uses: actions/old-action@v4.0.0
EOF

cat > "$tmpdir/fixtures/diff-offline-pip.txt" <<'EOF'
diff --git a/requirements.txt b/requirements.txt
index abc..def 100644
--- a/requirements.txt
+++ b/requirements.txt
@@ -1,3 +1,4 @@
 flask==2.3.0
+requests==2.31.0
 pytest==7.4.0
EOF

cat > "$tmpdir/fixtures/diff-no-deps.txt" <<'EOF'
diff --git a/README.md b/README.md
index abc..def 100644
--- a/README.md
+++ b/README.md
@@ -1,2 +1,3 @@
 # Hello
+A new line of prose, no dependency here.
EOF

cat > "$tmpdir/fixtures/prbody-cooldown.md" <<'EOF'
Closes #9999

## Summary

Added `stale-pkg@^1.0.0` — pinned below latest due to a documented supply-chain cooldown (min-release-age) carve-out note for this package.
EOF

cat > "$tmpdir/fixtures/prbody-records-requests.md" <<'EOF'
Closes #9999

## Summary

Added `requests@2.31.0` (latest stable, per pypi.org).
EOF

echo "== verify-new-dep-versions.sh (#1046) =="

# 1. npm dep whose written version matches the current major -> pass.
out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-npm-same-major.txt" 2>&1)"
rc=$?
assert_equals "$rc" "0" "same-major npm dep: exit 0"
assert_contains "$out" "PASS  left-pad" "same-major npm dep: reports PASS"

# 2. npm dep >=1 major behind, no explanation -> hard fail.
out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-npm-stale.txt" 2>&1)"
rc=$?
assert_equals "$rc" "1" "stale npm dep, unexplained: exit 1"
assert_contains "$out" "FAIL  stale-pkg" "stale npm dep, unexplained: reports FAIL"
assert_contains "$out" "4 major(s) behind" "stale npm dep, unexplained: names the gap size"

# 3. Peer/SDK carve-out (react) -> always skip-with-note, never checked.
out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-npm-carveout.txt" 2>&1)"
rc=$?
assert_equals "$rc" "0" "react carve-out: exit 0"
assert_contains "$out" "SKIP  react" "react carve-out: reports SKIP"
assert_contains "$out" "carve-out" "react carve-out: names the carve-out reason"

# 4. Coordinated @react-native-firebase/* carve-out.
out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-npm-firebase-carveout.txt" 2>&1)"
rc=$?
assert_equals "$rc" "0" "@react-native-firebase/* carve-out: exit 0"
assert_contains "$out" "SKIP  @react-native-firebase/app" "@react-native-firebase/* carve-out: reports SKIP"

# 5. Unexplained gap, but the PR body carries a cooldown/carve-out note ->
#    skip-with-note, not a failure.
out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-npm-stale.txt" --pr-body-file "$tmpdir/fixtures/prbody-cooldown.md" 2>&1)"
rc=$?
assert_equals "$rc" "0" "stale npm dep explained by PR-body cooldown note: exit 0"
assert_contains "$out" "SKIP  stale-pkg" "stale npm dep explained by PR-body cooldown note: reports SKIP"
assert_contains "$out" "PR body explains the gap" "stale npm dep explained by PR-body cooldown note: names the explanation"

# 6. npm CLI unavailable -> falls back to the offline PR-body-record check,
#    never hard-fails even though the dep IS stale.
out="$(PATH="$no_cli_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-npm-stale.txt" 2>&1)"
rc=$?
assert_equals "$rc" "0" "npm unavailable: falls back to offline, exit 0"
assert_contains "$out" "NOTE  stale-pkg" "npm unavailable: reports NOTE not FAIL"
assert_contains "$out" "registry lookup unavailable" "npm unavailable: names the reason"

# 7. GitHub Actions uses: pin, stale by several majors, no explanation -> fail.
out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-actions-stale.txt" 2>&1)"
rc=$?
assert_equals "$rc" "1" "stale Actions pin, unexplained: exit 1"
assert_contains "$out" "FAIL  actions/old-action" "stale Actions pin, unexplained: reports FAIL"
assert_not_contains "$out" "actions/checkout" "stale Actions pin: unchanged context line (checkout) not flagged"

# 8. gh CLI unavailable -> Actions class falls back to offline too.
out="$(PATH="$no_cli_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-actions-stale.txt" 2>&1)"
rc=$?
assert_equals "$rc" "0" "gh unavailable: falls back to offline, exit 0"
assert_contains "$out" "NOTE  actions/old-action" "gh unavailable: reports NOTE not FAIL"

# 9. Every other manifest class (pip requirements.txt here) is offline-only
#    and NEVER hard-fails, regardless of whether the PR body records a
#    version.
out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-offline-pip.txt" 2>&1)"
rc=$?
assert_equals "$rc" "0" "offline-only class (pip), no PR body: exit 0"
assert_contains "$out" "NOTE  requests" "offline-only class (pip), no PR body: reports NOTE"

out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-offline-pip.txt" --pr-body-file "$tmpdir/fixtures/prbody-records-requests.md" 2>&1)"
rc=$?
assert_equals "$rc" "0" "offline-only class (pip), PR body records version: exit 0"
assert_contains "$out" "PR body records a resolved version" "offline-only class (pip), PR body records version: notes the pass"

# 10. A version BUMP of an existing dependency (removed old line + added new
#     line for the same package) is not a newly-added dependency — not
#     flagged at all, not even a note.
out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-npm-bump.txt" 2>&1)"
rc=$?
assert_equals "$rc" "0" "existing-dep version bump: exit 0"
assert_not_contains "$out" "stale-pkg" "existing-dep version bump: not treated as a new dependency"

# 11. The npm reserved-key guard: a top-level "version" bump (the package's
#     OWN version) is never mistaken for a new dependency.
out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-npm-own-version-bump.txt" 2>&1)"
rc=$?
assert_equals "$rc" "0" "own package.json version bump: exit 0"
assert_contains "$out" "no newly-added dependency lines found" "own package.json version bump: not mistaken for a dependency"

# 12. No newly-added dependency lines anywhere in the diff -> clean pass.
out="$(PATH="$with_fakes_path" bash "$script" --diff-file "$tmpdir/fixtures/diff-no-deps.txt" 2>&1)"
rc=$?
assert_equals "$rc" "0" "no dependency lines in diff: exit 0"
assert_contains "$out" "no newly-added dependency lines found" "no dependency lines in diff: says so"

# 13. Usage errors.
out="$(bash "$script" 2>&1)"
rc=$?
assert_equals "$rc" "2" "no args: exit 2 (usage error)"

out="$(bash "$script" --diff-file "$tmpdir/fixtures/does-not-exist.txt" 2>&1)"
rc=$?
assert_equals "$rc" "2" "--diff-file pointing at a missing file: exit 2"

echo
echo "== Summary: ${pass} passed, ${fail} failed =="
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0

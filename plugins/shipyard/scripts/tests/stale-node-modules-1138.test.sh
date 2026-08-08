#!/usr/bin/env bash
# Test: recycled-worktree-slot stale `node_modules` detection (issue #1138).
#
# Background
# ----------
# `/shipyard:do-work` reuses worker worktree slots across dispatches. A
# recycled slot's checkout moves onto a new branch/commit (`git checkout -B`)
# without re-installing `node_modules/` — it's whatever the slot's previous
# occupant left behind. When the newly-checked-out `package.json` changed a
# dependency since that install, the worktree's `node_modules` predates the
# checked-out commit, but the existing missing-`node_modules` presence check
# (`[ ! -d node_modules ]`) passes cleanly because the directory still
# exists — the gap is invisible until a pre-push hook fails with a
# confusing, seemingly-unrelated "cannot resolve module" error.
#
# This suite pins three things:
#
#   (A) The DECISION LOGIC in detect-stale-node-modules.sh — its
#       `--decide <package_json_exists> <node_modules_exists> <npm_ls_ok>`
#       truth table. Pure (no filesystem or process I/O), same shape as
#       detect-missing-workflow-scope.sh's --decide mode.
#
#   (B) The LIVE-MODE behavior against real fixture directories — noop (no
#       package.json), missing (node_modules absent), fresh (installed tree
#       satisfies package.json), and stale (installed tree does NOT satisfy
#       package.json, the #1138 case) — using `npm ls --depth=0`, which is a
#       purely local, offline check (no network / no real install needed).
#
#   (C) DOC CONTRACT — worker-preamble's node-bootstrap.md fragment actually
#       invokes the script (single source of truth — the freshness condition
#       must not be re-derived as an inline bash conditional in the spec)
#       and documents the ESLint-cache-clear-after-real-install remediation.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/stale-node-modules-1138.test.sh

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

DETECTOR="$repo_root/plugins/shipyard/scripts/detect-stale-node-modules.sh"
NODE_BOOTSTRAP_MD="$repo_root/plugins/shipyard/skills/worker-preamble/node-bootstrap.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
  fi
}

# decide <pkg> <nm> <npm_ls_ok> <expected> <label>
assert_decide() {
  local got
  got="$(bash "$DETECTOR" --decide "$1" "$2" "$3" 2>/dev/null)"
  if [[ "$got" == "$4" ]]; then
    assert_pass "$5 (pkg=$1 nm=$2 npm_ls_ok=$3 => $got)"
  else
    assert_fail "$5 (pkg=$1 nm=$2 npm_ls_ok=$3 => expected [$4], got [$got])"
  fi
}

# assert_live <dir> <expected> <label>
assert_live() {
  local got
  got="$(bash "$DETECTOR" "$1" 2>/dev/null)"
  if [[ "$got" == "$2" ]]; then
    assert_pass "$3 (=> $got)"
  else
    assert_fail "$3 (expected [$2], got [$got])"
  fi
}

echo "stale-node-modules detection regression tests (issue #1138)"
echo

# ---------------------------------------------------------------------------
# (A) The decision-logic truth table.
# ---------------------------------------------------------------------------
echo "(A) detect-stale-node-modules.sh — decision truth table"
if [[ -f "$DETECTOR" ]]; then
  assert_pass "detect-stale-node-modules.sh exists"
  if [[ -x "$DETECTOR" ]]; then
    assert_pass "detect-stale-node-modules.sh is executable"
  else
    assert_fail "detect-stale-node-modules.sh is executable"
  fi

  # No package.json at all — ecosystem-tolerant no-op, regardless of the
  # other two signals (a repo with no package.json can't have a real
  # node_modules or npm-ls result worth reasoning about).
  assert_decide 0 0 0 noop "no package.json => noop"
  assert_decide 0 1 1 noop "no package.json (even if node_modules/npm-ls flags say otherwise) => noop"

  # package.json present, node_modules entirely absent — the PRE-EXISTING
  # gap the presence check at the top of node-bootstrap.md already covers.
  assert_decide 1 0 0 missing "package.json present, node_modules absent => missing"
  assert_decide 1 0 1 missing "package.json present, node_modules absent (npm_ls flag irrelevant) => missing"

  # Both present, npm ls succeeds — a genuinely fresh install. Never touch
  # the ESLint cache on this verdict.
  assert_decide 1 1 1 fresh "package.json + node_modules present, npm ls ok => fresh"

  # Both present, npm ls fails — the #1138 case: a recycled slot's leftover
  # install that predates the checked-out package.json.
  assert_decide 1 1 0 stale "package.json + node_modules present, npm ls failed => stale"
else
  assert_fail "detect-stale-node-modules.sh exists (missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (B) Live-mode behavior against real fixture directories. Uses a scratch
#     dir outside the repo tree (this is the test SCRIPT executing at run
#     time, not a Claude tool call — the worktree-write guard only gates the
#     Edit/Write tools, not a test's own filesystem operations).
# ---------------------------------------------------------------------------
echo "(B) live-mode fixtures — noop / missing / fresh / stale"
if [[ -f "$DETECTOR" ]]; then
  SCRATCH="$(mktemp -d)"
  trap 'rm -rf "$SCRATCH"' EXIT

  # noop: no package.json at all.
  mkdir -p "$SCRATCH/noop"
  assert_live "$SCRATCH/noop" noop "empty dir, no package.json => noop"

  # missing: package.json present, no node_modules dir.
  mkdir -p "$SCRATCH/missing"
  cat > "$SCRATCH/missing/package.json" <<'JSON'
{"name":"fixture","version":"1.0.0","dependencies":{"left-pad":"^1.3.0"}}
JSON
  assert_live "$SCRATCH/missing" missing "package.json present, node_modules absent => missing"

  # fresh: package.json declares no deps, empty node_modules satisfies it.
  mkdir -p "$SCRATCH/fresh/node_modules"
  cat > "$SCRATCH/fresh/package.json" <<'JSON'
{"name":"fixture","version":"1.0.0","dependencies":{}}
JSON
  assert_live "$SCRATCH/fresh" fresh "package.json with no deps, empty node_modules => fresh"

  # stale: package.json declares a dep that isn't actually installed — the
  # #1138 shape (a recycled slot's node_modules predates this package.json).
  mkdir -p "$SCRATCH/stale/node_modules"
  cat > "$SCRATCH/stale/package.json" <<'JSON'
{"name":"fixture","version":"1.0.0","dependencies":{"left-pad":"^1.3.0"}}
JSON
  assert_live "$SCRATCH/stale" stale "package.json declares an uninstalled dep, node_modules present => stale"

  rm -rf "$SCRATCH"
  trap - EXIT
else
  assert_fail "live-mode fixtures (detector missing at $DETECTOR)"
fi
echo

# ---------------------------------------------------------------------------
# (C) Doc contract — worker-preamble's node-bootstrap.md fragment.
# ---------------------------------------------------------------------------
echo "(C) node-bootstrap.md — doc contract"
if [[ -f "$NODE_BOOTSTRAP_MD" ]]; then
  assert_pass "node-bootstrap.md exists"

  assert_contains "$NODE_BOOTSTRAP_MD" 'detect-stale-node-modules.sh' \
    "node-bootstrap.md invokes the detector script (#1138)"

  assert_contains "$NODE_BOOTSTRAP_MD" '#1138' \
    "node-bootstrap.md cites #1138"

  assert_contains "$NODE_BOOTSTRAP_MD" 'npm ci' \
    "node-bootstrap.md documents the reinstall remediation for a stale verdict"

  assert_contains "$NODE_BOOTSTRAP_MD" '.eslintcache' \
    "node-bootstrap.md documents clearing the ESLint cache after a real install"

  assert_contains "$NODE_BOOTSTRAP_MD" '.expo/cache/eslint' \
    "node-bootstrap.md documents the Expo-specific ESLint cache location"

  # Single source of truth — the freshness condition (npm ls --depth=0
  # exiting non-zero) must not be re-implemented as an inline bash
  # conditional in the spec (the #716 drift hazard this repo has already
  # been bitten by once for a structurally similar condition). Only the
  # detector script itself should contain an executable `npm ls` invocation.
  if grep -qE '^\s*(if\s+.*npm ls|npm ls --depth=0[^`]*&&)' "$NODE_BOOTSTRAP_MD"; then
    assert_fail "node-bootstrap.md must NOT re-derive the npm-ls freshness condition inline — call the script"
  else
    assert_pass "node-bootstrap.md does not re-derive the npm-ls freshness condition inline"
  fi
else
  assert_fail "node-bootstrap.md exists (missing at $NODE_BOOTSTRAP_MD)"
fi
echo

printf 'passed: %d, failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1

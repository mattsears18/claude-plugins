#!/usr/bin/env bash
# Test: the dangling-spec-script-reference gate (issue #1467).
#
# Background: PR #1465 deleted `plugins/shipyard/scripts/assert-worktree-cwd.sh`
# and left two live invocations of it in `shipyard:worker-preamble`'s
# ALWAYS-LOADED `SKILL.md`. Every dispatched worker runs step 0 before anything
# else, so each one would have died on `No such file or directory` at its first
# command — and all 164 bash suites, shellcheck, and the anchor-link checker
# passed with that defect in place. It was found by hand, after merge, and
# fixed in PR #1466. `scripts/spec-script-reference-scan.sh` is the gate; this
# is its enforcement.
#
# Every positive assertion below is paired with a PLANTED VIOLATION so the
# scanner is proven to fail on a real finding rather than trivially exiting 0.
# Tests 12-14 guard the vacuous-pass shape #1312 found in the pre-existing
# preamble test: a matcher that stops matching must fail loudly, not report
# success over zero blocks. Test 3 plants the ACTUAL #1467 defect
# (`$CLAUDE_PLUGIN_ROOT/scripts/assert-worktree-cwd.sh`) so the regression is
# reproduced verbatim, not merely approximated.
#
# Pure bash + awk + git. Run with:
#   bash plugins/shipyard/scripts/tests/spec-script-references.test.sh

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

scanner="$repo_root/plugins/shipyard/scripts/spec-script-reference-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

echo "spec-script-reference gate regression tests (issue #1467)"
echo

# (1) The scanner exists.
if [[ -f "$scanner" ]]; then
  ok "scripts/spec-script-reference-scan.sh exists"
else
  bad "scripts/spec-script-reference-scan.sh is missing (expected at $scanner)"
  echo
  echo "  ${pass} passed, ${fail} failed"
  exit 1
fi

# (1b) …and carries the git exec bit itself. A gate that enforces #1395 on
# every script a spec references must satisfy it too.
scanner_mode="$(git -C "$repo_root" ls-files -s -- plugins/shipyard/scripts/spec-script-reference-scan.sh | awk '{print $1}')"
if [[ "$scanner_mode" == "100755" ]]; then
  ok "the scanner itself is recorded 100755 in the git index (#1395)"
else
  bad "the scanner's git index mode is '${scanner_mode:-<untracked>}', expected 100755 (git update-index --chmod=+x)"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# Explicit-path fixtures. These are scanned against the REAL repo's git index
# (the scanner builds its mode map from `git ls-files -s` at cwd), so a fixture
# can reference a genuinely-present script and get an honest clean verdict.
# ---------------------------------------------------------------------------

# (2) A block referencing scripts that really exist passes clean.
clean_md="$work/clean.md"
cat > "$clean_md" <<'FIXTURE'
# Heading

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get ci.settled_minutes
bash plugins/shipyard/scripts/brace-expansion-scan.sh --list
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$clean_md" ) >/dev/null 2>&1; then
  ok "scanner exits 0 on a block referencing scripts that exist and are executable"
else
  out="$( cd "$repo_root" && bash "$scanner" "$clean_md" 2>&1 )"
  bad "scanner FALSE-POSITIVED on a block referencing real scripts: $out"
fi

# (3) PLANTED VIOLATION — the actual #1467 defect, reproduced verbatim.
# `assert-worktree-cwd.sh` was deleted by PR #1465 while two invocations of it
# stayed live in the always-loaded worker preamble.
regression_md="$work/regression.md"
cat > "$regression_md" <<'FIXTURE'
```bash
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
bash "$CLAUDE_PLUGIN_ROOT/scripts/assert-worktree-cwd.sh" "$WORKTREE_PATH"
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$regression_md" ) >/dev/null 2>&1; then
  bad "scanner FAILED to detect the #1467 regression (deleted assert-worktree-cwd.sh) — exited 0"
else
  out="$( cd "$repo_root" && bash "$scanner" "$regression_md" 2>&1 )"
  if [[ "$out" == *"dangling-script-reference"* && "$out" == *"assert-worktree-cwd.sh"* ]]; then
    ok "scanner detects the #1467 regression and names the dangling script"
  else
    bad "scanner exited non-zero but did not name the dangling reference — output: $out"
  fi
fi

# (4) PLANTED VIOLATION in the `plugins/shipyard/...` spelling.
qualified_md="$work/qualified.md"
cat > "$qualified_md" <<'FIXTURE'
```bash
bash plugins/shipyard/scripts/no-such-script-anywhere.sh --live
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$qualified_md" ) >/dev/null 2>&1; then
  bad "scanner FAILED to flag a dangling plugins/shipyard/scripts/... reference"
else
  ok "scanner flags a dangling reference in the plugins/shipyard/... spelling"
fi

# (5) PLANTED VIOLATION in the bare `scripts/...` spelling.
bare_md="$work/bare.md"
cat > "$bare_md" <<'FIXTURE'
```bash
# eligibility checks happen in scripts/no-such-script-anywhere.sh classify
true
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$bare_md" ) >/dev/null 2>&1; then
  bad "scanner FAILED to flag a dangling bare scripts/... reference"
else
  ok "scanner flags a dangling reference in the bare scripts/... spelling"
fi

# (6) PLANTED VIOLATION in the braced `${CLAUDE_PLUGIN_ROOT}` spelling.
# brace-expansion-scan.sh (#1311) independently bans this spelling; this gate
# must not go blind if one ever slips past that one.
braced_md="$work/braced.md"
cat > "$braced_md" <<'FIXTURE'
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/no-such-script-anywhere.sh"
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$braced_md" ) >/dev/null 2>&1; then
  bad "scanner FAILED to flag a dangling \${CLAUDE_PLUGIN_ROOT} reference"
else
  ok "scanner flags a dangling reference in the braced \${CLAUDE_PLUGIN_ROOT} spelling"
fi

# (7) Prose, tables, and NON-bash fences are ignored — this corpus names script
# paths constantly in markdown links, which anchor-links-866.test.sh already
# validates.
prose_md="$work/prose.md"
cat > "$prose_md" <<'FIXTURE'
See [`scripts/no-such-script-anywhere.sh`](../scripts/no-such-script-anywhere.sh) for details.

| Script | Purpose |
|---|---|
| `$CLAUDE_PLUGIN_ROOT/scripts/also-not-real.sh` | illustrative |

```text
bash "$CLAUDE_PLUGIN_ROOT/scripts/not-real-either.sh"
```

```json
{"cmd": "plugins/shipyard/scripts/nope.sh"}
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$prose_md" ) >/dev/null 2>&1; then
  ok "scanner ignores prose, tables, and non-bash fences"
else
  out="$( cd "$repo_root" && bash "$scanner" "$prose_md" 2>&1 )"
  bad "scanner FALSE-POSITIVED outside a bash fence: $out"
fi

# (8) Placeholder and glob paths never form a match — `<`, `>`, and `*` are
# outside the path character class, so a spec can keep writing them.
placeholder_md="$work/placeholder.md"
cat > "$placeholder_md" <<'FIXTURE'
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/<name>.sh"
shellcheck plugins/shipyard/scripts/*.sh
ls scripts/*.sh
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$placeholder_md" ) >/dev/null 2>&1; then
  ok "scanner does NOT match placeholder (<name>.sh) or glob (*.sh) paths"
else
  out="$( cd "$repo_root" && bash "$scanner" "$placeholder_md" 2>&1 )"
  bad "scanner FALSE-POSITIVED on a placeholder / glob path: $out"
fi

# (9) Boundary guard: a bare `scripts/...` rooted somewhere this scanner cannot
# resolve is skipped rather than guessed at — but the qualified spellings in
# the SAME file are still checked, so the guard can't be mistaken for a
# file-level opt-out.
boundary_md="$work/boundary.md"
cat > "$boundary_md" <<'FIXTURE'
```bash
bash "../../scripts/no-such-script-anywhere.sh"
bash "$OTHER_REPO_ROOT/scripts/no-such-script-anywhere.sh"
bash myscripts/no-such-script-anywhere.sh
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$boundary_md" ) >/dev/null 2>&1; then
  ok "scanner skips a bare scripts/... token rooted outside the plugin"
else
  out="$( cd "$repo_root" && bash "$scanner" "$boundary_md" 2>&1 )"
  bad "scanner FALSE-POSITIVED on an externally-rooted scripts/... token: $out"
fi

boundary_paired_md="$work/boundary-paired.md"
cat > "$boundary_paired_md" <<'FIXTURE'
```bash
bash "../../scripts/no-such-script-anywhere.sh"
bash "$CLAUDE_PLUGIN_ROOT/scripts/still-not-real.sh"
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$boundary_paired_md" ) >/dev/null 2>&1; then
  bad "the boundary guard leaked past its own token (the qualified violation was not caught)"
else
  out="$( cd "$repo_root" && bash "$scanner" "$boundary_paired_md" 2>&1 )"
  if [[ "$out" == *"still-not-real.sh"* && "$out" != *"no-such-script-anywhere.sh"* ]]; then
    ok "the boundary guard scopes to one token (the qualified violation is still caught)"
  else
    bad "boundary-guard scoping is wrong — output: $out"
  fi
fi

# (10) The allow directive exempts exactly the following block — and ONLY that
# block, so it can't be mistaken for a file-level opt-out.
allow_md="$work/allow.md"
cat > "$allow_md" <<'FIXTURE'
<!-- spec-script-reference-scan: allow -->
```bash
[ -f scripts/setup.sh ] || [ -f bin/setup ]
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$allow_md" ) >/dev/null 2>&1; then
  ok "an allow directive exempts the following block"
else
  out="$( cd "$repo_root" && bash "$scanner" "$allow_md" 2>&1 )"
  bad "an allow directive should have exempted the following block: $out"
fi

allow_scope_md="$work/allow-scope.md"
cat > "$allow_scope_md" <<'FIXTURE'
<!-- spec-script-reference-scan: allow -->
```bash
[ -f scripts/setup.sh ]
```

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/still-flagged.sh"
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$allow_scope_md" ) >/dev/null 2>&1; then
  bad "an allow directive leaked past its own block (the later violation was not caught)"
else
  out="$( cd "$repo_root" && bash "$scanner" "$allow_scope_md" 2>&1 )"
  if [[ "$out" == *"still-flagged.sh"* && "$out" != *"setup.sh"* ]]; then
    ok "an allow directive scopes to exactly one block (later violation still caught)"
  else
    bad "allow-directive scoping is wrong — output: $out"
  fi
fi

# ---------------------------------------------------------------------------
# Synthetic-repo fixtures. The exec-bit half of the assertion reads the GIT
# INDEX mode, and this repo has no tracked-but-non-executable *.sh to point at
# (script-exec-bits.test.sh keeps it that way), so it is exercised against a
# purpose-built throwaway repo.
# ---------------------------------------------------------------------------

# _mkrepo <dir> — a git repo with the scanner copied in at its root.
_mkrepo() {
  local d="$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  cp "$scanner" "$d/scanner.sh"
}

# (11) A referenced script that EXISTS but is tracked 100644 is flagged (#1395:
# a non-executable script fails at runtime the same way a dangling one does).
exec_repo="$work/execrepo"
_mkrepo "$exec_repo"
mkdir -p "$exec_repo/plugins/shipyard/scripts" "$exec_repo/plugins/shipyard/commands"
printf '#!/usr/bin/env bash\ntrue\n' > "$exec_repo/plugins/shipyard/scripts/helper.sh"
chmod 644 "$exec_repo/plugins/shipyard/scripts/helper.sh"
# shellcheck disable=SC2016  # fixture text emitted literally, not an expansion
printf '```bash\nbash "$CLAUDE_PLUGIN_ROOT/scripts/helper.sh"\n```\n' \
  > "$exec_repo/plugins/shipyard/commands/spec.md"
( cd "$exec_repo" && git add -A ) >/dev/null 2>&1
noexec_out="$( cd "$exec_repo" && bash ./scanner.sh plugins/shipyard/commands/spec.md 2>&1 )"
noexec_rc=$?
if [[ "$noexec_rc" -eq 1 && "$noexec_out" == *"non-executable-script-reference"* && "$noexec_out" == *"100644"* ]]; then
  ok "a referenced script tracked 100644 is flagged as non-executable (#1395)"
else
  bad "expected a non-executable finding; got rc=$noexec_rc output: $noexec_out"
fi

# (11b) PAIRED POSITIVE: recording the exec bit clears the finding. Without
# this the assertion above could pass for the wrong reason (e.g. the path not
# resolving at all).
( cd "$exec_repo" && git update-index --chmod=+x plugins/shipyard/scripts/helper.sh ) >/dev/null 2>&1
if ( cd "$exec_repo" && bash ./scanner.sh plugins/shipyard/commands/spec.md ) >/dev/null 2>&1; then
  ok "git update-index --chmod=+x on the referenced script clears the finding"
else
  fixed_out="$( cd "$exec_repo" && bash ./scanner.sh plugins/shipyard/commands/spec.md 2>&1 )"
  bad "recording the exec bit should have cleared the finding: $fixed_out"
fi

# (11c) A script present on disk but NOT tracked in the git index is dangling —
# it does not ship to a plugin install, so "exists on my disk" is not the bar.
printf '#!/usr/bin/env bash\ntrue\n' > "$exec_repo/plugins/shipyard/scripts/untracked.sh"
chmod 755 "$exec_repo/plugins/shipyard/scripts/untracked.sh"
# shellcheck disable=SC2016  # fixture text emitted literally, not an expansion
printf '```bash\nbash "$CLAUDE_PLUGIN_ROOT/scripts/untracked.sh"\n```\n' \
  > "$exec_repo/plugins/shipyard/commands/untracked-spec.md"
untracked_out="$( cd "$exec_repo" && bash ./scanner.sh plugins/shipyard/commands/untracked-spec.md 2>&1 )"
if [[ "$untracked_out" == *"dangling-script-reference"* && "$untracked_out" == *"not tracked in the git index"* ]]; then
  ok "an untracked-but-present script is flagged (index is the bar, not the disk)"
else
  bad "an untracked script should be flagged as dangling; got: $untracked_out"
fi

# (12) ANTI-VACUITY: a discovery run that finds zero FILES is an error, not a
# clean pass.
empty_repo="$work/emptyrepo"
_mkrepo "$empty_repo"
( cd "$empty_repo" && git add -A ) >/dev/null 2>&1
empty_out="$( cd "$empty_repo" && bash ./scanner.sh 2>&1 )"
empty_rc=$?
if [[ "$empty_rc" -eq 2 && "$empty_out" == *"discovered zero files"* ]]; then
  ok "discovery run with zero discovered files exits 2 loudly (anti-vacuity)"
else
  bad "discovery run with zero discovered files exited $empty_rc without the anti-vacuity error"
fi

# (13) ANTI-VACUITY: a discovery run whose fence matcher matches too few blocks
# exits 2 — the exact shape #1312 found (a matcher silently at zero while still
# reporting success).
vac_repo="$work/vacrepo"
_mkrepo "$vac_repo"
mkdir -p "$vac_repo/plugins/shipyard/commands"
printf 'no fences here\n' > "$vac_repo/plugins/shipyard/commands/a.md"
( cd "$vac_repo" && git add -A ) >/dev/null 2>&1
vac_out="$( cd "$vac_repo" && bash ./scanner.sh 2>&1 )"
vac_rc=$?
if [[ "$vac_rc" -eq 2 && "$vac_out" == *"fenced bash block(s) — below the"* ]]; then
  ok "discovery run below the fenced-block floor exits 2 loudly (anti-vacuity, #1312)"
else
  bad "discovery run with zero matched blocks exited $vac_rc without the block-floor error"
fi

# (14) ANTI-VACUITY: blocks above the floor but ZERO references extracted is
# also an error — a broken REFERENCE matcher is as silent as a broken fence
# matcher, and the block floor alone would not catch it.
ref_repo="$work/refrepo"
_mkrepo "$ref_repo"
mkdir -p "$ref_repo/plugins/shipyard/commands"
{
  i=0
  while [[ "$i" -lt 400 ]]; do
    # shellcheck disable=SC2016  # fixture text emitted literally, not an expansion
    printf '```bash\ntrue\n```\n\n'
    i=$((i+1))
  done
} > "$ref_repo/plugins/shipyard/commands/many-blocks.md"
( cd "$ref_repo" && git add -A ) >/dev/null 2>&1
ref_out="$( cd "$ref_repo" && bash ./scanner.sh 2>&1 )"
ref_rc=$?
if [[ "$ref_rc" -eq 2 && "$ref_out" == *"script reference(s) — below the"* ]]; then
  ok "discovery run below the reference floor exits 2 loudly (anti-vacuity, #1312)"
else
  bad "discovery run with zero extracted references exited $ref_rc without the ref-floor error"
fi

# (15) A nonexistent path argument errors with exit 2, never a silent pass.
if ( cd "$repo_root" && bash "$scanner" "$work/does-not-exist.md" ) >/dev/null 2>&1; then
  bad "scanner should error (not silently pass) on a nonexistent file"
else
  ( cd "$repo_root" && bash "$scanner" "$work/does-not-exist.md" ) >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    ok "scanner exits 2 on a nonexistent file argument"
  else
    bad "scanner exited $rc (expected 2) on a nonexistent file argument"
  fi
fi

# (16) --list prints the discovered corpus and exits 0.
list_out="$( cd "$repo_root" && bash "$scanner" --list 2>&1 )"
list_rc=$?
list_n="$(printf '%s\n' "$list_out" | grep -c '\.md$')"
if [[ "$list_rc" -eq 0 && "$list_n" -gt 0 ]]; then
  ok "--list prints the discovered corpus ($list_n files) and exits 0"
else
  bad "--list exited $list_rc with $list_n markdown paths"
fi

# (17) THE REGRESSION ASSERTION: the real repo's whole spec tree is clean —
# every script a fenced bash block tells a worker to run exists and is
# executable. This is what any future deletion-without-updating-the-spec will
# fail against.
real_out="$( cd "$repo_root" && bash "$scanner" 2>&1 )"
real_rc=$?
if [[ "$real_rc" -eq 0 ]]; then
  ok "discovery run over the real plugins/shipyard/ tree reports clean"
else
  bad "discovery run over the real tree found unresolvable references: $real_out"
fi

# (18) ANTI-VACUITY floor on the REAL corpus, asserted from the outside. Test
# (17)'s clean verdict is only meaningful if both matchers actually walked a
# substantial corpus. Floors are deliberately well below the counts observed at
# #1467's fix time (601 blocks / 267 references — the 606/267 baseline the
# maintainer measured with the prototype, modulo fence-matcher strictness) so
# ordinary spec churn never trips them.
real_blocks="$(printf '%s\n' "$real_out" | sed -n 's/.*, \([0-9][0-9]*\) fenced bash block(s).*/\1/p' | tail -1)"
real_refs="$(printf '%s\n' "$real_out" | sed -n 's/.*, \([0-9][0-9]*\) script reference(s) checked.*/\1/p' | tail -1)"
[[ -n "$real_blocks" ]] || real_blocks=0
[[ -n "$real_refs" ]] || real_refs=0
if [[ "$real_blocks" -ge 300 ]]; then
  ok "discovery run walked $real_blocks fenced bash blocks (floor 300; 601 observed at #1467)"
else
  bad "discovery run walked only $real_blocks fenced bash blocks — below the 300 floor (#1312)"
fi
if [[ "$real_refs" -ge 150 ]]; then
  ok "discovery run checked $real_refs script references (floor 150; 267 observed at #1467)"
else
  bad "discovery run checked only $real_refs script references — below the 150 floor (#1312)"
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

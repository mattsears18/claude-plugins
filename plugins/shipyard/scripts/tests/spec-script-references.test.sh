#!/usr/bin/env bash
# Test: the dangling-spec-reference gate (issues #1467, #1468).
#
# Two reference classes share one fence traversal and one allow directive:
# SCRIPTS (#1467 — must exist AND carry the git exec bit) and MARKDOWN
# FRAGMENTS (#1468 — must exist; a fragment is read, never executed). The
# fragment cases are grouped under their own banner below and carry their own
# independent anti-vacuity floor, because a fragment matcher that silently
# stopped matching would sail past both of the script class's floors.
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

echo "spec-reference gate regression tests — scripts (#1467) + markdown fragments (#1468)"
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

# ---------------------------------------------------------------------------
# MARKDOWN-FRAGMENT class (issue #1468). Same fence traversal and same allow
# directive as the script class; different token shape, different resolution
# table (citing-file-relative as well as plugin-rooted), and existence-only
# (a fragment is read, never executed, so no mode-bit half).
# ---------------------------------------------------------------------------

# (F1) Fragments that really exist pass clean, in every rooted spelling. These
# forms resolve against the plugin root regardless of where the citing file
# sits, so they can be scanned from a scratch fixture like the script cases
# above; the citing-file-relative forms (F3/F4) need real repo paths and use a
# synthetic repo instead.
frag_clean_md="$work/frag-clean.md"
cat > "$frag_clean_md" <<'FIXTURE'
```bash
git show origin/main:plugins/shipyard/commands/do-work/dont.md
cat "$CLAUDE_PLUGIN_ROOT/commands/do-work/drain.md"
cat "${CLAUDE_PLUGIN_ROOT}/commands/do-work/steady-state.md"
cat "$PRIMARY_ROOT/plugins/shipyard/commands/do-work/setup.md"
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$frag_clean_md" ) >/dev/null 2>&1; then
  ok "scanner exits 0 on fragment references that exist (all rooted spellings)"
else
  out="$( cd "$repo_root" && bash "$scanner" "$frag_clean_md" 2>&1 )"
  bad "scanner FALSE-POSITIVED on real fragment references: $out"
fi

# (F2) PLANTED VIOLATION — the #1467 shape, one file-type over: a spec still
# telling a worker to read a fragment that no longer exists.
frag_dangling_md="$work/frag-dangling.md"
cat > "$frag_dangling_md" <<'FIXTURE'
```bash
cat "$CLAUDE_PLUGIN_ROOT/skills/worker-preamble/no-such-fragment-anywhere.md"
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$frag_dangling_md" ) >/dev/null 2>&1; then
  bad "scanner FAILED to flag a dangling fragment reference — exited 0"
else
  out="$( cd "$repo_root" && bash "$scanner" "$frag_dangling_md" 2>&1 )"
  if [[ "$out" == *"dangling-fragment-reference"* && "$out" == *"no-such-fragment-anywhere.md"* ]]; then
    ok "scanner flags a dangling fragment reference and names it"
  else
    bad "scanner exited non-zero but did not name the dangling fragment — output: $out"
  fi
fi

# (F3/F4) Citing-file-relative resolution — the half that genuinely differs
# from the script class, and the dual-root rule that follows from it. Both need
# the citing file to sit at a REAL repo path, so they run against a synthetic
# repo (same pattern as the exec-bit and anti-vacuity cases below) rather than
# by writing fixtures into the live tree.
frag_repo="$work/fragrepo"
_mkrepo "$frag_repo"
mkdir -p "$frag_repo/plugins/shipyard/commands/do-work/setup" \
         "$frag_repo/plugins/shipyard/skills/worker-preamble"
printf '# dont\n'   > "$frag_repo/plugins/shipyard/commands/do-work/dont.md"
printf '# router\n' > "$frag_repo/plugins/shipyard/commands/do-work.md"
printf '# divert\n' > "$frag_repo/plugins/shipyard/commands/do-work/setup/04-backlog-divert.md"
printf '# skill\n'  > "$frag_repo/plugins/shipyard/skills/worker-preamble/SKILL.md"

# Explicitly-relative: `./x.md` and `../x.md` resolve against the CITING file's
# own directory, never against $CLAUDE_PLUGIN_ROOT.
# shellcheck disable=SC2016  # fixture text emitted literally, not an expansion
printf '```bash\ncat ./dont.md\ncat ../do-work.md\n```\n' \
  > "$frag_repo/plugins/shipyard/commands/do-work/rel.md"
( cd "$frag_repo" && git add -A ) >/dev/null 2>&1
if ( cd "$frag_repo" && bash ./scanner.sh plugins/shipyard/commands/do-work/rel.md ) >/dev/null 2>&1; then
  ok "scanner resolves ./ and ../ fragments against the CITING file's directory"
else
  out="$( cd "$frag_repo" && bash ./scanner.sh plugins/shipyard/commands/do-work/rel.md 2>&1 )"
  bad "citing-file-relative resolution FALSE-POSITIVED: $out"
fi

# PAIRED NEGATIVE: the same shape pointing at a sibling that does NOT exist is
# still flagged, so the assertion above can't be passing merely because
# relative tokens are silently skipped.
# shellcheck disable=SC2016  # fixture text emitted literally, not an expansion
printf '```bash\ncat ./no-such-sibling-anywhere.md\n```\n' \
  > "$frag_repo/plugins/shipyard/commands/do-work/relbad.md"
( cd "$frag_repo" && git add -A ) >/dev/null 2>&1
if ( cd "$frag_repo" && bash ./scanner.sh plugins/shipyard/commands/do-work/relbad.md ) >/dev/null 2>&1; then
  bad "a ./ fragment pointing at a nonexistent sibling was NOT flagged"
else
  ok "a ./ fragment pointing at a nonexistent sibling is flagged"
fi

# Dual-root: a BARE relative fragment is accepted when it resolves against
# EITHER the citing file's directory or the plugin root. Both roots occur live
# in the real corpus, so one line here is plugin-rooted and the other
# citing-rooted, from the same citing file.
{
  printf '```bash\n'
  printf '# plugin-rooted: skills/... does not exist under commands/do-work/\n'
  printf 'cat skills/worker-preamble/SKILL.md\n'
  printf '# citing-rooted: setup/ is a real subdirectory of commands/do-work/\n'
  printf 'cat setup/04-backlog-divert.md\n'
  printf '```\n'
} > "$frag_repo/plugins/shipyard/commands/do-work/dual.md"
( cd "$frag_repo" && git add -A ) >/dev/null 2>&1
if ( cd "$frag_repo" && bash ./scanner.sh plugins/shipyard/commands/do-work/dual.md ) >/dev/null 2>&1; then
  ok "a bare relative fragment resolves against either the citing dir or the plugin root"
else
  out="$( cd "$frag_repo" && bash ./scanner.sh plugins/shipyard/commands/do-work/dual.md 2>&1 )"
  bad "the dual-root rule FALSE-POSITIVED: $out"
fi

# shellcheck disable=SC2016  # fixture text emitted literally, not an expansion
printf '```bash\ncat skills/worker-preamble/no-such-fragment-anywhere.md\n```\n' \
  > "$frag_repo/plugins/shipyard/commands/do-work/dualbad.md"
( cd "$frag_repo" && git add -A ) >/dev/null 2>&1
dual_bad_out="$( cd "$frag_repo" && bash ./scanner.sh plugins/shipyard/commands/do-work/dualbad.md 2>&1 )"
dual_bad_rc=$?
if [[ "$dual_bad_rc" -eq 1 && "$dual_bad_out" == *"neither is tracked"* ]]; then
  ok "a bare relative fragment resolving under NEITHER root is flagged, naming both candidates"
else
  bad "expected a both-candidates finding; got rc=$dual_bad_rc output: $dual_bad_out"
fi

# (F5) Skipped by design, each forced by a live false positive found while
# establishing #1468's baseline. Every line here would be a finding if the
# corresponding boundary guard broke.
frag_skip_md="$work/frag-skip.md"
cat > "$frag_skip_md" <<'FIXTURE'
```bash
# A bare FILENAME is prose in a fenced comment — see investigate.md § step 4b,
# and 04d-investigate-routing.md's own table. Neither names a directory.
Body="$WORKTREE_PATH/.shipyard-scratch/pr-body.md"
Alt="${SCRATCH_ROOT}/.shipyard-scratch/issue-body.md"
cat "$CLAUDE_PLUGIN_ROOT/skills/worker-preamble/<fragment>.md"
ls plugins/shipyard/commands/do-work/*.md
cat ../../../../../../../../escapes-the-repo.md
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$frag_skip_md" ) >/dev/null 2>&1; then
  ok "scanner skips bare filenames, foreign-variable roots, placeholders, globs, and repo escapes"
else
  out="$( cd "$repo_root" && bash "$scanner" "$frag_skip_md" 2>&1 )"
  bad "a documented fragment-class skip FALSE-POSITIVED: $out"
fi

# (F6) Prose and non-bash fences are ignored for fragments too — this corpus
# links fragment paths constantly, and anchor-links-866.test.sh owns those.
frag_prose_md="$work/frag-prose.md"
cat > "$frag_prose_md" <<'FIXTURE'
See [`no-such-fragment-anywhere.md`](./no-such-fragment-anywhere.md) and the
table row for `plugins/shipyard/commands/do-work/also-not-real.md`.

```text
cat "$CLAUDE_PLUGIN_ROOT/commands/not-real-either.md"
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$frag_prose_md" ) >/dev/null 2>&1; then
  ok "scanner ignores fragment paths in prose, tables, and non-bash fences"
else
  out="$( cd "$repo_root" && bash "$scanner" "$frag_prose_md" 2>&1 )"
  bad "scanner FALSE-POSITIVED on a fragment path outside a bash fence: $out"
fi

# (F7) The allow directive covers the fragment class too — one directive, one
# fence traversal, both classes. Paired with a later un-directived block so it
# can't be mistaken for a file-level opt-out.
frag_allow_md="$work/frag-allow.md"
cat > "$frag_allow_md" <<'FIXTURE'
<!-- spec-script-reference-scan: allow -->
```bash
ls CONTRIBUTING.md docs/CONTRIBUTING.md .github/CONTRIBUTING.md 2>/dev/null
```

```bash
cat "$CLAUDE_PLUGIN_ROOT/commands/still-flagged-fragment.md"
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$frag_allow_md" ) >/dev/null 2>&1; then
  bad "the allow directive leaked past its own block for the fragment class"
else
  out="$( cd "$repo_root" && bash "$scanner" "$frag_allow_md" 2>&1 )"
  if [[ "$out" == *"still-flagged-fragment.md"* && "$out" != *"CONTRIBUTING.md"* ]]; then
    ok "the allow directive exempts fragments in exactly one block"
  else
    bad "fragment-class allow-directive scoping is wrong — output: $out"
  fi
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
real_refs="$(printf '%s\n' "$real_out" | sed -n 's/.*, \([0-9][0-9]*\) script reference(s).*/\1/p' | tail -1)"
real_frags="$(printf '%s\n' "$real_out" | sed -n 's/.*+ \([0-9][0-9]*\) fragment reference(s).*/\1/p' | tail -1)"
[[ -n "$real_blocks" ]] || real_blocks=0
[[ -n "$real_refs" ]] || real_refs=0
[[ -n "$real_frags" ]] || real_frags=0
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
# Third floor, independent of the other two (#1468): a fragment matcher that
# silently stopped matching would sail past BOTH the block floor and the script
# floor, which is the exact shape #1467 added its second floor to catch.
if [[ "$real_frags" -ge 5 ]]; then
  ok "discovery run checked $real_frags fragment references (floor 5; 8 observed at #1468)"
else
  bad "discovery run checked only $real_frags fragment references — below the 5 floor (#1468)"
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

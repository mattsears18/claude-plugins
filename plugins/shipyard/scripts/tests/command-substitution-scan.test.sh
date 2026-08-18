#!/usr/bin/env bash
# Test: the argument-position-command-substitution gate (issue #1314).
#
# Background — issues #1308 -> #1311 -> #1314: #1308's controlled experiment
# isolated TWO worktree-isolation refusal triggers — a braced `${VAR}`
# parameter expansion anywhere, and `$(cmd)` in ARGUMENT position (its rows K
# vs L: the identical substitution passes as an assignment RHS and is refused
# as an argument). #1311 swept the brace half and enforced it in
# `brace-expansion-scan.sh`. #1314 swept the command-substitution half and
# added `scripts/command-substitution-scan.sh` as its sibling enforcement.
#
# Every positive assertion below is paired with a PLANTED VIOLATION so the
# scanner is proven to fail on a real finding rather than trivially exiting 0
# (tests 3-6, 14). Tests 11/12 guard the vacuous-pass shape #1312 found in the
# pre-existing preamble test: a matcher that stops matching must fail loudly,
# not report success over zero blocks. Test 16 puts a floor on the real
# corpus's block count for the same reason.
#
# Pure bash + awk. Run with:
#   bash plugins/shipyard/scripts/tests/command-substitution-scan.test.sh

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

scanner="$repo_root/plugins/shipyard/scripts/command-substitution-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

echo "command-substitution-scan gate regression tests (issue #1314)"
echo

# (1) The scanner exists and is executable as a bash script.
if [[ -f "$scanner" ]]; then
  ok "scripts/command-substitution-scan.sh exists"
else
  bad "scripts/command-substitution-scan.sh is missing (expected at $scanner)"
  echo
  echo "  ${pass} passed, ${fail} failed"
  exit 1
fi

# (1b) It is committed with the executable bit set in the INDEX — a script
# added without mode 100755 reds CI on repos that check it, and `chmod +x` on
# disk alone does not stage the mode.
mode="$(git -C "$repo_root" ls-files -s -- plugins/shipyard/scripts/command-substitution-scan.sh 2>/dev/null | awk '{print $1}')"
if [[ "$mode" == "100755" ]]; then
  ok "command-substitution-scan.sh is mode 100755 in the git index"
elif [[ -z "$mode" ]]; then
  ok "command-substitution-scan.sh not yet tracked (pre-commit run) — mode check deferred to CI"
else
  bad "command-substitution-scan.sh is mode $mode in the index (expected 100755)"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# (2) A block that only ever assigns command substitutions passes clean. This
# is the sanctioned form the whole convention exists to produce.
clean_md="$work/clean.md"
cat > "$clean_md" <<'FIXTURE'
# Heading

```bash
TOPLEVEL=$(git rev-parse --show-toplevel)
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
export DEFAULT_BRANCH=$(gh repo view o/r --json defaultBranchRef -q .defaultBranchRef.name)
local NAME=$(basename "$TOPLEVEL")
readonly STAMP=$(date +%s)
declare -x SESSION=$(cat .shipyard-session-id)
COUNTS[3]=$(wc -l < f.txt)
ACC+=$(cat more.txt)
bash some-script.sh "$TOPLEVEL" "$DEFAULT_BRANCH"
```
FIXTURE
if bash "$scanner" "$clean_md" >/dev/null 2>&1; then
  ok "scanner exits 0 on a block that only assigns command substitutions"
else
  out="$(bash "$scanner" "$clean_md" 2>&1)"
  bad "scanner FALSE-POSITIVED on assignment-RHS substitutions: $out"
fi

# (3) PLANTED VIOLATION: #1308's experiment row L verbatim — the one-statement,
# no-loop, no-pipe, no-braces argument-position form. This is the negative test
# that keeps test (2)'s clean exit from being vacuous.
planted_md="$work/planted.md"
cat > "$planted_md" <<'FIXTURE'
```bash
bash "/plugins/shipyard/scripts/assert-worktree-cwd.sh" "$(pwd)"
```
FIXTURE
if bash "$scanner" "$planted_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect #1308 experiment row L (exited 0)"
else
  out="$(bash "$scanner" "$planted_md" 2>&1)"
  # shellcheck disable=SC2016  # literal needle grepped from output, not an expansion
  if [[ "$out" == *"argument-position-command-substitution"* && "$out" == *'$(pwd)'* ]]; then
    ok "scanner detects #1308 experiment row L and names the substitution"
  else
    bad "scanner exited non-zero but did not name the argument-position finding"
  fi
fi

# (4) PLANTED VIOLATION: the NESTED case — the outer substitution is a legal
# assignment RHS, the inner one is in argument position and must still be
# flagged. This is the single most common shape #1314 swept (28 copies of the
# SHIPYARD_REPO_ROOT stanza).
nested_md="$work/nested.md"
cat > "$nested_md" <<'FIXTURE'
```bash
SHIPYARD_REPO_ROOT=$(cat "$(git rev-parse --show-toplevel)/.shipyard-primary-root" 2>/dev/null)
```
FIXTURE
if bash "$scanner" "$nested_md" >/dev/null 2>&1; then
  bad "scanner FAILED to flag the INNER substitution of a nested assignment (exited 0)"
else
  out="$(bash "$scanner" "$nested_md" 2>&1)"
  hits="$(printf '%s\n' "$out" | grep -c 'argument-position-command-substitution')"
  # shellcheck disable=SC2016  # literal needle grepped from output, not an expansion
  if [[ "$hits" -eq 1 && "$out" == *'$(git rev-parse'* ]]; then
    ok "scanner flags the inner substitution of a nested assignment, and only it"
  else
    bad "nested-assignment handling wrong ($hits finding(s)) — output: $out"
  fi
fi

# (5) PLANTED VIOLATION: a `for` loop iterating a command substitution, and a
# `[ -n "$(...)" ]` test — both argument position, neither path-shaped. Path
# forming is not the discriminator (#1308 experiment J's analogue).
argforms_md="$work/argforms.md"
cat > "$argforms_md" <<'FIXTURE'
```bash
for n in $(jq -r '.[].number' /tmp/x.json); do
  echo "$n"
done
[ -n "$(ls -A node_modules 2>/dev/null)" ] && echo present
```
FIXTURE
if bash "$scanner" "$argforms_md" >/dev/null 2>&1; then
  bad "scanner FAILED to flag for-loop / test-argument substitutions (exited 0)"
else
  out="$(bash "$scanner" "$argforms_md" 2>&1)"
  hits="$(printf '%s\n' "$out" | grep -c 'argument-position-command-substitution')"
  if [[ "$hits" -eq 2 ]]; then
    ok "scanner flags both a for-loop word-split and a test-argument substitution"
  else
    bad "expected 2 findings for the for-loop + test forms, got $hits: $out"
  fi
fi

# (6) PLANTED VIOLATION inside an UNQUOTED heredoc (<<EOF) is flagged — an
# unquoted heredoc body IS expanded, so a substitution there really runs.
unquoted_hd_md="$work/unquoted-heredoc.md"
cat > "$unquoted_hd_md" <<'FIXTURE'
```bash
cat > out.txt <<EOF
built at $(date -u +%s)
EOF
```
FIXTURE
if bash "$scanner" "$unquoted_hd_md" >/dev/null 2>&1; then
  bad "scanner FAILED to flag a substitution inside an UNQUOTED heredoc (exited 0)"
else
  ok "scanner flags a substitution inside an unquoted (expanding) heredoc"
fi

# (7) ARITHMETIC EXPANSION is NEVER flagged — `$((expr))` is not command
# substitution, and rewriting it would be a silent semantic break. This is the
# carve-out the brace sweep did not have and #1314 calls out by name.
arith_md="$work/arith.md"
cat > "$arith_md" <<'FIXTURE'
```bash
n=$((n + 1))
echo "$((a - b))"
printf '%d\n' "$(( (kb + 1023) / 1024 ))"
reaped=$((reaped + 1)) ; echo "total=$((reaped * 2))"
```
FIXTURE
if bash "$scanner" "$arith_md" >/dev/null 2>&1; then
  ok "scanner does NOT flag arithmetic expansion \$((expr)), in any position"
else
  out="$(bash "$scanner" "$arith_md" 2>&1)"
  bad "scanner FALSE-POSITIVED on arithmetic expansion: $out"
fi

# (8) PLANTED VIOLATION paired with (7): a prefixed assignment RHS IS flagged.
# Recognition is deliberately strict — the `$(` must sit immediately after the
# `=`. This pins the strictness decision so a later "loosen it" edit fails
# loudly instead of silently reopening the false-negative hole.
prefixed_md="$work/prefixed.md"
cat > "$prefixed_md" <<'FIXTURE'
```bash
OUT=/tmp/a11y-audit-$(date +%s)
```
FIXTURE
if bash "$scanner" "$prefixed_md" >/dev/null 2>&1; then
  bad "scanner did NOT flag a PREFIXED assignment RHS — the strict rule regressed"
else
  ok "scanner flags a prefixed assignment RHS (strict recognition, by design)"
fi

# (9) A QUOTED heredoc body (<<'EOF') is skipped — its text is emitted
# literally, so rewriting a substitution there would change the emitted OUTPUT.
quoted_hd_md="$work/quoted-heredoc.md"
cat > "$quoted_hd_md" <<'FIXTURE'
```bash
cat > template.sh <<'TEMPLATE'
echo "$(literal-placeholder-command)"
TEMPLATE
```
FIXTURE
if bash "$scanner" "$quoted_hd_md" >/dev/null 2>&1; then
  ok "scanner skips a QUOTED heredoc body (literal, not expanded)"
else
  out="$(bash "$scanner" "$quoted_hd_md" 2>&1)"
  bad "scanner FALSE-POSITIVED inside a quoted heredoc body: $out"
fi

# (10) The canonical `${CLAUDE_PLUGIN_ROOT:-...}` preamble line is skipped —
# it is pre-relocation-only by design and already permanently refused via its
# required-modifier brace, so de-substituting it buys nothing. The paired
# planted violation on the NEXT line proves the skip is line-scoped, not a
# block- or file-level opt-out.
preamble_md="$work/preamble.md"
cat > "$preamble_md" <<'FIXTURE'
```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); echo "$R/plugins/shipyard")}"
```
FIXTURE
if bash "$scanner" "$preamble_md" >/dev/null 2>&1; then
  ok "scanner skips the canonical \${CLAUDE_PLUGIN_ROOT:-...} preamble line"
else
  out="$(bash "$scanner" "$preamble_md" 2>&1)"
  bad "scanner flagged the exempt CLAUDE_PLUGIN_ROOT preamble line: $out"
fi

preamble_scope_md="$work/preamble-scope.md"
cat > "$preamble_scope_md" <<'FIXTURE'
```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); echo "$R/plugins/shipyard")}"
cd "$(git rev-parse --show-toplevel)"
```
FIXTURE
if bash "$scanner" "$preamble_scope_md" >/dev/null 2>&1; then
  bad "the CLAUDE_PLUGIN_ROOT exemption leaked to the whole block"
else
  out="$(bash "$scanner" "$preamble_scope_md" 2>&1)"
  hits="$(printf '%s\n' "$out" | grep -c 'argument-position-command-substitution')"
  if [[ "$hits" -eq 1 ]]; then
    ok "the CLAUDE_PLUGIN_ROOT exemption scopes to exactly its own line"
  else
    bad "expected exactly 1 finding beside the exempt preamble line, got $hits: $out"
  fi
fi

# (11) ANTI-VACUITY: on a discovery run the scanner must fail loudly if the
# fence matcher matched zero blocks (#1312's vacuous-pass shape).
vac_repo="$work/vacrepo"
mkdir -p "$vac_repo/plugins/shipyard/commands"
( cd "$vac_repo" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'no fences here\n' > "$vac_repo/plugins/shipyard/commands/a.md"
cp "$scanner" "$vac_repo/scanner.sh"
( cd "$vac_repo" && git add -A >/dev/null 2>&1 )
vac_out="$(cd "$vac_repo" && bash ./scanner.sh 2>&1)"
vac_rc=$?
if [[ "$vac_rc" -eq 2 && "$vac_out" == *"ZERO fenced bash blocks"* ]]; then
  ok "discovery run with zero matched blocks exits 2 loudly (anti-vacuity, #1312)"
else
  bad "discovery run with zero matched blocks exited $vac_rc without the anti-vacuity error"
fi

# (12) ANTI-VACUITY: a discovery run that finds zero FILES is also an error.
empty_repo="$work/emptyrepo"
mkdir -p "$empty_repo"
( cd "$empty_repo" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
cp "$scanner" "$empty_repo/scanner.sh"
( cd "$empty_repo" && git add -A >/dev/null 2>&1 )
empty_out="$(cd "$empty_repo" && bash ./scanner.sh 2>&1)"
empty_rc=$?
if [[ "$empty_rc" -eq 2 && "$empty_out" == *"discovered zero files"* ]]; then
  ok "discovery run with zero discovered files exits 2 loudly (anti-vacuity)"
else
  bad "discovery run with zero discovered files exited $empty_rc without the anti-vacuity error"
fi

# (13) Prose and NON-bash fences are ignored — this doc corpus discusses
# `$(cmd)` constantly in tables and prose (bash-refusal-triggers.md's whole
# experiment table is written that way).
prose_md="$work/prose.md"
cat > "$prose_md" <<'FIXTURE'
Write the assignment on its own line — `some-script "$(git rev-parse --show-toplevel)"` is refused.

| Shape | Verdict |
|---|---|
| `$(cmd)` in argument position | REFUSED |

```text
$(not-bash)
```

```json
{"tpl": "$(also-not-bash)"}
```
FIXTURE
if bash "$scanner" "$prose_md" >/dev/null 2>&1; then
  ok "scanner ignores prose, tables, and non-bash fences"
else
  out="$(bash "$scanner" "$prose_md" 2>&1)"
  bad "scanner FALSE-POSITIVED on prose / a non-bash fence: $out"
fi

# (14) The `<!-- command-substitution-scan: allow -->` directive exempts
# exactly the following block — and ONLY that block. The paired planted
# violation in a later, unmarked block must still be caught, so the directive
# can't be mistaken for a file-level opt-out.
allow_md="$work/allow.md"
cat > "$allow_md" <<'FIXTURE'
<!-- command-substitution-scan: allow -->
```bash
until [ "$(gh run view 1 --jq .status)" = "completed" ]; do sleep 30; done
```
FIXTURE
if bash "$scanner" "$allow_md" >/dev/null 2>&1; then
  ok "an allow directive exempts the following block"
else
  out="$(bash "$scanner" "$allow_md" 2>&1)"
  bad "an allow directive should have exempted the following block: $out"
fi

allow_scope_md="$work/allow-scope.md"
cat > "$allow_scope_md" <<'FIXTURE'
<!-- command-substitution-scan: allow -->
```bash
until [ "$(gh run view 1 --jq .status)" = "completed" ]; do sleep 30; done
```

```bash
bash some-script.sh "$(still-flagged)"
```
FIXTURE
if bash "$scanner" "$allow_scope_md" >/dev/null 2>&1; then
  bad "an allow directive leaked past its own block (the later violation was not caught)"
else
  out="$(bash "$scanner" "$allow_scope_md" 2>&1)"
  # shellcheck disable=SC2016  # literal needles grepped from output, not expansions
  if [[ "$out" == *'$(still-flagged)'* && "$out" != *'gh run view'* ]]; then
    ok "an allow directive scopes to exactly one block (later violation still caught)"
  else
    bad "allow-directive scoping is wrong — output: $out"
  fi
fi

# (15) A nonexistent path errors with exit 2, never a silent pass.
if bash "$scanner" "$work/does-not-exist.md" >/dev/null 2>&1; then
  bad "scanner should error (not silently pass) on a nonexistent file"
else
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    ok "scanner exits 2 on a nonexistent file argument"
  else
    bad "scanner exited $rc (expected 2) on a nonexistent file argument"
  fi
fi

# (16) THE REGRESSION ASSERTION: the real repo's whole plugin markdown tree is
# clean. This is what #1314's sweep bought — and what any future edit
# reintroducing an argument-position substitution will fail against.
real_out="$(bash "$scanner" 2>&1)"
real_rc=$?
if [[ "$real_rc" -eq 0 ]]; then
  ok "discovery run over the real plugins/ tree reports clean"
else
  bad "discovery run over the real plugins/ tree found argument-position substitutions: $real_out"
fi

# (17) ANTI-VACUITY floor on the REAL corpus. The clean verdict in (16) is only
# meaningful if the fence matcher actually walked a substantial number of
# blocks — #1312's finding was a matcher that had silently dropped to 0 while
# still reporting success. The floor is deliberately well below the observed
# count (570 blocks across 132 files at #1314's fix time) so ordinary spec
# churn doesn't trip it, but a matcher that breaks outright does.
real_blocks="$(printf '%s\n' "$real_out" | sed -n 's/.*, \([0-9][0-9]*\) fenced bash block(s) scanned.*/\1/p' | tail -1)"
[[ -n "$real_blocks" ]] || real_blocks=0
if [[ "$real_blocks" -ge 300 ]]; then
  ok "discovery run walked $real_blocks fenced bash blocks (floor 300; 570 observed at #1314)"
else
  bad "discovery run walked only $real_blocks fenced bash blocks — below the 300 floor; the fence matcher may have broken (#1312)"
fi


echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

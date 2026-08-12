#!/usr/bin/env bash
# Test: the decorative-brace-expansion gate (issue #1311).
#
# Background — issues #1308 -> #1311: #1308 isolated the real worktree-
# isolation refusal trigger (a braced `${VAR}` parameter expansion, plus
# `$(cmd)` in ARGUMENT position) after four consecutive issues each blamed a
# different wrong axis, and swept all 246 `${CLAUDE_PLUGIN_ROOT}` occurrences
# to the unbraced spelling with CI enforcement in
# `claude-plugin-root-preamble.test.sh` (checks 3b + 3c). #1311 swept the
# remaining decorative occurrences across ~80 other variable names and added
# `scripts/brace-expansion-scan.sh` as the general enforcement — a fence-aware
# scanner that flags the closing-brace form `${NAME}` inside ```bash blocks
# while leaving every modifier form (`${VAR:-x}`, `${#a[@]}`, `${V%.md}`)
# legal.
#
# Every positive assertion below is paired with a PLANTED VIOLATION so the
# scanner is proven to fail on a real finding rather than trivially exiting 0
# (see tests 3-6 and 12). Tests 10/11 additionally guard the vacuous-pass
# shape #1312 found in the pre-existing preamble test: a matcher that stops
# matching must fail loudly, not report success over zero blocks.
#
# Pure bash + awk. Run with:
#   bash plugins/shipyard/scripts/tests/brace-expansion-scan.test.sh

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

scanner="$repo_root/plugins/shipyard/scripts/brace-expansion-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

echo "brace-expansion-scan gate regression tests (issue #1311)"
echo

# (1) The scanner exists and is executable as a bash script.
if [[ -f "$scanner" ]]; then
  ok "scripts/brace-expansion-scan.sh exists"
else
  bad "scripts/brace-expansion-scan.sh is missing (expected at $scanner)"
  echo
  echo "  ${pass} passed, ${fail} failed"
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# (2) A block using ONLY unbraced expansions passes clean.
clean_md="$work/clean.md"
cat > "$clean_md" <<'FIXTURE'
# Heading

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
bash "$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get ci.settled_minutes
git worktree add "$WORKTREE_PATH" -b "do-work/issue-7" "origin/$DEFAULT_BRANCH"
```
FIXTURE
if bash "$scanner" "$clean_md" >/dev/null 2>&1; then
  ok "scanner exits 0 on a block using only unbraced expansions"
else
  bad "scanner FALSE-POSITIVED on a block using only unbraced expansions"
fi

# (3) PLANTED VIOLATION: a decorative `${NAME}` in a path is flagged, and the
# finding names the offending expansion. This is the negative test that keeps
# test (2)'s clean exit from being vacuous.
planted_md="$work/planted.md"
cat > "$planted_md" <<'FIXTURE'
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get ci.settled_minutes
```
FIXTURE
if bash "$scanner" "$planted_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect a planted \${CLAUDE_PLUGIN_ROOT} violation (exited 0)"
else
  out="$(bash "$scanner" "$planted_md" 2>&1)"
  # shellcheck disable=SC2016  # literal needle grepped from output, not an expansion
  if [[ "$out" == *"decorative-brace-expansion"* && "$out" == *'${CLAUDE_PLUGIN_ROOT}'* ]]; then
    ok "scanner detects a planted \${CLAUDE_PLUGIN_ROOT} violation and names it"
  else
    bad "scanner exited non-zero but did not name the decorative-brace-expansion finding"
  fi
fi

# (4) PLANTED VIOLATION: a decorative `${NAME}` in a plain (non-path) argument
# is flagged too — #1308's experiment J proved path-forming is not the
# discriminator, so the scanner must not narrow to path-shaped sites.
arg_md="$work/arg.md"
cat > "$arg_md" <<'FIXTURE'
```bash
bash some-script.sh get "${SY_ARG}"
```
FIXTURE
if bash "$scanner" "$arg_md" >/dev/null 2>&1; then
  bad "scanner FAILED to detect a decorative brace in a plain argument (exited 0)"
else
  ok "scanner detects a decorative brace in a plain (non-path) argument"
fi

# (5) PLANTED VIOLATION: identifier-adjacent `${count}MB` IS flagged. It reads
# as decorative on sight, but de-bracing it would expand a DIFFERENT name —
# so it must surface for a hand rewrite rather than be silently exempted.
adjacent_md="$work/adjacent.md"
cat > "$adjacent_md" <<'FIXTURE'
```bash
echo "free=${disk_free_mb}MB < floor=${floor_mb}MB"
```
FIXTURE
if bash "$scanner" "$adjacent_md" >/dev/null 2>&1; then
  bad "scanner FAILED to flag identifier-adjacent \${disk_free_mb}MB (exited 0)"
else
  out="$(bash "$scanner" "$adjacent_md" 2>&1)"
  # shellcheck disable=SC2016  # literal needle grepped from output, not an expansion
  if [[ "$out" == *'${disk_free_mb}'* && "$out" == *'${floor_mb}'* ]]; then
    ok "scanner flags identifier-adjacent \${NAME}SUFFIX for hand rewrite"
  else
    bad "scanner exited non-zero but did not name both identifier-adjacent sites"
  fi
fi

# (6) PLANTED VIOLATION inside an UNQUOTED heredoc (<<EOF) is flagged — an
# unquoted heredoc body IS expanded, so a braced expansion there is real.
unquoted_hd_md="$work/unquoted-heredoc.md"
cat > "$unquoted_hd_md" <<'FIXTURE'
```bash
cat > out.txt <<EOF
version is ${VERSION}
EOF
```
FIXTURE
if bash "$scanner" "$unquoted_hd_md" >/dev/null 2>&1; then
  bad "scanner FAILED to flag a braced expansion inside an UNQUOTED heredoc (exited 0)"
else
  ok "scanner flags a braced expansion inside an unquoted (expanding) heredoc"
fi

# (7) Modifier forms are NEVER flagged — they have no unbraced spelling, so
# banning them would be unfixable. Covers default / length / subscript /
# trim / substitution.
modifier_md="$work/modifier.md"
cat > "$modifier_md" <<'FIXTURE'
```bash
FLOOR="${floor_mb:-10240}"
NAME="${VAR:=fallback}"
CHECK="${VAR:?must be set}"
ALT="${VAR:+present}"
COUNT="${#tests[@]}"
FIRST="${tests[0]}"
ALL="${tests[@]}"
STEM="${f%.md}"
TAIL="${f#prefix-}"
SUB="${f//a/b}"
```
FIXTURE
if bash "$scanner" "$modifier_md" >/dev/null 2>&1; then
  ok "scanner does NOT flag modifier expansions (:- := :? :+ # % // [@] [0])"
else
  out="$(bash "$scanner" "$modifier_md" 2>&1)"
  bad "scanner FALSE-POSITIVED on a modifier expansion: $out"
fi

# (8) A QUOTED heredoc body (<<'EOF') is skipped — its text is emitted
# literally, so de-bracing would change the emitted OUTPUT, not shell
# behavior. This is the per-site-review carve-out #1311 calls out by name.
quoted_hd_md="$work/quoted-heredoc.md"
cat > "$quoted_hd_md" <<'FIXTURE'
```bash
cat > template.sh <<'TEMPLATE'
echo "${LITERAL_PLACEHOLDER}"
TEMPLATE
```
FIXTURE
if bash "$scanner" "$quoted_hd_md" >/dev/null 2>&1; then
  ok "scanner skips a QUOTED heredoc body (literal, not expanded)"
else
  bad "scanner FALSE-POSITIVED inside a quoted heredoc body"
fi

# (9) Prose and NON-bash fences are ignored — this doc corpus discusses
# `${VAR}` constantly in tables and prose (bash-refusal-triggers.md's whole
# experiment table is written that way).
prose_md="$work/prose.md"
cat > "$prose_md" <<'FIXTURE'
Write `$VAR`, never `${VAR}` — the braces are what gets refused.

| Shape | Verdict |
|---|---|
| `${VAR}` | REFUSED |

```text
${NOT_BASH}
```

```json
{"tpl": "${ALSO_NOT_BASH}"}
```
FIXTURE
if bash "$scanner" "$prose_md" >/dev/null 2>&1; then
  ok "scanner ignores prose, tables, and non-bash fences"
else
  bad "scanner FALSE-POSITIVED on prose / a non-bash fence"
fi

# (10) ANTI-VACUITY: on a discovery run the scanner must fail loudly if the
# fence matcher matched zero blocks. Simulated by pointing the scanner at a
# repo whose plugins/ tree has markdown but no bash fences.
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

# (11) ANTI-VACUITY: a discovery run that finds zero FILES is also an error,
# not a clean pass.
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

# (12) The `<!-- brace-expansion-scan: allow -->` directive exempts exactly
# the following block — and ONLY that block. The paired planted violation in
# a later, unmarked block must still be caught, so the directive can't be
# mistaken for a file-level opt-out.
allow_md="$work/allow.md"
cat > "$allow_md" <<'FIXTURE'
<!-- brace-expansion-scan: allow -->
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh"
```
FIXTURE
if bash "$scanner" "$allow_md" >/dev/null 2>&1; then
  ok "an allow directive exempts the following block"
else
  bad "an allow directive should have exempted the following block"
fi

allow_scope_md="$work/allow-scope.md"
cat > "$allow_scope_md" <<'FIXTURE'
<!-- brace-expansion-scan: allow -->
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh"
```

```bash
bash "${STILL_FLAGGED}/scripts/bar.sh"
```
FIXTURE
if bash "$scanner" "$allow_scope_md" >/dev/null 2>&1; then
  bad "an allow directive leaked past its own block (the later violation was not caught)"
else
  out="$(bash "$scanner" "$allow_scope_md" 2>&1)"
  # shellcheck disable=SC2016  # literal needle grepped from output, not an expansion
  if [[ "$out" == *'${STILL_FLAGGED}'* && "$out" != *'${CLAUDE_PLUGIN_ROOT}'* ]]; then
    ok "an allow directive scopes to exactly one block (later violation still caught)"
  else
    bad "allow-directive scoping is wrong — output: $out"
  fi
fi

# (13) A nonexistent path errors with exit 2, never a silent pass.
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

# (14) THE REGRESSION ASSERTION: the real repo's whole plugin markdown tree is
# clean. This is what #1311's sweep bought — and what any future edit
# reintroducing a decorative brace will fail against.
real_out="$(bash "$scanner" 2>&1)"
real_rc=$?
if [[ "$real_rc" -eq 0 ]]; then
  ok "discovery run over the real plugins/ tree reports clean"
else
  bad "discovery run over the real plugins/ tree found decorative braces: $real_out"
fi

# (15) ANTI-VACUITY floor on the REAL corpus. The clean verdict in (14) is
# only meaningful if the fence matcher actually walked a substantial number of
# blocks — #1312's finding was a matcher that had silently dropped to 0 while
# still reporting success. The floor is deliberately well below the observed
# count (570 blocks across 132 files at #1311's fix time) so ordinary spec
# churn doesn't trip it, but a matcher that breaks outright does.
real_blocks="$(printf '%s\n' "$real_out" | sed -n 's/.*, \([0-9][0-9]*\) fenced bash block(s) scanned.*/\1/p' | tail -1)"
[[ -n "$real_blocks" ]] || real_blocks=0
if [[ "$real_blocks" -ge 300 ]]; then
  ok "discovery run walked $real_blocks fenced bash blocks (floor 300; 570 observed at #1311)"
else
  bad "discovery run walked only $real_blocks fenced bash blocks — below the 300 floor; the fence matcher may have broken (#1312)"
fi

# (16) The convention doc still documents the trigger this scanner enforces,
# and no longer carries the pre-#1311 "Not yet enforced" deferral.
triggers_doc="$repo_root/plugins/shipyard/commands/do-work/bash-refusal-triggers.md"
if [[ -f "$triggers_doc" ]]; then
  if grep -qF -- 'Not yet enforced' "$triggers_doc"; then
    bad "bash-refusal-triggers.md still carries the pre-#1311 'Not yet enforced' note — #1311 completed the sweep, so it should be gone"
  else
    ok "bash-refusal-triggers.md no longer carries the 'Not yet enforced' note (#1311 completed the sweep)"
  fi
  if grep -qF -- 'brace-expansion-scan.sh' "$triggers_doc"; then
    ok "bash-refusal-triggers.md names brace-expansion-scan.sh as the enforcement"
  else
    bad "bash-refusal-triggers.md does not name brace-expansion-scan.sh as the enforcement"
  fi
else
  bad "bash-refusal-triggers.md is missing (expected at $triggers_doc)"
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

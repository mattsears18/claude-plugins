#!/usr/bin/env bash
# Test: the unregistered-skill-reference gate (issue #1468).
#
# Background: #1467 gated the SCRIPT half of the executable-by-proxy reference
# family — a fenced bash block that names a repo script must name one that
# exists. #1468 closes the two remaining halves. This file is the enforcement
# for the third one: a spec that tells a worker to load `shipyard:<name>` must
# name an asset this plugin actually registers. A renamed or deleted skill
# directory would otherwise leave every live `Skill` invocation dangling with
# no CI signal — the same silent defect, one layer up from a dangling path.
#
# The gate found one live defect on the tree it was written against:
# `/shipyard:investigate`, cited twice in `commands/my-turn.md` as a command a
# human should run, which has never existed (investigate is a `/do-work` MODE).
# Test (3) plants that exact regression so it is reproduced verbatim rather
# than merely approximated.
#
# Every positive assertion is paired with a PLANTED VIOLATION so the scanner is
# proven to fail on a real finding rather than trivially exiting 0. Tests
# 11-13 guard the vacuous-pass shape #1312 found: a matcher that stops matching
# must fail loudly, not report success over zero work.
#
# Pure bash + awk + git. Run with:
#   bash plugins/shipyard/scripts/tests/spec-skill-references.test.sh

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

scanner="$repo_root/plugins/shipyard/scripts/spec-skill-reference-scan.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

echo "unregistered-skill-reference gate regression tests (issue #1468)"
echo

# (1) The scanner exists.
if [[ -f "$scanner" ]]; then
  ok "scripts/spec-skill-reference-scan.sh exists"
else
  bad "scripts/spec-skill-reference-scan.sh is missing (expected at $scanner)"
  echo
  echo "  ${pass} passed, ${fail} failed"
  exit 1
fi

# (1b) …and carries the git exec bit itself (#1395).
scanner_mode="$(git -C "$repo_root" ls-files -s -- plugins/shipyard/scripts/spec-skill-reference-scan.sh | awk '{print $1}')"
if [[ "$scanner_mode" == "100755" ]]; then
  ok "the scanner itself is recorded 100755 in the git index (#1395)"
else
  bad "the scanner's git index mode is '${scanner_mode:-<untracked>}', expected 100755 (git update-index --chmod=+x)"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# Explicit-path fixtures, scanned against the REAL repo's registry (the scanner
# builds it from `git ls-files` at cwd), so a fixture can name a genuinely
# registered asset and get an honest clean verdict.
# ---------------------------------------------------------------------------

# (2) Names that really are registered — one of each kind — pass clean.
clean_md="$work/clean.md"
cat > "$clean_md" <<'FIXTURE'
Load the `shipyard:worker-preamble` skill, then dispatch `shipyard:issue-worker`
and tell the human to run `/shipyard:do-work` afterwards.
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$clean_md" ) >/dev/null 2>&1; then
  ok "scanner exits 0 on registered skill / agent / command names"
else
  out="$( cd "$repo_root" && bash "$scanner" "$clean_md" 2>&1 )"
  bad "scanner FALSE-POSITIVED on registered asset names: $out"
fi

# (3) PLANTED VIOLATION — the actual #1468 defect, reproduced verbatim.
# `/shipyard:investigate` was cited in commands/my-turn.md as a command to run;
# no such command has ever existed.
regression_md="$work/regression.md"
cat > "$regression_md" <<'FIXTURE'
…that's `/shipyard:do-work`'s job (or `/shipyard:investigate`'s), and doing it
here spends the human's wall-clock producing something they didn't ask for.
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$regression_md" ) >/dev/null 2>&1; then
  bad "scanner FAILED to detect the #1468 regression (/shipyard:investigate) — exited 0"
else
  out="$( cd "$repo_root" && bash "$scanner" "$regression_md" 2>&1 )"
  if [[ "$out" == *"unregistered-skill-reference"* && "$out" == *"investigate"* ]]; then
    ok "scanner detects the #1468 regression and names the unregistered command"
  else
    bad "scanner exited non-zero but did not name the unregistered reference — output: $out"
  fi
fi

# (4) PLANTED VIOLATION — a deleted/renamed SKILL, the failure this class was
# filed for. Paired with (2)'s positive so it can't pass for the wrong reason.
skill_md="$work/skill.md"
cat > "$skill_md" <<'FIXTURE'
Before doing anything else, load the `shipyard:worker-preambel` skill.
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$skill_md" ) >/dev/null 2>&1; then
  bad "scanner FAILED to flag a misspelled/renamed skill name"
else
  out="$( cd "$repo_root" && bash "$scanner" "$skill_md" 2>&1 )"
  if [[ "$out" == *"worker-preambel"* ]]; then
    ok "scanner flags a renamed/deleted skill name"
  else
    bad "scanner exited non-zero but did not name the bad skill — output: $out"
  fi
fi

# (5) The reference is a NAME, not a path — a fence boundary carries no meaning
# for it, so a bad name inside a bash fence is flagged just the same.
fence_md="$work/fence.md"
cat > "$fence_md" <<'FIXTURE'
```bash
echo "dispatching shipyard:no-such-agent-at-all"
```
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$fence_md" ) >/dev/null 2>&1; then
  bad "scanner FAILED to flag an unregistered name inside a bash fence"
else
  ok "scanner flags an unregistered name inside a bash fence too (names aren't fence-scoped)"
fi

# (6) A repo coordinate is not a reference — `mattsears18/shipyard:` in a URL
# or a `owner/repo:ref` string must not be mistaken for a slash-command.
coord_md="$work/coord.md"
cat > "$coord_md" <<'FIXTURE'
See https://github.com/mattsears18/shipyard:main for the tree, and the mirror at
mattsears18/shipyard:no-such-thing-at-all which is a git ref, not a command.
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$coord_md" ) >/dev/null 2>&1; then
  ok "scanner does NOT treat owner/shipyard:<ref> as an asset reference"
else
  out="$( cd "$repo_root" && bash "$scanner" "$coord_md" 2>&1 )"
  bad "scanner FALSE-POSITIVED on a repo coordinate: $out"
fi

# (7) The file-scoped allow directive exempts exactly the tokens it names —
# and ONLY those, so it can't be mistaken for a file-level opt-out.
allow_md="$work/allow.md"
cat > "$allow_md" <<'FIXTURE'
<!-- spec-skill-reference-scan: allow shipyard:no-inline shipyard:inline-eligible -->

Humans pre-applying `shipyard:no-inline` force normal dispatch; the reverse
override is `shipyard:inline-eligible`.
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$allow_md" ) >/dev/null 2>&1; then
  ok "a file-scoped allow directive exempts the tokens it names"
else
  out="$( cd "$repo_root" && bash "$scanner" "$allow_md" 2>&1 )"
  bad "the allow directive should have exempted its declared tokens: $out"
fi

allow_scope_md="$work/allow-scope.md"
cat > "$allow_scope_md" <<'FIXTURE'
<!-- spec-skill-reference-scan: allow shipyard:no-inline -->

`shipyard:no-inline` is a label. `shipyard:still-not-registered` is not, and
must still be flagged.
FIXTURE
if ( cd "$repo_root" && bash "$scanner" "$allow_scope_md" ) >/dev/null 2>&1; then
  bad "the allow directive leaked past the tokens it declared"
else
  out="$( cd "$repo_root" && bash "$scanner" "$allow_scope_md" 2>&1 )"
  if [[ "$out" == *"still-not-registered"* && "$out" != *"no-inline"* ]]; then
    ok "the allow directive scopes to exactly its declared tokens"
  else
    bad "allow-directive scoping is wrong — output: $out"
  fi
fi

# ---------------------------------------------------------------------------
# Synthetic-repo fixtures. The registry is built from the git index at cwd, so
# the depth rules and the slash-invocability rule are exercised against a
# purpose-built throwaway repo where the registry contents are known exactly.
# ---------------------------------------------------------------------------

# _mkrepo <dir> — a git repo with the scanner copied in at its root.
_mkrepo() {
  local d="$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  cp "$scanner" "$d/scanner.sh"
}

# (8) Registry depth rules: a NESTED spec fragment is not a registered asset.
# `commands/do-work/setup/04-backlog-divert.md` and
# `agents/issue-worker/issue-work.md` are reached by path, never by name, so
# folding them into the registry would let a dangling name resolve against an
# unrelated nested file.
depth_repo="$work/depthrepo"
_mkrepo "$depth_repo"
mkdir -p "$depth_repo/plugins/shipyard/commands/do-work" \
         "$depth_repo/plugins/shipyard/agents/issue-worker" \
         "$depth_repo/plugins/shipyard/skills/real-skill"
printf '# real\n' > "$depth_repo/plugins/shipyard/commands/do-work.md"
printf '# nested\n' > "$depth_repo/plugins/shipyard/commands/do-work/steady-state.md"
printf '# nested\n' > "$depth_repo/plugins/shipyard/agents/issue-worker/issue-work.md"
printf '# skill\n' > "$depth_repo/plugins/shipyard/skills/real-skill/SKILL.md"
( cd "$depth_repo" && git add -A ) >/dev/null 2>&1
depth_reg="$( cd "$depth_repo" && bash ./scanner.sh --registry 2>&1 )"
if [[ "$depth_reg" == *"command do-work"* && "$depth_reg" == *"skill real-skill"* \
      && "$depth_reg" != *"steady-state"* && "$depth_reg" != *"issue-work"* ]]; then
  ok "registry includes top-level commands/agents/skills and excludes nested fragments"
else
  bad "registry depth rules are wrong — got: $depth_reg"
fi

# shellcheck disable=SC2016  # fixture text emitted literally, not an expansion
printf 'Load `shipyard:steady-state` now.\n' > "$depth_repo/plugins/shipyard/commands/spec.md"
( cd "$depth_repo" && git add -A ) >/dev/null 2>&1
depth_out="$( cd "$depth_repo" && bash ./scanner.sh plugins/shipyard/commands/spec.md 2>&1 )"
if [[ "$depth_out" == *"unregistered-skill-reference"* && "$depth_out" == *"steady-state"* ]]; then
  ok "a name matching only a NESTED fragment is still flagged as unregistered"
else
  bad "a nested-fragment name should not resolve; got: $depth_out"
fi

# (9) Slash-invocability: `/shipyard:<agent>` is flagged even though the agent
# IS registered — agents are dispatched, never slash-invoked.
slash_repo="$work/slashrepo"
_mkrepo "$slash_repo"
mkdir -p "$slash_repo/plugins/shipyard/agents" "$slash_repo/plugins/shipyard/commands"
printf '# agent\n' > "$slash_repo/plugins/shipyard/agents/some-worker.md"
# shellcheck disable=SC2016  # fixture text emitted literally, not an expansion
printf 'Run `/shipyard:some-worker` to fix it.\n' > "$slash_repo/plugins/shipyard/commands/spec.md"
( cd "$slash_repo" && git add -A ) >/dev/null 2>&1
slash_out="$( cd "$slash_repo" && bash ./scanner.sh plugins/shipyard/commands/spec.md 2>&1 )"
if [[ "$slash_out" == *"non-invocable-slash-reference"* && "$slash_out" == *"agent"* ]]; then
  ok "a slash-invoked AGENT name is flagged as non-invocable"
else
  bad "expected a non-invocable-slash finding; got: $slash_out"
fi

# (9b) PAIRED POSITIVE: the same name WITHOUT the slash is fine — otherwise (9)
# could be passing merely because the name doesn't resolve at all.
# shellcheck disable=SC2016  # fixture text emitted literally, not an expansion
printf 'Dispatch `shipyard:some-worker` for that mode.\n' > "$slash_repo/plugins/shipyard/commands/spec.md"
if ( cd "$slash_repo" && bash ./scanner.sh plugins/shipyard/commands/spec.md ) >/dev/null 2>&1; then
  ok "the same agent name WITHOUT a leading slash is accepted"
else
  paired_out="$( cd "$slash_repo" && bash ./scanner.sh plugins/shipyard/commands/spec.md 2>&1 )"
  bad "a bare (non-slash) agent reference should be accepted: $paired_out"
fi

# (10) An asset present on disk but NOT tracked in the git index does not
# register — it does not ship to a plugin install, so "exists on my disk" is
# not the bar (matching the script scanner's posture).
untracked_repo="$work/untrackedrepo"
_mkrepo "$untracked_repo"
mkdir -p "$untracked_repo/plugins/shipyard/skills/ghost-skill" "$untracked_repo/plugins/shipyard/commands"
printf '# skill\n' > "$untracked_repo/plugins/shipyard/skills/ghost-skill/SKILL.md"
printf '# anchor\n' > "$untracked_repo/plugins/shipyard/commands/anchor.md"
( cd "$untracked_repo" && git add plugins/shipyard/commands/anchor.md ) >/dev/null 2>&1
# shellcheck disable=SC2016  # fixture text emitted literally, not an expansion
printf 'Load `shipyard:ghost-skill`.\n' > "$untracked_repo/plugins/shipyard/commands/spec.md"
untracked_out="$( cd "$untracked_repo" && bash ./scanner.sh plugins/shipyard/commands/spec.md 2>&1 )"
if [[ "$untracked_out" == *"unregistered-skill-reference"* && "$untracked_out" == *"ghost-skill"* ]]; then
  ok "an untracked-but-present skill does not register (index is the bar, not the disk)"
else
  bad "an untracked skill should not register; got: $untracked_out"
fi

# (11) ANTI-VACUITY: a discovery run that finds zero FILES is an error.
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

# (12) ANTI-VACUITY, floor 1 of 2 — the REGISTRY builder. A registry that
# silently under-builds must fail loudly; the token floor alone would not
# notice, because a small registry still lets a small corpus pass clean.
reg_repo="$work/regrepo"
_mkrepo "$reg_repo"
mkdir -p "$reg_repo/plugins/shipyard/commands"
printf '# only one asset\n' > "$reg_repo/plugins/shipyard/commands/solo.md"
( cd "$reg_repo" && git add -A ) >/dev/null 2>&1
reg_out="$( cd "$reg_repo" && bash ./scanner.sh 2>&1 )"
reg_rc=$?
if [[ "$reg_rc" -eq 2 && "$reg_out" == *"registered asset(s) — below the"* ]]; then
  ok "discovery run below the registry floor exits 2 loudly (anti-vacuity, #1468)"
else
  bad "discovery run with a near-empty registry exited $reg_rc without the registry-floor error"
fi

# (13) ANTI-VACUITY, floor 2 of 2 — the TOKEN matcher. A registry above its
# floor but ZERO references extracted is also an error: a broken token matcher
# is exactly as silent as a broken registry builder, and the registry floor
# alone would sail past it. This is the #1467 two-floors lesson, carried
# forward per #1468.
tok_repo="$work/tokrepo"
_mkrepo "$tok_repo"
mkdir -p "$tok_repo/plugins/shipyard/commands"
i=0
while [[ "$i" -lt 30 ]]; do
  printf '# asset %d\n' "$i" > "$tok_repo/plugins/shipyard/commands/asset-$i.md"
  i=$((i+1))
done
( cd "$tok_repo" && git add -A ) >/dev/null 2>&1
tok_out="$( cd "$tok_repo" && bash ./scanner.sh 2>&1 )"
tok_rc=$?
if [[ "$tok_rc" -eq 2 && "$tok_out" == *"reference(s) — below the"* ]]; then
  ok "discovery run below the token floor exits 2 loudly (anti-vacuity, #1468)"
else
  bad "discovery run with zero extracted tokens exited $tok_rc without the token-floor error"
fi

# (14) A nonexistent path argument errors with exit 2, never a silent pass.
( cd "$repo_root" && bash "$scanner" "$work/does-not-exist.md" ) >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 2 ]]; then
  ok "scanner exits 2 on a nonexistent file argument"
else
  bad "scanner exited $rc (expected 2) on a nonexistent file argument"
fi

# (15) --registry prints the resolved registry and exits 0.
reg_list="$( cd "$repo_root" && bash "$scanner" --registry 2>&1 )"
reg_list_rc=$?
reg_list_n="$(printf '%s\n' "$reg_list" | grep -c '^\(skill\|command\|agent\) ')"
if [[ "$reg_list_rc" -eq 0 && "$reg_list_n" -gt 0 ]]; then
  ok "--registry prints the resolved registry ($reg_list_n assets) and exits 0"
else
  bad "--registry exited $reg_list_rc with $reg_list_n entries"
fi

# (16) THE REGRESSION ASSERTION: the real repo's whole spec tree is clean —
# every shipyard: name a spec cites is a registered asset. This is what any
# future rename-without-updating-the-specs will fail against.
real_out="$( cd "$repo_root" && bash "$scanner" 2>&1 )"
real_rc=$?
if [[ "$real_rc" -eq 0 ]]; then
  ok "discovery run over the real plugins/shipyard/ tree reports clean"
else
  bad "discovery run over the real tree found unregistered references: $real_out"
fi

# (17) ANTI-VACUITY floors on the REAL corpus, asserted from the outside.
# (16)'s clean verdict is only meaningful if both the token matcher and the
# registry builder actually did substantial work. Floors sit well below the
# counts observed at #1468's fix time (1070 tokens / 55 assets).
real_tokens="$(printf '%s\n' "$real_out" | sed -n 's/.*, \([0-9][0-9]*\) shipyard: reference(s) checked.*/\1/p' | tail -1)"
real_assets="$(printf '%s\n' "$real_out" | sed -n 's/.*against \([0-9][0-9]*\) registered asset(s).*/\1/p' | tail -1)"
[[ -n "$real_tokens" ]] || real_tokens=0
[[ -n "$real_assets" ]] || real_assets=0
if [[ "$real_tokens" -ge 500 ]]; then
  ok "discovery run checked $real_tokens shipyard: references (floor 500; 1070 observed at #1468)"
else
  bad "discovery run checked only $real_tokens references — below the 500 floor (#1312)"
fi
if [[ "$real_assets" -ge 20 ]]; then
  ok "discovery run resolved $real_assets registered assets (floor 20; 55 observed at #1468)"
else
  bad "discovery run resolved only $real_assets registered assets — below the 20 floor (#1312)"
fi

echo
echo "  ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

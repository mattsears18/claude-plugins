#!/usr/bin/env bash
# Test: every bash code block in the /shipyard:do-work orchestrator + worker
# spec tree that references ${CLAUDE_PLUGIN_ROOT} also carries the canonical
# idempotent fallback-export preamble as its first non-blank line (or is a
# bare script-invocation block immediately preceded by a preamble-only
# block — the two-block idiom used in a few places, see (3) below).
#
# Background — issue #354: $CLAUDE_PLUGIN_ROOT expands to the empty string
# inside the Bash-tool subprocess shells the orchestrator uses. The very
# first templated invocation of /shipyard:do-work (setup.md step 0.4's
# `"${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" exists`) therefore
# evaluates as `/scripts/shipyard-config.sh` and exits 127. Every subsequent
# script invocation anywhere in the orchestrator or worker spec tree would
# fail the same way.
#
# The fix is an idempotent preamble at the top of every bash snippet:
#
#   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
#
# Semantics:
#   - When the harness DOES set $CLAUDE_PLUGIN_ROOT, the `${VAR:-default}`
#     short-circuits and the export is a no-op.
#   - When the harness does NOT set it (the observed steady-state for every
#     Bash-tool call inside this orchestrator), the fallback PROBES in order:
#       1. repo-local `<repo>/plugins/shipyard` IF it actually carries a
#          `scripts/` dir (the dogfooding case — shipyard's own checkout);
#       2. else the AUTHORITATIVE installed path from
#          `$HOME/.claude/plugins/installed_plugins.json` (the `installPath`
#          for `shipyard@shipyard`) IF it carries a `scripts/` dir (issue
#          #681). This is the loaded install under `cache/<mp>/<plugin>/
#          <version>/`, so it can never resolve to a stale backup or a
#          version-mismatched marketplace checkout;
#       3. else the marketplace install `$HOME/.claude/plugins/marketplaces/
#          */plugins/shipyard` (the consumer-install fallback — issue #417,
#          where a marketplace-installed shipyard runs against a repo that has
#          no repo-local plugins/shipyard). This glob is HARDENED (issue #681):
#          it tries the exact `marketplaces/shipyard` path first, EXCLUDES
#          `.bak`/`.old`/`.orig`/`.disabled` siblings (a `shipyard.bak` sorts
#          before the real dir because `.` < `/`, so the old `ls -d | head -1`
#          silently selected the backup), and requires a real `scripts/` dir;
#       4. else the repo-local path anyway (preserves a meaningful path for
#          error messaging when no layer resolves).
#
# This test is the regression guard: if anyone adds a new bash block that
# uses ${CLAUDE_PLUGIN_ROOT} without the preamble at its top, the test
# fails. Existing blocks were swept by the issue #354 PR; new ones (or
# any block whose preamble got moved / removed) regress here.
#
# --- File discovery (issue #910) -------------------------------------------
#
# Earlier versions of this test walked a hardcoded FILES array. Since #611
# split setup.md into a thin router + step-cluster sub-files under
# commands/do-work/setup/, setup.md itself carries ZERO ${CLAUDE_PLUGIN_ROOT}
# occurrences (they moved to the sub-files) — the array entry passed
# vacuously and covered nothing. Separately, dispatch-rules.md,
# skills/worker-preamble/SKILL.md (+ its on-demand fragments),
# agents/issue-worker/issue-work.md, and agents/issue-worker/fix-rebase.md
# all grew their own preamble-carrying bash blocks over time and were never
# added to the array either — 41 of 69 preamble occurrences (59%) had zero
# regression coverage at the time #910 was filed.
#
# Rather than append the missing filenames (which just recreates the same
# rot at the next reorg — see #611's own history), FILES below is discovered
# MECHANICALLY: every *.md file under the three directories that make up the
# do-work orchestrator + worker spec tree — commands/do-work/ (recursive,
# so a future setup/ or operate/ sub-file is swept in automatically),
# skills/worker-preamble/ (the skill + all its on-demand fragments), and
# agents/issue-worker/ (every per-mode worker spec) — is a candidate. A
# candidate with zero ${CLAUDE_PLUGIN_ROOT}-referencing bash blocks is a
# no-op (nothing to check), so this glob is safe to keep wide: adding a new
# file to any of these three directories costs nothing until it actually
# grows a bash block using the variable, at which point this test starts
# covering it with no manual edit required.
#
# Scope — explicitly the do-work orchestrator + worker spec tree. NOT
# version.md, eas-watch.md, init.md, or status.md: those are different
# surfaces with different rationales (version.md wants the *installed*
# plugin path, not the repo checkout; eas-watch.md runs in an Expo project
# where the repo's plugins/shipyard doesn't exist; status.md is invoked by
# the user, not templated into orchestrator output; init.md only mentions
# the variable in prose/JSON, never in a bash block).
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/claude-plugin-root-preamble.test.sh

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

# Directories that make up the do-work orchestrator + worker spec tree.
# Every *.md file under these (recursively) is a discovery candidate.
SCAN_DIRS=(
  "$repo_root/plugins/shipyard/commands/do-work"
  "$repo_root/plugins/shipyard/skills/worker-preamble"
  "$repo_root/plugins/shipyard/agents/issue-worker"
)

FILES=()
while IFS= read -r -d '' f; do
  FILES+=("$f")
done < <(find "${SCAN_DIRS[@]}" -type f -name '*.md' -print0 2>/dev/null | sort -z)

# The canonical preamble line. Anchored against literal text so any
# substitution (e.g. swapping the fallback path) trips this test. The
# preamble now embeds a single-quoted jq filter ('.plugins[...]'), so it
# can no longer live inside a single-quoted assignment — a quoted here-doc
# (<<'EOF') captures it verbatim with no escaping. Command substitution
# strips the trailing newline, so the value is exactly the one-line preamble.
EXPECTED_PREAMBLE=$(cat <<'PREAMBLE_EOF'
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else M=$(for d in "$HOME/.claude/plugins/marketplaces/shipyard/plugins/shipyard" "$HOME/.claude/plugins/marketplaces/"*/plugins/shipyard; do [[ "$d" == *.bak/* || "$d" == *.old/* || "$d" == *.orig/* || "$d" == *.disabled/* ]] && continue; [ -d "$d/scripts" ] && { echo "$d"; break; }; done); echo "${M:-$R/plugins/shipyard}"; fi; fi)}"
PREAMBLE_EOF
)

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() {
  printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"
  pass=$((pass+1))
}

assert_fail() {
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
  fail=$((fail+1))
}

echo "claude-plugin-root preamble regression tests (issue #354, discovery per #910)"
echo

# (1) Discovery sanity. A `find` scope regression (wrong repo_root, a
# directory rename that silently drops out of SCAN_DIRS) would make FILES
# empty and every subsequent check "pass" vacuously — exactly the
# false-confidence failure mode #910 was filed to close, just moved one
# layer down. Assert discovery actually found a non-trivial number of files,
# and that a small canary set of well-known phase/skill files — which must
# always exist under this scope — was among them.
if (( ${#FILES[@]} >= 10 )); then
  assert_pass "discovery found ${#FILES[@]} candidate *.md files under SCAN_DIRS"
else
  assert_fail "discovery found ${#FILES[@]} candidate *.md files under SCAN_DIRS (expected >= 10 — SCAN_DIRS or repo_root may be wrong)"
fi

CANARY_FILES=(
  "$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
  "$repo_root/plugins/shipyard/commands/do-work/drain.md"
  "$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
  "$repo_root/plugins/shipyard/commands/do-work/inline-trivial.md"
  "$repo_root/plugins/shipyard/skills/worker-preamble/SKILL.md"
)
for canary in "${CANARY_FILES[@]}"; do
  found=0
  for f in "${FILES[@]}"; do
    [[ "$f" == "$canary" ]] && { found=1; break; }
  done
  if (( found )); then
    assert_pass "discovery includes canary file $canary"
  else
    assert_fail "discovery includes canary file $canary (missing — SCAN_DIRS regressed)"
  fi
done

# (2) The canonical preamble is documented in setup step 0.3, so any
# reader of the spec can find the rationale for the pattern in one place.
# Since #611 split setup.md into a thin router + step-cluster sub-files,
# step 0.3 lives in do-work/setup/00-config-worktree.md.
SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/00-config-worktree.md"
if [[ -f "$SETUP_MD" ]]; then
  if grep -qF "### 0.3 \`CLAUDE_PLUGIN_ROOT\` re-export preamble" "$SETUP_MD"; then
    assert_pass "setup.md documents step 0.3 (preamble rationale)"
  else
    assert_fail "setup.md documents step 0.3 (preamble rationale)"
  fi

  if grep -qF "$EXPECTED_PREAMBLE" "$SETUP_MD"; then
    assert_pass "setup.md contains the canonical preamble line"
  else
    assert_fail "setup.md contains the canonical preamble line"
  fi
fi

# (3) Walk every bash code block in every discovered file, IN FILE ORDER.
# For each block that references ${CLAUDE_PLUGIN_ROOT}, the block passes if
# EITHER:
#   (a) its own first non-blank line is the canonical preamble
#       (the common, single-block idiom), OR
#   (b) the block is a bare script-invocation block (no preamble of its
#       own) immediately preceded — in the same file, skipping only prose
#       between fences — by a bash block whose ENTIRE content is the
#       canonical preamble line and nothing else (the two-block idiom used
#       by skills/worker-preamble/SKILL.md's step-0 / mid-session-anchoring
#       sections, which document the preamble once and then show two
#       different follow-up commands that reuse it).
#
# Walking is done by an awk one-liner that emits one line per bash block:
# "<block_start_line>|<has_ref 0/1>|<is_preamble_only 0/1>|<first_non_blank_line>"
walk_blocks() {
  local file="$1"
  awk -v expected="$EXPECTED_PREAMBLE" '
    BEGIN { in_block = 0 }

    # opening bash fence (any indent)
    /^[ \t]*```bash[ \t]*$/ {
      in_block = 1
      block_start = NR
      first_line = ""
      first_line_num = 0
      has_ref = 0
      nonblank_count = 0
      next
    }

    # closing fence
    /^[ \t]*```[ \t]*$/ {
      if (in_block) {
        stripped = first_line
        sub(/^[ \t]+/, "", stripped)
        is_preamble_only = (nonblank_count == 1 && stripped == expected) ? 1 : 0
        printf "%d|%d|%d|%s\n", block_start, has_ref, is_preamble_only, first_line
      }
      in_block = 0
      next
    }

    # inside a block
    in_block {
      if (/\$\{CLAUDE_PLUGIN_ROOT\}/) {
        has_ref = 1
      }
      if (/[^ \t]/) {
        nonblank_count++
        if (first_line == "") {
          first_line = $0
          first_line_num = NR
        }
      }
    }
  ' "$file"
}

offending_blocks=0
total_ref_blocks=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  prev_is_preamble_only=0
  while IFS='|' read -r fence_line has_ref is_preamble_only first_line; do
    if (( has_ref )); then
      total_ref_blocks=$((total_ref_blocks + 1))
      stripped_first="$first_line"
      # strip leading whitespace for comparison (preamble may be indented
      # to match the fence indent, e.g. inside a numbered list item).
      stripped_first="${stripped_first#"${stripped_first%%[![:space:]]*}"}"
      if [[ "$stripped_first" == "$EXPECTED_PREAMBLE" ]]; then
        : # (a) inline preamble — pass
      elif (( prev_is_preamble_only )); then
        : # (b) two-block idiom — pass
      else
        offending_blocks=$((offending_blocks + 1))
        assert_fail "$f: bash block at line $fence_line uses \${CLAUDE_PLUGIN_ROOT} but is not preceded by the canonical preamble (own first line, or an immediately preceding preamble-only block)"
        printf '         expected: %s\n' "$EXPECTED_PREAMBLE"
        printf '         got:      %s\n' "$first_line"
      fi
    fi
    prev_is_preamble_only=$is_preamble_only
  done < <(walk_blocks "$f")
done

if (( offending_blocks == 0 )); then
  assert_pass "all $total_ref_blocks bash blocks using \${CLAUDE_PLUGIN_ROOT} across ${#FILES[@]} scanned files carry the canonical preamble"
fi

# (4) Sanity check — the preamble itself must actually work. Run it in a
# clean shell and confirm $CLAUDE_PLUGIN_ROOT resolves to a path that
# contains the helper scripts. This is the runtime contract the docs
# encode; if the path computation regresses (e.g. someone changes
# "plugins/shipyard" to "plugin/shipyard"), this catches it.
sanity_dir=$(env -i HOME="$HOME" PATH="$PATH" bash -c "
  cd '$repo_root'
  $EXPECTED_PREAMBLE
  echo \"\$CLAUDE_PLUGIN_ROOT\"
")
if [[ -d "$sanity_dir" && -x "$sanity_dir/scripts/shipyard-config.sh" ]]; then
  assert_pass "preamble resolves to a directory containing scripts/shipyard-config.sh"
else
  assert_fail "preamble resolves to a directory containing scripts/shipyard-config.sh (got '$sanity_dir')"
fi

# (5) Consumer-install sanity check (issue #417). Simulate a marketplace
# install running against a repo with NO repo-local plugins/shipyard: the
# old bare `$(git rev-parse --show-toplevel)/plugins/shipyard` fallback
# resolved to a non-existent path and every helper call exited 127. The
# new probe must fall through to the marketplace install path.
#
# Build a throwaway sandbox: a fake $HOME containing a marketplace tree,
# and a fake consumer git repo with no plugins/shipyard dir. Then run the
# preamble with cd into the consumer repo and confirm it resolves to the
# marketplace path (not the missing repo-local one).
sandbox=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-417)
if [[ -n "$sandbox" && -d "$sandbox" ]]; then
  fake_home="$sandbox/home"
  fake_mp="$fake_home/.claude/plugins/marketplaces/shipyard/plugins/shipyard"
  mkdir -p "$fake_mp/scripts"
  # the probe only checks for the scripts/ dir on the repo-local branch and
  # returns the marketplace path verbatim, so an empty marketplace dir is
  # enough to prove the fall-through.
  consumer_repo="$sandbox/consumer"
  mkdir -p "$consumer_repo"
  ( cd "$consumer_repo" && git init -q 2>/dev/null )

  consumer_dir=$(env -i HOME="$fake_home" PATH="$PATH" bash -c "
    cd '$consumer_repo'
    $EXPECTED_PREAMBLE
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  ")
  if [[ "$consumer_dir" == "$fake_mp" ]]; then
    assert_pass "preamble falls through to marketplace install when repo has no plugins/shipyard (issue #417)"
  else
    assert_fail "preamble falls through to marketplace install when repo has no plugins/shipyard (got '$consumer_dir', expected '$fake_mp')"
  fi
  rm -rf "$sandbox"
else
  assert_fail "could not create sandbox for consumer-install sanity check"
fi

# (6) Authoritative-install preference over a shadowing .bak (issue #681).
# The old fallback globbed `marketplaces/*/plugins/shipyard | head -1`, and
# because `.` (0x2E) sorts before `/` (0x2F), a `shipyard.bak` sibling sorted
# BEFORE the real `shipyard` dir and won `head -1` — so a stale backup copy
# shadowed the live install. Worse, the glob targets `marketplaces/` while the
# actually-installed plugin lives under `cache/<mp>/<plugin>/<version>/`, so
# even without a .bak the two could differ in version. The fix probes
# `installed_plugins.json`'s installPath FIRST (the authoritative pointer to
# the loaded install). This scenario proves the cache install wins over BOTH
# a shadowing .bak and a real marketplace dir.
sandbox=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-681)
if [[ -n "$sandbox" && -d "$sandbox" ]]; then
  fake_home="$sandbox/home"
  cache_install="$fake_home/.claude/plugins/cache/shipyard/shipyard/9.9.9"
  bak_mp="$fake_home/.claude/plugins/marketplaces/shipyard.bak/plugins/shipyard"
  real_mp="$fake_home/.claude/plugins/marketplaces/shipyard/plugins/shipyard"
  mkdir -p "$cache_install/scripts" "$bak_mp/scripts" "$real_mp/scripts"
  mkdir -p "$fake_home/.claude/plugins"
  printf '{"plugins":{"shipyard@shipyard":[{"installPath":"%s"}]}}\n' \
    "$cache_install" > "$fake_home/.claude/plugins/installed_plugins.json"
  consumer_repo="$sandbox/consumer"
  mkdir -p "$consumer_repo"
  ( cd "$consumer_repo" && git init -q 2>/dev/null )

  resolved=$(env -i HOME="$fake_home" PATH="$PATH" bash -c "
    cd '$consumer_repo'
    $EXPECTED_PREAMBLE
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  ")
  if [[ "$resolved" == "$cache_install" ]]; then
    assert_pass "preamble prefers installed_plugins.json installPath over a shadowing .bak marketplace (issue #681)"
  else
    assert_fail "preamble prefers installed_plugins.json installPath (got '$resolved', expected '$cache_install')"
  fi
  rm -rf "$sandbox"
else
  assert_fail "could not create sandbox for authoritative-install sanity check (#681)"
fi

# (7) .bak exclusion in the marketplace-glob fallback (issue #681). When
# installed_plugins.json is unreadable, the fallback still globs the
# marketplace tree — but it must EXCLUDE `.bak`/`.old`/`.orig`/`.disabled`
# siblings and prefer the exact `marketplaces/shipyard` path, rather than
# blindly taking the sort-first `head -1` (which the .bak dir would win).
sandbox=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-681b)
if [[ -n "$sandbox" && -d "$sandbox" ]]; then
  fake_home="$sandbox/home"
  bak_mp="$fake_home/.claude/plugins/marketplaces/shipyard.bak/plugins/shipyard"
  real_mp="$fake_home/.claude/plugins/marketplaces/shipyard/plugins/shipyard"
  # Both present, no installed_plugins.json. `ls -d` would sort .bak first.
  mkdir -p "$bak_mp/scripts" "$real_mp/scripts"
  consumer_repo="$sandbox/consumer"
  mkdir -p "$consumer_repo"
  ( cd "$consumer_repo" && git init -q 2>/dev/null )

  resolved=$(env -i HOME="$fake_home" PATH="$PATH" bash -c "
    cd '$consumer_repo'
    $EXPECTED_PREAMBLE
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  ")
  if [[ "$resolved" == "$real_mp" ]]; then
    assert_pass "marketplace-glob fallback excludes .bak and picks the real marketplace dir (issue #681)"
  else
    assert_fail "marketplace-glob fallback should skip .bak (got '$resolved', expected '$real_mp')"
  fi
  rm -rf "$sandbox"
else
  assert_fail "could not create sandbox for .bak-exclusion sanity check (#681)"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
if (( fail > 0 )); then
  exit 1
fi
exit 0

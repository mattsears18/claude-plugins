#!/usr/bin/env bash
# Test: every bash code block in the /shipyard:do-work orchestrator + worker
# spec tree that references ${CLAUDE_PLUGIN_ROOT} also carries a valid
# preamble as its first non-blank line(s) — either the canonical compound
# fallback-export (or a bare script-invocation block immediately preceded by
# a preamble-only block — the two-block idiom used in a few places, see (3)
# below), OR, for ORCHESTRATOR-PHASE files only (commands/do-work/**), the
# post-relocation stash-read two-liner (issue #1181 — see below).
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
#   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
#
# Semantics:
#   - When the harness DOES set $CLAUDE_PLUGIN_ROOT, the `${VAR:-default}`
#     short-circuits and the export is a no-op.
#   - When the harness does NOT set it (the observed steady-state for every
#     Bash-tool call inside this orchestrator), the fallback PROBES two
#     install layouts in order (issue #883 collapsed this from four layers
#     to two — see below):
#       1. repo-local `<repo>/plugins/shipyard` IF it actually carries a
#          `scripts/` dir (the dogfooding case — shipyard's own checkout).
#          Kept unconditionally: #907 is the governing decision on whether
#          this layer survives, and it kept it (added a staleness warning,
#          did not remove the layer);
#       2. else the AUTHORITATIVE installed path from
#          `$HOME/.claude/plugins/installed_plugins.json` (the `installPath`
#          for `shipyard@shipyard`) IF it carries a `scripts/` dir (issue
#          #681). This is the loaded install under `cache/<mp>/<plugin>/
#          <version>/`, and it resolves identically for the maintainer's own
#          installs and for any marketplace consumer — it isn't a special
#          case;
#       3. else the repo-local path anyway (preserves a meaningful path for
#          error messaging when neither layer above resolves).
#
#   Collapsed from four layers to two (issue #883): the preamble used to
#   ALSO glob `$HOME/.claude/plugins/marketplaces/*/plugins/shipyard` as a
#   third layer (hardened against a shadowing `.bak` sibling and a
#   version-mismatched marketplace checkout — issue #681/#417), used only
#   when installed_plugins.json was unreadable or missing the
#   `shipyard@shipyard` entry. installed_plugins.json is populated by the
#   harness's own plugin manager for every install method (verified
#   directly against the maintainer's own install before this collapse
#   landed — see #883's decision comment), so that third layer was pure
#   dead weight in practice. Dropping it saves ~350 bytes per occurrence
#   (~696 -> ~403 bytes) while keeping the one layer that's both
#   authoritative and universal. Helper-script extraction (source a
#   `resolve-plugin-root.sh`) was proposed and explicitly rejected for this
#   same issue: every occurrence runs in a fresh, hermetic subshell, so
#   sourcing a helper first requires re-deriving $CLAUDE_PLUGIN_ROOT to
#   locate it — the circularity this whole preamble exists to avoid.
#
# This test is the regression guard: if anyone adds a new bash block that
# uses $CLAUDE_PLUGIN_ROOT without a valid preamble at its top, the test
# fails. Existing blocks were swept by the issue #354 PR (then shrunk in
# place by issue #883); new ones (or any block whose preamble got moved /
# removed / reverted to the old four-layer form) regress here.
#
# --- Unbraced-expansion convention (issue #1308) ---------------------------
#
# Every INVOCATION site spells the variable unbraced — `$CLAUDE_PLUGIN_ROOT`,
# never `${CLAUDE_PLUGIN_ROOT}`. The braced form is refused outright by the
# harness's worktree-isolation guard once a session is isolated in a worktree
# ("this command is too complex to verify that it stays inside the worktree"),
# and that refusal fires on the BRACES, not on statement count, loop shape,
# block length, or whether the expansion sits in command position — the four
# axes issues #1182 / #1277 / #1289 / #1291 each decomposed in turn without
# stopping the refusals. See setup/00-config-worktree.md step 0.3 for the
# controlled experiment table that isolated it.
#
# Two consequences for this test:
#
#   - `has_ref` below matches the UNBRACED spelling. Matching only the braced
#     form after the #1308 sweep would make every check pass vacuously across
#     zero blocks — an absence-assertion that observed nothing, which is not a
#     pass (see worker-preamble's ci-pitfalls.md). Check (3b) asserts a floor
#     on the observed block count so that failure mode can't recur silently.
#   - Check (8) bans the braced spelling outright, repo-wide across the
#     plugin's markdown. That is the actual convention guard: without it, a
#     re-braced call site would simply drop out of coverage rather than fail.
#
# The one place the braced spelling legitimately survives is the canonical
# preamble itself (`${CLAUDE_PLUGIN_ROOT:-...}`) — `${VAR:-default}` has no
# unbraced spelling in POSIX shell. That is exactly why the preamble is
# PRE-RELOCATION-ONLY and why the stash-read form below exists for everything
# after it. Check (8) matches the braced form with a CLOSING brace only, so
# the `:-` default form is untouched.
#
# --- Post-relocation stash-read form (issue #1181) --------------------------
#
# The compound preamble above is refused by the harness once the orchestrator
# session is isolated in its own worktree ("this command is too complex to
# verify that it stays inside the worktree") — so it is only valid PRE-
# relocation: do-work/setup/00-config-worktree.md's steps 0.3, 0.4, and the
# pre-EnterWorktree timing-start bracket at the top of step 0.5. Step 0.5
# resolves CLAUDE_PLUGIN_ROOT post-relocation via a decomposed (non-compound)
# sequence of plain commands and stashes the result to
# `<orch-worktree>/.shipyard-plugin-root` — every other ORCHESTRATOR-PHASE
# block (everything under commands/do-work/, recursively — steady-state.md,
# drain.md, cleanup-summary.md, inline-trivial.md, dispatch-rules.md, and the
# rest of setup/) reads it back with the plain, non-compound two-liner:
#
#   CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
#   export CLAUDE_PLUGIN_ROOT
#
# WORKER-SIDE files (skills/worker-preamble/**, agents/issue-worker/**) are a
# separate case and are NOT eligible for this stash-read form: a dispatched
# worker runs in its own agent-* worktree with no .shipyard-plugin-root
# stash of its own (it gets the resolved literal via its dispatch prompt
# instead, per issue #965) — the compound block there is the worker's own
# fallback for when that literal is missing, and stays required.
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
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
PREAMBLE_EOF
)

# The post-relocation stash-read preamble (issue #1181) — the ONLY other
# valid form, and only for orchestrator-phase files (see ORCH_PHASE_DIR
# below). Two lines: a `cat` of the step-0.5 stash, then a plain export.
# shellcheck disable=SC2016  # literal text — must NOT expand $(...)
EXPECTED_STASH_LINE1='CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)'
EXPECTED_STASH_LINE2='export CLAUDE_PLUGIN_ROOT'

# Orchestrator-phase scope: everything under commands/do-work/ (recursively).
# Worker-side files (skills/worker-preamble/**, agents/issue-worker/**) are
# NOT in this directory and stay compound-preamble-only.
ORCH_PHASE_DIR="$repo_root/plugins/shipyard/commands/do-work"

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
#   (a) its own first non-blank line is the canonical compound preamble
#       (the common, single-block idiom), OR
#   (b) the block is a bare script-invocation block (no preamble of its
#       own) immediately preceded — in the same file, skipping only prose
#       between fences — by a bash block whose ENTIRE content is the
#       canonical preamble line and nothing else (the two-block idiom used
#       by skills/worker-preamble/SKILL.md's step-0 / mid-session-anchoring
#       sections, which document the preamble once and then show two
#       different follow-up commands that reuse it), OR
#   (c) — ORCHESTRATOR-PHASE FILES ONLY (issue #1181) — its own first two
#       non-blank lines are the post-relocation stash-read two-liner
#       (`CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root ...)` then
#       `export CLAUDE_PLUGIN_ROOT`). NOT a valid form for worker-side files
#       (skills/worker-preamble/**, agents/issue-worker/**) — those keep (a)
#       or (b) only.
#
# Walking is done by an awk one-liner that emits one line per bash block:
# "<block_start_line>|<has_ref 0/1>|<is_preamble_only 0/1>|<first_non_blank_line>|<second_non_blank_line>"
walk_blocks() {
  local file="$1"
  awk -v expected="$EXPECTED_PREAMBLE" '
    BEGIN { in_block = 0 }

    # opening bash fence (any indent)
    /^[ \t]*```bash[ \t]*$/ {
      in_block = 1
      block_start = NR
      first_line = ""
      second_line = ""
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
        printf "%d|%d|%d|%s|%s\n", block_start, has_ref, is_preamble_only, first_line, second_line
      }
      in_block = 0
      next
    }

    # inside a block
    in_block {
      # Unbraced spelling only (issue #1308) — `$CLAUDE_PLUGIN_ROOT` followed
      # by a non-identifier character or end-of-line. Deliberately does NOT
      # match `${CLAUDE_PLUGIN_ROOT:-...}` (the char after `$` is `{`), so a
      # preamble-only block still reports has_ref=0 and is recognised as the
      # leading block of the two-block idiom.
      if (/\$CLAUDE_PLUGIN_ROOT([^A-Za-z0-9_]|$)/) {
        has_ref = 1
      }
      if (/[^ \t]/) {
        nonblank_count++
        if (first_line == "") {
          first_line = $0
          first_line_num = NR
        } else if (second_line == "") {
          second_line = $0
        }
      }
    }
  ' "$file"
}

offending_blocks=0
total_ref_blocks=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  case "$f" in
    "$ORCH_PHASE_DIR"/*) is_orch_phase=1 ;;
    *)                   is_orch_phase=0 ;;
  esac
  prev_is_preamble_only=0
  while IFS='|' read -r fence_line has_ref is_preamble_only first_line second_line; do
    if (( has_ref )); then
      total_ref_blocks=$((total_ref_blocks + 1))
      stripped_first="$first_line"
      # strip leading whitespace for comparison (preamble may be indented
      # to match the fence indent, e.g. inside a numbered list item).
      stripped_first="${stripped_first#"${stripped_first%%[![:space:]]*}"}"
      stripped_second="$second_line"
      [[ -n "$stripped_second" ]] && stripped_second="${stripped_second#"${stripped_second%%[![:space:]]*}"}"
      if [[ "$stripped_first" == "$EXPECTED_PREAMBLE" ]]; then
        : # (a) inline compound preamble — pass
      elif (( prev_is_preamble_only )); then
        : # (b) two-block idiom — pass
      elif (( is_orch_phase )) && [[ "$stripped_first" == "$EXPECTED_STASH_LINE1" && "$stripped_second" == "$EXPECTED_STASH_LINE2" ]]; then
        : # (c) post-relocation stash-read two-liner, orchestrator-phase only — pass
      else
        offending_blocks=$((offending_blocks + 1))
        assert_fail "$f: bash block at line $fence_line uses \${CLAUDE_PLUGIN_ROOT} but is not preceded by a valid preamble (own first line, an immediately preceding preamble-only block, or — orchestrator-phase files only — the stash-read two-liner)"
        printf '         expected either: %s\n' "$EXPECTED_PREAMBLE"
        if (( is_orch_phase )); then
          printf '                     or: %s / %s\n' "$EXPECTED_STASH_LINE1" "$EXPECTED_STASH_LINE2"
        fi
        printf '         got:             %s\n' "$first_line"
      fi
    fi
    prev_is_preamble_only=$is_preamble_only
  done < <(walk_blocks "$f")
done

if (( offending_blocks == 0 )); then
  assert_pass "all $total_ref_blocks bash blocks using \$CLAUDE_PLUGIN_ROOT across ${#FILES[@]} scanned files carry a valid preamble"
fi

# (3b) Vacuous-pass guard (issue #1308). Check (3) above is an ABSENCE
# assertion: it only reports offending blocks, so a `has_ref` pattern that
# stops matching — because the spelling convention changed underneath it, as
# it did during the #1308 sweep — turns the whole check into "0 blocks
# examined, 0 offences found, PASS". That is a pass over nothing, not a pass.
# #910 closed the same failure shape one layer up (an empty FILES array);
# this closes it at the block layer. The floor is deliberately well below the
# real count (~180 at the time of writing) so ordinary spec churn never trips
# it — only a matcher that has gone blind.
REF_BLOCK_FLOOR=100
if (( total_ref_blocks >= REF_BLOCK_FLOOR )); then
  assert_pass "block-level discovery observed $total_ref_blocks \$CLAUDE_PLUGIN_ROOT blocks (>= floor $REF_BLOCK_FLOOR)"
else
  assert_fail "block-level discovery observed only $total_ref_blocks \$CLAUDE_PLUGIN_ROOT blocks (expected >= $REF_BLOCK_FLOOR — the has_ref matcher has likely gone blind, making check (3) pass vacuously; see issue #1308)"
fi

# (3c) Convention guard (issue #1308). The BRACED spelling
# `${CLAUDE_PLUGIN_ROOT}` is refused by the harness worktree-isolation guard
# in every isolated session, so no invocation site may use it. Scanned across
# the whole plugin's markdown (not just SCAN_DIRS): the refusal is a property
# of the shell syntax, so it applies identically to /shipyard:my-turn,
# /shipyard:file-issue, the auditor skills, and every other surface that
# templates a helper invocation.
#
# The pattern requires a CLOSING brace, so the canonical preamble's
# `${CLAUDE_PLUGIN_ROOT:-...}` default-expansion is deliberately NOT matched —
# it has no unbraced spelling and is pre-relocation-only by design (#1181).
# Exactly ONE file is exempt: the fragment that documents the ban. It quotes
# the braced spelling in its controlled-experiment table, so a blanket scan
# would flag the documentation of the rule as a violation of it. The exemption
# is a single named path, and its existence is asserted below — a rename or
# deletion must not silently widen the hole into "no file is scanned".
BRACE_DOC_EXEMPT="plugins/shipyard/commands/do-work/bash-refusal-triggers.md"

PLUGIN_ROOT_DIR="$repo_root/plugins/shipyard"
if [[ -f "$repo_root/$BRACE_DOC_EXEMPT" ]]; then
  assert_pass "brace-ban exemption target exists ($BRACE_DOC_EXEMPT)"
else
  assert_fail "brace-ban exemption target is missing ($BRACE_DOC_EXEMPT) — the exemption below would silently apply to nothing; re-point it or drop it"
fi

# shellcheck disable=SC2016  # literal search text — must NOT expand
braced_hits=$(grep -rlF '${CLAUDE_PLUGIN_ROOT}' "$PLUGIN_ROOT_DIR" --include='*.md' 2>/dev/null \
  | grep -vF "$repo_root/$BRACE_DOC_EXEMPT" | sort)
if [[ -z "$braced_hits" ]]; then
  assert_pass "no braced \${CLAUDE_PLUGIN_ROOT} spelling anywhere in the plugin's markdown (issue #1308)"
else
  assert_fail "braced \${CLAUDE_PLUGIN_ROOT} found — the harness refuses this form in an isolated session; use the unbraced \$CLAUDE_PLUGIN_ROOT (issue #1308)"
  while IFS= read -r hit; do
    printf '         %s\n' "${hit#"$repo_root/"}"
  done <<< "$braced_hits"
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

# (5) Consumer-install sanity check (issue #417, re-verified after the
# #883 layer collapse). Simulate a marketplace-installed shipyard running
# against a repo with NO repo-local plugins/shipyard: the probe must fall
# through repo-local (layer 1 fails) to installed_plugins.json's
# installPath (layer 2) — the one layer that replaces the old layers 2+3.
#
# Build a throwaway sandbox: a fake $HOME with an installed_plugins.json
# pointing at a cache install, and a fake consumer git repo with no
# plugins/shipyard dir. Then run the preamble with cd into the consumer
# repo and confirm it resolves to the cache install path.
sandbox=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-417)
if [[ -n "$sandbox" && -d "$sandbox" ]]; then
  fake_home="$sandbox/home"
  cache_install="$fake_home/.claude/plugins/cache/shipyard/shipyard/9.9.9"
  mkdir -p "$cache_install/scripts"
  mkdir -p "$fake_home/.claude/plugins"
  printf '{"plugins":{"shipyard@shipyard":[{"installPath":"%s"}]}}\n' \
    "$cache_install" > "$fake_home/.claude/plugins/installed_plugins.json"
  consumer_repo="$sandbox/consumer"
  mkdir -p "$consumer_repo"
  ( cd "$consumer_repo" && git init -q 2>/dev/null )

  consumer_dir=$(env -i HOME="$fake_home" PATH="$PATH" bash -c "
    cd '$consumer_repo'
    $EXPECTED_PREAMBLE
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  ")
  if [[ "$consumer_dir" == "$cache_install" ]]; then
    assert_pass "preamble falls through to installed_plugins.json's installPath when repo has no plugins/shipyard (issue #417)"
  else
    assert_fail "preamble falls through to installed_plugins.json's installPath when repo has no plugins/shipyard (got '$consumer_dir', expected '$cache_install')"
  fi
  rm -rf "$sandbox"
else
  assert_fail "could not create sandbox for consumer-install sanity check"
fi

# (6) Malformed/partial installed_plugins.json entry falls through to the
# repo-local-anyway default rather than being trusted blindly (issue
# #883). Before the layer collapse, a malformed layer-2 entry (installPath
# set but no scripts/ dir — e.g. a stale or half-written record) fell
# through to layer 3 (the marketplace glob). That layer no longer exists,
# so the guard's fall-through destination changed to the final
# repo-local-anyway default — this proves the `-d "$I/scripts"` guard is
# still load-bearing post-collapse, not silently dead code.
sandbox=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-883)
if [[ -n "$sandbox" && -d "$sandbox" ]]; then
  fake_home="$sandbox/home"
  broken_install="$fake_home/.claude/plugins/cache/shipyard/shipyard/0.0.0"
  # installPath is recorded but the directory has NO scripts/ subdir —
  # simulates a stale/half-written installed_plugins.json entry.
  mkdir -p "$broken_install"
  mkdir -p "$fake_home/.claude/plugins"
  printf '{"plugins":{"shipyard@shipyard":[{"installPath":"%s"}]}}\n' \
    "$broken_install" > "$fake_home/.claude/plugins/installed_plugins.json"
  consumer_repo="$sandbox/consumer"
  mkdir -p "$consumer_repo"
  ( cd "$consumer_repo" && git init -q 2>/dev/null )
  # Canonicalize via `git rev-parse --show-toplevel` itself (the same call
  # the preamble makes) rather than the raw mktemp path — on macOS $TMPDIR
  # is a symlink (/var/... -> /private/var/...), so comparing against the
  # raw path would spuriously fail even though the preamble resolved
  # correctly.
  consumer_repo_canonical=$(cd "$consumer_repo" && git rev-parse --show-toplevel)

  resolved=$(env -i HOME="$fake_home" PATH="$PATH" bash -c "
    cd '$consumer_repo'
    $EXPECTED_PREAMBLE
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  ")
  expected_fallback="$consumer_repo_canonical/plugins/shipyard"
  if [[ "$resolved" == "$expected_fallback" ]]; then
    assert_pass "a malformed installed_plugins.json entry (no scripts/ dir) falls through to the repo-local-anyway default (issue #883)"
  else
    assert_fail "a malformed installed_plugins.json entry should fall through to repo-local-anyway (got '$resolved', expected '$expected_fallback')"
  fi
  rm -rf "$sandbox"
else
  assert_fail "could not create sandbox for malformed-installed_plugins.json sanity check (#883)"
fi

# (7) The post-relocation stash-read two-liner (issue #1181) must actually
# work: given a `.shipyard-plugin-root` stash file in cwd containing a
# resolved path, the two-liner reads it back into $CLAUDE_PLUGIN_ROOT
# unchanged. This is the runtime contract the docs encode for every
# orchestrator-phase block from step 0.5 onward — if the stash-read literal
# text drifts from what step 0.5 actually writes, this catches it.
stash_sandbox=$(mktemp -d 2>/dev/null || mktemp -d -t shipyard-1181)
if [[ -n "$stash_sandbox" && -d "$stash_sandbox" ]]; then
  printf '%s\n' "$stash_sandbox/plugins/shipyard" > "$stash_sandbox/.shipyard-plugin-root"
  stash_resolved=$(env -i HOME="$HOME" PATH="$PATH" bash -c "
    cd '$stash_sandbox'
    $EXPECTED_STASH_LINE1
    $EXPECTED_STASH_LINE2
    echo \"\$CLAUDE_PLUGIN_ROOT\"
  ")
  if [[ "$stash_resolved" == "$stash_sandbox/plugins/shipyard" ]]; then
    assert_pass "post-relocation stash-read two-liner reads back .shipyard-plugin-root unchanged (issue #1181)"
  else
    assert_fail "post-relocation stash-read two-liner should read back the stash file unchanged (got '$stash_resolved', expected '$stash_sandbox/plugins/shipyard')"
  fi
  rm -rf "$stash_sandbox"
else
  assert_fail "could not create sandbox for stash-read sanity check (#1181)"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
if (( fail > 0 )); then
  exit 1
fi
exit 0

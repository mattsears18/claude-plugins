#!/usr/bin/env bash
# Test: every post-relocation orchestrator bash block that invokes
# shipyard-config.sh (directly, or via a helper like resolve-dispatch-model.sh
# that shells out to it) also re-derives and re-exports the SHIPYARD_REPO_ROOT
# pin from the step-0.56 `.shipyard-primary-root` stash — issue #1059 (phase
# 1: the pin itself + the one known-affected consumer), #1064 (phase 2: sweep
# every remaining call site).
#
# Background
# ----------
# `shipyard-config.sh`'s `repo_root()` resolves via `git rev-parse
# --show-toplevel` from cwd unless `SHIPYARD_REPO_ROOT` overrides it. Setup
# step 0.5 relocates the orchestrator's session into a fresh worktree checked
# out from origin/<default-branch> — which, by construction, cannot contain
# gitignored files like `.shipyard/config.local.json`. Step 0.56
# (setup/00-config-worktree.md) stashes the PRIMARY checkout's root at
# `<orch-worktree>/.shipyard-primary-root` and documents that every
# SUBSEQUENT config read this session should re-derive `SHIPYARD_REPO_ROOT`
# from that stash — the same way every `${CLAUDE_PLUGIN_ROOT}`-consuming
# block already re-derives that variable (each Bash-tool call is a fresh,
# hermetic subshell — nothing set in call N survives into call N+1).
#
# #1059's own PR (#1063) wired the pin at its origin (step 0.56) plus the one
# call site its repro named (the flake-registry enforcement in
# setup/04-backlog-divert.md's step 5.8) and deliberately left every other
# post-relocation `shipyard-config.sh get` / `resolve-dispatch-model.sh` call
# site un-swept as a follow-up. #1064 is that follow-up. This suite is the
# durable regression guard so a NEW call site added later can't silently
# reintroduce the same gap: a repo with `.shipyard/config.local.json` set
# would have that layer silently drop out of the merged config for whichever
# call site forgot the pin, with no error — exactly the class of bug #1059
# reported (this session's own orchestrator run hit it directly, on
# resolve-dispatch-model.sh, while dogfooding #1064 itself).
#
# What this test checks
# ----------------------
# For each scanned file, walk every ```bash code block (any indent, matching
# the plugin-root preamble test's own fence walker). A block "counts" if it
# invokes `${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh"` or
# `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-dispatch-model.sh"` literally. A
# counting block passes if it ALSO contains the `.shipyard-primary-root`
# stash-file marker somewhere in the same block — the shared substring both
# the canonical `SHIPYARD_REPO_ROOT=$(cat ".../.shipyard-primary-root" ...)`
# re-derivation and the pre-existing flake-enforce block's
# `$ORCH_WT/.shipyard-primary-root` variant both carry, so the test doesn't
# hardcode one exact snippet shape and reject an equally-valid alternative.
#
# --- File discovery (issue #1105) -------------------------------------------
#
# This suite originally walked a hardcoded FILES array (six files named by
# #1064's own sweep). #1105 converted it to the same MECHANICAL discovery
# `claude-plugin-root-preamble.test.sh` already uses for the analogous
# ${CLAUDE_PLUGIN_ROOT} preamble, after the hardcoded array was caught
# missing a real, live call site: `setup/01b-backlog-overview.md`'s step-2
# `triage.investigate_dispatch` read called `shipyard-config.sh` post-
# relocation with no SHIPYARD_REPO_ROOT pin, and was never added to the
# array (#1064's sweep predates that file growing the call — it isn't in
# the six files #1064 named). #1105 fixed that specific gap and switched
# discovery so a NEW call site in a NEW file can't reintroduce it silently —
# this is the exact rot `claude-plugin-root-preamble.test.sh`'s own #910
# history describes (59% of real occurrences uncovered before its glob
# conversion), just found here one file at a time instead of by count.
#
# Candidates: every *.md file under commands/do-work/ (recursively, so a
# future setup/ or operate/ sub-file is swept in automatically) MINUS
# setup/00-config-worktree.md and setup/01c-label-recovery-refine.md, both
# excluded explicitly rather than scanned-and-ignored — see the Scope
# paragraph below for why a scan would false-positive on each. A candidate
# with zero call-bearing bash blocks is a no-op (nothing to check), so this
# glob is safe to keep wide.
#
# Scope — explicitly NOT setup/00-config-worktree.md. That file's step 0.4
# `shipyard-config.sh` reads run BEFORE step 0.5's relocation (against the
# PRIMARY checkout directly, where SHIPYARD_REPO_ROOT is a no-op — the cwd
# IS already the primary checkout) and step 0.56 is where the pin itself is
# DEFINED, not consumed — sweeping that file would produce false positives
# against reads that are correct exactly as written.
#
# Scope — also explicitly NOT setup/01c-label-recovery-refine.md ([#1202](https://github.com/mattsears18/shipyard/issues/1202)).
# Steps 3b and 3c's canonical implementation moved into this file's own
# sections and now runs pre-relocation, at step 0.45 — before step 0.5's
# `EnterWorktree`, for the identical reason 00-config-worktree.md's step 0.4
# is excluded above. Every `shipyard-config.sh` call site in this file (the
# `worktree_reap.warn_threshold` / `worktree_reap.max_per_session` /
# `auto_merge.method` reads) lives inside the 3b/3c pre-relocation bash
# blocks, so sweeping the file would produce the same class of false
# positive.
#
# Also explicitly NOT any agents/issue-worker/*.md file (out of SCAN_DIRS
# entirely — the glob only walks commands/do-work/). Workers run in their
# OWN isolated worktree, resolve their OWN config against their own cwd, and
# step 0.56 documents "Scope: orchestrator session only — never propagate
# into a dispatched worker." A worker-side shipyard-config.sh call correctly
# has no SHIPYARD_REPO_ROOT pin at all.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/shipyard-repo-root-preamble.test.sh

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

DO_WORK_DIR="$repo_root/plugins/shipyard/commands/do-work"

# Mechanical discovery (issue #1105, converting the #354/#910 pattern
# `claude-plugin-root-preamble.test.sh` already uses for the analogous
# ${CLAUDE_PLUGIN_ROOT} preamble): every *.md file under commands/do-work/,
# recursively, MINUS the pre-relocation files below (excluded explicitly —
# see the Scope notes above for why a scan would false-positive on each, not
# just find nothing). A new commands/do-work/ file is covered automatically
# the moment it grows a real call site — no hand-maintained array entry
# needed.
EXCLUDE_FILES=(
  "$DO_WORK_DIR/setup/00-config-worktree.md"
  "$DO_WORK_DIR/setup/01c-label-recovery-refine.md"
)
is_excluded() {
  local candidate="$1" ex
  for ex in "${EXCLUDE_FILES[@]}"; do
    [[ "$candidate" == "$ex" ]] && return 0
  done
  return 1
}
FILES=()
while IFS= read -r -d '' f; do
  is_excluded "$f" && continue
  FILES+=("$f")
done < <(find "$DO_WORK_DIR" -type f -name '*.md' -print0 2>/dev/null | sort -z)

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

echo "SHIPYARD_REPO_ROOT pin regression tests (issue #1059/#1064, discovery per #1105)"
echo

# (1) Discovery sanity. A `find` scope regression (wrong repo_root, a
# directory rename that silently drops commands/do-work/ out of scope) would
# make FILES empty and every subsequent check "pass" vacuously — the exact
# false-confidence failure mode #910 was filed to close for the sibling
# ${CLAUDE_PLUGIN_ROOT} test, now closed here too. Assert discovery found a
# non-trivial number of files, and that a small canary set of well-known
# files — including the file #1105 found this array had been missing —
# was among them.
if (( ${#FILES[@]} >= 20 )); then
  assert_pass "discovery found ${#FILES[@]} candidate *.md files under commands/do-work/ (minus setup/00-config-worktree.md, setup/01c-label-recovery-refine.md)"
else
  assert_fail "discovery found ${#FILES[@]} candidate *.md files under commands/do-work/ (expected >= 20 — DO_WORK_DIR or repo_root may be wrong)"
fi

CANARY_FILES=(
  "$DO_WORK_DIR/dispatch-rules.md"
  "$DO_WORK_DIR/drain.md"
  "$DO_WORK_DIR/steady-state.md"
  "$DO_WORK_DIR/inline-trivial.md"
  "$DO_WORK_DIR/setup/00b-parallelization-cache.md"
  "$DO_WORK_DIR/setup/04-backlog-divert.md"
  "$DO_WORK_DIR/setup/04d-investigate-routing.md"
  "$DO_WORK_DIR/setup/01b-backlog-overview.md"
)
for canary in "${CANARY_FILES[@]}"; do
  found=0
  for f in "${FILES[@]}"; do
    [[ "$f" == "$canary" ]] && { found=1; break; }
  done
  if (( found )); then
    assert_pass "discovery includes canary file ${canary#"$repo_root"/}"
  else
    assert_fail "discovery includes canary file ${canary#"$repo_root"/} (missing — DO_WORK_DIR or exclude list may have regressed)"
  fi
done

# (1b) Every excluded file must still exist and still be excluded — a rename
# of either would silently stop excluding anything (EXCLUDE_FILES just
# wouldn't match), re-introducing the false-positive scan the Scope notes
# above document.
for ex in "${EXCLUDE_FILES[@]}"; do
  rel="${ex#"$repo_root"/}"
  if [[ -f "$ex" ]]; then
    assert_pass "$rel (the excluded pre-relocation file) still exists at the expected path"
  else
    assert_fail "$rel (the excluded pre-relocation file) still exists at the expected path (renamed? EXCLUDE_FILES needs updating)"
  fi
  excluded_ok=1
  for f in "${FILES[@]}"; do
    [[ "$f" == "$ex" ]] && excluded_ok=0
  done
  if (( excluded_ok )); then
    assert_pass "$rel is excluded from the scanned FILES set"
  else
    assert_fail "$rel is excluded from the scanned FILES set (exclude filter regressed)"
  fi
done

# (2) Walk every bash code block in every scanned file, IN FILE ORDER. A
# block that invokes shipyard-config.sh or resolve-dispatch-model.sh must
# also carry the .shipyard-primary-root stash marker somewhere in the same
# block.
walk_blocks() {
  local file="$1"
  awk '
    BEGIN { in_block = 0 }

    /^[ \t]*```bash[ \t]*$/ {
      in_block = 1
      block_start = NR
      has_call = 0
      has_pin = 0
      next
    }

    /^[ \t]*```[ \t]*$/ {
      if (in_block) {
        printf "%d|%d|%d\n", block_start, has_call, has_pin
      }
      in_block = 0
      next
    }

    in_block {
      if ($0 ~ /\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\/shipyard-config\.sh"/ ||
          $0 ~ /\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\/resolve-dispatch-model\.sh"/) {
        has_call = 1
      }
      if ($0 ~ /\.shipyard-primary-root/) {
        has_pin = 1
      }
    }
  ' "$file"
}

offending_blocks=0
total_call_blocks=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS='|' read -r fence_line has_call has_pin; do
    if (( has_call )); then
      total_call_blocks=$((total_call_blocks + 1))
      if (( has_pin )); then
        : # pass
      else
        offending_blocks=$((offending_blocks + 1))
        assert_fail "${f#"$repo_root"/}: bash block at line $fence_line calls shipyard-config.sh/resolve-dispatch-model.sh but never re-derives SHIPYARD_REPO_ROOT from the .shipyard-primary-root stash (issue #1059/#1064)"
      fi
    fi
  done < <(walk_blocks "$f")
done

if (( offending_blocks == 0 )); then
  assert_pass "all $total_call_blocks bash blocks calling shipyard-config.sh/resolve-dispatch-model.sh across ${#FILES[@]} scanned files re-derive the SHIPYARD_REPO_ROOT pin"
fi

# (3) Sanity check that this suite actually found something to check — a
# scope regression (wrong FILES paths, a rename) would make total_call_blocks
# 0 and every check above "pass" vacuously, the same false-confidence trap
# issue #910 called out for the plugin-root preamble test.
if (( total_call_blocks >= 10 )); then
  assert_pass "discovery found $total_call_blocks call-bearing bash blocks (expected >= 10 — sweep covers a non-trivial surface)"
else
  assert_fail "discovery found $total_call_blocks call-bearing bash blocks (expected >= 10 — FILES list or repo_root may be wrong)"
fi

# (4) The step-0.56 origin itself must still document the stash file this
# whole pin depends on — a rename there would silently break every
# consumer's `cat ".../.shipyard-primary-root"` re-derivation with no error.
ORIGIN_MD="$DO_WORK_DIR/setup/00-config-worktree.md"
if [[ -f "$ORIGIN_MD" ]] && grep -qF '.shipyard-primary-root' "$ORIGIN_MD"; then
  assert_pass "setup/00-config-worktree.md still documents the .shipyard-primary-root stash (step 0.56 origin)"
else
  assert_fail "setup/00-config-worktree.md still documents the .shipyard-primary-root stash (step 0.56 origin)"
fi

echo
printf 'passed: %d, failed: %d\n' "$pass" "$fail"
if (( fail > 0 )); then
  exit 1
fi
exit 0

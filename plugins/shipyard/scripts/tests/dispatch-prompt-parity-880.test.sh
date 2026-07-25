#!/usr/bin/env bash
# Test: dispatch-rules.md's per-mode dispatch-prompt templates stay in sync
# with do-work-dispatch.workflow.js's `build<Mode>Prompt` builders — issue #880.
#
# Background
# ----------
# Every `mode:`-driven `/shipyard:do-work` worker's dispatch prompt exists in
# TWO hand-maintained copies: the reviewable prose template in
# `commands/do-work/dispatch-rules.md` (passed verbatim as the `Agent` tool's
# `prompt` under the default Agent-tool dispatch shape, #825) and the
# executing builder in `workflows/do-work-dispatch.workflow.js` (used under
# the alternate Workflow-substrate shape). #856 found and fixed the identical
# drift shape for the worker-RETURN schema and added a mechanical parity
# checker (`check-worker-return-schema-parity.mjs`) so it can't silently
# recur; #880 is the prompt-TEMPLATE half of the same problem, fixed the same
# way: `check-dispatch-prompt-parity.mjs` plus this regression suite.
#
# The two prompt forms are NOT byte-identical by design (the Workflow-
# substrate builders additionally inject a worktree-anchor block and a
# structured-return-contract closing, neither of which the Agent-tool prose
# needs), so the checker does mode-inventory / spec-file-reference /
# augmentation-anchor / worktree-anchor-dedup structural checks rather than a
# byte diff — see check-dispatch-prompt-parity.mjs's own header comment for
# the full rationale.
#
# #918 UPDATE — augmentation-anchor derivation, not a static table
# -----------------------------------------------------------------
# #880's original augmentation-anchor check (CHECK 3) compared against a
# hand-maintained table inside the checker script itself — it caught a KNOWN
# anchor's text drifting, but was structurally blind to a brand-NEW
# augmentation being added to dispatch-rules.md and never wired into the
# corresponding builder. That happened twice in two consecutive releases
# (PR #917 / #851's operator-residual augmentation, PR #919 / #852's
# verification-scope augmentation) with this suite green both times. #918
# replaces the static table with structural derivation: every bolded
# "**<Name> augmentation ...**" heading in dispatch-rules.md marks the start
# of an augmentation, and the checker extracts the anchor phrase from the
# Context-paragraph blockquote that follows it — so a NEW augmentation
# extends coverage automatically. Sections (C) and (G) below cover this
# directly; sections (D.4)/(D.5) were updated to match the new message
# format (the underlying augmentations they exercise are unchanged) and every
# fixture below now carries the heading paragraphs the new derivation
# requires to find an augmentation at all.
#
# Pure bash + node, no other external dependencies. Run with:
#   bash plugins/shipyard/scripts/tests/dispatch-prompt-parity-880.test.sh

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

checker="$repo_root/plugins/shipyard/scripts/check-dispatch-prompt-parity.mjs"
dispatch_rules_path="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
workflow_js_path="$repo_root/plugins/shipyard/workflows/do-work-dispatch.workflow.js"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    missing: %s\n' "$path"
  fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not on PATH — this suite cannot verify dispatch-prompt parity" >&2
  exit 1
fi

for f in "$checker" "$dispatch_rules_path" "$workflow_js_path"; do
  assert_file_exists "$f" "$(basename "$f") exists"
done

tmp="$(mktemp -d)"
# `cleanup` IS invoked, indirectly via `trap cleanup EXIT` on the next line —
# the unused-function/unreachable-code linter below loses track of that on a
# file this size with this many heredocs (worker-return-schema-parity-856
# .test.sh uses the identical trap-cleanup pattern and does NOT trigger this
# at its shorter length, so this is a false positive tied to this file's
# size, not a real dead-code finding). Different shellcheck versions flag it
# under different codes — SC2329 ("never invoked") locally (0.11.0), SC2317
# ("unreachable") on CI's apt-installed version — so both are disabled.
# shellcheck disable=SC2317,SC2329
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# Assert the checker PASSES (no drift found).
assert_parity_ok() {
  local md="$1" js="$2" label="$3" out rc
  out=$(node "$checker" "$md" "$js" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    assert_pass "$label"
  else
    assert_fail "$label"
    printf '    checker reported a drift:\n'
    printf '    %s\n' "$out"
  fi
}

# Assert the checker FAILS (a real drift exists), optionally requiring the
# diagnostic output to mention a specific substring.
assert_parity_drift() {
  local md="$1" js="$2" label="$3" expect="${4:-}" out rc
  out=$(node "$checker" "$md" "$js" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    assert_fail "$label"
    printf '    checker ACCEPTED a drifted prompt pair — the guard is not working\n'
    return
  fi
  if [[ -n "$expect" ]] && ! grep -qF -- "$expect" <<<"$out"; then
    assert_fail "$label"
    printf '    expected the diagnostic to mention: %s\n    got:\n    %s\n' "$expect" "$out"
    return
  fi
  assert_pass "$label"
}

# ==========================================================================
echo "== (A) the checker's own syntax and a bare run against the real repo files"
# ==========================================================================

if node --check "$checker" >/dev/null 2>&1; then
  assert_pass "check-dispatch-prompt-parity.mjs has valid JS syntax (node --check)"
else
  assert_fail "check-dispatch-prompt-parity.mjs has valid JS syntax (node --check)"
fi

if node --check "$workflow_js_path" >/dev/null 2>&1; then
  assert_pass "do-work-dispatch.workflow.js has valid JS syntax (node --check)"
else
  assert_fail "do-work-dispatch.workflow.js has valid JS syntax (node --check)"
fi

# ==========================================================================
echo
echo "== (B) POSITIVE — the real repo files match today (the #880 fix itself)"
# ==========================================================================

# This is the assertion that would have been RED before #880's fix landed —
# buildIssueWorkPrompt's user-feedback preamble was missing dispatch-rules.md's
# trailing "the refinement step may have misread the user" clause.
assert_parity_ok "$dispatch_rules_path" "$workflow_js_path" \
  "workflow.js's per-mode prompt builders match dispatch-rules.md's templates today"

# #918: the operator-residual and verification-scope augmentations are
# currently documented but not yet wired into buildIssueWorkPrompt — an
# EXPLICIT waiver marker on each keeps the check above green rather than
# silently skipping them. Assert the waiver escape hatch is actually what's
# keeping this passing (not, say, both augmentations having quietly lost
# their headings) — if this ever regresses to 0, either the augmentations
# got wired (great — remove the waiver comments in dispatch-rules.md) or the
# waiver markers were dropped without wiring anything (a real regression).
real_output=$(node "$checker" "$dispatch_rules_path" "$workflow_js_path" 2>&1)
if grep -q 'augmentation(s) explicitly waived' <<<"$real_output"; then
  assert_pass "real files: the operator-residual/verification-scope gap is an explicit, checked-for waiver (not silent)"
else
  assert_fail "real files: the operator-residual/verification-scope gap is an explicit, checked-for waiver (not silent)"
  printf '    got:\n    %s\n' "$real_output"
fi

# ==========================================================================
echo
echo "== (C) sanity — the heading-DERIVED anchor set finds all four known augmentations"
# ==========================================================================

# Every fixture from here down carries a "**<Name> augmentation**" heading
# immediately before each augmentation's Context-paragraph blockquote — that
# heading is what the #918 derivation keys off (see check-dispatch-prompt-
# parity.mjs's extractAugmentations). A fixture pair with NO drift at all.
cat > "$tmp/dispatch-rules-clean.md" <<'MDEOF'
   > **`mode: spike`** — Work issue #<N> in `<owner/repo>` to completion. **Load the `shipyard:worker-preamble` skill, then `agents/issue-worker/spike.md`.** Branch: `do-work/issue-<N>`.

   > **`mode: issue-work`** — Work issue #<N> in `<owner/repo>` to completion. **Load the `shipyard:worker-preamble` skill, then `agents/issue-worker/issue-work.md`.** Branch: `do-work/issue-<N>`. Open a PR that closes the issue.

   **Verify-gate augmentation (opt-in via verify_gate.enabled).** Before composing the prompt, read the flag from config.

   > **Verify gate: `on`.** Before arming auto-merge (step 6), run step 5.9.

   **User-feedback augmentation.** If the issue carries the `user-feedback` label, prepend this extra-scrutiny preamble to the prompt above:

   > **This issue originated from end-user feedback** and was refined by a prior `/refine-issues` pass. If the original raw user text (in the preserved comment) contradicts what's in the refined body, trust the **raw text** and flag the discrepancy in the issue — the refinement step may have misread the user.

   **Phase-1 slice augmentation ([#298](https://github.com/mattsears18/shipyard/issues/298)).** When the candidate carries a `phase_1_scope` field, append an extra Context paragraph.

   > **Phase-1 slice (scope-agent-supplied):** This issue was scoped as a multi-phase change.

   **Next-available-version augmentation.** When `next_available_version` is non-empty, append a Context paragraph.

   > **Next-available version (orchestrator-supplied):** the manifest's version row is coordination-managed.
MDEOF

make_clean_js() {
  cat > "$1" <<'JSEOF'
function buildWorkerPrompt(unit, repoSlug) {
  switch (unit.mode) {
    case 'issue-work':
      return buildIssueWorkPrompt(unit, repoSlug)
    case 'spike':
      return buildSpikePrompt(unit, repoSlug)
  }
}

function worktreeAnchorLines(unit, mode) {
  if (!unit.worktreePath) {
    const label = unit.number != null ? `issue #${unit.number}` : `this ${mode} dispatch`
    return [`CALLER BUG: no worktreePath was supplied for ${label}.`]
  }
  return [`cd "${unit.worktreePath}"`]
}

function buildSpikePrompt(unit, repoSlug) {
  const lines = [`mode: spike`, ``, ...worktreeAnchorLines(unit, 'spike')]
  lines.push(`Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/spike.md\`.`)
  if (unit.nextAvailableVersion) {
    lines.push(`**Next-available version (orchestrator-supplied):** the manifest's version row is coordination-managed.`)
  }
  return lines.join('\n')
}

function buildIssueWorkPrompt(unit, repoSlug) {
  const lines = [`mode: issue-work`, ``, ...worktreeAnchorLines(unit, 'issue-work')]
  lines.push(`Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/issue-work.md\`.`)
  if (unit.verifyGate) {
    lines.push(`**Verify gate: on.** Before arming auto-merge (step 6), run step 5.9.`)
  }
  if (unit.userFeedback) {
    lines.push(
      `**This issue originated from end-user feedback** and was refined by a prior`,
      `\`/refine-issues\` pass. If the original raw user text (in the preserved comment)`,
      `contradicts what's in the refined body, trust the **raw text** and flag the`,
      `discrepancy in the issue — the refinement step may have misread the user.`,
    )
  }
  if (unit.phase1Scope) {
    lines.push(`**Phase-1 slice (scope-agent-supplied):** This issue was scoped as a multi-phase change.`)
  }
  if (unit.nextAvailableVersion) {
    lines.push(`**Next-available version (orchestrator-supplied):** the manifest's version row is coordination-managed.`)
  }
  return lines.join('\n')
}
JSEOF
}

make_clean_js "$tmp/workflow-clean.js"
assert_parity_ok "$tmp/dispatch-rules-clean.md" "$tmp/workflow-clean.js" \
  "sanity: the clean fixture pair (baseline for (D)'s isolated mutations) passes"

# ==========================================================================
echo
echo "== (D) NEGATIVE — other drift shapes the checker must also catch"
# ==========================================================================

# (D.1) a mode added to dispatch-rules.md's routing but never wired into
# buildWorkerPrompt's switch (or vice versa — the switch has a mode with no
# documented template).
d1_md="$tmp/d1.md"
cat "$tmp/dispatch-rules-clean.md" > "$d1_md"
cat >> "$d1_md" <<'MDEOF'

   > **`mode: fix-checks-only`** — Fix failing CI checks on PR #<M>. **Load the `shipyard:worker-preamble` skill, then `agents/issue-worker/fix-checks-only.md`.**
MDEOF
assert_parity_drift "$d1_md" "$tmp/workflow-clean.js" \
  "(D.1) a mode documented in dispatch-rules.md with no buildWorkerPrompt case is caught" \
  'mode "fix-checks-only": has a dispatch-rules.md template but no case'

# (D.2) the mirror case — a case in the switch with no dispatch-rules.md template.
d2_js="$tmp/d2.js"
cat > "$d2_js" <<'JSEOF'
function buildWorkerPrompt(unit, repoSlug) {
  switch (unit.mode) {
    case 'issue-work':
      return buildIssueWorkPrompt(unit, repoSlug)
    case 'spike':
      return buildSpikePrompt(unit, repoSlug)
    case 'fix-rebase':
      return buildFixRebasePrompt(unit, repoSlug)
  }
}
JSEOF
tail -n +2 "$tmp/workflow-clean.js" >> "$d2_js"
cat >> "$d2_js" <<'JSEOF'

function buildFixRebasePrompt(unit, repoSlug) {
  return `mode: fix-rebase`
}
JSEOF
assert_parity_drift "$tmp/dispatch-rules-clean.md" "$d2_js" \
  "(D.2) a buildWorkerPrompt case with no dispatch-rules.md template is caught" \
  'mode "fix-rebase": has a buildWorkerPrompt case but no dispatch-rules.md template'

# (D.3) spec-file path renamed in the builder only (e.g. issue-work.md ->
# issue-worker.md) while dispatch-rules.md keeps the old path.
d3_js="$tmp/d3.js"
sed 's#agents/issue-worker/issue-work\.md#agents/issue-worker/issue-worker.md#' "$tmp/workflow-clean.js" > "$d3_js"
assert_parity_drift "$tmp/dispatch-rules-clean.md" "$d3_js" \
  "(D.3) a spec-file path renamed in the builder only is caught" \
  'dispatch-rules.md'"'"'s template references "agents/issue-worker/issue-work.md" but'

# (D.4) the verify-gate augmentation paragraph deleted from buildIssueWorkPrompt only.
d4_js="$tmp/d4.js"
grep -v 'Verify gate: on' "$tmp/workflow-clean.js" > "$d4_js"
assert_parity_drift "$tmp/dispatch-rules-clean.md" "$d4_js" \
  "(D.4) the verify-gate augmentation deleted from the builder only is caught" \
  'augmentation "Verify-gate augmentation (opt-in via verify_gate.enabled)." (anchor "Verify gate: on."): missing from'

# (D.5) the next-available-version augmentation deleted from buildSpikePrompt
# only (issue-work still has it) — proves the per-mode augmentation
# applicability (issue-work AND spike both get this one) is enforced
# independently per mode, not just "present somewhere in the file."
d5_js="$tmp/d5.js"
awk '
  /^function buildSpikePrompt/ { in_spike = 1 }
  in_spike && /Next-available version/ { next }
  /^}/ && in_spike { in_spike = 0 }
  { print }
' "$tmp/workflow-clean.js" > "$d5_js"
assert_parity_drift "$tmp/dispatch-rules-clean.md" "$d5_js" \
  "(D.5) next-available-version deleted from buildSpikePrompt only (issue-work keeps it) is caught" \
  'augmentation "Next-available-version augmentation." (anchor "Next-available version (orchestrator-supplied):"): missing from'

# (D.6) buildIssueWorkPrompt regresses to inlining its own worktree-anchor
# CALLER-BUG copy instead of delegating to worktreeAnchorLines — the exact
# "Internal dup" shape #880 evidenced and #880's fix folded away. Built
# directly (not via sed on the clean fixture) so the fixture's `#` in
# `issue #${unit.number}` can't collide with a sed delimiter.
d6_js="$tmp/d6.js"
cat > "$d6_js" <<'JSEOF'
function buildWorkerPrompt(unit, repoSlug) {
  switch (unit.mode) {
    case 'issue-work':
      return buildIssueWorkPrompt(unit, repoSlug)
    case 'spike':
      return buildSpikePrompt(unit, repoSlug)
  }
}

function worktreeAnchorLines(unit, mode) {
  if (!unit.worktreePath) {
    const label = unit.number != null ? `issue #${unit.number}` : `this ${mode} dispatch`
    return [`CALLER BUG: no worktreePath was supplied for ${label}.`]
  }
  return [`cd "${unit.worktreePath}"`]
}

function buildSpikePrompt(unit, repoSlug) {
  const lines = [`mode: spike`, ``, ...worktreeAnchorLines(unit, 'spike')]
  lines.push(`Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/spike.md\`.`)
  if (unit.nextAvailableVersion) {
    lines.push(`**Next-available version (orchestrator-supplied):** the manifest's version row is coordination-managed.`)
  }
  return lines.join('\n')
}

// REGRESSION: inlines its own CALLER-BUG copy instead of calling
// worktreeAnchorLines(unit, 'issue-work') the way every other builder does.
function buildIssueWorkPrompt(unit, repoSlug) {
  const lines = [`mode: issue-work`, ``, `CALLER BUG: no worktreePath was supplied for issue #${unit.number}.`]
  lines.push(`Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/issue-work.md\`.`)
  if (unit.verifyGate) {
    lines.push(`**Verify gate: on.** Before arming auto-merge (step 6), run step 5.9.`)
  }
  if (unit.userFeedback) {
    lines.push(
      `**This issue originated from end-user feedback** and was refined by a prior`,
      `\`/refine-issues\` pass. If the original raw user text (in the preserved comment)`,
      `contradicts what's in the refined body, trust the **raw text** and flag the`,
      `discrepancy in the issue — the refinement step may have misread the user.`,
    )
  }
  if (unit.phase1Scope) {
    lines.push(`**Phase-1 slice (scope-agent-supplied):** This issue was scoped as a multi-phase change.`)
  }
  if (unit.nextAvailableVersion) {
    lines.push(`**Next-available version (orchestrator-supplied):** the manifest's version row is coordination-managed.`)
  }
  return lines.join('\n')
}
JSEOF
assert_parity_drift "$tmp/dispatch-rules-clean.md" "$d6_js" \
  "(D.6) buildIssueWorkPrompt inlining its own worktree-anchor copy instead of delegating is caught" \
  "does not call worktreeAnchorLines(unit, 'issue-work')"

# ==========================================================================
echo
echo "== (E) POSITIVE-but-tricky — a cosmetic source line-wrap must NOT false-fail"
# ==========================================================================

# Same content as the clean fixture's user-feedback preamble, but with the
# "misread the user" clause's sentence split across an EXTRA line-wrap
# boundary partway through a word-run (mimicking an ~80-col reflow after an
# unrelated edit) — this must still be recognized as present, proving the
# checker compares rendered prose, not raw source line boundaries.
e_js="$tmp/e.js"
cat > "$e_js" <<'JSEOF'
function buildWorkerPrompt(unit, repoSlug) {
  switch (unit.mode) {
    case 'issue-work':
      return buildIssueWorkPrompt(unit, repoSlug)
    case 'spike':
      return buildSpikePrompt(unit, repoSlug)
  }
}

function worktreeAnchorLines(unit, mode) {
  if (!unit.worktreePath) {
    return [`CALLER BUG: no worktreePath was supplied for this ${mode} dispatch.`]
  }
  return [`cd "${unit.worktreePath}"`]
}

function buildSpikePrompt(unit, repoSlug) {
  const lines = [`mode: spike`, ``, ...worktreeAnchorLines(unit, 'spike')]
  lines.push(`Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/spike.md\`.`)
  if (unit.nextAvailableVersion) {
    lines.push(`**Next-available version (orchestrator-supplied):** the manifest's version row is coordination-managed.`)
  }
  return lines.join('\n')
}

function buildIssueWorkPrompt(unit, repoSlug) {
  const lines = [`mode: issue-work`, ``, ...worktreeAnchorLines(unit, 'issue-work')]
  lines.push(`Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/issue-work.md\`.`)
  if (unit.verifyGate) {
    lines.push(`**Verify gate: on.** Before arming auto-merge (step 6), run step 5.9.`)
  }
  if (unit.userFeedback) {
    lines.push(
      `**This issue originated from end-user feedback** and was refined by a prior`,
      `\`/refine-issues\` pass. If the original raw user text (in the preserved comment)`,
      `contradicts what's in the refined body, trust the **raw text** and flag the`,
      `discrepancy in the issue — the`,
      `refinement step may have`,
      `misread the user.`,
    )
  }
  if (unit.phase1Scope) {
    lines.push(`**Phase-1 slice (scope-agent-supplied):** This issue was scoped as a multi-phase change.`)
  }
  if (unit.nextAvailableVersion) {
    lines.push(`**Next-available version (orchestrator-supplied):** the manifest's version row is coordination-managed.`)
  }
  return lines.join('\n')
}
JSEOF
assert_parity_ok "$tmp/dispatch-rules-clean.md" "$e_js" \
  "(E) a mid-sentence line-wrap across 3 template-literal segments does NOT false-fail"

# ==========================================================================
echo
echo "== (F) the checker is wired into this repo's CI discovery"
# ==========================================================================

# tests.yml discovers every plugins/**/*.test.sh automatically (no per-file
# workflow edit needed — see .github/workflows/tests.yml). This suite lives
# at that convention, so running it IS how the checker gets wired into CI —
# assert the convention holds rather than re-deriving it, so a future rename
# of the test-discovery mechanism doesn't leave this checker silently unrun
# (the exact #878 defect: a checker nobody invokes).
this_file="$repo_root/plugins/shipyard/scripts/tests/dispatch-prompt-parity-880.test.sh"
assert_file_exists "$this_file" "this suite lives under plugins/ at the *.test.sh convention tests.yml auto-discovers"

if grep -q "find plugins -type f -name '\*.test.sh'" "$repo_root/.github/workflows/tests.yml" 2>/dev/null; then
  assert_pass "tests.yml auto-discovers *.test.sh under plugins/ (confirms this suite runs in CI without a workflow edit)"
else
  assert_fail "tests.yml auto-discovers *.test.sh under plugins/ (confirms this suite runs in CI without a workflow edit)"
fi

# ==========================================================================
echo
echo "== (G) NEGATIVE/POSITIVE — the #918 fix itself: a NEW augmentation the"
echo "       static table could never have known about"
# ==========================================================================

# (G.1) THE #917/#919 REPRO. A brand-new augmentation heading + blockquote is
# appended to dispatch-rules.md — mirroring exactly what PR #917 (#851) and
# PR #919 (#852) each did — and buildIssueWorkPrompt is NEVER updated to
# render it. Under the pre-#918 static-table checker this passed silently
# (the table simply never grew an entry for it); under the #918 derivation
# it MUST fail, because the anchor set is read from dispatch-rules.md itself.
g1_md="$tmp/g1.md"
cat "$tmp/dispatch-rules-clean.md" > "$g1_md"
cat >> "$g1_md" <<'MDEOF'

   **Operator-residual augmentation ([#851](https://github.com/mattsears18/shipyard/issues/851)).** When the candidate carries an `operator_residual` field, append a second Context paragraph.

   > **Operator residual (scope-agent-supplied, #851):** After shipping the phase-1 slice above, this issue is NOT resolved.
MDEOF
assert_parity_drift "$g1_md" "$tmp/workflow-clean.js" \
  "(G.1) a brand-new augmentation added to dispatch-rules.md and never wired into the builder is caught (the #917/#919 shape)" \
  'augmentation "Operator-residual augmentation ([#851](https://github.com/mattsears18/shipyard/issues/851))." (anchor "Operator residual (scope-agent-supplied, #851):"): missing from'

# (G.2) The SAME new-and-unwired augmentation, but now carrying the explicit
# waiver marker `check-dispatch-prompt-parity.mjs` recognizes — this is
# EXACTLY how #918's own fix resolves the real operator-residual /
# verification-scope gap in the real dispatch-rules.md (see section (B)
# above). A waived augmentation must NOT fail the suite.
g2_md="$tmp/g2.md"
cat "$tmp/dispatch-rules-clean.md" > "$g2_md"
cat >> "$g2_md" <<'MDEOF'

   **Operator-residual augmentation ([#851](https://github.com/mattsears18/shipyard/issues/851)).** <!-- dispatch-prompt-parity: waived — not yet rendered by buildIssueWorkPrompt; see #918 --> When the candidate carries an `operator_residual` field, append a second Context paragraph.

   > **Operator residual (scope-agent-supplied, #851):** After shipping the phase-1 slice above, this issue is NOT resolved.
MDEOF
assert_parity_ok "$g2_md" "$tmp/workflow-clean.js" \
  "(G.2) the SAME new-and-unwired augmentation, now with an explicit waiver marker, does NOT fail the suite"

# (G.3) STALE WAIVER — the waiver marker from (G.2) is kept, but the anchor
# text has since been added to the builder (i.e. someone wired the
# augmentation and forgot to remove the now-stale waiver comment). The
# checker must flag this so the waiver doesn't silently outlive its reason.
# Built directly (not via sed on the clean fixture) to keep the mutation
# unambiguous: identical to workflow-clean.js's buildIssueWorkPrompt, plus
# ONE extra line rendering the operator-residual anchor.
g3_js="$tmp/g3.js"
cat > "$g3_js" <<'JSEOF'
function buildWorkerPrompt(unit, repoSlug) {
  switch (unit.mode) {
    case 'issue-work':
      return buildIssueWorkPrompt(unit, repoSlug)
    case 'spike':
      return buildSpikePrompt(unit, repoSlug)
  }
}

function worktreeAnchorLines(unit, mode) {
  if (!unit.worktreePath) {
    const label = unit.number != null ? `issue #${unit.number}` : `this ${mode} dispatch`
    return [`CALLER BUG: no worktreePath was supplied for ${label}.`]
  }
  return [`cd "${unit.worktreePath}"`]
}

function buildSpikePrompt(unit, repoSlug) {
  const lines = [`mode: spike`, ``, ...worktreeAnchorLines(unit, 'spike')]
  lines.push(`Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/spike.md\`.`)
  if (unit.nextAvailableVersion) {
    lines.push(`**Next-available version (orchestrator-supplied):** the manifest's version row is coordination-managed.`)
  }
  return lines.join('\n')
}

function buildIssueWorkPrompt(unit, repoSlug) {
  const lines = [`mode: issue-work`, ``, ...worktreeAnchorLines(unit, 'issue-work')]
  lines.push(`Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/issue-work.md\`.`)
  if (unit.verifyGate) {
    lines.push(`**Verify gate: on.** Before arming auto-merge (step 6), run step 5.9.`)
  }
  if (unit.userFeedback) {
    lines.push(
      `**This issue originated from end-user feedback** and was refined by a prior`,
      `\`/refine-issues\` pass. If the original raw user text (in the preserved comment)`,
      `contradicts what's in the refined body, trust the **raw text** and flag the`,
      `discrepancy in the issue — the refinement step may have misread the user.`,
    )
  }
  if (unit.phase1Scope) {
    lines.push(`**Phase-1 slice (scope-agent-supplied):** This issue was scoped as a multi-phase change.`)
  }
  // STALE WAIVER: this augmentation is now actually rendered here, but (g2_md
  // above) still carries the waiver comment saying it isn't.
  if (unit.operatorResidual) {
    lines.push(`**Operator residual (scope-agent-supplied, #851):** stub.`)
  }
  if (unit.nextAvailableVersion) {
    lines.push(`**Next-available version (orchestrator-supplied):** the manifest's version row is coordination-managed.`)
  }
  return lines.join('\n')
}
JSEOF
assert_parity_drift "$g2_md" "$g3_js" \
  "(G.3) a stale waiver — the waived anchor is now actually present in the builder — is caught" \
  'is marked waived but its anchor'

# ==========================================================================
echo
echo "Results: $pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
  exit 1
fi
exit 0

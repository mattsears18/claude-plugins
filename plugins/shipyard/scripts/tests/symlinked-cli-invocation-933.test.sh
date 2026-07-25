#!/usr/bin/env bash
# Test: check-workflow-meta-literal.mjs, check-dispatch-prompt-parity.mjs, and
# check-worker-return-schema-parity.mjs actually RUN their CLI body when
# invoked via a SYMLINKED path — issue #933.
#
# Background
# ----------
# All three checkers guarded their CLI entry point with:
#
#   const isMain = process.argv[1] && import.meta.url === `file://${process.argv[1]}`
#
# `import.meta.url` is always the fully-resolved REAL path of the running
# script; `process.argv[1]` is the path exactly as typed on the command line.
# Those differ whenever the script is invoked through a symlinked path (macOS
# `/tmp` -> `/private/tmp` is the everyday case, but any wrapper using
# `mktemp -d`, a symlinked worktree, or a manually-constructed symlink hits
# it too) — so `isMain` evaluates to `false`, the entire `if (isMain) { ... }`
# CLI body is skipped, and the process falls off the end of the module with
# NO output and exit code 0, having validated nothing. A caller sees a green
# exit and concludes the gate held; it never ran.
#
# GitHub Actions checks out to `/home/runner/work/...` — no symlink
# component — so CI never observed this; it only bit local runs, which is
# exactly the situation this suite must reproduce on ANY platform (including
# a CI runner that itself has no symlinks in its own paths), so it builds
# its OWN symlink rather than relying on the host's `/tmp` shape.
#
# The fix (see each checker's `resolvesToThisFile()` helper) compares
# REALPATHs instead of raw strings:
#
#   realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])
#
# This suite pins three things per checker, matching the issue's own
# acceptance criteria:
#
#   (1) invoked via a symlinked path with known-bad input, the checker exits
#       NON-ZERO and prints its diagnostic (not silent exit 0);
#   (2) invoked via a symlinked path with known-good input, the checker still
#       exits 0 and prints its OK line (the fix doesn't just flip everything
#       to "fail" — the gate now genuinely runs, in both directions);
#   (3) invoked via a symlinked path with NO input files at all, the checker
#       still exits non-zero (the usage-error branch each checker already had
#       for the zero-files case, which only fires now that `isMain` fires).
#
# It also re-runs the existing `workflow-meta-pure-literal-809.test.sh` suite
# through the same symlinked path and asserts it reports the identical
# "30 passed, 0 failed" whether invoked from the real path or the symlinked
# one — directly pinning the acceptance criterion phrased in those terms.
#
# Pure bash + node, no other external dependencies. Run with:
#   bash plugins/shipyard/scripts/tests/symlinked-cli-invocation-933.test.sh

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

scripts_dir="$repo_root/plugins/shipyard/scripts"
meta_checker="$scripts_dir/check-workflow-meta-literal.mjs"
prompt_checker="$scripts_dir/check-dispatch-prompt-parity.mjs"
schema_checker="$scripts_dir/check-worker-return-schema-parity.mjs"
suite_809="$scripts_dir/tests/workflow-meta-pure-literal-809.test.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not on PATH — this suite cannot verify symlinked CLI invocation" >&2
  exit 1
fi

for f in "$meta_checker" "$prompt_checker" "$schema_checker" "$suite_809"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: expected file not found: $f" >&2
    exit 1
  fi
done

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# The symlink under test: a deliberately-constructed indirection so this
# reproduces on any platform, not just macOS's incidental /tmp symlink.
symlink_dir="$tmp/symlinked-checkout"
ln -s "$repo_root" "$symlink_dir"

sym_meta_checker="$symlink_dir/plugins/shipyard/scripts/check-workflow-meta-literal.mjs"
sym_prompt_checker="$symlink_dir/plugins/shipyard/scripts/check-dispatch-prompt-parity.mjs"
sym_schema_checker="$symlink_dir/plugins/shipyard/scripts/check-worker-return-schema-parity.mjs"
sym_suite_809="$symlink_dir/plugins/shipyard/scripts/tests/workflow-meta-pure-literal-809.test.sh"

# ==========================================================================
echo "== (A) check-workflow-meta-literal.mjs via a symlinked invocation path"
# ==========================================================================

bad_meta="$tmp/bad.workflow.js"
cat > "$bad_meta" <<'EOF'
export const meta = {
  name: 'x',
  description: 'a' + 'b',
}
EOF

good_meta="$tmp/good.workflow.js"
cat > "$good_meta" <<'EOF'
export const meta = {
  name: 'x',
  description: 'y',
}
EOF

out=$(node "$sym_meta_checker" "$bad_meta" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
  assert_fail "symlinked invocation with bad input exits non-zero"
  printf '    exit 0 with no work done — the isMain gate is silently no-op-ing again\n'
elif [[ -z "$out" ]]; then
  assert_fail "symlinked invocation with bad input exits non-zero"
  printf '    exited non-zero but printed NOTHING — that is not the real diagnostic path\n'
elif ! grep -qF 'BinaryExpression' <<<"$out"; then
  assert_fail "symlinked invocation with bad input exits non-zero and prints its diagnostic"
  printf '    expected diagnostic to mention BinaryExpression, got:\n    %s\n' "$out"
else
  assert_pass "symlinked invocation with bad input exits non-zero and prints its diagnostic"
fi

out=$(node "$sym_meta_checker" "$good_meta" 2>&1); rc=$?
if [[ $rc -ne 0 ]]; then
  assert_fail "symlinked invocation with good input still exits 0"
  printf '    got exit %d:\n    %s\n' "$rc" "$out"
elif ! grep -qF 'OK' <<<"$out"; then
  assert_fail "symlinked invocation with good input prints its OK line"
  printf '    got:\n    %s\n' "$out"
else
  assert_pass "symlinked invocation with good input exits 0 and prints its OK line"
fi

out=$(node "$sym_meta_checker" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
  assert_fail "symlinked invocation with ZERO files still exits non-zero"
  printf '    exit 0 having validated zero files — isMain never fired\n'
else
  assert_pass "symlinked invocation with ZERO files exits non-zero (usage error)"
fi

# ==========================================================================
echo
echo "== (B) check-dispatch-prompt-parity.mjs via a symlinked invocation path"
# ==========================================================================

# A minimal but structurally-real drift fixture pair, reproducing the exact
# pre-#880 regression shape (borrowed verbatim from
# dispatch-prompt-parity-880.test.sh's own fixture): the workflow.js copy's
# user-feedback preamble is missing the trailing "misread the user" clause.
drift_md="$tmp/dispatch-rules-drift.md"
cat > "$drift_md" <<'MDEOF'
   > **`mode: issue-work`** — Work issue #<N> in `<owner/repo>` to completion. **Load the `shipyard:worker-preamble` skill, then `agents/issue-worker/issue-work.md`.** Branch: `do-work/issue-<N>`. Open a PR that closes the issue.

   **This issue originated from end-user feedback** and was refined by a prior `/refine-issues` pass. If the original raw user text (in the preserved comment) contradicts what's in the refined body, trust the **raw text** and flag the discrepancy in the issue — the refinement step may have misread the user.
MDEOF

drift_js="$tmp/workflow-drift.js"
cat > "$drift_js" <<'JSEOF'
function buildWorkerPrompt(unit, repoSlug) {
  switch (unit.mode) {
    case 'issue-work':
      return buildIssueWorkPrompt(unit, repoSlug)
  }
}

function worktreeAnchorLines(unit, mode) {
  if (!unit.worktreePath) {
    return [`CALLER BUG: no worktreePath was supplied for this ${mode} dispatch.`]
  }
  return [`cd "${unit.worktreePath}"`]
}

// Missing the trailing "the refinement step may have misread the user"
// clause dispatch-rules.md's copy has — the exact pre-#880 drift shape.
function buildIssueWorkPrompt(unit, repoSlug) {
  const lines = [`mode: issue-work`, ``, ...worktreeAnchorLines(unit, 'issue-work')]
  lines.push(`Load the \`shipyard:worker-preamble\` skill, then \`agents/issue-worker/issue-work.md\`.`)
  if (unit.userFeedback) {
    lines.push(
      `**This issue originated from end-user feedback** and was refined by a prior`,
      `\`/refine-issues\` pass. If the original raw user text (in the preserved comment)`,
      `contradicts what's in the refined body, trust the **raw text** and flag the`,
      `discrepancy in the issue.`,
    )
  }
  return lines.join('\n')
}
JSEOF

out=$(node "$sym_prompt_checker" "$drift_md" "$drift_js" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
  assert_fail "symlinked invocation with a drifted pair exits non-zero"
  printf '    exit 0 with no work done — the isMain gate is silently no-op-ing again\n'
elif [[ -z "$out" ]]; then
  assert_fail "symlinked invocation with a drifted pair exits non-zero and prints its diagnostic"
  printf '    exited non-zero but printed NOTHING\n'
else
  assert_pass "symlinked invocation with a drifted pair exits non-zero and prints its diagnostic"
fi

# The real, currently-in-sync repo files, reached THROUGH the symlink, must
# still report a clean parity pass.
sym_dispatch_rules="$symlink_dir/plugins/shipyard/commands/do-work/dispatch-rules.md"
sym_workflow_js="$symlink_dir/plugins/shipyard/workflows/do-work-dispatch.workflow.js"
out=$(node "$sym_prompt_checker" "$sym_dispatch_rules" "$sym_workflow_js" 2>&1); rc=$?
if [[ $rc -ne 0 ]]; then
  assert_fail "symlinked invocation against the real, in-sync repo files still exits 0"
  printf '    got exit %d:\n    %s\n' "$rc" "$out"
else
  assert_pass "symlinked invocation against the real, in-sync repo files still exits 0"
fi

out=$(node "$sym_prompt_checker" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
  assert_fail "symlinked invocation with ZERO args still exits non-zero"
  printf '    exit 0 having validated zero files — isMain never fired\n'
else
  assert_pass "symlinked invocation with ZERO args exits non-zero (usage error)"
fi

# ==========================================================================
echo
echo "== (C) check-worker-return-schema-parity.mjs via a symlinked invocation path"
# ==========================================================================

# A minimal canonical-schema / drifted-copy pair (borrowed verbatim from
# worker-return-schema-parity-856.test.sh's own D.1 fixture): an enum drift
# on a property both sides declare.
canon_min="$tmp/canon-min.json"
cat > "$canon_min" <<'EOF'
{
  "type": "object",
  "required": ["mode", "outcome"],
  "additionalProperties": false,
  "properties": {
    "mode": { "type": "string", "enum": ["issue-work", "spike"] },
    "outcome": { "type": "string", "enum": ["shipped", "blocked"] }
  },
  "allOf": [
    { "if": { "properties": { "outcome": { "const": "blocked" } } }, "then": { "required": ["blocked_reason"] } }
  ]
}
EOF

enum_drift_js="$tmp/enum-drift.js"
cat > "$enum_drift_js" <<'EOF'
const workerReturnSchema = {
  type: 'object',
  required: ['mode', 'outcome'],
  additionalProperties: false,
  properties: {
    mode: { type: 'string', enum: ['issue-work'] },
    outcome: { type: 'string', enum: ['shipped', 'blocked'] },
  },
  allOf: [
    { if: { properties: { outcome: { const: 'blocked' } } }, then: { required: ['blocked_reason'] } },
  ],
}
EOF

out=$(node "$sym_schema_checker" "$canon_min" "$enum_drift_js" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
  assert_fail "symlinked invocation with an enum-drifted pair exits non-zero"
  printf '    exit 0 with no work done — the isMain gate is silently no-op-ing again\n'
elif [[ -z "$out" ]]; then
  assert_fail "symlinked invocation with an enum-drifted pair exits non-zero and prints its diagnostic"
  printf '    exited non-zero but printed NOTHING\n'
else
  assert_pass "symlinked invocation with an enum-drifted pair exits non-zero and prints its diagnostic"
fi

out=$(node "$sym_schema_checker" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
  assert_fail "symlinked invocation with ZERO args still exits non-zero"
  printf '    exit 0 having validated zero files — isMain never fired\n'
else
  assert_pass "symlinked invocation with ZERO args exits non-zero (usage error)"
fi

# ==========================================================================
echo
echo "== (D) the full 809 suite reports the SAME result via a symlinked path"
# ==========================================================================
# Directly pins the acceptance criterion phrased in exactly these terms:
# "workflow-meta-pure-literal-809.test.sh reports 30/30 whether run from a
# real or symlinked path."

real_summary=$(bash "$suite_809" 2>&1 | tail -1)
sym_summary=$(bash "$sym_suite_809" 2>&1 | tail -1)

# Strip ANSI color codes before comparing so the assertion isn't fooled by an
# incidental escape-sequence difference between the two runs.
strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g' <<<"$1"; }
real_summary_plain="$(strip_ansi "$real_summary")"
sym_summary_plain="$(strip_ansi "$sym_summary")"

if [[ "$real_summary_plain" != *"0 failed"* ]]; then
  assert_fail "the 809 suite itself reports 0 failed from the REAL path (precondition)"
  printf '    got: %s\n' "$real_summary_plain"
elif [[ "$sym_summary_plain" != *"0 failed"* ]]; then
  assert_fail "the 809 suite reports 0 failed when run via a SYMLINKED path"
  printf '    got: %s\n' "$sym_summary_plain"
elif [[ "$real_summary_plain" != "$sym_summary_plain" ]]; then
  assert_fail "the 809 suite reports the IDENTICAL pass/fail count from both paths"
  printf '    real:      %s\n    symlinked: %s\n' "$real_summary_plain" "$sym_summary_plain"
else
  assert_pass "the 809 suite reports '$sym_summary_plain' identically from both the real and symlinked path"
fi

# ==========================================================================
echo
printf 'symlinked-cli-invocation-933: %s%d passed%s, %s%d failed%s\n' \
  "$GREEN" "$pass" "$RESET" "$([[ $fail -gt 0 ]] && printf '%s' "$RED" || printf '%s' "$GREEN")" "$fail" "$RESET"

[[ $fail -eq 0 ]]

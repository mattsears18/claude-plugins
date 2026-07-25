#!/usr/bin/env bash
# Test: do-work-dispatch.workflow.js stays in sync with the source-of-truth
# fragments it's generated from — issue #958.
#
# Background
# ----------
# Before #958, the seven `build<Mode>Prompt` worker-dispatch-prompt template
# functions (~469 lines) lived inline in `do-work-dispatch.workflow.js`
# alongside the actual orchestration logic (`meta`, `args` handling, the
# select/dispatch/collect stages) — none of that bulk was orchestration
# logic, and the Dynamic Workflows runtime's no-filesystem-access constraint
# meant a plain `import`/`require` split was not an option for the file that
# actually runs. #958 moves the seven builders (plus their shared
# worktree-anchor helpers) into small, independently-editable ES modules
# under `workflows/prompt-templates/`, and introduces
# `scripts/generate-dispatch-workflow.mjs`, which concatenates those modules
# with `workflows/do-work-dispatch.core.js` (the orchestration logic) to
# produce `do-work-dispatch.workflow.js` — checked into git as the generated
# artifact, exactly as the issue's own suggested approach describes.
#
# What this suite checks
# -----------------------
# (A) `--check` mode against the REAL repo files: the checked-in
#     `do-work-dispatch.workflow.js` must be byte-for-byte what regenerating
#     from `do-work-dispatch.core.js` + `prompt-templates/*.mjs` produces
#     right now. This is the drift check that fails CI if a future PR
#     hand-edits the generated file directly (or edits one source fragment
#     but forgets to regenerate) instead of editing a source fragment and
#     regenerating.
# (B) Every `prompt-templates/*.mjs` file is independently valid — `node
#     --check` passes on each in isolation (they're plain ES modules, unlike
#     the generated file / core fragment, which contain runtime-only
#     constructs that only make sense post-concatenation).
# (C) The generator's own `stripModuleSyntax`/`generate` logic — exercised
#     directly (not by shelling out) against small FIXTURE fragments, so a
#     regression in the strip/join logic itself is caught even if the real
#     repo files happen to already be in sync. Covers: an `import` line is
#     dropped, an `export function` becomes a plain `function`, fragment
#     order matches the documented TEMPLATE_FILES sequence, and blank-line
#     seams between fragments don't compound into multiple blank lines.
# (D) `check-dispatch-prompt-parity.mjs` (the pre-existing #880 checker)
#     still passes against the generated file post-#958 — proving the split
#     didn't defeat that checker's ability to detect drift, which was an
#     explicit constraint on this refactor (it inspects
#     `do-work-dispatch.workflow.js` directly, so as long as the GENERATED
#     file still contains real `function build<Mode>Prompt(...)  { ... }`
#     declarations with the same text, it keeps working unmodified).
# (E) The suite is wired into this repo's CI discovery (`*.test.sh` under
#     `plugins/`, per tests.yml's `find`-based auto-discovery).
#
# Pure bash + node, no other external dependencies. Run with:
#   bash plugins/shipyard/scripts/tests/dispatch-workflow-generated-958.test.sh

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

generator="$repo_root/plugins/shipyard/scripts/generate-dispatch-workflow.mjs"
workflows_dir="$repo_root/plugins/shipyard/workflows"
templates_dir="$workflows_dir/prompt-templates"
workflow_js="$workflows_dir/do-work-dispatch.workflow.js"
core_js="$workflows_dir/do-work-dispatch.core.js"
parity_checker="$repo_root/plugins/shipyard/scripts/check-dispatch-prompt-parity.mjs"
dispatch_rules="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
assert_fail() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not on PATH — this suite cannot verify the generated workflow" >&2
  exit 1
fi

echo "== (A) --check against the REAL repo files: no drift right now"

if [[ ! -f "$generator" ]]; then
  assert_fail "generate-dispatch-workflow.mjs exists at the expected path"
else
  assert_pass "generate-dispatch-workflow.mjs exists at the expected path"

  check_output="$(node "$generator" --check 2>&1)"
  check_status=$?
  if [[ $check_status -eq 0 ]]; then
    assert_pass "do-work-dispatch.workflow.js matches its generated source (core.js + prompt-templates/*.mjs)"
  else
    assert_fail "do-work-dispatch.workflow.js matches its generated source — got: $check_output"
  fi
fi

echo
echo "== (B) every prompt-templates/*.mjs file is independently valid"

expected_templates=(shared.mjs fix-checks-only.mjs fix-rebase.mjs fix-main-ci.mjs fix-failing-prs-batch.mjs investigate.mjs spike.mjs issue-work.mjs)
for f in "${expected_templates[@]}"; do
  path="$templates_dir/$f"
  if [[ ! -f "$path" ]]; then
    assert_fail "$f exists under prompt-templates/"
    continue
  fi
  if node --check "$path" >/dev/null 2>&1; then
    assert_pass "$f is syntactically valid (node --check)"
  else
    assert_fail "$f is syntactically valid (node --check)"
  fi
done

if [[ ! -f "$core_js" ]]; then
  assert_fail "do-work-dispatch.core.js exists at the expected path"
elif node --check "$core_js" >/dev/null 2>&1; then
  assert_pass "do-work-dispatch.core.js is syntactically valid (node --check)"
else
  assert_fail "do-work-dispatch.core.js is syntactically valid (node --check)"
fi

echo
echo "== (C) generator logic — exercised against FIXTURE fragments, not just the real repo"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fixture_harness="$tmp/fixture-check.mjs"
fixture_workflows_dir="$tmp/workflows"
fixture_templates_dir="$fixture_workflows_dir/prompt-templates"
mkdir -p "$fixture_templates_dir"

cat > "$fixture_workflows_dir/do-work-dispatch.core.js" <<'CORE_EOF'
// core fragment (fixture)
const x = 1
CORE_EOF

cat > "$fixture_templates_dir/shared.mjs" <<'SHARED_EOF'
// shared fragment (fixture)
export function sharedHelper() {
  return 'shared'
}
SHARED_EOF

cat > "$fixture_templates_dir/fix-checks-only.mjs" <<'MODE_EOF'
import { sharedHelper } from './shared.mjs'

// fix-checks-only fragment (fixture)
export function buildFixChecksOnlyPromptFixture() {
  return sharedHelper() + '-fix-checks-only'
}
MODE_EOF

# Minimal stand-ins for the remaining five template files the generator's
# TEMPLATE_FILES list expects — content is irrelevant to what this check
# exercises, only their presence and the import-strip/export-strip behavior.
for f in fix-rebase fix-main-ci fix-failing-prs-batch investigate spike issue-work; do
  cat > "$fixture_templates_dir/$f.mjs" <<MODE_EOF2
import { sharedHelper } from './shared.mjs'
export function fixture_${f//-/_}() {
  return sharedHelper()
}
MODE_EOF2
done

cat > "$fixture_harness" <<HARNESS_EOF
import { generate } from '${generator}'
const out = generate({ workflowsDir: '${fixture_workflows_dir}' })
process.stdout.write(out)
HARNESS_EOF

fixture_output="$(node "$fixture_harness" 2>&1)"
fixture_status=$?

if [[ $fixture_status -eq 0 ]]; then
  assert_pass "generate() runs against a fixture fragment set without error"
else
  assert_fail "generate() runs against a fixture fragment set — got: $fixture_output"
fi

if printf '%s' "$fixture_output" | grep -q "^import "; then
  assert_fail "generated output strips every 'import ... from ./*.mjs' line"
else
  assert_pass "generated output strips every 'import ... from ./*.mjs' line"
fi

if printf '%s' "$fixture_output" | grep -q "^export function"; then
  assert_fail "generated output strips the 'export ' prefix off every function declaration"
else
  assert_pass "generated output strips the 'export ' prefix off every function declaration"
fi

if printf '%s' "$fixture_output" | grep -q "^function sharedHelper"; then
  assert_pass "sharedHelper survives as a plain (non-exported) function declaration"
else
  assert_fail "sharedHelper survives as a plain (non-exported) function declaration"
fi

if printf '%s' "$fixture_output" | grep -q "^function buildFixChecksOnlyPromptFixture"; then
  assert_pass "buildFixChecksOnlyPromptFixture survives as a plain (non-exported) function declaration"
else
  assert_fail "buildFixChecksOnlyPromptFixture survives as a plain (non-exported) function declaration"
fi

if printf '%s' "$fixture_output" | grep -q "^const x = 1"; then
  assert_pass "the core fragment's own content is preserved verbatim"
else
  assert_fail "the core fragment's own content is preserved verbatim"
fi

# Ordering: core fragment content must appear before every template
# fragment's content in the concatenated output.
# awk (not grep|head|cut) so nothing downstream closes the pipe early and
# triggers a spurious "Broken pipe" warning from the upstream printf.
core_line="$(printf '%s\n' "$fixture_output" | awk '/^const x = 1/{print NR; exit}')"
shared_line="$(printf '%s\n' "$fixture_output" | awk '/^function sharedHelper/{print NR; exit}')"
if [[ -n "$core_line" && -n "$shared_line" && "$core_line" -lt "$shared_line" ]]; then
  assert_pass "the core fragment's content precedes the template fragments' content"
else
  assert_fail "the core fragment's content precedes the template fragments' content"
fi

# No 2+ consecutive blank lines anywhere (a sign the trim/join logic
# double-counts blank lines at a fragment boundary). Uses awk rather than
# `grep -z` for a multi-line pattern — GNU and BSD grep's `-z` semantics
# diverge, and this suite must behave identically on the macOS dev
# environment and the ubuntu-latest CI runner.
fixture_max_blank_run="$(printf '%s\n' "$fixture_output" | awk 'BEGIN{run=0;max=0} {if ($0=="") {run++; if(run>max) max=run} else run=0} END{print max}')"
if [[ "$fixture_max_blank_run" -ge 2 ]]; then
  assert_fail "no run of 2+ consecutive blank lines at a fragment seam (found a run of $fixture_max_blank_run)"
else
  assert_pass "no run of 2+ consecutive blank lines at a fragment seam"
fi

echo
echo "== (D) check-dispatch-prompt-parity.mjs still passes against the generated file post-#958"

if [[ ! -f "$parity_checker" || ! -f "$dispatch_rules" || ! -f "$workflow_js" ]]; then
  assert_fail "parity checker + its two inputs all exist"
else
  parity_output="$(node "$parity_checker" "$dispatch_rules" "$workflow_js" 2>&1)"
  parity_status=$?
  if [[ $parity_status -eq 0 ]]; then
    assert_pass "check-dispatch-prompt-parity.mjs passes against the post-#958 generated workflow.js"
  else
    assert_fail "check-dispatch-prompt-parity.mjs passes against the post-#958 generated workflow.js — got: $parity_output"
  fi
fi

echo
echo "== (E) this suite is wired into CI discovery"

this_suite="$here/dispatch-workflow-generated-958.test.sh"
if [[ "$this_suite" == "$repo_root/plugins/"*".test.sh" ]]; then
  assert_pass "this suite lives under plugins/ at the *.test.sh convention tests.yml auto-discovers"
else
  assert_fail "this suite lives under plugins/ at the *.test.sh convention tests.yml auto-discovers"
fi

echo
echo "dispatch-workflow-generated-958: ${GREEN}${pass} passed${RESET}, ${RED}${fail} failed${RESET}"
[[ $fail -eq 0 ]]

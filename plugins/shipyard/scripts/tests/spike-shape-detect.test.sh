#!/usr/bin/env bash
# Test: the spike-shape detector (issue #1475).
#
# Background — issue #1475: #774's spike-shape detector was a bare-prefix
# enumeration living as PROSE in two independently-worded places
# (`commands/do-work/dispatch-rules.md` and `agents/spike-worker.md`). Every
# entry was the BARE form (`spike:`, `investigate:`, ...), so none of them
# matched the Conventional-Commits SCOPED form (`spike(ci):`) that this repo's
# own filing conventions reliably produce — CLAUDE.md mandates Conventional
# Commits titles and `shipyard:filing-github-issues` enforces them on every
# filing path. Shipyard's filing convention therefore produced spike titles
# that shipyard's spike detector could not match, silently routing a
# spike-shaped issue to `mode: issue-work` (a contract built to open a PR that
# closes the issue) when the honest answer might be "build nothing."
#
# The fix is `plugins/shipyard/scripts/spike-shape-detect.sh` — one executable
# definition, following the `backlog-filter.sh` precedent (#1247), with both
# prose copies marked non-normative and pointing at it.
#
# This suite pins BOTH DIRECTIONS of the matcher (what must match, and what
# must NOT), the two-signal contract, the CLI surface, and the spec agreement
# between the two files that describe the detector in prose.
#
# The literal title from #1474 —
#   `spike(ci): measure the guard's resolvability boundary`
# — is asserted as a named fixture so this specific miss cannot regress.
#
# Pure bash. Run with:
#   bash plugins/shipyard/scripts/tests/spike-shape-detect.test.sh

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

detector="$repo_root/plugins/shipyard/scripts/spike-shape-detect.sh"
dispatch_rules="$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
spike_worker="$repo_root/plugins/shipyard/agents/spike-worker.md"
spike_spec="$repo_root/plugins/shipyard/agents/issue-worker/spike.md"
setup_dir="$repo_root/plugins/shipyard/commands/do-work/setup"

# The #1474 title, verbatim. This is the fixture #1475 requires.
FIXTURE_1474="spike(ci): measure the guard's resolvability boundary, then decide whether a \"does this block run\" gate is buildable (follow-up to #1471 step 4)"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

# --- helpers -----------------------------------------------------------------

# assert_verdict <expected> <title> [labels]
assert_verdict() {
  local expected="$1" title="$2" labels="${3:-}"
  local got
  if [[ -n "$labels" ]]; then
    got="$(bash "$detector" --title "$title" --labels "$labels" 2>&1)"
  else
    got="$(bash "$detector" --title "$title" 2>&1)"
  fi
  if [[ "$got" == "$expected" ]]; then
    ok "$expected  <-  ${title:0:64}${labels:+  [labels: $labels]}"
  else
    bad "expected '$expected', got '$got'  <-  ${title:0:64}${labels:+  [labels: $labels]}"
  fi
}

# assert_signal <expected-signal> <title> [labels]
assert_signal() {
  local expected="$1" title="$2" labels="${3:-}"
  local got
  if [[ -n "$labels" ]]; then
    got="$(bash "$detector" --title "$title" --labels "$labels" --why 2>&1 | cut -f2)"
  else
    got="$(bash "$detector" --title "$title" --why 2>&1 | cut -f2)"
  fi
  if [[ "$got" == "$expected" ]]; then
    ok "signal '$expected'  <-  ${title:0:64}"
  else
    bad "expected signal '$expected', got '$got'  <-  ${title:0:64}"
  fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    ok "$label"
  else
    bad "$label (missing from ${file#"$repo_root/"}: $needle)"
  fi
}

echo "== (0) the detector exists and is executable"
if [[ -f "$detector" ]]; then ok "spike-shape-detect.sh exists"; else bad "spike-shape-detect.sh missing at $detector"; fi
if [[ -x "$detector" ]]; then ok "spike-shape-detect.sh is executable"; else bad "spike-shape-detect.sh is not executable"; fi

echo
echo "== (1) the #1474 fixture — the exact miss this issue exists to prevent"

# The headline regression. If someone reverts the optional `(scope)` group,
# THIS is the assertion that reds.
assert_verdict "spike" "$FIXTURE_1474"
assert_signal "title-type-prefix" "$FIXTURE_1474"

# The bare-prefix form #774 already handled must keep working — the fix is
# additive, not a replacement.
assert_verdict "spike" "spike: measure the guard's resolvability boundary"

echo
echo "== (2) MATCH direction — Conventional-Commits scoped forms on type-shaped prefixes"

assert_verdict "spike" "spike(ci): foo"
assert_verdict "spike" "investigate(do-work): foo"
assert_verdict "spike" "research(api): foo"
assert_verdict "spike" "feasibility(auth): foo"
# An empty scope group is still a scope group.
assert_verdict "spike" "spike(): foo"
# Scopes routinely carry `/`, `-`, and `.`.
assert_verdict "spike" "spike(do-work/dispatch): foo"
# Case-insensitive, per #774.
assert_verdict "spike" "SPIKE(CI): FOO"
assert_verdict "spike" "Investigate(Do-Work): Foo"
# Leading whitespace tolerated.
assert_verdict "spike" "   spike(ci): foo"

echo
echo "== (3) MATCH direction — the bare forms #774 already handled, unregressed"

assert_verdict "spike" "spike: foo"
assert_verdict "spike" "investigate: foo"
assert_verdict "spike" "research: foo"
assert_verdict "spike" "feasibility: foo"
assert_verdict "spike" "spike on caching strategies"
assert_verdict "spike" "design spike: navigation shell"
assert_signal "title-prose-prefix" "spike on caching strategies"
assert_signal "title-prose-prefix" "design spike: navigation shell"

echo
echo "== (4) NO-MATCH direction — the detector must stay narrow"

# `spike` as the SCOPE of another type is a normal bug fix, not a spike. This
# is the most important no-match: it is what a naive substring matcher breaks.
assert_verdict "issue-work" "fix(spike): tighten the detector"
assert_verdict "issue-work" "feat(research): add a citation field"
# The prefix is ANCHORED, never a substring match anywhere in the title.
assert_verdict "issue-work" "chore: investigate whether the cache is warm"
assert_verdict "issue-work" "fix(ci): the spike: prefix is quoted here"
# The type must be the WHOLE word before the scope/colon.
assert_verdict "issue-work" "spikes: three of them"
assert_verdict "issue-work" "investigation(x): not the same word"
assert_verdict "issue-work" "researching alternatives: y"
# A scope group without the colon is not a Conventional Commits prefix.
assert_verdict "issue-work" "spike(ci) measure the boundary"
# No colon at all — #1475's own title shape, which is a fix, not a spike.
assert_verdict "issue-work" "spike-shape detection misses the scoped form"
# `spike on` requires a word boundary.
assert_verdict "issue-work" "spike online telemetry rollout"
# Scope discipline (#1475 suggested-fix point 1): the two PROSE framings are
# deliberately NOT given a scope group, and `design spike on` is neither form.
assert_verdict "issue-work" "design spike(ui): navigation shell"
assert_verdict "issue-work" "design spike on caching"
# An ordinary issue title.
assert_verdict "issue-work" "fix(dispatch): the detector misses a form"
assert_signal "none" "fix(dispatch): the detector misses a form"

echo
echo "== (5) the label signal (unchanged from #774), and its own no-match direction"

assert_verdict "spike" "fix(x): an ordinary bug" "P2,spike,shipyard"
assert_signal "label" "fix(x): an ordinary bug" "P2,spike,shipyard"
assert_verdict "spike" "fix(x): an ordinary bug" "SPIKE"
# Exact token only — a label that merely CONTAINS `spike` is not the signal.
assert_verdict "issue-work" "fix(x): an ordinary bug" "P2,spike-followup"
assert_verdict "issue-work" "fix(x): an ordinary bug" "needs-spike"
assert_verdict "issue-work" "fix(x): an ordinary bug" ""
# Whitespace around a field is trimmed; label names may contain spaces.
assert_verdict "spike" "fix(x): an ordinary bug" "P2, spike , shipyard"
assert_verdict "issue-work" "fix(x): an ordinary bug" "needs human review,P2"
# The label wins even when the title also matches — signal reporting must not
# silently flip to the title.
assert_signal "label" "spike(ci): both signals fire" "spike"

echo
echo "== (6) CLI surface"

if bash "$detector" --title "spike: x" >/dev/null 2>&1; then
  ok "exit 0 on a spike verdict"
else
  bad "expected exit 0 on a spike verdict"
fi

if bash "$detector" --title "fix(x): y" >/dev/null 2>&1; then
  ok "exit 0 on an issue-work verdict (the verdict is on stdout, not the exit status)"
else
  bad "expected exit 0 on an issue-work verdict — issue-work is an answer, not a failure"
fi

rc=0
bash "$detector" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then ok "exit 2 when --title is omitted"; else bad "expected exit 2 when --title is omitted, got $rc"; fi

rc=0
bash "$detector" --title "spike: x" --bogus >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then ok "exit 2 on an unrecognized argument"; else bad "expected exit 2 on an unrecognized argument, got $rc"; fi

# A title that looks like a flag must be consumed as the title, not reparsed.
assert_verdict "issue-work" "--labels is not a title prefix"

# --why output shape.
why_out="$(bash "$detector" --title "spike(ci): x" --why 2>&1)"
if [[ "$why_out" == $'spike\ttitle-type-prefix' ]]; then
  ok "--why prints '<verdict>\\t<signal>'"
else
  bad "--why shape wrong: got '$why_out'"
fi

# Default output is the bare verdict — no trailing signal for a caller that
# just wants the routing decision.
plain_out="$(bash "$detector" --title "spike(ci): x" 2>&1)"
if [[ "$plain_out" == "spike" ]]; then
  ok "default output is the bare verdict"
else
  bad "default output wrong: got '$plain_out'"
fi

echo
echo "== (7) spec agreement — both prose copies point at the one implementation"

# #1475 point 3: dispatch-rules.md carries the matcher and spike-worker.md
# independently describes the same shape signal. Before this change they were
# two hand-maintained copies. Both must now name the script.
assert_contains "$dispatch_rules" "scripts/spike-shape-detect.sh" \
  "dispatch-rules.md invokes the detector script"
assert_contains "$dispatch_rules" "single source of truth" \
  "dispatch-rules.md marks its prose non-normative"
assert_contains "$spike_worker" "spike-shape-detect.sh" \
  "spike-worker.md's shape-signal prose points at the detector script"

# The optional-scope group itself must be visible in the spec a reader lands
# on, not only in the script — otherwise the two drift again.
assert_contains "$dispatch_rules" '(\([^)]*\))?:' \
  "dispatch-rules.md quotes the optional Conventional-Commits scope group"

# The #1474 fixture title is cited in the spec as the concrete repro.
assert_contains "$dispatch_rules" 'spike(ci):' \
  "dispatch-rules.md names the scoped form that was missed"

echo
echo "== (8) the investigate-collision decision is written down, not left implicit"

# #1475 point 2 required this be DECIDED and stated, in both directions:
# the investigate MODE wins whenever its own detection fires (it runs earlier,
# at step 4, and removes the issue from the pool); a title-matched
# `investigate(scope):` whose body is not symptom-shaped routes to spike.
assert_contains "$dispatch_rules" "04d-investigate-routing.md" \
  "dispatch-rules.md links the investigate-mode detection path it can collide with"
assert_contains "$dispatch_rules" "never reaches this check" \
  "dispatch-rules.md states the investigate mode wins by pipeline order"
# Scanned ACROSS setup/*.md rather than pinned to one fragment path: the
# router/fragment split relocates content between fragments, and a hardcoded
# path here would break in CI with no local warning (issue #1453).
if grep -rqF -- "spike-shape-detect.sh" "$setup_dir" 2>/dev/null; then
  ok "some setup/*.md fragment carries the reciprocal pointer to the detector"
else
  bad "no setup/*.md fragment carries the reciprocal pointer to the detector"
fi

# spike.md's own "Don't" bullet must keep disclaiming detection heuristics —
# the detector lives in the dispatch path, not in the per-mode spec. That
# bullet is why spike.md is NOT the second prose copy (#1475's body assumed it
# was; the actual second copy is spike-worker.md).
assert_contains "$spike_spec" "Don't define or hardcode spike-detection heuristics" \
  "spike.md still disclaims owning the detection heuristics"

echo
echo "-------------------------------------------"
printf 'spike-shape-detect: %d passed, %d failed\n' "$pass" "$fail"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0

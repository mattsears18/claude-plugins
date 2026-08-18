#!/usr/bin/env bash
# Test: issue #1055 — the `user-feedback` label is permanent ORIGIN
# provenance (applied at intake, never removed per CLAUDE.md § Origin
# labels), not a live "still needs refining" signal. Before this fix,
# `/refine-issues`' candidate scan treated the bare label as sufficient to
# route an issue into the classify+rewrite branch, so an issue filed
# ALREADY REFINED but carrying the label (e.g. #1045 in the live repro:
# trusted author, well-structured body, no raw-feedback fenced block)
# matched the scan on every session, forever — there is no
# `<!-- do-work-refinement-agent -->` sentinel until a refinement worker
# has actually processed the issue once.
#
# The fix narrows the classify+rewrite source signal to require BOTH:
#   (a) the `user-feedback` label present, AND
#   (b) the body still contains the raw-feedback fenced block
#       (``` user-feedback ... ```) from the intake contract — the ONLY
#       hard requirement of that contract, so every genuinely-unrefined
#       user-feedback issue satisfies it, while an already-refined issue
#       (hand-written, or refined by a prior pass whose rewrite removes
#       the block) does not.
#
# This test also pins the second half of #1055: `refine-issues.md`'s
# worker prompt template for Branch A bucket (c) ("legitimate work") now
# explicitly ENSURES `needs-human-review` is present (mirroring Branch C's
# explicit `--add-label`) rather than the prior ambiguous "leave ... in
# place" phrasing — resolving the contradiction with CLAUDE.md's
# gate-label table, which already documented the classify+rewrite branch
# as an applier of `needs-human-review`.
#
# Two parts:
#   1. Doc-consistency assertions (grep) across refine-issues.md,
#      CLAUDE.md, and the do-work/setup/* files that duplicate or
#      describe the same source-signal scan.
#   2. A functional jq test that pins the ACTUAL scan behavior against
#      synthetic fixtures reproducing #1045 (must NOT match) alongside a
#      genuine raw-feedback issue and an open-questions issue (must still
#      match).
#
# Pure bash + jq, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/refine-origin-label-1055.test.sh

# setup-fragment-content-scan: allow-file
# This suite regression-tests a SPECIFIC historical migration (#1055) against
# the exact fragment files it touched — its purpose IS to verify those
# particular files, not generic step content that happens to live there
# today (issue #1453).
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

cmd_path="$repo_root/plugins/shipyard/commands/refine-issues.md"
claude_md_path="$repo_root/CLAUDE.md"
backlog_overview_path="$repo_root/plugins/shipyard/commands/do-work/setup/01b-backlog-overview.md"
label_recovery_refine_path="$repo_root/plugins/shipyard/commands/do-work/setup/01c-label-recovery-refine.md"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_file_exists() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (missing: %s)\n' "$RED" "$RESET" "$label" "$path"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  fi
}

assert_equals() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  %sPASS%s  %s (got %s)\n' "$GREEN" "$RESET" "$label" "$actual"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected %s, got %s)\n' "$RED" "$RESET" "$label" "$expected" "$actual"
    fail=$((fail+1))
  fi
}

echo "refine-issues / origin-label-vs-refinement-signal tests (#1055)"
echo

# ---------------------------------------------------------------------
# Part 1: doc-consistency assertions
# ---------------------------------------------------------------------

assert_file_exists "$cmd_path" "commands/refine-issues.md exists"

if [[ -f "$cmd_path" ]]; then
  assert_contains "$cmd_path" "1055" \
    "refine-issues.md cites #1055 as the source of the body-shape narrowing"

  # The scan's jq must require BOTH the label AND the raw-feedback fenced
  # block — not the label alone. Pin the exact variable-name shape so a
  # future edit that silently drops the body-shape half is caught.
  # shellcheck disable=SC2016  # literal jq variable names, not shell expansion
  assert_contains "$cmd_path" '$has_user_feedback_label' \
    "refine-issues.md scan computes has_user_feedback_label separately from is_user_feedback"
  # shellcheck disable=SC2016  # literal jq variable name, not shell expansion
  assert_contains "$cmd_path" '$looks_like_raw_feedback' \
    "refine-issues.md scan computes a looks_like_raw_feedback signal"
  # shellcheck disable=SC2016  # literal jq expression, not shell expansion
  assert_contains "$cmd_path" '($has_user_feedback_label and $looks_like_raw_feedback)' \
    "refine-issues.md scan ANDs the label with the raw-feedback body-shape check"

  # Branch A's directive for bucket (c) must EXPLICITLY ensure/add
  # needs-human-review (mirroring Branch C's explicit --add-label), not
  # the old ambiguous "leave ... in place" phrasing that contradicted
  # CLAUDE.md's gate-label table.
  assert_contains "$cmd_path" "gh issue edit <N> --add-label needs-human-review" \
    "refine-issues.md Branch A bucket (c) explicitly adds needs-human-review (not just 'leave in place')"

  # The rewritten body must be documented as removing the raw-feedback
  # fenced block — load-bearing for the new signal, same as
  # resolve-defaults' heading removal.
  assert_contains "$cmd_path" "must not contain the raw" \
    "refine-issues.md documents that bucket (c)'s rewrite removes the raw-feedback fenced block"
fi

assert_file_exists "$claude_md_path" "CLAUDE.md exists"
if [[ -f "$claude_md_path" ]]; then
  assert_contains "$claude_md_path" "1055" \
    "CLAUDE.md's Origin labels section cites #1055"
  assert_contains "$claude_md_path" "the label alone can't double as a live" \
    "CLAUDE.md documents that the permanent user-feedback label isn't a live refinement flag"
fi

assert_file_exists "$backlog_overview_path" "do-work/setup/01b-backlog-overview.md exists"
if [[ -f "$backlog_overview_path" ]]; then
  assert_contains "$backlog_overview_path" "1055" \
    "01b-backlog-overview.md's duplicated scan cites #1055"
  # The --fast advisory-count jq must be kept in sync with the same
  # label-AND-body-shape condition as the canonical scan.
  assert_contains "$backlog_overview_path" '(.labels | any(.name == "user-feedback")) and ((.body // "") | test("(?m)^```user-feedback"))' \
    "01b-backlog-overview.md's --fast advisory scan ANDs the label with the raw-feedback body-shape check"
fi

assert_file_exists "$label_recovery_refine_path" "do-work/setup/01c-label-recovery-refine.md exists"
if [[ -f "$label_recovery_refine_path" ]]; then
  assert_contains "$label_recovery_refine_path" "1055" \
    "01c-label-recovery-refine.md's step 3.5 description cites #1055"
fi

# ---------------------------------------------------------------------
# Part 2: functional jq test — pins the actual scan behavior
# ---------------------------------------------------------------------

echo
echo "Functional scan behavior (jq, synthetic fixtures)"
echo

# Mirrors the canonical scan in refine-issues.md step 3 (and the --fast
# advisory duplicate in 01b-backlog-overview.md). Keep in sync if the
# projection changes — same convention as rollup-latest-per-name.test.sh's
# JQ_LATEST_PER_NAME.
# shellcheck disable=SC2016  # literal jq variable references ($labels, $body, ...), not shell expansion
JQ_SIGNAL_MATCH='
  ($labels | any(. == "user-feedback"))                                   as $has_user_feedback_label
  | (($body // "") | test("(?m)^```user-feedback"))                      as $looks_like_raw_feedback
  | ($has_user_feedback_label and $looks_like_raw_feedback)               as $is_user_feedback
  | (($body // "") | test("(?m)^## Open [qQ]uestions[[:space:]]*$"))     as $has_open_questions
  | ($is_user_feedback or $has_open_questions)
'

# Fixture 1: the live #1045 repro — trusted-author, already-refined body
# (Summary / evidence table / Suggested shape), carries the permanent
# user-feedback label, but no raw-feedback fenced block. MUST NOT match.
ALREADY_REFINED_BODY=$(cat <<'BODY'
## Summary

Some fully-refined description with a table and evidence.

## Suggested shape

1. Do the thing.

## Non-goals

- Not doing the other thing.
BODY
)
already_refined_match=$(jq -n --arg body "$ALREADY_REFINED_BODY" \
  --argjson labels '["enhancement", "P1", "user-feedback"]' \
  '{body: $body, labels: $labels} | .body as $body | .labels as $labels | '"$JQ_SIGNAL_MATCH")
assert_equals "#1045-shaped issue (user-feedback label, already-refined body) does NOT match the scan" \
  "false" "$already_refined_match"

# Fixture 2: genuine raw feedback per the intake contract — carries the
# label AND the raw fenced block. MUST match.
RAW_FEEDBACK_BODY=$(cat <<'BODY'
> **End-user feedback** — filed automatically from the mobile app.

## Metadata

- **Source:** `mobile-app/ios`

## Reported feedback

```user-feedback
The app crashed when I tapped save.
```
BODY
)
raw_feedback_match=$(jq -n --arg body "$RAW_FEEDBACK_BODY" \
  --argjson labels '["user-feedback"]' \
  '{body: $body, labels: $labels} | .body as $body | .labels as $labels | '"$JQ_SIGNAL_MATCH")
assert_equals "genuine raw-feedback issue (label + fenced block) DOES match the scan" \
  "true" "$raw_feedback_match"

# Fixture 3: an already-refined bucket-(c) rewrite — label still present
# (permanent), but the body was rewritten per the issue template and no
# longer contains the fenced block. MUST NOT match (this is the
# no-longer-matching-signal property described in the Idempotency
# invariants section, in addition to the sentinel).
REWRITTEN_BODY=$(cat <<'BODY'
## Summary

Rewritten per the issue template.

## Steps to reproduce

(not provided — would need to ask the user)
BODY
)
rewritten_match=$(jq -n --arg body "$REWRITTEN_BODY" \
  --argjson labels '["user-feedback", "needs-human-review"]' \
  '{body: $body, labels: $labels} | .body as $body | .labels as $labels | '"$JQ_SIGNAL_MATCH")
assert_equals "post-rewrite bucket-(c) issue (label present, fenced block removed) does NOT match the scan" \
  "false" "$rewritten_match"

# Fixture 4: no user-feedback label at all, but an open-questions heading.
# The open-questions signal must be untouched by the #1055 narrowing.
OPEN_QUESTIONS_BODY=$(cat <<'BODY'
Some design proposal.

## Open questions

- Should this be P0 or P1?
BODY
)
open_questions_match=$(jq -n --arg body "$OPEN_QUESTIONS_BODY" \
  --argjson labels '[]' \
  '{body: $body, labels: $labels} | .body as $body | .labels as $labels | '"$JQ_SIGNAL_MATCH")
assert_equals "open-questions issue (no user-feedback label) still matches via the untouched open-questions signal" \
  "true" "$open_questions_match"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

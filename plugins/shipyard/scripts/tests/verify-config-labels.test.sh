#!/usr/bin/env bash
# Test: verify-config-labels.sh — cross-references the merged config's
# `labels` block against the labels that actually exist in the target repo
# (issue #1359).
#
# Background: a consumer repo (e.g. mattsears18/lightwork) that declares no
# `labels` block inherits shipyard's built-in defaults wholesale, including
# label names that only ever held true of shipyard's OWN repo. Nothing
# verified this before #1359 — the mismatch was silent, and an issue routed
# through a phantom label is invisible to both `/do-work` and `/my-turn`.
#
# These tests exercise the script's hermetic `--decide` mode (pure function
# of two JSON blobs, no network I/O) — the same shape
# detect-ungated-admin-direct-merge.sh uses for its own `--decide` tests.
#
# Pure bash + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/verify-config-labels.test.sh

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

script="$repo_root/plugins/shipyard/scripts/verify-config-labels.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

echo "verify-config-labels.sh regression tests (issue #1359)"
echo

if [[ -f "$script" ]]; then
  ok "scripts/verify-config-labels.sh exists"
else
  bad "scripts/verify-config-labels.sh exists (missing: $script)"
  echo
  printf '%sFAIL%s  %d test(s) failed (%d passed) — cannot run behavioral tests, script missing\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
fi

if [[ -x "$script" ]]; then
  ok "scripts/verify-config-labels.sh has the exec bit set"
else
  bad "scripts/verify-config-labels.sh has the exec bit set"
fi

# ── (1) All config-named labels present → OK, exit 0. ───────────────────────
cfg='{"session_stamp":"shipyard","needs_human_review":"needs-human-review"}'
existing='["shipyard","needs-human-review","bug","P1"]'
out="$(bash "$script" --decide "$cfg" "$existing" 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* && "$out" == *"2 label(s)"* ]]; then
  ok "all config-named labels present: exit 0, OK verdict naming the count"
else
  bad "all config-named labels present: expected exit 0 + OK 2 label(s), got exit $status: $out"
fi

# ── (2) THE #1359 REPRO SHAPE: two config-named labels absent (the
# lightwork case — blocked:agent / blocked:agent-hard never existed there).
# Must fire loudly, never silently continue. ────────────────────────────────
cfg='{"session_stamp":"shipyard","blocked":"blocked:agent","blocked_hard":"blocked:agent-hard","blocked_soft":"blocked:agent-soft","ci_blocked":"blocked:ci"}'
existing='["shipyard","blocked:agent-soft","blocked:ci","bug","P1"]'
out="$(bash "$script" --decide "$cfg" "$existing" 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == *"MISSING: 2 of 5 label(s)"* ]]; then
  ok "issue #1359 repro shape: exit 1, MISSING summary names 2 of 5"
else
  bad "issue #1359 repro shape: expected exit 1 + 'MISSING: 2 of 5', got exit $status: $out"
fi
if [[ "$out" == *'MISSING_LABEL: labels.blocked="blocked:agent"'* ]]; then
  ok "issue #1359 repro shape: names the missing 'blocked' key and its label value"
else
  bad "issue #1359 repro shape: expected a MISSING_LABEL line for labels.blocked=\"blocked:agent\", got: $out"
fi
if [[ "$out" == *'MISSING_LABEL: labels.blocked_hard="blocked:agent-hard"'* ]]; then
  ok "issue #1359 repro shape: names the missing 'blocked_hard' key and its label value"
else
  bad "issue #1359 repro shape: expected a MISSING_LABEL line for labels.blocked_hard=\"blocked:agent-hard\", got: $out"
fi
if [[ "$out" != *'MISSING_LABEL: labels.blocked_soft='* && "$out" != *'MISSING_LABEL: labels.ci_blocked='* ]]; then
  ok "issue #1359 repro shape: does not flag the two present labels (blocked_soft, ci_blocked)"
else
  bad "issue #1359 repro shape: false-flagged a present label, got: $out"
fi

# ── (3) A single missing label out of many. ─────────────────────────────────
cfg='{"a":"one","b":"two","c":"three"}'
existing='["one","three"]'
out="$(bash "$script" --decide "$cfg" "$existing" 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == *"MISSING: 1 of 3 label(s)"* && "$out" == *'MISSING_LABEL: labels.b="two"'* ]]; then
  ok "single missing label out of three: exit 1, correctly identifies only 'b'"
else
  bad "single missing label out of three: expected exit 1 naming only labels.b, got exit $status: $out"
fi

# ── (4) SUBSTRING TRAP: a config label that is a substring of an existing
# label must NOT be treated as present — jq's contains/inside recurse into
# substring matching for strings, which would silently swallow this exact
# case if the script used inside()/contains() instead of exact index()
# equality. This is the regression this suite exists to pin. ───────────────
cfg='{"ci_blocked":"blocked:ci"}'
existing='["blocked:ci-old","something-else"]'
out="$(bash "$script" --decide "$cfg" "$existing" 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == *'MISSING_LABEL: labels.ci_blocked="blocked:ci"'* ]]; then
  ok "substring trap: 'blocked:ci' is not falsely satisfied by the existing label 'blocked:ci-old'"
else
  bad "substring trap: expected exit 1 flagging labels.ci_blocked, got exit $status: $out (exact-match check regressed to substring matching)"
fi

# ── (5) Empty config-labels object → nothing to check, OK. ──────────────────
out="$(bash "$script" --decide '{}' '["bug"]' 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* && "$out" == *"0 label(s)"* ]]; then
  ok "empty config-labels object: exit 0, OK 0 label(s)"
else
  bad "empty config-labels object: expected exit 0 + OK 0 label(s), got exit $status: $out"
fi

# ── (6) Bad usage — wrong arg count under --decide. ──────────────────────────
out="$(bash "$script" --decide '{}' 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == *usage:* ]]; then
  ok "bad usage (--decide with missing arg): exit 2, usage message"
else
  bad "bad usage (--decide with missing arg): expected exit 2 + usage, got exit $status: $out"
fi

# ── (7) Malformed JSON input never reads as a silent pass — must be loud
# (INDETERMINATE), never OK. ─────────────────────────────────────────────────
out="$(bash "$script" --decide 'not-json' '["bug"]' 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == *INDETERMINATE:* ]]; then
  ok "malformed config-labels JSON: exit 2, INDETERMINATE — never a silent OK"
else
  bad "malformed config-labels JSON: expected exit 2 + INDETERMINATE, got exit $status: $out"
fi

out="$(bash "$script" --decide '{"a":"one"}' 'not-json' 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == *INDETERMINATE:* ]]; then
  ok "malformed existing-labels JSON: exit 2, INDETERMINATE — never a silent OK"
else
  bad "malformed existing-labels JSON: expected exit 2 + INDETERMINATE, got exit $status: $out"
fi

# ── (8) Wrong JSON shape (array where an object is expected, and vice
# versa) is rejected loudly rather than silently misread. ───────────────────
out="$(bash "$script" --decide '["not","an","object"]' '["bug"]' 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == *INDETERMINATE:* ]]; then
  ok "config-labels is an array, not an object: exit 2, INDETERMINATE"
else
  bad "config-labels is an array, not an object: expected exit 2 + INDETERMINATE, got exit $status: $out"
fi

out="$(bash "$script" --decide '{"a":"one"}' '{"not":"an-array"}' 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == *INDETERMINATE:* ]]; then
  ok "existing-labels is an object, not an array: exit 2, INDETERMINATE"
else
  bad "existing-labels is an object, not an array: expected exit 2 + INDETERMINATE, got exit $status: $out"
fi

# ── (9) Live mode with no CLAUDE_PLUGIN_ROOT set → loud INDETERMINATE, never
# a silent pass just because the config couldn't be resolved. ───────────────
out="$(env -u CLAUDE_PLUGIN_ROOT bash "$script" "mattsears18/shipyard" 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == *INDETERMINATE:* ]]; then
  ok "live mode with no CLAUDE_PLUGIN_ROOT: exit 2, INDETERMINATE — never a silent pass"
else
  bad "live mode with no CLAUDE_PLUGIN_ROOT: expected exit 2 + INDETERMINATE, got exit $status: $out"
fi

# ── (10) Live-mode usage error (no repo arg). ────────────────────────────────
out="$(bash "$script" 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == *usage:* ]]; then
  ok "live mode with no repo argument: exit 2, usage message"
else
  bad "live mode with no repo argument: expected exit 2 + usage, got exit $status: $out"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

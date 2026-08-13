#!/usr/bin/env bash
# Test: the post-return worktree reap step (A.0.5) is documented in
# commands/do-work/steady-state.md with the crash-detection contract,
# the worktree-reap.sh helper references, and the load-bearing
# `peer-alive → still reap` override that distinguishes it from step B.
#
# Background — issue #358: when an agent crashes mid-flight (API socket
# error, harness phantom re-fire per #317, etc.), step B's per-completion
# reap defers on `peer-alive` classifications — leaving the worktree
# locked until end-of-session because the agent's `claude` subprocess
# remained alive past the harness's `task-notification`. The fix adds a
# crash-aware A.0.5 sub-step that fires BEFORE A.1's return-string
# parsing and reaps on every classification including peer-alive,
# closing the worktree-leak window step B's defensive defer leaves open.
#
# This test is the regression guard: if the A.0.5 step is removed,
# renamed, or loses its load-bearing semantics (the peer-alive override,
# the crash-prefix detection, the worktree-reap.sh helper calls), the
# test fails.
#
# Pure bash, no external dependencies. Run with:
#
#   bash plugins/shipyard/scripts/tests/post-return-reap-A05.test.sh

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

steady_state_path="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
worktree_reap_path="$repo_root/plugins/shipyard/scripts/worktree-reap.sh"
# The terminal-prefix check itself was extracted into crash-recovery-reap.sh
# by issue #1291 — steady-state.md now only holds the invocation + verify/
# bookkeeping code, not the case statement.
crash_recovery_reap_path="$repo_root/plugins/shipyard/scripts/crash-recovery-reap.sh"
# detect-orchestrator-pid moved to session-identity.sh (issue #941) — the
# reap/classify-lock subcommands this test also exercises stayed put in
# worktree-reap.sh, so both paths are needed.
session_identity_path="$repo_root/plugins/shipyard/scripts/session-identity.sh"

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

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to find in %s: %s\n' "$file" "$needle"
    fail=$((fail+1))
  else
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  fi
}

# Same shape as worktree-reap.test.sh's assert_equals/assert_exit_code —
# used by the issue #1316 inspect-unpushed runtime tests below, which check
# literal stdout/exit-code values rather than file content.
assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_exit_code() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected exit %s, got %s)\n' "$RED" "$RESET" "$label" "$expected" "$actual"
    fail=$((fail+1))
  fi
}

assert_section_ordering() {
  local file="$1"
  local before="$2"
  local after="$3"
  local label="$4"
  local before_line after_line
  before_line=$(grep -nF -- "$before" "$file" | head -1 | cut -d: -f1)
  after_line=$(grep -nF -- "$after" "$file" | head -1 | cut -d: -f1)
  if [[ -z "$before_line" ]]; then
    printf '  %sFAIL%s  %s (could not find before-marker: %s)\n' "$RED" "$RESET" "$label" "$before"
    fail=$((fail+1))
    return
  fi
  if [[ -z "$after_line" ]]; then
    printf '  %sFAIL%s  %s (could not find after-marker: %s)\n' "$RED" "$RESET" "$label" "$after"
    fail=$((fail+1))
    return
  fi
  if (( before_line < after_line )); then
    printf '  %sPASS%s  %s (before @ line %d, after @ line %d)\n' "$GREEN" "$RESET" "$label" "$before_line" "$after_line"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (expected before-marker before after-marker; got before @ %d, after @ %d)\n' "$RED" "$RESET" "$label" "$before_line" "$after_line"
    fail=$((fail+1))
  fi
}

# Run reap helper subcommand with a tempfile and check classification (used
# below to assert the helper still supports the subcommand shapes A.0.5
# depends on, in case the helper itself drifts).
run_classify_lock() {
  local lock_content="$1"
  local tmp
  tmp=$(mktemp)
  printf '%s' "$lock_content" > "$tmp"
  bash "$worktree_reap_path" classify-lock "$tmp" 2>/dev/null
  local rc=$?
  rm -f "$tmp"
  return $rc
}

echo ""
echo "Test: post-return worktree reap (A.0.5) — issue #358 regression guard"
echo ""

# 1) The spec files we depend on exist.
assert_file_exists "$steady_state_path" "steady-state.md exists"
assert_file_exists "$worktree_reap_path" "worktree-reap.sh exists"

# 2) The A.0.5 step is documented by name with the canonical header.
assert_contains "$steady_state_path" \
  "#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns" \
  "A.0.5 header present"

# 3) The issue is referenced inline so a reader can trace the rationale.
assert_contains "$steady_state_path" \
  "Closes [#358]" \
  "A.0.5 names issue #358 inline"

# 4) The crash-detection contract is documented — the six valid terminal prefixes
#    must all appear in the prefix-check guidance. This case statement moved
#    into crash-recovery-reap.sh with the #1291 extraction.
assert_file_exists "$crash_recovery_reap_path" "scripts/crash-recovery-reap.sh exists (#1291 extraction)"
assert_contains "$crash_recovery_reap_path" \
  "shipped*|green*|noop:*|blocked*|rebased*|reaped:*" \
  "crash-recovery-reap.sh prefix check enumerates all six terminal prefixes"

# 5) The crash-like shapes the user might encounter are named (API Error,
#    empty, narrative). These are documentation contract — the prose tells
#    the orchestrator what to recognize.
assert_contains "$steady_state_path" \
  "API Error:" \
  "A.0.5 names \"API Error:\" as a crash-like shape"
assert_contains "$steady_state_path" \
  "narrative" \
  "A.0.5 names narrative status updates as crash-like"

# 6) The worktree-reap.sh helper is invoked via the two canonical subcommands
#    the orchestrator's other reap paths use.
assert_contains "$steady_state_path" \
  "scripts/worktree-reap.sh\" \\" \
  "A.0.5 invokes worktree-reap.sh (line-continuation form)"
assert_contains "$steady_state_path" \
  "classify-lock" \
  "A.0.5 calls classify-lock"
assert_contains "$steady_state_path" \
  '--phase "reconcile-A.0.5"' \
  "A.0.5 reap call carries --phase reconcile-A.0.5"

# 7) The load-bearing peer-alive override is documented — this is the key
#    difference from step B (which defers on peer-alive). Removing it
#    re-introduces the #358 failure mode.
assert_contains "$steady_state_path" \
  "peer-alive" \
  "A.0.5 names peer-alive classification"
assert_contains "$steady_state_path" \
  "still reap" \
  "A.0.5 documents the still-reap override on crash returns"

# 8) The SHIPYARD_ORCHESTRATOR_PID bootstrap is preserved (same idiom as
#    step B / step A.1's shipped path) — without it, classify-lock can
#    mis-classify the lock as peer-alive in subagent-invocation cases.
assert_contains "$steady_state_path" \
  "SHIPYARD_ORCHESTRATOR_PID" \
  "A.0.5 bootstraps SHIPYARD_ORCHESTRATOR_PID"
assert_contains "$steady_state_path" \
  "detect-orchestrator-pid" \
  "A.0.5 uses detect-orchestrator-pid to bootstrap the env var"

# 9) Step ordering — A.0.5 must come AFTER A.0 (token attribution) and
#    BEFORE A.1 (return-string parsing). The dispatch prompt makes this
#    explicit and the orchestrator's working memory depends on `agent_id`
#    still being in `.in_flight.<slot>` (slot release is step B).
assert_section_ordering "$steady_state_path" \
  "#### A.0. Attribute the dispatch's token usage" \
  "#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns" \
  "A.0.5 follows A.0 in document order"
assert_section_ordering "$steady_state_path" \
  "#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns" \
  "#### A.1. Parse the return string" \
  "A.0.5 precedes A.1 in document order"

# 10) Interaction with step B is documented — A.0.5 does NOT replace step B;
#     it fires earlier on crash returns. The duplicate-reap is intentionally
#     harmless.
assert_contains "$steady_state_path" \
  "step B" \
  "A.0.5 names step B in the interaction discussion"
assert_contains "$steady_state_path" \
  "duplicate-reap is harmless" \
  "A.0.5 documents the duplicate-reap-is-harmless invariant"

# 11) Audit-log phase contract — the new phase string must be documented
#     so the reap-audit.jsonl consumer (operator or future tooling) can
#     filter on it.
assert_contains "$steady_state_path" \
  '"phase":"reconcile-A.0.5"' \
  "A.0.5 documents the reap-audit.jsonl phase value"

# 12) Helper-runtime sanity gate — the classify-lock subcommand the spec
#     calls is still implemented in worktree-reap.sh. If the helper drifts
#     (e.g., subcommand rename), this test catches it independently of the
#     spec assertions above.
echo ""
echo "Runtime: worktree-reap.sh subcommand sanity"
echo ""

# A non-existent lock file → no-lock (the path A.0.5 hits when the
# worktree's already been reaped by a concurrent path).
nolock_out=$(bash "$worktree_reap_path" classify-lock /tmp/this-file-does-not-exist-358 2>/dev/null)
if [[ "$nolock_out" == "no-lock" ]]; then
  printf '  %sPASS%s  classify-lock returns no-lock for missing lock file\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  classify-lock for missing file: expected "no-lock", got "%s"\n' "$RED" "$RESET" "$nolock_out"
  fail=$((fail+1))
fi

# Dead-PID lock (PID 0 is unkillable but ps -p 0 returns non-zero) →
# `dead`. This is the canonical safe-to-reap path. We use PID 0 because
# it's stable and predictable across CI runs; macOS and Linux both report
# it as not-alive via ps -p.
dead_classification=$(run_classify_lock "claude agent test-agent-id (pid 0)")
if [[ "$dead_classification" == "dead" ]]; then
  printf '  %sPASS%s  classify-lock returns dead for PID 0\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  classify-lock with PID 0: expected "dead", got "%s"\n' "$RED" "$RESET" "$dead_classification"
  fail=$((fail+1))
fi

# detect-orchestrator-pid subcommand exists and is callable (now in the
# sibling session-identity.sh — issue #941). We don't assert the output —
# the result depends on the test runner's process tree — only that the
# subcommand is recognized (exit 0).
if bash "$session_identity_path" detect-orchestrator-pid >/dev/null 2>&1; then
  printf '  %sPASS%s  detect-orchestrator-pid subcommand is callable\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  detect-orchestrator-pid subcommand failed\n' "$RED" "$RESET"
  fail=$((fail+1))
fi

# reap subcommand recognizes the --phase reconcile-A.0.5 form (we exercise
# with --action reaped, --skip-remove so no actual worktree manipulation
# happens). Use a temp SHIPYARD_HOME so the audit log lands in /tmp and
# doesn't pollute the user's real audit log.
tmp_shipyard_home=$(mktemp -d)
export SHIPYARD_HOME="$tmp_shipyard_home"
reap_out=$(bash "$worktree_reap_path" reap \
  --action reaped \
  --worktree-path "/tmp/nonexistent-358-test" \
  --worktree-name "agent-test-358" \
  --session-id "test-session-358" \
  --classification "self-ancestor" \
  --lock-pid 0 \
  --phase "reconcile-A.0.5" \
  --skip-remove 2>&1)
reap_rc=$?
if [[ $reap_rc -eq 1 ]]; then
  printf '  %sPASS%s  reap --phase reconcile-A.0.5 with NO --bypass-return-check is refused (issue #1237 — no session-state fixture exists here)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  reap --phase reconcile-A.0.5 without bypass: expected exit 1, got %d (output: %s)\n' "$RED" "$RESET" "$reap_rc" "$reap_out"
  fail=$((fail+1))
fi

# The A.0.5 crash-recovery reap is a documented issue #1237 exception — the
# crashed/stalled agent never reached a terminal return, so it can never
# have a .returned_agent_ids record. steady-state.md's A.0.5 block passes
# --bypass-return-check accordingly; this is the regression pin that the
# real call site still works once that flag is supplied.
rm -f "$tmp_shipyard_home/reap-audit.jsonl"
reap_out_bypassed=$(bash "$worktree_reap_path" reap \
  --action reaped \
  --worktree-path "/tmp/nonexistent-358-test" \
  --worktree-name "agent-test-358" \
  --session-id "test-session-358" \
  --classification "self-ancestor" \
  --lock-pid 0 \
  --phase "reconcile-A.0.5" \
  --bypass-return-check "crash-recovery reap (#1237) — worker never reached a terminal return" \
  --skip-remove 2>&1)
reap_bypassed_rc=$?
if [[ $reap_bypassed_rc -eq 0 ]]; then
  printf '  %sPASS%s  reap --phase reconcile-A.0.5 --bypass-return-check succeeds (the documented A.0.5 exception)\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  reap --phase reconcile-A.0.5 --bypass-return-check: expected exit 0, got %d (output: %s)\n' "$RED" "$RESET" "$reap_bypassed_rc" "$reap_out_bypassed"
  fail=$((fail+1))
fi

# Audit-log line for the reap above contains the phase field.
audit_log="$tmp_shipyard_home/reap-audit.jsonl"
if [[ -f "$audit_log" ]] && grep -qF '"phase":"reconcile-A.0.5"' "$audit_log"; then
  printf '  %sPASS%s  reap audit-log line carries "phase":"reconcile-A.0.5"\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  reap audit-log missing phase field at %s\n' "$RED" "$RESET" "$audit_log"
  [[ -f "$audit_log" ]] && printf '    audit-log content:\n%s\n' "$(cat "$audit_log")"
  fail=$((fail+1))
fi

# Cleanup
rm -rf "$tmp_shipyard_home"
unset SHIPYARD_HOME

echo ""
echo "Test: A.0.5's pre-reap inspection is reachable from a worktree-isolated"
echo "orchestrator session — issue #1316 regression guard"
echo ""

# Background — issue #1316: A.0.5's mandated inspection ("Never reap before
# inspecting") used to be written as an inline `git -C "$worktree_path" ...`
# in TWO places in steady-state.md — the "mechanical check that grounds the
# judgment call" and the stalled-worker resume path's step 2. Both are
# refused verbatim by the orchestrator's own worktree-isolation guard once
# the orchestrator has isolated itself per setup step 0.5 (EnterWorktree):
# a worktree-isolated session's harness guard unconditionally refuses any
# `git -C <other-worktree>` issued directly from its own Bash tool call,
# read-only or not. The fix moves the inspection inside a helper script
# (`worktree-reap.sh inspect-unpushed`) — `git -C` INSIDE a script's own
# bash process is unaffected by the guard, the same pattern `reap-stale`
# and `crash-recovery-reap.sh` already rely on.
#
# 1) The two literal inline `git -C "$worktree_path" ...` invocations that
#    used to live in these two spots are GONE from steady-state.md. This is
#    a narrow, exact-string check — it must not false-positive against the
#    "Recovery semantics, in order" section further down, which documents
#    (in prose, using `<worktree_path>` angle-bracket placeholders, not real
#    `"$worktree_path"` shell-variable syntax) what ALREADY runs inside the
#    extracted crash-recovery-reap.sh script — that site was never affected
#    by the guard and is intentionally left alone.
# shellcheck disable=SC2016  # literal needle — must NOT expand $(...) / $worktree_path
assert_not_contains "$steady_state_path" \
  'ahead_count=$(git -C "$worktree_path" rev-list --count' \
  "A.0.5 mechanical check no longer inlines a direct git -C rev-list (#1316)"
# shellcheck disable=SC2016  # literal needle — must NOT expand $(...) / $worktree_path
assert_not_contains "$steady_state_path" \
  'dirty=$(git -C "$worktree_path" status --porcelain' \
  "A.0.5 mechanical check no longer inlines a direct git -C status (#1316)"
# shellcheck disable=SC2016  # literal needle — must NOT expand $worktree_path / $DEFAULT_BRANCH
assert_not_contains "$steady_state_path" \
  'git -C "$worktree_path" fetch origin "$DEFAULT_BRANCH" 2>/dev/null || true' \
  "A.0.5 resume-path step 2 no longer inlines a direct git -C fetch (#1316)"
# shellcheck disable=SC2016  # literal needle — must NOT expand $worktree_path / $DEFAULT_BRANCH
assert_not_contains "$steady_state_path" \
  'git -C "$worktree_path" log --oneline "origin/$DEFAULT_BRANCH..HEAD"' \
  "A.0.5 resume-path step 2 no longer inlines a direct git -C log (#1316)"

# 2) Both spots now call the inspect-unpushed subcommand instead, and the
#    resume path passes --fetch (it used to run its own explicit fetch
#    first).
# shellcheck disable=SC1003  # literal needle ending in a line-continuation backslash, not a shell escape
assert_contains "$steady_state_path" \
  'scripts/worktree-reap.sh" inspect-unpushed \' \
  "A.0.5 invokes worktree-reap.sh inspect-unpushed (#1316)"
# shellcheck disable=SC2016  # literal needle — must NOT expand $worktree_path / $DEFAULT_BRANCH
assert_contains "$steady_state_path" \
  '--worktree-path "$worktree_path" --default-branch "$DEFAULT_BRANCH" --fetch' \
  "A.0.5 resume-path step 2 calls inspect-unpushed --fetch (#1316)"

# 3) The Recovery semantics section's documentation of crash-recovery-
#    reap.sh's OWN internals — a genuinely different, already-extracted call
#    site the #1316 fix must not touch — is still intact.
assert_contains "$steady_state_path" \
  'git -C <worktree_path> rev-list --count origin/<default>..HEAD' \
  "Recovery semantics section (crash-recovery-reap.sh internals) is untouched by the #1316 fix"

echo ""
echo "Test: worktree-reap.sh inspect-unpushed subcommand (issue #1316)"
echo ""

# Runtime fixture: a real git repo with a local "origin" remote and a
# worktree registered on its own branch, mirroring the fast-reap fixture
# convention in worktree-reap.test.sh / crash-recovery-reap-1291.test.sh.
inspect_repo="$(mktemp -d)"
inspect_wt="$inspect_repo/.claude/worktrees/wt-inspect"

reset_inspect_repo() {
  rm -rf "$inspect_repo"
  mkdir -p "$inspect_repo"
  (
    cd "$inspect_repo" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
    git remote add origin "$inspect_repo"
    # A real remote-tracking ref, established once at fixture-reset time —
    # never advanced by an actual push, so any commit made in the worktree
    # afterward naturally simulates "unpushed" without needing a real push.
    git update-ref refs/remotes/origin/main main
    git branch wt-inspect >/dev/null 2>&1
    git worktree add -q "$inspect_wt" wt-inspect
  ) >/dev/null 2>&1
}

reset_inspect_repo

# --- (121) usage: missing --worktree-path exits 64 ---
out=$(bash "$worktree_reap_path" inspect-unpushed --default-branch main 2>&1); rc=$?
if [[ $rc -eq 64 ]]; then
  printf '  %sPASS%s  (121) inspect-unpushed without --worktree-path exits 64\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (121) inspect-unpushed without --worktree-path: expected exit 64, got %d\n' "$RED" "$RESET" "$rc"
  fail=$((fail+1))
fi

# --- (122) usage: missing --default-branch exits 64 ---
out=$(bash "$worktree_reap_path" inspect-unpushed --worktree-path "$inspect_wt" 2>&1); rc=$?
if [[ $rc -eq 64 ]]; then
  printf '  %sPASS%s  (122) inspect-unpushed without --default-branch exits 64\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (122) inspect-unpushed without --default-branch: expected exit 64, got %d\n' "$RED" "$RESET" "$rc"
  fail=$((fail+1))
fi

# --- (123) a non-worktree path exits 65 ---
out=$(bash "$worktree_reap_path" inspect-unpushed --worktree-path "/nonexistent-1316-$$" --default-branch main 2>&1); rc=$?
if [[ $rc -eq 65 ]]; then
  printf '  %sPASS%s  (123) inspect-unpushed on a non-git path exits 65\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (123) inspect-unpushed on a non-git path: expected exit 65, got %d\n' "$RED" "$RESET" "$rc"
  fail=$((fail+1))
fi

# --- (124) a clean worktree (no commits ahead, nothing dirty) → verdict=clean ---
out=$(bash "$worktree_reap_path" inspect-unpushed --worktree-path "$inspect_wt" --default-branch main)
rc=$?
if [[ $rc -eq 0 ]]; then
  printf '  %sPASS%s  (124) inspect-unpushed on a clean worktree exits 0\n' "$GREEN" "$RESET"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  (124) inspect-unpushed on a clean worktree: expected exit 0, got %d\n' "$RED" "$RESET" "$rc"
  fail=$((fail+1))
fi
case "$out" in
  "ahead_count=0 dirty_count=0 verdict=clean"*) clean_ok=1 ;;
  *) clean_ok=0 ;;
esac
assert_equals "$clean_ok" "1" \
  "(124a) clean worktree reports ahead_count=0 dirty_count=0 verdict=clean"

# --- (125) an uncommitted, dirty worktree → verdict=resume-worthy, dirty_count>0 ---
echo "scratch" > "$inspect_wt/scratch-file.txt"
out=$(bash "$worktree_reap_path" inspect-unpushed --worktree-path "$inspect_wt" --default-branch main)
case "$out" in
  "ahead_count=0 dirty_count=1 verdict=resume-worthy"*) dirty_ok=1 ;;
  *) dirty_ok=0 ;;
esac
assert_equals "$dirty_ok" "1" \
  "(125) dirty worktree reports ahead_count=0 dirty_count=1 verdict=resume-worthy"
case "$out" in
  *"--- dirty (git status --porcelain) ---"*"scratch-file.txt"*) dirty_listing_ok=1 ;;
  *) dirty_listing_ok=0 ;;
esac
assert_equals "$dirty_listing_ok" "1" \
  "(125a) dirty worktree's stdout includes the literal porcelain listing"
rm -f "$inspect_wt/scratch-file.txt"

# --- (126) a committed-but-unpushed commit → verdict=resume-worthy, ahead_count>0 ---
(
  cd "$inspect_wt" || exit 1
  git commit -q --allow-empty -m "unpushed work"
) >/dev/null 2>&1
out=$(bash "$worktree_reap_path" inspect-unpushed --worktree-path "$inspect_wt" --default-branch main)
case "$out" in
  "ahead_count=1 dirty_count=0 verdict=resume-worthy"*) ahead_ok=1 ;;
  *) ahead_ok=0 ;;
esac
assert_equals "$ahead_ok" "1" \
  "(126) worktree with one unpushed commit reports ahead_count=1 dirty_count=0 verdict=resume-worthy"
case "$out" in
  *"--- commits (git log --oneline origin/main..HEAD) ---"*"unpushed work"*) commit_listing_ok=1 ;;
  *) commit_listing_ok=0 ;;
esac
assert_equals "$commit_listing_ok" "1" \
  "(126a) unpushed-commit worktree's stdout includes the literal commit subject line"

# --- (127) --fetch does not error against a real (non-bare) origin remote ---
out=$(bash "$worktree_reap_path" inspect-unpushed --worktree-path "$inspect_wt" --default-branch main --fetch 2>&1)
rc=$?
assert_exit_code "$rc" "0" \
  "(127) inspect-unpushed --fetch exits 0 against a real origin remote"

rm -rf "$inspect_repo"

echo ""
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
exit 0

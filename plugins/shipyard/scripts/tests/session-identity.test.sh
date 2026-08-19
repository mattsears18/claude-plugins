#!/usr/bin/env bash
# Test suite for scripts/session-identity.sh.
#
# Issue #941 — this suite is a pure relocation of the detect-orchestrator-pid
# / derive-session-id / find-orphan-orchestrators test coverage that used to
# live in worktree-reap.test.sh, split out alongside the source-code move of
# those three subcommands into their own sibling script (session-identity.sh).
# No test content was rewritten or dropped in the move — only the `$helper`
# path target changed (worktree-reap.sh → session-identity.sh) and the
# harness scaffolding was duplicated so this file runs standalone. Test
# labels below keep their ORIGINAL numbers from worktree-reap.test.sh's
# matrix (15-17, 18-30, 67-75a) rather than being renumbered from 1 — that
# preserves history-searchability (a comment, an issue, or a session
# transcript that cites "test 69" still resolves to the same assertion) at
# the minor cost of the new file's own numbering not starting at 1.
#
# Test matrix:
#  15-17) detect-orchestrator-pid match / no-match / exit code
#  18-30) issue #280 — find-orphan-orchestrators subcommand covers:
#         - empty layouts (no worktrees dir, no orchestrator-* entries)
#         - happy-path orphan with missing session file
#         - current session's own worktree never emitted
#         - alive PID session file → not orphan
#         - dead PID / null pid session file → orphan
#         - multiple orphans → multiple lines
#         - bad-usage cases (missing flags, unknown flag, positional arg)
#         - --flag=value form parity with --flag value form
#  31-35) issue #1232 — find-orphan-orchestrators reads the OCCUPANT
#         (.shipyard-session-id stash), not the directory name:
#         - the exact repro: dead name-embedded id, live stash id → not
#           emitted (whether the stash names the current session or a
#           different still-alive one)
#         - a readable stash naming a genuinely dead session → still
#           emitted (the fix doesn't stop reaping real orphans)
#         - no stash + non-empty directory → fail closed, not emitted
#         - no stash + genuinely empty directory → falls back to the
#           name-embedded id, unchanged from pre-#1232 behavior
#  36-38) issue #1234 — find-orphan-orchestrators --emit-resolved-id:
#         - default output (no flag) is unchanged — bare path only, even
#           when name and stash diverge
#         - the divergent case pinned exactly: dir name embeds one dead
#           id, stash names a DIFFERENT dead id → --emit-resolved-id
#           emits the STASH id (the one actually tested for liveness),
#           not the name-embedded one
#         - the degenerate fallback case (#1232's test 35) still reports
#           the name-embedded id as the "resolved" id when there's no
#           stash to prefer
#  67-75a) issue #513 — derive-session-id picks the NEWEST orchestrator-*
#         worktree's stash (not the oldest orphan in listing order):
#         - empty layout, single-worktree common case
#         - the repro: live (newest) wins over 5 accumulated older orphans
#         - recency beats lexical name order
#         - candidate without/with empty stash skipped for an older valid one
#         - agent-* worktrees ignored; stash contents whitespace-trimmed
#         - bad-usage cases (missing flag, unknown flag)
#  76-82a) issue #1479 — resolve-session-id collapses the two-path derive
#         (derive-session-id + the `<repo-root>/.shipyard-session-id`
#         fallback + #548's loud-empty diagnostic) into ONE call, so the
#         orchestrator's reconcile blocks carry no `--repo-root
#         "$REPO_ROOT"` / `[ -z "$SESSION_ID" ]` word for the
#         worktree-isolation guard to refuse:
#         - derive path preferred; primary-stash fallback when it's empty
#         - fallback contents whitespace-trimmed (parity with the derive)
#         - both empty → empty stdout, exit 0, loud stderr line
#         - a successful resolve is silent on stderr
#         - --repo-root is OPTIONAL here (omitting it is not exit 64)
#         - --repo-root=<value> parity; unknown flag / positional → exit 64
#
# Pure bash + `ps`. Run with:
#   bash plugins/shipyard/scripts/tests/session-identity.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../session-identity.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

tmpdir=$(mktemp -d -t session-identity-test.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

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

echo "session-identity.sh tests (issue #941)"
echo

# --- (15) detect-orchestrator-pid — match on this test process's own
# basename. We invoke a fresh bash subprocess to run the helper, so the
# walk will find a process whose `comm` matches the test runner. We pick
# the comm by reading our own `$$`'s comm dynamically — that way the
# test is robust across shells (bash, zsh) and OS conventions for the
# `ps -o comm=` output format.
own_comm=$(basename "$(ps -o comm= -p $$ 2>/dev/null | tr -d ' ')" 2>/dev/null)
if [ -n "$own_comm" ]; then
  # Spawn a child shell of OUR own kind so the detection finds it. The
  # helper walks via PPID, so the child's parent is our test runner. The
  # child sees its own ancestor chain including our PID with our comm.
  # Use process substitution so we don't fork a subshell that changes the
  # process tree shape.
  result=$("$own_comm" "$helper" detect-orchestrator-pid "$own_comm" 2>/dev/null)
  if [ -n "$result" ] && [[ "$result" =~ ^[0-9]+$ ]]; then
    printf '  %sPASS%s  (15) detect-orchestrator-pid with override finds an ancestor PID (own_comm=%s, found=%s)\n' \
      "$GREEN" "$RESET" "$own_comm" "$result"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  (15) detect-orchestrator-pid returned empty / non-numeric: %s (own_comm=%s)\n' \
      "$RED" "$RESET" "$result" "$own_comm"
    fail=$((fail+1))
  fi
else
  printf '  %sSKIP%s  (15) could not determine own comm — skipping detect-orchestrator-pid match test\n' \
    "$GREEN" "$RESET"
fi

# --- (16) detect-orchestrator-pid — non-existent comm name returns empty.
result=$(bash "$helper" detect-orchestrator-pid this-comm-does-not-exist-anywhere 2>/dev/null)
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(16) detect-orchestrator-pid with unknown comm-name returns empty stdout"

# --- (17) detect-orchestrator-pid — exit code 0 whether or not a match.
bash "$helper" detect-orchestrator-pid this-comm-does-not-exist-anywhere >/dev/null 2>&1
assert_exit_code "$?" "0" \
  "(17) detect-orchestrator-pid exits 0 even on no-match (caller decides)"

# --- find-orphan-orchestrators (issue #280) ---
#
# These tests build a synthetic worktrees layout under $tmpdir and a
# synthetic SHIPYARD_HOME so the discovery logic can be exercised
# without touching the real repo or real session files. Each test
# resets the fake layout before running.

echo
echo "find-orphan-orchestrators tests (issue #280)"
echo

# Build a fake repo-root with a worktrees dir.
fake_repo="$tmpdir/fake-repo"
mkdir -p "$fake_repo/.claude/worktrees"

# Build a fake SHIPYARD_HOME with a sessions dir.
fake_shipyard_home="$tmpdir/fake-shipyard"
mkdir -p "$fake_shipyard_home/sessions"

# Helper to invoke find-orphan-orchestrators with our fake SHIPYARD_HOME.
run_find_orphans() {
  SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
    --repo-root "$fake_repo" \
    --current-session-id "$1" 2>/dev/null
}

# Reset the fake layout to a known-empty state.
reset_fake_layout() {
  rm -rf "$fake_repo/.claude/worktrees"/orchestrator-*
  rm -f "$fake_shipyard_home/sessions"/*.json
}

# --- (18) no worktrees dir at all → empty output, exit 0 ---
no_wt_repo="$tmpdir/no-wt-repo"
mkdir -p "$no_wt_repo"
result=$(SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$no_wt_repo" --current-session-id "current-sess" 2>/dev/null)
exit_code=$?
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(18) no .claude/worktrees dir → empty output"
assert_exit_code "$exit_code" "0" \
  "(18a) no .claude/worktrees dir → exit 0"

# --- (19) worktrees dir present but no orchestrator-* entries → empty ---
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/agent-abc"   # only agent-*, no orchestrator-*
result=$(run_find_orphans "current-sess")
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(19) only agent-* worktrees, no orchestrator-* → empty output"

# --- (20) orphan: orchestrator-<dead> with NO session file → emit ---
# The exact failure mode the issue reports: prior session's cleanup got
# far enough to flush + delete its session file, but crashed before
# reaping its own worktree.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-dead-session-1"
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-dead-session-1" \
  "(20) orphan with no session file → emitted (the issue #280 repro case)"

# --- (21) current session's own orchestrator worktree → NOT emitted ---
# Even when its session file is missing — the in-flight session may
# have race conditions around its own file, but we must NEVER reap
# the running session's worktree out from under itself.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-current-sess"
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-dead-session-2"
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-dead-session-2" \
  "(21) current session's own worktree excluded even when own session file is missing"

# --- (22) session file PRESENT with live PID → NOT emitted (peer-alive) ---
# is-active should exit 0, this helper treats that as "active session,
# skip." Use our own $$ as the live PID — same pattern as classify-lock
# tests 4/5.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-live-session"
cat > "$fake_shipyard_home/sessions/live-session.json" <<EOF
{"session_id":"live-session","pid":$$}
EOF
result=$(run_find_orphans "current-sess")
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(22) session file present + PID alive → not emitted (defer)"

# --- (23) session file PRESENT but PID dead → emitted (orphan) ---
# Spawn-and-reap pattern (matches test 2 in the classify-lock suite).
(true) &
dead_pid_for_orph=$!
wait "$dead_pid_for_orph" 2>/dev/null
while ps -p "$dead_pid_for_orph" -o pid= >/dev/null 2>&1; do
  sleep 0.05
done
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-dead-pid-session"
cat > "$fake_shipyard_home/sessions/dead-pid-session.json" <<EOF
{"session_id":"dead-pid-session","pid":$dead_pid_for_orph}
EOF
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-dead-pid-session" \
  "(23) session file present + PID dead → emitted (is-active exits non-zero)"

# --- (24) session file PRESENT but pid is null → emitted (treated as inactive) ---
# Older session files written before the pid field existed: is-active
# falls through to exit 1 → orphan from this helper's perspective.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-null-pid-session"
cat > "$fake_shipyard_home/sessions/null-pid-session.json" <<EOF
{"session_id":"null-pid-session","pid":null}
EOF
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-null-pid-session" \
  "(24) session file present + pid null → emitted (is-active treats null as inactive)"

# --- (25) multiple orphans → multiple paths emitted (newline-delimited) ---
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-orphan-a"
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-orphan-b"
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-current-sess"
result=$(run_find_orphans "current-sess" | sort)
expected=$(printf '%s\n%s' \
  "$fake_repo/.claude/worktrees/orchestrator-orphan-a" \
  "$fake_repo/.claude/worktrees/orchestrator-orphan-b" | sort)
assert_equals "$result" "$expected" \
  "(25) multiple orphans → all emitted, current session excluded"

# --- (26) bad usage — missing --repo-root → exit 64 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --current-session-id foo >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(26) missing --repo-root → exit 64"

# --- (27) bad usage — missing --current-session-id → exit 64 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$fake_repo" >/dev/null 2>&1
assert_exit_code "$?" "64" \
  "(27) missing --current-session-id → exit 64"

# --- (28) bad usage — unknown flag → exit 64 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$fake_repo" --current-session-id foo --unknown 2>/dev/null
assert_exit_code "$?" "64" \
  "(28) unknown flag → exit 64"

# --- (29) bad usage — unexpected positional → exit 64 ---
SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root "$fake_repo" --current-session-id foo trailing-positional 2>/dev/null
assert_exit_code "$?" "64" \
  "(29) unexpected positional arg → exit 64"

# --- (30) --flag=value form works for --repo-root and --current-session-id ---
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-equals-form-orphan"
result=$(SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
  --repo-root="$fake_repo" --current-session-id=current-sess 2>/dev/null)
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-equals-form-orphan" \
  "(30) --flag=value form accepted for both flags"

# --- find-orphan-orchestrators: stash-first occupant resolution (issue #1232) ---
#
# The live repro this closes: a session runs inside an orchestrator
# worktree named for an EARLIER, now-dead session (EnterWorktree reuses
# the existing worktree when a second /do-work runs in an already-
# isolated Claude session, under a freshly-derived session id — the
# directory NAME and the live OCCUPANT diverge from that moment on). The
# pre-#1232 helper classified the directory as an orphan purely from its
# name, reaping a LIVE session's own cwd out from under it. The fix
# reads `.shipyard-session-id` (the occupant) instead of trusting the
# name, and fails closed (skips, never emits) when that stash can't be
# read and the directory isn't otherwise empty.

echo
echo "find-orphan-orchestrators: stash-first occupant resolution (issue #1232)"
echo

# --- (31) THE #1232 REPRO, pinned exactly: dir name embeds a DEAD
# session id, but the stash inside names the CURRENT (live) session.
# Must NOT be emitted — this is the destructive false-positive the
# issue reports.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-dead-name-embedded-id"
printf '%s\n' "current-sess" \
  > "$fake_repo/.claude/worktrees/orchestrator-dead-name-embedded-id/.shipyard-session-id"
result=$(run_find_orphans "current-sess")
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(31) #1232 repro: name embeds a dead id but stash names the LIVE current session → not emitted"

# --- (32) generalized repro: dir name embeds a dead id, but the stash
# names a DIFFERENT session (not the current one) that is itself still
# alive (session file present, PID alive). Must NOT be emitted — proves
# the fix reads the stash for the general liveness check, not merely as
# a current-session shortcut.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-dead-name-embedded-id-2"
printf '%s\n' "other-live-session" \
  > "$fake_repo/.claude/worktrees/orchestrator-dead-name-embedded-id-2/.shipyard-session-id"
cat > "$fake_shipyard_home/sessions/other-live-session.json" <<EOF
{"session_id":"other-live-session","pid":$$}
EOF
result=$(run_find_orphans "current-sess")
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(32) stash names a different but still-live session → not emitted (general stash-priority, not just current-session)"

# --- (33) genuinely abandoned: the stash IS readable and names a dead
# session (no session file at all). Must still be emitted — the fix
# does not make the sweep stop reaping real orphans when the stash is
# trustworthy.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-genuinely-dead-name"
printf '%s\n' "genuinely-dead-stash-id" \
  > "$fake_repo/.claude/worktrees/orchestrator-genuinely-dead-name/.shipyard-session-id"
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-genuinely-dead-name" \
  "(33) readable stash names a genuinely dead session (no session file) → still emitted"

# --- (34) fail-closed on ambiguity: NO stash file, but the directory is
# otherwise non-empty (simulates a real checkout — some other file
# present). Must NOT be emitted even though the name-embedded id's
# session file is missing (the pre-#1232 behavior would have emitted
# this). A missed reap only costs disk; a wrong reap costs a running
# session's work.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-no-stash-nonempty"
: > "$fake_repo/.claude/worktrees/orchestrator-no-stash-nonempty/some-checked-out-file"
result=$(run_find_orphans "current-sess")
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(34) no stash + non-empty directory → fail closed, not emitted (#1232 ambiguity guard)"

# --- (34a) fail-closed on ambiguity: stash file present but EMPTY, and
# nothing else in the directory besides that empty stash file. The
# directory is non-empty (the empty stash file itself counts), so this
# must fail closed too, not fall back to the name-embedded id.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-empty-stash-only"
: > "$fake_repo/.claude/worktrees/orchestrator-empty-stash-only/.shipyard-session-id"
result=$(run_find_orphans "current-sess")
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(34a) empty stash file present (directory non-empty) → fail closed, not emitted"

# --- (35) degenerate case preserved: NO stash file AND the directory is
# otherwise completely empty → falls back to the name-embedded id, same
# as the pre-#1232 behavior (nothing to lose — this is what tests
# 20/21/23/24/25/30 above already exercise, pinned explicitly here for
# the #1232 fallback rule itself).
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-truly-empty-dead"
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-truly-empty-dead" \
  "(35) no stash + genuinely empty directory → falls back to name-embedded id, still emitted"

# --- find-orphan-orchestrators --emit-resolved-id (issue #1234) ---
#
# The step-1.6.5 reap loop's audit log used to log `reaped_session_id`
# derived from the directory basename alone — correct only when the
# directory name and the id this helper actually tested for liveness
# (stash-first, per #1232) happen to agree. Once #1232 made the detector
# prefer the stash, a candidate whose stash names a DIFFERENT dead
# session than its directory name would still log the stale
# name-embedded id. --emit-resolved-id closes that gap by letting the
# caller read back the exact id the helper tested, instead of
# re-deriving (and potentially drifting from) the same rule a second
# time in the caller's own loop.

echo
echo "find-orphan-orchestrators --emit-resolved-id tests (issue #1234)"
echo

run_find_orphans_resolved() {
  SHIPYARD_HOME="$fake_shipyard_home" bash "$helper" find-orphan-orchestrators \
    --repo-root "$fake_repo" \
    --current-session-id "$1" \
    --emit-resolved-id 2>/dev/null
}

# --- (36) default output (no --emit-resolved-id) is byte-for-byte
# unchanged even when the directory name and stash diverge — the flag
# is additive/opt-in, not a format change for existing callers.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-name-embedded-dead-id"
printf '%s\n' "stash-embedded-dead-id" \
  > "$fake_repo/.claude/worktrees/orchestrator-name-embedded-dead-id/.shipyard-session-id"
result=$(run_find_orphans "current-sess")
assert_equals "$result" "$fake_repo/.claude/worktrees/orchestrator-name-embedded-dead-id" \
  "(36) default output (no flag) stays a bare path even when name and stash diverge"

# --- (37) THE #1234 REPRO, pinned exactly: directory name embeds one
# dead session id, the stash inside names a DIFFERENT dead session id.
# --emit-resolved-id must emit the STASH id (the id actually tested for
# liveness), never the name-embedded one.
result=$(run_find_orphans_resolved "current-sess")
assert_equals "$result" "$(printf '%s\t%s' \
  "$fake_repo/.claude/worktrees/orchestrator-name-embedded-dead-id" \
  "stash-embedded-dead-id")" \
  "(37) #1234 repro: --emit-resolved-id emits the STASH id, not the name-embedded id, when they diverge"

# --- (38) degenerate fallback case (mirrors test 35): no stash, genuinely
# empty directory → the "resolved" id IS the name-embedded id (there's
# nothing else to prefer), so --emit-resolved-id reports it explicitly
# rather than leaving the second field blank.
reset_fake_layout
mkdir -p "$fake_repo/.claude/worktrees/orchestrator-truly-empty-dead-resolved"
result=$(run_find_orphans_resolved "current-sess")
assert_equals "$result" "$(printf '%s\t%s' \
  "$fake_repo/.claude/worktrees/orchestrator-truly-empty-dead-resolved" \
  "truly-empty-dead-resolved")" \
  "(38) no stash + genuinely empty directory → --emit-resolved-id reports the name-embedded fallback id"

# --- derive-session-id (issue #513) ---
#
# Build a synthetic worktrees layout under $tmpdir and exercise the
# newest-by-mtime selection. The bug: the old `awk '...; exit'` derive
# returned the FIRST orchestrator-* worktree in listing order — the oldest
# orphan when prior crashed sessions accumulate — misattributing every
# session-state write to a dead orphan's session file.

echo
echo "derive-session-id tests (issue #513)"
echo

dsi_repo="$tmpdir/dsi-repo"
mkdir -p "$dsi_repo/.claude/worktrees"

run_derive() {
  bash "$helper" derive-session-id --repo-root "$dsi_repo" 2>/dev/null
}

reset_dsi_layout() {
  rm -rf "$dsi_repo/.claude/worktrees"/orchestrator-* 2>/dev/null
  rm -rf "$dsi_repo/.claude/worktrees"/agent-* 2>/dev/null
}

# Make an orchestrator worktree with a given session id and a controllable
# mtime. `touch -t <YYYYMMDDhhmm>` sets the dir mtime portably (GNU + BSD).
make_orch_wt() {
  local sid="$1" mtime_stamp="$2"
  local dir="$dsi_repo/.claude/worktrees/orchestrator-$sid"
  mkdir -p "$dir"
  printf '%s\n' "$sid" > "$dir/.shipyard-session-id"
  touch -t "$mtime_stamp" "$dir"
}

# --- (67) no worktrees dir → empty output, exit 0 ---
dsi_no_wt="$tmpdir/dsi-no-wt"
mkdir -p "$dsi_no_wt"
result=$(bash "$helper" derive-session-id --repo-root "$dsi_no_wt" 2>/dev/null)
exit_code=$?
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(67) no .claude/worktrees dir → empty output"
assert_exit_code "$exit_code" "0" \
  "(67a) no .claude/worktrees dir → exit 0"

# --- (68) single orchestrator worktree → its id (the common case) ---
reset_dsi_layout
make_orch_wt "do-work-only-session" "202606101200"
result=$(run_derive)
assert_equals "$result" "do-work-only-session" \
  "(68) single orchestrator worktree → its session id"

# --- (69) THE #513 repro: live session is NEWEST, orphans are older ---
# 5 older orphans + 1 live session created "now". The old first-in-listing
# derive returned the oldest orphan; newest-by-mtime must return the live one.
reset_dsi_layout
make_orch_wt "do-work-20260604T210804Z-81232" "202606042108"  # oldest orphan
make_orch_wt "do-work-20260605T100000Z-00001" "202606051000"
make_orch_wt "do-work-20260607T100000Z-00002" "202606071000"
make_orch_wt "do-work-20260608T100000Z-00003" "202606081000"
make_orch_wt "do-work-20260609T100000Z-00004" "202606091000"
make_orch_wt "do-work-20260610T045915Z-99999" "202606100459"  # live (newest)
result=$(run_derive)
assert_equals "$result" "do-work-20260610T045915Z-99999" \
  "(69) newest-by-mtime wins over 5 accumulated older orphans (the #513 repro)"

# --- (70) reverse mtime ordering — recency, not name, decides ---
# A lexically-LATER session id with an OLDER mtime must NOT win.
reset_dsi_layout
make_orch_wt "zzz-lexically-last-but-old" "202606010000"
make_orch_wt "aaa-lexically-first-but-new" "202606100000"
result=$(run_derive)
assert_equals "$result" "aaa-lexically-first-but-new" \
  "(70) newest mtime wins regardless of lexical name order"

# --- (71) candidate without a stash is skipped in favor of an older one
# that has one — correctness (a readable id) beats raw recency. ---
reset_dsi_layout
make_orch_wt "has-stash-but-older" "202606090000"
# A newer worktree with NO stash file (half-set-up or already-cleaned).
mkdir -p "$dsi_repo/.claude/worktrees/orchestrator-newer-no-stash"
touch -t "202606100000" "$dsi_repo/.claude/worktrees/orchestrator-newer-no-stash"
result=$(run_derive)
assert_equals "$result" "has-stash-but-older" \
  "(71) newer worktree without a stash is skipped; older one with a stash wins"

# --- (72) empty stash contents are skipped ---
reset_dsi_layout
make_orch_wt "good-stash" "202606090000"
mkdir -p "$dsi_repo/.claude/worktrees/orchestrator-empty-stash"
: > "$dsi_repo/.claude/worktrees/orchestrator-empty-stash/.shipyard-session-id"
touch -t "202606100000" "$dsi_repo/.claude/worktrees/orchestrator-empty-stash"
result=$(run_derive)
assert_equals "$result" "good-stash" \
  "(72) empty .shipyard-session-id is skipped in favor of a non-empty one"

# --- (73) agent-* worktrees are ignored (only orchestrator-* considered) ---
reset_dsi_layout
make_orch_wt "real-session" "202606090000"
mkdir -p "$dsi_repo/.claude/worktrees/agent-deadbeef"
printf '%s\n' "agent-should-not-win" > "$dsi_repo/.claude/worktrees/agent-deadbeef/.shipyard-session-id"
touch -t "202606100000" "$dsi_repo/.claude/worktrees/agent-deadbeef"
result=$(run_derive)
assert_equals "$result" "real-session" \
  "(73) agent-* worktrees are not candidates (only orchestrator-*)"

# --- (74) stash with surrounding whitespace/newlines is trimmed ---
reset_dsi_layout
mkdir -p "$dsi_repo/.claude/worktrees/orchestrator-padded"
printf '  do-work-padded-session  \n\n' > "$dsi_repo/.claude/worktrees/orchestrator-padded/.shipyard-session-id"
touch -t "202606100000" "$dsi_repo/.claude/worktrees/orchestrator-padded"
result=$(run_derive)
assert_equals "$result" "do-work-padded-session" \
  "(74) stash contents are whitespace-trimmed"

# --- (75) bad usage: missing --repo-root → exit 64 ---
bash "$helper" derive-session-id 2>/dev/null
assert_exit_code "$?" "64" \
  "(75) derive-session-id without --repo-root → exit 64"

# --- (75a) unknown flag → exit 64 ---
bash "$helper" derive-session-id --repo-root "$dsi_repo" --bogus 2>/dev/null
assert_exit_code "$?" "64" \
  "(75a) derive-session-id unknown flag → exit 64"

# ---------------------------------------------------------------------------
# resolve-session-id (issue #1479)
#
# The one-call form of the two-path derive the orchestrator's reconcile
# blocks used to spell inline. The point of the subcommand is that a caller
# needs neither `--repo-root "$REPO_ROOT"` nor a `[ -z "$SESSION_ID" ]`
# fallback test — both are words the worktree-isolation Bash guard refuses
# (do-work/dont.md's #1474 corrected rule; named as residual bucket-4
# findings by the #1476 audit). These tests pin the semantics the inline
# form had, so the collapse is verifiably behaviour-preserving.
# ---------------------------------------------------------------------------

echo
echo "resolve-session-id tests (issue #1479)"
echo

run_resolve() {
  bash "$helper" resolve-session-id --repo-root "$dsi_repo" 2>/dev/null
}

# --- (76) derive path wins: newest orchestrator-* stash is returned ---
reset_dsi_layout
rm -f "$dsi_repo/.shipyard-session-id"
make_orch_wt "do-work-old-orphan" "202606100000"
make_orch_wt "do-work-live" "202606201200"
result=$(run_resolve)
assert_equals "$result" "do-work-live" \
  "(76) resolve-session-id prefers the newest orchestrator-* stash"

# --- (77) fallback path: no orchestrator worktree, primary stash present ---
reset_dsi_layout
printf 'do-work-primary-stash\n' > "$dsi_repo/.shipyard-session-id"
result=$(run_resolve)
assert_equals "$result" "do-work-primary-stash" \
  "(77) falls back to <repo-root>/.shipyard-session-id when the derive is empty"

# --- (77a) the derive path OUTRANKS the primary stash when both exist ---
reset_dsi_layout
printf 'do-work-primary-stash\n' > "$dsi_repo/.shipyard-session-id"
make_orch_wt "do-work-live" "202606201200"
result=$(run_resolve)
assert_equals "$result" "do-work-live" \
  "(77a) derive result outranks the primary stash when both are present"

# --- (78) fallback contents are whitespace-trimmed (parity with the derive) ---
reset_dsi_layout
printf '  do-work-padded-primary  \n\n' > "$dsi_repo/.shipyard-session-id"
result=$(run_resolve)
assert_equals "$result" "do-work-padded-primary" \
  "(78) primary-stash fallback contents are whitespace-trimmed"

# --- (79) both paths empty → empty stdout, exit 0, loud stderr (#548) ---
reset_dsi_layout
rm -f "$dsi_repo/.shipyard-session-id"
result=$(bash "$helper" resolve-session-id --repo-root "$dsi_repo" 2>/dev/null)
exit_code=$?
assert_equals "${result:-EMPTY}" "EMPTY" \
  "(79) both derive paths empty → empty stdout"
assert_exit_code "$exit_code" "0" \
  "(79a) both derive paths empty → exit 0 (caller decides what empty means)"
stderr_out=$(bash "$helper" resolve-session-id --repo-root "$dsi_repo" 2>&1 >/dev/null)
case "$stderr_out" in
  *"[session-id-derive] empty"*)
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" \
      "(79b) both derive paths empty → loud [session-id-derive] empty line on stderr (#548)"
    pass=$((pass+1))
    ;;
  *)
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" \
      "(79b) both derive paths empty → expected a [session-id-derive] empty stderr line, got: $stderr_out"
    fail=$((fail+1))
    ;;
esac

# --- (80) a successful resolve prints NOTHING on stderr ---
reset_dsi_layout
make_orch_wt "do-work-quiet" "202606201200"
stderr_out=$(bash "$helper" resolve-session-id --repo-root "$dsi_repo" 2>&1 >/dev/null)
assert_equals "${stderr_out:-EMPTY}" "EMPTY" \
  "(80) a successful resolve is silent on stderr"

# --- (81) --repo-root is OPTIONAL (unlike derive-session-id, where it is
# required) — omitting it must NOT be a usage error. It defaults to
# `git rev-parse --show-toplevel`; from a non-repo cwd that resolves empty,
# which is the loud-but-exit-0 case, never exit 64. ---
resolve_nonrepo_dir="$tmpdir/resolve-nonrepo"
mkdir -p "$resolve_nonrepo_dir"
( cd "$resolve_nonrepo_dir" && bash "$helper" resolve-session-id >/dev/null 2>&1 )
assert_exit_code "$?" "0" \
  "(81) resolve-session-id without --repo-root is NOT a usage error"

# --- (81a) --repo-root=<value> form parity with --repo-root <value> ---
reset_dsi_layout
make_orch_wt "do-work-eqform" "202606201200"
result=$(bash "$helper" resolve-session-id --repo-root="$dsi_repo" 2>/dev/null)
assert_equals "$result" "do-work-eqform" \
  "(81a) --repo-root=<value> form matches --repo-root <value>"

# --- (82) bad usage: unknown flag / unexpected positional → exit 64 ---
bash "$helper" resolve-session-id --repo-root "$dsi_repo" --bogus 2>/dev/null
assert_exit_code "$?" "64" \
  "(82) resolve-session-id unknown flag → exit 64"
bash "$helper" resolve-session-id "$dsi_repo" 2>/dev/null
assert_exit_code "$?" "64" \
  "(82a) resolve-session-id unexpected positional arg → exit 64"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

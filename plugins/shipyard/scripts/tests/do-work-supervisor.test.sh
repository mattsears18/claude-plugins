#!/usr/bin/env bash
# Test suite for scripts/do-work-supervisor.sh (issue #1083).
#
# Exercises the supervisor through its CLI surface rather than by sourcing
# individual functions — the decision the script exists to make ("launch or
# not") is the composition of five guards, so testing the composed verdict is
# what actually pins the behavior.
#
# Every test runs against a throwaway SHIPYARD_HOME and stubs both `gh` and
# `claude`, so no test touches the real ledger, the real session files, or
# spends a single token.
#
# Pure bash + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/do-work-supervisor.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../do-work-supervisor.sh"

if [[ ! -f "$script" ]]; then
  echo "FAIL: do-work-supervisor.sh not found at $script" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack"
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"; pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to contain: %s\n' "$needle"
    fail=$((fail+1))
  fi
}

REPO="acme/widget"
SLUG="acme-widget"

# --------------------------------------------------------------------------
# Harness: a fresh SHIPYARD_HOME + stub gh/claude per test.
# --------------------------------------------------------------------------

setup_env() {
  TMP=$(mktemp -d)
  export SHIPYARD_HOME="$TMP/shipyard"
  mkdir -p "$SHIPYARD_HOME/sessions" "$TMP/bin" "$TMP/workdir"

  # Stub gh: issue/pr counts come from files the test writes.
  cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ -n "${STUB_GH_FAIL:-}" ]]; then exit 1; fi
case "${1:-}" in
  issue) cat "${STUB_ISSUES:-/dev/null}" ;;
  pr)    cat "${STUB_PRS:-/dev/null}" ;;
  *)     echo "[]" ;;
esac
GH
  chmod +x "$TMP/bin/gh"

  # Stub claude: records that it was invoked, then exits.
  cat > "$TMP/bin/claude" <<CLAUDE
#!/usr/bin/env bash
echo "\$@" >> "$TMP/claude-invocations"
exit 0
CLAUDE
  chmod +x "$TMP/bin/claude"

  export SHIPYARD_SUPERVISOR_GH_BIN="$TMP/bin/gh"
  export SHIPYARD_SUPERVISOR_CLAUDE_BIN="$TMP/bin/claude"

  # Default: plenty of work available.
  echo '[{"number":1,"labels":[]},{"number":2,"labels":[]}]' > "$TMP/issues.json"
  echo '[]' > "$TMP/prs.json"
  export STUB_ISSUES="$TMP/issues.json"
  export STUB_PRS="$TMP/prs.json"
  unset STUB_GH_FAIL
}

teardown_env() {
  [[ -n "${TMP:-}" ]] && rm -rf "$TMP"
  unset STUB_GH_FAIL STUB_ISSUES STUB_PRS
}

# Write a session file for $REPO. $1=name $2=age_seconds $3=prs $4=in_flight
# $5=duration_seconds (started_at = mtime - duration)
make_session() {
  local name="$1" age="$2" prs="$3" inflight="$4" duration="${5:-3600}"
  local f="$SHIPYARD_HOME/sessions/${name}.json"
  local now mtime started
  now=$(date -u +%s)
  mtime=$(( now - age ))
  started=$(( mtime - duration ))

  local pr_array in_flight_obj
  pr_array=$(jq -n --argjson n "$prs" '[range(0;$n)] | map(. + 100)')
  in_flight_obj=$(jq -n --argjson n "$inflight" \
    '[range(0;$n)] | map({key: "slot\(.)", value: {kind:"issue"}}) | from_entries')

  jq -n --arg repo "$REPO" \
    --arg started "$(date -u -r "$started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                     || date -u -d "@$started" +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson prs "$pr_array" --argjson inflight "$in_flight_obj" \
    '{repo:$repo, started_at:$started, session_prs:$prs, in_flight:$inflight}' > "$f"

  # Backdate mtime — the liveness heartbeat the supervisor reads.
  #
  # `touch -t` parses its stamp as LOCAL time, so the stamp must be rendered
  # in local time too (no `-u`). Rendering it as UTC pushes every fixture
  # into the future by the local UTC offset, which silently inverts every
  # staleness assertion in this file.
  touch -t "$(date -r "$mtime" +%Y%m%d%H%M.%S 2>/dev/null \
              || date -d "@$mtime" +%Y%m%d%H%M.%S)" "$f"
  printf '%s\n' "$f"
}

tick() {
  bash "$script" tick --repo "$REPO" --workdir "$TMP/workdir" "$@" 2>&1
}

# Count *.json directly under $1 (find, not ls — SC2012).
count_json() {
  find "$1" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

state_json() {
  cat "$SHIPYARD_HOME/supervisor/${SLUG}.state.json" 2>/dev/null || echo '{}'
}

ledger_lines() {
  cat "$SHIPYARD_HOME/supervisor/${SLUG}.ledger.jsonl" 2>/dev/null || true
}

# ==========================================================================
echo "== liveness gate"
# ==========================================================================
setup_env
make_session "live-session" 60 0 1 >/dev/null
out=$(tick)
assert_contains "$out" "session alive" "a session file touched 60s ago reads as alive"
assert_not_contains "$out" "launching" "does not launch while a session is alive"
assert_equals "$([[ -f "$TMP/claude-invocations" ]] && echo yes || echo no)" "no" \
  "claude is never invoked while a session is alive"
teardown_env

# ==========================================================================
echo "== abandoned-session classification (#1084)"
# ==========================================================================
setup_env
# 2h stale, 0 PRs, 2 workers still in flight, ran only 5 min: the exact shape
# of the tombstones that motivated #1083.
make_session "dead-session" 7200 0 2 300 >/dev/null
out=$(tick)
assert_contains "$out" "archived 1 abandoned session file" "stale session file is archived"
assert_equals "$(count_json "$SHIPYARD_HOME/sessions")" "0" \
  "abandoned file leaves the live sessions directory"
assert_equals "$(count_json "$SHIPYARD_HOME/sessions/abandoned")" "1" \
  "abandoned file is archived, not deleted (the tombstone is the evidence)"

entry=$(ledger_lines | jq -c 'select(.event=="session-death")' | head -1)
assert_equals "$(printf '%s' "$entry" | jq -r .classification)" "abandoned" \
  "ledger classifies the death as abandoned"
assert_equals "$(printf '%s' "$entry" | jq -r .in_flight_at_death)" "2" \
  "ledger records in_flight at death (the #1083 smoking gun)"
assert_equals "$(printf '%s' "$entry" | jq -r .productive)" "false" \
  "short session with zero PRs is unproductive"
assert_equals "$(state_json | jq -r .consecutive_unproductive)" "1" \
  "unproductive death advances the breaker streak"
teardown_env

# ==========================================================================
echo "== productive abandoned session does not advance the breaker"
# ==========================================================================
setup_env
make_session "productive" 7200 4 1 7200 >/dev/null
tick >/dev/null
entry=$(ledger_lines | jq -c 'select(.event=="session-death")' | head -1)
assert_equals "$(printf '%s' "$entry" | jq -r .productive)" "true" \
  "a session that opened 4 PRs is productive even though it was abandoned"
assert_equals "$(state_json | jq -r .consecutive_unproductive)" "0" \
  "productive death resets the streak"
teardown_env

# ==========================================================================
echo "== a long session that shipped nothing is still unproductive"
# ==========================================================================
# Regression pin. An earlier rule excused a zero-PR session if it had run
# long enough; real ledger data showed a 6-hour session with session_prs=0
# being classified productive. That is the worst outcome the breaker exists
# to catch — maximum tokens, nothing shipped — so duration must not enter
# the verdict.
setup_env
make_session "long-and-empty" 7200 0 0 21996 >/dev/null
tick >/dev/null
entry=$(ledger_lines | jq -c 'select(.event=="session-death")' | head -1)
assert_equals "$(printf '%s' "$entry" | jq -r .productive)" "false" \
  "a 6-hour session with zero PRs is unproductive regardless of duration"
assert_equals "$(printf '%s' "$entry" | jq -r .duration_s)" "21996" \
  "duration is still recorded for forensics even though it is not the verdict"
assert_equals "$(state_json | jq -r .consecutive_unproductive)" "1" \
  "the long empty session advances the breaker streak"
teardown_env

# ==========================================================================
echo "== circuit breaker"
# ==========================================================================
setup_env
export SHIPYARD_SUPERVISOR_BREAKER_THRESHOLD=2
make_session "bad-1" 7200 0 1 60 >/dev/null
tick >/dev/null
make_session "bad-2" 7200 0 1 60 >/dev/null
out=$(tick)
assert_contains "$out" "CIRCUIT BREAKER TRIPPED" "breaker trips at the threshold"
assert_equals "$(state_json | jq -r .breaker.tripped)" "true" "breaker state persists"

# A tripped breaker must block launches even with work available. The ticks
# above legitimately launched (the breaker had not tripped yet), so clear the
# marker first — what matters is that nothing launches from here on.
rm -f "$TMP/claude-invocations"
out=$(tick)
assert_contains "$out" "breaker tripped" "tripped breaker blocks the next tick"
sleep 1
assert_equals "$([[ -f "$TMP/claude-invocations" ]] && echo yes || echo no)" "no" \
  "no session is launched while the breaker is tripped"

# reset re-arms it.
bash "$script" reset --repo "$REPO" >/dev/null
assert_equals "$(state_json | jq -r .breaker.tripped)" "false" "reset clears the breaker"
assert_equals "$(state_json | jq -r .consecutive_unproductive)" "0" "reset clears the streak"
assert_equals "$(ledger_lines | jq -rc 'select(.event=="breaker-reset")' | wc -l | tr -d ' ')" "1" \
  "reset is recorded in the ledger"
unset SHIPYARD_SUPERVISOR_BREAKER_THRESHOLD
teardown_env

# ==========================================================================
echo "== work-exists gate"
# ==========================================================================
setup_env
echo '[]' > "$TMP/issues.json"
echo '[]' > "$TMP/prs.json"
out=$(tick)
assert_contains "$out" "backlog is drained" "empty backlog short-circuits before launching"
assert_equals "$([[ -f "$TMP/claude-invocations" ]] && echo yes || echo no)" "no" \
  "no tokens spent discovering an empty backlog"

# Gate labels make an issue ineligible...
echo '[{"number":1,"labels":[{"name":"needs-human-review"}]}]' > "$TMP/issues.json"
out=$(tick)
assert_contains "$out" "backlog is drained" "a needs-human-review issue is not workable"

# ...but agent-console is explicitly still agent work.
echo '[{"number":1,"labels":[{"name":"agent-console"}]}]' > "$TMP/issues.json"
out=$(tick)
assert_contains "$out" "launching" "agent-console counts as workable (agent does it, outside the build)"

# An open PR alone is enough work to justify a session (drain).
echo '[]' > "$TMP/issues.json"
echo '[{"number":7}]' > "$TMP/prs.json"
rm -f "$SHIPYARD_HOME/supervisor/${SLUG}.state.json" "$TMP/claude-invocations"
out=$(tick)
assert_contains "$out" "launching" "an open PR needing drain is workable even with no issues"
teardown_env

# ==========================================================================
echo "== GitHub unreachable is not 'no work'"
# ==========================================================================
setup_env
export STUB_GH_FAIL=1
out=$(tick)
assert_contains "$out" "could not reach GitHub" "gh failure is reported distinctly"
assert_not_contains "$out" "backlog is drained" "gh failure must not be read as an empty backlog"
assert_equals "$(state_json | jq -r .consecutive_unproductive)" "0" \
  "an unreachable-GitHub tick does not penalise the breaker"
unset STUB_GH_FAIL
teardown_env

# ==========================================================================
echo "== daily budget ceiling"
# ==========================================================================
setup_env
export SHIPYARD_SUPERVISOR_MAX_SESSIONS_PER_DAY=1
tick >/dev/null                       # launch 1 — consumes the budget
out=$(tick)
assert_contains "$out" "daily budget reached" "second launch is refused once the ceiling is hit"
assert_equals "$(ledger_lines | jq -rc 'select(.event=="launch")' | wc -l | tr -d ' ')" "1" \
  "exactly one launch is recorded"
unset SHIPYARD_SUPERVISOR_MAX_SESSIONS_PER_DAY
teardown_env

# ==========================================================================
echo "== launch"
# ==========================================================================
setup_env
out=$(tick)
assert_contains "$out" "launching" "launches when every gate passes"
sleep 1
assert_equals "$([[ -f "$TMP/claude-invocations" ]] && echo yes || echo no)" "yes" \
  "the claude binary is actually invoked"
invocation=$(cat "$TMP/claude-invocations" 2>/dev/null || true)
assert_contains "$invocation" "/shipyard:do-work --repo $REPO" "invokes /do-work against the repo"
assert_contains "$invocation" "--permission-mode auto" \
  "defaults to Auto mode, not bypassPermissions (do-work-RATIONALE #763)"
assert_equals "$(state_json | jq -r .pending.pid > /dev/null && echo ok)" "ok" \
  "pending launch is recorded so the next tick can classify its outcome"
teardown_env

# ==========================================================================
echo "== dry run"
# ==========================================================================
setup_env
out=$(tick --dry-run)
assert_contains "$out" "DRY RUN" "dry run announces itself"
assert_equals "$([[ -f "$TMP/claude-invocations" ]] && echo yes || echo no)" "no" \
  "dry run launches nothing"
assert_equals "$(ledger_lines | jq -rc 'select(.event=="launch")' | wc -l | tr -d ' ')" "0" \
  "dry run records no launch"
teardown_env

# ==========================================================================
echo "== single-instance lock"
# ==========================================================================
setup_env
lock="$SHIPYARD_HOME/supervisor/${SLUG}.lock"
mkdir -p "$lock"
echo $$ > "$lock/pid"          # held by this very much alive test process
out=$(tick)
assert_contains "$out" "another tick holds the lock" "a live lock holder blocks a concurrent tick"
assert_equals "$([[ -f "$TMP/claude-invocations" ]] && echo yes || echo no)" "no" \
  "no launch happens while the lock is held"

# A stale lock (dead holder) must be taken over, not honoured forever.
echo "999999" > "$lock/pid"
out=$(tick)
assert_not_contains "$out" "another tick holds the lock" "a stale lock is taken over"
teardown_env

# ==========================================================================
echo "== reap subcommand"
# ==========================================================================
setup_env
make_session "old-a" 7200 0 1 60 >/dev/null
make_session "old-b" 7200 1 0 900 >/dev/null
make_session "fresh" 30 0 1 60 >/dev/null
out=$(bash "$script" reap --repo "$REPO" 2>&1)
assert_contains "$out" "archived 2" "reap archives only the stale files"
assert_equals "$(count_json "$SHIPYARD_HOME/sessions")" "1" \
  "the live session file is left alone"
assert_equals "$([[ -f "$TMP/claude-invocations" ]] && echo yes || echo no)" "no" \
  "reap never launches a session"
teardown_env

# ==========================================================================
echo "== GNU stat semantics (Linux) — mtime probe ordering"
# ==========================================================================
# Regression pin for a macOS-only-green bug that CI caught on Linux.
#
# GNU's `stat -f` means --file-system, so `stat -f %m <file>` reads `%m` as a
# FILE ARGUMENT and prints multi-line filesystem info WITH EXIT 0. A
# BSD-probe-first file_mtime therefore never fails over on Linux — it
# succeeds with garbage, which reaches `(( now - mtime ))`, where bash
# resolves the bare word "File" as a variable name and `set -u` aborts the
# entire tick. Every mtime-dependent assertion in this file failed that way.
#
# This stub exposes ONLY GNU semantics, so the suite exercises the Linux
# path even on a BSD host.
setup_env
cat > "$TMP/bin/stat" <<'STAT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == "%Y" ]]; then
  perl -e 'print ((stat($ARGV[0]))[9], "\n")' "$3"
  exit 0
fi
if [[ "${1:-}" == "-f" ]]; then
  # GNU --file-system: every remaining arg is treated as a FILE, and the
  # command still exits 0 — the exact trap.
  shift
  for a in "$@"; do
    echo "  File: \"$a\""
    echo "    ID: 0 Namelen: 255 Type: ext2/ext3"
  done
  exit 0
fi
exit 1
STAT
chmod +x "$TMP/bin/stat"

make_session "gnu-stale" 7200 0 1 60 >/dev/null
make_session "gnu-fresh" 30 0 1 60 >/dev/null
out=$(PATH="$TMP/bin:$PATH" bash "$script" reap --repo "$REPO" 2>&1)
assert_not_contains "$out" "unbound variable" \
  "GNU stat's exit-0 garbage never reaches bash arithmetic"
assert_contains "$out" "archived 1" "stale file is still archived under GNU stat"
assert_equals "$(count_json "$SHIPYARD_HOME/sessions")" "1" \
  "the fresh session survives under GNU stat (mtime read correctly, not zeroed)"
teardown_env

# ==========================================================================
echo "== status subcommand"
# ==========================================================================
setup_env
out=$(bash "$script" status --repo "$REPO" 2>&1)
assert_contains "$out" "never ticked" "status is graceful before the first tick"
tick >/dev/null
out=$(bash "$script" status --repo "$REPO" 2>&1)
assert_contains "$out" "Supervisor — $REPO" "status renders a header"
assert_contains "$out" "breaker:" "status reports breaker state"
teardown_env

# ==========================================================================
echo "== install refuses by default (#1096: OAuth cannot be read under launchd)"
# ==========================================================================
setup_env
fake_home="$TMP/fakehome"
mkdir -p "$fake_home"
out=$(HOME="$fake_home" bash "$script" install --repo "$REPO" \
        --workdir "$TMP/workdir" --interval 900 2>&1); rc=$?
assert_equals "$rc" "64" "install without --use-api-key/--force-oauth-unverified exits 64"
assert_contains "$out" "1096" "refusal cites issue #1096"
assert_contains "$out" "--use-api-key" "refusal names the working path"
plist="$fake_home/Library/LaunchAgents/com.shipyard.do-work-supervisor.${SLUG}.plist"
assert_equals "$([[ -f "$plist" ]] && echo yes || echo no)" "no" \
  "no plist is written when install refuses"
teardown_env

# ==========================================================================
echo "== install --use-api-key requires ANTHROPIC_API_KEY"
# ==========================================================================
setup_env
fake_home="$TMP/fakehome"
mkdir -p "$fake_home"
out=$(HOME="$fake_home" env -u ANTHROPIC_API_KEY bash "$script" install --repo "$REPO" \
        --workdir "$TMP/workdir" --use-api-key 2>&1); rc=$?
assert_equals "$rc" "64" "--use-api-key without ANTHROPIC_API_KEY exits 64"
assert_contains "$out" "ANTHROPIC_API_KEY" "error names the missing env var"
teardown_env

# ==========================================================================
echo "== install --use-api-key writes a correct, locked-down launchd plist"
# ==========================================================================
setup_env
fake_home="$TMP/fakehome"
mkdir -p "$fake_home"
out=$(HOME="$fake_home" ANTHROPIC_API_KEY="NOT-A-REAL-SECRET-TEST-FIXTURE-VALUE-0000" \
        bash "$script" install --repo "$REPO" \
        --workdir "$TMP/workdir" --interval 900 --use-api-key 2>&1)
plist="$fake_home/Library/LaunchAgents/com.shipyard.do-work-supervisor.${SLUG}.plist"
assert_equals "$([[ -f "$plist" ]] && echo yes || echo no)" "yes" "plist is written"
plist_body=$(cat "$plist" 2>/dev/null || true)
assert_contains "$plist_body" "<key>AbandonProcessGroup</key>" \
  "plist sets AbandonProcessGroup (without it launchd reaps the session on tick exit)"
assert_contains "$plist_body" "<key>SessionCreate</key>" \
  "plist sets SessionCreate (harmless, standard launchd Keychain-session remedy)"
assert_contains "$plist_body" "<integer>900</integer>" "plist honours --interval"
assert_contains "$plist_body" "tick" "plist invokes the tick subcommand"
assert_contains "$plist_body" "$REPO" "plist pins the repo"
assert_contains "$plist_body" "NOT-A-REAL-SECRET-TEST-FIXTURE-VALUE-0000" \
  "plist embeds ANTHROPIC_API_KEY — the verified-working unattended auth path"
perm=$(stat -f %Lp "$plist" 2>/dev/null || stat -c %a "$plist" 2>/dev/null || echo "")
assert_equals "$perm" "600" "plist carrying a secret is locked down to the owner"
teardown_env

# ==========================================================================
echo "== install --force-oauth-unverified writes a plist without a key"
# ==========================================================================
setup_env
fake_home="$TMP/fakehome"
mkdir -p "$fake_home"
out=$(HOME="$fake_home" bash "$script" install --repo "$REPO" \
        --workdir "$TMP/workdir" --force-oauth-unverified 2>&1)
plist="$fake_home/Library/LaunchAgents/com.shipyard.do-work-supervisor.${SLUG}.plist"
assert_equals "$([[ -f "$plist" ]] && echo yes || echo no)" "yes" \
  "--force-oauth-unverified writes a plist despite the unverified auth path"
assert_not_contains "$(cat "$plist" 2>/dev/null)" "ANTHROPIC_API_KEY" \
  "plist carries no API key on the forced-OAuth path"
assert_contains "$out" "1096" "forced-OAuth install still warns, citing #1096"
teardown_env

# ==========================================================================
echo "== usage / arg validation"
# ==========================================================================
setup_env
out=$(bash "$script" --help 2>&1)
assert_contains "$out" "do-work-supervisor.sh" "--help prints usage"
out=$(bash "$script" tick 2>&1); rc=$?
assert_contains "$out" "--repo owner/name is required" "tick without --repo errors"
assert_equals "$rc" "64" "usage error exits 64 (EX_USAGE)"
out=$(bash "$script" bogus 2>&1); rc=$?
assert_equals "$rc" "64" "unknown subcommand exits 64"
teardown_env

# ==========================================================================
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1

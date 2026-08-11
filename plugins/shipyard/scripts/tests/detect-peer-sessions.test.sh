#!/usr/bin/env bash
# Test suite for scripts/detect-peer-sessions.sh (issue #1204).
#
# Covers the setup-time peer-session detection this script backs: given
# $SHIPYARD_HOME/sessions/*.json, find LIVE peers on the SAME repo (fresh
# mtime, matching .repo) and report the union of their .in_flight[].target
# claims, so this session's own backlog filter can exclude them. Mirrors
# sweep-orphan-sessions.test.sh's shape (same helpers, same
# throwaway-shipyard-home discipline) but with the mtime gate inverted:
# FRESH files are the ones of interest here, not stale ones.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/detect-peer-sessions.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="${here}/../detect-peer-sessions.sh"

if [[ ! -f "$helper" ]]; then
  echo "FAIL: helper not found at $helper" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

assert_equals() {
  local actual="$1" expected="$2" label="$3"
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

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'
    fail=$((fail+1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected NOT to contain: %s\n' "$needle"
    printf '    actual: %s\n' "$haystack" | head -c 400
    printf '\n'
    fail=$((fail+1))
  fi
}

# Set a file's mtime to <minutes> ago, portable across BSD (macOS, local
# dev) and GNU (ubuntu-latest CI) `touch`/`date` dialects — same pattern
# sweep-orphan-sessions.test.sh's backdate() uses.
backdate() {
  local path="$1" mins="$2" ts
  ts=$(date -v-"${mins}M" +%Y%m%d%H%M 2>/dev/null) || \
    ts=$(date -d "${mins} minutes ago" +%Y%m%d%H%M 2>/dev/null)
  touch -t "$ts" "$path"
}

mktmphome() { mktemp -d; }

write_session() {
  local path="$1" repo="$2" in_flight_json="$3"
  mkdir -p "$(dirname "$path")"
  jq -n --arg repo "$repo" --argjson in_flight "$in_flight_json" \
    '{repo: $repo, in_flight: $in_flight}' > "$path"
}

echo "detect-peer-sessions.sh tests (issue #1204)"
echo

# --- bad usage -------------------------------------------------------------

out=$(bash "$helper" check 2>&1); rc=$?
assert_equals "$rc" "64" "(1) missing --shipyard-home exits 64"
assert_contains "$out" "shipyard-home is required" "(1) missing --shipyard-home explains why"

tmphome=$(mktmphome)
out=$(bash "$helper" check --shipyard-home "$tmphome" 2>&1); rc=$?
assert_equals "$rc" "64" "(2) missing --repo exits 64"
rm -rf "$tmphome"

tmphome=$(mktmphome)
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" 2>&1); rc=$?
assert_equals "$rc" "64" "(3) missing --current-session-id exits 64"
rm -rf "$tmphome"

tmphome=$(mktmphome)
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "s1" --fresh-min notanumber 2>&1); rc=$?
assert_equals "$rc" "64" "(4) non-numeric --fresh-min exits 64"
rm -rf "$tmphome"

out=$(bash "$helper" bogus-subcommand 2>&1); rc=$?
assert_equals "$rc" "64" "(5) unknown subcommand exits 64"

out=$(bash "$helper" 2>&1); rc=$?
assert_equals "$rc" "64" "(6) no subcommand exits 64"

out=$(bash "$helper" --help 2>&1); rc=$?
assert_equals "$rc" "0" "(7) --help exits 0"

# --- empty layout ------------------------------------------------------------

tmphome=$(mktmphome)
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "s1" 2>&1); rc=$?
assert_equals "$rc" "0" "(8) empty \$SHIPYARD_HOME check exits 0"
assert_contains "$out" "summary: peers=0 claimed_targets=(none)" "(8) empty layout reports zero peers"
rm -rf "$tmphome"

# --- the acceptance case: fresh, same-repo peer with in_flight claims ------

tmphome=$(mktmphome)
peer_json="$tmphome/sessions/peer-live.json"
write_session "$peer_json" "acme/widgets" '{"slot1": {"kind": "issue", "target": 1201}}'
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" 2>&1); rc=$?
assert_equals "$rc" "0" "(9) fresh same-repo peer check exits 0"
assert_contains "$out" "peer: peer-live claimed=1201" "(9) peer line names the session id and its claimed target"
assert_contains "$out" "summary: peers=1 claimed_targets=1201" "(9) summary reports the peer and its claimed target"
rm -rf "$tmphome"

# --- string target with a leading '#' normalizes to a bare number ---------

tmphome=$(mktmphome)
hash_json="$tmphome/sessions/peer-hash.json"
write_session "$hash_json" "acme/widgets" '{"slot1": {"kind": "issue", "target": "#1201"}}'
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" 2>&1); rc=$?
assert_contains "$out" "peer: peer-hash claimed=1201" "(10) a \"#1201\"-shaped target string normalizes to bare 1201"
assert_contains "$out" "summary: peers=1 claimed_targets=1201" "(10) normalized target lands in the summary set"
rm -rf "$tmphome"

# --- NOT counted: peer on a DIFFERENT repo ----------------------------------

tmphome=$(mktmphome)
other_json="$tmphome/sessions/peer-other-repo.json"
write_session "$other_json" "acme/other" '{"slot1": {"kind": "issue", "target": 5}}'
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" 2>&1); rc=$?
assert_contains "$out" "summary: peers=0 claimed_targets=(none)" "(11) a same-host peer on a different repo is not counted"
rm -rf "$tmphome"

# --- NOT counted: this session's own file -----------------------------------

tmphome=$(mktmphome)
self_json="$tmphome/sessions/self.json"
write_session "$self_json" "acme/widgets" '{"slot1": {"kind": "issue", "target": 5}}'
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" 2>&1); rc=$?
assert_contains "$out" "summary: peers=0 claimed_targets=(none)" "(12) the current session's own file is excluded from peer detection"
rm -rf "$tmphome"

# --- the design-constraint case: a stale (dead-mid-flight) peer ages out ----

tmphome=$(mktmphome)
stale_json="$tmphome/sessions/peer-dead.json"
write_session "$stale_json" "acme/widgets" '{"slot1": {"kind": "issue", "target": 777}}'
backdate "$stale_json" 45
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" 2>&1); rc=$?
assert_contains "$out" "summary: peers=0 claimed_targets=(none)" "(13) a stale (>30min) peer file — e.g. died mid-flight — ages out and never permanently starves the backlog"
rm -rf "$tmphome"

# --- --fresh-min override lets the window be widened or narrowed -----------

tmphome=$(mktmphome)
override_json="$tmphome/sessions/peer-override.json"
write_session "$override_json" "acme/widgets" '{"slot1": {"kind": "issue", "target": 9}}'
backdate "$override_json" 45
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" --fresh-min 60 2>&1); rc=$?
assert_contains "$out" "summary: peers=1 claimed_targets=9" "(14) --fresh-min widens the window past the 30-min default"
rm -rf "$tmphome"

tmphome=$(mktmphome)
narrow_json="$tmphome/sessions/peer-narrow.json"
write_session "$narrow_json" "acme/widgets" '{"slot1": {"kind": "issue", "target": 9}}'
backdate "$narrow_json" 10
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" --fresh-min 5 2>&1); rc=$?
assert_contains "$out" "summary: peers=0 claimed_targets=(none)" "(15) --fresh-min narrows the window below the peer's actual age, excluding it"
rm -rf "$tmphome"

# --- multiple in-flight slots on one peer contribute multiple targets ------

tmphome=$(mktmphome)
multi_json="$tmphome/sessions/peer-multi.json"
write_session "$multi_json" "acme/widgets" '{"slot1": {"target": 10}, "slot2": {"target": 20}}'
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" 2>&1); rc=$?
assert_contains "$out" "summary: peers=1 claimed_targets=10,20" "(16) both of a peer's in-flight slots contribute their targets, sorted"
rm -rf "$tmphome"

# --- a peer with an empty in_flight still counts as a live peer, claiming nothing --

tmphome=$(mktmphome)
empty_json="$tmphome/sessions/peer-empty.json"
write_session "$empty_json" "acme/widgets" '{}'
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" 2>&1); rc=$?
assert_contains "$out" "peer: peer-empty claimed=(none)" "(17) a live peer with no in-flight work is still reported, claiming nothing"
assert_contains "$out" "summary: peers=1 claimed_targets=(none)" "(17) summary counts the peer without adding to claimed_targets"
rm -rf "$tmphome"

# --- multiple peers claiming overlapping targets dedupe in the summary -----

tmphome=$(mktmphome)
dup_a="$tmphome/sessions/peer-dup-a.json"
dup_b="$tmphome/sessions/peer-dup-b.json"
write_session "$dup_a" "acme/widgets" '{"slot1": {"target": 50}}'
write_session "$dup_b" "acme/widgets" '{"slot1": {"target": 50}}'
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" 2>&1); rc=$?
assert_contains "$out" "summary: peers=2 claimed_targets=50" "(18) two peers both claiming #50 dedupe to a single entry in claimed_targets"
assert_not_contains "$out" "claimed_targets=50,50" "(18) the dedup actually removed the duplicate"
rm -rf "$tmphome"

# --- malformed JSON is skipped, not fatal -----------------------------------

tmphome=$(mktmphome)
bad_json="$tmphome/sessions/broken.json"
mkdir -p "$(dirname "$bad_json")"
printf 'not valid json{{{' > "$bad_json"
out=$(bash "$helper" check --shipyard-home "$tmphome" --repo "acme/widgets" --current-session-id "self" 2>&1); rc=$?
assert_equals "$rc" "0" "(19) malformed session JSON does not abort the check"
assert_contains "$out" "summary: peers=0 claimed_targets=(none)" "(19) malformed file contributes no peer"
rm -rf "$tmphome"

echo
echo "----------------------------------------"
echo "pass=$pass fail=$fail"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0

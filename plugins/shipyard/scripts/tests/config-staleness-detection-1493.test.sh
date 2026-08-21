#!/usr/bin/env bash
# Test: a shipyard.config.json change that merges MID-SESSION reads stale
# for the rest of the run, and nothing surfaces it (issue #1493).
#
# Background
# ----------
# `SHIPYARD_REPO_ROOT` is pinned to the PRIMARY checkout by setup step 0.56
# (#1059) so config reads still see the gitignored
# `.shipyard/config.local.json` layer. The pin is correct and load-bearing
# — but the primary checkout is read-only for the session and nothing
# refreshes it, so the COMMITTED `shipyard.config.json` layer freezes at
# session start.
#
# The #1493 repro (session do-work-20260820T024447Z-51928 against
# mattsears18/lightwork): PR #4372 set `backlog.someday_milestone` and
# merged mid-session. The orchestrator re-ran its own canonical
# `classify-backlog.sh run` to confirm the acceptance criterion and got
# `2691 eligible:` — exactly what a BROKEN fix would produce. The classifier
# was reading a pre-merge config. The session very nearly recorded "the
# Someday drop still doesn't fire after #4372" on the issue: a wrong claim,
# sourced from a real command with real output, about a change that was
# actually correct.
#
# The fix (suggestion 1 + suggestion 3 from the issue — detect-and-say-so,
# plus stating the constraint at the pin): a `detect-config-staleness.sh`
# drift detector, a step-D sub-step that runs it every refresh tick and
# warns on a transition, and the constraint written down in
# `00k-repo-root-pin.md` alongside the pin that causes it.
#
# Two halves, mirroring skill-cache-staleness-detection.test.sh (#1319):
#   1. Static assertions that the spec files actually wire it together.
#   2. FUNCTIONAL scenarios exercising the REAL script against git
#      fixtures — including the exact lightwork repro key — so the shipped
#      logic is verified to behave, not merely to exist.

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

detector_script="$repo_root/plugins/shipyard/scripts/detect-config-staleness.sh"
steady_file="$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
# The pin-file assertions below scan across every setup/*.md fragment rather
# than hardcoding 00k-repo-root-pin.md, since a future router/fragment split
# could relocate step 0.56's content without warning (issue #1453; same
# pattern as skill-cache-staleness-detection.test.sh and
# shipyard-repo-root-preamble.test.sh check (4)).
setup_dir="$repo_root/plugins/shipyard/commands/do-work/setup"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

check() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "0" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$desc"
    pass=$((pass + 1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$desc"
    fail=$((fail + 1))
  fi
}

assert_streq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    check "$desc" 0
  else
    check "$desc (expected '$expected', got '$actual')" 1
  fi
}

echo "mid-session config-staleness detection regression tests (issue #1493)"
echo

# --- Static assertions -------------------------------------------------

detector_executable=1
[ -x "$detector_script" ] && detector_executable=0
check "detect-config-staleness.sh exists and is executable" "$detector_executable"

grep -q '#1493' "$detector_script"
check "detect-config-staleness.sh cites issue #1493" "$?"

grep -q 'resolved config staleness:' "$detector_script"
check "detect-config-staleness.sh echoes the resolved root/path/ref unconditionally (mirrors #681)" "$?"

grep -q 'SHIPYARD_REPO_ROOT' "$detector_script"
check "detect-config-staleness.sh honours the step-0.56 SHIPYARD_REPO_ROOT pin" "$?"

grep -q '.shipyard-primary-root' "$detector_script"
check "detect-config-staleness.sh falls back to the .shipyard-primary-root stash" "$?"

grep -q 'is NOT a staleness source' "$detector_script"
check "detect-config-staleness.sh documents why the gitignored local layer is not compared" "$?"

grep -q 'detect-config-staleness.sh' "$steady_file"
check "steady-state.md's step D calls detect-config-staleness.sh" "$?"

grep -q '\[config-stale\]' "$steady_file"
check "steady-state.md defines the one-line [config-stale] warning" "$?"

grep -q 'SHIPYARD_CONFIG_STALE_KEYS' "$steady_file"
check "steady-state.md caches the changed-key list so the warning fires only on a transition" "$?"

grep -q 'false negative' "$steady_file"
check "steady-state.md's warning names the false-negative hazard, not just the staleness" "$?"

grep -q 'six sub-steps' "$steady_file"
check "steady-state.md's step D preamble counts the new sub-step" "$?"

grep -q '#1493' "$steady_file"
check "steady-state.md cites issue #1493" "$?"

grep -ql 'merges mid-session reads stale' "$setup_dir"/*.md 2>/dev/null
check "the repo-root-pin setup fragment states the mid-session config-staleness constraint (#1493)" "$?"

grep -ql '#1493' "$setup_dir"/*.md 2>/dev/null
check "the repo-root-pin setup fragment cites issue #1493" "$?"

grep -ql 'detect-config-staleness.sh' "$setup_dir"/*.md 2>/dev/null
check "the setup fragment points at the detector rather than only describing the constraint" "$?"

grep -ql 'never conclude' "$setup_dir"/*.md 2>/dev/null
check "the setup fragment states the don't-conclude-from-a-live-read rule" "$?"

grep -qle 'unpinning' -e 'Unpinning' "$setup_dir"/*.md 2>/dev/null
check "the setup fragment forbids 'fixing' this by unpinning SHIPYARD_REPO_ROOT (#1059 regression)" "$?"

# --- Functional: exercise the REAL script end-to-end -------------------
#
# A source repo cloned once, so the clone has a real `origin` to
# `git show` against. The clone stands in for the session's pinned
# primary checkout; the source stands in for the default branch that
# moved underneath it.

tmp_src="$(mktemp -d)"
tmp_clone="$(mktemp -d)"
rmdir "$tmp_clone"
trap 'rm -rf "$tmp_src" "$tmp_clone"' EXIT

MERGED='{"backlog":{"someday_milestone":"Someday"},"auto_merge":{"method":"squash"}}'
PRE_MERGE='{"auto_merge":{"method":"squash"}}'

printf '%s\n' "$MERGED" > "$tmp_src/shipyard.config.json"
git -C "$tmp_src" init -q
git -C "$tmp_src" checkout -q -b main
git -C "$tmp_src" -c user.email=t@t -c user.name=t add -A
git -C "$tmp_src" -c user.email=t@t -c user.name=t commit -q -m init
git clone -q "$tmp_src" "$tmp_clone"

# Scenario 1: the actual lightwork repro — the merged PR added
# backlog.someday_milestone, the session's frozen checkout doesn't have it.
printf '%s\n' "$PRE_MERGE" > "$tmp_clone/shipyard.config.json"
result=$(bash "$detector_script" main "$tmp_clone" 2>/dev/null)
assert_streq "reports stale and names backlog.someday_milestone (the #1493 repro key)" \
  "stale:backlog.someday_milestone" "$result"

# Scenario 1b: the verdict is advisory — exit status is 0 even when stale,
# so a caller can never misread an environment error as drift.
bash "$detector_script" main "$tmp_clone" >/dev/null 2>&1
check "exit status is 0 on a stale verdict (advisory, not a gate)" "$?"

# Scenario 2: no drift.
printf '%s\n' "$MERGED" > "$tmp_clone/shipyard.config.json"
result=$(bash "$detector_script" main "$tmp_clone" 2>/dev/null)
assert_streq "reports fresh when the pinned checkout matches origin/main" "fresh" "$result"

# Scenario 3: whitespace / key-order churn only — semantically identical,
# must NOT be reported as drift (the check compares effective values, not
# raw text).
printf '%s\n' '{ "auto_merge" : { "method" : "squash" } ,
  "backlog" : { "someday_milestone" : "Someday" } }' > "$tmp_clone/shipyard.config.json"
result=$(bash "$detector_script" main "$tmp_clone" 2>/dev/null)
assert_streq "formatting/key-order-only difference reports fresh, not stale" "fresh" "$result"

# Scenario 4: a value CHANGED rather than added — the dangerous class the
# issue calls out (auto_merge.policy, trust.authors, models.*).
printf '%s\n' '{"backlog":{"someday_milestone":"Someday"},"auto_merge":{"method":"merge"}}' \
  > "$tmp_clone/shipyard.config.json"
result=$(bash "$detector_script" main "$tmp_clone" 2>/dev/null)
assert_streq "a changed (not merely added) value is reported with its dotted key path" \
  "stale:auto_merge.method" "$result"

# Scenario 5: no default-branch argument (e.g. gh repo view failed
# upstream) — degrades to fresh rather than a one-sided false positive.
printf '%s\n' "$PRE_MERGE" > "$tmp_clone/shipyard.config.json"
result=$(bash "$detector_script" "" "$tmp_clone" 2>/dev/null)
assert_streq "empty default-branch argument never produces a false-positive stale verdict" \
  "fresh" "$result"

# Scenario 6: the live file is mid-edit / conflicted and not valid JSON —
# INDETERMINATE must degrade to fresh, never to a fabricated drift report.
printf 'not json at all\n' > "$tmp_clone/shipyard.config.json"
result=$(bash "$detector_script" main "$tmp_clone" 2>/dev/null)
assert_streq "invalid-JSON live config degrades to fresh, not a crash or a false stale" \
  "fresh" "$result"

# Scenario 7: the config file was ADDED on the default branch mid-session
# and the frozen checkout has none at all — real drift, not a missing side
# to shrug off.
rm -f "$tmp_clone/shipyard.config.json"
result=$(bash "$detector_script" main "$tmp_clone" 2>/dev/null)
assert_streq "a config file added on the default branch is reported as stale" \
  "stale:auto_merge.method, backlog.someday_milestone" "$result"

# Scenario 8: no committed config layer on the default branch at all — a
# repo that has not opted in. Nothing to be stale against.
tmp_bare_src="$(mktemp -d)"
tmp_bare_clone="$(mktemp -d)"
rmdir "$tmp_bare_clone"
printf 'placeholder\n' > "$tmp_bare_src/README.md"
git -C "$tmp_bare_src" init -q
git -C "$tmp_bare_src" checkout -q -b main
git -C "$tmp_bare_src" -c user.email=t@t -c user.name=t add -A
git -C "$tmp_bare_src" -c user.email=t@t -c user.name=t commit -q -m init
git clone -q "$tmp_bare_src" "$tmp_bare_clone"
printf '%s\n' "$PRE_MERGE" > "$tmp_bare_clone/shipyard.config.json"
result=$(bash "$detector_script" main "$tmp_bare_clone" 2>/dev/null)
assert_streq "no committed config on the default branch reports fresh" "fresh" "$result"
rm -rf "$tmp_bare_src" "$tmp_bare_clone"

# Scenario 9: repo root resolved from $SHIPYARD_REPO_ROOT rather than argv,
# which is how the pin actually reaches an un-swept call site.
printf '%s\n' "$PRE_MERGE" > "$tmp_clone/shipyard.config.json"
result=$(SHIPYARD_REPO_ROOT="$tmp_clone" bash "$detector_script" main 2>/dev/null)
assert_streq "resolves the repo root from \$SHIPYARD_REPO_ROOT when argv omits it" \
  "stale:backlog.someday_milestone" "$result"

# Scenario 10: repo root resolved from the .shipyard-primary-root stash in
# cwd — the step-0.56 shape, where the orchestrator worktree's cwd carries
# the stash pointing at the primary checkout.
tmp_orch="$(mktemp -d)"
printf '%s\n' "$tmp_clone" > "$tmp_orch/.shipyard-primary-root"
result=$(cd "$tmp_orch" && bash "$detector_script" main 2>/dev/null)
assert_streq "resolves the repo root from the .shipyard-primary-root stash in cwd" \
  "stale:backlog.someday_milestone" "$result"
rm -rf "$tmp_orch"

# Scenario 11: the resolved root/path/ref is echoed to stderr
# unconditionally, even on a fresh run (#681 "echo once" discipline) — so a
# transcript answers "what did this session actually compare?".
printf '%s\n' "$MERGED" > "$tmp_clone/shipyard.config.json"
stderr_out=$(bash "$detector_script" main "$tmp_clone" 2>&1 >/dev/null)
case "$stderr_out" in
  *"resolved config staleness:"*"ref=origin/main"*) check "stderr echoes the resolved comparison unconditionally" 0 ;;
  *) check "stderr echoes the resolved comparison unconditionally (got: $stderr_out)" 1 ;;
esac

# Scenario 12: a large rewrite is summarized rather than dumped, so the
# caller's one-line warning stays one line.
python3 - "$tmp_src/shipyard.config.json" <<'PY'
import json, sys
json.dump({("k%02d" % i): i for i in range(20)}, open(sys.argv[1], "w"))
PY
git -C "$tmp_src" -c user.email=t@t -c user.name=t commit -q -am bulk
git -C "$tmp_clone" fetch -q origin
result=$(bash "$detector_script" main "$tmp_clone" 2>/dev/null)
case "$result" in
  stale:*"more)") check "a large key delta is capped and summarized with a (+N more) suffix" 0 ;;
  *) check "a large key delta is capped and summarized with a (+N more) suffix (got: $result)" 1 ;;
esac
case "$result" in
  *$'\n'*) check "the capped verdict is still a single line" 1 ;;
  *) check "the capped verdict is still a single line" 0 ;;
esac

echo
if [[ "$fail" -gt 0 ]]; then
  printf '%sFAIL%s  %d passed, %d failed\n' "$RED" "$RESET" "$pass" "$fail" >&2
  exit 1
else
  printf '%sPASS%s  %d passed, %d failed\n' "$GREEN" "$RESET" "$pass" "$fail"
  exit 0
fi

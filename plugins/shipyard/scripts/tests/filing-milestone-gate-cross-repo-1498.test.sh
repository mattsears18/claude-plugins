#!/usr/bin/env bash
# Test: cross-repo issue filing must resolve the milestone gate from the
# TARGET repo, not from the repo the session happens to be running in
# (issue #1498).
#
# Background
# ----------
# `shipyard:filing-github-issues` § "Milestone assignment" read the gate as
#
#     shipyard-config.sh get milestones.enabled
#
# and `shipyard-config.sh` resolves its repo layer from the cwd's git toplevel.
# Correct for a same-repo filing; silently wrong for a cross-repo one.
#
# The repro (session do-work-20260821T204914Z-74826): seven issues
# (#1490–#1496) were filed against `mattsears18/shipyard` — which sets
# `milestones.enabled: true` and `milestones.assign_on_file: true` — from a
# session working in `mattsears18/lightwork`, whose committed config carries no
# `milestones` block. The gate resolved to the built-in `false` and assignment
# was skipped without a word. Because `milestones.prioritize_dispatch` ranks on
# the milestone, three fresh P1s then sorted BEHIND an older P2 in
# `backlog-filter.sh classify`'s `_sort_key`.
#
# This is distinct from #1421 (closed 2026-08-17, three days before those
# issues were filed), which covered a parent-with-no-milestone filing bare.
#
# Two halves, mirroring config-staleness-detection-1493.test.sh:
#   1. Static assertions that the spec files actually wire the resolver in.
#   2. FUNCTIONAL scenarios exercising the REAL script against a stubbed `gh`,
#      including the exact lightwork→shipyard repro.

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

resolver="$repo_root/plugins/shipyard/scripts/resolve-filing-milestone-gate.sh"
config_script="$repo_root/plugins/shipyard/scripts/shipyard-config.sh"
skill_file="$repo_root/plugins/shipyard/skills/filing-github-issues/SKILL.md"
file_issue_file="$repo_root/plugins/shipyard/commands/file-issue.md"
drain_file="$repo_root/plugins/shipyard/commands/do-work/drain.md"
prohibition_file="$repo_root/plugins/shipyard/skills/worker-preamble/milestone-prohibition.md"

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

echo "cross-repo filing milestone-gate regression tests (issue #1498)"
echo

# --- Static assertions -------------------------------------------------

resolver_executable=1
[ -x "$resolver" ] && resolver_executable=0
check "resolve-filing-milestone-gate.sh exists and is executable" "$resolver_executable"

grep -q '#1498' "$resolver"
check "resolve-filing-milestone-gate.sh cites issue #1498" "$?"

grep -q 'resolve-filing-milestone-gate: target=' "$resolver"
check "resolve-filing-milestone-gate.sh echoes the resolved target/session unconditionally (mirrors #681)" "$?"

grep -q 'resolve-filing-milestone-gate.sh' "$skill_file"
check "filing-github-issues SKILL.md calls the resolver" "$?"

# The whole bug was reading the gate through the cwd-scoped config helper. If
# either filing surface still does that, the fix is not actually wired in.
if grep -q 'shipyard-config.sh" get milestones' "$skill_file"; then
  check "filing-github-issues SKILL.md no longer reads milestones.* via the cwd-scoped shipyard-config.sh" 1
else
  check "filing-github-issues SKILL.md no longer reads milestones.* via the cwd-scoped shipyard-config.sh" 0
fi

grep -q 'resolve-filing-milestone-gate.sh' "$file_issue_file"
check "file-issue.md calls the resolver" "$?"

if grep -q 'shipyard-config.sh" get milestones' "$file_issue_file"; then
  check "file-issue.md no longer reads milestones.* via the cwd-scoped shipyard-config.sh" 1
else
  check "file-issue.md no longer reads milestones.* via the cwd-scoped shipyard-config.sh" 0
fi

grep -q 'resolve-filing-milestone-gate.sh' "$drain_file"
check "drain.md's end-of-session friction filing points at the resolver (the path #1498 broke on)" "$?"

grep -q '1498' "$prohibition_file"
check "milestone-prohibition.md's tier-1 inheritance carries the same-repo guard" "$?"

grep -q 'Only the gate was misresolved' "$skill_file"
check "SKILL.md records that only the gate was misresolved, not the milestone list" "$?"

grep -q 'MILESTONES_SOURCE' "$skill_file"
check "SKILL.md wires the visibility half — a skipped cross-repo gate is reported, not silent" "$?"

# --- Functional scenarios ----------------------------------------------

echo
echo "  functional scenarios (real script, stubbed gh)"

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

stub_bin="$tmp_root/bin"
mkdir -p "$stub_bin"

# A `gh` stub driven entirely by env vars, so each scenario declares the world
# it wants rather than sharing mutable fixture state.
#
#   GH_STUB_SESSION_REPO   what `gh repo view` reports (empty => the call fails)
#   GH_STUB_TARGET_REPO    the repo the contents/metadata calls know about
#   GH_STUB_CONFIG         the target repo's shipyard.config.json body
#                          ("__ABSENT__" => contents 404s but the repo exists;
#                           "__NOREPO__"  => the repo itself 404s)
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
args="$*"
case "$args" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    if [ -z "${GH_STUB_SESSION_REPO:-}" ]; then
      echo '{"message":"Not Found"}'
      exit 1
    fi
    printf '%s\n' "$GH_STUB_SESSION_REPO"
    exit 0
    ;;
esac
case "$args" in
  "api repos/${GH_STUB_TARGET_REPO:-__unset__}/contents/shipyard.config.json --jq .content")
    case "${GH_STUB_CONFIG:-__ABSENT__}" in
      __ABSENT__|__NOREPO__)
        # gh prints the API error body on STDOUT and bypasses --jq. Reproducing
        # that here is the point: a naive `|| true` capture swallows it as data.
        echo '{"message":"Not Found","status":"404"}'
        exit 1
        ;;
      *)
        printf '%s' "$GH_STUB_CONFIG" | base64 | tr -d '\n'
        echo
        exit 0
        ;;
    esac
    ;;
  "api repos/${GH_STUB_TARGET_REPO:-__unset__} --jq .full_name")
    if [ "${GH_STUB_CONFIG:-__ABSENT__}" = "__NOREPO__" ]; then
      echo '{"message":"Not Found","status":"404"}'
      exit 1
    fi
    printf '%s\n' "$GH_STUB_TARGET_REPO"
    exit 0
    ;;
esac
echo '{"message":"Not Found","status":"404"}'
exit 1
STUB
chmod +x "$stub_bin/gh"

field() {
  # field <output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

run_resolver() {
  PATH="$stub_bin:$PATH" bash "$resolver" "$@" 2>/dev/null
}

# (1) THE #1498 REPRO — filing against shipyard from a lightwork session.
export GH_STUB_SESSION_REPO="mattsears18/lightwork"
export GH_STUB_TARGET_REPO="mattsears18/shipyard"
export GH_STUB_CONFIG='{"version":1,"milestones":{"enabled":true,"assign_on_file":true,"fallback":"Ongoing maintenance"}}'
out=$(run_resolver "mattsears18/shipyard")
assert_streq "repro: cross-repo filing reads the TARGET repo's enabled=true" "true" "$(field "$out" enabled)"
assert_streq "repro: cross-repo filing reads the TARGET repo's assign_on_file=true" "true" "$(field "$out" assign_on_file)"
assert_streq "repro: source names the target-repo read" "target-repo-config" "$(field "$out" source)"
assert_streq "repro: the target repo's fallback title comes through" "Ongoing maintenance" "$(field "$out" fallback)"

# The pre-fix behaviour, asserted directly: the session repo's own config says
# nothing about milestones, so a cwd-scoped read would have said `false`.
sess_root="$tmp_root/session-repo"
mkdir -p "$sess_root"
cat > "$sess_root/shipyard.config.json" <<'JSON'
{"version":1,"repo":{"owner":"mattsears18","name":"lightwork"}}
JSON
fake_home="$tmp_root/home"
mkdir -p "$fake_home"
legacy=$(HOME="$fake_home" SHIPYARD_REPO_ROOT="$sess_root" bash "$config_script" get milestones.enabled 2>/dev/null)
assert_streq "pre-fix control: a cwd-scoped read of the session repo returns false" "false" "$legacy"

# (2) Target repo with no milestones block at all => built-in defaults.
export GH_STUB_CONFIG='{"version":1,"repo":{"owner":"x","name":"y"}}'
out=$(run_resolver "mattsears18/shipyard")
assert_streq "target repo without a milestones block resolves enabled=false" "false" "$(field "$out" enabled)"
assert_streq "target repo without a milestones block keeps the assign_on_file default" "true" "$(field "$out" assign_on_file)"
assert_streq "target repo without a milestones block still reports a real read" "target-repo-config" "$(field "$out" source)"

# (3) An EXPLICIT `false` must survive. jq's `//` treats false as absent, so a
#     naive `.milestones.assign_on_file // "true"` would flip this back to true.
export GH_STUB_CONFIG='{"milestones":{"enabled":true,"assign_on_file":false}}'
out=$(run_resolver "mattsears18/shipyard")
assert_streq "an explicit assign_on_file:false is not clobbered by the default" "false" "$(field "$out" assign_on_file)"
assert_streq "an explicit enabled:true alongside it still reads true" "true" "$(field "$out" enabled)"

export GH_STUB_CONFIG='{"milestones":{"enabled":false,"assign_on_file":true}}'
out=$(run_resolver "mattsears18/shipyard")
assert_streq "an explicit enabled:false is not clobbered by the default" "false" "$(field "$out" enabled)"

# (4) A custom fallback title propagates.
export GH_STUB_CONFIG='{"milestones":{"enabled":true,"fallback":"Someday"}}'
out=$(run_resolver "mattsears18/shipyard")
assert_streq "a custom fallback milestone title propagates" "Someday" "$(field "$out" fallback)"

# (5) Target repo exists but has no committed config.
export GH_STUB_CONFIG='__ABSENT__'
out=$(run_resolver "mattsears18/shipyard")
assert_streq "a target repo with no committed config reports absent" "target-repo-config-absent" "$(field "$out" source)"
assert_streq "a target repo with no committed config gates off" "false" "$(field "$out" enabled)"

# (6) Target repo itself unreachable. `gh api` writes its 404 body to STDOUT,
#     so this also guards the "error JSON captured as config" regression.
export GH_STUB_CONFIG='__NOREPO__'
export GH_STUB_TARGET_REPO="mattsears18/nope"
out=$(run_resolver "mattsears18/nope")
assert_streq "an unreachable target repo reports unreadable, not invalid" "target-repo-config-unreadable" "$(field "$out" source)"
assert_streq "an unreachable target repo gates off" "false" "$(field "$out" enabled)"

# (7) Malformed config on the target repo.
export GH_STUB_TARGET_REPO="mattsears18/shipyard"
export GH_STUB_CONFIG='{ this is not json'
out=$(run_resolver "mattsears18/shipyard")
assert_streq "a malformed target config reports invalid" "target-repo-config-invalid" "$(field "$out" source)"
assert_streq "a malformed target config gates off" "false" "$(field "$out" enabled)"

# (8) Same-repo: the session's own effective config, untouched.
export GH_STUB_SESSION_REPO="mattsears18/shipyard"
export GH_STUB_CONFIG='{"milestones":{"enabled":true}}'
same_root="$tmp_root/same-repo"
mkdir -p "$same_root"
cat > "$same_root/shipyard.config.json" <<'JSON'
{"version":1,"milestones":{"enabled":true,"assign_on_file":true,"fallback":"Ongoing maintenance"}}
JSON
out=$(PATH="$stub_bin:$PATH" HOME="$fake_home" SHIPYARD_REPO_ROOT="$same_root" \
      bash "$resolver" "mattsears18/shipyard" 2>/dev/null)
assert_streq "a same-repo filing uses the session's own config" "session-config" "$(field "$out" source)"
assert_streq "a same-repo filing reports the session config's enabled value" "true" "$(field "$out" enabled)"

# (9) Repo comparison is case-insensitive — GitHub slugs are.
out=$(PATH="$stub_bin:$PATH" HOME="$fake_home" SHIPYARD_REPO_ROOT="$same_root" \
      bash "$resolver" "MattSears18/Shipyard" 2>/dev/null)
assert_streq "the target/session comparison is case-insensitive" "session-config" "$(field "$out" source)"

# (10) An explicit session-repo argument beats the `gh repo view` probe.
export GH_STUB_SESSION_REPO="mattsears18/lightwork"
export GH_STUB_CONFIG='{"milestones":{"enabled":true}}'
out=$(PATH="$stub_bin:$PATH" HOME="$fake_home" SHIPYARD_REPO_ROOT="$same_root" \
      bash "$resolver" "mattsears18/shipyard" "mattsears18/shipyard" 2>/dev/null)
assert_streq "an explicit session-repo argument overrides the gh probe" "session-config" "$(field "$out" source)"

# (11) Output contract: exactly four lines, fixed keys, fixed order.
export GH_STUB_CONFIG='{"milestones":{"enabled":true}}'
out=$(run_resolver "mattsears18/shipyard")
line_count=$(printf '%s\n' "$out" | grep -c .)
assert_streq "the resolver emits exactly four lines" "4" "$line_count"
keys=$(printf '%s\n' "$out" | sed 's/=.*//' | tr '\n' ',')
assert_streq "the four keys appear in the documented order" "enabled,assign_on_file,fallback,source," "$keys"

# (12) Never fail a filing: exit 0 on every path, including a missing argument.
PATH="$stub_bin:$PATH" bash "$resolver" "mattsears18/nope" >/dev/null 2>&1
check "the resolver exits 0 even when the target repo is unreachable" "$?"

PATH="$stub_bin:$PATH" bash "$resolver" >/dev/null 2>&1
check "the resolver exits 0 even with no target repo argument" "$?"

out=$(PATH="$stub_bin:$PATH" bash "$resolver" 2>/dev/null)
assert_streq "a missing target repo argument still emits a gated-off verdict" "false" "$(field "$out" enabled)"

# (13) Defaults parity with shipyard-config.sh's own DEFAULTS_JSON. If a future
#      edit changes one and not the other, a cross-repo filing and a same-repo
#      filing would disagree about the same absent key.
empty_root="$tmp_root/empty-repo"
mkdir -p "$empty_root"
for key in enabled assign_on_file fallback; do
  builtin_val=$(HOME="$fake_home" SHIPYARD_REPO_ROOT="$empty_root" \
    bash "$config_script" get "milestones.$key" 2>/dev/null)
  case "$key" in
    enabled)        resolver_val=$(grep -E '^DEFAULT_ENABLED=' "$resolver" | sed 's/.*="\(.*\)"/\1/') ;;
    assign_on_file) resolver_val=$(grep -E '^DEFAULT_ASSIGN=' "$resolver" | sed 's/.*="\(.*\)"/\1/') ;;
    fallback)       resolver_val=$(grep -E '^DEFAULT_FALLBACK=' "$resolver" | sed 's/.*="\(.*\)"/\1/') ;;
  esac
  assert_streq "milestones.$key default matches shipyard-config.sh's DEFAULTS_JSON" "$builtin_val" "$resolver_val"
done

echo
if [[ "$fail" -gt 0 ]]; then
  printf '%sFAIL%s  %d passed, %d failed\n' "$RED" "$RESET" "$pass" "$fail" >&2
  exit 1
else
  printf '%sPASS%s  %d passed, %d failed\n' "$GREEN" "$RESET" "$pass" "$fail"
  exit 0
fi

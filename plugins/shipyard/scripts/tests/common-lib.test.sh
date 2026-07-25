#!/usr/bin/env bash
# Test suite for scripts/lib/common.sh.
#
# Covers the three helpers extracted from per-script duplication (issue
# #887):
#
#   shipyard_home   — $SHIPYARD_HOME resolution (default + override)
#   require_jq      — hard-fail-if-missing dependency guard
#   atomic_write    — mktemp + rename, with the issue #357 0-byte guard
#
# Pure bash + jq. Run with:
#
#   bash plugins/shipyard/scripts/tests/common-lib.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="${here}/../lib/common.sh"

if [[ ! -f "$lib" ]]; then
  echo "FAIL: lib/common.sh not found at $lib" >&2
  exit 1
fi

# shellcheck source=../lib/common.sh disable=SC1091
source "$lib"

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
    printf '    actual: %s\n' "$haystack"
    fail=$((fail+1))
  fi
}

assert_exit() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    expected exit: %s\n' "$expected"
    printf '    actual exit:   %s\n' "$actual"
    fail=$((fail+1))
  fi
}

# --------------------------------------------------------------------------
echo "== shipyard_home"
# --------------------------------------------------------------------------

out=$(env -u SHIPYARD_HOME HOME="/tmp/fake-home-$$" bash -c "source '$lib'; shipyard_home")
assert_equals "$out" "/tmp/fake-home-$$/.shipyard" "shipyard_home defaults to \$HOME/.shipyard when unset"

out=$(SHIPYARD_HOME="/custom/shipyard/home" bash -c "source '$lib'; shipyard_home")
assert_equals "$out" "/custom/shipyard/home" "shipyard_home honors SHIPYARD_HOME override"

# --------------------------------------------------------------------------
echo "== require_jq"
# --------------------------------------------------------------------------

# jq is present in this test environment (every scripts/*.sh caller already
# depends on it) — require_jq must be a silent no-op and never exit.
out=$(bash -c "source '$lib'; require_jq; echo survived")
assert_equals "$out" "survived" "require_jq does not exit when jq is present"

# Simulate a jq-less PATH — but keep `basename` reachable (require_jq's own
# default-arg fallback shells out to it), so the negative case actually
# isolates "jq is missing" rather than "PATH is unusably empty". Resolve
# both real binaries FIRST, by absolute path, and symlink only `basename`
# into a fresh jq-free bin dir.
real_bash=$(command -v bash)
real_basename=$(command -v basename)
jq_free_bin=$(mktemp -d)
ln -s "$real_basename" "$jq_free_bin/basename"

out=$(PATH="$jq_free_bin" "$real_bash" -c "source '$lib'; require_jq myscript.sh" 2>&1)
code=$?
assert_exit "$code" 65 "require_jq exits 65 when jq is missing from PATH"
assert_contains "$out" "myscript.sh: jq is required but not installed" "require_jq names the passed script in its error"

# Default script_name derives from $0 when omitted.
runner_dir=$(mktemp -d)
runner="$runner_dir/named-caller.sh"
cat > "$runner" <<EOF
#!/usr/bin/env bash
source "$lib"
require_jq
EOF
out=$(PATH="$jq_free_bin" "$real_bash" "$runner" 2>&1)
code=$?
assert_exit "$code" 65 "require_jq (no arg) still exits 65 when jq is missing"
assert_contains "$out" "named-caller.sh: jq is required but not installed" "require_jq (no arg) derives the script name from \$0"
rm -rf "$runner_dir" "$jq_free_bin"

# --------------------------------------------------------------------------
echo "== atomic_write — success path"
# --------------------------------------------------------------------------

workdir=$(mktemp -d)
target="$workdir/state.json"
# shellcheck source=../lib/common.sh disable=SC1090,SC1091
printf '{"a":1}\n' | (source "$lib"; atomic_write "$target")
assert_exit "$?" 0 "atomic_write exits 0 on a successful write"
assert_equals "$(cat "$target" 2>/dev/null)" '{"a":1}' "atomic_write's target holds the written content"

shopt -s nullglob
leftover=("$workdir"/*.tmp.*)
shopt -u nullglob
assert_equals "${#leftover[@]}" "0" "atomic_write leaves no .tmp.<pid> stragglers after success"
rm -rf "$workdir"

# --------------------------------------------------------------------------
echo "== atomic_write — empty-tempfile guard (issue #357)"
# --------------------------------------------------------------------------

workdir=$(mktemp -d)
target="$workdir/state.json"
printf '{"prior":"value"}\n' > "$target"

# Simulate an upstream jq failure that produces empty stdout but a
# non-zero exit — `false` never writes anything to the pipe.
errfile=$(mktemp)
code=0
# shellcheck source=../lib/common.sh disable=SC1090,SC1091
false | (source "$lib"; atomic_write "$target") 2>"$errfile" || code=$?
err=$(cat "$errfile")
rm -f "$errfile"
assert_exit "$code" 66 "atomic_write refuses a 0-byte tempfile with exit 66"
assert_contains "$err" "refusing to rename empty tempfile" "atomic_write's 0-byte guard names the reason"
assert_equals "$(cat "$target")" '{"prior":"value"}' "atomic_write's 0-byte guard leaves the prior target untouched"

shopt -s nullglob
leftover=("$workdir"/*.tmp.*)
shopt -u nullglob
assert_equals "${#leftover[@]}" "0" "atomic_write's 0-byte guard leaves no .tmp.<pid> stragglers"
rm -rf "$workdir"

# --------------------------------------------------------------------------
echo "== atomic_write — custom script_name in error messages"
# --------------------------------------------------------------------------

workdir=$(mktemp -d)
target="$workdir/nested/state.json"
# shellcheck source=../lib/common.sh disable=SC1090,SC1091
out=$(false | (source "$lib"; atomic_write "$target" "custom-caller.sh") 2>&1)
assert_contains "$out" "custom-caller.sh: refusing to rename empty tempfile" "atomic_write honors an explicit script_name argument"
rm -rf "$workdir"

# --------------------------------------------------------------------------
printf '\n%sPASS%s: %d  %sFAIL%s: %d\n' "$GREEN" "$RESET" "$pass" "$RED" "$RESET" "$fail"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi

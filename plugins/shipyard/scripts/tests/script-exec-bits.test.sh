#!/usr/bin/env bash
# Test suite: every production script under plugins/shipyard/scripts/ is
# committed executable (git mode 100755).
#
# Background (issue #1094): a script shipped at mode 100644 and nothing
# caught it — shellcheck lints content, not permissions, and CI invokes
# every suite as `bash <file>`, which works regardless of the exec bit. The
# break surfaced only when a human ran the script the way its own docs said
# to, and got `permission denied`.
#
# A second, older instance (verify-new-dep-versions.sh, documented for
# direct invocation in the adding-dependencies skill) was found by the same
# sweep, which is what makes this a class worth guarding rather than a
# one-off slip. The script that prompted the guard has since been removed
# from the plugin (#1150); the guard stays because the failure mode is a
# property of the pipeline, not of that one file.
#
# Scope note: `tests/` is deliberately excluded. Test suites are genuinely
# mixed in this repo (both 755 and 644 are present) because CI and every
# documented workflow run them as `bash <file>` — there is no convention
# there to enforce. Production scripts are different: they are documented
# as directly invocable commands, so the exec bit is part of their contract.
#
# Pure bash + git. Run with:
#
#   bash plugins/shipyard/scripts/tests/script-exec-bits.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../../.." && pwd)"

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

cd "$repo_root" || { echo "FAIL: cannot cd to repo root $repo_root" >&2; exit 1; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "SKIP: not a git work tree (cannot read committed file modes)"
  exit 0
fi

# --------------------------------------------------------------------------
echo "== every production script under scripts/ is committed executable"
# --------------------------------------------------------------------------

# git ls-files -s prints: <mode> <object> <stage>\t<path>
non_exec=$(git ls-files -s 'plugins/shipyard/scripts/*.sh' \
  | awk '$1 != "100755" && $NF !~ /\/tests\// { print $NF }' \
  | sort)

if [[ -n "$non_exec" ]]; then
  printf '  offending files:\n'
  while IFS= read -r offender; do
    printf '    %s\n' "$offender"
  done <<< "$non_exec"
fi
assert_equals "$non_exec" "" \
  "no production script under plugins/shipyard/scripts/ is committed non-executable"

# Sanity: the sweep must actually be looking at something. A glob that
# silently matches nothing would make the assertion above vacuously true —
# the same failure shape .claude/rules warns about for narrowed sweeps.
counted=$(git ls-files -s 'plugins/shipyard/scripts/*.sh' \
  | awk '$NF !~ /\/tests\// { n++ } END { print n+0 }')
if (( counted > 20 )); then
  printf '  %sPASS%s  %s (%d files)\n' "$GREEN" "$RESET" \
    "the sweep is non-vacuous — it inspected the real script set" "$counted"
  pass=$((pass+1))
else
  printf '  %sFAIL%s  sweep matched only %d production scripts — glob is wrong\n' \
    "$RED" "$RESET" "$counted"
  fail=$((fail+1))
fi

# --------------------------------------------------------------------------
echo "== the file that motivated this guard"
# --------------------------------------------------------------------------
# do-work-supervisor.sh was the other one; it was removed from the plugin in
# #1150, so verify-new-dep-versions.sh is the surviving named regression.

f=plugins/shipyard/scripts/verify-new-dep-versions.sh
mode=$(git ls-files -s "$f" | awk '{print $1}')
assert_equals "$mode" "100755" "$(basename "$f") is committed 100755"

# --------------------------------------------------------------------------
echo "== every production script starts with a shebang"
# --------------------------------------------------------------------------
# An exec bit is only meaningful with one; checking both together is what
# makes "directly invocable" a real contract rather than a mode number.

missing_shebang=""
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  read -r first < "$f" || true
  [[ "$first" == '#!'* ]] || missing_shebang+="$f"$'\n'
done < <(git ls-files 'plugins/shipyard/scripts/*.sh' | grep -v '/tests/')

assert_equals "${missing_shebang%$'\n'}" "" \
  "every production script under scripts/ starts with a shebang"

# --------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1

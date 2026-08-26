#!/usr/bin/env bash
# Test suite: -h/--help exit-0 coverage across plugins/shipyard/scripts/*.sh
# (issue #1550).
#
# Background. The repo has an established convention, codified twice before
# this suite existed (#1455, #1492/#1546), that a script's own `usage()`
# block is the normative source of its call shape when spec prose drifts.
# That fallback only works if `--help` (and `-h`) actually exits 0 — a
# caller who gets a non-zero exit reasonably concludes the invocation itself
# was wrong, not that it just asked for help. #1550's repro found
# `detect-ci-runner-capacity.sh --help` exiting 64 (EX_USAGE), and a full
# behavioral sweep of every OTHER scripts/*.sh with a usage() block turned up
# 19 more (assert-branch-switched.sh, assert-ci-green.sh,
# resolve-manifest-only-dirty.sh, trusted-authors-normalize.sh,
# validate-awaiting-external-probe.sh, watch-pr-terminal.sh,
# watch-resume-probe.sh, and ten *-scan.sh scanners, plus
# spike-shape-detect.sh and verify-new-dep-versions.sh) — every one sharing
# the identical bug shape: `-h|--help)` was already routed to the shared
# `usage()` function, but that function's OWN body ended in an unconditional
# `exit <N>` (64, 2, or 4 depending on the script's own convention), so
# --help silently inherited the same non-zero code as every genuine usage
# error. All 21 were fixed the same way: `usage()` became print-only, and
# every call site — including the `-h|--help` one — now picks its own exit
# code explicitly (`exit 0` for help, the script's original code for a real
# error).
#
# This suite is the guard that keeps that regressing. It is BEHAVIORAL, not
# a text scan (unlike brace-expansion-scan.sh / command-substitution-scan.sh,
# which grep markdown for a banned shell shape) — it actually invokes every
# candidate script with `-h` and `--help` and asserts exit 0, because the
# text-presence of an `-h|--help)` case arm proved a poor proxy: several of
# the 21 broken scripts already MATCHED that arm and still exited non-zero,
# because the bug lived one level down, inside the shared `usage()` body.
#
# Candidate set. Every `plugins/shipyard/scripts/*.sh` (top-level only — not
# `scripts/tests/*.sh`, not `scripts/lib/*.sh`, which is sourced, never
# invoked directly) that defines a `usage()` function, MINUS the EXCLUDED
# set below. Two, and only two, exclusion reasons are legitimate (per the
# issue's own scope note):
#
#   1. No usage() block at all — nothing to make normative. Not applicable
#      here since the candidate set is already scoped to `grep -l
#      '^usage()'`, so a script with none is never a candidate to begin
#      with; this reason exists for documentation, not as an active filter.
#   2. The script's ONLY interface is a required subcommand with no
#      standalone bare-invocation shape that --help could sensibly attach
#      to. As of #1550's fix this set is EMPTY — even
#      resolve-manifest-only-dirty.sh (single required `resolve`
#      subcommand) got --help support, since it already had a usage() block
#      and the fix was mechanical. The array stays here, empty, so a future
#      genuinely subcommand-only script can be added with a one-line reason
#      instead of this suite needing new machinery.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/help-flag-coverage.test.sh

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts_dir="$(cd "$here/.." && pwd)"

if [[ ! -d "$scripts_dir" ]]; then
  echo "FAIL: scripts dir not found at $scripts_dir" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

echo "help-flag-coverage: -h/--help exit-0 sweep (issue #1550)"
echo

# --- EXCLUDED: scripts whose ONLY interface is a required subcommand with
# no sensible bare --help attach point. Empty as of #1550 — see header.
# Plain array + `case`, not `declare -A` — associative arrays are a bash-4+
# feature and this suite must also run under macOS's bundled bash 3.2 (see
# legacy-agent-dispatch-retired-791.test.sh for the same convention).
EXCLUDED=()
is_excluded() {
  local f="$1" x
  for x in "${EXCLUDED[@]:-}"; do
    [[ -n "$x" && "$x" == "$f" ]] && return 0
  done
  return 1
}

# --- Candidate discovery: every top-level scripts/*.sh defining usage().
candidates=()
while IFS= read -r f; do
  candidates+=("$f")
done < <(cd "$scripts_dir" && grep -l '^usage()' -- *.sh | sort)

if [[ ${#candidates[@]} -lt 40 ]]; then
  bad "candidate discovery found only ${#candidates[@]} usage()-bearing scripts (floor 40) — the grep itself may be broken, not the corpus shrunk"
else
  ok "candidate discovery found ${#candidates[@]} usage()-bearing scripts (floor 40)"
fi

checked=0
for f in "${candidates[@]}"; do
  if is_excluded "$f"; then
    continue
  fi
  checked=$((checked+1))
  path="$scripts_dir/$f"

  # --help
  out="$(timeout 10 bash "$path" --help </dev/null 2>&1)"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "$f --help exits 0"
  else
    bad "$f --help exited $rc (expected 0) — output: ${out//$'\n'/ | }"
  fi

  # -h (the short alias — checked separately since a script can wire one
  # without the other, e.g. a case arm typo'd as `--help)` alone).
  out_h="$(timeout 10 bash "$path" -h </dev/null 2>&1)"
  rc_h=$?
  if [[ "$rc_h" -eq 0 ]]; then
    ok "$f -h exits 0"
  else
    bad "$f -h exited $rc_h (expected 0) — output: ${out_h//$'\n'/ | }"
  fi
done

if [[ "$checked" -eq 0 ]]; then
  bad "zero scripts were actually checked — EXCLUDED swallowed the whole candidate set"
fi

echo
echo "-----------------------------------------"

# --- NEGATIVE CONTROL: a script whose usage() force-exits non-zero
# regardless of caller (the exact #1550 bug shape) must be CAUGHT, proving
# this suite fails on a real finding rather than trivially passing.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
broken="$work/broken-help.sh"
cat > "$broken" <<'FIXTURE'
#!/usr/bin/env bash
usage() {
  echo "usage: broken-help.sh <thing>" >&2
  exit 64
}
case "${1:-}" in
  -h|--help) usage ;;
esac
[ -n "${1:-}" ] || usage
echo "ok"
FIXTURE
chmod +x "$broken"

mutant_rc="$(timeout 10 bash "$broken" --help </dev/null >/dev/null 2>&1; echo $?)"
if [[ "$mutant_rc" -ne 0 ]]; then
  ok "negative control: a usage() that force-exits non-zero is caught (mutant --help exited $mutant_rc, not 0) — this suite is load-bearing"
else
  bad "negative control: the planted #1550-shaped mutant unexpectedly exited 0 — the check itself is broken"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

#!/usr/bin/env bash
# Test: the positional-<owner/repo> detector scripts reject a malformed
# invocation with exit 64 (EX_USAGE) BEFORE any `gh` call, instead of binding
# the bad token into the repo variable and forwarding it (issue #1502).
#
# Background
# ----------
# `gh` spells the target-repo argument `--repo`, so a caller deriving the
# invocation from surrounding spec prose reaches for the flag form. These
# scripts take the repo POSITIONALLY, and before #1502 an unrecognized flag was
# bound straight into the repo variable and forwarded — building a nonsense
# command line whose failure was then reported through each script's
# *fail-safe* path (`could not read repo signals`, `unknown`, exit 2, or a
# confident `silent`). The diagnostic pointed at the wrong layer, so the reader
# debugged `gh` or the network instead of their own call.
#
# #1492 fixed the same shape in verify-config-labels.sh, deliberately narrowly.
# #1502 is the sibling sweep. This suite pins the shared contract across the
# four `detect-*` scripts that take `<owner/repo>` positionally:
#
#   * an unrecognized `-*` first argument, a malformed owner/name slug, an
#     extra positional, and a wrong `--decide*` arity all exit 64 with a
#     `USAGE_ERROR:` stdout prefix;
#   * the rejection fires BEFORE any `gh` process is spawned (asserted with a
#     PATH shim that records every invocation);
#   * `-h` / `--help` prints usage and exits 0;
#   * and — the reverse-direction pin — a WELL-FORMED call whose signal is
#     genuinely unreadable still resolves through each script's own
#     pre-existing fail-safe, never reclassified as a usage error. Without this
#     half, the conflation could be "fixed" by collapsing the other way.
#
# Hermetic: no network. Every live-mode call runs against a `gh` shim on PATH.
#
# Run with:
#
#   bash plugins/shipyard/scripts/tests/positional-repo-usage-guard.test.sh

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

scripts_dir="$repo_root/plugins/shipyard/scripts"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

echo "positional <owner/repo> usage-guard tests (issue #1502)"
echo

# ── A `gh` shim that records every invocation and fails. Two jobs: it makes
#    every live-mode call hermetic, AND it is the instrument for the
#    "rejected before any gh call" assertion. ────────────────────────────────
shimdir="$(mktemp -d)"
trap 'rm -rf "$shimdir"' EXIT
ghlog="$shimdir/gh-invocations"
cat >"$shimdir/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_SHIM_LOG"
exit 1
SHIM
chmod +x "$shimdir/gh"

# Run a script with the shim on PATH. Sets $out and $status; truncates the log
# first so $ghlog reflects only this call.
run_shimmed() {
  : >"$ghlog"
  out="$(PATH="$shimdir:$PATH" GH_SHIM_LOG="$ghlog" bash "$@" 2>&1)"
  status=$?
}

gh_was_called() { [[ -s "$ghlog" ]]; }

# ── The four scripts under test, with the arguments each needs. ─────────────
#    name | good-args | bad-flag-args | extra-positional-args | decide-mode-flag
#
# Kept as parallel arrays rather than an associative array — these scripts must
# run on macOS's stock bash 3.2 as well as CI's newer bash, and the rest of this
# repo's suites hold to the same floor.
names=(
  "detect-ungated-admin-direct-merge.sh"
  "detect-missing-workflow-scope.sh"
  "detect-ci-gate-narrowing.sh"
  "detect-mutually-blocking-prs.sh"
)

for name in "${names[@]}"; do
  script="$scripts_dir/$name"

  echo "($name)"

  if [[ -f "$script" ]]; then
    ok "$name exists"
  else
    bad "$name exists (missing: $script)"
    echo
    continue
  fi

  if [[ -x "$script" ]]; then
    ok "$name has the exec bit set"
  else
    bad "$name has the exec bit set"
  fi

  # Per-script argument shapes.
  case "$name" in
    detect-ungated-admin-direct-merge.sh)
      good_args=("mattsears18/shipyard")
      bad_flag_args=("--repo" "mattsears18/shipyard")
      slug_args=("not-a-slug")
      extra_args=("mattsears18/shipyard" "extra")
      decide_flag="--decide"
      ;;
    detect-missing-workflow-scope.sh)
      good_args=("mattsears18/shipyard" "main")
      bad_flag_args=("--repo" "mattsears18/shipyard")
      slug_args=("not-a-slug" "main")
      extra_args=("mattsears18/shipyard" "main" "extra")
      decide_flag="--decide"
      ;;
    detect-ci-gate-narrowing.sh)
      good_args=("mattsears18/shipyard" "1")
      bad_flag_args=("--repo" "mattsears18/shipyard" "1")
      slug_args=("not-a-slug" "1")
      extra_args=("mattsears18/shipyard" "1" "extra")
      decide_flag="--decide"
      ;;
    detect-mutually-blocking-prs.sh)
      good_args=("mattsears18/shipyard" "1" "2")
      bad_flag_args=("--repo" "mattsears18/shipyard" "1" "2")
      slug_args=("not-a-slug" "1" "2")
      extra_args=()          # variadic PR list — no "too many positionals" shape
      decide_flag="--decide-pair"
      ;;
  esac

  # ── (1) THE #1502 REPRO. `--repo <owner/repo>` exits 64 with USAGE_ERROR:
  #        on stdout — not laundered through the fail-safe path. ─────────────
  run_shimmed "$script" "${bad_flag_args[@]}"
  if [[ $status -eq 64 && "$out" == USAGE_ERROR:* ]]; then
    ok "--repo <owner/repo> (the #1502 repro): exit 64, stdout starts USAGE_ERROR:"
  else
    bad "--repo <owner/repo>: expected exit 64 + USAGE_ERROR:, got exit $status: $out"
  fi

  # ── (2) …and the rejection fired BEFORE any `gh` process was spawned. This
  #        is the acceptance criterion the fail-safe paths cannot satisfy: they
  #        all require a failed `gh` call to reach their verdict. ────────────
  if gh_was_called; then
    bad "--repo <owner/repo>: rejected only AFTER calling gh ($(head -1 "$ghlog"))"
  else
    ok "--repo <owner/repo>: rejected before any gh call"
  fi

  # ── (3) The offending flag is named in the message, so the reader fixes the
  #        call site instead of debugging gh. ───────────────────────────────
  if [[ "$out" == *"--repo"* && "$out" == *POSITIONAL* ]]; then
    ok "usage error names the offending flag and says the repo is POSITIONAL"
  else
    bad "usage error should name '--repo' and say POSITIONAL, got: $out"
  fi

  # ── (4) Any other unrecognized flag, not just --repo. ────────────────────
  run_shimmed "$script" "--limit" "5"
  if [[ $status -eq 64 && "$out" == USAGE_ERROR:* ]]; then
    ok "unrecognized flag (--limit): exit 64, USAGE_ERROR:"
  else
    bad "unrecognized flag (--limit): expected exit 64 + USAGE_ERROR:, got exit $status: $out"
  fi
  if gh_was_called; then
    bad "unrecognized flag (--limit): rejected only AFTER calling gh"
  else
    ok "unrecognized flag (--limit): rejected before any gh call"
  fi

  # ── (5) A malformed owner/name slug is the same class of caller error. ───
  run_shimmed "$script" "${slug_args[@]}"
  if [[ $status -eq 64 && "$out" == USAGE_ERROR:* && "$out" == *slug* ]]; then
    ok "malformed slug ('not-a-slug'): exit 64, USAGE_ERROR: naming the slug"
  else
    bad "malformed slug: expected exit 64 + USAGE_ERROR: naming the slug, got exit $status: $out"
  fi
  if gh_was_called; then
    bad "malformed slug: rejected only AFTER calling gh"
  else
    ok "malformed slug: rejected before any gh call"
  fi

  # ── (6) Too many positionals (where the script has a fixed arity). ──────
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    run_shimmed "$script" "${extra_args[@]}"
    if [[ $status -eq 64 && "$out" == USAGE_ERROR:* ]]; then
      ok "extra positional argument: exit 64, USAGE_ERROR:"
    else
      bad "extra positional argument: expected exit 64 + USAGE_ERROR:, got exit $status: $out"
    fi
  fi

  # ── (7) Wrong --decide* arity is a usage error too, not a silent default. ─
  run_shimmed "$script" "$decide_flag" "1"
  if [[ $status -eq 64 && "$out" == USAGE_ERROR:* ]]; then
    ok "$decide_flag with wrong arity: exit 64, USAGE_ERROR:"
  else
    bad "$decide_flag with wrong arity: expected exit 64 + USAGE_ERROR:, got exit $status: $out"
  fi

  # ── (8) -h / --help is NOT an error: usage on stderr, exit 0, and no
  #        USAGE_ERROR token (which would make a help request look like a bug). ─
  run_shimmed "$script" "--help"
  if [[ $status -eq 0 && "$out" == *usage:* && "$out" != USAGE_ERROR:* ]]; then
    ok "--help: exit 0, usage block, no USAGE_ERROR token"
  else
    bad "--help: expected exit 0 + usage block without USAGE_ERROR, got exit $status: $out"
  fi

  run_shimmed "$script" "-h"
  if [[ $status -eq 0 && "$out" == *usage:* ]]; then
    ok "-h: exit 0, usage block"
  else
    bad "-h: expected exit 0 + usage block, got exit $status: $out"
  fi

  # ── (9) The usage block states the positional contract, so a reader who runs
  #        the script to find the signature learns it without reading source. ─
  if [[ "$out" == *"POSITIONAL"* && "$out" == *"no --repo flag"* ]]; then
    ok "usage block states the repo is POSITIONAL and there is no --repo flag"
  else
    bad "usage block should state POSITIONAL / no --repo flag, got: $out"
  fi

  # ── (10) REVERSE-DIRECTION PIN. A WELL-FORMED call whose `gh` reads all fail
  #         must still resolve through this script's OWN pre-existing fail-safe
  #         — never reclassified as a usage error. Without this, the 64-vs-
  #         fail-safe conflation could be "fixed" by collapsing the other way,
  #         turning every transient API failure into a bogus caller error. ───
  run_shimmed "$script" "${good_args[@]}"
  if [[ $status -ne 64 && "$out" != *USAGE_ERROR:* ]]; then
    ok "well-formed call, unreadable signal: kept its own fail-safe (exit $status), not reclassified as usage"
  else
    bad "well-formed call, unreadable signal: must NOT be a usage error, got exit $status: $out"
  fi

  # …and it actually reached `gh`, proving the reverse pin exercised the live
  # path rather than short-circuiting on argument validation.
  if gh_was_called; then
    ok "well-formed call reaches the live gh path (reverse pin is not vacuous)"
  else
    bad "well-formed call never called gh — the reverse-direction pin is vacuous"
  fi

  echo
done

# ── (11) Each script's own fail-safe verdict is unchanged on a well-formed
#         unreadable call — the specific token, not just "not 64". ───────────
echo "(fail-safe verdicts preserved)"

run_shimmed "$scripts_dir/detect-missing-workflow-scope.sh" "mattsears18/shipyard" "main"
if [[ $status -eq 0 && "$out" == *silent* ]]; then
  ok "detect-missing-workflow-scope: unreadable signal still resolves toward 'silent'"
else
  bad "detect-missing-workflow-scope: expected exit 0 + 'silent', got exit $status: $out"
fi

run_shimmed "$scripts_dir/detect-ci-gate-narrowing.sh" "mattsears18/shipyard" "1"
if [[ $status -eq 2 && "$out" == *unknown* ]]; then
  ok "detect-ci-gate-narrowing: unreadable diff still resolves toward 'unknown' (exit 2)"
else
  bad "detect-ci-gate-narrowing: expected exit 2 + 'unknown', got exit $status: $out"
fi

run_shimmed "$scripts_dir/detect-mutually-blocking-prs.sh" "mattsears18/shipyard" "1" "2"
if [[ $status -eq 2 ]]; then
  ok "detect-mutually-blocking-prs: unreadable signal still exits 2 (no pairs this poll)"
else
  bad "detect-mutually-blocking-prs: expected exit 2, got exit $status: $out"
fi

# detect-missing-workflow-scope's documented "no repo to probe" degrade is
# deliberately NOT a usage error — a caller with nothing to pass is a stated
# shape, unlike a flag or a malformed slug. Pin it so the sweep didn't
# accidentally tighten it.
run_shimmed "$scripts_dir/detect-missing-workflow-scope.sh"
if [[ $status -eq 0 && "$out" == *silent* ]]; then
  ok "detect-missing-workflow-scope: no-argument degrade to 'silent' preserved (not a usage error)"
else
  bad "detect-missing-workflow-scope: no-argument call should still print 'silent' + exit 0, got exit $status: $out"
fi

echo

# ── (12) Caller-spec contract: every spec that invokes one of these scripts
#         states the positional form, per the #1455 / #1492 precedent. A
#         literal invocation in the spec is what stops the next caller from
#         re-deriving `--repo` out of surrounding prose. ────────────────────
echo "(caller specs state the positional contract)"

check_doc() {
  local rel="$1" needle="$2" label="$3"
  local path="$repo_root/$rel"
  if [[ ! -f "$path" ]]; then
    bad "$label ($rel is missing)"
    return
  fi
  if grep -qF "$needle" "$path"; then
    ok "$label"
  else
    bad "$label (expected to find \"$needle\" in $rel)"
  fi
}

check_doc "plugins/shipyard/skills/worker-preamble/auto-merge.md" "1502" \
  "auto-merge.md cites #1502 for the ungated/gate-narrowing detectors"
check_doc "plugins/shipyard/skills/worker-preamble/auto-merge.md" "POSITIONAL" \
  "auto-merge.md states the repo argument is POSITIONAL"
check_doc "plugins/shipyard/skills/worker-preamble/auto-merge.md" "USAGE_ERROR:" \
  "auto-merge.md documents the USAGE_ERROR: branch"
check_doc "plugins/shipyard/agents/issue-worker/issue-work.md" "1502" \
  "issue-work.md step 6.a cites #1502"
check_doc "plugins/shipyard/agents/issue-worker/fix-main-ci.md" "1502" \
  "fix-main-ci.md cites #1502"
check_doc "plugins/shipyard/agents/issue-worker/fix-failing-prs-batch.md" "1502" \
  "fix-failing-prs-batch.md cites #1502"
check_doc "plugins/shipyard/commands/do-work/inline-trivial.md" "1502" \
  "inline-trivial.md cites #1502"
check_doc "plugins/shipyard/commands/do-work/setup/01-repo-recovery.md" "USAGE_ERROR:" \
  "01-repo-recovery.md normalizes a USAGE_ERROR verdict at both call sites"
check_doc "plugins/shipyard/commands/do-work/drain.md" "mb_exit == 64" \
  "drain.md gives detect-mutually-blocking-prs.sh an explicit 64 branch"
check_doc "plugins/shipyard/commands/do-work/drain.md" "USAGE_ERROR:*) merge_gating=ungated" \
  "drain.md normalizes a USAGE_ERROR merge-gating verdict to the conservative reading"
check_doc "CLAUDE.md" "1502" \
  "CLAUDE.md's executable-source-of-truth line states the positional contract"

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

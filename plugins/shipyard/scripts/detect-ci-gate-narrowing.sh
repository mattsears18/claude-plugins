#!/usr/bin/env bash
# detect-ci-gate-narrowing.sh — decide whether a PR's diff NARROWS a required
# CI gate (makes it more permissive) rather than fixing the underlying cause.
#
# This script is the SINGLE EXECUTABLE SOURCE OF TRUTH for that decision.
#
# Background (issue #1139)
# -------------------------
# A `fix-main-ci` worker restored green `main` by adding a self-authored
# allowlist that permanently exempts three high-severity `npm audit`
# advisories from ever failing the gate — engineering that was itself sound
# (fails closed on unknown shapes, justified per-GHSA) — and then armed
# auto-merge on the PR that shipped it. Nothing in the existing spec required
# disarming it; only orchestrator judgment caught it before it landed.
#
# This is a DIFFERENT risk class from the existing "Never disable a committed
# security or supply-chain control" rule (#1088, see `SKILL.md` and this
# fragment's own step 0.3): #1088 catches a PR that had to *disable/bypass* an
# EXISTING committed control to get CI to pass. This catches a PR that leaves
# the control nominally in place but *narrows what it considers a failure* —
# a brand-new allowlist/exception file, a raised severity threshold
# (`--audit-level` or an ecosystem equivalent), a `continue-on-error: true`
# added to a gate step, a deleted gate step, or a narrowed workflow trigger
# filter (`paths-ignore:`). The mechanism can be entirely justified; the point
# is that its blast radius is every FUTURE PR, not just this one — so the risk
# acceptance belongs to a human, not an autonomous merge.
#
# Detection is diff-based and mechanical, matching the issue's own "cheap,
# mostly-mechanical signal" framing — it is a heuristic, not a semantic
# analysis, and deliberately requires BOTH (a) the diff touches a CI-gate
# surface (a workflow file, or a brand-new file that looks like an allowlist/
# exception list) AND (b) at least one concrete permissive-edit signal, so an
# ordinary unrelated workflow tweak does not trip it.
#
# Usage — live detection (the normal path):
#   bash detect-ci-gate-narrowing.sh <owner/repo> <pr-number>
#     -> prints `narrowing`, `clean`, or `unknown` on stdout; diagnostics on
#        stderr. Exit 0 on `narrowing`/`clean`, 2 when the diff could not be
#        read at all (`unknown`), 1 on a usage error.
#
#   `narrowing` => do NOT arm auto-merge in any form. Label needs-human-review.
#   `clean`     => no gate-narrowing signal found; continue the normal flow.
#   `unknown`   => the diff could not be read. Treat exactly like `narrowing`
#                  — fail toward the safe/blocking reading, never toward
#                  silently arming auto-merge on an unreadable diff.
#
# Usage — pure decision (hermetic, for tests and for callers that already hold
# the six signals):
#   bash detect-ci-gate-narrowing.sh --decide <touches_workflow:0|1> \
#     <new_gate_file:0|1> <continue_on_error_added:0|1> \
#     <audit_level_lowered:0|1> <gate_step_deleted:0|1> \
#     <path_filter_narrowed:0|1>
#
# Fail-safe posture: any signal that cannot be computed resolves toward 0
# (not detected) for that individual signal, but a total read failure (the
# diff itself can't be fetched) resolves the WHOLE decision toward `unknown`,
# which callers treat as `narrowing`. The asymmetry mirrors
# detect-ungated-admin-direct-merge.sh: missing this once is a silent,
# repo-wide security-control weakening that autonomously reaches `main`; a
# false positive costs one PR one human-review step, and the fix itself still
# ships (see auto-merge.md step 0.34 — this is not a refusal to do the work).

set -uo pipefail

# ---------------------------------------------------------------------------
# The decision. Pure function of the six signals — no I/O, no network.
# ---------------------------------------------------------------------------
decide() {
  local touches_workflow="$1" new_gate_file="$2" continue_on_error_added="$3" \
        audit_level_lowered="$4" gate_step_deleted="$5" path_filter_narrowed="$6"

  local gate_surface=0 permissive=0
  if [ "$touches_workflow" = "1" ] || [ "$new_gate_file" = "1" ]; then
    gate_surface=1
  fi
  if [ "$continue_on_error_added" = "1" ] || [ "$new_gate_file" = "1" ] \
     || [ "$audit_level_lowered" = "1" ] || [ "$gate_step_deleted" = "1" ] \
     || [ "$path_filter_narrowed" = "1" ]; then
    permissive=1
  fi

  if [ "$gate_surface" = "1" ] && [ "$permissive" = "1" ]; then
    printf 'narrowing\n'
  else
    printf 'clean\n'
  fi
}

# ---------------------------------------------------------------------------
# Signal extraction from a unified diff (as produced by `gh pr diff`).
# ---------------------------------------------------------------------------

sig_touches_workflow() {
  printf '%s' "$1" | grep -qE '^diff --git a/\.github/workflows/' && echo 1 || echo 0
}

# A brand-new file whose name looks like an allowlist/exception/ignore list
# for a security or CI gate — the exact shape of the #1139 repro.
sig_new_gate_file() {
  local diff="$1" new_files
  new_files="$(printf '%s' "$diff" | awk '
    /^diff --git a\// { is_new=0 }
    /^new file mode/  { is_new=1 }
    /^\+\+\+ b\// {
      if (is_new == 1) {
        p=$0
        sub(/^\+\+\+ b\//, "", p)
        print p
      }
      is_new=0
    }
  ')"
  if printf '%s\n' "$new_files" | grep -qiE '(^|/)[a-z0-9_.-]*(allow[-_]?list|except(ion)?s?|ignore[-_]?list|audit[-_]?ignore|security[-_]?except(ion)?s?|suppress(ion)?s?)[a-z0-9_.-]*\.(json|ya?ml|txt|list|conf|cfg)$'; then
    echo 1
  else
    echo 0
  fi
}

sig_continue_on_error_added() {
  printf '%s' "$1" | grep -qE '^\+[[:space:]]*continue-on-error:[[:space:]]*true[[:space:]]*$' && echo 1 || echo 0
}

sev_rank() {
  case "$1" in
    low) echo 1 ;;
    moderate) echo 2 ;;
    high) echo 3 ;;
    critical) echo 4 ;;
    *) echo 0 ;;
  esac
}

# Flags a raised (weakened) `--audit-level` — or ecosystem-equivalent
# `--audit-level=`-shaped flag — comparing the max removed severity against
# the min added severity. Approximation, not a per-line pairing: good enough
# for the "cheap, mechanical signal" this detector is meant to be.
sig_audit_level_lowered() {
  local diff="$1" removed added max_removed=0 min_added=99 lvl rank
  removed="$(printf '%s' "$diff" | grep -E '^-[^-]' | grep -oE -- '--audit-level[= ]+[a-z]+' | grep -oE '[a-z]+$')"
  added="$(printf '%s' "$diff" | grep -E '^\+[^+]' | grep -oE -- '--audit-level[= ]+[a-z]+' | grep -oE '[a-z]+$')"

  [ -z "$removed" ] && { echo 0; return; }
  [ -z "$added" ] && { echo 0; return; }

  for lvl in $removed; do
    rank="$(sev_rank "$lvl")"
    [ "$rank" -gt "$max_removed" ] && max_removed="$rank"
  done
  for lvl in $added; do
    rank="$(sev_rank "$lvl")"
    [ "$rank" -gt 0 ] && [ "$rank" -lt "$min_added" ] && min_added="$rank"
  done

  if [ "$min_added" -lt 99 ] && [ "$min_added" -lt "$max_removed" ]; then
    echo 1
  else
    echo 0
  fi
}

# A deleted gate step: more `- name:` step headers removed than added, scoped
# to hunks inside `.github/workflows/**` only (so an unrelated step reorder
# elsewhere in the repo can't trip this).
sig_gate_step_deleted() {
  printf '%s' "$1" | awk '
    /^diff --git a\// { inwf = ($0 ~ /a\/\.github\/workflows\//) ? 1 : 0; next }
    inwf && /^-[[:space:]]*- name:/ { removed++ }
    inwf && /^\+[[:space:]]*- name:/ { added++ }
    END { print ((removed+0) > (added+0)) ? 1 : 0 }
  '
}

# A brand-new `paths-ignore:` trigger key appearing inside a workflow file —
# the highest-signal, lowest-noise shape of "narrow the trigger filter so the
# gate stops running on the files that used to fail it". Extending an
# already-existing paths-ignore list is a weaker signal and deliberately not
# covered here — precision over recall for a mechanical heuristic.
sig_path_filter_narrowed() {
  printf '%s' "$1" | awk '
    /^diff --git a\// { inwf = ($0 ~ /a\/\.github\/workflows\//) ? 1 : 0; next }
    inwf && /^\+[[:space:]]*paths-ignore:/ { found=1 }
    END { print (found ? 1 : 0) }
  '
}

main() {
  if [ "${1:-}" = "--decide" ]; then
    if [ "$#" -ne 7 ]; then
      echo "usage: $0 --decide <touches_workflow> <new_gate_file> <continue_on_error_added> <audit_level_lowered> <gate_step_deleted> <path_filter_narrowed>" >&2
      exit 1
    fi
    decide "$2" "$3" "$4" "$5" "$6" "$7"
    exit 0
  fi

  local repo="${1:-}" pr="${2:-}"
  if [ -z "$repo" ] || [ -z "$pr" ]; then
    echo "usage: $0 <owner/repo> <pr-number>" >&2
    echo "       $0 --decide <touches_workflow> <new_gate_file> <continue_on_error_added> <audit_level_lowered> <gate_step_deleted> <path_filter_narrowed>" >&2
    exit 1
  fi

  local diff
  diff="$(gh pr diff "$pr" --repo "$repo" 2>/dev/null)"
  if [ -z "$diff" ]; then
    echo "detect-ci-gate-narrowing: could not read diff for ${repo}#${pr} — failing toward 'unknown' (treat as narrowing)" >&2
    echo "unknown"
    exit 2
  fi

  local touches_workflow new_gate_file continue_on_error_added \
        audit_level_lowered gate_step_deleted path_filter_narrowed verdict
  touches_workflow="$(sig_touches_workflow "$diff")"
  new_gate_file="$(sig_new_gate_file "$diff")"
  continue_on_error_added="$(sig_continue_on_error_added "$diff")"
  audit_level_lowered="$(sig_audit_level_lowered "$diff")"
  gate_step_deleted="$(sig_gate_step_deleted "$diff")"
  path_filter_narrowed="$(sig_path_filter_narrowed "$diff")"

  verdict="$(decide "$touches_workflow" "$new_gate_file" "$continue_on_error_added" \
    "$audit_level_lowered" "$gate_step_deleted" "$path_filter_narrowed")"

  {
    printf 'repo=%s pr=%s\n' "$repo" "$pr"
    printf 'touches_workflow=%s new_gate_file=%s continue_on_error_added=%s audit_level_lowered=%s gate_step_deleted=%s path_filter_narrowed=%s\n' \
      "$touches_workflow" "$new_gate_file" "$continue_on_error_added" \
      "$audit_level_lowered" "$gate_step_deleted" "$path_filter_narrowed"
    if [ "$verdict" = "narrowing" ]; then
      printf 'verdict=narrowing -- this PR narrows a required CI gate. Do NOT arm auto-merge.\n'
    else
      printf 'verdict=clean -- no gate-narrowing signal found.\n'
    fi
  } >&2

  printf '%s\n' "$verdict"
}

main "$@"

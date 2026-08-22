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
# The `continue-on-error` signal is attributed PER STEP (issue #1494): the flag
# only counts when the step it belongs to already existed on the base branch.
# The same flag on a brand-new reporting-only step (an `actions/upload-artifact`
# upload, a summary emitter) relaxes nothing that existed before — a repo can
# even *mandate* it there, as `mattsears18/lightwork` does after a quota-
# exhausted upload step turned an all-green run red across two required checks.
# Treating that shape as narrowing made every such PR cost a human clear, which
# is how a gate loses its credibility. See sig_continue_on_error_added below.
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
#        read at all from a WELL-FORMED call (`unknown`), 64 on a usage error.
#
#   The target repo is POSITIONAL. There is no `--repo` flag — passing one is a
#   usage error (exit 64), not an unreadable diff. See issue #1502: before that
#   fix, `--repo owner/name 123` bound `repo` to the literal `--repo`, produced
#   `gh pr diff owner/name --repo --repo`, and reported
#   `could not read diff for --repo#owner/name — failing toward 'unknown'` —
#   a caller error wearing the costume of a transient read failure, which then
#   silently costs a human-review clear on a PR that never needed one.
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

# EX_USAGE, per sysexits.h — the same convention session-state.sh,
# shipyard-config.sh and detect-ci-runner-capacity.sh already use.
EX_USAGE=64

usage() {
  echo "usage: $0 <owner/repo> <pr-number>" >&2
  echo "       $0 --decide <touches_workflow> <new_gate_file> <continue_on_error_added> <audit_level_lowered> <gate_step_deleted> <path_filter_narrowed>" >&2
  echo "       $0 --help" >&2
  echo "note: the target repo is POSITIONAL — there is no --repo flag." >&2
}

# A caller error: the command line itself is wrong. Distinct from the `unknown`
# path below, which is for a well-formed call whose diff could not be read.
die_usage() {
  echo "USAGE_ERROR: $1"
  echo "detect-ci-gate-narrowing: usage error (exit $EX_USAGE): $1" >&2
  usage
  exit "$EX_USAGE"
}

# Shape-check the repo before spending a network call on it: `owner/name`,
# exactly one slash, both halves non-empty, no whitespace.
assert_repo_slug() {
  local repo="$1"
  case "$repo" in
    */*/*) die_usage "'$repo' is not a valid <owner/repo> slug — too many '/' separators" ;;
    */*)   ;;
    *)     die_usage "'$repo' is not a valid <owner/repo> slug — expected the form owner/name" ;;
  esac
  case "$repo" in
    /*|*/) die_usage "'$repo' is not a valid <owner/repo> slug — expected the form owner/name" ;;
    *[[:space:]]*) die_usage "'$repo' is not a valid <owner/repo> slug — contains whitespace" ;;
  esac
}

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

# A `continue-on-error: true` added to a step that ALREADY EXISTED on the base
# branch — the gate stays nominally in place while ceasing to fail (the #1139
# risk). The same flag on a step this PR is itself *adding* is NOT a narrowing
# signal: it relaxes nothing that existed before, and gate strength on the
# default branch after the merge is identical to before it (issue #1494).
#
# Attribution is per-step, walking the unified diff hunk-wise. For each added
# `continue-on-error: true` at indent K, the enclosing step is the nearest
# preceding YAML sequence-item marker (`- name:` / `- uses:` / `- run:` …) at
# an indent < K that is present in the NEW file (a context or added line).
# Deeper markers are nested lists (`with: { paths: [...] }`) and are skipped.
#
# Fail-safe direction is preserved in three places, all resolving toward 1:
#   * no enclosing marker in the hunk (the hunk starts mid-step) => cannot
#     attribute => count it;
#   * the enclosing marker is a context line => pre-existing step => count it;
#   * the enclosing ADDED marker replaces a removed marker at the same indent
#     within the same contiguous change block => a renamed/rewritten existing
#     step, not a new one => count it.
sig_continue_on_error_added() {
  printf '%s' "$1" | awk '
    BEGIN { blkgen = 1 }
    # File boundary: nothing carries across it.
    /^diff --git / { inhunk = 0; enc_set = 0; blkgen++; next }
    # Hunk boundary: lines are non-contiguous, so a marker seen in a previous
    # hunk is not necessarily the step this hunk starts inside.
    /^@@/          { inhunk = 1; enc_set = 0; blkgen++; next }
    !inhunk { next }
    {
      pfx = substr($0, 1, 1)
      if (pfx != "+" && pfx != "-" && pfx != " ") next   # e.g. "\ No newline..."
      body = substr($0, 2)
      match(body, /^ */); ind = RLENGTH

      # A context line closes the current contiguous change block.
      if (pfx == " ") blkgen++

      if (body ~ /^ *-[ \t]/) {                          # YAML sequence item
        if (pfx == "-") {
          blkrm[ind] = blkgen                            # step entry removed here
        } else if (enc_set == 0 || ind <= enc_ind) {
          enc_ind = ind
          enc_added = (pfx == "+" && blkrm[ind] != blkgen) ? 1 : 0
          enc_set = 1
        }
        next
      }

      if (pfx == "+" && body ~ /^ *continue-on-error:[ \t]*true[ \t]*$/) {
        if (enc_set && enc_ind < ind && enc_added) next   # MUTATION-ANCHOR-1494: deleting this line reproduces the #1494 false positive
        found = 1
      }
    }
    END { print (found ? 1 : 0) }
  '
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
  if [ "$#" -eq 0 ]; then
    die_usage "no arguments given — <owner/repo> and <pr-number> are both required"
  fi

  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --decide)
      if [ "$#" -ne 7 ]; then
        die_usage "--decide takes exactly 6 arguments, got $(( $# - 1 ))"
      fi
      decide "$2" "$3" "$4" "$5" "$6" "$7"
      exit 0
      ;;
    -*)
      # THE #1502 FIX. Never bind an unrecognized flag into `repo` and forward
      # it to `gh pr diff` — the resulting failure is misreported as `unknown`,
      # which callers treat as `narrowing`, so a caller error silently costs a
      # human-review clear on a PR that never needed one.
      die_usage "unrecognized flag '$1' — the target repo is a POSITIONAL argument; this script does not accept --repo"
      ;;
  esac

  if [ "$#" -ne 2 ]; then
    die_usage "expected exactly two arguments (<owner/repo> <pr-number>), got $#"
  fi

  local repo="$1" pr="$2"
  if [ -z "$repo" ]; then
    die_usage "the <owner/repo> argument is empty"
  fi
  assert_repo_slug "$repo"
  case "$pr" in
    ''|*[!0-9]*) die_usage "'$pr' is not a valid <pr-number> — expected a positive integer" ;;
  esac

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

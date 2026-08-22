#!/usr/bin/env bash
# detect-ungated-admin-direct-merge.sh — decide whether a PR against <owner/repo>
# is on the "ungated admin-direct-merge" path, where `gh pr merge --auto` does
# NOT queue behind CI but instead lands the PR *immediately*, before its own
# checks complete.
#
# This script is the SINGLE EXECUTABLE SOURCE OF TRUTH for that decision.
#
# Background (issues #438 / #465 / #598 / #602 / #645 / #716)
# ----------------------------------------------------------
# `gh pr merge --auto` is widely assumed to mean "queue this PR and merge it
# when CI goes green." That guarantee silently does not hold in two repo
# configurations, both of which cause an admin's `--auto` call to fall through
# to an *immediate direct merge*:
#
#   Shape 1 (#438): allow_auto_merge == false.
#     With repo-level auto-merge disabled there is no queue to arm, so gh
#     falls through to a direct merge.
#
#   Shape 2 (#465): the base branch has ZERO required status checks.
#     Fires REGARDLESS of allow_auto_merge. Even with allow_auto_merge: true,
#     with no *required* check gating the branch there is no pending check for
#     `--auto` to wait on — so the merge fires immediately.
#
# Either shape requires the caller to hold ADMIN or MAINTAIN (otherwise the
# direct-merge fall-through isn't permitted and `--auto` queues normally).
#
# On the ungated path the PR's own CI is the ONLY gate that exists, and
# `--auto` bypasses it — so the worker must re-create the gate by hand:
# wait for the PR's checks to settle, then merge only when green (#598).
#
# Why this is a SCRIPT and not prose (issue #716)
# -----------------------------------------------
# This condition previously existed as prose in TWO places — the worker-preamble
# `auto-merge.md` fragment (correct: two-shape) and `agents/issue-worker/
# issue-work.md` step 6 (WRONG: it restated the trigger as shape 1 only, and
# explicitly listed "repo allows auto-merge" as a *skip* condition). Because
# `auto-merge.md` is an on-demand fragment and `issue-work.md` is loaded by
# every issue-work worker, whichever copy a given worker happened to read
# decided whether the gate fired. The #716 repro: in one session, the worker on
# PR #713 loaded the fragment and correctly held for its checks, while the
# worker on PR #715 followed issue-work.md's prose, concluded "auto-merge isn't
# enabled on the repo" (it is: allow_auto_merge == true), and admin-direct-merged
# while CI was still IN_PROGRESS.
#
# A condition restated in prose in two files WILL drift. A condition that is one
# executable command cannot. Both call sites now invoke this script; neither
# restates the rule.
#
# Usage — live detection (the normal path):
#   bash detect-ungated-admin-direct-merge.sh <owner/repo>
#     -> prints `ungated` or `gated` on stdout; diagnostic signals on stderr.
#     -> exit 0 on a successful decision, 1 on an API error, 64 on a usage error.
#
#   The target repo is POSITIONAL. There is no `--repo` flag — passing one is a
#   usage error (exit 64), not an unreadable signal. See issue #1502.
#
#   `ungated` => do NOT run `gh pr merge --auto`. Block on
#                `gh pr checks <M> --watch --interval 30`, then merge only if green.
#   `gated`   => `gh pr merge --auto` genuinely queues behind CI. Arm it and return.
#
# Usage — pure decision (hermetic, for tests and for callers that already hold
# the three signals):
#   bash detect-ungated-admin-direct-merge.sh --decide <VIEWER_PERM> <ALLOW_AUTO_MERGE> <REQUIRED_CHECKS>
#
# Exit codes:
#   0 — a verdict was reached; stdout is `ungated` or `gated`.
#   1 — a WELL-FORMED call whose repo signals could not be read at all.
#  64 — usage error (EX_USAGE, per sysexits.h — the convention ~30 of this
#       repo's scripts already follow, e.g. session-state.sh, shipyard-config.sh,
#       detect-ci-runner-capacity.sh). stdout: `USAGE_ERROR: ...`; the full usage
#       block goes to stderr.
#
# Why 64 is separate from the fail-safe posture (issue #1502)
# ----------------------------------------------------------
# Resolving an unreadable signal toward `ungated` is the right default for this
# detector — but a malformed command line is not an unreadable signal, it is a
# bug in the invocation, and it is perfectly detectable. Before #1502 an
# unrecognized flag was bound straight into `repo` and forwarded, so
# `detect-ungated-admin-direct-merge.sh --repo owner/name` produced
# `gh api repos/--repo` and `gh repo view --repo`, and the script reported
# "could not read repo signals for '--repo'" — a caller error wearing the
# costume of a transient API/permission failure. This script is the surface
# CLAUDE.md designates as the executable source of truth a maintainer runs by
# hand, so it is the one most likely to be invoked ad hoc, from memory, by
# someone who has not read the signature. Same split #1492 made in
# verify-config-labels.sh.
#
# Fail-safe posture: any signal that cannot be read *from a well-formed call*
# resolves toward `ungated` (i.e. toward *waiting for CI*). Waiting when we
# didn't need to costs one worker's time; not waiting when we needed to lands a
# red commit on the default branch with no gate at all. The asymmetry is
# deliberate. A usage error is NOT laundered through that posture — it exits 64
# with an empty verdict so the caller fixes its call site rather than silently
# inheriting the conservative branch for the wrong reason.

set -uo pipefail

# EX_USAGE, per sysexits.h — the same convention session-state.sh,
# shipyard-config.sh and detect-ci-runner-capacity.sh already use for every
# bad-subcommand / missing-argument path.
EX_USAGE=64

usage() {
  echo "usage: $0 <owner/repo>" >&2
  echo "       $0 --decide <VIEWER_PERM> <ALLOW_AUTO_MERGE> <REQUIRED_CHECKS>" >&2
  echo "       $0 --help" >&2
  echo "note: the target repo is POSITIONAL — there is no --repo flag." >&2
}

# A caller error: the command line itself is wrong. Distinct from the API-error
# path below, which is for a well-formed call whose signals could not be read.
die_usage() {
  echo "USAGE_ERROR: $1"
  echo "detect-ungated-admin-direct-merge: usage error (exit $EX_USAGE): $1" >&2
  usage
  exit "$EX_USAGE"
}

# Shape-check the repo before spending a network call on it: `owner/name`,
# exactly one slash, both halves non-empty, no whitespace. A malformed repo slug
# is the same class of caller error as an unrecognized flag — cheaply
# detectable, and not something to launder into an API-error diagnostic.
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
# The decision. Pure function of the three signals — no I/O, no network.
# This is the whole rule; everything else in this file just feeds it.
# ---------------------------------------------------------------------------
decide() {
  local viewer_perm="$1" allow_auto_merge="$2" required_checks="$3"

  # Normalize. A non-numeric / empty required-checks reading means "we could not
  # determine that the branch is gated" — treat as 0 (ungated-leaning), matching
  # the fail-safe posture above.
  case "$required_checks" in
    ''|*[!0-9]*) required_checks=0 ;;
  esac
  viewer_perm="$(printf '%s' "$viewer_perm" | tr '[:lower:]' '[:upper:]')"

  # The direct-merge fall-through is only available to ADMIN / MAINTAIN. Without
  # it, `--auto` queues normally no matter how the repo is configured.
  case "$viewer_perm" in
    ADMIN|MAINTAIN) ;;
    *) printf 'gated\n'; return 0 ;;
  esac

  # Shape 1 (#438): no auto-merge queue exists to arm.
  # Shape 2 (#465): no required check exists to wait on — fires regardless of
  #                 allow_auto_merge. This is the shape that #716 regressed on.
  if [ "$allow_auto_merge" = "false" ] || [ "$required_checks" -eq 0 ]; then
    printf 'ungated\n'
    return 0
  fi

  printf 'gated\n'
}

# ---------------------------------------------------------------------------
# Signal (c): required status checks on the default branch.
#
# Classic branch protection and repository RULESETS are two SEPARATE gating
# mechanisms. The classic `protection/required_status_checks/contexts` endpoint
# does NOT see rulesets, so a ruleset-gated branch reads 0 there — a false
# "ungated" that would send the worker into an unnecessary --watch block (#645).
# So when the classic probe reads 0, ALSO probe the rulesets endpoint.
#
# Check ONLY the `required_status_checks` rule, NOT `pull_request`: a
# `pull_request` rule requires the change to arrive via a PR but does NOT gate
# the *merge* on CI, so an admin `--auto` still lands immediately on a ruleset
# that has `pull_request` but no `required_status_checks` (the
# mattsears18/shipyard shape: [deletion, non_fast_forward, pull_request]).
# Including `pull_request` here would over-gate that shape and falsely SKIP the
# protective wait — reintroducing the exact bug this file exists to prevent.
#
# The returned value is a real COUNT on BOTH paths (issue #1488). It used to be
# a count on the classic path but a bare boolean sentinel (`1`) on the ruleset
# path, printed under one count-shaped `required_checks=` label in either case —
# so this repo, whose `main` ruleset requires five contexts, reported
# `required_checks=1`. `decide()` only ever compares this against 0, so the
# verdict was always right; the DIAGNOSTIC under-reported, on a surface CLAUDE.md
# designates as the single executable source of truth a human reads during an
# incident. The `rules/branches/{branch}` response already carries every required
# context by name, so the true count costs no extra API call.
# ---------------------------------------------------------------------------
read_required_checks() {
  local repo="$1" branch="$2" count rules ruleset_count ruleset_gated

  count="$(gh api "repos/${repo}/branches/${branch}/protection/required_status_checks/contexts" \
    --jq 'length' 2>/dev/null)"
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac

  if [ "$count" -eq 0 ]; then
    # ONE fetch of the branch's effective rules; both reads below run against
    # this local copy, so the true-count read adds no second API call.
    rules="$(gh api "repos/${repo}/rules/branches/${branch}" 2>/dev/null)"

    # True count first. Same jq path detect-mutually-blocking-prs.sh's
    # read_required_check_names() already uses against this endpoint. `unique`
    # because two rulesets applying to the same branch can each require the
    # same context, and a human reads this as "how many distinct checks gate
    # main", not "how many rules mention one".
    ruleset_count="$(printf '%s' "$rules" | jq '
      [.[] | select(.type == "required_status_checks")
           | .parameters.required_status_checks[]?.context] | unique | length' 2>/dev/null)"
    case "$ruleset_count" in
      ''|*[!0-9]*) ruleset_count=0 ;;
    esac

    if [ "$ruleset_count" -gt 0 ]; then
      count="$ruleset_count"
    else
      # Boolean-sentinel floor, preserved verbatim from the pre-#1488 shape: a
      # `required_status_checks` rule whose context list is absent, empty, or
      # unreadable still resolves to 1. `decide()` only ever compares against 0,
      # so keeping the floor leaves the gated/ungated verdict byte-for-byte
      # unchanged — #1488 fixes the printed diagnostic, never the gate.
      ruleset_gated="$(printf '%s' "$rules" \
        | jq -r '[.[].type] | contains(["required_status_checks"]) | tostring' 2>/dev/null || echo false)"
      [ "$ruleset_gated" = "true" ] && count=1
    fi
  fi

  printf '%s' "$count"
}

main() {
  if [ "$#" -eq 0 ]; then
    die_usage "no arguments given — the target repo is required"
  fi

  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --decide)
      if [ "$#" -ne 4 ]; then
        die_usage "--decide takes exactly 3 arguments (<VIEWER_PERM> <ALLOW_AUTO_MERGE> <REQUIRED_CHECKS>), got $(( $# - 1 ))"
      fi
      decide "$2" "$3" "$4"
      exit 0
      ;;
    -*)
      # THE #1502 FIX. Never bind an unrecognized flag into `repo` and forward
      # it to `gh` — that produces a nonsense command line (`gh api repos/--repo`)
      # whose failure is then misreported as "could not read repo signals", i.e.
      # a caller error indistinguishable from a transient API failure.
      die_usage "unrecognized flag '$1' — the target repo is a POSITIONAL argument; this script does not accept --repo"
      ;;
  esac

  if [ "$#" -ne 1 ]; then
    die_usage "expected exactly one <owner/repo> argument, got $#"
  fi

  local repo="$1"
  if [ -z "$repo" ]; then
    die_usage "the <owner/repo> argument is empty"
  fi
  assert_repo_slug "$repo"

  local allow_auto_merge viewer_perm default_branch required_checks verdict

  # NOTE: allow_auto_merge is NOT exposed by `gh repo view --json` (there is no
  # autoMergeAllowed field). It must be read from the REST repo object.
  allow_auto_merge="$(gh api "repos/${repo}" --jq '.allow_auto_merge' 2>/dev/null)"
  viewer_perm="$(gh repo view "$repo" --json viewerPermission --jq '.viewerPermission' 2>/dev/null)"
  default_branch="$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"

  if [ -z "$viewer_perm" ] || [ -z "$default_branch" ]; then
    echo "detect-ungated-admin-direct-merge: could not read repo signals for '${repo}'" >&2
    exit 1
  fi

  required_checks="$(read_required_checks "$repo" "$default_branch")"
  verdict="$(decide "$viewer_perm" "$allow_auto_merge" "$required_checks")"

  {
    printf 'repo=%s default_branch=%s\n' "$repo" "$default_branch"
    printf 'viewer_permission=%s allow_auto_merge=%s required_checks=%s\n' \
      "$viewer_perm" "$allow_auto_merge" "$required_checks"
    if [ "$verdict" = "ungated" ]; then
      printf 'verdict=ungated -- "gh pr merge --auto" would land this PR IMMEDIATELY, before CI completes.\n'
      printf 'ACTION: do NOT arm --auto. Run "gh pr checks <M> --watch --interval 30", then merge only if green.\n'
    else
      printf 'verdict=gated -- "gh pr merge --auto" genuinely queues behind CI. Arm it normally.\n'
    fi
  } >&2

  printf '%s\n' "$verdict"
}

main "$@"

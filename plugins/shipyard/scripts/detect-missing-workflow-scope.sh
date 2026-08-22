#!/usr/bin/env bash
# detect-missing-workflow-scope.sh — decide whether to print the session-start
# preflight warning for a `gh` token missing the `workflow` OAuth scope
# (issue #818 — the PROACTIVE half of #812's reactive detection).
#
# Background (issue #812 / #818)
# -------------------------------
# GitHub blocks `enablePullRequestAutoMerge` for an OAuth-app token when the
# PR's diff touches `.github/workflows/*`, unless the token carries the
# `workflow` scope. `repo` alone is not enough. #812 taught the REACTIVE path
# (the worker discovers this at the first failed `gh pr merge --auto` call and
# emits the `auto-merge: unavailable — gh token lacks `workflow` scope` token
# / end-of-session banner). This script backs the PROACTIVE half: a one-time
# session-start warning, printed BEFORE the first workflow-touching PR is ever
# opened, when the session shape suggests one is likely this session.
#
# Two independent concerns, split so the DECISION LOGIC is unit-testable
# without a live gh/network call — same shape as
# detect-ungated-admin-direct-merge.sh's `--decide` mode:
#
#   --decide <has_workflow_scope:0|1> <workflow_signal:0|1>
#       Pure decision: prints "warn" or "silent". No network I/O. This is
#       what the regression test drives.
#
#   <owner/repo> [default-branch]
#       The target repo is POSITIONAL. There is no `--repo` flag — passing one
#       is a usage error (exit 64), not a signal that resolves toward "silent".
#       See issue #1502.
#
#       Live mode: reads `gh auth status` for the token's scope list, probes
#       two cheap signals for "this session looks likely to touch
#       .github/workflows/", and prints "warn" or "silent" to stdout:
#         (a) an open issue OR PR (GitHub's issue-search endpoint returns
#             both) whose title/body references `.github/workflows/`
#         (b) the default branch's most recent workflow run concluded
#             `failure` — a cheap proxy for "a fix-main-ci divert (which
#             routinely edits workflow files) is likely to fire this
#             session"; the canonical `main_ci.status` aggregate computed in
#             do-work/setup/04-backlog-divert.md#45 is deliberately NOT
#             re-derived here (that would be a second copy of that rule) —
#             this is a cheaper, narrower, single-call proxy good enough for
#             an advisory warning, not a dispatch decision.
#       Silent by default: has-scope short-circuits to "silent" without
#       spending either read; missing-scope-but-no-signal is also "silent".
#       Any read failure resolves toward "silent" — fail toward NOT warning.
#       A missed warning costs one avoidable auto-merge failure later in the
#       session, which #812's reactive path already surfaces; a FALSE warning
#       (or a network error surfaced as a hard failure) costs nothing but is
#       pure noise on the common case, which the issue's acceptance criteria
#       explicitly forbid.
#
# Exit codes:
#   0 — a verdict was reached; stdout is `warn` or `silent`.
#  64 — usage error (EX_USAGE, per sysexits.h — the convention ~30 of this
#       repo's scripts already follow). stdout: `USAGE_ERROR: ...`; the full
#       usage block goes to stderr.
#
# Why 64 does NOT fold into the fail-toward-silent posture (issue #1502)
# ----------------------------------------------------------------------
# "Any read failure resolves toward silent" is the right default for an
# advisory — but a malformed command line is not a read failure, it is a bug in
# the invocation, and it is perfectly detectable. Before #1502 an unrecognized
# flag was bound straight into REPO, so
# `detect-missing-workflow-scope.sh --repo owner/name` probed the repo `--repo`,
# both `gh` reads failed, and the script printed `silent` and exited 0 — a
# caller error laundered into a confident "no warning needed", which is the
# worst diagnostic outcome of the family: not a misattributed error, but a
# plausible wrong ANSWER. The empty-argument case is deliberately left on the
# silent path (a caller with nothing to give is a documented degrade, not a
# malformed call); a flag, an extra positional, or a malformed slug is not.
#
# Usage: commands/do-work/setup/01-repo-recovery.md's "1.35" preflight step.
set -u

# EX_USAGE, per sysexits.h — the same convention session-state.sh,
# shipyard-config.sh and detect-ci-runner-capacity.sh already use.
EX_USAGE=64

usage() {
  echo "usage: $0 <owner/repo> [default-branch]" >&2
  echo "       $0 --decide <has_workflow_scope:0|1> <workflow_signal:0|1>" >&2
  echo "       $0 --help" >&2
  echo "note: the target repo is POSITIONAL — there is no --repo flag." >&2
}

# A caller error: the command line itself is wrong. Distinct from every read
# failure below, which resolves toward `silent` by design.
die_usage() {
  echo "USAGE_ERROR: $1"
  echo "detect-missing-workflow-scope: usage error (exit $EX_USAGE): $1" >&2
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

decide() {
  local has_scope="$1" signal="$2"
  if [[ "$has_scope" == "1" ]]; then
    echo "silent"
    return
  fi
  if [[ "$signal" == "1" ]]; then
    echo "warn"
  else
    echo "silent"
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --decide)
    if [[ "$#" -ne 3 ]]; then
      die_usage "--decide takes exactly 2 arguments (<has_workflow_scope> <workflow_signal>), got $(( $# - 1 ))"
    fi
    decide "$2" "$3"
    exit 0
    ;;
  -*)
    # THE #1502 FIX. Never bind an unrecognized flag into REPO — the probes then
    # fail against a nonsense repo and the script prints a confident `silent`,
    # i.e. a caller error laundered into a plausible wrong answer.
    die_usage "unrecognized flag '$1' — the target repo is a POSITIONAL argument; this script does not accept --repo"
    ;;
esac

if [[ "$#" -gt 2 ]]; then
  die_usage "expected at most two arguments (<owner/repo> [default-branch]), got $#"
fi

case "${2:-}" in
  -*) die_usage "unrecognized flag '$2' in the [default-branch] position — this script takes positional arguments only" ;;
esac

REPO="${1:-}"
DEFAULT_BRANCH="${2:-}"

if [[ -z "$REPO" ]]; then
  # No repo to probe — fail toward silent rather than erroring the caller. This
  # stays a degrade, not a usage error (#1502): a caller with nothing to pass is
  # a documented shape, unlike a flag or a malformed slug.
  echo "silent"
  exit 0
fi

assert_repo_slug "$REPO"

# --- Does the token already carry `workflow`? ---
GH_AUTH_STATUS="$(gh auth status 2>&1 || true)"
HAS_SCOPE=0
if printf '%s' "$GH_AUTH_STATUS" | grep -q "Token scopes:.*'workflow'"; then
  HAS_SCOPE=1
fi

if [[ "$HAS_SCOPE" == "1" ]]; then
  echo "silent"
  exit 0
fi

# --- Does the session shape suggest workflow-touching work is likely? ---
SIGNAL=0

ISSUE_HIT=$(gh api search/issues \
  -f q="repo:${REPO} is:open \".github/workflows\" in:body,title" \
  --jq '.total_count' 2>/dev/null || echo 0)
[[ "$ISSUE_HIT" =~ ^[0-9]+$ ]] || ISSUE_HIT=0
if [[ "$ISSUE_HIT" -gt 0 ]]; then
  SIGNAL=1
fi

if [[ "$SIGNAL" == "0" && -n "$DEFAULT_BRANCH" ]]; then
  LATEST_CONCLUSION=$(gh run list --repo "$REPO" --branch "$DEFAULT_BRANCH" \
    --limit 1 --json conclusion --jq '.[0].conclusion // "unknown"' 2>/dev/null || echo unknown)
  if [[ "$LATEST_CONCLUSION" == "failure" ]]; then
    SIGNAL=1
  fi
fi

decide "$HAS_SCOPE" "$SIGNAL"

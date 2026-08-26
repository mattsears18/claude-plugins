#!/usr/bin/env bash
# commit-subject-scan.sh — fail if any commit subject on a branch violates the
# Conventional Commits grammar, with a scratch `wip:` prefix tolerated on
# non-final commits but never on the final one.
#
# Background (issues #1410 / #1412): GitHub's squash-merge uses the SOLE
# commit's subject when a PR has exactly one commit — the PR title is only the
# squash-message default at two or more commits. A worker that writes a
# correct, Conventional-Commits-compliant PR title but leaves a throwaway
# commit subject unamended ships that throwaway subject to the default branch
# verbatim. Every visible surface looks right up to the moment of merge (title
# correct, auto-merge armed, CI green) and the defect only surfaces in
# `git log` afterward, unfixable without a history rewrite the branch ruleset
# forbids.
#
# Concrete repro (#1408): the PR title was the fully-compliant
# `fix(scripts): shipped-immediate-branch-reap.sh reported reaped=true on a
# failed removal (closes #1404)`, but its single commit was subject-prefixed
# `wip:`. On squash-merge `main` got `wip: fix false-success reaped=true in
# shipped-immediate-branch-reap.sh (#1404) (#1408)` — a subject that parses as
# none of major/minor/patch under Conventional-Commits-driven release tooling,
# and that no existing gate (`conflict markers`, `gitleaks`, the test suites,
# `shellcheck`) inspects.
#
# `skills/worker-preamble/commit-hygiene.md` § "Final commit subject" shipped
# the prose rule in #1410. This script is the mechanical counterpart, in the
# same family as `conflict-marker-scan.sh` / `compound-block-scan.sh`: a check
# that catches the defect regardless of whether the worker read or internalized
# the prose.
#
# Usage:
#   bash plugins/shipyard/scripts/commit-subject-scan.sh
#   bash plugins/shipyard/scripts/commit-subject-scan.sh <base-ref>
#   bash plugins/shipyard/scripts/commit-subject-scan.sh <base-ref> <head-ref>
#
#   <base-ref>  exclusive lower bound. Defaults to the first of `origin/HEAD`,
#               `origin/main`, `origin/master`, `main`, `master` that resolves.
#   <head-ref>  inclusive upper bound. Defaults to `HEAD`.
#
# The scanned range is `<base-ref>..<head-ref>` — the commits this branch adds
# on top of the base, i.e. exactly what a squash-merge would collapse.
#
# CI note: this IS wired as a `pull_request` check — the "Conventional Commits
# subject scan" step in `.github/workflows/tests.yml`, inside the already-
# required `bash test suites` job (issue #1534). Two properties of that wiring
# are load-bearing and must survive any edit:
#   * `fetch-depth: 0` on the checkout. `actions/checkout` defaults to depth 1,
#     which leaves the base commit unavailable and the range unresolvable
#     (exit 2 — loud, but it means nothing is being scanned).
#   * The head bound is the PR's `head.sha`, NOT the ambient `HEAD`. Under a
#     `pull_request` checkout `HEAD` is `refs/pull/<N>/merge`, a git-generated
#     test-merge commit; using it as <head-ref> would make THAT the "final"
#     commit and silently tolerate a `wip:` subject on the PR's real last one.
# `plugins/shipyard/scripts/tests/commit-subject-scan.test.sh` section (12)
# pins both.
#
# Recognized types default to the Conventional Commits v1.0.0 conventional
# set. Override with COMMIT_SUBJECT_SCAN_TYPES (space- or comma-separated) for
# a repo with its own vocabulary. `wip` is deliberately NOT in the default set
# — that is what makes the final-vs-non-final distinction meaningful.
#
# Exempt from the grammar check (both reported as skips, never as passes):
#   * git-generated merge subjects (`Merge branch ...`, `Merge pull request ...`,
#     `Merge remote-tracking branch ...`) — git writes these, not the author.
#     Also GitHub's PR test-merge subject (`Merge <sha> into <sha>`), which is
#     what `refs/pull/<N>/merge` is checked out as in CI — the shape a scan
#     running on a pull_request event actually sees at the tip of its range.
#   * git-generated revert subjects (`Revert "..."`) — likewise.
#
# Exit status: 0 = every subject clean, 1 = violation(s) found (prints
# `<short-sha>\t<subject>` plus the reason for each), 2 = usage / environment
# error (not in a git repo, unresolvable ref, empty type list).

set -u

DEFAULT_TYPES='build chore ci docs feat fix perf refactor revert style test'

# A scratch subject: the sanctioned worktree-local substitute for `git stash`
# (see skills/worker-preamble/git-stash-prohibition.md). Fine as a transient
# local convenience on a non-final commit; never what ships.
WIP_RE='^wip:'

# Subjects git itself authors. Anchored so an ordinary subject that merely
# starts with the word (`Merge the two code paths`) is NOT exempted — either a
# trailing keyword or the anchored `<sha> into <sha>` shape is what makes these
# git-generated. The hex-only, end-anchored second alternative is what keeps
# prose like `Merge the login and signup flows into one` on the checked path.
MERGE_RE='^Merge ((branch|pull request|remote-tracking branch|tag|commit) |[0-9a-f]{7,40} into [0-9a-f]{7,40}$)'
REVERT_RE='^Revert "'

usage() {
  cat >&2 <<'EOF'
usage: commit-subject-scan.sh [<base-ref> [<head-ref>]]
  Asserts every commit subject in <base-ref>..<head-ref> matches the
  Conventional Commits grammar (<type>(<scope>)?!?: <description>).
  A `wip:` prefix is tolerated on non-final commits but never on the
  final (squash-merge) commit.

  <base-ref>  defaults to origin/HEAD, origin/main, origin/master,
              main, or master — whichever resolves first.
  <head-ref>  defaults to HEAD.

  COMMIT_SUBJECT_SCAN_TYPES overrides the recognized type list
  (space- or comma-separated).

  Exit: 0 clean, 1 violation(s) found, 2 usage/environment error.
  --help itself always exits 0 (#1550).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [[ $# -gt 2 ]]; then
  echo "commit-subject-scan: too many arguments" >&2
  usage
  exit 2
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "commit-subject-scan: not inside a git work tree" >&2
  exit 2
fi

# Build the type alternation from the configured list.
types_raw="${COMMIT_SUBJECT_SCAN_TYPES:-$DEFAULT_TYPES}"
types_raw="${types_raw//,/ }"
type_alt=''
for t in $types_raw; do
  [[ -z "$t" ]] && continue
  if [[ -n "$type_alt" ]]; then
    type_alt="$type_alt|$t"
  else
    type_alt="$t"
  fi
done
if [[ -z "$type_alt" ]]; then
  echo "commit-subject-scan: COMMIT_SUBJECT_SCAN_TYPES resolved to an empty type list" >&2
  exit 2
fi

# Conventional Commits v1.0.0: <type>[(<scope>)][!]: <description>
# The `: ` (colon-space) and the non-empty description are both required, so
# `fix:` and `fix:no-space` are rejected the same way an unknown type is.
CC_RE="^(${type_alt})(\([^()]+\))?!?: .+"

# ---------------------------------------------------------------------------
# Resolve the range.
# ---------------------------------------------------------------------------

resolve_ref() {
  git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null
}

base_ref="${1:-}"
head_ref="${2:-HEAD}"

if [[ -z "$base_ref" ]]; then
  for candidate in origin/HEAD origin/main origin/master main master; do
    if resolve_ref "$candidate" >/dev/null; then
      base_ref="$candidate"
      break
    fi
  done
  if [[ -z "$base_ref" ]]; then
    echo "commit-subject-scan: could not auto-detect a base ref (tried origin/HEAD, origin/main, origin/master, main, master)." >&2
    echo "Pass one explicitly: commit-subject-scan.sh <base-ref> [<head-ref>]" >&2
    exit 2
  fi
fi

if ! resolve_ref "$base_ref" >/dev/null; then
  echo "commit-subject-scan: base ref '$base_ref' does not resolve to a commit" >&2
  exit 2
fi

final_sha="$(resolve_ref "$head_ref")"
if [[ -z "$final_sha" ]]; then
  echo "commit-subject-scan: head ref '$head_ref' does not resolve to a commit" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Walk the range.
# ---------------------------------------------------------------------------

shas=()
subjects=()
while IFS=$'\x1f' read -r sha subject; do
  [[ -z "$sha" ]] && continue
  shas+=("$sha")
  subjects+=("$subject")
done < <(git log --format='%H%x1f%s' "$base_ref..$head_ref" 2>/dev/null)

if [[ ${#shas[@]} -eq 0 ]]; then
  # Not a pass in any meaningful sense — say so explicitly rather than
  # printing the same "clean" line a real scan prints, so an empty range
  # (a mis-specified base, a branch already merged) is visible rather than
  # silently vacuous.
  echo "commit-subject-scan: no commits in range $base_ref..$head_ref — nothing to scan."
  exit 0
fi

violations=0
skipped=0
scanned=0

for i in "${!shas[@]}"; do
  sha="${shas[$i]}"
  subject="${subjects[$i]}"
  short="${sha:0:12}"

  if [[ $subject =~ $MERGE_RE ]] || [[ $subject =~ $REVERT_RE ]]; then
    skipped=$((skipped + 1))
    continue
  fi

  scanned=$((scanned + 1))

  if [[ $subject =~ $CC_RE ]]; then
    continue
  fi

  if [[ $subject =~ $WIP_RE ]]; then
    if [[ "$sha" == "$final_sha" ]]; then
      printf '%s\t%s\n' "$short" "$subject"
      echo "  ^ FINAL commit carries a scratch 'wip:' subject. GitHub's squash-merge"
      echo "    uses this subject verbatim on a single-commit PR — amend it before"
      echo "    pushing: git commit --amend -m '<type>(<scope>): <description>'"
      violations=$((violations + 1))
    else
      # Tolerated: a transient scratch commit that is not what squash-merge
      # will use. Reported on stderr so it stays visible without failing.
      printf 'commit-subject-scan: note: %s carries a tolerated scratch subject on a non-final commit: %s\n' \
        "$short" "$subject" >&2
    fi
    continue
  fi

  printf '%s\t%s\n' "$short" "$subject"
  echo "  ^ subject does not match the Conventional Commits grammar"
  echo "    (<type>(<scope>)?!?: <description>); recognized types: ${type_alt//|/, }"
  violations=$((violations + 1))
done

if [[ "$violations" -gt 0 ]]; then
  echo >&2
  echo "commit-subject-scan: $violations non-conforming commit subject(s) in $base_ref..$head_ref." >&2
  echo "Amend or squash them before merging (issues #1410 / #1412)." >&2
  exit 1
fi

echo "commit-subject-scan: $scanned commit subject(s) conform in $base_ref..$head_ref (${skipped} git-generated subject(s) skipped)."
exit 0

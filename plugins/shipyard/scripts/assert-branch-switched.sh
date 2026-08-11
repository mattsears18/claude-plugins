#!/usr/bin/env bash
# assert-branch-switched.sh — a cheap, generic predicate for "has this worker
# actually switched off the harness-provided placeholder branch onto the
# branch its dispatch requires (or landed on detached HEAD, for the modes
# that use that instead of a named branch)?"
#
# Background (issue #1258)
# -------------------------
# Every /shipyard:do-work worker mode's spec has a "sync + branch" step that
# reads as narrative prose sandwiched between "read the issue" and
# "implement" — unlike the step-0 worktree-cwd check (assert-worktree-cwd.sh),
# nothing forces a worker to actually VERIFY the branch switch took effect
# before its first Edit/Write call. #1258's repro: a worker loaded the full
# issue-work.md spec up front, had the branch-checkout step in context the
# whole time, and still drifted from "read the issue" straight into
# implementation on the harness's own placeholder branch
# (`worktree-agent-<id>` — see worktree-reap.sh's header comment for the full
# background on that naming convention) — never running `git checkout -B
# do-work/issue-<N>` at all. The gap wasn't missing information, it was the
# absence of a concrete, checkable gate at the exact point drift happens.
#
# This script is that gate. It does NOT itself switch branches or fix
# anything — like assert-worktree-cwd.sh, it is a PURE PREDICATE the calling
# spec invokes at a structurally-mandatory checkpoint (issue-work.md wires it
# in as the first action of its "Implement" step, immediately before the
# first Edit/Write a dispatch would make) and branches on the verdict.
#
# Usage:
#   assert-branch-switched.sh <DIR> <EXPECTED_BRANCH>
#   assert-branch-switched.sh <DIR> --detached
#
#   DIR              the worktree path to check (never omitted — always pass
#                     the caller's own re-derived WORKTREE_PATH explicitly,
#                     per worker-preamble's mid-session cwd-anchoring rule;
#                     this script does not default to '.').
#   EXPECTED_BRANCH   the exact branch name this dispatch's mode requires
#                     (e.g. `do-work/issue-1258`, `do-work/fix-main-ci-abc123`).
#                     Compared verbatim against `git branch --show-current`.
#   --detached        for modes that intentionally land on detached HEAD
#                     instead of a named branch (fix-checks-only, fix-rebase —
#                     see those files' "detached HEAD, not a named-branch
#                     checkout" rationale, issue #966). Verdict is `match`
#                     when HEAD has no branch name at all, `mismatch` when
#                     it's still sitting on ANY named branch (almost always
#                     the harness placeholder).
#
#   -> exit 0, prints `match`    on stdout: the worktree is on the branch (or
#      detached HEAD) this dispatch's mode actually requires. Healthy,
#      common-case path once the dispatch has done its branch setup — no-op
#      for the caller.
#   -> exit 1, prints `mismatch` on stdout: the worktree is NOT on the
#      expected branch/state. The caller MUST stop before its first
#      Edit/Write and complete its branch-setup step first — see the calling
#      spec's own wording for the exact `blocked:`/retry phrasing, this
#      script only supplies the verdict.
#   -> exit 2, prints `error`    on stdout: DIR does not resolve to a git
#      working tree at all (missing dir, not inside any git repo, or the
#      underlying `git` reads themselves failed).
#
#   Full diagnostics (dir/toplevel/actual-branch/expected/verdict) always go
#   to stderr, mirroring assert-worktree-cwd.sh's stdout-terse/stderr-
#   diagnostic convention.
#
# Fail-safe posture: matches assert-worktree-cwd.sh — any signal that can't
# be read resolves toward the stricter outcome (`error`/`mismatch`), never
# toward silently reporting `match`. A false `match` here is the one outcome
# that lets the exact #1258 failure mode run to completion undetected.

set -u

usage() {
  cat >&2 <<'EOF'
usage: assert-branch-switched.sh <DIR> <EXPECTED_BRANCH>
       assert-branch-switched.sh <DIR> --detached

  DIR is required — always the caller's own re-derived worktree path, never
  defaulted. EXPECTED_BRANCH is compared verbatim against the current branch
  name; --detached instead asserts HEAD carries no branch name at all.

  Prints `match` (exit 0) if DIR is on the expected branch/state, `mismatch`
  (exit 1) if it is on something else (most often still the harness
  placeholder branch, worktree-agent-<id>), or `error` (exit 2) if DIR
  doesn't resolve to a git working tree at all. Full diagnostics always go to
  stderr.

  See the header comment in this file for the #1258 background.
EOF
  exit 2
}

case "${1:-}" in
  -h|--help) usage ;;
esac

dir="${1:-}"
expected="${2:-}"

if [ -z "$dir" ] || [ -z "$expected" ]; then
  usage
fi

toplevel="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$toplevel" ]; then
  {
    echo "assert-branch-switched: '$dir' does not resolve to a git working tree"
    echo "(git rev-parse --show-toplevel failed against it)"
  } >&2
  printf 'error\n'
  exit 2
fi

# `git branch --show-current` prints the branch name, or nothing at all when
# HEAD is detached. Unlike `git rev-parse --abbrev-ref HEAD` (which prints
# the literal string "HEAD" when detached), this gives us a clean empty-
# string signal for the --detached comparison below.
actual="$(git -C "$dir" branch --show-current 2>/dev/null)"

{
  printf 'dir=%s toplevel=%s\n' "$dir" "$toplevel"
  printf 'actual-branch=%s expected=%s\n' "${actual:-<detached>}" "$expected"
} >&2

if [ "$expected" = "--detached" ]; then
  if [ -z "$actual" ]; then
    echo "verdict=match -- HEAD is detached, as this mode requires." >&2
    printf 'match\n'
    exit 0
  fi
  echo "verdict=mismatch -- expected detached HEAD but a named branch ('$actual') is checked out." >&2
  printf 'mismatch\n'
  exit 1
fi

if [ "$actual" = "$expected" ]; then
  echo "verdict=match -- on the expected branch." >&2
  printf 'match\n'
  exit 0
fi

placeholder_note=""
case "$actual" in
  worktree-agent-*)
    placeholder_note=" ('$actual' is the harness-provided placeholder branch — this dispatch has not switched onto its own branch yet, see issue #1258)"
    ;;
esac

echo "verdict=mismatch -- on '$actual', expected '$expected'.${placeholder_note}" >&2
printf 'mismatch\n'
exit 1

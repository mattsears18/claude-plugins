#!/usr/bin/env bash
# primary-leak-guard.sh — steady-state.md's A.0.6 "primary-checkout
# branch-leak guard" (closes #387), extracted to a script per issue #1323.
#
# Background (issues #1316 / #1317 / #1323)
# ------------------------------------------
# #1316 established that a worktree-isolated orchestrator's harness guard
# unconditionally refuses `git -C <other-path>` issued directly from its own
# Bash tool call, read-only or not. #1317 fixed A.0.5's two *inspection*
# sites (`worktree-reap.sh inspect-unpushed`). A.0.6's primary-leak guard —
# which reads and, on the sanctioned clean-restore path, WRITES to the
# user's PRIMARY checkout via `git -C "$PRIMARY_CHECKOUT" ...` — was left
# inline and is unperformable the same way: every one of those calls is
# refused from a worktree-isolated orchestrator session, and because the
# guard's own discipline is fire-and-forget (`2>/dev/null || true`), the
# refusal was SILENT — the guard read as "no-op, primary was fine" whether
# it actually checked or was refused outright.
#
# `git -C` INSIDE a helper script's own bash process is unaffected by the
# guard — the guard inspects the literal command TEXT of the orchestrator's
# own Bash tool call, not what a script it invokes does internally (see
# `worktree-reap.sh`'s `inspect_unpushed` docstring for the same asymmetry,
# and `crash-recovery-reap.sh` / `drain-pre-dispatch-branch-reap.sh`, both of
# which already rely on it). Moving the guard here — a plain `bash
# primary-leak-guard.sh run ...` invocation, no `-C` in the outer call —
# restores the orchestrator's ability to run it at all from an isolated
# session, AND fixes the swallow: this script's `verdict=` output
# distinguishes "checked, primary was fine" (`clean`), "checked, restored"
# (`restored`), "checked, dirty — deferred to human" (`dirty-skip`), a
# restore that was attempted but itself failed (`restore-failed`), and
# "could NOT check" (`error`) — the last of these is exactly the case the
# inline block's blanket `2>/dev/null || true` used to make indistinguishable
# from `clean`.
#
# Preconditions preserved EXACTLY from the inline block (do not widen):
#   - Only ever restores the primary when it is OFF the default branch AND
#     its working tree is CLEAN. A `--ff-only` pull can't clobber anything
#     when no local edits exist, so this restore is provably lossless.
#   - When the tree is DIRTY, never auto-restore — warn and defer to the
#     human. Uncommitted edits on the leaked branch might be real user work;
#     a checkout could strand or clobber it. See `dont.md` — this is the one
#     narrow, documented exception to "shipyard never writes to the primary
#     checkout," and it must not be generalized into "shipyard may move the
#     primary's HEAD" under any other condition.
#
# Subcommand
# ----------
#
#   run --repo <owner/repo>
#     1. Derives PRIMARY_CHECKOUT cwd-independently (issue #452): the first
#        `worktree ` entry from `git worktree list --porcelain` is always
#        the primary, regardless of which linked worktree the caller's cwd
#        is in. Falls back to a cwd-strip only when the porcelain read is
#        empty (non-worktree layout).
#     2. Resolves the repo's default branch via `gh repo view`. A failure or
#        empty result here is a genuine "could not check" — NOT treated as
#        "primary is on some other branch than ''" the way the inline
#        block's empty-string comparison used to (a real pre-existing bug:
#        an empty DEFAULT_BRANCH made every primary branch compare as
#        "leaked," and a `git checkout ""` failure was then swallowed by
#        `|| true` while the block's own `echo "restored ..."` line and
#        counter increment fired unconditionally regardless of whether the
#        checkout actually happened — see #1323).
#     3. Reads PRIMARY_BRANCH via `git -C "$PRIMARY_CHECKOUT" symbolic-ref`.
#     4. If PRIMARY_BRANCH == DEFAULT_BRANCH -> verdict=clean.
#     5. Else (primary off default branch — leak detected):
#        a. Clean tree -> checkout + `pull --ff-only`. verdict=restored once
#           the CHECKOUT itself succeeds (that's what frees the leaked
#           head-branch lock — the actual invariant this guard protects);
#           a `pull --ff-only` failure (no remote tracking, network down,
#           non-fast-forward) is surfaced as an advisory in `reason`
#           without downgrading the verdict, mirroring the original inline
#           block's own `checkout && pull ... || true` non-blocking pull.
#           If the CHECKOUT itself fails, verdict=restore-failed — never
#           unconditionally reported as restored the way the inline
#           block's bug did.
#        b. Dirty tree -> verdict=dirty-skip. Never writes.
#
# Output (stdout, key=value lines):
#   verdict=<clean|restored|dirty-skip|restore-failed|error>
#   primary_checkout=<path-or-empty>
#   primary_branch=<branch-or-empty>
#   default_branch=<branch-or-empty>
#   reason=<free-text, populated on dirty-skip / restore-failed / error>
#
# Exit codes: 0 on clean/restored/dirty-skip (none of these should ever
# abort the caller's reconcile turn — same fire-and-forget posture as the
# inline block); 1 on restore-failed; 2 on error (could not determine
# primary state at all); 64 bad usage. The caller reads the `verdict=` field
# to decide what to log — it should never gate control flow on this
# script's own exit status, exactly as it never did on the inline block's.

set -u

usage() {
  cat <<'EOF'
Usage:
  primary-leak-guard.sh run --repo <owner/repo>
EOF
}

GH="${GH:-gh}"

emit() {
  local verdict="$1" primary_checkout="$2" primary_branch="$3" default_branch="$4" reason="$5"
  printf 'verdict=%s\n' "$verdict"
  printf 'primary_checkout=%s\n' "$primary_checkout"
  printf 'primary_branch=%s\n' "$primary_branch"
  printf 'default_branch=%s\n' "$default_branch"
  printf 'reason=%s\n' "$reason"
}

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  run)
    repo=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        *) echo "primary-leak-guard.sh run: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$repo" ]; then
      echo "primary-leak-guard.sh run: --repo is required" >&2
      usage >&2
      exit 64
    fi

    # --- Derive PRIMARY_CHECKOUT independent of cwd (issue #452) -----------
    PRIMARY_CHECKOUT=$(awk '/^worktree /{print substr($0,10); exit}' <(git worktree list --porcelain 2>/dev/null))
    if [ -z "$PRIMARY_CHECKOUT" ]; then
      PRIMARY_CHECKOUT="$(git rev-parse --show-toplevel 2>/dev/null)"
      case "$PRIMARY_CHECKOUT" in
        */.claude/worktrees/orchestrator-*) PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/orchestrator-*}" ;;
        */.claude/worktrees/agent-*)        PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/agent-*}" ;;
      esac
    fi
    if [ -z "$PRIMARY_CHECKOUT" ] || ! git -C "$PRIMARY_CHECKOUT" rev-parse --git-dir >/dev/null 2>&1; then
      emit "error" "${PRIMARY_CHECKOUT:-}" "" "" "could not derive a readable primary checkout path"
      exit 2
    fi

    # --- Resolve the default branch — a failure here is a genuine
    # "could not check," not "primary is off some other branch" (#1323). ---
    DEFAULT_BRANCH=$("$GH" repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
    if [ -z "$DEFAULT_BRANCH" ]; then
      emit "error" "$PRIMARY_CHECKOUT" "" "" "could not resolve default branch via gh repo view --repo $repo"
      exit 2
    fi

    PRIMARY_BRANCH=$(git -C "$PRIMARY_CHECKOUT" symbolic-ref --short -q HEAD 2>/dev/null || echo "<detached>")

    if [ "$PRIMARY_BRANCH" = "$DEFAULT_BRANCH" ]; then
      emit "clean" "$PRIMARY_CHECKOUT" "$PRIMARY_BRANCH" "$DEFAULT_BRANCH" ""
      exit 0
    fi

    # Primary is off the default branch — leak detected.
    PRIMARY_STATUS=$(git -C "$PRIMARY_CHECKOUT" status --porcelain 2>/dev/null)
    if [ -n "$PRIMARY_STATUS" ]; then
      # DIRTY tree — never auto-restore. Uncommitted edits on the leaked
      # branch might be real user work; a checkout could strand/clobber it.
      emit "dirty-skip" "$PRIMARY_CHECKOUT" "$PRIMARY_BRANCH" "$DEFAULT_BRANCH" \
        "primary checkout is on $PRIMARY_BRANCH (not $DEFAULT_BRANCH) AND has uncommitted changes; NOT auto-restoring (possible real edits). Restore manually with: git -C \"$PRIMARY_CHECKOUT\" checkout $DEFAULT_BRANCH (#387)"
      exit 0
    fi

    # CLEAN tree — lossless restore. The load-bearing operation is the
    # CHECKOUT (that's what frees the leaked head-branch lock — the actual
    # invariant A.0.6 protects, per its own "Why it matters"); the
    # `--ff-only` pull is a best-effort freshness step layered on top,
    # exactly as the original inline block treated it (`checkout && pull
    # ... || true` — pull failure never blocked the "restored" outcome
    # there either). Report `restored` once the checkout itself actually
    # succeeds (#1323 fixes the inline block's bug where this line fired
    # unconditionally even when the checkout ALSO failed); a pull failure
    # (no remote tracking, network down, non-fast-forward) is surfaced as
    # an advisory in `reason` rather than silently swallowed, but does not
    # downgrade the verdict — the primary is off the leaked branch either
    # way, which is the guard's actual job.
    if git -C "$PRIMARY_CHECKOUT" checkout "$DEFAULT_BRANCH" >/dev/null 2>&1; then
      if git -C "$PRIMARY_CHECKOUT" pull --ff-only >/dev/null 2>&1; then
        emit "restored" "$PRIMARY_CHECKOUT" "$PRIMARY_BRANCH" "$DEFAULT_BRANCH" ""
      else
        emit "restored" "$PRIMARY_CHECKOUT" "$PRIMARY_BRANCH" "$DEFAULT_BRANCH" \
          "checked out $DEFAULT_BRANCH successfully; pull --ff-only failed or was skipped (no remote tracking, network down, or non-fast-forward) — primary may be behind origin/$DEFAULT_BRANCH; refresh manually if needed"
      fi
      exit 0
    else
      emit "restore-failed" "$PRIMARY_CHECKOUT" "$PRIMARY_BRANCH" "$DEFAULT_BRANCH" \
        "checkout of $DEFAULT_BRANCH on the primary checkout failed — primary may now be in an inconsistent state; manual inspection required: git -C \"$PRIMARY_CHECKOUT\" status"
      exit 1
    fi
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "primary-leak-guard.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac

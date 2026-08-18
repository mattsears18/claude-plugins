#!/usr/bin/env bash
# resolve-manifest-only-dirty.sh — resolve a DIRTY PR in-process, without
# dispatching a full fix-rebase worker, when the rebase is either clean or
# conflicts ONLY on the version-coordinated manifest `.version` row (+
# optionally the top-of-file CHANGELOG entry).
#
# Background (issue #1377). On a `version_coordination`-enabled repo whose
# release convention bumps a shared manifest row on every merge (this repo's
# own "ALWAYS cut a release when a PR merges" rule), a sibling PR merging
# while another is still in flight DIRTYs the second PR's manifest/CHANGELOG
# rows — not a race, a structural consequence of allocating a version at
# dispatch time. `agents/issue-worker/fix-rebase.md` §4.6 already resolves
# this deterministically (take main's version, bump at the PR's release
# level to the next free slot, re-number the CHANGELOG heading, place
# newest-first) — but paying for a full worker dispatch (a fresh isolated
# worktree, an agent turn, a model call) to run a two-line renumber is
# expensive: one measured session spent 8 of 25 dispatches (~32%, ~1.11M
# input tokens) on exactly this. This script is the orchestrator's own
# in-process shortcut for the common, cheap case; a manifest/CHANGELOG
# resolution here is functionally identical to what the worker would have
# produced, so the caller treats a `resolved` exit as equivalent to a
# `rebased #<M>` worker return. Anything wider than the recognized case
# defers to the normal fix-rebase dispatch — this script never attempts a
# semantic merge.
#
# This also covers the DEFAULT_BRANCH != coordinated case for free: any
# DIRTY PR whose rebase turns out to be conflict-free once actually
# attempted (GitHub's cached mergeStateStatus can be stale) is resolved and
# pushed here too, with no manifest/CHANGELOG config required at all.
#
# Design — an EPHEMERAL, NESTED git worktree, not the caller's own checkout.
# The orchestrator (or, via a hand-invocation, a fix-rebase-adjacent context)
# calls this script from ITS OWN worktree/cwd, which must stay untouched —
# this script never changes the caller's checked-out branch. It creates a
# short-lived `git worktree add --detach` under --scratch-root (default
# .shipyard-scratch/, already self-ignored by worker-preamble convention),
# does all rebase/resolve/verify/push work there, and removes it before
# returning — success or failure. Nested worktrees under an existing linked
# worktree are ordinary git and were confirmed to work in this environment.
#
# Usage:
#   resolve-manifest-only-dirty.sh resolve --repo <owner/repo> --pr <M>
#       --head-ref <headRefName> --default-branch <branch>
#       [--manifest <path>] [--version-jq <jq-expr>] [--changelog <path>]
#       [--scratch-root <path>]
#
# --manifest / --version-jq / --changelog are optional — omit them (or pass
# empty strings) when `version_coordination` isn't enabled on this repo. A
# clean rebase is still attempted and pushed; only an ACTUAL conflict on the
# manifest/CHANGELOG rows requires them to be set, and their absence in that
# case is treated as "can't resolve this conflict" (deferred), not a script
# error.
#
# Exit status / stdout (exactly one line):
#   0  resolved pr=<M> version=<next-free-or-empty> head=<new-sha>
#      The rebase (clean, or a recognized manifest/CHANGELOG conflict) was
#      resolved and force-pushed. Caller should treat this exactly like a
#      `rebased #<M>` fix-rebase worker return — no worker dispatch needed.
#   1  deferred reason=<short-code>: <detail>
#      Could not resolve in-process (PR no longer DIRTY, conflict extends
#      beyond the recognized set, a safety-net check tripped, or the push
#      lease was rejected). Caller falls back to the normal fix-rebase
#      dispatch — nothing was pushed, and any local rebase state was
#      aborted and cleaned up.
#   2  deferred reason=script-error: <detail>
#      Usage error or a missing required tool. Caller treats identically to
#      exit 1 (fall back to worker dispatch); the distinct code is only so a
#      human reading logs can tell a real conflict apart from an
#      environment problem.
#
# Never left behind: the ephemeral worktree is removed via a trap on every
# exit path, and `git rebase --abort` runs before any bail that leaves the
# ephemeral worktree mid-rebase.

set -u
export LC_ALL=C
# Never pop an interactive editor for `git rebase --continue` — this script
# always resolves conflicts by staging content directly, never by writing a
# commit message.
export GIT_EDITOR=true

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "$here/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  resolve-manifest-only-dirty.sh resolve --repo <owner/repo> --pr <M>
      --head-ref <headRefName> --default-branch <branch>
      [--manifest <path>] [--version-jq <jq-expr>] [--changelog <path>]
      [--scratch-root <path>]
EOF
}

defer() {
  # $1: short reason code, $2: human detail
  printf 'deferred reason=%s: %s\n' "$1" "$2"
  exit 1
}

script_error() {
  printf 'deferred reason=script-error: %s\n' "$1"
  exit 2
}

require_jq "resolve-manifest-only-dirty.sh"
GH="${GH:-gh}"
for tool in "$GH" git awk sed; do
  command -v "$tool" >/dev/null 2>&1 || script_error "required tool '$tool' not found on PATH"
done

sub="${1:-}"
[ $# -gt 0 ] && shift
[ "$sub" = "resolve" ] || { usage >&2; script_error "unknown or missing subcommand '$sub'"; }

REPO=""
PR=""
HEAD_REF=""
DEFAULT_BRANCH=""
MANIFEST=""
VERSION_JQ=".version"
CHANGELOG=""
SCRATCH_ROOT=".shipyard-scratch"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --head-ref) HEAD_REF="${2:-}"; shift 2 ;;
    --default-branch) DEFAULT_BRANCH="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --version-jq) VERSION_JQ="${2:-.version}"; shift 2 ;;
    --changelog) CHANGELOG="${2:-}"; shift 2 ;;
    --scratch-root) SCRATCH_ROOT="${2:-.shipyard-scratch}"; shift 2 ;;
    *) usage >&2; script_error "unknown argument: $1" ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$PR" ] || [ -z "$HEAD_REF" ] || [ -z "$DEFAULT_BRANCH" ]; then
  usage >&2
  script_error "--repo, --pr, --head-ref, and --default-branch are required"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || script_error "not inside a git working tree"

# --- Pre-flight: confirm DIRTY is still the state (state drifts between
# the caller's snapshot and this script running) ---------------------------
preflight=$("$GH" pr view "$PR" --repo "$REPO" --json mergeStateStatus,state 2>/dev/null)
[ -n "$preflight" ] || defer "preflight-failed" "could not read PR #$PR state"
pr_state=$(printf '%s' "$preflight" | jq -r '.state')
merge_state=$(printf '%s' "$preflight" | jq -r '.mergeStateStatus')
[ "$pr_state" = "OPEN" ] || defer "not-open" "PR #$PR is $pr_state, not OPEN"
[ "$merge_state" = "DIRTY" ] || defer "not-dirty" "PR #$PR mergeStateStatus=$merge_state, not DIRTY"

# --- Scratch worktree setup -------------------------------------------------
mkdir -p "$SCRATCH_ROOT" 2>/dev/null || script_error "could not create scratch root '$SCRATCH_ROOT'"
# Resolve to an absolute path — every downstream path built from
# $SCRATCH_ROOT must stay valid even after a `cd "$WT_DIR"` into a subshell
# several directories below it (the safety-net calls below do exactly
# that), which a relative path wouldn't survive.
SCRATCH_ROOT="$(cd "$SCRATCH_ROOT" && pwd)"
printf '*\n' > "$SCRATCH_ROOT/.gitignore" 2>/dev/null || true
git worktree prune >/dev/null 2>&1 || true

WT_DIR="$SCRATCH_ROOT/vc-resolve-$PR-$$-$RANDOM"
# Inline trap command (not a named function) so it fires reliably on every
# exit path — best-effort, never lets a cleanup failure mask the real exit
# code. Mirrors this directory's own trap convention (assert-rebase-diff-
# nonempty.sh, gh-batch.sh, etc. all use an inline string here too).
trap 'if [ -d "$WT_DIR" ]; then git -C "$WT_DIR" rebase --abort >/dev/null 2>&1 || true; git worktree remove "$WT_DIR" --force >/dev/null 2>&1 || true; rm -rf "$WT_DIR" 2>/dev/null || true; fi; git worktree prune >/dev/null 2>&1 || true' EXIT

git fetch origin "$HEAD_REF" "$DEFAULT_BRANCH" --quiet 2>/dev/null \
  || defer "fetch-failed" "could not fetch origin/$HEAD_REF and origin/$DEFAULT_BRANCH"

PRE_HEAD_OID=$(git rev-parse "origin/$HEAD_REF" 2>/dev/null)
[ -n "$PRE_HEAD_OID" ] || defer "fetch-failed" "origin/$HEAD_REF did not resolve after fetch"

git worktree add --detach "$WT_DIR" "origin/$HEAD_REF" --quiet 2>/dev/null \
  || defer "worktree-add-failed" "could not create ephemeral worktree at $WT_DIR"

# --- Attempt the rebase ------------------------------------------------------
if git -C "$WT_DIR" rebase "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
  NEXT_FREE=""
else
  # --- Conflict triage: recognized set is {manifest, changelog} only -------
  CONFLICTED=$(git -C "$WT_DIR" diff --name-only --diff-filter=U 2>/dev/null)
  [ -n "$CONFLICTED" ] || defer "rebase-failed-no-conflict" "rebase exited non-zero but no conflicted paths found"

  UNRECOGNIZED=""
  MANIFEST_CONFLICTED=0
  CHANGELOG_CONFLICTED=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -n "$MANIFEST" ] && [ "$f" = "$MANIFEST" ]; then
      MANIFEST_CONFLICTED=1
    elif [ -n "$CHANGELOG" ] && [ "$f" = "$CHANGELOG" ]; then
      CHANGELOG_CONFLICTED=1
    else
      UNRECOGNIZED="$UNRECOGNIZED $f"
    fi
  done <<EOF
$CONFLICTED
EOF

  if [ -n "$UNRECOGNIZED" ]; then
    defer "conflict-wider" "conflict extends beyond coordinated manifest+CHANGELOG rows ($UNRECOGNIZED trimmed)"
  fi
  if [ "$MANIFEST_CONFLICTED" -eq 0 ] && [ "$CHANGELOG_CONFLICTED" -eq 0 ]; then
    # Conflicted paths existed but matched neither recognized file — only
    # reachable if MANIFEST/CHANGELOG were both empty while a conflict
    # still occurred (vc disabled on this repo).
    defer "vc-disabled" "rebase conflicted but no coordinated manifest/CHANGELOG configured"
  fi

  # Computed once, unconditionally, whenever there IS a recognized conflict
  # — both the manifest resolution and the known-rewrites extraction below
  # need it, and either can run without the other (e.g. CHANGELOG-only
  # conflicted, MANIFEST auto-merged clean).
  BASE_SHA=$(git merge-base "origin/$HEAD_REF" "origin/$DEFAULT_BRANCH" 2>/dev/null)
  [ -n "$BASE_SHA" ] || defer "merge-base-failed" "could not resolve the merge-base of origin/$HEAD_REF and origin/$DEFAULT_BRANCH"

  # --- Hunk-shape gates, via git's diff3 conflict markers -------------------
  # Regenerating in diff3 style gives an explicit ours/base/theirs split per
  # hunk (see resolve-append-only-conflict.sh for the sibling technique).
  # During a REBASE, "ours" is the branch being rebased ONTO (main) and
  # "theirs" is the commit being replayed (this PR) — confirmed empirically
  # against this environment's git before relying on it here.
  extract_single_hunk() {
    # $1: conflicted file (worktree-relative). Regenerates it in diff3 form
    # and, IFF it contains exactly one hunk, splits pre-hunk content into
    # $2, ours/base/theirs into $3/$4/$5, and trailing (post-hunk) content
    # into $6. Prints "1" on stdout if exactly one hunk was found and
    # split, else "0" (multi-hunk — caller must bail, nothing is written).
    local file="$1" prefile="$2" oursfile="$3" basefile="$4" theirsfile="$5" trailfile="$6"
    git -C "$WT_DIR" checkout --conflict=diff3 -- "$file" 2>/dev/null || { echo 0; return; }
    : > "$prefile"; : > "$oursfile"; : > "$basefile"; : > "$theirsfile"; : > "$trailfile"
    awk -v prefile="$prefile" -v oursfile="$oursfile" -v basefile="$basefile" -v theirsfile="$theirsfile" -v trailfile="$trailfile" '
      BEGIN { sect = "pre"; n = 0 }
      /^<<<<<<< / { n++; sect = "ours"; next }
      /^\|\|\|\|\|\|\| / { sect = "base"; next }
      /^=======$/ { sect = "theirs"; next }
      /^>>>>>>> / { sect = "trail"; next }
      sect == "pre"    { print > prefile; next }
      sect == "ours"   { print > oursfile; next }
      sect == "base"   { print > basefile; next }
      sect == "theirs" { print > theirsfile; next }
      sect == "trail"  { print > trailfile; next }
      { next }
      END { printf "%d\n", n > "/dev/stderr" }
    ' "$WT_DIR/$file" 2> "$SCRATCH_ROOT/.vc-resolve-nhunks-$$"
    local n
    n=$(cat "$SCRATCH_ROOT/.vc-resolve-nhunks-$$" 2>/dev/null || echo 0)
    rm -f "$SCRATCH_ROOT/.vc-resolve-nhunks-$$"
    if [ "${n:-0}" = "1" ]; then echo 1; else echo 0; fi
  }

  if [ "$MANIFEST_CONFLICTED" -eq 1 ]; then
    # Structural check, not a hunk-count heuristic: read BOTH sides' full
    # manifest content directly ("ours" during a rebase is the branch being
    # rebased onto — origin/$DEFAULT_BRANCH; "theirs" is the commit being
    # replayed — origin/$HEAD_REF, confirmed empirically against this
    # environment's git), blank out the version field on each via jq, and
    # require the two blanked documents to be byte-identical. This is a
    # stronger guarantee than "the diff hunk was N lines" — it directly
    # proves every OTHER key is unchanged, so a whole-file `--ours` +
    # single jq-set of the version field cannot silently discard a
    # legitimate PR edit to some other key (the issue #646 failure shape).
    GATE_OURS_FULL=$(git show "origin/$DEFAULT_BRANCH:$MANIFEST" 2>/dev/null)
    GATE_THEIRS_FULL=$(git show "origin/$HEAD_REF:$MANIFEST" 2>/dev/null)
    if [ -z "$GATE_OURS_FULL" ] || [ -z "$GATE_THEIRS_FULL" ]; then
      defer "manifest-read-failed" "could not read $MANIFEST from both sides of the conflict"
    fi
    GATE_OURS_NOVER=$(printf '%s' "$GATE_OURS_FULL" | jq -S --arg z "__vc_sentinel__" "$VERSION_JQ = \$z" 2>/dev/null)
    GATE_THEIRS_NOVER=$(printf '%s' "$GATE_THEIRS_FULL" | jq -S --arg z "__vc_sentinel__" "$VERSION_JQ = \$z" 2>/dev/null)
    if [ -z "$GATE_OURS_NOVER" ] || [ "$GATE_OURS_NOVER" != "$GATE_THEIRS_NOVER" ]; then
      defer "manifest-conflict-outside-version-row" "manifest conflict touches more than the $VERSION_JQ row"
    fi
  fi

  if [ "$CHANGELOG_CONFLICTED" -eq 1 ]; then
    C_PRE="$SCRATCH_ROOT/.vc-c-pre-$$"
    C_OURS="$SCRATCH_ROOT/.vc-c-ours-$$"
    C_BASE="$SCRATCH_ROOT/.vc-c-base-$$"
    C_THEIRS="$SCRATCH_ROOT/.vc-c-theirs-$$"
    C_TRAIL="$SCRATCH_ROOT/.vc-c-trail-$$"
    SINGLE=$(extract_single_hunk "$CHANGELOG" "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL")
    if [ "$SINGLE" != "1" ]; then
      rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL"
      defer "changelog-multi-hunk" "CHANGELOG conflict has more than one hunk — needs manual rebase"
    fi
    # Version-heading insert: both sides' conflicting content must itself
    # START with a `### <version>` heading line — this is the semantic
    # shape check (a version block being prepended), deliberately NOT a
    # "nothing may precede the hunk in the whole file" position check,
    # since a real CHANGELOG.md legitimately has unconflicted prose (a
    # title, a `## shipyard` section heading) ahead of the first entry.
    C_OURS_FIRST=$(head -1 "$C_OURS" 2>/dev/null)
    C_THEIRS_FIRST=$(head -1 "$C_THEIRS" 2>/dev/null)
    case "$C_OURS_FIRST" in
      "### "*) : ;;
      *)
        rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL"
        defer "changelog-conflict-outside-top-insert" "CHANGELOG conflict's main-side content is not a version heading insert"
        ;;
    esac
    case "$C_THEIRS_FIRST" in
      "### "*) : ;;
      *)
        rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL"
        defer "changelog-conflict-outside-top-insert" "CHANGELOG conflict's PR-side content is not a version heading insert"
        ;;
    esac
    rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL"
  fi

  # --- Resolve the manifest --------------------------------------------------
  if [ "$MANIFEST_CONFLICTED" -eq 1 ]; then
    FLOOR=$(git show "origin/$DEFAULT_BRANCH:$MANIFEST" 2>/dev/null | jq -r "$VERSION_JQ" 2>/dev/null)
    PR_VERSION=$(git show "origin/$HEAD_REF:$MANIFEST" 2>/dev/null | jq -r "$VERSION_JQ" 2>/dev/null)
    BASE_VERSION=$(git show "$BASE_SHA:$MANIFEST" 2>/dev/null | jq -r "$VERSION_JQ" 2>/dev/null)
    if [ -z "$FLOOR" ] || [ -z "$PR_VERSION" ] || [ -z "$BASE_VERSION" ]; then
      defer "version-read-failed" "could not read $MANIFEST version at one of floor/pr/base refs"
    fi

    # shellcheck disable=SC2034  # B_PAT/P_PAT: patch component isn't
    # consulted by the major/minor bump-level check below, only major/minor
    # are — kept for symmetry with the FLOOR split below, which does use
    # its own patch component.
    IFS='.' read -r B_MAJ B_MIN B_PAT <<EOF
$BASE_VERSION
EOF
    # shellcheck disable=SC2034
    IFS='.' read -r P_MAJ P_MIN P_PAT <<EOF
$PR_VERSION
EOF
    if [ "${P_MAJ:-0}" -gt "${B_MAJ:-0}" ] 2>/dev/null; then
      BUMP_LEVEL="major"
    elif [ "${P_MIN:-0}" -gt "${B_MIN:-0}" ] 2>/dev/null; then
      BUMP_LEVEL="minor"
    else
      BUMP_LEVEL="patch"
    fi

    IFS='.' read -r F_MAJ F_MIN F_PAT <<EOF
$FLOOR
EOF
    case "$BUMP_LEVEL" in
      major) NEXT_FREE="$((F_MAJ + 1)).0.0" ;;
      minor) NEXT_FREE="$F_MAJ.$((F_MIN + 1)).0" ;;
      *)     NEXT_FREE="$F_MAJ.$F_MIN.$((F_PAT + 1))" ;;
    esac

    git -C "$WT_DIR" checkout --ours -- "$MANIFEST" 2>/dev/null \
      || defer "manifest-checkout-failed" "git checkout --ours $MANIFEST failed"
    TMP_MANIFEST="$SCRATCH_ROOT/.vc-manifest-$$"
    if ! jq --arg newver "$NEXT_FREE" "$VERSION_JQ = \$newver" "$WT_DIR/$MANIFEST" > "$TMP_MANIFEST" 2>/dev/null; then
      rm -f "$TMP_MANIFEST"
      defer "manifest-jq-set-failed" "jq could not set $VERSION_JQ to $NEXT_FREE"
    fi
    mv "$TMP_MANIFEST" "$WT_DIR/$MANIFEST"
    git -C "$WT_DIR" add "$MANIFEST"
  else
    # Manifest wasn't in conflict — either untouched, or git's own 3-way
    # merge already resolved it. Either way its post-merge value on disk IS
    # the version any changelog resolution below should reuse.
    NEXT_FREE=$(jq -r "$VERSION_JQ" "$WT_DIR/$MANIFEST" 2>/dev/null || echo "")
  fi

  # --- Resolve the CHANGELOG (renumber PR's own entry, hoist above main's) --
  if [ "$CHANGELOG_CONFLICTED" -eq 1 ]; then
    [ -n "$NEXT_FREE" ] || defer "changelog-no-version" "no resolved manifest version available to renumber the CHANGELOG heading with"
    C_PRE="$SCRATCH_ROOT/.vc-c-pre-$$"
    C_OURS="$SCRATCH_ROOT/.vc-c-ours-$$"
    C_BASE="$SCRATCH_ROOT/.vc-c-base-$$"
    C_THEIRS="$SCRATCH_ROOT/.vc-c-theirs-$$"
    C_TRAIL="$SCRATCH_ROOT/.vc-c-trail-$$"
    SINGLE=$(extract_single_hunk "$CHANGELOG" "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL")
    if [ "$SINGLE" != "1" ]; then
      rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL"
      defer "changelog-resolve-shape-changed" "CHANGELOG hunk shape changed between gate check and resolution"
    fi
    RENUMBERED="$SCRATCH_ROOT/.vc-c-renumbered-$$"
    # Line 1 only — the gate above already confirmed $C_THEIRS's first line
    # is a `### <version>` heading, so a `1s/…/…/` address is both
    # sufficient and (unlike a GNU-only `0,/regex/` address, which BSD/macOS
    # sed rejects with "bad flag in substitute command") portable.
    sed -E "1s/^### [0-9]+\\.[0-9]+\\.[0-9]+/### $NEXT_FREE/" "$C_THEIRS" > "$RENUMBERED"
    # $C_PRE is the shared, unconflicted content BEFORE the hunk (a real
    # CHANGELOG.md typically has a `# Changelog` title + `## shipyard`
    # section heading here) — it must be preserved, not just the hunk's
    # two sides + trailing content.
    cat "$C_PRE" "$RENUMBERED" "$C_OURS" "$C_TRAIL" > "$WT_DIR/$CHANGELOG"
    rm -f "$C_PRE" "$C_OURS" "$C_BASE" "$C_THEIRS" "$C_TRAIL" "$RENUMBERED"
    git -C "$WT_DIR" add "$CHANGELOG"
  fi

  # --- Known-rewrites record for the added-lines-survived guard below -------
  KNOWN_REWRITES="$SCRATCH_ROOT/.vc-known-rewrites-$$"
  : > "$KNOWN_REWRITES"
  if [ "$MANIFEST_CONFLICTED" -eq 1 ]; then
    M_DIFF=$(git diff "$BASE_SHA" "origin/$HEAD_REF" -- "$MANIFEST" 2>/dev/null)
    case "$M_DIFF" in
      "" | "diff --git "*)
        M_LINE=$(printf '%s\n' "$M_DIFF" | awk '/^\+\+\+/{next} /^\+/{line=substr($0,2); if (line ~ /[^ \t]/) print line}' | grep -F -- "$PR_VERSION" | head -1 || true)
        [ -n "$M_LINE" ] && printf '%s\t%s\n' "$MANIFEST" "$M_LINE" >> "$KNOWN_REWRITES"
        ;;
      *) : ;; # unexpected diff shape — leave unexempted, verify step below is stricter, never looser
    esac
  fi
  if [ "$CHANGELOG_CONFLICTED" -eq 1 ] && [ -n "$CHANGELOG" ]; then
    CL_DIFF=$(git diff "$BASE_SHA" "origin/$HEAD_REF" -- "$CHANGELOG" 2>/dev/null)
    case "$CL_DIFF" in
      "" | "diff --git "*)
        CL_LINE=$(printf '%s\n' "$CL_DIFF" | awk '/^\+\+\+/{next} /^\+/{line=substr($0,2); if (line ~ /[^ \t]/) print line}' | grep -E '^### ' | head -1 || true)
        [ -n "$CL_LINE" ] && printf '%s\t%s\n' "$CHANGELOG" "$CL_LINE" >> "$KNOWN_REWRITES"
        ;;
      *) : ;;
    esac
  fi

  git -C "$WT_DIR" rebase --continue >/dev/null 2>&1 \
    || defer "rebase-continue-failed" "git rebase --continue failed after resolution (possible second conflict stop)"
fi

# --- Safety nets (mirrors fix-rebase.md steps 5.5-5.8) ----------------------
# Issue #1462: a raw whole-tree `git grep` for the marker pattern
# false-positives DETERMINISTICALLY on this repo's own clean tree, because
# `plugins/shipyard/scripts/tests/conflict-marker-scan.test.sh` ships marker-
# shaped fixture strings as its test data. Shell out to the authoritative
# scanner instead — it already honors that fixture's `conflict-marker-scan:
# allow` opt-out directive and is the same script wired into the `conflict
# markers` CI required check, so a worktree that passes here also passes CI.
# Fall back to the raw grep ONLY if the scanner binary is somehow missing —
# a genuine surviving marker must remain fatal either way.
CONFLICT_SCANNER="$here/conflict-marker-scan.sh"
if [ -f "$CONFLICT_SCANNER" ]; then
  if ! ( cd "$WT_DIR" && bash "$CONFLICT_SCANNER" >/dev/null 2>&1 ); then
    defer "conflict-markers-remain" "conflict markers survived resolution"
  fi
elif git -C "$WT_DIR" grep -qnE '^(<{7}|={7}|>{7})( |$)' -- . 2>/dev/null; then
  defer "conflict-markers-remain" "conflict markers survived resolution"
fi

if [ -n "$CHANGELOG" ]; then
  SCANNER="$here/changelog-monotonicity-scan.sh"
  if [ -f "$SCANNER" ]; then
    if ! ( cd "$WT_DIR" && CHANGELOG_PATH="$CHANGELOG" bash "$SCANNER" "origin/$DEFAULT_BRANCH" >/dev/null 2>&1 ); then
      defer "changelog-heading-deleted" "resolution deleted a released CHANGELOG heading"
    fi
  fi
fi

DIFF_GUARD="$here/assert-rebase-diff-nonempty.sh"
if [ -f "$DIFF_GUARD" ]; then
  if ! ( cd "$WT_DIR" && bash "$DIFF_GUARD" "origin/$DEFAULT_BRANCH" "origin/$HEAD_REF" >/dev/null 2>&1 ); then
    defer "empty-diff" "rebase result has an empty diff vs base — refusing to push"
  fi
fi

SURVIVED_GUARD="$here/verify-added-lines-survived.sh"
if [ -f "$SURVIVED_GUARD" ]; then
  MERGE_BASE=$(git merge-base "origin/$HEAD_REF" "origin/$DEFAULT_BRANCH" 2>/dev/null)
  KNOWN_REWRITES_ARG=""
  [ -n "${KNOWN_REWRITES:-}" ] && [ -s "$KNOWN_REWRITES" ] && KNOWN_REWRITES_ARG="$KNOWN_REWRITES"
  if [ -n "$MERGE_BASE" ]; then
    if [ -n "$KNOWN_REWRITES_ARG" ]; then
      SURVIVED_OK=0
      ( cd "$WT_DIR" && bash "$SURVIVED_GUARD" "$MERGE_BASE" "origin/$HEAD_REF" "$KNOWN_REWRITES_ARG" >/dev/null 2>&1 ) && SURVIVED_OK=1
    else
      SURVIVED_OK=0
      ( cd "$WT_DIR" && bash "$SURVIVED_GUARD" "$MERGE_BASE" "origin/$HEAD_REF" >/dev/null 2>&1 ) && SURVIVED_OK=1
    fi
    [ "$SURVIVED_OK" = "1" ] || defer "added-lines-missing" "a PR-added line did not survive the resolution verbatim"
  fi
fi
[ -n "${KNOWN_REWRITES:-}" ] && rm -f "$KNOWN_REWRITES"

# --- Push ---------------------------------------------------------------
NEW_HEAD=$(git -C "$WT_DIR" rev-parse HEAD 2>/dev/null)
[ -n "$NEW_HEAD" ] || defer "no-head" "rebased worktree has no resolvable HEAD"

LEASE="refs/heads/$HEAD_REF:$PRE_HEAD_OID"
if ! git -C "$WT_DIR" push --force-with-lease="$LEASE" origin "HEAD:refs/heads/$HEAD_REF" >/dev/null 2>&1; then
  defer "push-lease-rejected" "head branch $HEAD_REF moved since fetch — someone else pushed"
fi

printf 'resolved pr=%s version=%s head=%s\n' "$PR" "${NEXT_FREE:-}" "$NEW_HEAD"
exit 0

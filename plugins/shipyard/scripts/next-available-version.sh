#!/usr/bin/env bash
# next-available-version.sh — dispatch-rules.md's "Next-available-version
# computation" ([#339](https://github.com/mattsears18/shipyard/issues/339),
# bump-type-aware per #671, batch-monotonic per #437), extracted to a script
# per issue #1289 (the follow-up to #1277/#1288).
#
# Background
# ----------
# On a `version_coordination`-enabled repo, dispatch-rules.md computes a
# collision-avoidance floor + a recommended next version slot BEFORE
# composing each worker's dispatch prompt, so sequential/batch dispatches
# don't all bump the same shared manifest row (`plugin.json` `.version`,
# etc.) to the same value. The computation walks `session_prs` — a
# data-dependent set whose size isn't known at spec-authoring time — with
# three internal `gh api ... | base64 -d | jq ...` pipes inside the loop
# body, plus two `printf | sort -V | tail -1` pipes outside it. That's
# exactly the two shapes the worktree-isolation guard refuses
# post-relocation: a for-loop wrapping gh calls, and a pipe spanning a shell
# command boundary. See `dont.md`'s "Post-relocation Bash blocks must be
# plain, single-purpose commands" section for the general rule.
#
# As a side benefit (mirroring stale-check-refresh.sh's own rationale), this
# also gives the `version_cursor` batch-monotonicity mechanism a REAL
# persistence mechanism: the original inline computation kept `version_cursor`
# as a bash variable, which does not survive between separate Bash tool
# calls — across a batch of N simultaneous dispatches (the actual case this
# mechanism exists for) the in-memory variable was silently reset before
# each dispatch's prompt-composition call ran. The `--cursor-file` here is a
# real file, so it persists correctly across the N sequential invocations
# that compose one batch's N prompts.
#
# Subcommand
# ----------
#
#   compute --repo <owner/repo> --manifest <path> --version-jq <jq-expr>
#       --default-branch <branch> --issue <N> [--session-prs <PR numbers,
#       space or comma separated>] [--cursor-file <path>]
#     Reads the manifest version from origin/<default-branch> as the floor,
#     walks --session-prs for any OPEN PR that already touched --manifest
#     and keeps the max version claimed, folds in --cursor-file's stored
#     value (if present and newer), infers the release bump LEVEL
#     (major/minor/patch) from the --issue's Conventional-Commits-shaped
#     title/body, computes next_available_version = floor bumped at that
#     level, and — only on a successful computation — advances
#     --cursor-file to the new value so the NEXT invocation in the same
#     batch sees it as claimed. --cursor-file defaults to
#     `.shipyard-version-cursor` in the current directory (plain text, one
#     semver string, overwritten each successful compute — no dedup needed,
#     unlike stale-check-refresh.sh's append-only log, since only the latest
#     cursor value is ever consulted).
#
#     Prints four `key=value` lines to stdout:
#       max_inflight_version=<semver-or-empty>
#       bump_level=<major|minor|patch>
#       next_available_version=<semver-or-empty>
#       reclaimed_slot=<semver-or-empty>
#
#     `reclaimed_slot` (issue #1420) is non-empty only when this call handed
#     back a previously-RELEASED slot (see `release` below) instead of
#     advancing past the cursor. When the holes file is absent or empty —
#     the overwhelmingly common case, and every case before #1420 — the
#     line reads `reclaimed_slot=` and every other output byte is identical
#     to the pre-#1420 behavior.
#
#     `next_available_version` is empty when no floor could be established
#     at all (manifest read failed AND no in-flight bump AND no cursor) —
#     the caller's documented fallback is to omit the coordination
#     paragraph entirely and let the worker bump from `origin/<default-
#     branch>` on its own. Exit 0 always (best-effort — an individual `gh`/
#     `jq` failure degrades a single input rather than aborting the whole
#     computation, matching the `|| echo ""` posture the original inline
#     block had throughout).
#
#     `compute` itself is UNCHANGED by issue #1417 below — it always folds
#     in a present --cursor-file's value, exactly as before. That is
#     load-bearing for batch monotonicity (#437): a batch of N simultaneous
#     dispatches runs this computation N times in sequence against the SAME
#     --session-prs value (often with zero OPEN members, since the batch's
#     own sibling PRs don't exist yet), relying on the cursor alone to keep
#     slots 1..N distinct. Any self-heal that conditioned compute()'s own
#     cursor fold-in on --session-prs would silently re-collide every slot
#     in that case — see `reseed-if-idle` below for where the self-heal
#     actually lives instead.
#
#   reseed-if-idle --repo <owner/repo> --session-prs <PR numbers, space or
#       comma separated> --cursor-file <path>
#     Closes issue #1417 — the cursor advances on what `compute` COMPUTED,
#     not on what a worker actually CLAIMED (a worker legitimately taking a
#     different bump level than the orchestrator inferred, per #671's "the
#     level is yours to raise" contract, leaves the old computed slot
#     unclaimed forever, and every later `compute` floors above the
#     phantom). This is the caller-side self-healing half of the fix
#     (issue #1417's "option 2") — a stale cursor is discarded here, at a
#     well-defined, safe point, rather than inside `compute` trying to
#     distinguish "trustworthy same-batch advance" from "stale cross-
#     dispatch drift" on every call — which it cannot do from
#     --session-prs alone, per the `compute` note above.
#
#     Call this ONCE per dispatch-decision round — before the single
#     `compute` call for an ordinary per-dispatch, or once before the
#     sequential per-slot `compute` loop for a batch fill (never inside
#     that loop), so a batch's own monotonic cursor advances are never
#     touched mid-batch. See dispatch-rules.md's "Next-available-version
#     computation" section and setup/07-pool-fill.md's step 7 for the two
#     call sites.
#
#     Walks --session-prs exactly like `compute` does. If ANY listed PR
#     resolves to state OPEN, the cursor may still be backing a genuinely
#     in-flight claim — no-op. Otherwise (including an empty
#     --session-prs) nothing this session currently relies on the
#     persisted cursor, so it is discarded (the file is removed) — the
#     next `compute` call re-seeds the floor from `origin/<default-
#     branch>`'s manifest instead of an unclaimed, possibly-inflated,
#     holdover value.
#
#     Prints one `key=value` line to stdout:
#       reseed=<reset|skipped-open-pr-found|noop-no-cursor>
#
#     Exit 0 always (best-effort, same posture as `compute`).
#
#   release --version <v> [--cursor-file <path>] [--holes-file <path>]
#     Closes issue #1420 — the release-on-non-claim hook. `compute` hands a
#     slot to a dispatch and advances the cursor immediately; when that
#     dispatch terminates WITHOUT ever opening a PR (a `blocked` return, a
#     permission-classifier denial, a crash, or an explicit worker decline)
#     nothing ever claims the slot, and every later `compute` floors above
#     the phantom. `reseed-if-idle` cannot recover this variant: it only
#     fires once `session_prs` has NO open member, and the leak routinely
#     happens while sibling PRs are still open (the #1420 repro: cursor
#     4.40.0 while the true highest claim across all open PRs was 4.38.0).
#
#     **A release is NOT a cursor rollback, and this subcommand never
#     lowers the cursor.** Slots are handed out monotonically, so a
#     released slot may not be the highest one outstanding — decrementing
#     would hand a later batch member's already-promised value back out and
#     reintroduce the exact #437 collision the cursor exists to prevent.
#     Instead the released version is recorded as a HOLE, and `compute`
#     reclaims it on its next run (preferring the smallest hole that is
#     strictly above the ground-truth claimed floor and no higher than the
#     slot it would otherwise have handed out). That is observationally
#     equivalent to "collapse the cursor when the released version is the
#     current top" — the very next `compute` hands the released value
#     straight back — while staying safe in the general case where it is
#     NOT the top, and it needs no per-slot promise ledger to do it.
#
#     The safety argument rests on two invariants, both enforced here and
#     in `compute`: (1) the cursor is monotonic non-decreasing, so every
#     batch-monotonicity guarantee from #437 is untouched; (2) a hole is
#     only ever handed back out when it is strictly above the floor
#     derived from GROUND TRUTH ALONE (origin's manifest + the open-PR
#     walk), so a reclaimed slot can never collide with something already
#     claimed. A hole only enters the file for a dispatch that has already
#     terminated, so it can never collide with a live promise either.
#
#     **A forgotten or skipped release degrades to the STATUS QUO, never to
#     a collision** — the slot simply stays leaked, exactly as before
#     #1420. That asymmetry is what makes this safe without the per-slot
#     promise ledger: nothing here can under-count the floor.
#
#     --holes-file defaults to `<cursor-file>.holes` so the hole set is
#     always co-located with the cursor it belongs to (plain text, one
#     semver per line, append-only until a hole is reclaimed or pruned).
#
#     Prints one `key=value` line to stdout:
#       release=<recorded-hole|already-recorded|noop-no-cursor
#                |noop-above-cursor|noop-no-version|noop-bad-version>
#
#     `noop-no-version` is the "the caller had no recorded slot for this
#     dispatch" case — the one the orchestrator's `version_release=skipped`
#     invariant-line token exists to surface.
#
#     Exit 0 always (best-effort, same posture as `compute`).
#
# Exit codes: 0 success; 64 bad usage; 65 missing dependency (jq/gh).

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${here}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  next-available-version.sh compute --repo <owner/repo> --manifest <path>
      --version-jq <jq-expr> --default-branch <branch> --issue <N>
      [--session-prs <PR numbers, space or comma separated>]
      [--cursor-file <path>] [--holes-file <path>]
  next-available-version.sh reseed-if-idle --repo <owner/repo>
      [--session-prs <PR numbers, space or comma separated>]
      [--cursor-file <path>]
  next-available-version.sh release --version <semver>
      [--cursor-file <path>] [--holes-file <path>]
EOF
}

require_jq "next-available-version.sh"
GH="${GH:-gh}"
if ! command -v "$GH" >/dev/null 2>&1; then
  echo "next-available-version.sh: gh is required but not installed" >&2
  exit 65
fi

# manifest_version_at_ref <manifest_path> <jq_expr> <ref> — read the
# manifest's version row from a specific git ref via the contents API.
# Prints the version string, or empty on any failure. No pipe: uses process
# substitution so `jq` reads the base64-decoded content as its own stdin
# without a `cmd | cmd` chain spanning a shell command boundary.
manifest_version_at_ref() {
  local manifest="$1" version_jq="$2" ref="$3"
  local content
  content=$("$GH" api "repos/${repo}/contents/${manifest}?ref=${ref}" --jq '.content' 2>/dev/null)
  [ -z "$content" ] && { echo ""; return; }
  jq -r "$version_jq" 2>/dev/null <(base64 -d 2>/dev/null <<< "$content") || echo ""
}

# version_max <a> <b> — version-sort max of two (possibly empty) semver
# strings. `sort -V` handles 1.5.9 vs 1.5.10 correctly; plain lexicographic
# max would wrongly pick 1.5.9 over 1.5.10.
version_max() {
  local a="$1" b="$2"
  if [ -z "$a" ]; then echo "$b"; return; fi
  if [ -z "$b" ]; then echo "$a"; return; fi
  sort -V <<< "$(printf '%s\n%s' "$a" "$b")" | tail -1
}

# version_gt <a> <b> — exit 0 when semver <a> is strictly greater than <b>.
# Both operands must be non-empty; an empty operand returns non-zero so a
# caller that could not establish a floor never treats "unknown" as "lower".
version_gt() {
  local a="$1" b="$2"
  [ -z "$a" ] && return 1
  [ -z "$b" ] && return 1
  [ "$a" = "$b" ] && return 1
  [ "$(version_max "$a" "$b")" = "$a" ]
}

# is_semver <s> — exit 0 for a bare MAJOR.MINOR.PATCH string.
is_semver() {
  grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$1"
}

sub="${1:-}"
[ $# -gt 0 ] && shift

case "$sub" in
  compute)
    repo=""
    manifest=""
    version_jq=""
    default_branch=""
    issue=""
    session_prs_raw=""
    cursor_file=".shipyard-version-cursor"
    holes_file=""

    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --manifest) manifest="${2:-}"; shift 2 ;;
        --version-jq) version_jq="${2:-}"; shift 2 ;;
        --default-branch) default_branch="${2:-}"; shift 2 ;;
        --issue) issue="${2:-}"; shift 2 ;;
        --session-prs) session_prs_raw="${2:-}"; shift 2 ;;
        --cursor-file) cursor_file="${2:-}"; shift 2 ;;
        --holes-file) holes_file="${2:-}"; shift 2 ;;
        *) echo "next-available-version.sh compute: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done
    [ -z "$holes_file" ] && holes_file="${cursor_file}.holes"

    if [ -z "$repo" ] || [ -z "$manifest" ] || [ -z "$version_jq" ] || [ -z "$default_branch" ] || [ -z "$issue" ]; then
      echo "next-available-version.sh compute: --repo, --manifest, --version-jq, --default-branch, and --issue are required" >&2
      usage >&2
      exit 64
    fi

    # --- Floor: origin's current manifest version -------------------------
    main_version=$(manifest_version_at_ref "$manifest" "$version_jq" "$default_branch")
    max_inflight_version="$main_version"

    # --- Walk session_prs for any in-flight bump ---------------------------
    session_prs_normalized="${session_prs_raw//,/ }"
    # shellcheck disable=SC2086
    set -- $session_prs_normalized
    for pr in "$@"; do
      [ -z "$pr" ] && continue
      pr_state=$("$GH" pr view "$pr" --repo "$repo" --json state -q .state 2>/dev/null)
      [ "$pr_state" != "OPEN" ] && continue
      pr_touches_manifest=$("$GH" pr view "$pr" --repo "$repo" --json files \
        --jq "[.files[] | select(.path == \"${manifest}\")] | length" 2>/dev/null)
      [ "${pr_touches_manifest:-0}" -eq 0 ] && continue
      pr_head=$("$GH" pr view "$pr" --repo "$repo" --json headRefName -q .headRefName 2>/dev/null)
      [ -z "$pr_head" ] && continue
      pr_version=$(manifest_version_at_ref "$manifest" "$version_jq" "$pr_head")
      [ -z "$pr_version" ] && continue
      max_inflight_version=$(version_max "$max_inflight_version" "$pr_version")
    done

    # --- #1420: the GROUND-TRUTH floor, before the cursor is folded in -----
    # Everything at or below this value is provably claimed (it is either
    # already on the default branch or already committed on an OPEN PR's
    # head). It is the safety bound for reclaiming a released slot below:
    # a hole is only ever handed back out when it sits strictly above this.
    claimed_floor="$max_inflight_version"

    # --- #437: fold in the persisted cursor (batch-monotonicity) -----------
    if [ -f "$cursor_file" ]; then
      cursor_value=$(cat "$cursor_file" 2>/dev/null || echo "")
      [ -n "$cursor_value" ] && max_inflight_version=$(version_max "$max_inflight_version" "$cursor_value")
    fi

    # --- #671: infer the bump LEVEL from the issue's Conventional Commits
    # signals so the computed slot matches the issue's stated release intent.
    issue_title=$("$GH" issue view "$issue" --repo "$repo" --json title -q .title 2>/dev/null || echo "")
    issue_body=$("$GH" issue view "$issue" --repo "$repo" --json body -q .body 2>/dev/null || echo "")
    bump_level="patch"
    if grep -qiE '^[[:space:]]*feat(\([^)]*\))?[[:space:]]*:' <<< "$issue_title"; then
      bump_level="minor"
    fi
    if grep -qiE '^[[:space:]]*[a-z]+(\([^)]*\))?!:' <<< "$issue_title" \
       || grep -qiE 'BREAKING[ -]CHANGE|major version bump|\(X\.0\.0\)' <<< "$(printf '%s\n%s' "$issue_title" "$issue_body")"; then
      bump_level="major"
    fi

    # --- next_available_version = floor bumped at the inferred level -------
    reclaimed_slot=""
    if [ -n "$max_inflight_version" ]; then
      IFS='.' read -r MAJ MIN PAT <<< "$max_inflight_version"
      case "$bump_level" in
        major)   next_available_version="$((MAJ + 1)).0.0" ;;
        minor)   next_available_version="${MAJ}.$((MIN + 1)).0" ;;
        patch|*) next_available_version="${MAJ}.${MIN}.$((PAT + 1))" ;;
      esac

      # --- #1420: prefer a RELEASED slot over a fresh advance -------------
      # A hole is a version a prior `compute` handed to a dispatch that then
      # terminated without opening a PR (see `release`). Reclaiming it is
      # what stops the leak from compounding. Two bounds keep this safe:
      #   * strictly ABOVE `claimed_floor` — nothing at or below that value
      #     is free, so a reclaimed slot can never collide with a real claim;
      #   * no HIGHER than the slot we would otherwise have handed out — so
      #     reclaiming can only ever lower the number we emit, never inflate
      #     it past the raise-only contract's own prediction.
      # Holes at or below `claimed_floor` are stale (something claimed them
      # in the meantime) and get pruned. When the file is absent or nothing
      # qualifies, every byte below behaves exactly as it did pre-#1420.
      if [ -f "$holes_file" ] && [ -n "$claimed_floor" ]; then
        kept=""
        candidates=""
        while IFS= read -r hole; do
          [ -z "$hole" ] && continue
          is_semver "$hole" || continue
          version_gt "$hole" "$claimed_floor" || continue   # stale — prune
          kept="${kept}${hole}"$'\n'
          version_gt "$hole" "$next_available_version" && continue
          candidates="${candidates}${hole}"$'\n'
        done < "$holes_file"

        if [ -n "$candidates" ]; then
          reclaimed_slot=$(sort -V <<< "${candidates%$'\n'}" | head -1)
          next_available_version="$reclaimed_slot"
          # Consume it: a hole is handed back out at most once.
          kept=$(grep -vxF "$reclaimed_slot" <<< "${kept%$'\n'}" || echo "")
          [ -n "$kept" ] && kept="${kept}"$'\n'
        fi

        if [ -n "$kept" ]; then
          printf '%s' "$kept" > "$holes_file"
        else
          rm -f "$holes_file"
        fi
      fi

      # Advance the cursor to the exact value handed out — the load-bearing
      # write that makes a batch of N simultaneous dispatches monotonic.
      # #1420: take the MAX against the cursor's existing value so a
      # reclaimed hole (which is by construction <= the cursor) can never
      # lower it. On the no-hole path `next_available_version` is always
      # strictly greater than the stored cursor, so this is byte-identical
      # to the pre-#1420 unconditional write.
      cursor_prev=$(cat "$cursor_file" 2>/dev/null || echo "")
      printf '%s' "$(version_max "$cursor_prev" "$next_available_version")" > "$cursor_file"
    else
      next_available_version=""
    fi

    echo "max_inflight_version=${max_inflight_version}"
    echo "bump_level=${bump_level}"
    echo "next_available_version=${next_available_version}"
    echo "reclaimed_slot=${reclaimed_slot}"
    exit 0
    ;;
  reseed-if-idle)
    repo=""
    session_prs_raw=""
    cursor_file=".shipyard-version-cursor"

    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --session-prs) session_prs_raw="${2:-}"; shift 2 ;;
        --cursor-file) cursor_file="${2:-}"; shift 2 ;;
        *) echo "next-available-version.sh reseed-if-idle: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

    if [ -z "$repo" ]; then
      echo "next-available-version.sh reseed-if-idle: --repo is required" >&2
      usage >&2
      exit 64
    fi

    # --- #1417: does session_prs still have an OPEN member? ----------------
    session_prs_normalized="${session_prs_raw//,/ }"
    # shellcheck disable=SC2086
    set -- $session_prs_normalized
    any_open_session_pr="false"
    for pr in "$@"; do
      [ -z "$pr" ] && continue
      pr_state=$("$GH" pr view "$pr" --repo "$repo" --json state -q .state 2>/dev/null)
      if [ "$pr_state" = "OPEN" ]; then
        any_open_session_pr="true"
        break
      fi
    done

    if [ "$any_open_session_pr" = "true" ]; then
      echo "reseed=skipped-open-pr-found"
    elif [ -f "$cursor_file" ]; then
      rm -f "$cursor_file"
      echo "reseed=reset"
    else
      echo "reseed=noop-no-cursor"
    fi
    exit 0
    ;;
  release)
    released_version=""
    cursor_file=".shipyard-version-cursor"
    holes_file=""

    while [ $# -gt 0 ]; do
      case "$1" in
        --version) released_version="${2:-}"; shift 2 ;;
        --cursor-file) cursor_file="${2:-}"; shift 2 ;;
        --holes-file) holes_file="${2:-}"; shift 2 ;;
        *) echo "next-available-version.sh release: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done
    [ -z "$holes_file" ] && holes_file="${cursor_file}.holes"

    # --- #1420: the four no-op shapes, each named distinctly ---------------
    # None of these is an error: every one of them leaves the cursor exactly
    # where it was, which is the STATUS QUO (a leaked slot), never a
    # collision. `noop-no-version` in particular is the "the caller had no
    # recorded slot for this dispatch" case the orchestrator surfaces as
    # `version_release=skipped` on its invariant line.
    if [ -z "$released_version" ]; then
      echo "release=noop-no-version"
      exit 0
    fi
    if ! is_semver "$released_version"; then
      echo "release=noop-bad-version"
      exit 0
    fi
    if [ ! -f "$cursor_file" ]; then
      # `reseed-if-idle` already discarded the cursor, or no coordinated
      # dispatch has run yet — the next `compute` re-seeds the floor from
      # origin's manifest, so there is no phantom left to reclaim.
      echo "release=noop-no-cursor"
      exit 0
    fi

    cursor_value=$(cat "$cursor_file" 2>/dev/null || echo "")
    if version_gt "$released_version" "$cursor_value"; then
      # A value above the cursor cannot have come from this cursor's own
      # `compute` run (the cursor is advanced to every value it hands out).
      # Recording it would let a later `compute` hand out a slot the ground
      # truth has never accounted for. Refuse rather than guess.
      echo "release=noop-above-cursor"
      exit 0
    fi

    if [ -f "$holes_file" ] && grep -qxF "$released_version" "$holes_file"; then
      # Idempotent: a re-fired reconcile (or a duplicate notification) must
      # not record the same hole twice.
      echo "release=already-recorded"
      exit 0
    fi

    # The ONLY mutation this subcommand performs. The cursor is never
    # touched — see the header comment for why a rollback would reintroduce
    # #437, and why recording the hole is observationally equivalent to the
    # "collapse when it is the top" case without the risk.
    printf '%s\n' "$released_version" >> "$holes_file"
    echo "release=recorded-hole"
    exit 0
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "next-available-version.sh: unknown subcommand: $sub" >&2
    usage >&2
    exit 64
    ;;
esac

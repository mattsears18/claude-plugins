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
#     Prints three `key=value` lines to stdout:
#       max_inflight_version=<semver-or-empty>
#       bump_level=<major|minor|patch>
#       next_available_version=<semver-or-empty>
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
      [--cursor-file <path>]
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

    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --manifest) manifest="${2:-}"; shift 2 ;;
        --version-jq) version_jq="${2:-}"; shift 2 ;;
        --default-branch) default_branch="${2:-}"; shift 2 ;;
        --issue) issue="${2:-}"; shift 2 ;;
        --session-prs) session_prs_raw="${2:-}"; shift 2 ;;
        --cursor-file) cursor_file="${2:-}"; shift 2 ;;
        *) echo "next-available-version.sh compute: unknown argument: $1" >&2; usage >&2; exit 64 ;;
      esac
    done

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
    if [ -n "$max_inflight_version" ]; then
      IFS='.' read -r MAJ MIN PAT <<< "$max_inflight_version"
      case "$bump_level" in
        major)   next_available_version="$((MAJ + 1)).0.0" ;;
        minor)   next_available_version="${MAJ}.$((MIN + 1)).0" ;;
        patch|*) next_available_version="${MAJ}.${MIN}.$((PAT + 1))" ;;
      esac
      # Advance the cursor to the exact value handed out — the load-bearing
      # write that makes a batch of N simultaneous dispatches monotonic.
      printf '%s' "$next_available_version" > "$cursor_file"
    else
      next_available_version=""
    fi

    echo "max_inflight_version=${max_inflight_version}"
    echo "bump_level=${bump_level}"
    echo "next_available_version=${next_available_version}"
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

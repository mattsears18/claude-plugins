#!/usr/bin/env bash
# draft-pr-recovery.sh — recover inherited draft PRs that /shipyard:do-work's
# other sweeps cannot see.
#
# Background (issue #1069)
# -------------------------
# Setup step 5.7 seeds inherited `@me` PRs into `session_prs` only when they
# are `DIRTY`-but-green (the #373 cross-session DIRTY-PR blackhole fix); the
# failed-PR scan (step 5) keys on a RED check rollup. A PR left in **draft**
# is typically neither: `mergeStateStatus` reads `CLEAN` (not `DIRTY`) and,
# on any repo whose CI guards jobs with a `draft != true` condition (a common
# cost optimization), every check reads `SKIPPED` (not red). No sweep in the
# session ever looks at it, so a fully-resolved agent-authored draft can sit
# open indefinitely — the concrete repro (mattsears18/lightwork#3465) sat
# stranded 2 days holding a P1 fix that needed nothing but `gh pr ready`.
#
# This script is the SINGLE EXECUTABLE SOURCE OF TRUTH for the classification
# decision (mirrors the detect-ungated-admin-direct-merge.sh precedent from
# issue #716 — a condition restated in prose drifts; a condition that is one
# script cannot). It also performs the recovery action (ready + arm auto-merge
# for a mechanically-safe candidate; label + comment for everything else) so
# a single call handles both classification and enforcement.
#
# The auto-ready path is DELIBERATELY narrow. A human's own deliberate WIP
# draft must never be auto-readied — see issue #1069's negative test case
# (mattsears18/shipyard#1100): a PR carrying `closingIssuesReferences` and an
# agent co-author trailer that was hand-converted to draft + labeled
# `needs-human-review` after its issue was closed NOT_PLANNED must hand back,
# not auto-ready. The classifier below is ordered so any one of several
# independent signals is sufficient to force a hand-back.
#
# Usage — pure decision (hermetic, for tests and for callers that already
# hold the seven signals):
#   bash draft-pr-recovery.sh classify-one \
#     <agent_authored:true|false> <gated_label:true|false> \
#     <closing_ref_count:N> <any_closing_closed:true|false> \
#     <body_empty:true|false> <body_wip_marker:true|false> \
#     <body_unchecked_tasks:true|false>
#     -> prints one disposition token on stdout:
#          ready
#          hand-back:gated-label
#          hand-back:no-closing-ref
#          hand-back:stale-closing-issue
#          hand-back:empty-body
#          hand-back:wip-marker
#          hand-back:unchecked-tasks
#          skip:not-agent-authored
#
# Usage — pure signal extractors (hermetic, for tests):
#   bash draft-pr-recovery.sh agent-authored-check   < commit-messages.txt
#     -> true if any commit carries a `Co-Authored-By:` trailer naming Claude
#        or a `Claude-Session:` trailer line (the shipyard worker commit
#        convention); false otherwise. NOT the `do-work/*` branch prefix —
#        issue #1069 notes the repro PR's branch was `fix/android-sdk-root-
#        3461`, so the co-author trailer is the only reliable signal.
#   bash draft-pr-recovery.sh gated-label-check      < labels.txt   (one per line)
#     -> true if any label is a disposition/gate label that already answers
#        "should this merge" (needs-human-review, wontfix,
#        discussion, duplicate, invalid, agent-console, or any blocked:*).
#   bash draft-pr-recovery.sh is-body-empty          < body.txt
#   bash draft-pr-recovery.sh has-wip-marker         < title-and-body.txt
#     -> true on a standalone "WIP" token or "do not merge" (case-insensitive).
#   bash draft-pr-recovery.sh has-unchecked-tasks    < body.txt
#     -> true if any `- [ ]` / `* [ ]` markdown task item is unchecked.
#
# Usage — live enforcement:
#   bash draft-pr-recovery.sh enforce --repo <owner/repo> [--author <login>] [--dry-run]
#     Lists open draft PRs authored by --author (default: @me — the identity
#     driving this /do-work session, so every candidate is trust-scoped by
#     construction; this is deliberately narrower than "any trusted author"),
#     classifies each via classify-one, and acts:
#       ready              -> `gh pr ready`, then arm auto-merge the same
#                              gated/ungated-aware way issue-work.md step 6.a
#                              does (see detect-ungated-admin-direct-merge.sh).
#                              On the ungated shape, ready it but do NOT block
#                              this setup-time call on `--watch` — leave a
#                              comment saying manual merge is needed once CI
#                              settles (watching CI synchronously inside setup
#                              would stall every other setup step for a
#                              single inherited PR).
#       hand-back:*        -> ensure `needs-human-review` exists + apply it
#                              (skipped when the PR already carries a gate
#                              label — `hand-back:gated-label` means one is
#                              already there, so re-applying + re-commenting
#                              would be pure noise) + a one-line comment
#                              explaining which signal tripped.
#       skip:not-agent-authored -> no-op; not shipyard's stranded output.
#     Prints one JSON object per line to stdout for every PR that was NOT
#     skip:not-agent-authored (this is what the caller folds into the
#     end-of-session summary): {"number":N,"disposition":"...","action":"...","url":"..."}
#     --dry-run performs the identical classification and printed JSON with
#     `action` prefixed `would-` and NO gh mutations.
#
# Fail-safe posture: any signal that cannot be read resolves toward NOT
# auto-readying (unknown agent-authorship -> not-agent-authored; unreadable
# closing-issue state -> treat as closed/stale; unreadable body -> treat as
# empty). Skipping a genuinely-safe candidate costs nothing (it stays a
# normal open draft for a human or a future session to pick up); auto-ready
# ing a genuinely-unsafe one merges dead or unwanted work.

set -uo pipefail

GH="${GH:-gh}"
GATED_LABEL_RE='^(needs-human-review|wontfix|discussion|duplicate|invalid|agent-console|blocked:.*)$'

# ---------------------------------------------------------------------------
# Pure decision. No I/O. This is the whole classification rule.
# ---------------------------------------------------------------------------
classify_one() {
  local agent_authored="$1" gated_label="$2" closing_ref_count="$3" \
        any_closing_closed="$4" body_empty="$5" body_wip_marker="$6" \
        body_unchecked_tasks="$7"

  if [ "$agent_authored" != "true" ]; then
    printf 'skip:not-agent-authored\n'
    return 0
  fi
  if [ "$gated_label" = "true" ]; then
    printf 'hand-back:gated-label\n'
    return 0
  fi
  case "$closing_ref_count" in
    ''|*[!0-9]*) closing_ref_count=0 ;;
  esac
  if [ "$closing_ref_count" -eq 0 ]; then
    printf 'hand-back:no-closing-ref\n'
    return 0
  fi
  if [ "$any_closing_closed" = "true" ]; then
    printf 'hand-back:stale-closing-issue\n'
    return 0
  fi
  if [ "$body_empty" = "true" ]; then
    printf 'hand-back:empty-body\n'
    return 0
  fi
  if [ "$body_wip_marker" = "true" ]; then
    printf 'hand-back:wip-marker\n'
    return 0
  fi
  if [ "$body_unchecked_tasks" = "true" ]; then
    printf 'hand-back:unchecked-tasks\n'
    return 0
  fi
  printf 'ready\n'
}

# ---------------------------------------------------------------------------
# Pure signal extractors. Each reads its input on stdin, prints true/false.
# ---------------------------------------------------------------------------
agent_authored_check() {
  local text
  text="$(cat)"
  if printf '%s' "$text" | grep -qiE 'co-authored-by:.*claude|^claude-session:'; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

gated_label_check() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if printf '%s' "$line" | grep -qE "$GATED_LABEL_RE"; then
      printf 'true\n'
      return 0
    fi
  done
  printf 'false\n'
}

is_body_empty() {
  local text
  text="$(cat | tr -d '[:space:]')"
  if [ -z "$text" ]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

has_wip_marker() {
  local text
  text="$(cat)"
  if printf '%s' "$text" | grep -qiE '(^|[^[:alnum:]])wip([^[:alnum:]]|$)|do not merge'; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

has_unchecked_tasks() {
  local text
  text="$(cat)"
  if printf '%s' "$text" | grep -qE '^[[:space:]]*[-*][[:space:]]\[[[:space:]]\]'; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

# ---------------------------------------------------------------------------
# Live enforcement.
# ---------------------------------------------------------------------------
json_escape() {
  # Minimal JSON string escaping for the fields we interpolate ourselves.
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
}

enforce() {
  local repo="" author="@me" dry_run="false"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --author) author="$2"; shift 2 ;;
      --dry-run) dry_run="true"; shift ;;
      *) echo "enforce: unrecognized argument $1" >&2; return 64 ;;
    esac
  done
  if [ -z "$repo" ]; then
    echo "usage: $0 enforce --repo <owner/repo> [--author <login>] [--dry-run]" >&2
    return 64
  fi

  local numbers
  numbers="$("$GH" pr list --repo "$repo" --state open --author "$author" \
    --search 'is:draft' --json number --jq '.[].number' 2>/dev/null)"
  [ -z "$numbers" ] && return 0

  local method
  method="$(shipyard_config_get auto_merge.method)"
  case "$method" in squash|merge|rebase) ;; *) method="squash" ;; esac

  local n
  for n in $numbers; do
    process_one_pr "$repo" "$n" "$method" "$dry_run"
  done
}

# Resolve auto_merge.method via shipyard-config.sh if reachable; default squash.
shipyard_config_get() {
  local key="$1" root cfg
  root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  cfg="${root}/scripts/shipyard-config.sh"
  if [ -f "$cfg" ]; then
    bash "$cfg" get "$key" 2>/dev/null
  fi
}

process_one_pr() {
  local repo="$1" n="$2" method="$3" dry_run="$4"

  local view
  view="$("$GH" pr view "$n" --repo "$repo" \
    --json number,url,body,title,labels,closingIssuesReferences,commits \
    --jq '{number, url, title, body, labels: [.labels[].name], closing: [.closingIssuesReferences[]?.number], commits: [.commits[]?.messageBody // ""]}' 2>/dev/null)"
  [ -z "$view" ] && return 0

  # Commit trailers (agent-authorship signal).
  local commit_text agent_authored
  commit_text="$(printf '%s' "$view" | jq -r '.commits[]' 2>/dev/null)"
  agent_authored="$(printf '%s' "$commit_text" | agent_authored_check)"

  # Labels (gate signal).
  local labels gated
  labels="$(printf '%s' "$view" | jq -r '.labels[]' 2>/dev/null)"
  gated="$(printf '%s\n' "$labels" | gated_label_check)"

  # closingIssuesReferences state — GraphQL directly for state/stateReason,
  # since `gh pr view --json closingIssuesReferences` does not expose them.
  local owner name closing_count any_closed
  owner="${repo%%/*}"; name="${repo##*/}"
  local closing_states
  # The $o/$r/$n inside the query string are GraphQL variable references, not
  # shell expansions; they're bound below via -F, deliberately not
  # shell-interpolated (avoids injecting untrusted owner/repo/number text
  # straight into the query document).
  # shellcheck disable=SC2016
  closing_states="$("$GH" api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){closingIssuesReferences(first:20){nodes{number state}}}}}' \
    -F o="$owner" -F r="$name" -F n="$n" \
    --jq '.data.repository.pullRequest.closingIssuesReferences.nodes[].state' 2>/dev/null)"
  closing_count="$(printf '%s' "$closing_states" | grep -c . || true)"
  any_closed="false"
  if printf '%s\n' "$closing_states" | grep -qx 'CLOSED'; then
    any_closed="true"
  fi

  # Body signals.
  local body title body_empty wip unchecked
  body="$(printf '%s' "$view" | jq -r '.body // ""')"
  title="$(printf '%s' "$view" | jq -r '.title // ""')"
  body_empty="$(printf '%s' "$body" | is_body_empty)"
  wip="$(printf '%s\n%s' "$title" "$body" | has_wip_marker)"
  unchecked="$(printf '%s' "$body" | has_unchecked_tasks)"

  local disposition
  disposition="$(classify_one "$agent_authored" "$gated" "$closing_count" "$any_closed" "$body_empty" "$wip" "$unchecked")"

  [ "$disposition" = "skip:not-agent-authored" ] && return 0

  local url action
  url="$(printf '%s' "$view" | jq -r '.url')"

  if [ "$disposition" = "ready" ]; then
    if [ "$dry_run" = "true" ]; then
      action="would-ready-and-arm-auto-merge"
    else
      "$GH" pr ready "$n" --repo "$repo" >/dev/null 2>&1
      local verdict
      verdict="$(detect_ungated "$repo")"
      if [ "$verdict" = "ungated" ]; then
        action="readied-manual-merge-needed"
        "$GH" pr comment "$n" --repo "$repo" \
          --body "Recovered inherited draft PR (issue #1069): marked ready. This repo's admin-direct-merge shape means \`--auto\` would bypass CI — merge manually once checks settle green." >/dev/null 2>&1
      else
        "$GH" pr merge "$n" --repo "$repo" --auto --"$method" --delete-branch >/dev/null 2>&1
        action="readied-and-auto-merge-armed"
      fi
    fi
  else
    if [ "$dry_run" = "true" ]; then
      action="would-hand-back"
    else
      action="handed-back"
      if [ "$gated" != "true" ]; then
        "$GH" label create needs-human-review --repo "$repo" \
          --description "Worked on by /shipyard:do-work" 2>/dev/null || true
        "$GH" pr edit "$n" --repo "$repo" --add-label needs-human-review >/dev/null 2>&1
        "$GH" pr comment "$n" --repo "$repo" \
          --body "Recovered inherited draft PR (issue #1069): left in draft — ${disposition#hand-back:} — needs a human look before merging." >/dev/null 2>&1
      fi
    fi
  fi

  printf '{"number":%s,"disposition":"%s","action":"%s","url":"%s"}\n' \
    "$n" "$(json_escape "$disposition")" "$(json_escape "$action")" "$(json_escape "$url")"
}

detect_ungated() {
  local repo="$1" root detector
  # Test seam: detect-ungated-admin-direct-merge.sh itself calls the literal
  # `gh` binary (not the $GH override this script otherwise honors), so a
  # hermetic test can't intercept it via $GH alone. Let a test force the
  # verdict directly instead of mocking the sub-script's own gh calls.
  if [ -n "${DRAFT_PR_RECOVERY_VERDICT_OVERRIDE:-}" ]; then
    printf '%s\n' "$DRAFT_PR_RECOVERY_VERDICT_OVERRIDE"
    return 0
  fi
  root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  detector="${root}/scripts/detect-ungated-admin-direct-merge.sh"
  if [ -f "$detector" ]; then
    bash "$detector" "$repo" 2>/dev/null
  else
    echo "gated"
  fi
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    classify-one)
      if [ "$#" -ne 7 ]; then
        echo "usage: $0 classify-one <agent_authored> <gated_label> <closing_ref_count> <any_closing_closed> <body_empty> <body_wip_marker> <body_unchecked_tasks>" >&2
        exit 64
      fi
      classify_one "$@"
      ;;
    agent-authored-check) agent_authored_check ;;
    gated-label-check) gated_label_check ;;
    is-body-empty) is_body_empty ;;
    has-wip-marker) has_wip_marker ;;
    has-unchecked-tasks) has_unchecked_tasks ;;
    enforce) enforce "$@" ;;
    *)
      echo "usage: $0 {classify-one|agent-authored-check|gated-label-check|is-body-empty|has-wip-marker|has-unchecked-tasks|enforce} ..." >&2
      exit 64
      ;;
  esac
}

main "$@"

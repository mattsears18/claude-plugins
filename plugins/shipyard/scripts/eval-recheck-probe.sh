#!/usr/bin/env bash
# eval-recheck-probe.sh — allowlist-only evaluator for a `<!-- do-work-recheck:
# <verb> <args...> -->` issue-body marker (issue #1198, follow-up to #1195/#1199).
#
# Background
# ----------
# #1195 gave `external-dependency` scope-preflight defers a self-clearing
# `<!-- do-work-blocked-until: YYYY-MM-DD -->` body marker so the proactive
# operator sweep stops re-litigating an unchanged upstream fact every tick —
# but that marker is a blind calendar gate: it can only ever say "don't look
# again before this date," never "the condition actually changed." #1198 asks
# for a *recorded probe* companion marker that names a mechanically-checkable
# command, turning "re-investigate from scratch" into "run one command and
# compare" for the (common) case where the blocking condition genuinely is
# testable by a single read-only call.
#
# THIS IS A UNTRUSTED-INPUT-TO-CODE-EXECUTION SURFACE. The marker lives in a
# GitHub issue body — content that, per this repo's own worker-preamble
# discipline, is treated as untrusted regardless of the issue author's trust
# level, because the body can be edited by a third party (any collaborator,
# or the issue's own author under outside influence) after the orchestrator's
# author-trust check already ran. This script is the ONE place that marker
# text is allowed to influence what command runs, and it is deliberately
# narrow:
#
#   - ALLOWLIST ONLY. Exactly two verbs are recognized: `npm-view` (a
#     package-registry field lookup) and `gh-api` (a read-only GET against a
#     narrow set of GitHub REST sub-resources, scoped to the CURRENT repo
#     only). Anything else — a different verb, a malformed argument, an
#     extra/missing token — is REJECTED. There is no free-form fallback and
#     no attempt to sanitize a shell string; a marker that doesn't match one
#     of the two fixed grammars below is simply never executed.
#   - NO SHELL EVER SEES THE MARKER TEXT. Every field is validated against an
#     anchored (`^...$`) character-class regex BEFORE use, then passed as its
#     own element of a bash array (`"${cmd[@]}"`) to a fixed binary (`npm` or
#     `gh`) — never through `eval`, never interpolated into a `sh -c` string,
#     never concatenated into a command line. Because bash arrays preserve
#     argument boundaries regardless of content, even a regex gap could not
#     smuggle a second command — there is no shell parse step for it to
#     escape into.
#   - READ-ONLY, NO CREDENTIALS BEYOND WHAT'S ALREADY THERE. `npm view` never
#     installs or runs package scripts. `gh api` is invoked with no `-X` /
#     `--method` / `--input` — it is a GET request, and the endpoint allowlist
#     below excludes every mutation-adjacent or secret-adjacent sub-resource
#     (no `secrets`, `hooks`, `keys`, `deploy_keys`, `actions`, `collaborators`,
#     `teams`). It piggybacks on the orchestrator's own already-authorized
#     `gh` session exactly the way every other read in this plugin does — it
#     is not a new credential and cannot write anything.
#   - EVERY FAILURE MODE DEGRADES TO "unknown", NEVER TO "changed" (which
#     would bypass the blocked-until calendar gate) OR SILENTLY TO "unchanged"
#     with no signal. A malformed marker, an unrecognized verb, a probe that
#     errors, times out, or returns empty/unexpected output, and a network
#     failure all produce `unknown` on stdout plus a one-line reason on
#     stderr. The caller's job (see the "Caller contract" section below) is
#     to treat `unknown` exactly like `unchanged` — fall through to the plain
#     calendar check, never treat an inconclusive probe as proof the
#     condition resolved.
#
# Marker grammar
# ---------------
#   <!-- do-work-recheck: npm-view <pkg> <field> == <expected> -->
#   <!-- do-work-recheck: gh-api <endpoint> <jq-field> == <expected> -->
#
#   npm-view:
#     <pkg>      an (optionally scoped) npm package name, no version/tag —
#                always resolves against whatever is currently tagged
#                `latest`, since the point is detecting drift in the CURRENT
#                published state, not re-reading an immutable historical
#                version.        regex: ^(@[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*|[a-z0-9][a-z0-9._-]*)$
#     <field>    a dotted field path npm view understands natively (e.g.
#                `dependencies.image-size`, `dist-tags.latest`, `version`).
#                Intended for SCALAR fields only — an array/object field's
#                default-format rendering isn't a stable comparison target.
#                                regex: ^[A-Za-z0-9_.-]+$
#     <expected> the value recorded at diagnosis time.
#                                regex: ^[A-Za-z0-9_.-]+$
#
#   gh-api:
#     <endpoint> `repos/<owner>/<repo>/<allowed-subresource>`, where
#                <owner>/<repo> MUST equal the `<owner/repo>` this script was
#                invoked with (no cross-repo probing) and <allowed-subresource>
#                is one of: releases/latest, tags, commits/<sha>, issues/<n>,
#                pulls/<n>. Every other sub-resource is rejected, including
#                ones that are technically GET-safe (e.g. `collaborators`) —
#                narrower than the issue's own suggested direction on
#                purpose; widen the allowlist only with a deliberate,
#                reviewed change, never by relaxing the regex to "whatever
#                the marker happens to say".
#     <jq-field> a restricted jq path — dotted field names and integer
#                array indices only, no pipes, no filters, no functions.
#                                regex: ^\.[A-Za-z0-9_]+(\.[A-Za-z0-9_]+|\[[0-9]+\])*$
#     <expected> same as npm-view's.
#
#   Both grammars require a literal ` == ` token between <field>/<jq-field>
#   and <expected> — the token separates the "what to check" tokens from the
#   "what value it should still equal" token and doubles as a format sanity
#   check. Anything not matching one of these two full shapes is rejected —
#   invalid, not "best-effort parsed".
#
# Caller contract
# ----------------
#   bash eval-recheck-probe.sh <owner/repo>          (issue body on stdin)
#     -> prints exactly one of `absent` / `unchanged` / `changed` / `unknown`
#        on stdout; diagnostics on stderr. Always exits 0 — this script
#        reports a verdict, it does not fail (a usage error is the one
#        exception, see below).
#
#   `absent`    -> no `do-work-recheck:` marker in the body. Caller falls
#                  through to the plain `do-work-blocked-until` date check —
#                  behavior is byte-for-byte unchanged from before this
#                  script existed.
#   `unchanged` -> the probe ran and matched the recorded `<expected>` value.
#                  The blocking condition, by this evidence, still holds —
#                  fall through to the plain date check (same as `absent`).
#   `changed`   -> the probe ran and did NOT match `<expected>`. The upstream
#                  fact has moved — the caller should treat this the same as
#                  the blocked-until date having elapsed (re-admit the issue
#                  for a fresh look) REGARDLESS of whether the calendar date
#                  is still in the future. This is the one case that can
#                  bring re-evaluation forward.
#   `unknown`   -> marker present but invalid, OR the probe errored / timed
#                  out / returned nothing / returned something that doesn't
#                  parse. Fall through to the plain date check — identical
#                  to `absent`/`unchanged`. NEVER treat `unknown` as `changed`.
#
#   Hermetic modes (no network, for tests and callers that already hold the
#   pieces):
#     bash eval-recheck-probe.sh --validate <owner/repo> <marker-rest>
#       -> exit 0 (valid, prints "<verb>|<arg1>|<arg2>|<expected>") or exit 1
#          (invalid, prints "invalid").
#     bash eval-recheck-probe.sh --decide <actual> <expected>
#       -> prints `unchanged` / `changed` / `unknown` — the pure comparison,
#          given an already-fetched actual value.
#
# Fail-safe posture (mirrors detect-ungated-admin-direct-merge.sh's stated
# posture): any signal this script cannot obtain or validate resolves toward
# `unknown`, i.e. toward the SLOWER but SAFE path (wait for the calendar
# date). Under-triggering a re-check costs a little re-litigation latency;
# over-triggering by treating an inconclusive read as "confirmed changed"
# would mean an untrusted, unvalidated signal controls when an issue gets
# re-admitted to the dispatch pool. The asymmetry is deliberate.

set -uo pipefail

RECHECK_PROBE_TIMEOUT_SECONDS="${RECHECK_PROBE_TIMEOUT_SECONDS:-15}"

# ---------------------------------------------------------------------------
# Pure functions — no I/O, no network. Fully covered by the hermetic test
# modes above.
# ---------------------------------------------------------------------------

extract_marker() {
  # $1 = issue body (may be multi-line). Prints the FIRST marker's inner
  # text (everything between "do-work-recheck: " and " -->"), or nothing.
  local body="$1"
  printf '%s\n' "$body" \
    | grep -oE '^<!-- do-work-recheck: .+ -->$' \
    | head -1 \
    | sed -E 's/^<!-- do-work-recheck: (.*) -->$/\1/'
}

validate_and_extract() {
  # $1 = marker inner text (everything the caller got from extract_marker,
  #      or the raw --validate CLI argument)
  # $2 = the "<owner>/<repo>" this evaluation is scoped to (gh-api endpoints
  #      may only reference this exact repo — no cross-repo probing)
  #
  # On success: prints "<verb>|<arg1>|<arg2>|<expected>" and returns 0.
  # On failure: prints nothing and returns 1. Never partial — a rejected
  # marker yields no extracted fields at all.
  local rest="$1" owner_repo="$2"
  local -a tok
  # Word-splitting on IFS, not a shell re-parse of the string — this cannot
  # execute anything and cannot be tricked into producing more than one
  # command; it just tokenizes on whitespace.
  read -r -a tok <<<"$rest"

  local verb="${tok[0]:-}"
  case "$verb" in
    npm-view)
      [ "${#tok[@]}" -eq 5 ] || return 1
      local pkg="${tok[1]}" field="${tok[2]}" eq="${tok[3]}" expected="${tok[4]}"
      [ "$eq" = "==" ] || return 1
      [[ "$pkg" =~ ^(@[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*|[a-z0-9][a-z0-9._-]*)$ ]] || return 1
      [[ "$field" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
      [[ "$expected" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
      printf 'npm-view|%s|%s|%s\n' "$pkg" "$field" "$expected"
      return 0
      ;;
    gh-api)
      [ "${#tok[@]}" -eq 5 ] || return 1
      local endpoint="${tok[1]}" jqfield="${tok[2]}" eq="${tok[3]}" expected="${tok[4]}"
      [ "$eq" = "==" ] || return 1
      [[ "$endpoint" =~ ^repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(releases/latest|tags|commits/[0-9A-Fa-f]+|issues/[0-9]+|pulls/[0-9]+)$ ]] || return 1
      local ep_owner="${BASH_REMATCH[1]}" ep_repo="${BASH_REMATCH[2]}"
      [ "${ep_owner}/${ep_repo}" = "$owner_repo" ] || return 1
      [[ "$jqfield" =~ ^\.[A-Za-z0-9_]+(\.[A-Za-z0-9_]+|\[[0-9]+\])*$ ]] || return 1
      [[ "$expected" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
      printf 'gh-api|%s|%s|%s\n' "$endpoint" "$jqfield" "$expected"
      return 0
      ;;
    *)
      # Unrecognized verb — the allowlist is exhaustive; anything else is
      # rejected outright, never "attempted" or "best-effort sanitized".
      return 1
      ;;
  esac
}

decide() {
  # $1 = actual value already fetched (already trimmed by the caller),
  # $2 = expected value. Pure string comparison.
  local actual="$1" expected="$2"
  if [ -z "$actual" ]; then
    printf 'unknown\n'
    return 0
  fi
  if [ "$actual" = "$expected" ]; then
    printf 'unchanged\n'
  else
    printf 'changed\n'
  fi
}

# ---------------------------------------------------------------------------
# Impure — the two allowlisted probe executions. Fixed binary, argv array,
# bounded timeout, stderr discarded (never leaks into the compared value).
# ---------------------------------------------------------------------------

run_npm_view() {
  local pkg="$1" field="$2"
  local -a cmd=(npm view "$pkg" "$field")
  if command -v timeout >/dev/null 2>&1; then
    timeout "${RECHECK_PROBE_TIMEOUT_SECONDS}s" "${cmd[@]}" 2>/dev/null
  else
    "${cmd[@]}" 2>/dev/null
  fi
}

run_gh_api() {
  local endpoint="$1" jqfield="$2"
  local -a cmd=(gh api "$endpoint" --jq "$jqfield")
  if command -v timeout >/dev/null 2>&1; then
    timeout "${RECHECK_PROBE_TIMEOUT_SECONDS}s" "${cmd[@]}" 2>/dev/null
  else
    "${cmd[@]}" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
main() {
  if [ "${1:-}" = "--decide" ]; then
    if [ "$#" -ne 3 ]; then
      echo "usage: $0 --decide <actual> <expected>" >&2
      exit 1
    fi
    decide "$2" "$3"
    exit 0
  fi

  if [ "${1:-}" = "--validate" ]; then
    if [ "$#" -lt 3 ]; then
      echo "usage: $0 --validate <owner/repo> <marker-rest...>" >&2
      exit 1
    fi
    local owner_repo="$2"
    shift 2
    local rest="$*"
    local parsed
    if parsed="$(validate_and_extract "$rest" "$owner_repo")"; then
      printf '%s\n' "$parsed"
      exit 0
    else
      echo "invalid"
      exit 1
    fi
  fi

  local owner_repo="${1:-}"
  if [ -z "$owner_repo" ]; then
    echo "usage: $0 <owner/repo>   (reads the issue body on stdin)" >&2
    echo "       $0 --validate <owner/repo> <marker-rest...>" >&2
    echo "       $0 --decide <actual> <expected>" >&2
    exit 1
  fi

  local body marker parsed verb arg1 arg2 expected actual
  body="$(cat)"

  marker="$(extract_marker "$body")"
  if [ -z "$marker" ]; then
    printf 'absent\n'
    exit 0
  fi

  if ! parsed="$(validate_and_extract "$marker" "$owner_repo")"; then
    echo "eval-recheck-probe: marker present but failed allowlist validation (\"${marker}\") — treating as unknown" >&2
    printf 'unknown\n'
    exit 0
  fi

  IFS='|' read -r verb arg1 arg2 expected <<<"$parsed"

  case "$verb" in
    npm-view) actual="$(run_npm_view "$arg1" "$arg2")" ;;
    gh-api)   actual="$(run_gh_api "$arg1" "$arg2")" ;;
    *)        actual="" ;;
  esac
  # Defensive trim: take the first line only and strip all whitespace, in
  # case the probe's output format drifts (extra whitespace, a trailing
  # newline, or — for npm view on an unexpected field shape — multi-line
  # array/object rendering). A field that doesn't reduce to a clean scalar
  # simply won't match `<expected>` and reports `changed` rather than
  # crashing; see the npm-view grammar note above about scalar-only fields.
  actual="$(printf '%s' "$actual" | head -1 | tr -d '[:space:]')"

  if [ -z "$actual" ]; then
    echo "eval-recheck-probe: probe (${verb} ${arg1} ${arg2}) produced no output — error, timeout, or empty field; treating as unknown" >&2
    printf 'unknown\n'
    exit 0
  fi

  decide "$actual" "$expected"
}

main "$@"

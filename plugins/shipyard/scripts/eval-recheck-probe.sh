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
#   - ALLOWLIST ONLY. Exactly three verbs are recognized: `npm-view` (a
#     package-registry field lookup), `gh-api` (a read-only GET against a
#     narrow set of GitHub REST sub-resources, scoped to the CURRENT repo
#     only), and `url-json` (a read-only HTTPS GET against a host the repo's
#     own COMMITTED config has explicitly allowlisted — issue #1496).
#     Anything else — a different verb, a malformed argument, an
#     extra/missing token — is REJECTED. There is no free-form fallback and
#     no attempt to sanitize a shell string; a marker that doesn't match one
#     of the three fixed grammars below is simply never executed.
#   - `url-json` IS NOT A GENERAL-PURPOSE FETCH PRIMITIVE, and is not a
#     general-purpose one by accident of configuration either: its host set
#     is EMPTY by default (`scope.recheck_probe_url_hosts: []`), so on a
#     repo that has not deliberately opted in, every `url-json` marker
#     resolves to `unknown` and NOTHING IS EVER REQUESTED. Widening it takes
#     a reviewed edit to the repo's committed `shipyard.config.json` — a
#     far higher trust boundary than the issue body the marker itself lives
#     in. That asymmetry is the entire design: someone who can edit an issue
#     body still cannot choose which host gets contacted, only which of the
#     already-approved hosts does. #1496 left "is an arbitrary outbound host
#     acceptable at all" open as a deliberate design question; this is the
#     answer — no arbitrary hosts, per-repo opt-in only, and the opt-in
#     itself is reviewable in a PR.
#   - NO SHELL EVER SEES THE MARKER TEXT. Every field is validated against an
#     anchored (`^...$`) character-class regex BEFORE use, then passed as its
#     own element of a bash array (`"${cmd[@]}"`) to a fixed binary (`npm`,
#     `gh`, or `curl`) — never through `eval`, never interpolated into a
#     `sh -c` string,
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
#     is not a new credential and cannot write anything. `curl` (url-json)
#     is invoked with `--request GET`, no `-d`/`--data`, no `-b`/`--cookie`,
#     no `-u`, no `--netrc`, and no header beyond a fixed
#     `Accept: application/json` — it carries no ambient credential at all,
#     and no redirect is ever followed, so it cannot be walked off the
#     allowlisted host onto something else.
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
#   url-json (issue #1496):
#     <url>      an absolute `https://` URL. HTTPS ONLY (never `http://`,
#                never any other scheme), no userinfo (`@`), no port (`:`),
#                no fragment (`#`), no shell metacharacter of any kind, and
#                a DNS host name whose LAST label is alphabetic — so a bare
#                IP literal (`127.0.0.1`, or the cloud metadata address
#                `169.254.169.254`) can never be named at all. Capped at 500
#                characters. The host must ALSO appear in the repo's
#                `scope.recheck_probe_url_hosts` config array, which is
#                empty by default; see the allowlist note above.
#                                regex: ^https://([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z][a-z]+)(/[A-Za-z0-9._~=+,%-]*)*(\?[A-Za-z0-9._~=+,%&-]*)?$
#     <jq-filter> the same restricted jq path `gh-api` accepts, plus ONE
#                optional trailing `|length` written with NO surrounding
#                spaces (so the marker stays exactly five whitespace-
#                separated tokens — the shared 5-token shape is what lets
#                every downstream consumer, including the authorship path's
#                marker reconstruction, stay verb-agnostic). No other pipe,
#                filter, or function: `length` is allowed because "how many
#                entries does this feed have" is the single most common
#                event-gate shape and is not otherwise expressible.
#                                regex: ^\.[A-Za-z0-9_]+(\.[A-Za-z0-9_]+|\[[0-9]+\])*(\|length)?$
#     <expected> same as npm-view's.
#
#     Execution: ONE `curl` GET — no request body, no cookies, no
#     credentials, no custom header beyond a fixed
#     `Accept: application/json`, `--proto '=https'`, and NO `-L` (a 3xx is
#     never followed, and only a 2xx status is accepted, so a redirect
#     resolves to `unknown` instead of quietly landing on a host nobody
#     allowlisted). Bounded by `--max-time` / the `timeout` binary and by a
#     response-size cap (`scope.recheck_probe_max_bytes`, default 1 MiB)
#     enforced BOTH by curl and by an in-script byte count — curl's own
#     `--max-filesize` only fires when the server declares a Content-Length.
#     A non-2xx, a body that isn't JSON, a filter that yields nothing, and a
#     filter that yields `null` all resolve to `unknown`, never `changed`.
#
#   All three grammars require a literal ` == ` token between the field /
#   filter token and <expected> — the token separates the "what to check"
#   tokens from the "what value it should still equal" token and doubles as
#   a format sanity check. Anything not matching one of these three full
#   shapes is rejected — invalid, not "best-effort parsed".
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
#       -> exit 0 (valid, prints "<verb>\t<arg1>\t<arg2>\t<expected>",
#          TAB-separated) or exit 1 (invalid, prints "invalid"). The
#          separator is a TAB rather than the `|` used before #1496 because
#          `url-json`'s jq filter may itself contain a `|` (its one
#          permitted operator, `|length`); a tab cannot appear in ANY
#          validated field, since every field regex excludes whitespace.
#     bash eval-recheck-probe.sh --decide <actual> <expected>
#       -> prints `unchanged` / `changed` / `unknown` — the pure comparison,
#          given an already-fetched actual value.
#
#   Bulk mode (issue #1356 — generalizing the marker beyond a single
#   external-dependency-class caller so ANY defer class carrying a
#   `do-work-recheck` marker can be evaluated by a single, batched pass over
#   a whole backlog fetch, rather than one `gh issue view` + one subprocess
#   per issue at each call site):
#     bash eval-recheck-probe.sh --bulk <owner/repo>
#       (NDJSON `{"number":N,"body":"<body>"}` on stdin, one line per issue —
#       exactly the `number`/`body` fields already present in the wide-fetch
#       payload `backlog-filter.sh classify` reads, so a caller that already
#       holds that payload needs no extra `gh` round-trip to build this
#       input.)
#       -> prints NDJSON `{"number":N,"verdict":"<verdict>"}` on stdout, but
#          ONLY for lines whose verdict is NOT `absent` — an issue with no
#          `do-work-recheck` marker at all produces no output line, so the
#          caller's downstream `{number: verdict}` map naturally has no
#          entry for it (silence, not a wasted "absent" line, for what is
#          overwhelmingly the common case across a whole backlog). Each
#          line's body is evaluated with EXACTLY the same logic as the
#          single-issue mode above — this is a thin iteration wrapper, not a
#          second implementation. A malformed input line (bad JSON, missing
#          `number`) is skipped with a diagnostic on stderr; it never aborts
#          the batch. Always exits 0.
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

# url-json policy (issue #1496), resolved lazily and cached — and ONLY when a
# `url-json` marker is actually encountered, so the two pre-existing verbs
# keep byte-for-byte their previous behavior with no new config subprocess
# and no new failure mode on their path.
_URL_POLICY_LOADED=""
_URL_ALLOWED_HOSTS=""
_URL_MAX_BYTES=""

# ---------------------------------------------------------------------------
# url-json policy — the per-repo host allowlist and the response-size cap.
# Hermetic: reads only the merged shipyard config (no network), and only on
# first use. Env vars win over config, so tests stay self-contained and a
# caller that already resolved the merged config can pass it straight
# through. EVERY failure to resolve config degrades to "no host is allowed",
# i.e. toward `unknown` — the same asymmetry the rest of this script keeps.
# ---------------------------------------------------------------------------

load_url_policy() {
  if [ -n "$_URL_POLICY_LOADED" ]; then
    return 0
  fi
  _URL_POLICY_LOADED=1

  local scope_json="" cfg
  cfg="$(dirname "${BASH_SOURCE[0]}")/shipyard-config.sh"
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    scope_json="$(bash "$cfg" get scope 2>/dev/null)" || scope_json=""
  fi

  if [ -n "${RECHECK_PROBE_URL_HOSTS+x}" ]; then
    _URL_ALLOWED_HOSTS="$RECHECK_PROBE_URL_HOSTS"
  elif [ -n "$scope_json" ]; then
    _URL_ALLOWED_HOSTS="$(printf '%s' "$scope_json" | jq -r '
      if (.recheck_probe_url_hosts | type) == "array"
      then [.recheck_probe_url_hosts[] | select(type == "string")] | join(" ")
      else "" end' 2>/dev/null)"
  fi

  if [ -n "${RECHECK_PROBE_MAX_BYTES:-}" ]; then
    _URL_MAX_BYTES="$RECHECK_PROBE_MAX_BYTES"
  elif [ -n "$scope_json" ]; then
    _URL_MAX_BYTES="$(printf '%s' "$scope_json" | jq -r '
      if (.recheck_probe_max_bytes | type) == "number"
      then (.recheck_probe_max_bytes | tostring)
      else "" end' 2>/dev/null)"
  fi
  case "$_URL_MAX_BYTES" in
    '' | *[!0-9]*) _URL_MAX_BYTES=1048576 ;;
  esac
  if [ "$_URL_MAX_BYTES" -le 0 ]; then
    _URL_MAX_BYTES=1048576
  fi
}

url_host_allowed() {
  # $1 = the lowercase host already extracted from a shape-validated URL.
  # EXACT match only — no wildcards, no implicit subdomain match. A repo that
  # wants a subdomain lists that subdomain; "narrow, and widened only
  # deliberately" is the same philosophy the gh-api sub-resource list keeps.
  local host="$1" entry
  load_url_policy
  if [ -z "$_URL_ALLOWED_HOSTS" ]; then
    return 1
  fi
  # shellcheck disable=SC2086
  # Word-splitting on whitespace is intended: the allowlist is a
  # space-separated host list assembled by load_url_policy from a JSON array.
  for entry in $_URL_ALLOWED_HOSTS; do
    entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    if [ "$entry" = "$host" ]; then
      return 0
    fi
  done
  return 1
}

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
  # On success: prints "<verb>\t<arg1>\t<arg2>\t<expected>" (TAB-separated —
  # see the --validate note in the header: url-json's jq filter can contain a
  # `|`, and no validated field can ever contain whitespace) and returns 0.
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
      printf 'npm-view\t%s\t%s\t%s\n' "$pkg" "$field" "$expected"
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
      printf 'gh-api\t%s\t%s\t%s\n' "$endpoint" "$jqfield" "$expected"
      return 0
      ;;
    url-json)
      # Issue #1496. Deliberately the narrowest of the three grammars: the
      # shape check below rejects every non-HTTPS scheme, every credential /
      # port / fragment form, and every IP-literal host, and THEN the host
      # must still be named in the repo's committed allowlist (empty by
      # default) before the marker is considered valid at all. A marker
      # naming a non-allowlisted host is `invalid`, exactly like a malformed
      # one — so the authorship path never writes it and the read path never
      # runs it.
      [ "${#tok[@]}" -eq 5 ] || return 1
      local url="${tok[1]}" jqfilter="${tok[2]}" eq="${tok[3]}" expected="${tok[4]}"
      [ "$eq" = "==" ] || return 1
      [ "${#url}" -le 500 ] || return 1
      [[ "$url" =~ ^https://([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z][a-z]+)(/[A-Za-z0-9._~=+,%-]*)*(\?[A-Za-z0-9._~=+,%&-]*)?$ ]] || return 1
      local host="${BASH_REMATCH[1]}"
      url_host_allowed "$host" || return 1
      [[ "$jqfilter" =~ ^\.[A-Za-z0-9_]+(\.[A-Za-z0-9_]+|\[[0-9]+\])*(\|length)?$ ]] || return 1
      [[ "$expected" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
      printf 'url-json\t%s\t%s\t%s\n' "$url" "$jqfilter" "$expected"
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

run_url_json() {
  # $1 = a shape-validated, host-allowlisted https URL; $2 = a validated jq
  # filter. Prints the probed scalar on stdout, or NOTHING (the caller
  # resolves an empty result to `unknown`). Issue #1496.
  local url="$1" jqfilter="$2"
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  load_url_policy

  # No -L: a redirect is never followed. No -d/-b/-u/--netrc: no body, no
  # cookies, no credentials. One fixed Accept header, nothing marker-derived.
  local -a cmd=(curl
    --silent
    --request GET
    --proto '=https'
    --max-redirs 0
    --max-time "$RECHECK_PROBE_TIMEOUT_SECONDS"
    --max-filesize "$_URL_MAX_BYTES"
    --header 'Accept: application/json'
    --user-agent 'shipyard-eval-recheck-probe'
    --write-out '\n%{http_code}'
    --url "$url")

  local raw
  if command -v timeout >/dev/null 2>&1; then
    raw="$(timeout "${RECHECK_PROBE_TIMEOUT_SECONDS}s" "${cmd[@]}" 2>/dev/null)" || return 1
  else
    raw="$("${cmd[@]}" 2>/dev/null)" || return 1
  fi

  # curl appends the HTTP status as a final line (--write-out); split it off
  # before anything else looks at the body.
  local status body
  case "$raw" in
    *$'\n'*) status="${raw##*$'\n'}"; body="${raw%$'\n'*}" ;;
    *)        status="$raw"; body="" ;;
  esac

  # 2xx ONLY. A 3xx is not followed and is not accepted either — a redirect
  # is precisely the shape that could otherwise walk the probe off the
  # allowlisted host, so it degrades to `unknown` like any other failure.
  case "$status" in
    2[0-9][0-9]) ;;
    *) return 1 ;;
  esac

  # Second, in-script response-size cap: curl's own --max-filesize only fires
  # when the server declares a Content-Length, so this is the one that
  # actually holds for a chunked or streamed response.
  local bytes
  bytes="$(printf '%s' "$body" | wc -c | tr -d '[:space:]')"
  [ "$bytes" -le "$_URL_MAX_BYTES" ] || return 1

  local out
  out="$(printf '%s' "$body" | jq -r "$jqfilter" 2>/dev/null)" || return 1
  # Nothing, or JSON `null` (which jq -r renders as the literal string
  # "null"), is not evidence of anything — resolve to `unknown` rather than
  # string-comparing a placeholder against <expected> and reporting
  # `changed` off a field that simply isn't there.
  if [ -z "$out" ] || [ "$out" = "null" ]; then
    return 1
  fi
  printf '%s\n' "$out"
}

# evaluate_body <body> <owner_repo> -- prints exactly one of `absent` /
# `unchanged` / `changed` / `unknown` on stdout (diagnostics on stderr), the
# same single-issue logic the CLI entry point below used to run inline.
# Extracted so --bulk can call it once per NDJSON line without duplicating
# the marker-extraction / validation / probe-execution / decide sequence.
evaluate_body() {
  local body="$1" owner_repo="$2"
  local marker parsed verb arg1 arg2 expected actual

  marker="$(extract_marker "$body")"
  if [ -z "$marker" ]; then
    printf 'absent\n'
    return 0
  fi

  if ! parsed="$(validate_and_extract "$marker" "$owner_repo")"; then
    echo "eval-recheck-probe: marker present but failed allowlist validation (\"${marker}\") — treating as unknown" >&2
    printf 'unknown\n'
    return 0
  fi

  IFS=$'\t' read -r verb arg1 arg2 expected <<<"$parsed"

  case "$verb" in
    npm-view) actual="$(run_npm_view "$arg1" "$arg2")" ;;
    gh-api)   actual="$(run_gh_api "$arg1" "$arg2")" ;;
    url-json) actual="$(run_url_json "$arg1" "$arg2")" ;;
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
    return 0
  fi

  decide "$actual" "$expected"
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

  if [ "${1:-}" = "--bulk" ]; then
    if [ "$#" -ne 2 ]; then
      echo "usage: $0 --bulk <owner/repo>   (NDJSON {number,body} on stdin)" >&2
      exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo "eval-recheck-probe: --bulk requires jq, which is not installed" >&2
      exit 1
    fi
    local owner_repo="$2"
    local line num body verdict
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      if ! num="$(printf '%s' "$line" | jq -r '.number // empty' 2>/dev/null)" || [ -z "$num" ]; then
        echo "eval-recheck-probe: --bulk skipping malformed input line (no .number): ${line}" >&2
        continue
      fi
      body="$(printf '%s' "$line" | jq -r '.body // ""' 2>/dev/null)"
      verdict="$(evaluate_body "$body" "$owner_repo")"
      if [ "$verdict" != "absent" ]; then
        jq -nc --argjson n "$num" --arg v "$verdict" '{number: $n, verdict: $v}'
      fi
    done
    exit 0
  fi

  local owner_repo="${1:-}"
  if [ -z "$owner_repo" ]; then
    echo "usage: $0 <owner/repo>   (reads the issue body on stdin)" >&2
    echo "       $0 --validate <owner/repo> <marker-rest...>" >&2
    echo "       $0 --decide <actual> <expected>" >&2
    echo "       $0 --bulk <owner/repo>   (NDJSON {number,body} on stdin)" >&2
    exit 1
  fi

  local body
  body="$(cat)"
  evaluate_body "$body" "$owner_repo"
}

main "$@"

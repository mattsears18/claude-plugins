#!/usr/bin/env bash
# backlog-filter.sh — the executable, single-source-of-truth definition of
# /shipyard:do-work's backlog eligibility filter (issue #1247).
#
# Background
# ----------
# The eligibility filter that decides which open issues /do-work may
# dispatch against was, before this script existed, a six-clause predicate
# expressed as PROSE and re-derived from scratch by an LLM at three
# independent call-sites:
#
#   - commands/do-work/setup/04-backlog-divert.md step 4 (build raw_backlog)
#   - commands/do-work/steady-state.md step C          (mid-session re-check)
#   - commands/do-work/drain.md termination-assertion step 4 (fresh-fetch
#     verification before ending the session)
#
# Three prose copies of the same predicate have already drifted TWICE:
#   - #332 — a shorthand ("drop issues with no assignee") silently erased
#     every self-assigned resumable-work issue.
#   - #1194 — the same class of regression recurred one layer down, in a
#     mid-drain ad-hoc re-derivation.
# A third divergence was found (not yet regressed in production, but
# already committed to the spec text): `needs-triage` is explicitly
# excluded from the drop-label enumeration in setup.md (it's routed to
# investigate_candidates instead) but was listed INSIDE the drop-label
# enumeration in both steady-state.md and drain.md — the exact contradiction
# a hand-rolled second copy cannot help but eventually produce.
#
# This script is the fix: ONE implementation of the classification/routing
# decision, invoked identically at all three call-sites, so they cannot
# disagree. The three .md files now mark their prose descriptions
# non-normative and point here.
#
# Subcommands
# -----------
#
#   classify --me <login> --trusted-authors <csv> [--closed-by-healthy-pr <csv>]
#            [--closed-by-open-pr <json-object>]
#            [--peer-claimed <csv>] [--investigate-dispatch true|false]
#            [--prioritize-label <label>] [--today YYYY-MM-DD]
#            [--respect-assignees true|false]
#            [--milestones-enabled true|false] [--milestones-prioritize-dispatch true|false]
#            [--probe-verdicts <json-object>] [--recheck-probe-enabled true|false]
#     Reads a JSON array of issues on stdin — the exact projection setup.md
#     step 4's wide fetch produces: [{number, title, body, labels: [name,...],
#     assignees: [login,...], author: {login}, createdAt, updatedAt,
#     milestone: "<N · Title>"|null}, ...]. `milestone` is the issue's
#     milestone TITLE (already flattened from gh's `{number,title,...}`
#     object by the caller's wide-fetch --jq projection, mirroring how
#     `labels`/`assignees` are flattened) or null/absent when unmilestoned.
#     Emits one NDJSON line per issue on stdout:
#       {"number":N,"verdict":"eligible"}
#       {"number":N,"verdict":"route","reason":"investigate"}
#       {"number":N,"verdict":"route","reason":"operator"}
#       {"number":N,"verdict":"drop","reason":"<reason>"}
#       {"number":N,"verdict":"gate","reason":"<label>"}
#       {"number":N,"verdict":"gate","reason":"tracking","evidence_pointer":"<content-sourced citation>"}
#       {"number":N,"verdict":"gate","reason":"tracking-unjustified"}
#       {"number":N,"verdict":"drop","reason":"covered-by-open-pr","evidence_pointer":"PR #M closingIssuesReferences includes #N"}
#     The `tracking` shapes are that label's special case (issue #1364) — see
#     "Provisional gate: tracking requires a content-sourced justification"
#     below. Every OTHER gate label (`blocked:ci`, `wontfix`, `discussion`,
#     `needs-human-review`) always emits the plain
#     `{"verdict":"gate","reason":"<label>"}` shape; among GATE verdicts only
#     `tracking` ever carries `evidence_pointer` or the
#     `tracking-unjustified` reason. The `covered-by-open-pr` DROP verdict
#     (issue #1389) is the one other shape that carries an
#     `evidence_pointer`.
#     Output ORDER: every "eligible" line first, in rank order. The default
#     (milestone ranking OFF — either --milestones-enabled or
#     --milestones-prioritize-dispatch is false, matching a repo that never
#     opted into milestones.*) is BYTE-IDENTICAL to the pre-#1241 order:
#     prioritized-label tier, then P0>P1>P2>unlabeled, then
#     bug>fix(*)>feat(*)>chore(*)>other, then oldest-updatedAt-first.
#     When BOTH --milestones-enabled and --milestones-prioritize-dispatch
#     are true, the eligible order becomes (issue #1241 — see
#     do-work-RATIONALE.md for why each tier sits where it does):
#       1. P0 — global, wins in ANY milestone (an emergency escape, not
#          part of the sequencing plan).
#       2. prioritized-label tier — an explicit per-run operator override,
#          now ranked below P0 (this is a behavior CHANGE from the
#          milestone-off order, where the prioritized-label tier is
#          outermost and can rank ABOVE a P0).
#       3. milestone sequence, ascending, parsed from the issue's milestone
#          title's `N · ` numeric prefix — this is "the earliest milestone
#          with dispatchable work," which falls out of the sort for free:
#          a milestone with zero eligible issues simply never appears in
#          this list, so ascending-N naturally skips it. An unmilestoned
#          issue, or one whose milestone title doesn't parse, sorts to the
#          tail (alongside where the fallback milestone's own high N
#          already sorts) rather than being dropped.
#       4. P1>P2>unlabeled, then type, then staleness — the same
#          tiebreakers as the milestone-off order, now operating WITHIN a
#          milestone rather than across the whole backlog.
#     Then every "route":"investigate" line, in its own rank order
#     (P0>P1>P2>unlabeled, then staleness — no prioritized-label, type, or
#     milestone tier, per 04d-investigate-routing.md — milestone ranking is
#     scoped to raw_backlog only). Then every remaining line
#     (route:operator, drop:*, gate:*) in input order, as an audit trail.
#     A caller that wants only the ranked eligible numbers does:
#     `jq -r 'select(.verdict=="eligible") | .number'`.
#     `--respect-assignees` (issue #1248) gates the "drop:assigned-other"
#     clause. Default `true` when the flag is omitted entirely (preserves
#     the #1194-fixed predicate for a caller that hasn't been updated yet).
#     Real callers should always pass the resolved `backlog.respect_assignees`
#     config value explicitly (config default: `false` — on a single-
#     contributor repo, the common shipyard-marketplace case, "assigned to
#     someone else" has no correct exclusion to make). When `false`, an
#     issue's `assignees` array never affects its verdict — self-assigned,
#     unassigned, and other-assigned issues are all equally eligible. It is
#     orthogonal to the milestone-ranking flags above: `--respect-assignees`
#     decides which issues reach the eligible bucket at all, the milestone
#     flags decide only how that bucket is ordered.
#     `--closed-by-open-pr` (issue #1389) is a JSON object mapping issue
#     number (as a STRING key, same convention as `--probe-verdicts`) to the
#     number of an OPEN `--me`-authored PR whose `closingIssuesReferences`
#     names that issue — REGARDLESS of that PR's check health or
#     `mergeStateStatus`. Defaults to `{}` when omitted (the clause never
#     fires, byte-identical to pre-#1389 behavior). Produced by the
#     `closed-by-open-pr` subcommand below. This is deliberately a WIDER set
#     than `--closed-by-healthy-pr`, because the two flags answer two
#     different questions and #1389 is the bug that came from conflating
#     them: PR health decides "does this PR belong in `failed_prs`?", which
#     is a question about the PR. Whether an ISSUE is already covered by
#     in-flight work is a question about the issue, and health is irrelevant
#     to it — an issue whose open PR is red is fix-checks work on that PR,
#     not workable issue-work, so dispatching an issue-worker at it can only
#     bail (the #1389 repro burned 3 worker + 3 scope-agent dispatches,
#     ~250k tokens, on five such issues in one session). The
#     `closed/abandoned PR -> issue stays dispatchable` row is untouched:
#     the subcommand queries `--state open` only, so a closed or abandoned
#     PR contributes no entry and #332's resumable-work case is preserved by
#     construction. Evaluated AFTER `--closed-by-healthy-pr` in
#     `classify_one`, so an issue in BOTH sets keeps emitting the older
#     `closed-by-healthy-pr` reason verbatim and only the two genuinely-new
#     rows (open+red, open+DIRTY) emit `covered-by-open-pr`.
#     `--probe-verdicts` (issue #1356) is a JSON object mapping issue number
#     (as a STRING key — `{"123":"changed"}`, not `{123:"changed"}`, since
#     JSON object keys are always strings) to the verdict a prior
#     `eval-probes` pass (below) already computed for that issue's
#     `do-work-recheck` marker: `changed` / `unchanged` / `unknown`. Defaults
#     to `{}` when omitted (every issue falls back to `unknown`, the safe
#     default — see `--recheck-probe-enabled` below for the flag that
#     disables this mechanism at the class level rather than per-issue).
#     Any issue whose body carries a `do-work-recheck` marker (any line, not
#     line-1-restricted — the position discipline only ever applied to
#     `do-work-blocked-until`) is EVENT-GATED rather than TIME-GATED: its
#     eligibility is decided from this map's verdict, not from the calendar
#     date. `changed` -> eligible now, REGARDLESS of whether the paired
#     `do-work-blocked-until` date (if any) is still in the future — the one
#     case that brings admission forward, matching the read-side semantics
#     `eval-recheck-probe.sh`'s own header comment documents.
#     `unchanged`/`unknown`/no-entry-in-map -> `{"verdict":"drop","reason":
#     "event-gated"}`, REGARDLESS of whether the calendar date has already
#     elapsed — this is the fix for the churn loop issue #1356 documents: an
#     event-gated issue never silently re-admits itself into the dispatch
#     pool (and never triggers a fresh scope-agent pass that would invent a
#     new date) just because a placeholder date happened to pass; only an
#     explicit `changed` probe verdict does. A plain calendar-only issue
#     (no `do-work-recheck` marker at all) is completely unaffected — this
#     clause never runs for it, and `time_gate_future`'s line-1-only
#     calendar check is exactly what it was before this issue.
#     `--recheck-probe-enabled` (default `true`, mirrors the
#     `scope.recheck_probe_enabled` config knob) is the class-level kill
#     switch: when `false`, EVERY issue is treated as though it carries no
#     `do-work-recheck` marker at all, regardless of its body or of
#     `--probe-verdicts` — full calendar-only fallback, byte-identical to
#     the pre-#1356 behavior. This is deliberately a caller-supplied flag,
#     not something `classify` reads from config itself, so the pure
#     function stays free of I/O (see the design note near the bottom of
#     this header for why that purity is load-bearing).
#     Exit 0 always (even on an empty input array — emits nothing).
#
#   eval-probes --repo <owner/repo>
#     < wide-fetch-issue-json (array) on stdin — the exact same payload
#     `classify` reads (only `number` and `body` are used).
#     Live-queries: for every issue whose body carries a `do-work-recheck`
#     marker (issue #1356, generalizing #1198's evaluator beyond its single
#     original `external-dependency`-defer, operator-sweep-only caller to
#     ANY defer class and to the ordinary dispatch-eligibility filter), runs
#     `eval-recheck-probe.sh --bulk` and captures its verdict. This is the
#     live-network precomputation half of the event-gate filter — kept as
#     its own subcommand for exactly the same reason `closed-by-healthy-pr`
#     is: `classify` itself stays a pure function with zero `gh`/`npm` calls
#     of its own, fixture-testable forever (see the design note below).
#     Prints a JSON object `{"<number>":"<verdict>", ...}` on stdout —
#     ready to pass straight through as `classify --probe-verdicts`. Issues
#     with no `do-work-recheck` marker contribute no key (silence, not an
#     `"absent"` entry — matches `eval-recheck-probe.sh --bulk`'s own output
#     contract). Empty object (`{}`), not empty string, when no issue in the
#     input carries a marker — so `--probe-verdicts "$(...)"` composes
#     directly without a caller-side empty-string special case.
#     Exit codes: 0 success (even if no issue carries a marker); 65 if `gh`
#     or `jq` is missing.
#
#   closed-by-healthy-pr --repo <owner/repo> --me <login>
#     Live-queries GitHub: the set of issue numbers with an OPEN PR,
#     authored by --me, that (a) is currently healthy — its latest-per-name
#     check-rollup projection (the #333 group-by, reused verbatim rather
#     than re-derived) has ZERO failing checks, and mergeStateStatus !=
#     DIRTY — and (b) has this issue in closingIssuesReferences. Health is
#     deliberately NOT gated on mergeStateStatus's CLEAN/HAS_HOOKS/UNSTABLE
#     allowlist (the pre-#1262 behavior): on a ruleset-protected default
#     branch, a PR whose required checks are merely queued reports
#     mergeStateStatus == BLOCKED even though nothing has actually failed —
#     misclassifying a genuinely healthy, still-in-flight PR as unhealthy
#     and leaving its issue in the workable backlog, risking a duplicate PR
#     against work already in flight (issue #1262). DIRTY is excluded on
#     its own — that state belongs to the fix-rebase path, never "healthy,"
#     regardless of check state.
#     This is the "closed-by-@me-authored-healthy-PR" drop clause's input
#     set — it requires live network access, so unlike `classify` it is NOT
#     a pure function and is not fixture-tested; it is the thin,
#     single-copy replacement for the `gh pr list` + jq block that used to
#     be written out in full in setup.md step 4 and silently assumed
#     ("apply the same filter") at the other two call-sites.
#     Prints a comma-separated, numerically-sorted, deduped list of issue
#     numbers to stdout (empty output, not "(none)", when the set is empty
#     — so `--closed-by-healthy-pr "$(...)"` composes directly).
#     Exit codes: 0 success (even if the set is empty); 65 if `gh` or `jq`
#     is missing.
#
#   closed-by-open-pr --repo <owner/repo> --me <login>
#     Live-queries GitHub: the set of issue numbers with an OPEN PR authored
#     by --me that names them in closingIssuesReferences — with NO health
#     filter of any kind (no check-rollup walk, no mergeStateStatus test).
#     The sibling of `closed-by-healthy-pr` above, and deliberately NOT a
#     replacement for it: that subcommand keeps its exact current meaning
#     and its current consumers, because "is this PR healthy?" is still the
#     right question for the `failed_prs` / fix-checks routing it feeds.
#     This one answers the different question issue #1389 identified as
#     being wrongly answered by that same health check — "is this ISSUE
#     already covered by in-flight work?" — for which health is irrelevant.
#     Prints a JSON object `{"<issue-number>": <pr-number>, ...}` on stdout,
#     ready to pass straight through as `classify --closed-by-open-pr`. The
#     PR number is carried (rather than a bare CSV of issue numbers, the
#     shape `closed-by-healthy-pr` uses) so `classify` can emit a concrete
#     `evidence_pointer` naming the covering PR. When more than one open PR
#     closes the same issue, the LOWEST PR number wins — arbitrary but
#     deterministic, so the emitted evidence pointer is stable across runs.
#     Empty object (`{}`), not empty string, when no open PR closes any
#     issue — so `--closed-by-open-pr "$(...)"` composes without a
#     caller-side empty-string special case.
#     Uses `closingIssuesReferences` — GitHub's canonical "this PR
#     auto-closes that issue" signal — never a PR-body substring search
#     (issue #301). Its `gh pr list` projection is strictly cheaper than
#     `closed-by-healthy-pr`'s: `number,closingIssuesReferences` only, with
#     no `statusCheckRollup` (the expensive per-check array).
#     Exit codes: 0 success (even if the set is empty); 65 if `gh` or `jq`
#     is missing.
#
#   summary --me <login>
#     < wide-fetch-issue-json (array) on stdin — the exact same payload
#     `classify` reads, passed BEFORE classification runs.
#     Emits the `unfiltered_open_count` / `me_assigned_open` invariant-line
#     tokens (issue #1246) as a single JSON object on stdout:
#       {"unfiltered_open_count":36,"me_assigned_open":16}
#     `unfiltered_open_count` is simply the input array's length;
#     `me_assigned_open` is the count of issues whose `assignees` array
#     contains --me (case-insensitive). A deliberately separate subcommand
#     from `classify` rather than a line folded into its NDJSON stream —
#     `classify`'s output contract (one line per input issue, in a
#     documented rank order) is depended on verbatim by three call-sites
#     and their fixture tests; appending a summary line there would change
#     that contract for every existing consumer. Kept here (not computed
#     ad hoc by each caller) for the same reason `classify` itself exists:
#     the caller already holds the pre-filter payload, so this is the
#     single place the count is computed, rather than three independent
#     `jq 'length'` / assignee-matching one-liners that could drift.
#     Exit 0 always (even on an empty input array — emits count 0/0).
#
# Design note — why classify takes precomputed sets rather than doing its
# own network I/O for --closed-by-healthy-pr / --peer-claimed: the
# classification/routing DECISION is the part that has actually drifted
# (see the #332/#1194/needs-triage history above) and is exactly what
# needs to be fixture-testable against fixed inputs, byte-for-byte,
# forever. The live network calls that produce those input sets are
# comparatively simple, already had their own bugs fixed once each (#301's
# closingIssuesReferences fix, #333's latest-per-name rollup fix) and
# aren't where the drift has occurred. Keeping `classify` pure means its
# test suite runs with no `gh` calls, no `--repo`, and no network at all.
#
# Why "Blocked by #N still open" needs no extra input: the wide-fetch
# payload IS the complete set of this repo's currently-open issues (the
# server-side fetch is `--state open`, no other filter) — so "is #N still
# open" is answered by "does #N appear in this same payload's own `number`
# list", with no separate per-reference `gh issue view` call required. A
# referenced #N that has already closed (or was never an issue in this
# repo) simply doesn't appear, and the issue is correctly treated as
# unblocked.
#
# Exit codes: 0 success; 64 bad usage; 65 missing dependency (jq/gh).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${here}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  backlog-filter.sh classify --me <login> --trusted-authors <csv>
      [--closed-by-healthy-pr <csv-of-numbers>]
      [--closed-by-open-pr <json-object>] [--peer-claimed <csv-of-numbers>]
      [--investigate-dispatch true|false] [--prioritize-label <label>]
      [--today YYYY-MM-DD] [--respect-assignees true|false]
      [--milestones-enabled true|false]
      [--milestones-prioritize-dispatch true|false]
      [--probe-verdicts <json-object>] [--recheck-probe-enabled true|false]
    < wide-fetch-issue-json (array) on stdin

  backlog-filter.sh closed-by-healthy-pr --repo <owner/repo> --me <login>

  backlog-filter.sh closed-by-open-pr --repo <owner/repo> --me <login>

  backlog-filter.sh eval-probes --repo <owner/repo>
    < wide-fetch-issue-json (array) on stdin

  backlog-filter.sh summary --me <login>
    < wide-fetch-issue-json (array) on stdin
EOF
}

# _csv_to_json_number_array <csv> — "" -> [], "3,7,7,x" -> [3,7] (non-numeric
# tokens dropped silently — defensive against a caller passing a stray
# empty field from a trailing comma).
_csv_to_json_number_array() {
  local csv="$1"
  jq -nc --arg csv "$csv" '
    ($csv | split(",") | map(select(test("^[0-9]+$"))) | map(tonumber))
  '
}

# _csv_to_json_lower_string_array <csv> — "" -> [], "Foo,bar" -> ["foo","bar"].
_csv_to_json_lower_string_array() {
  local csv="$1"
  jq -nc --arg csv "$csv" '
    ($csv | split(",") | map(select(length > 0)) | map(ascii_downcase))
  '
}

# The symptom-shaped-body regex, verbatim from
# setup/04d-investigate-routing.md's SYMPTOM_REGEX — kept as a single
# source string here so a future edit to the signal only has to change one
# place. jq's built-in regex engine (Oniguruma) accepts the same syntax.
SYMPTOM_REGEX='(Traceback \(most recent call last\)|Fatal error:|Unhandled( Promise)? [Rr]ejection|Exception in thread|Segmentation fault|NullPointerException|panic:|Stack trace:|sentry\.io/(organizations|issues)/|[Ff]ingerprint:[[:space:]]*[0-9a-f]{8,}|at [A-Za-z0-9_.$]+ ?\([^)]*:[0-9]+:[0-9]+\))'

# The jq classification program. Reads the wide-fetch array as `.` (top
# level input), emits the ordered NDJSON stream described in the header
# comment. Every dynamic input arrives via --arg/--argjson — no shell
# interpolation inside the program string itself.
# shellcheck disable=SC2016
# NOTE on style: every function below takes its issue as a `$`-prefixed
# (value) parameter, never a bare filter parameter. jq bare (non-$) function
# parameters are dynamically-scoped filters re-evaluated against whatever
# `.` happens to be at each point they are REFERENCED inside the function
# body — not lexically-captured values — so a bare `issue` referenced from
# inside a nested select()/map()/any() (where `.` has already changed to
# some inner iteration variable) silently evaluates against the WRONG
# value. `$`-parameters are evaluated once, at the call site, and behave
# like ordinary bound values from then on, which is what every function
# below actually needs.
CLASSIFY_JQ='
def lower: ascii_downcase;

# Dispatch-gate labels that DROP an issue outright (never routed) — the
# literal enumeration from setup.md step 4. needs-triage and agent-console
# are deliberately absent: both are ROUTES, handled by their own clauses
# below, never by this drop-on-label clause.
#
# `tracking` is the one PROVISIONAL member of this list (defensive gate,
# #1081, pending migration to needs-human-review by 01c sub-sweep e) — see
# backlog-ownership.md bucket 5.5 Notes for the full history. The other
# four (`blocked:ci`, `wontfix`, `discussion`, `needs-human-review`) are
# settled, intentional gates with a stated owner in backlog-ownership.md;
# label presence alone is sufficient justification for those. `tracking`
# alone gets the extra has_tracking_justification() check below (#1364) —
# a provisional/defensive rule may not drop an issue on label presence
# alone with no content-sourced signal that the label reflects the issue
# real state.
def gate_labels: ["blocked:ci", "wontfix", "discussion", "needs-human-review", "tracking"];

# has_tracking_justification($issue) -- issue #1364. The bare `tracking`
# gate above is explicitly documented as provisional (a defensive gate
# against the label object never being migrated, #1081) rather than a
# settled, intentional routing decision -- so unlike the other four gate
# labels, it must not fire silently on label presence alone. This is the
# CHEAP version from the issue own suggested fix: require the body to
# contain at least one recognized human-owned signal. Absence of every
# signal means the label is doing all the work, which is the case worth
# surfacing rather than silently dropping. Returns a short citation string
# (becomes the emitted `evidence_pointer`) on a match, or null on no match
# -- mirrors the deferred_issues evidence_pointer convention (a single
# concrete, content-sourced citation string), not that subsystem full
# object shape (defer_reason_class/provenance/deferred_at do not apply to
# a pure mechanical classifier with no LLM judgment involved).
def has_tracking_justification($issue):
  ($issue.body // "") as $b
  | if ($b | test("(?im)^#{1,6}\\s*decision required\\b")) then
      "Decision-required heading in body"
    elif ($b | test("(?im)^#{1,6}\\s*options?\\b")) then
      "Options heading in body"
    else
      ([$b | scan("(?i)blocked by #([0-9]+)")] | first) as $bcap
      | if ($bcap == null) then null
        else ("Blocked by #" + $bcap[0] + " reference in body")
        end
    end;

def priority_rank($issue):
  if ($issue.labels | index("P0") != null) then 0
  elif ($issue.labels | index("P1") != null) then 1
  elif ($issue.labels | index("P2") != null) then 2
  else 3
  end;

def type_rank($issue):
  if ($issue.labels | index("bug") != null) then 0
  elif ($issue.title | test("^fix\\(")) then 1
  elif ($issue.title | test("^feat\\(")) then 2
  elif ($issue.title | test("^chore\\(")) then 3
  else 4
  end;

# milestone_seq($issue) -- the issue milestone sequence number, parsed
# from the milestone title "N · Title" prefix (U+00B7 MIDDLE DOT, one
# space each side -- the fixed, non-configurable numbering contract per
# schemas/shipyard.config.schema.json milestones block). An unmilestoned
# issue, or one whose milestone title does not parse (malformed, or a
# pre-#1239 milestone that predates the numbering convention), gets a
# sentinel far larger than any real sequence number so it sorts to the
# tail alongside where the fallback milestone (always the highest N)
# already sorts, rather than being dropped from the ranked list (issue
# #1241 acceptance: "An issue with no milestone at all still ranks").
# capture() wrapped in [...] then `first` turns "zero outputs on
# no-match" into a real `null` we can branch on, same defensive pattern
# time_gate_future uses below for the identical reason. NOTE: no literal
# apostrophes anywhere in this program string -- CLASSIFY_JQ is itself a
# single-quoted bash string, so an apostrophe (even inside a comment)
# would terminate it early.
def milestone_seq($issue):
  ($issue.milestone // "") as $m
  | ([$m | capture("^\\s*(?<n>[0-9]+)\\s*·")] | first) as $cap
  | if ($cap == null) then 999999999
    else ($cap.n | tonumber)
    end;

def prioritized_tier($issue; $plabel):
  if ($plabel == "") then 0
  elif ($issue.labels | index($plabel) != null) then 0
  else 1
  end;

def matches_gate_label($issue):
  [gate_labels[] | select(. as $g | $issue.labels | index($g) != null)] | first;

def is_agent_console($issue):
  ($issue.labels | index("agent-console") != null);

def is_investigate_signal($issue; $re):
  ($issue.labels | index("needs-triage") != null)
  or (($issue.author.login // "") | test("\\[bot\\]$|^app/"))
  or (($issue.body // "") | test($re; "i"));

def is_untrusted($issue; $trusted):
  (($issue.author.login // "") | lower) as $a | ($trusted | index($a)) == null;

def is_peer_claimed($issue; $peer):
  ($peer | index($issue.number) != null);

def is_assigned_to_other($issue; $me):
  ($issue.assignees | length) > 0
  and ((($issue.assignees | map(lower)) | index($me)) == null);

def blocked_by_open_issue($issue; $opennums):
  (($issue.body // "") | [scan("(?i)blocked by #([0-9]+)")]) as $refs
  | ($refs | map(.[0] | tonumber)) as $nums
  | ($nums | any(. as $n | ($n != $issue.number) and ($opennums | index($n) != null)));

def time_gate_future($issue; $today):
  ($issue.body // "") as $b
  | ($b | split("\n") | (.[0] // "")) as $first_line
  # capture() produces NO output at all (an empty stream, not a null) when
  # the string fails to match -- wrapping in [...] then `first` turns "zero
  # outputs" into a real `null` we can bind and branch on below. Binding
  # `capture(...)` directly via `as $cap` would otherwise make this entire
  # function silently produce zero outputs on every non-matching (the
  # overwhelmingly common) case -- every eligible issue would silently
  # vanish from classify output, because this def is called from every
  # classify_one and would swallow its own return value.
  | ([$first_line | capture("^<!--\\s*do-work-blocked-until:\\s*(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})\\s*-->\\s*$")] | first) as $cap
  | if ($cap == null) then false
    else ($cap.d > $today)
    end;

def is_closed_by_healthy_pr($issue; $healthy):
  ($healthy | index($issue.number) != null);

# covered_by_open_pr($issue; $covered) -- issue #1389. Returns the number of
# an OPEN --me-authored PR whose closingIssuesReferences names this issue,
# or null when no such PR exists. Health is deliberately NOT consulted: the
# check-rollup/mergeStateStatus test that feeds is_closed_by_healthy_pr
# above answers "should this PR go in failed_prs?", a question about the PR,
# and reusing it to answer "should this issue go in raw_backlog?" is the bug
# #1389 documents. An issue whose open PR is red is fix-checks work on that
# PR; an issue whose open PR is DIRTY is fix-rebase work on that PR. Neither
# is workable issue-work, so dispatching an issue-worker at either can only
# bail (issue-work.md step 0 catches it, but only AFTER a full worker
# dispatch has read the issue). The closed/abandoned-PR row that #332
# protects never reaches this map at all -- the producing subcommand queries
# --state open only -- so resumable work stays dispatchable by construction.
def covered_by_open_pr($issue; $covered):
  ($covered[($issue.number | tostring)] // null);

# is_event_gated($issue; $recheck_probe_enabled) -- issue #1356. True only
# when the class-level kill switch is on AND the body carries a
# `do-work-recheck` marker on ANY line (multiline flag "m" -- unlike
# `do-work-blocked-until`, this marker carries no line-1 "position
# discipline" requirement; eval-recheck-probe.sh extract_marker scans the
# whole body the same way, matching every occurrence of the marker line, so
# this mirrors the read side contract exactly). When true, the issue
# eligibility is decided entirely by probe_verdict below -- never by the
# calendar -- which is what stops the churn-loop this issue closes: an
# unresolved event gate keeps dropping the issue on every single classify
# pass regardless of whether a paired blocked-until date elapses, and never
# invents a new date to do it.
def is_event_gated($issue; $recheck_probe_enabled):
  $recheck_probe_enabled and (($issue.body // "") | test("(?m)^<!-- do-work-recheck: .+ -->$"));

# probe_verdict($issue; $verdicts) -- looks up the precomputed verdict
# eval-probes already ran (network I/O happens there, never here -- classify
# stays pure). No entry in the map (the precompute step was not run, or it
# produced no verdict for this issue for any reason) fails safe to
# "unknown", the same never-treat-inconclusive-as-resolved posture
# eval-recheck-probe.sh documents in its own header comment.
def probe_verdict($issue; $verdicts):
  ($verdicts[($issue.number | tostring)] // "unknown");

def classify_one($issue; $me; $trusted; $healthy; $covered; $peer; $investigate_dispatch; $today; $re; $opennums; $respect_assignees; $recheck_probe_enabled; $probe_verdicts):
  (matches_gate_label($issue)) as $gate_hit
  | is_event_gated($issue; $recheck_probe_enabled) as $event_gated
  | if is_untrusted($issue; $trusted) then
      {number: $issue.number, verdict: "drop", reason: "untrusted-author"}
    elif ($gate_hit != null) then
      (if ($gate_hit == "tracking") then
         (has_tracking_justification($issue)) as $justification
         | (if ($justification != null) then
              {number: $issue.number, verdict: "gate", reason: "tracking", evidence_pointer: $justification}
            else
              {number: $issue.number, verdict: "gate", reason: "tracking-unjustified"}
            end)
       else
         {number: $issue.number, verdict: "gate", reason: $gate_hit}
       end)
    elif is_agent_console($issue) then
      {number: $issue.number, verdict: "route", reason: "operator"}
    elif is_investigate_signal($issue; $re) then
      (if $investigate_dispatch then
         {number: $issue.number, verdict: "route", reason: "investigate"}
       else
         {number: $issue.number, verdict: "drop", reason: "investigate-disabled"}
       end)
    elif is_peer_claimed($issue; $peer) then
      {number: $issue.number, verdict: "drop", reason: "peer-claimed"}
    elif ($respect_assignees and is_assigned_to_other($issue; $me)) then
      {number: $issue.number, verdict: "drop", reason: "assigned-other"}
    elif blocked_by_open_issue($issue; $opennums) then
      {number: $issue.number, verdict: "drop", reason: "blocked-by-open-issue"}
    elif ($event_gated and (probe_verdict($issue; $probe_verdicts) != "changed")) then
      {number: $issue.number, verdict: "drop", reason: "event-gated"}
    elif ((($event_gated | not)) and time_gate_future($issue; $today)) then
      {number: $issue.number, verdict: "drop", reason: "time-gated"}
    elif is_closed_by_healthy_pr($issue; $healthy) then
      {number: $issue.number, verdict: "drop", reason: "closed-by-healthy-pr"}
    elif (covered_by_open_pr($issue; $covered) != null) then
      # Ordered AFTER the healthy clause on purpose (issue #1389): the
      # covered set is a strict SUPERSET of the healthy set, so putting it
      # first would silently relabel every already-dropped healthy row.
      # Reaching here therefore means "open PR, but NOT healthy" -- exactly
      # the two rows (open+red, open+DIRTY) that used to stay dispatchable.
      (covered_by_open_pr($issue; $covered)) as $pr
      | {number: $issue.number, verdict: "drop", reason: "covered-by-open-pr",
         evidence_pointer: ("PR #" + ($pr | tostring)
                            + " closingIssuesReferences includes #"
                            + ($issue.number | tostring))}
    else
      {number: $issue.number, verdict: "eligible"}
    end
  | . + {
      _priority_rank: priority_rank($issue),
      _type_rank: type_rank($issue),
      _prioritized_tier: prioritized_tier($issue; $prioritize_label),
      _updatedAt: ($issue.updatedAt // ""),
      # _sort_key -- the eligible-bucket sort key, issue #1241. Computed
      # here (not left inline at the final sort_by) so BOTH branches are
      # visible together with the byte-identical-by-construction guarantee
      # they exist to satisfy: the milestone-off branch is a verbatim copy
      # of the pre-#1241 [_prioritized_tier, _priority_rank, _type_rank,
      # _updatedAt] key, so a repo with milestones.enabled:false OR
      # milestones.prioritize_dispatch:false gets the exact same ranking
      # as every prior release, never a "close enough" approximation. The
      # milestone-on branch promotes P0 to a global tier ABOVE
      # _prioritized_tier -- a deliberate behavior CHANGE, gated so it can
      # only fire when a repo has actually opted into milestone-ordered
      # dispatch (see header comment + do-work-RATIONALE.md for the full
      # tier-ordering rationale).
      _sort_key: (
        if $milestone_rank_on then
          [(if priority_rank($issue) == 0 then 0 else 1 end),
           prioritized_tier($issue; $prioritize_label),
           milestone_seq($issue),
           priority_rank($issue),
           type_rank($issue),
           ($issue.updatedAt // "")]
        else
          [prioritized_tier($issue; $prioritize_label),
           priority_rank($issue),
           type_rank($issue),
           ($issue.updatedAt // "")]
        end
      )
    };

. as $issues
| ($issues | map(.number)) as $opennums
| ($issues | map(. as $issue | classify_one($issue; $me; $trusted; $healthy; $covered_by_open_pr; $peer; $investigate_dispatch; $today; $symptom_re; $opennums; $respect_assignees; $recheck_probe_enabled; $probe_verdicts))) as $classified
| (
    ($classified | map(select(.verdict == "eligible"))
      | sort_by(._sort_key))
    +
    ($classified | map(select(.verdict == "route" and .reason == "investigate"))
      | sort_by([._priority_rank, ._updatedAt]))
    +
    ($classified | map(select(
        (.verdict != "eligible")
        and (.verdict != "route" or .reason != "investigate")
      )))
  )
| .[]
| (if has("evidence_pointer") then {number, verdict, reason, evidence_pointer}
   elif has("reason") then {number, verdict, reason}
   else {number, verdict}
   end)
'

cmd_classify() {
  local me="" trusted_csv="" healthy_csv="" peer_csv="" investigate_dispatch="true"
  local prioritize_label="" today="" respect_assignees="true"
  # milestones.enabled / milestones.prioritize_dispatch (issue #1241) --
  # BOTH default "false" so a caller that never passes these flags at all
  # (every pre-#1241 invocation, and every fixture test written before
  # this issue) gets the exact pre-#1241 behavior with zero code change on
  # its end -- the milestone-ranking gate below can only ever turn ON via
  # an explicit true/true pair.
  local milestones_enabled="false" milestones_prioritize_dispatch="false"
  # --probe-verdicts / --recheck-probe-enabled (issue #1356). Default
  # "{}" / "true" reproduces pre-#1356 behavior byte-for-byte for every
  # existing caller and fixture: with an empty verdicts map and no
  # do-work-recheck marker in the body, is_event_gated is false for every
  # issue and classify_one falls straight through to the unchanged
  # time_gate_future branch.
  local probe_verdicts_json="{}" recheck_probe_enabled="true"
  # --closed-by-open-pr (issue #1389). Default "{}" reproduces pre-#1389
  # behavior byte-for-byte for every existing caller and fixture: with an
  # empty map, covered_by_open_pr returns null for every issue and
  # classify_one falls straight through to the unchanged `eligible` branch.
  local covered_by_open_pr_json="{}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --me) me="${2:-}"; shift 2 ;;
      --trusted-authors) trusted_csv="${2:-}"; shift 2 ;;
      --closed-by-healthy-pr) healthy_csv="${2:-}"; shift 2 ;;
      --closed-by-open-pr) covered_by_open_pr_json="${2:-}"; shift 2 ;;
      --peer-claimed) peer_csv="${2:-}"; shift 2 ;;
      --investigate-dispatch) investigate_dispatch="${2:-}"; shift 2 ;;
      --prioritize-label) prioritize_label="${2:-}"; shift 2 ;;
      --today) today="${2:-}"; shift 2 ;;
      --respect-assignees) respect_assignees="${2:-}"; shift 2 ;;
      --milestones-enabled) milestones_enabled="${2:-}"; shift 2 ;;
      --milestones-prioritize-dispatch) milestones_prioritize_dispatch="${2:-}"; shift 2 ;;
      --probe-verdicts) probe_verdicts_json="${2:-}"; shift 2 ;;
      --recheck-probe-enabled) recheck_probe_enabled="${2:-}"; shift 2 ;;
      *) echo "classify: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done

  if [[ -z "$me" ]]; then
    echo "classify: --me is required" >&2
    usage
    return 64
  fi
  if [[ -z "$trusted_csv" ]]; then
    echo "classify: --trusted-authors is required (pass an explicit empty-safe value, not an omitted flag, if the trusted set is genuinely empty)" >&2
    usage
    return 64
  fi
  case "$investigate_dispatch" in
    true|false) ;;
    *) echo "classify: --investigate-dispatch must be true or false, got: $investigate_dispatch" >&2; return 64 ;;
  esac
  case "$respect_assignees" in
    true|false) ;;
    *) echo "classify: --respect-assignees must be true or false, got: $respect_assignees" >&2; return 64 ;;
  esac
  case "$milestones_enabled" in
    true|false) ;;
    *) echo "classify: --milestones-enabled must be true or false, got: $milestones_enabled" >&2; return 64 ;;
  esac
  case "$milestones_prioritize_dispatch" in
    true|false) ;;
    *) echo "classify: --milestones-prioritize-dispatch must be true or false, got: $milestones_prioritize_dispatch" >&2; return 64 ;;
  esac
  case "$recheck_probe_enabled" in
    true|false) ;;
    *) echo "classify: --recheck-probe-enabled must be true or false, got: $recheck_probe_enabled" >&2; return 64 ;;
  esac
  if [[ -z "$today" ]]; then
    today="$(date -u +%F)"
  fi
  if ! [[ "$today" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "classify: --today must be YYYY-MM-DD, got: $today" >&2
    return 64
  fi

  require_jq "backlog-filter.sh"

  if ! printf '%s' "$probe_verdicts_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "classify: --probe-verdicts must be a JSON object, got: $probe_verdicts_json" >&2
    return 64
  fi

  if [[ -z "$covered_by_open_pr_json" ]]; then
    covered_by_open_pr_json="{}"
  fi
  if ! printf '%s' "$covered_by_open_pr_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "classify: --closed-by-open-pr must be a JSON object, got: $covered_by_open_pr_json" >&2
    return 64
  fi

  local me_lower trusted_json healthy_json peer_json input milestone_rank_on
  me_lower=$(printf '%s' "$me" | tr '[:upper:]' '[:lower:]')
  trusted_json=$(_csv_to_json_lower_string_array "$trusted_csv")
  healthy_json=$(_csv_to_json_number_array "$healthy_csv")
  peer_json=$(_csv_to_json_number_array "$peer_csv")
  input=$(cat)

  if [[ -z "$input" ]]; then
    input="[]"
  fi

  # The AND-gate itself -- milestone-aware ranking requires BOTH knobs
  # true. Either one false reproduces the pre-#1241 sort byte-for-byte
  # (see CLASSIFY_JQ's _sort_key comment above) -- this is what makes the
  # "milestones.enabled:false OR prioritize_dispatch:false -> unchanged
  # ranking" acceptance criterion hold structurally rather than by
  # convention.
  milestone_rank_on="false"
  if [[ "$milestones_enabled" == "true" && "$milestones_prioritize_dispatch" == "true" ]]; then
    milestone_rank_on="true"
  fi

  printf '%s' "$input" | jq -c \
    --arg me "$me_lower" \
    --argjson trusted "$trusted_json" \
    --argjson healthy "$healthy_json" \
    --argjson peer "$peer_json" \
    --argjson investigate_dispatch "$investigate_dispatch" \
    --arg prioritize_label "$prioritize_label" \
    --arg today "$today" \
    --argjson milestone_rank_on "$milestone_rank_on" \
    --arg symptom_re "$SYMPTOM_REGEX" \
    --argjson respect_assignees "$respect_assignees" \
    --argjson recheck_probe_enabled "$recheck_probe_enabled" \
    --argjson probe_verdicts "$probe_verdicts_json" \
    --argjson covered_by_open_pr "$covered_by_open_pr_json" \
    "$CLASSIFY_JQ"
}

cmd_closed_by_healthy_pr() {
  local repo="" me=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --me) me="${2:-}"; shift 2 ;;
      *) echo "closed-by-healthy-pr: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done
  if [[ -z "$repo" ]]; then
    echo "closed-by-healthy-pr: --repo is required" >&2
    usage
    return 64
  fi
  if [[ -z "$me" ]]; then
    echo "closed-by-healthy-pr: --me is required" >&2
    usage
    return 64
  fi
  require_jq "backlog-filter.sh"
  if ! command -v gh >/dev/null 2>&1; then
    echo "closed-by-healthy-pr: gh is required but not installed" >&2
    return 65
  fi

  # Direct `gh pr list` (not gh-batch.sh) — its GraphQL projection only
  # returns the aggregate `statusCheckRollup.state`, not the per-check
  # array this latest-per-name group-by needs. `gh pr list --json
  # statusCheckRollup` returns the real per-check array, same as every
  # other rollup walk in setup/04-backlog-divert.md and drain.md.
  gh pr list --repo "$repo" --state open --author "$me" --limit 200 \
    --json number,mergeStateStatus,statusCheckRollup,closingIssuesReferences 2>/dev/null | jq -r '
    [.[] | select(.mergeStateStatus != "DIRTY")
      | select(
        ([(.statusCheckRollup // [])
         | group_by(.name)
         | map(sort_by(.completedAt // .startedAt // "") | last)
         | .[]
         | select((.conclusion // .state // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
        ] | length) == 0
      )
      | .closingIssuesReferences[]?.number
    ] | unique | join(",")
  '
}

# cmd_closed_by_open_pr — the live-network half of the covered-by-open-PR
# drop clause (issue #1389). Deliberately a SIBLING of
# cmd_closed_by_healthy_pr, not a modification of it: that function answers
# "should this PR go in failed_prs?" and must keep doing exactly that, while
# this one answers "is this ISSUE already covered by in-flight work?" — a
# question to which the PR's check health and mergeStateStatus are simply
# irrelevant. Conflating the two is the bug #1389 documents.
cmd_closed_by_open_pr() {
  local repo="" me=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --me) me="${2:-}"; shift 2 ;;
      *) echo "closed-by-open-pr: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done
  if [[ -z "$repo" ]]; then
    echo "closed-by-open-pr: --repo is required" >&2
    usage
    return 64
  fi
  if [[ -z "$me" ]]; then
    echo "closed-by-open-pr: --me is required" >&2
    usage
    return 64
  fi
  require_jq "backlog-filter.sh"
  if ! command -v gh >/dev/null 2>&1; then
    echo "closed-by-open-pr: gh is required but not installed" >&2
    return 65
  fi

  # `--state open` is what preserves #332's resumable-work row by
  # construction: a closed or merged-without-closing PR is never returned,
  # so its issue never enters the map and stays dispatchable. The projection
  # is deliberately narrower than cmd_closed_by_healthy_pr's — no
  # statusCheckRollup, because no health test is performed here.
  local pr_json
  pr_json=$(gh pr list --repo "$repo" --state open --author "$me" --limit 200 \
    --json number,closingIssuesReferences 2>/dev/null)
  if [[ -z "$pr_json" ]]; then
    pr_json="[]"
  fi

  # shellcheck disable=SC2016
  printf '%s' "$pr_json" | jq -c '
    [ .[] | . as $pr | (($pr.closingIssuesReferences // [])[] | {issue: .number, pr: $pr.number}) ]
    | group_by(.issue)
    | map({ (.[0].issue | tostring): (map(.pr) | min) })
    | add // {}
  '
}

# cmd_eval_probes — the live-network precomputation half of the event-gate
# filter (issue #1356). Reads the same wide-fetch payload `classify` reads
# (only `number`/`body` matter), extracts every issue whose body carries a
# `do-work-recheck` marker, and evaluates each via
# `eval-recheck-probe.sh --bulk` (the single executable source of truth for
# marker validation + probe execution — this function never re-derives that
# logic). Kept separate from `classify` for the same reason
# `closed-by-healthy-pr` is (see the design note near the top of this file):
# the classification DECISION needs to stay a pure, fixture-testable
# function with zero network calls of its own.
cmd_eval_probes() {
  local repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      *) echo "eval-probes: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done
  if [[ -z "$repo" ]]; then
    echo "eval-probes: --repo is required" >&2
    usage
    return 64
  fi
  require_jq "backlog-filter.sh"

  local evaluator input
  evaluator="${here}/eval-recheck-probe.sh"
  if [[ ! -f "$evaluator" ]]; then
    echo "eval-probes: eval-recheck-probe.sh not found at $evaluator" >&2
    return 65
  fi

  input=$(cat)
  if [[ -z "$input" ]]; then
    input="[]"
  fi

  # Pre-filter to {number,body} NDJSON, restricted to issues whose body
  # actually carries a do-work-recheck marker -- avoids spawning a
  # subprocess (let alone a network probe) for the overwhelmingly common
  # case of a marker-free issue. eval-recheck-probe.sh --bulk would reach
  # the identical "absent" verdict on its own; this is purely an efficiency
  # pre-filter, not a second copy of the marker grammar (the actual
  # validation still happens exactly once, inside eval-recheck-probe.sh).
  printf '%s' "$input" | jq -c '
    .[] | select((.body // "") | test("(?m)^<!-- do-work-recheck: .+ -->$"))
        | {number, body}
  ' | bash "$evaluator" --bulk "$repo" | jq -sc '
    map({(.number | tostring): .verdict}) | add // {}
  '
}

# cmd_summary — the unfiltered_open_count / me_assigned_open invariant-line
# tokens (issue #1246). Reads the same wide-fetch payload `classify` reads,
# BEFORE classification runs, so a regression in the classifier itself is
# visible as a "raw_backlog=0 but unfiltered_open_count=29" divergence
# rather than silently indistinguishable from a genuinely empty backlog.
cmd_summary() {
  local me=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --me) me="${2:-}"; shift 2 ;;
      *) echo "summary: unknown arg $1" >&2; usage; return 64 ;;
    esac
  done

  if [[ -z "$me" ]]; then
    echo "summary: --me is required" >&2
    usage
    return 64
  fi

  require_jq "backlog-filter.sh"

  local me_lower input
  me_lower=$(printf '%s' "$me" | tr '[:upper:]' '[:lower:]')
  input=$(cat)

  if [[ -z "$input" ]]; then
    input="[]"
  fi

  printf '%s' "$input" | jq -c --arg me "$me_lower" '
    {
      unfiltered_open_count: length,
      me_assigned_open:
        (map(select(((.assignees // []) | map(ascii_downcase)) | index($me) != null))
         | length)
    }
  '
}

main() {
  local sub="${1:-}"
  case "$sub" in
    classify)
      shift
      cmd_classify "$@"
      ;;
    closed-by-healthy-pr)
      shift
      cmd_closed_by_healthy_pr "$@"
      ;;
    closed-by-open-pr)
      shift
      cmd_closed_by_open_pr "$@"
      ;;
    eval-probes)
      shift
      cmd_eval_probes "$@"
      ;;
    summary)
      shift
      cmd_summary "$@"
      ;;
    -h|--help|help|"")
      usage
      [ -z "$sub" ] && return 64
      return 0
      ;;
    *)
      echo "backlog-filter.sh: unknown subcommand: $sub" >&2
      usage
      return 64
      ;;
  esac
}

main "$@"
exit $?

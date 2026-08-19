#!/usr/bin/env bash
# spike-shape-detect.sh — the executable, single-source-of-truth definition of
# /shipyard:do-work's SPIKE-SHAPE detector (issue #1475).
#
# Background
# ----------
# #774 wired spike-shape detection into the `ready_issues` dispatch site as
# PROSE: a bare-prefix enumeration in `commands/do-work/dispatch-rules.md`
#
#     `spike:`, `spike on`, `investigate:`, `feasibility:`, `research:`,
#     `design spike:`
#
# with a second, independently-worded copy of the same signal in
# `agents/spike-worker.md`. Every entry in that list is the BARE form. None of
# them matches the Conventional-Commits SCOPED form — `spike(ci):`,
# `investigate(do-work):`, `research(api):` — which is the form this repo's own
# filing conventions reliably PRODUCE, because CLAUDE.md mandates Conventional
# Commits titles and the `shipyard:filing-github-issues` skill enforces them on
# every filing path.
#
# So shipyard's own filing convention produced spike titles that shipyard's own
# spike detector could not match. Repro (#1475): issue #1474, titled
#
#     spike(ci): measure the guard's resolvability boundary, then decide
#     whether a "does this block run" gate is buildable (follow-up to #1471
#     step 4)
#
# is spike-shaped by its own title word, but `spike(ci):` does not match the
# literal `spike:`. An orchestrator following the spec literally dispatches it
# as `mode: issue-work` — a contract built to open a PR that closes the issue —
# when the honest answer the spike may reach is "measure it and build nothing."
# The mis-route was caught only because the dispatching orchestrator overrode
# the documented rule on judgment. That is the tell: correctness should not
# depend on the orchestrator noticing.
#
# This script is the fix, following the `backlog-filter.sh` precedent (#1247):
# ONE implementation of the detection decision, so the two prose copies cannot
# drift apart the way the label enumerations did before that script existed.
# `commands/do-work/dispatch-rules.md` and `agents/spike-worker.md` now mark
# their prose descriptions non-normative and point here.
#
# The matcher
# -----------
# Two independent signals, OR'd. Either is sufficient.
#
#   1. LABEL — the issue carries a `spike` label (case-insensitive, exact
#      token). Unchanged from #774.
#
#   2. TITLE PREFIX — anchored at the start of the title (leading whitespace
#      tolerated), case-insensitive, in one of two families:
#
#      a. TYPE-SHAPED, with an OPTIONAL Conventional-Commits scope group:
#
#           ^[[:space:]]*(spike|investigate|research|feasibility)(\([^)]*\))?:
#
#         These four are genuine Conventional-Commits *types*, so a `(scope)`
#         group is meaningful on each. This is the #1475 fix: the `(\(...\))?`
#         group is what `spike(ci):` needed and did not have.
#
#      b. PROSE-SHAPED, bare, unchanged from #774:
#
#           ^[[:space:]]*spike on([[:space:]]|$)
#           ^[[:space:]]*design spike:
#
#         `spike on` and `design spike:` are prose framings, not CC types. A
#         `(scope)` group is meaningless on either (`spike on(ci)` is not a
#         thing anyone writes), so they are deliberately NOT given one. #1475's
#         suggested-fix point 1 scopes the change to type-shaped prefixes only,
#         and this is that scoping made executable.
#
# Deliberate non-matches, each asserted in the test suite:
#
#   fix(spike): tighten the detector      — `spike` is the SCOPE, not the type
#   spike-shape detection misses ...      — no colon, no scope group
#   spikes: three of them                 — `spike` must be the whole type
#   investigation(x): ...                 — `investigation` != `investigate`
#   chore: investigate whether ...         — prefix is anchored, not substring
#   design spike on caching                — neither prose form; #774 behavior
#
# `investigate(...)` vs. the investigate MODE — the collision, decided
# -------------------------------------------------------------------
# `investigate` is BOTH a title prefix here AND a live /do-work mode with its
# own separate detection path (`setup/04d-investigate-routing.md`: bot-shaped
# trusted author, or symptom-shaped body). #1475 required this be decided
# explicitly rather than left to whoever reads the two specs next.
#
# THE INVESTIGATE MODE WINS WHENEVER ITS OWN DETECTION FIRES — and it wins
# structurally, not by a tiebreak rule anyone has to remember:
#
#   - Investigate routing runs at setup step 4, during backlog classification.
#     A matched issue is REMOVED from the survivor list and appended to
#     `investigate_candidates`, drained by its own dispatch step.
#   - Spike-shape detection runs later, at the `ready_issues` dispatch site,
#     over candidates that survived step 4 and landed in `raw_backlog`.
#
# So an `investigate(x):`-titled issue whose body IS symptom-shaped (or whose
# author is bot-shaped) never reaches this detector at all — it was diverted an
# entire phase earlier. And an `investigate(x):`-titled issue whose body is NOT
# symptom-shaped never matched the investigate route in the first place, so
# there is nothing for it to collide with: it routes to `mode: spike`.
#
# That is also the right answer on the merits. The two detectors read different
# fields on purpose: the investigate MODE keys off the BODY and AUTHOR (a
# machine-filed crash report needing triage before it can be specified), while
# this detector keys off the TITLE (a human framing an open question, e.g.
# "investigate whether X is worth doing" — which is spike shape). A human who
# titles an issue `investigate(scope):` and writes a prose question, not a
# stack trace, is asking for a feasibility investigation, and spike mode is the
# contract that lets the answer be "we measured it; build nothing."
#
# Usage
# -----
#   spike-shape-detect.sh --title <title> [--labels <csv>] [--why]
#
#   --title   REQUIRED. The issue title, verbatim.
#   --labels  Optional comma-separated label names (the `labels` projection the
#             dispatch site already fetched). Empty/absent means no labels.
#   --why     Also print the matching signal, tab-separated after the verdict.
#
# Output: exactly one line on stdout.
#   `spike`       — dispatch `mode: spike` (shipyard:spike-worker)
#   `issue-work`  — not spike-shaped; the caller's normal routing applies
#
# With --why the line is `<verdict>\t<signal>`, where signal is one of
# `label`, `title-type-prefix`, `title-prose-prefix`, or `none`.
#
# Exit status: 0 = classified (either verdict), 2 = usage error. The verdict is
# on STDOUT, never in the exit status — `issue-work` is a normal answer, not a
# failure, and encoding it as a non-zero exit would make every call site need a
# `|| true` that would then swallow real usage errors.

set -u

usage() {
  cat >&2 <<'EOF'
usage: spike-shape-detect.sh --title <title> [--labels <csv>] [--why]

  --title   REQUIRED. The issue title, verbatim.
  --labels  Optional comma-separated label names.
  --why     Print `<verdict>\t<signal>` instead of just `<verdict>`.

Prints `spike` or `issue-work` on stdout. Exit 0 = classified, 2 = usage error.
EOF
  exit 2
}

# The two title-prefix families. Kept as named constants so the test suite and
# any future call site can reference the same strings rather than re-typing a
# second copy of the regex — the exact drift this script exists to prevent.
#
# TYPE-shaped: the four genuine Conventional-Commits types, each with an
# OPTIONAL `(scope)` group. This is the #1475 fix.
SPIKE_TYPE_PREFIX_RE='^[[:space:]]*(spike|investigate|research|feasibility)(\([^)]*\))?:'
# PROSE-shaped: the two non-CC framings, bare, unchanged from #774.
SPIKE_PROSE_PREFIX_RE='^[[:space:]]*(spike on([[:space:]]|$)|design spike:)'

title=""
labels=""
why="false"
have_title="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      [[ $# -ge 2 ]] || usage
      title="$2"
      have_title="true"
      shift 2
      ;;
    --labels)
      [[ $# -ge 2 ]] || usage
      labels="$2"
      shift 2
      ;;
    --why)
      why="true"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "spike-shape-detect: unrecognized argument: $1" >&2
      usage
      ;;
  esac
done

if [[ "$have_title" != "true" ]]; then
  echo "spike-shape-detect: --title is required" >&2
  usage
fi

verdict="issue-work"
signal="none"

# --- Signal 1: the `spike` label (exact token, case-insensitive). -------------
# Split on commas only; a label name may legitimately contain spaces, so the
# per-field trim is whitespace-only and the comparison is against the whole
# field, never a substring of it (`spike-followup` must not match).
if [[ -n "$labels" ]]; then
  IFS=',' read -r -a _label_fields <<<"$labels"
  for _label in "${_label_fields[@]}"; do
    # Trim surrounding whitespace.
    _label="${_label#"${_label%%[![:space:]]*}"}"
    _label="${_label%"${_label##*[![:space:]]}"}"
    if [[ "$(printf '%s' "$_label" | tr '[:upper:]' '[:lower:]')" == "spike" ]]; then
      verdict="spike"
      signal="label"
      break
    fi
  done
fi

# --- Signal 2: the title prefix. ---------------------------------------------
# Lowercase once and match with ERE rather than toggling `nocasematch`, so the
# regex constants above are exactly the strings a reader sees quoted in the
# specs (a `shopt` toggle would leave them looking case-sensitive).
if [[ "$verdict" != "spike" ]]; then
  _title_lc="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
  if [[ "$_title_lc" =~ $SPIKE_TYPE_PREFIX_RE ]]; then
    verdict="spike"
    signal="title-type-prefix"
  elif [[ "$_title_lc" =~ $SPIKE_PROSE_PREFIX_RE ]]; then
    verdict="spike"
    signal="title-prose-prefix"
  fi
fi

if [[ "$why" == "true" ]]; then
  printf '%s\t%s\n' "$verdict" "$signal"
else
  printf '%s\n' "$verdict"
fi

exit 0

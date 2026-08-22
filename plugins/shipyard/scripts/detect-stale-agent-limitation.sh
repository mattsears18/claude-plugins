#!/usr/bin/env bash
# detect-stale-agent-limitation.sh — re-validate an issue body's SELF-DECLARED
# "this part is out of scope for an autonomous agent" claim against live
# session state, instead of taking it at face value (issue #1491).
#
# Background (issue #1491)
# -----------------------
# An issue body is a snapshot of what was true when it was filed. Capability
# grants — token scopes, new tooling, a lifted policy — move independently of
# it. Session `do-work-20260820T024447Z-51928` against `mattsears18/lightwork`
# hit the failure this script exists to prevent: two issues (#4255, #4176)
# declared, in their own bodies, that the `.github/workflows/` half of their
# work was "out of scope for an autonomous `/shipyard:do-work` worker" and
# handed it to a human. Both premises were FALSE at dispatch time — the
# dispatching `gh` token carried the `workflow` OAuth scope. Taken at face
# value, both would have shipped half a feature and filed a spurious
# `agent-console` hand-back for work the agent could do itself. Four more
# issues in the same backlog were shaped by the same assumption.
#
# The existing machinery is one-directional: `detect-missing-workflow-scope.sh`
# warns when the token LACKS `workflow` and workflow-touching work looks
# likely. Nothing checks the far more damaging inverse — the token HAS a
# capability that the backlog's own text asserts it lacks. This script is that
# inverse check, and it deliberately does NOT delegate to
# `detect-missing-workflow-scope.sh`: that script's verdict vocabulary
# (`warn`/`silent`) conflates *has the scope* with *lacks it but no session
# signal*, so it structurally cannot answer "does this token carry `workflow`?"
# (see do-work/setup/06-scope-preflight.md's Detector 1 note, which explicitly
# forbids consulting it for this purpose).
#
# Deliberately NARROW. It fires only when a body BOTH declares an agent
# limitation AND names a capability this script can mechanically probe — today
# exactly one class, `workflow-scope`, anchored on the literal path fragment
# `.github/workflows`. It is not a general-purpose "second-guess the issue
# author" heuristic and must not grow into one: a new class earns its place
# only when it comes with a real probe of live session state.
#
# The action on a `stale` verdict is ADVISORY ONLY — a correction sentence in
# the dispatch prompt, and a standing prohibition on letting the self-declared
# limitation feed a defer. Nothing here gates, defers, or reorders a dispatch,
# so the scan is allowed to over-fire on a meta-issue that merely QUOTES the
# shape (issue #1491's own body is the canonical such fixture). The asymmetry
# is the opposite of Detector 2's: a false correction costs one advisory
# sentence; a missed correction costs a wrongly-narrowed dispatch that ships
# half a deliverable and files a spurious hand-back.
#
# Modes
# -----
#   --decide <claim:0|1> <capability:has|lacks|unknown>
#       Pure decision, no I/O — prints one of:
#         no-claim       no self-declared limitation was found
#         stale          the body claims the agent can't; the session says it can
#         upheld         the body's claim about the capability still holds
#         indeterminate  the capability could not be established
#       This is what the regression suite drives, same split as
#       detect-missing-workflow-scope.sh's and
#       detect-ungated-admin-direct-merge.sh's `--decide` modes.
#
#   --scan <body-file>
#       Body scan only, no network I/O. Prints either
#       `class=<class> phrase=<matched limitation phrasing>` or `none`.
#
#   --probe <class>
#       Live capability probe only. Prints `has` / `lacks` / `unknown`.
#
#   <body-file>
#       Live mode: scan, then probe (only when the scan hit), then decide.
#       Prints one line:
#         verdict=<v> class=<c> capability=<s> phrase=<p>
#
# Always exits 0. Every unresolvable condition resolves toward the no-op
# verdict — an advisory check must never be able to fail a caller.
#
# Usage: commands/do-work/setup/06-scope-preflight.md's "Self-declared
# agent-limitation re-validation" step.
set -u

# Self-declared agent-limitation phrasings, lowercased ERE alternation. Kept
# to phrasings that name the AGENT as the thing that can't do the work — a
# bare "out of scope" (which is about the ISSUE's scope, not the agent's
# capability) deliberately does not match.
LIMIT_RE="out of scope for [^.]*(worker|agent)|handed back|handed off to a human|left (for|to) a human|requires a human|needs a human|(agent|worker) (cannot|can not|can.t)|not something an? (agent|worker) can"

# Capability anchors, per class. A class fires only when its anchor appears in
# the SAME paragraph as a limitation phrasing.
ANCHOR_WORKFLOW_RE="\\.github/workflows"

usage() {
  cat <<'USAGE'
detect-stale-agent-limitation.sh — re-validate an issue body's self-declared
"out of scope for an agent" claim against live session state (issue #1491).

  --decide <claim:0|1> <capability:has|lacks|unknown>   pure decision
  --scan   <body-file>                                  body scan only
  --probe  <class>                                      live capability probe
  <body-file>                                           scan + probe + decide
USAGE
}

decide() {
  local claim="${1:-0}" capability="${2:-unknown}"
  if [[ "$claim" != "1" ]]; then
    echo "no-claim"
    return
  fi
  case "$capability" in
    has)   echo "stale" ;;
    lacks) echo "upheld" ;;
    *)     echo "indeterminate" ;;
  esac
}

scan_body() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "none"
    return
  fi
  awk -v limit_re="$LIMIT_RE" -v anchor_re="$ANCHOR_WORKFLOW_RE" '
    BEGIN { RS = ""; found = 0 }
    {
      para = $0
      gsub(/\r/, "", para)
      lower = tolower(para)
      if (lower ~ anchor_re && match(lower, limit_re)) {
        phrase = substr(para, RSTART, RLENGTH)
        gsub(/[\n\t]+/, " ", phrase)
        gsub(/  +/, " ", phrase)
        if (length(phrase) > 120) { phrase = substr(phrase, 1, 117) "..." }
        print "class=workflow-scope phrase=" phrase
        found = 1
        exit
      }
    }
    END { if (!found) print "none" }
  ' "$file"
}

# Does the dispatching `gh` token carry the `workflow` OAuth scope?
#
# TRI-STATE on purpose. `gh auth status` prints a `Token scopes:` line for an
# OAuth-app token; a fine-grained PAT or a `GITHUB_TOKEN` prints `none` or no
# line at all, and neither is evidence the token lacks workflow write access.
# Collapsing "can't tell" into "lacks" is exactly the conflation that makes
# detect-missing-workflow-scope.sh's `silent` unusable for this question.
probe_workflow_scope() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  local status_out scopes_line
  status_out="$(gh auth status 2>&1 || true)"
  scopes_line="$(printf '%s\n' "$status_out" | grep -m1 'Token scopes:' || true)"
  if [[ -z "$scopes_line" ]]; then
    echo "unknown"
    return
  fi
  if printf '%s' "$scopes_line" | grep -q "'workflow'"; then
    echo "has"
    return
  fi
  if printf '%s' "$scopes_line" | grep -qi 'none'; then
    echo "unknown"
    return
  fi
  echo "lacks"
}

probe_class() {
  case "${1:-}" in
    workflow-scope) probe_workflow_scope ;;
    *)              echo "unknown" ;;
  esac
}

case "${1:-}" in
  --decide)
    decide "${2:-0}" "${3:-unknown}"
    exit 0
    ;;
  --scan)
    scan_body "${2:-}"
    exit 0
    ;;
  --probe)
    probe_class "${2:-}"
    exit 0
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  "")
    echo "verdict=no-claim class=none capability=n/a phrase=-"
    exit 0
    ;;
esac

BODY_FILE="$1"
SCAN_RESULT="$(scan_body "$BODY_FILE")"

if [[ "$SCAN_RESULT" == "none" ]]; then
  echo "verdict=no-claim class=none capability=n/a phrase=-"
  exit 0
fi

CLASS="${SCAN_RESULT%% phrase=*}"
CLASS="${CLASS#class=}"
PHRASE="${SCAN_RESULT#*phrase=}"
CAPABILITY="$(probe_class "$CLASS")"
VERDICT="$(decide 1 "$CAPABILITY")"

echo "verdict=$VERDICT class=$CLASS capability=$CAPABILITY phrase=$PHRASE"
exit 0

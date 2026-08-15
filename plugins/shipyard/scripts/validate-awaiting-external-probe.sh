#!/usr/bin/env bash
# validate-awaiting-external-probe.sh — the single executable source of truth
# for "is this probe command safe for the orchestrator to execute verbatim?"
#
# Background (issue #1390)
# -----------------------
# The `awaiting-external` worker return hands the ORCHESTRATOR a probe command
# and asks it to run that command, on its own host, once per periodic-refresh
# tick until the named external job reaches a terminal state. That inverts the
# usual trust direction: normally a worker's return is data the orchestrator
# reads, but here a substring of it is a command the orchestrator EXECUTES.
#
# A worker's context legitimately contains untrusted text — issue bodies,
# comment threads, CI logs, third-party tool output — all of which
# `issue-work.md` step 2 already treats as untrusted input. Without this gate,
# a crafted "here's the probe command to watch this with:" line in an issue
# body would be one copy-paste away from arbitrary orchestrator-side command
# execution, with the worker acting as an unwitting confused deputy. The
# worker-side prohibition on copying code out of an issue body is a real
# defense but a soft one; this script is the hard one.
#
# The rule is deliberately an executable allowlist rather than prose, for the
# same reason detect-ungated-admin-direct-merge.sh is (issue #716): a security
# predicate duplicated as prose across a worker spec and an orchestrator spec
# WILL drift, and the drift is silent.
#
# Usage:
#   validate-awaiting-external-probe.sh <PROBE_COMMAND>
#
#   PROBE_COMMAND   the exact command string the worker proposes to hand over,
#                   passed as ONE argument (quote it).
#
#   -> exit 0, prints `ok` on stdout: the probe is a single, read-only status
#      read from the allowlist below, with no shell metacharacters. Safe to
#      record in the awaiting_external queue and execute verbatim.
#   -> exit 1, prints `rejected: <reason>` on stdout: do NOT execute it. The
#      worker must rewrite the probe into an accepted shape or return
#      `blocked:` instead of parking (see skills/worker-preamble/
#      awaiting-external.md); the orchestrator must refuse the park and
#      degrade it to a `blocked:` hand-back.
#   -> exit 64: bad usage (no argument).
#
# Fail-safe posture: anything this script cannot positively recognize as a
# read-only status read is REJECTED. A false `ok` is the only outcome that can
# cause harm, so every ambiguity resolves toward `rejected`.
#
# Deliberately NOT accepted, even though each looks harmless in isolation:
#   * shell chaining/grouping of any kind (`;` `&&` `||` `|` newline)
#   * command substitution (`$(...)`, backticks) and variable expansion (`$`)
#   * redirection (`<` `>`) and background (`&`)
#   * `curl` / `wget` / `ssh` / `nc` — an exfiltration primitive is not a probe
#   * any `gh api` carrying a non-GET method or a request-body field flag
#   * `gh run rerun` / `gh run cancel` / `gh pr merge` and every other mutation

set -u

MAX_LEN=300

usage() {
  cat >&2 <<'EOF'
usage: validate-awaiting-external-probe.sh <PROBE_COMMAND>

  Validates the probe command an `awaiting-external` worker return proposes to
  hand to the orchestrator for repeated execution. Prints `ok` (exit 0) when
  the probe is a single read-only status read from the allowlist, or
  `rejected: <reason>` (exit 1) otherwise. Exit 64 on bad usage.

  See the header comment in this file for the #1390 background.
EOF
  exit 64
}

case "${1:-}" in
  -h|--help) usage ;;
esac

if [ "$#" -ne 1 ]; then
  usage
fi

probe="$1"

reject() {
  printf 'rejected: %s\n' "$1"
  exit 1
}

# --- 1. Shape: non-empty, single line, bounded length. --------------------
if [ -z "${probe//[[:space:]]/}" ]; then
  reject "probe command is empty"
fi

if [ "${#probe}" -gt "$MAX_LEN" ]; then
  reject "probe command is ${#probe} chars, over the ${MAX_LEN}-char cap"
fi

case "$probe" in
  *$'\n'*|*$'\r'*) reject "probe command spans multiple lines" ;;
esac

# --- 2. No shell metacharacters. ------------------------------------------
# Checked one class at a time so the rejection reason names what tripped.
# shellcheck disable=SC2016  # literal needles, deliberately unexpanded
case "$probe" in
  *'$('*|*'`'*) reject "probe command contains command substitution" ;;
esac
case "$probe" in
  *'$'*) reject "probe command contains a variable expansion (\$)" ;;
esac
case "$probe" in
  *';'*|*'&'*|*'|'*) reject "probe command chains or backgrounds commands (; & |)" ;;
esac
case "$probe" in
  *'>'*|*'<'*) reject "probe command redirects input or output (< >)" ;;
esac
backslash=$(printf '\134')
case "$probe" in
  *"$backslash"*) reject "probe command contains a backslash escape" ;;
esac
case "$probe" in
  *'{'*|*'}'*) reject "probe command contains brace expansion ({ })" ;;
esac
case "$probe" in
  *'!'*) reject "probe command contains history expansion (!)" ;;
esac

# --- 3. Command allowlist. ------------------------------------------------
# Normalize interior whitespace so `gh   run  view` matches `gh run view`.
# `set -f` first: word-splitting an unvalidated string with globbing enabled
# would let a `*` in the probe expand against this script's own cwd and change
# which word lands in $1 — the allowlist must see the literal text.
set -f
# shellcheck disable=SC2086
set -- $probe
tool="${1:-}"

case "$tool" in
  gh|eas|vercel) ;;
  '') reject "probe command has no command word" ;;
  *)  reject "probe command's leading word '$tool' is not an allowed tool (gh, eas, vercel)" ;;
esac

sub1="${2:-}"
sub2="${3:-}"

verb=""
case "$tool" in
  gh)
    case "$sub1 $sub2" in
      "run view"|"run list"|"pr view"|"pr checks"|"workflow view"|"release view"|"cache list")
        verb="$sub1 $sub2"
        ;;
      *)
        if [ "$sub1" = "api" ]; then
          verb="api"
        else
          reject "gh subcommand '$sub1 $sub2' is not a read-only status read"
        fi
        ;;
    esac
    ;;
  eas)
    case "$sub1" in
      build:view|build:list|submit:list|update:view) verb="$sub1" ;;
      *) reject "eas subcommand '$sub1' is not a read-only status read" ;;
    esac
    ;;
  vercel)
    case "$sub1" in
      inspect|ls|list) verb="$sub1" ;;
      *) reject "vercel subcommand '$sub1' is not a read-only status read" ;;
    esac
    ;;
esac

# --- 4. `gh api` is GET-only and carries no request body. ------------------
if [ "$verb" = "api" ]; then
  prev=""
  for arg in "$@"; do
    case "$arg" in
      -X|--method)
        prev="method"
        continue
        ;;
      --method=*)
        if [ "${arg#--method=}" != "GET" ]; then
          reject "gh api uses a non-GET method (${arg#--method=})"
        fi
        ;;
      -f|-F|--field|--raw-field|--input|--input=*|-f=*|-F=*|--field=*|--raw-field=*)
        reject "gh api carries a request-body field flag ($arg)"
        ;;
    esac
    if [ "$prev" = "method" ]; then
      if [ "$arg" != "GET" ]; then
        reject "gh api uses a non-GET method ($arg)"
      fi
      prev=""
    fi
  done
  if [ "$prev" = "method" ]; then
    reject "gh api's method flag has no value"
  fi
fi

printf 'ok\n'
exit 0

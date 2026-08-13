#!/usr/bin/env bash
# PreToolUse hook — blocks a `Read` call that targets a `plugins/shipyard/**`
# spec file OUTSIDE the agent's own isolated worktree, when a worktree-local
# copy of that same file exists to read instead.
#
# WHY THIS EXISTS (issue #1320)
# ------------------------------
# #969 made every dispatched worker PREFER its own worktree's `plugins/
# shipyard` copy over the orchestrator-supplied primary-checkout literal for
# SCRIPT INVOCATION (`CLAUDE_PLUGIN_ROOT`) — but that resolution is prose the
# worker has to remember to apply, and nothing stopped a plain `Read` call
# from bypassing it entirely by naming an absolute path straight into the
# primary checkout. #1319's own evidence is a dispatched worker actually
# doing exactly that: it read the primary checkout's copy of a spec file
# first, and only self-corrected via a live discriminator test later in the
# same session — caught by luck plus diligence, not by anything structural.
# On the dogfooding repo (shipyard working on its own source), the primary
# checkout can be measurably behind `origin/<default-branch>` (issue #907),
# so a `Read` that lands there hands the worker a stale spec with nothing in
# its own context flagging it.
#
# This hook makes the "prefer your own worktree's copy" resolution
# STRUCTURAL for `Read`, mirroring `enforce-edit-scope.sh`'s write-side
# scoping (same worktree-detection convention: only fires when cwd is inside
# `.claude/worktrees/agent-<id>/`) rather than leaving it as advisory text a
# worker has to apply on every `Read` call by itself. Companion mechanism to
# `assert-worktree-cwd.sh` (the git-dir/git-common-dir predicate every
# Bash-tool worktree check already uses) and to #1320's other half — wiring
# #1319's staleness warnings into the Workflow-substrate dispatch shape
# (`workflows/prompt-templates/shared.mjs`'s `stalenessAddendumLines`).
#
# DECISION RULES (all must hold to BLOCK)
# ----------------------------------------
#   1. Tool name is Read.
#   2. Hook's `cwd` is inside `.claude/worktrees/agent-<id>/` — i.e. we are
#      inside a dispatched worker's isolated worktree. Orchestrator worktrees
#      (`.claude/worktrees/orchestrator-<...>`), bare primary-checkout
#      sessions, and any other cwd shape fall through transparently — this
#      guard exists for dispatched WORKERS reading their own copy of the
#      spec, not for the orchestrator's own use of the primary checkout.
#   3. The file_path (absolute, or resolved against cwd if relative) contains
#      a `plugins/shipyard/` path component, AND the resolved path is NOT
#      already inside the worktree.
#   4. A worktree-local equivalent — `<worktree_root>/plugins/shipyard/<the
#      same suffix>` — actually EXISTS on disk. This is what keeps the guard
#      a pure redirect rather than a dead end: a genuine consumer-install
#      layout (no worktree-local `plugins/shipyard` copy at all, because the
#      plugin is installed elsewhere and this repo isn't shipyard's own
#      source) has no in-worktree equivalent to redirect to, so the read is
#      allowed through unchanged — exactly the "prefer worktree, else fall
#      back to the literal" resolution #1319's PR recommended and #965/#969
#      already document for script invocation.
#
# When all four hold, exit 2 with stderr naming the exact worktree-local path
# to re-issue the Read against. Anything else exits 0 transparently.
#
# SCOPE NOTE: this guards `Read` only, not `Grep`/`Bash cat`/etc. `Read` is
# the concrete failure mode #1319's evidence and the issue body both name
# ("an absolute-path Read call bypasses the resolution above entirely") — a
# worker reaching for `cat`/`grep` against an absolute primary-checkout path
# instead is already covered by the git-mutation surface guarded elsewhere,
# and widening this hook to every possible read-shaped tool call risks false
# positives (e.g. a legitimate cross-repo Grep) for a benefit this issue
# doesn't evidence. Narrow and structural beats broad and guessed.
#
# FAIL-OPEN: not a repo / detection error / malformed input / no worktree-
# local equivalent on disk → allow. A guard that blocks every read on a
# hiccup is far worse than one that occasionally misses (same posture as
# enforce-edit-scope.sh and guard-primary-checkout.sh).
#
# Contract: read PreToolUse JSON from stdin; exit 2 + stderr to block; exit 0
# otherwise. Never propagate other errors.

set -u

# Belt-and-braces — any internal error falls through to "allowed".
trap 'exit 0' ERR

input=$(cat 2>/dev/null || true)

if [[ -z "$input" ]]; then
  exit 0
fi

# Single source of decision logic (python3, matching enforce-edit-scope.sh's
# convention — already a required dependency via report-plugin-error.sh, so
# this doesn't widen the dependency surface).
PY_DECIDE=$(cat <<'PY'
import json, os, sys

raw = sys.stdin.read() or ""
try:
    d = json.loads(raw)
except Exception:
    print("ALLOW")
    sys.exit(0)

tool = d.get("tool_name") or ""
if tool != "Read":
    print("ALLOW")
    sys.exit(0)

tool_input = d.get("tool_input") or {}
file_path = tool_input.get("file_path") or ""
cwd = d.get("cwd") or os.environ.get("PWD") or ""

if not file_path or not cwd:
    print("ALLOW")
    sys.exit(0)

# Identify the agent's worktree by walking up from cwd until we find a
# `.claude/worktrees/agent-<id>` triplet — identical detection to
# enforce-edit-scope.sh, deliberately not extended to orchestrator-* (the
# orchestrator legitimately reads the primary checkout directly; this guard
# is scoped to dispatched WORKER sessions only).
norm_cwd = os.path.normpath(cwd)
parts = norm_cwd.split(os.sep)

worktree_root = None
for i in range(len(parts) - 1):
    if (parts[i] == ".claude" and i + 2 < len(parts)
            and parts[i + 1] == "worktrees"
            and parts[i + 2].startswith("agent-")):
        worktree_root = os.sep.join(parts[: i + 3])
        break

if worktree_root is None:
    print("ALLOW")
    sys.exit(0)

# Resolve file_path relative to cwd, normalize (no symlink following — same
# rationale as enforce-edit-scope.sh: we compare the path the model typed,
# not whatever it might resolve to on disk).
if not os.path.isabs(file_path):
    file_path = os.path.join(cwd, file_path)
norm_file = os.path.normpath(file_path)

# Already inside the worktree? Nothing to redirect.
try:
    common = os.path.commonpath([norm_file, worktree_root])
except ValueError:
    common = ""
if common == worktree_root:
    print("ALLOW")
    sys.exit(0)

# Does the path even go through a plugins/shipyard/ component? If not, this
# guard has nothing to say about it — every other out-of-worktree Read (a
# README a worker legitimately wants to inspect, a sibling repo, etc.) is
# unaffected, matching enforce-edit-scope.sh's own "Read is allowed" carve-out.
marker = f"{os.sep}plugins{os.sep}shipyard{os.sep}"
idx = norm_file.find(marker)
if idx == -1:
    print("ALLOW")
    sys.exit(0)

suffix = norm_file[idx + len(marker):]
if not suffix:
    print("ALLOW")
    sys.exit(0)

candidate = os.path.join(worktree_root, "plugins", "shipyard", suffix)

# Only redirect when the worktree-local equivalent genuinely exists — a
# consumer-install target repo (no plugins/shipyard tree of its own) has
# nothing to redirect to, so fall through unchanged (issue #969's
# already-documented fallback).
if not os.path.isfile(candidate):
    print("ALLOW")
    sys.exit(0)

print(f"BLOCK\t{worktree_root}\t{norm_file}\t{candidate}")
PY
)

result=$(printf '%s' "$input" | python3 -c "$PY_DECIDE" 2>/dev/null || true)

case "${result%%$'\t'*}" in
  BLOCK)
    rest="${result#*$'\t'}"
    worktree="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    target="${rest%%$'\t'*}"
    candidate="${rest#*$'\t'}"
    cat >&2 <<EOF
BLOCKED by shipyard/hooks/enforce-fresh-spec-read.sh.

You attempted to Read a plugins/shipyard/** spec file OUTSIDE your isolated
worktree, even though your own worktree carries a copy of the same file:

  worktree:            ${worktree}
  attempted (stale):    ${target}
  re-issue against:      ${candidate}

Reading a spec file via an absolute path into the primary checkout bypasses
the worktree-preferred CLAUDE_PLUGIN_ROOT resolution entirely and can hand
you a stale spec on the dogfooding repo, where the primary checkout can be
measurably behind origin/<default-branch> (issue #907) with nothing else in
this session flagging it (issue #1319's own evidence: a worker read the
primary checkout's copy first and only self-corrected later by luck plus
diligence).

Fix: re-issue this Read against the worktree-local path shown above. Your OWN
worktree is always the fresher, load-bearing copy for anything you read to
edit or reason about this session (issue #969) — the primary-checkout literal
is an invocation fallback for script calls only (issue #965), never a Read
target when a worktree-local copy exists.

If you think this block is wrong (e.g. you deliberately need the primary
checkout's copy for some reason this guard doesn't anticipate), return
blocked with the worktree path so the orchestrator can investigate.
EOF
    exit 2
    ;;
  *)
    exit 0
    ;;
esac

#!/usr/bin/env bash
# orchestrator-git-dash-c-scan.sh — flag a post-relocation ```bash fenced
# block that issues `git -C <other-path>` directly (not via a helper
# script), inside a curated set of orchestrator-context command files.
#
# Background (issue #1323, extending #1316 / #1317)
# ---------------------------------------------------
# #1316 established that a worktree-isolated orchestrator's harness guard
# unconditionally refuses `git -C <other-path>` issued directly from its own
# Bash tool call, read-only or not: "this command redirects git to the
# shared checkout via -C. Refusing to run it." #1317 converted A.0.5's two
# inspection sites to a helper-script call (`worktree-reap.sh
# inspect-unpushed`); #1323 converted A.0.6's primary-checkout branch-leak
# guard the same way (`primary-leak-guard.sh run`). Both fixes follow the
# same pattern: `git -C` INSIDE a helper script's own bash process is
# unaffected by the guard (it inspects the literal command TEXT of the
# orchestrator's own Bash tool call, not what a script it invokes does
# internally) — so the fix is always "move the `git -C` inside a script
# invoked by a plain, no-`-C` outer call," never "leave it inline and hope."
#
# This scanner is the "keep this from recurring" half of #1323's suggested
# direction #3: a repo-wide grep for `git -C` inside `plugins/shipyard/
# commands/**` plus a CI gate, in the spirit of `compound-block-scan.sh` /
# `claude-plugin-root-preamble.test.sh` — a cheap, deliberately narrow
# structural check, not a full shell parser or a liveness prover.
#
# Scope (deliberately conservative, same reasoning as compound-block-scan.sh
# issue #1277). This does NOT sweep every tracked file by default — the
# corpus mixes pre-relocation content (the `setup/*.md` sweeps that
# EnterWorktree-precede relocation, where `git -C <other-worktree>` is
# legitimate because the isolation guard has not yet activated for the
# session — see `setup/00e-pre-relocation-sweeps.md`) with post-relocation
# content, and a blind sweep would either miss the pre-relocation exclusion
# or drown in it. Instead it walks an explicit FILES list of files that run
# exclusively post-relocation (after `EnterWorktree`, i.e. after setup step
# 0.5) — extend FILES as more of the corpus is swept and verified clean,
# same evolutionary path `compound-block-scan.sh` itself took.
#
# What counts as a finding: a line inside a fenced ```bash block, not a
# comment (doesn't start with `#` after leading whitespace), containing the
# literal substring `git -C`. This intentionally does NOT try to distinguish
# "targets another worktree" (refused) from "targets the caller's own
# current worktree" (the sanctioned `worker-preamble` mid-session
# cwd-anchoring shape, `git -C "$WORKTREE_PATH" ...` against yourself) —
# that distinction requires knowing which worktree is "self" at the call
# site, which is not statically decidable from the markdown text alone. The
# one known self-targeting exception in this corpus
# (`cleanup-summary.md`'s end-of-session reap of the orchestrator's OWN
# worktree) is exempted via the explicit allow-marker below, same mechanism
# as `compound-block-scan.sh`'s own documented-bad-example exemption — this
# keeps the scanner's job narrow (inline `git -C` in a post-relocation
# fenced block is *always* worth a human decision: either it is the
# self-targeting shape and gets the marker, or it is the refused
# cross-worktree shape and needs a helper script) rather than trying to be
# clever about which is which.
#
# False-positive guard:
#   - An explicit `<!-- orchestrator-git-dash-c-scan: allow -->` line
#     immediately before the opening fence exempts that one block — for a
#     documented, reviewed exception (self-targeting `-C`, or a block
#     intentionally showing the refused shape as a "don't do this" example).
#
# Usage:
#   bash plugins/shipyard/scripts/orchestrator-git-dash-c-scan.sh            # scan the built-in FILES list
#   bash plugins/shipyard/scripts/orchestrator-git-dash-c-scan.sh <path>...  # scan explicit files instead
#
# Exit status: 0 = no findings, 1 = at least one finding (prints
# file:line + snippet), 2 = usage / environment error.

set -u

usage() {
  cat >&2 <<'EOF'
usage: orchestrator-git-dash-c-scan.sh [path ...]
  With no args, scans the built-in FILES list (see script header for scope
  rationale). With paths, scans exactly the given files instead.
  --help itself always exits 0, distinct from the usage/environment-error
  exit 2 (#1550).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "orchestrator-git-dash-c-scan: not inside a git work tree" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"

# The curated, entirely-post-relocation orchestrator-context file list. See
# the Scope note in the header for why this isn't a blanket repo sweep.
FILES=(
  "$repo_root/plugins/shipyard/commands/do-work/steady-state.md"
  "$repo_root/plugins/shipyard/commands/do-work/drain.md"
  "$repo_root/plugins/shipyard/commands/do-work/dispatch-rules.md"
  "$repo_root/plugins/shipyard/commands/do-work/cleanup-summary.md"
)

if [[ $# -gt 0 ]]; then
  candidates=("$@")
else
  candidates=("${FILES[@]}")
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "orchestrator-git-dash-c-scan: no files to scan" >&2
  exit 0
fi

# _scan_file <path> — prints findings (if any) to stdout, one per line:
#   <path>:<line>: <the offending line, trimmed>
# Returns 0 if clean, 1 if it found something.
_scan_file() {
  local file="$1"
  awk -v FILE="$file" '
    BEGIN { in_block = 0; pending_allow = 0; found_any = 0 }

    /^[[:space:]]*<!--[[:space:]]*orchestrator-git-dash-c-scan:[[:space:]]*allow[[:space:]]*-->[[:space:]]*$/ {
      pending_allow = 1
      next
    }

    /^[[:space:]]*```bash[[:space:]]*$/ {
      in_block = 1
      allow_this = pending_allow
      pending_allow = 0
      next
    }

    /^[[:space:]]*```[[:space:]]*$/ {
      if (in_block) {
        in_block = 0
      }
      next
    }

    in_block {
      line = $0
      stripped = line
      sub(/^[[:space:]]+/, "", stripped)
      if (!allow_this && stripped !~ /^#/ && index(line, "git -C") > 0) {
        printf "%s:%d: %s\n", FILE, NR, stripped
        found_any = 1
      }
      next
    }

    END { exit (found_any ? 1 : 0) }
  ' "$file"
}

found=0
for f in "${candidates[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "orchestrator-git-dash-c-scan: no such file: $f" >&2
    exit 2
  fi
  if ! _scan_file "$f"; then
    found=1
  fi
done

if [[ "$found" -eq 1 ]]; then
  echo >&2
  echo "orchestrator-git-dash-c-scan: inline 'git -C' found in a post-relocation fenced bash block (issue #1323)." >&2
  echo "A worktree-isolated orchestrator's harness guard unconditionally refuses \`git -C <other-path>\`" >&2
  echo "issued directly from its own Bash tool call, read-only or not (issue #1316)." >&2
  echo "Move the git -C call inside a helper script (see scripts/worktree-reap.sh's inspect-unpushed" >&2
  echo "subcommand and scripts/primary-leak-guard.sh for the pattern) and invoke the script with a" >&2
  echo "plain, no-\`-C\` outer call instead — or, if this is a reviewed, self-targeting exception," >&2
  echo "add an <!-- orchestrator-git-dash-c-scan: allow --> marker immediately before the fence." >&2
  exit 1
fi

echo "orchestrator-git-dash-c-scan: all scanned file(s) are free of inline 'git -C' in post-relocation fenced bash blocks."

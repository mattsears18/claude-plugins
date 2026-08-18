#!/usr/bin/env bash
# command-substitution-scan.sh — flag ARGUMENT-POSITION command substitutions
# (`$(cmd)` passed as an argument rather than assigned to a variable) inside
# ```bash fenced blocks in the orchestrator + worker spec tree. The harness's
# worktree-isolation guard refuses any Bash call containing one:
#
#   "This agent is isolated in the worktree <path>, but this command is too
#    complex to verify that it stays inside the worktree; break it into
#    plain, separate commands."
#
# Background (issues #1308 -> #1311 -> #1314): #1308's controlled experiment
# isolated TWO refused shapes — a braced `${VAR}` parameter expansion
# ANYWHERE, and `$(cmd)` in ARGUMENT position. Its experiment rows K and L are
# the decisive pair:
#
#   K  export … ; SETTLED=$(bash "$CLAUDE_PLUGIN_ROOT/…/x.sh" get …)   allowed
#   L  bash "<literal>/scripts/assert-worktree-cwd.sh" "$(pwd)"        REFUSED
#
# Identical substitution, three statements vs one — the discriminator is
# assignment-RHS vs argument position, not statement count or block length.
#
# #1311 swept the brace half and enforced it in `brace-expansion-scan.sh`.
# #1314 is the sweep of the command-substitution half, and this scanner is its
# CI enforcement. It is a SIBLING of `brace-expansion-scan.sh` rather than a
# check bolted into it: the two shapes need different exemption policies (this
# one carries the assignment-RHS and arithmetic carve-outs plus the
# `CLAUDE_PLUGIN_ROOT` preamble exemption below, and its own allow marker so
# exempting a block for one shape never silently exempts it for the other).
#
# See https://code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation
# for the harness's own documentation of this refusal (the controlled
# experiment that isolated the trigger and for the convention itself.
#
# WHAT IS FLAGGED:
#
#   some-script "$(git rev-parse --show-toplevel)"    — argument position
#   cd "$(git rev-parse --show-toplevel)"             — argument position
#   for n in $(jq -r '.[].number' f.json); do         — argument position
#   [ -n "$(ls -A node_modules)" ]                    — argument position
#   X=$(cat "$(git rev-parse --show-toplevel)/f")     — the INNER one only
#
# The fix is always the same: hoist the substitution onto its own line as an
# assignment and pass the variable unbraced.
#
#   TOPLEVEL=$(git rev-parse --show-toplevel)
#   some-script "$TOPLEVEL"
#
# WHAT IS NOT FLAGGED — deliberately:
#
#   ARITHMETIC EXPANSION `$((expr))` is not command substitution at all and
#   must never be rewritten. `n=$((n + 1))`, `echo "$((a - b))"`, and
#   `printf '%d' "$(( (kb + 1023) / 1024 ))"` all stay legal. The scanner
#   detects it by the `(` immediately following `$(`.
#
#   ASSIGNMENT-RHS `$(cmd)` is the sanctioned form — the whole point of the
#   convention. `VAR=$(cmd)`, `VAR="$(cmd)"`, `VAR='$(cmd)'`,
#   `export VAR=$(cmd)`, `local/readonly/declare/typeset VAR=$(cmd)`, and
#   `arr[k]=$(cmd)` / `VAR+=$(cmd)` are all legal. Recognition is deliberately
#   STRICT — the `$(` must sit immediately after the `=` (optionally through
#   one opening quote), so `OUT=/tmp/run-$(date +%s)` IS flagged even though
#   it is technically on an assignment's right-hand side. #1308's experiment
#   only ever cleared the immediate form, and the cost asymmetry is lopsided:
#   a false positive costs one extra hoisted line in a spec, a false negative
#   costs a refused tool call in production on every dispatch that runs the
#   block.
#
# THE `CLAUDE_PLUGIN_ROOT` PREAMBLE EXEMPTION. Any line containing
# `CLAUDE_PLUGIN_ROOT:-` is skipped entirely. That is the canonical
# plugin-root resolution preamble:
#
#   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse …
#
# It is documented (bash-refusal-triggers.md § "The convention", and
# `worker-preamble`'s step-0) as PRE-RELOCATION-ONLY and already known-refused
# post-relocation — via the required-modifier `${VAR:-default}` expansion,
# which HAS no unbraced spelling and so cannot be fixed by de-bracing OR by
# de-substituting. Rewriting its inner `$(…)` would not make the block
# runnable; it would only churn 38 identical lines and hide the real residual.
# Both call sites that carry it already tell the reader to skip straight to
# the decomposed fallback when it is refused. It stays tracked under
# bash-refusal-triggers.md's required-modifier residual row.
#
# QUOTED-HEREDOC BODIES are skipped entirely, same as in
# `brace-expansion-scan.sh`: inside `<<'EOF'` (or `<<"EOF"`) the text is
# emitted LITERALLY rather than expanded, so a `$(cmd)` there is part of the
# emitted output, not a command the shell runs. Unquoted heredocs (`<<EOF`)
# DO expand and are still checked.
#
# False-positive guard: an explicit `<!-- command-substitution-scan: allow -->`
# line immediately before the opening fence skips that block entirely — for a
# block that intentionally shows the refused shape as a documented bad
# example, or one that is not a `Bash` call at all (the `Monitor` command in
# `worker-preamble/compound-command-refusal.md` is the canonical case: its
# whole point is that `Monitor` accepts the loop `Bash` refuses).
#
# SCOPE: mechanical discovery over every git-tracked `*.md` under `plugins/`,
# identical to `brace-expansion-scan.sh` and for the same reason — a NEW spec
# file is covered the day it lands, with no scanner edit, so the sweep cannot
# silently re-accumulate.
#
# Non-plugin markdown (repo-root README / CHANGELOG / CLAUDE.md) is out of
# scope — none of it is loaded into a worktree-isolated agent's context. Pass
# such a file explicitly if you want it checked anyway.
#
# Usage:
#   bash plugins/shipyard/scripts/command-substitution-scan.sh            # discovered plugin *.md
#   bash plugins/shipyard/scripts/command-substitution-scan.sh <path>...  # explicit files
#   bash plugins/shipyard/scripts/command-substitution-scan.sh --list     # print discovered paths
#
# Exit status: 0 = clean, 1 = at least one finding (prints file:line + the
# offending substitution), 2 = usage / environment error.

set -u

usage() {
  cat >&2 <<'EOF'
usage: command-substitution-scan.sh [--list] [path ...]
  With no args, scans every git-tracked *.md under plugins/ (see script
  header for scope rationale). With paths, scans exactly those files.
  --list prints the discovered paths (one per line) and exits 0.
EOF
  exit 2
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "command-substitution-scan: not inside a git work tree" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"

# Mechanical discovery — every git-tracked *.md under plugins/. `git ls-files`
# (rather than `find`) so untracked scratch files and anything gitignored can
# never enter the corpus.
discover() {
  local rel
  while IFS= read -r -d '' rel; do
    printf '%s\0' "$repo_root/$rel"
  done < <(git -C "$repo_root" ls-files -z -- 'plugins/*.md')
}

case "${1:-}" in
  -h|--help) usage ;;
  --list)
    discover | tr '\0' '\n'
    exit 0
    ;;
esac

candidates=()
if [[ $# -gt 0 ]]; then
  candidates=("$@")
else
  while IFS= read -r -d '' f; do
    candidates+=("$f")
  done < <(discover)
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  # A discovery run that finds nothing is a BROKEN scanner, not a clean repo —
  # the exact vacuous-pass shape #1312 found in the preamble test. Fail loudly.
  echo "command-substitution-scan: discovered zero files under plugins/ — the scanner is broken, not the corpus clean" >&2
  exit 2
fi

# _scan_file <path> — prints findings to stdout, one per line:
#   <path>:<line>: argument-position-command-substitution — $(...) (hoist it to an assignment)
# Prints a trailing `#blocks <n>` line to STDERR so the caller can total the
# number of fenced bash blocks actually inspected. That total is the
# anti-vacuity signal: a matcher that silently stops matching must fail
# loudly rather than pass over zero blocks — the exact regression #1312
# found in the pre-existing preamble test.
# Returns 0 if clean, 1 if it found something.
_scan_file() {
  local file="$1"
  awk -v FILE="$file" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }

    # A QUOTED heredoc opener. <<EOF (unquoted) expands and stays checked;
    # <<'"'"'EOF'"'"' / <<"EOF" emit their body literally, so their bodies are
    # skipped. Returns the delimiter word, or "" when the line opens none.
    function heredoc_tag(line,    s, i) {
      if (match(line, SQ_HD_RE)) {
        s = substr(line, RSTART, RLENGTH)
        i = index(s, SQ)
        return substr(s, i + 1, length(s) - i - 1)
      }
      if (match(line, DQ_HD_RE)) {
        s = substr(line, RSTART, RLENGTH)
        i = index(s, DQ)
        return substr(s, i + 1, length(s) - i - 1)
      }
      return ""
    }

    # Is the text immediately preceding a `$(` an assignment operator? One
    # optional opening quote is tolerated between the `=` and the `$(`.
    function is_assignment_rhs(p,    q) {
      q = p
      sub(QUOTE_TAIL_RE, "", q)
      return (q ~ ASSIGN_RE)
    }

    BEGIN {
      SQ = sprintf("%c", 39)
      DQ = sprintf("%c", 34)
      SQ_HD_RE = "<<-?[[:space:]]*" SQ "[A-Za-z_][A-Za-z0-9_]*" SQ
      DQ_HD_RE = "<<-?[[:space:]]*" DQ "[A-Za-z_][A-Za-z0-9_]*" DQ
      QUOTE_TAIL_RE = "[" SQ DQ "]$"
      # ^ or whitespace or a command separator, an optional declaration
      # keyword, a shell identifier (optionally subscripted), then `=` or `+=`
      # as the very last thing before the `$(`.
      ASSIGN_RE = "(^|[[:space:]]|[;&|(])((export|local|readonly|declare|typeset)[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*(\\[[^]]*\\])?[+]?=$"
      # The canonical pre-relocation-only plugin-root preamble — see the
      # header. Any line carrying it is skipped wholesale.
      PLUGIN_ROOT_PREAMBLE_RE = "CLAUDE_PLUGIN_ROOT:-"
      in_block = 0
      in_heredoc = 0
      hd_tag = ""
      allow_this = 0
      pending_allow = 0
      found_any = 0
      blocks = 0
    }

    /^[[:space:]]*<!--[[:space:]]*command-substitution-scan:[[:space:]]*allow[[:space:]]*-->[[:space:]]*$/ {
      pending_allow = 1
      next
    }

    !in_block && /^[[:space:]]*```bash[[:space:]]*$/ {
      in_block = 1
      in_heredoc = 0
      hd_tag = ""
      allow_this = pending_allow
      pending_allow = 0
      blocks++
      next
    }

    in_block && /^[[:space:]]*```[[:space:]]*$/ {
      in_block = 0
      in_heredoc = 0
      hd_tag = ""
      next
    }

    in_block {
      line = $0

      if (in_heredoc) {
        if (trim(line) == hd_tag) { in_heredoc = 0; hd_tag = "" }
        next
      }

      if (!allow_this && line !~ PLUGIN_ROOT_PREAMBLE_RE) {
        pos = 1
        while (1) {
          idx = index(substr(line, pos), "$(")
          if (idx == 0) break
          abs = pos + idx - 1
          pos = abs + 2
          # `$((` opens an ARITHMETIC expansion, never a command substitution.
          if (substr(line, abs + 2, 1) == "(") continue
          if (is_assignment_rhs(substr(line, 1, abs - 1))) continue
          snippet = substr(line, abs, 48)
          printf "%s:%d: argument-position-command-substitution — %s (hoist it to an assignment)\n", FILE, NR, snippet
          found_any = 1
        }
      }

      t = heredoc_tag(line)
      if (t != "") { in_heredoc = 1; hd_tag = t }
      next
    }

    END {
      printf "#blocks %d\n", blocks > "/dev/stderr"
      exit (found_any ? 1 : 0)
    }
  ' "$file"
}

found=0
total_blocks=0
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

for f in "${candidates[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "command-substitution-scan: no such file: $f" >&2
    exit 2
  fi
  if ! _scan_file "$f" 2>"$err_file"; then
    found=1
  fi
  n="$(sed -n 's/^#blocks \([0-9][0-9]*\)$/\1/p' "$err_file" | tail -1)"
  [[ -n "$n" ]] || n=0
  total_blocks=$((total_blocks + n))
done

if [[ "$found" -eq 1 ]]; then
  echo >&2
  echo "command-substitution-scan: argument-position command substitution(s) found in fenced bash blocks (issue #1314)." >&2
  echo "The worktree-isolation guard refuses a Bash call that passes \$(cmd) as an ARGUMENT:" >&2
  echo "  \"this command is too complex to verify that it stays inside the worktree;" >&2
  echo "   break it into plain, separate commands.\"" >&2
  echo "Hoist the substitution onto its own line and pass the variable unbraced:" >&2
  echo "  TOPLEVEL=\$(git rev-parse --show-toplevel)" >&2
  echo "  bash some-script.sh \"\$TOPLEVEL\"" >&2
  echo "Assignment RHS (VAR=\$(cmd)) and arithmetic (\$((expr))) are never flagged." >&2
  echo "See https://code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation for the convention." >&2
  exit 1
fi

# Anti-vacuity: a clean verdict is only meaningful if the fence matcher
# actually matched something. #1312 found the pre-existing preamble test had
# silently dropped to 0 blocks matched while still reporting success — a
# scanner that matches nothing must fail loudly rather than pass over an empty
# corpus. Only enforced on a DISCOVERY run; an explicit-path invocation may
# legitimately name a file with no bash fences at all.
if [[ $# -eq 0 && "$total_blocks" -eq 0 ]]; then
  echo "command-substitution-scan: scanned ${#candidates[@]} file(s) but matched ZERO fenced bash blocks — the fence matcher is broken, not the corpus clean." >&2
  exit 2
fi

echo "command-substitution-scan: ${#candidates[@]} file(s), $total_blocks fenced bash block(s) scanned; no argument-position command substitutions."
exit 0

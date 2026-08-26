#!/usr/bin/env bash
# brace-expansion-scan.sh — flag DECORATIVE braced parameter expansions
# (`${NAME}`) inside ```bash fenced blocks in the orchestrator + worker spec
# tree. The harness's worktree-isolation guard refuses any Bash call
# containing a braced expansion:
#
#   "This agent is isolated in the worktree <path>, but this command is too
#    complex to verify that it stays inside the worktree; break it into
#    plain, separate commands."
#
# Background (issues #1308 -> #1311): #1308 isolated the real trigger — a
# braced `${VAR}` parameter expansion, plus `$(cmd)` in ARGUMENT position —
# after four consecutive issues (#1182 statement count, #1277 compound
# shape, #1289 loop bodies, #1291 block length) each diagnosed a different
# wrong axis and shipped a locally-reasonable fix that left the braces
# untouched. #1308 swept all 246 `${CLAUDE_PLUGIN_ROOT}` occurrences to the
# unbraced spelling and enforced that ONE variable in
# `tests/claude-plugin-root-preamble.test.sh` (checks 3b + 3c). #1311 is the
# sweep of the remaining decorative occurrences across ~80 other variable
# names, and this scanner is its CI enforcement.
#
# See https://code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation
# for the harness's own documentation of this refusal (the controlled
# experiment that isolated the trigger and for the convention itself.
#
# WHAT IS FLAGGED — the closing-brace form only:
#
#   ${NAME}      where NAME is a plain identifier ([A-Za-z_][A-Za-z0-9_]*)
#                immediately followed by `}`.
#
# Bash terminates an unbraced name at the first non-identifier character, so
# `$VAR/path`, `"$VAR"`, and `$VAR ` are all unambiguous — the braces buy
# nothing and cost a refused tool call per affected block per session.
#
# WHAT IS NOT FLAGGED — deliberately, because these forms have no unbraced
# spelling and de-bracing them would change semantics:
#
#   ${VAR:-default}  ${VAR:=x}  ${VAR:?msg}  ${VAR:+x}   — modifier forms
#   ${#arr[@]}  ${arr[@]}  ${arr[0]}                     — length / subscript
#   ${VAR%.md}  ${VAR#prefix}  ${VAR//a/b}               — trim / substitute
#
# The pattern is anchored on `}` immediately after the identifier, so every
# one of those stays legal without needing an exemption. A block that
# genuinely needs one of them still cannot run post-relocation and must be
# decomposed or extracted to a script per `commands/do-work/dont.md` — a
# separate concern, guarded by #1277's compound-block-scan.sh.
#
# IDENTIFIER-ADJACENT occurrences (`${count}M`, `${VAR}_suffix`) DO match the
# closing-brace form and ARE flagged, because they read as decorative on
# sight while de-bracing them silently changes WHICH variable is expanded
# (`$countM` is a different, almost certainly unset, name). Flagging them is
# the point: the fix is to rewrite the site so no adjacency exists (fold the
# suffix into the variable's own value, or emit it as a separate word), NOT
# to blind-sweep the braces off.
#
# QUOTED-HEREDOC BODIES are skipped entirely. Inside `<<'EOF'` (or `<<"EOF"`)
# the text is emitted LITERALLY rather than expanded, so a `${VAR}` there is
# part of the emitted output — de-bracing it would silently change what the
# block writes or prints, not what the shell does. Unquoted heredocs
# (`<<EOF`) DO expand and are still checked.
#
# False-positive guard: an explicit `<!-- brace-expansion-scan: allow -->`
# line immediately before the opening fence skips that block entirely — for
# the rare case a block intentionally shows the refused shape as a documented
# bad example (e.g. a "here's what NOT to write" callout).
#
# SCOPE: mechanical discovery over every git-tracked `*.md` under `plugins/`.
#
# compound-block-scan.sh (#1277) walks a hand-curated FILES list because its
# corpus is genuinely mixed — pre-relocation blocks legitimately keep the
# compound preamble shape, so a blanket sweep there would false-positive.
# This scanner has no such split: #1311's sweep classified EVERY `${NAME}`
# occurrence in a `bash` fence across the whole plugin tree and drove the
# count to zero, so discovery can start where
# `shipyard-repo-root-preamble.test.sh` ended up (#1064 hardcoded array ->
# #1105 mechanical discovery) instead of working its way there file-by-file.
# Discovery is also what keeps the sweep from silently re-accumulating: a NEW
# spec file is covered the day it lands, with no scanner edit.
#
# Non-plugin markdown (repo-root README / CHANGELOG / CLAUDE.md) is out of
# scope — none of it is loaded into a worktree-isolated agent's context, so a
# braced expansion there costs nothing. Pass such a file explicitly if you
# want it checked anyway.
#
# Usage:
#   bash plugins/shipyard/scripts/brace-expansion-scan.sh            # discovered plugin *.md
#   bash plugins/shipyard/scripts/brace-expansion-scan.sh <path>...  # explicit files
#   bash plugins/shipyard/scripts/brace-expansion-scan.sh --list     # print discovered paths
#
# Exit status: 0 = clean, 1 = at least one finding (prints file:line + the
# offending expansion), 2 = usage / environment error.

set -u

usage() {
  cat >&2 <<'EOF'
usage: brace-expansion-scan.sh [--list] [path ...]
       brace-expansion-scan.sh --help
  With no args, scans every git-tracked *.md under plugins/ (see script
  header for scope rationale). With paths, scans exactly those files.
  --list prints the discovered paths (one per line) and exits 0.
  --help itself always exits 0, distinct from the usage/environment-error
  exit 2 below (#1550).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "brace-expansion-scan: not inside a git work tree" >&2
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
  echo "brace-expansion-scan: discovered zero files under plugins/ — the scanner is broken, not the corpus clean" >&2
  exit 2
fi

# _scan_file <path> — prints findings to stdout, one per line:
#   <path>:<line>: decorative-brace-expansion — ${NAME} (write it unbraced)
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

    BEGIN {
      SQ = sprintf("%c", 39)
      DQ = sprintf("%c", 34)
      SQ_HD_RE = "<<-?[[:space:]]*" SQ "[A-Za-z_][A-Za-z0-9_]*" SQ
      DQ_HD_RE = "<<-?[[:space:]]*" DQ "[A-Za-z_][A-Za-z0-9_]*" DQ
      BRACE_RE = "[$][{][A-Za-z_][A-Za-z0-9_]*[}]"
      in_block = 0
      in_heredoc = 0
      hd_tag = ""
      allow_this = 0
      pending_allow = 0
      found_any = 0
      blocks = 0
    }

    /^[[:space:]]*<!--[[:space:]]*brace-expansion-scan:[[:space:]]*allow[[:space:]]*-->[[:space:]]*$/ {
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

      if (!allow_this) {
        rest = line
        while (match(rest, BRACE_RE)) {
          hit = substr(rest, RSTART, RLENGTH)
          printf "%s:%d: decorative-brace-expansion — %s (write it unbraced)\n", FILE, NR, hit
          found_any = 1
          rest = substr(rest, RSTART + RLENGTH)
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
    echo "brace-expansion-scan: no such file: $f" >&2
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
  echo "brace-expansion-scan: decorative braced parameter expansion(s) found in fenced bash blocks (issue #1311)." >&2
  echo "The worktree-isolation guard refuses ANY Bash call containing a braced expansion:" >&2
  echo "  \"this command is too complex to verify that it stays inside the worktree;" >&2
  echo "   break it into plain, separate commands.\"" >&2
  echo "Write the expansion unbraced — \"\$VAR/path\", never \"\${VAR}/path\". Bash terminates an" >&2
  echo "unbraced name at the first non-identifier character, so the braces buy nothing." >&2
  echo "Modifier forms (\${VAR:-default}, \${#arr[@]}, \${VAR%.md}) are never flagged." >&2
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
  echo "brace-expansion-scan: scanned ${#candidates[@]} file(s) but matched ZERO fenced bash blocks — the fence matcher is broken, not the corpus clean." >&2
  exit 2
fi

echo "brace-expansion-scan: ${#candidates[@]} file(s), $total_blocks fenced bash block(s) scanned; no decorative braced expansions."
exit 0

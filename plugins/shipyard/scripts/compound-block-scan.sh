#!/usr/bin/env bash
# compound-block-scan.sh — flag post-relocation ```bash fenced blocks that
# contain a compound shell shape the harness's worktree-isolation guard is
# known to refuse: "this command is too complex to verify that it stays
# inside the worktree; break it into plain, separate commands."
#
# Background (issue #1277): #1181 established that the guard refuses
# compound shapes post-relocation and decomposed ONE call site (the
# `CLAUDE_PLUGIN_ROOT` preamble at setup step 0.3) into plain sequential
# commands, with an explicit "PRE-RELOCATION ONLY" callout. That fix was
# scoped to the preamble alone — every other post-relocation multi-statement
# block in the orchestrator spec is still templated the same refused way,
# and each orchestrator has to improvise its own split by hand, with no
# guarantee the improvisation preserves the block's semantics.
#
# What actually gets refused (per #1277's corroborated repro set) is NOT
# "more than one line in a fenced block" — plain sequential statements
# (`VAR=$(cmd)` / `export VAR` / `echo ...`) are exercised constantly
# throughout this spec with no reported refusal. What gets refused is a
# SINGLE shell construct whose effect the guard can't cheaply verify stays
# inside the worktree:
#
#   - a `for` / `while` loop wrapping `gh` / `git` calls
#   - a shell pipe (`|`, not `||`) spanning two distinct tool invocations
#     (`printf ... | some-script`, `git show ... | jq ...`)
#
# This scanner flags exactly those two shapes inside ```bash fenced blocks,
# in the spirit of `fence-balance-scan.sh` / `conflict-marker-scan.sh`: a
# cheap, deliberately narrow structural check, not a full shell parser.
#
# Scope (deliberately conservative, issue #1277). Unlike the fence-balance
# and conflict-marker scanners, this one does NOT sweep every tracked file
# by default — the corpus mixes pre-relocation and post-relocation content
# within single files (e.g. `setup/00-config-worktree.md`), and a blind
# repo-wide sweep would false-positive on pre-relocation blocks that
# legitimately keep the compound preamble shape. Instead it walks an
# explicit FILES list (below) of files that are either entirely
# post-relocation, or files this scanner has been deliberately verified
# clean of the false-positive risk. Extend FILES as more of the corpus gets
# swept and verified — same evolutionary path
# `shipyard-repo-root-preamble.test.sh` took (#1064 hardcoded array →
# #1105 mechanical discovery). A hardcoded, honestly-incomplete list beats
# a blanket sweep that either misses pre-relocation exclusions or drowns in
# false positives from jq-internal pipes.
#
# False-positive guards:
#   - Pipe detection strips single- and double-quoted spans from the block
#     BEFORE looking for a bare `|` — a `--jq '[.foo | .bar]'` filter's
#     internal pipe is quoted and never flagged. Quote-stripping runs over
#     the whole block (not line-by-line) because this corpus's `--jq '...'`
#     filters routinely span multiple physical lines before the closing
#     quote.
#   - `||` is never flagged as a pipe — only a single unpaired `|`.
#   - A `case ... in word|word) ... ;; esac` pattern's `|` alternation
#     operator is unquoted and would otherwise false-positive; lines that
#     look like a case-pattern arm (`^[[:space:]]*[A-Za-z0-9_]+(\|[A-Za-z0-9_]+)*\)`)
#     are excluded from the pipe check.
#   - An explicit `<!-- compound-block-scan: allow -->` line immediately
#     before the opening fence skips that block entirely — for the rare
#     case a block is intentionally showing the refused shape as a
#     documented bad example (e.g. inside this scanner's own regression
#     doc, or a "here's what NOT to write" callout).
#
# Usage:
#   bash plugins/shipyard/scripts/compound-block-scan.sh            # scan the built-in FILES list
#   bash plugins/shipyard/scripts/compound-block-scan.sh <path>...  # scan explicit files instead
#
# Exit status: 0 = no compound shapes found, 1 = at least one finding
# (prints file:line + shape + snippet), 2 = usage / environment error.

set -u

usage() {
  cat >&2 <<'EOF'
usage: compound-block-scan.sh [path ...]
  With no args, scans the built-in FILES list (see script header for scope
  rationale). With paths, scans exactly the given files instead.
EOF
  exit 2
}

case "${1:-}" in
  -h|--help) usage ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "compound-block-scan: not inside a git work tree" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"

# The curated, entirely-post-relocation-or-verified-clean file list. See the
# Scope note in the header for why this isn't a blanket repo sweep yet.
FILES=(
  "$repo_root/plugins/shipyard/commands/do-work/setup/04-backlog-divert.md"
)

if [[ $# -gt 0 ]]; then
  candidates=("$@")
else
  candidates=("${FILES[@]}")
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "compound-block-scan: no files to scan" >&2
  exit 0
fi

# _scan_file <path> — prints findings (if any) to stdout, one per line:
#   <path>:<fence-start-line>: <shape> — <one-line context>
# Returns 0 if clean, 1 if it found something.
_scan_file() {
  local file="$1"
  awk -v FILE="$file" '
    function is_case_arm_line(line,    stripped) {
      # Heuristic: a case-pattern arm looks like word-bar-word-bar-word then
      # a close paren (optionally indented), possibly using glob-class
      # syntax such as star-bang-bracket-zero-dash-nine-bracket-star. Such a
      # line legitimately carries an unquoted pipe character as the
      # pattern-alternation operator, not a shell pipe. A quote-stripped
      # empty alternative (an empty single-quoted string as the first
      # pattern arm) can leave the line starting with a bare pipe once the
      # empty string is stripped away — the character class below allows
      # that too, rather than requiring a leading word character.
      return (line ~ /^[[:space:]]*[]A-Za-z0-9_*!.,[-]*([|][]A-Za-z0-9_*!.,[-]*)*[)]/)
    }

    function is_case_construct_line(line) {
      # This corpus also writes a whole case statement compressed onto ONE
      # source line — `case "$X" in pattern) action ;; esac` — rather than
      # the pattern-arm-per-line style is_case_arm_line() targets. On such a
      # line the case-arm pattern is preceded by `case ... in` and followed
      # by `... esac`, so the is_case_arm_line start-anchored check never
      # matches even though the unquoted pipe is still a pattern-alternation
      # operator, not a shell pipe. Recognize the whole-line form directly:
      # a line that opens a case statement (`case <expr> in`) or closes one
      # (contains `esac` as a standalone word) is exempt from the pipe
      # check in its entirety.
      return (line ~ /(^|[^A-Za-z0-9_])case[[:space:]].*[[:space:]]in([[:space:]]|$)/ ||
              line ~ /(^|[^A-Za-z0-9_])esac([^A-Za-z0-9_]|$)/)
    }

    # strip_quotes(s) — remove single- and double-quoted spans AND `#`
    # comment spans from s, replacing each with nothing. Walks char-by-char;
    # handles \" escaping inside double quotes (bash single quotes have no
    # escape mechanism). Comments matter here: this corpus writes ordinary
    # English prose in bash `#` comments (contractions like "it is" / "the
    # repo is" / "main is"), and real bash treats a `#` comment as
    # quote-agnostic —
    # apostrophes inside it never open/close a shell string. Without an
    # explicit comment skip, an odd number of apostrophes in one comment
    # line flips in_s and silently swallows everything up to the NEXT
    # apostrophe anywhere later in the block (including real code on a
    # subsequent line) into the "quoted, ergo stripped" bucket — exactly the
    # false-negative this function exists to avoid producing.
    function strip_quotes(s,    i, c, n, out, in_s, in_d, in_c, prev) {
      out = ""; in_s = 0; in_d = 0; in_c = 0; prev = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (in_c) {
          if (c == "\n") { in_c = 0; out = out c }
          prev = c
          continue
        }
        if (in_s) {
          if (c == SQ) { in_s = 0 }
          prev = c
          continue
        }
        if (in_d) {
          if (c == DQ && prev != "\\") { in_d = 0 }
          prev = c
          continue
        }
        if (c == "#") { in_c = 1; prev = c; continue }
        if (c == SQ) { in_s = 1; prev = c; continue }
        if (c == DQ) { in_d = 1; prev = c; continue }
        out = out c
        prev = c
      }
      return out
    }

    BEGIN {
      SQ = sprintf("%c", 39)
      DQ = sprintf("%c", 34)
      in_block = 0
      pending_allow = 0
      found_any = 0
    }

    /^[[:space:]]*<!--[[:space:]]*compound-block-scan:[[:space:]]*allow[[:space:]]*-->[[:space:]]*$/ {
      pending_allow = 1
      next
    }

    /^[[:space:]]*```bash[[:space:]]*$/ {
      in_block = 1
      block_start = NR
      block_text = ""
      raw_first_line = ""
      allow_this = pending_allow
      pending_allow = 0
      next
    }

    /^[[:space:]]*```[[:space:]]*$/ {
      if (in_block) {
        in_block = 0
        if (!allow_this) {
          stripped = strip_quotes(block_text)

          # --- Loop check: for/while keyword + gh/git call in same block ---
          if ((stripped ~ /(^|[^A-Za-z0-9_])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]/ ||
               stripped ~ /(^|[^A-Za-z0-9_])while[[:space:]]*\[/ ||
               stripped ~ /(^|[^A-Za-z0-9_])while[[:space:]]+[A-Za-z]/) &&
              (stripped ~ /(^|[^A-Za-z0-9_])gh[[:space:]]/ || stripped ~ /(^|[^A-Za-z0-9_])git[[:space:]]/)) {
            printf "%s:%d: for/while-loop-wraps-gh-or-git — block starting here contains a for/while keyword and a gh/git invocation in the same fenced block\n", FILE, block_start
            found_any = 1
          }

          # --- Pipe check: bare `|` (not `||`, not a case-arm) outside quotes ---
          n = split(stripped, lines, "\n")
          for (li = 1; li <= n; li++) {
            ln = lines[li]
            if (is_case_arm_line(ln) || is_case_construct_line(ln)) continue
            # Replace every `||` with a placeholder so it cannot register as
            # a bare `|`, then look for a remaining `|`.
            tmp = ln
            gsub(/\|\|/, "\x01\x01", tmp)
            if (tmp ~ /\|/) {
              printf "%s:%d: unquoted-pipe — block starting here pipes across a shell command boundary outside any case arm\n", FILE, block_start
              found_any = 1
            }
          }
        }
        next
      }
    }

    in_block {
      block_text = block_text $0 "\n"
      next
    }

    END { exit (found_any ? 1 : 0) }
  ' "$file"
}

found=0
for f in "${candidates[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "compound-block-scan: no such file: $f" >&2
    exit 2
  fi
  if ! _scan_file "$f"; then
    found=1
  fi
done

if [[ "$found" -eq 1 ]]; then
  echo >&2
  echo "compound-block-scan: compound shell shape(s) found in post-relocation fenced bash blocks (issue #1277)." >&2
  echo "These are the shapes the worktree-isolation guard is known to refuse post-relocation:" >&2
  echo "  \"this command is too complex to verify that it stays inside the worktree;" >&2
  echo "   break it into plain, separate commands.\"" >&2
  echo "Decompose the flagged block into plain sequential commands, or extract it behind" >&2
  echo "a script (see plugins/shipyard/commands/do-work/dont.md's post-relocation compound-block" >&2
  echo "rule for both options and when to pick each)." >&2
  exit 1
fi

echo "compound-block-scan: all scanned file(s) are free of the known-refused compound shapes."
exit 0

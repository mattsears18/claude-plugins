#!/usr/bin/env bash
# spec-script-reference-scan.sh — assert that every repo script a SPEC tells a
# worker to run actually exists and is executable.
#
# Background (issue #1467): PR #1465 deleted
# `plugins/shipyard/scripts/assert-worktree-cwd.sh` and left two live
# invocations of it in `shipyard:worker-preamble`'s ALWAYS-LOADED `SKILL.md` —
# the step-0 cwd fail-fast and the mid-session cwd anchor. Every dispatched
# worker runs step 0 before anything else, so each one would have died on
# `No such file or directory` at its first command. All 164 bash suites passed
# with that defect in place; so did shellcheck and the anchor-link checker. It
# was found by hand, after merge, and fixed in PR #1466.
#
# Why every existing gate missed it:
#
#   anchor-links-866.test.sh      validates markdown LINKS; these were fenced
#                                 bash blocks
#   brace-expansion-scan.sh       scan fenced bash for SYNTAX SHAPES, never
#   command-substitution-scan.sh  for whether a referenced path exists
#   the linter itself             lints *.sh files; shell embedded in a .md
#                                 spec is not linted at all
#   spec-size-budget.test.sh      byte counts only
#
# Specs in this repo are EXECUTABLE-BY-PROXY: an agent reads a fenced block and
# runs it verbatim. A dangling script path in a spec is exactly as broken as a
# dangling import in source, and this scanner is what finally treats it that
# way.
#
# WHAT IS CHECKED — inside ```bash fenced blocks only, a token shaped like a
# repo script path:
#
#   $CLAUDE_PLUGIN_ROOT/scripts/foo.sh      -> plugins/shipyard/scripts/foo.sh
#   ${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh    -> plugins/shipyard/scripts/foo.sh
#   plugins/shipyard/scripts/foo.sh         -> plugins/shipyard/scripts/foo.sh
#   scripts/foo.sh                          -> plugins/shipyard/scripts/foo.sh
#
# The braced `${CLAUDE_PLUGIN_ROOT}` spelling is matched even though
# brace-expansion-scan.sh (#1311) independently bans it — the two gates are
# orthogonal, and this one must not go blind if a braced occurrence ever slips
# past the other.
#
# Each resolved path must satisfy BOTH:
#
#   1. It is tracked in the git index. An untracked file in one working tree
#      does not ship to a plugin install, so "exists on my disk" is not the bar.
#   2. Its index mode is 100755 — the git exec bit. #1395 established that a
#      worker adding a script must record the bit with
#      `git update-index --chmod=+x`; a spec that references a script which
#      exists but is not executable fails at runtime the same way a dangling
#      one does. `script-exec-bits.test.sh` asserts the bit on every script
#      that EXISTS; this asserts it on every script a spec REFERENCES, which is
#      the intersection a worker actually runs.
#
# WHAT IS NOT CHECKED — deliberately:
#
#   - Prose, tables, and non-bash fences. This corpus discusses script paths
#     constantly in markdown links, and `anchor-links-866.test.sh` already
#     validates those. Only bash fences are executable-by-proxy.
#   - Placeholder paths (`$CLAUDE_PLUGIN_ROOT/scripts/<name>.sh`,
#     `scripts/*.sh`). `<`, `>`, and `*` are outside the path character class,
#     so a placeholder never forms a match in the first place.
#   - Non-`.sh` executables. `.mjs` / `.py` helpers exist under `scripts/` but
#     are invoked through a runtime (`node`, `python3`) rather than directly,
#     so the exec-bit half of the assertion does not apply to them. Extending
#     coverage there is a separate change.
#
# False-positive guard: an explicit `<!-- spec-script-reference-scan: allow -->`
# line immediately before the opening fence skips that block entirely. It
# exists for a block whose `scripts/...` token names a path in the AUDITED
# repo rather than in shipyard (`skills/dx-catalog/SKILL.md`'s setup-script
# probe is the live example), or for illustrative prose in a RATIONALE file
# that deliberately names something nonexistent.
#
# SCOPE: mechanical discovery over every git-tracked `*.md` under
# `plugins/shipyard/`. Scoped to this plugin rather than all of `plugins/`
# (which is what brace-expansion-scan.sh walks) because the resolution table
# above is shipyard-specific — `$CLAUDE_PLUGIN_ROOT` in a hypothetical second
# plugin's markdown would resolve somewhere else entirely.
#
# Usage:
#   bash plugins/shipyard/scripts/spec-script-reference-scan.sh            # discovered
#   bash plugins/shipyard/scripts/spec-script-reference-scan.sh <path>...  # explicit files
#   bash plugins/shipyard/scripts/spec-script-reference-scan.sh --list     # print discovered paths
#
# Exit status: 0 = clean, 1 = at least one dangling / non-executable reference
# (prints file:line + the offending token), 2 = usage / environment error /
# anti-vacuity trip.

set -u

# Anti-vacuity floors. A discovery run that matches nothing is a BROKEN
# scanner, not a clean corpus — the exact trap #1312 closed for
# brace-expansion-scan.sh, where a fence matcher had silently dropped to zero
# blocks while still reporting success. Observed at #1467's fix time: 601
# fenced bash blocks, 265 script references. The floors sit well below both so
# ordinary spec churn never trips them, but a matcher that breaks outright
# cannot pass clean. Enforced ONLY on a discovery run — an explicit-path
# invocation may legitimately name a file with no bash fences at all.
BLOCK_FLOOR=300
REF_FLOOR=150

usage() {
  cat >&2 <<'EOF'
usage: spec-script-reference-scan.sh [--list] [path ...]
  With no args, scans every git-tracked *.md under plugins/shipyard/ (see
  script header for scope rationale). With paths, scans exactly those files.
  --list prints the discovered paths (one per line) and exits 0.
EOF
  exit 2
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "spec-script-reference-scan: not inside a git work tree" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"

# Mechanical discovery — every git-tracked *.md under plugins/shipyard/.
# `git ls-files` (rather than `find`) so untracked scratch files and anything
# gitignored can never enter the corpus.
discover() {
  local rel
  while IFS= read -r -d '' rel; do
    printf '%s\0' "$repo_root/$rel"
  done < <(git -C "$repo_root" ls-files -z -- 'plugins/shipyard/*.md')
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
  echo "spec-script-reference-scan: discovered zero files under plugins/shipyard/ — the scanner is broken, not the corpus clean" >&2
  exit 2
fi

map_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$map_file" "$err_file"' EXIT

# path<TAB>mode for every git-tracked file under plugins/shipyard/.
# `git ls-files -s` emits "<mode> <object> <stage>\t<path>". Reformatted with
# awk rather than sed because BSD sed (macOS) does not understand `\t` in a
# regex, and this script must behave identically locally and in CI.
git -C "$repo_root" ls-files -s -- 'plugins/shipyard/*' \
  | awk -F'\t' 'NF > 1 { split($1, meta, " "); print $2 "\t" meta[1] }' > "$map_file"

if [[ ! -s "$map_file" ]]; then
  echo "spec-script-reference-scan: git index lookup returned zero tracked files under plugins/shipyard/ — the scanner is broken, not the corpus clean" >&2
  exit 2
fi

# _scan_file <path> — prints findings to stdout, one per line:
#   <path>:<line>: <verdict> — <token> (resolved: <repo-relative path> — why)
# Prints trailing `#blocks <n>` / `#refs <n>` lines to STDERR so the caller can
# total what was actually inspected (the anti-vacuity signal).
# Returns 0 if clean, 1 if it found something.
_scan_file() {
  local file="$1"
  awk -v FILE="$file" -v MAPFILE="$map_file" '
    # is_tail(tok, prev) — 1 when this match is really the TAIL of a longer
    # token rather than a reference in its own right. The rule is per-form:
    #
    #   $CLAUDE_PLUGIN_ROOT/... — a `$` cannot continue a preceding path, so
    #     only an identifier character before it means mid-token.
    #   plugins/shipyard/...    — `/plugins/shipyard/scripts/x.sh` (rooted off
    #     some other variable) IS a shipyard path and stays in scope; a leading
    #     `.` (`../plugins/...`, relative to an unknown cwd) or an identifier
    #     char (`myplugins/...`) means it is not.
    #   scripts/...             — the ambiguous one. Anything path-ish before
    #     it (`../../scripts/x.sh`, `$OTHER_ROOT/scripts/x.sh`) means the token
    #     is rooted somewhere this scanner cannot resolve, so it is skipped
    #     rather than guessed at.
    function is_tail(tok, prev,   c) {
      if (prev == "") return 0
      c = substr(tok, 1, 1)
      if (c == "$") return (prev ~ IDENT_RE)
      if (substr(tok, 1, 8) == "plugins/") return (prev ~ IDENT_RE || prev == ".")
      return (prev ~ BARE_TAIL_RE)
    }

    function resolve(t,   tail, p) {
      # Strip the prefix and re-root everything at the plugin directory.
      if (substr(t, 1, 21) == "${CLAUDE_PLUGIN_ROOT}") {
        tail = substr(t, 22)
      } else if (substr(t, 1, 19) == "$CLAUDE_PLUGIN_ROOT") {
        tail = substr(t, 20)
      } else if (substr(t, 1, 16) == "plugins/shipyard") {
        tail = substr(t, 17)
      } else {
        tail = "/" t
      }
      p = "plugins/shipyard" tail
      gsub("//+", "/", p)
      return p
    }

    BEGIN {
      while ((getline maprow < MAPFILE) > 0) {
        sep = index(maprow, "\t")
        if (sep > 0) MODE[substr(maprow, 1, sep - 1)] = substr(maprow, sep + 1)
      }
      close(MAPFILE)

      # Leftmost-longest alternation. In a fully-qualified token the
      # `plugins/shipyard` prefix starts earlier in the line than the inner
      # `scripts/`, so awk matches the longer, correct prefix; consuming the
      # matched substring below prevents the inner form from re-matching.
      REF_RE = "([$]CLAUDE_PLUGIN_ROOT|[$][{]CLAUDE_PLUGIN_ROOT[}]|plugins/shipyard|scripts)/[A-Za-z0-9_./-]*[.]sh"
      # Boundary guards, per matched form — see is_tail() for why the bare
      # `scripts/` form needs the stricter one.
      IDENT_RE = "[A-Za-z0-9_-]"
      BARE_TAIL_RE = "[A-Za-z0-9_./$}-]"
      in_block = 0
      allow_this = 0
      pending_allow = 0
      found_any = 0
      blocks = 0
      refs = 0
    }

    /^[[:space:]]*<!--[[:space:]]*spec-script-reference-scan:[[:space:]]*allow[[:space:]]*-->[[:space:]]*$/ {
      pending_allow = 1
      next
    }

    !in_block && /^[[:space:]]*```bash[[:space:]]*$/ {
      in_block = 1
      allow_this = pending_allow
      pending_allow = 0
      blocks++
      next
    }

    in_block && /^[[:space:]]*```[[:space:]]*$/ {
      in_block = 0
      next
    }

    in_block && !allow_this {
      rest = $0
      consumed = 0
      while (match(rest, REF_RE)) {
        tok = substr(rest, RSTART, RLENGTH)
        if (RSTART > 1) {
          prev = substr(rest, RSTART - 1, 1)
        } else if (consumed > 0) {
          # Start of a suffix produced by a previous match — the real
          # preceding character is that match final "h", so this is mid-token.
          prev = "h"
        } else {
          prev = ""
        }

        if (!is_tail(tok, prev)) {
          refs++
          rel = resolve(tok)
          if (!(rel in MODE)) {
            printf "%s:%d: dangling-script-reference — %s (resolved: %s — not tracked in the git index)\n", FILE, NR, tok, rel
            found_any = 1
          } else if (MODE[rel] != "100755") {
            printf "%s:%d: non-executable-script-reference — %s (resolved: %s — git index mode %s, expected 100755)\n", FILE, NR, tok, rel, MODE[rel]
            found_any = 1
          }
        }

        consumed += RSTART + RLENGTH - 1
        rest = substr(rest, RSTART + RLENGTH)
      }
      next
    }

    END {
      printf "#blocks %d\n", blocks > "/dev/stderr"
      printf "#refs %d\n", refs > "/dev/stderr"
      exit (found_any ? 1 : 0)
    }
  ' "$file"
}

found=0
total_blocks=0
total_refs=0

for f in "${candidates[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "spec-script-reference-scan: no such file: $f" >&2
    exit 2
  fi
  if ! _scan_file "$f" 2>"$err_file"; then
    found=1
  fi
  nb="$(sed -n 's/^#blocks \([0-9][0-9]*\)$/\1/p' "$err_file" | tail -1)"
  nr="$(sed -n 's/^#refs \([0-9][0-9]*\)$/\1/p' "$err_file" | tail -1)"
  [[ -n "$nb" ]] || nb=0
  [[ -n "$nr" ]] || nr=0
  total_blocks=$((total_blocks + nb))
  total_refs=$((total_refs + nr))
done

if [[ "$found" -eq 1 ]]; then
  echo >&2
  echo "spec-script-reference-scan: a fenced bash block names a repo script that does not resolve (issue #1467)." >&2
  echo "Specs in this repo are executable-by-proxy — an agent reads a fenced block and runs it" >&2
  echo "verbatim, so a dangling script path is as broken as a dangling import in source." >&2
  echo "Fix by one of:" >&2
  echo "  * restoring / renaming the script so the referenced path resolves;" >&2
  echo "  * updating the spec to name the script's real current path;" >&2
  echo "  * recording the git exec bit — git update-index --chmod=+x <path> (#1395)," >&2
  echo "    then confirming with git ls-files -s <path> (expect mode 100755);" >&2
  echo "  * marking the block with an allow directive on the line immediately before its" >&2
  echo "    opening fence, when the path deliberately names something outside this repo" >&2
  echo "    (e.g. a probe against the AUDITED repo rather than against shipyard)." >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  # Anti-vacuity. A clean verdict is only meaningful if the matchers actually
  # matched. See the floor constants at the top for the observed baseline.
  if [[ "$total_blocks" -lt "$BLOCK_FLOOR" ]]; then
    echo "spec-script-reference-scan: scanned ${#candidates[@]} file(s) but matched only $total_blocks fenced bash block(s) — below the $BLOCK_FLOOR floor; the fence matcher is broken, not the corpus clean (#1312)." >&2
    exit 2
  fi
  if [[ "$total_refs" -lt "$REF_FLOOR" ]]; then
    echo "spec-script-reference-scan: walked $total_blocks fenced bash block(s) but extracted only $total_refs script reference(s) — below the $REF_FLOOR floor; the reference matcher is broken, not the corpus clean (#1312)." >&2
    exit 2
  fi
fi

echo "spec-script-reference-scan: ${#candidates[@]} file(s), $total_blocks fenced bash block(s), $total_refs script reference(s) checked; every reference resolves and is executable."
exit 0

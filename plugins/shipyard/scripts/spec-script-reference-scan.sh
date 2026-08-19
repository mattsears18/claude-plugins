#!/usr/bin/env bash
# spec-script-reference-scan.sh — assert that every repo path a SPEC names
# inside a fenced bash block actually resolves: a script must exist and be
# executable, a markdown fragment must exist.
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
# ---------------------------------------------------------------------------
# SECOND REFERENCE CLASS — markdown fragments (issue #1468)
# ---------------------------------------------------------------------------
#
# The same seam exists one file-type over. A fenced bash block that names a
# SPEC FRAGMENT — `git show origin/main:plugins/shipyard/commands/do-work/dont.md`,
# `cat "$CLAUDE_PLUGIN_ROOT/skills/worker-preamble/<frag>.md"` — is
# executable-by-proxy in exactly the same way, and dies at runtime in exactly
# the same way once that fragment is renamed or deleted.
# `anchor-links-866.test.sh` validates markdown LINKS; a path written inside a
# ```bash fence is not a link, which is the same blind spot #1467 closed for
# scripts.
#
# WHAT IS CHECKED — inside ```bash fenced blocks only, a token ending in `.md`
# that contains at least one `/`:
#
#   $CLAUDE_PLUGIN_ROOT/commands/x.md    -> plugins/shipyard/commands/x.md
#   ${CLAUDE_PLUGIN_ROOT}/commands/x.md  -> plugins/shipyard/commands/x.md
#   plugins/shipyard/commands/x.md       -> plugins/shipyard/commands/x.md
#   $ANY_ROOT/plugins/shipyard/x.md      -> plugins/shipyard/x.md
#   ./sibling.md  ../up.md               -> normalized against the CITING
#                                           file's own directory
#   bare a/b.md                          -> accepted when it resolves against
#                                           the CITING file's directory OR
#                                           against plugins/shipyard/
#
# The resolution table deliberately DIFFERS from the script one, which is why
# #1468 treated this as a separate class rather than reusing resolve(). A
# script reference is always rooted at `$CLAUDE_PLUGIN_ROOT`; a fragment
# reference is usually written relative to the file citing it. BOTH roots occur
# live in this corpus — `commands/do-work/setup/04b-untrusted-author-handoff.md`
# cites `./01b-backlog-overview.md` (citing-file-relative) while
# `commands/do-work/drain.md` cites `skills/worker-preamble/ci-pitfalls.md`
# (plugin-root-relative) — so a bare relative token is accepted when EITHER
# root resolves. That is not matcher-loosening to turn a finding green: both
# are resolution rules a reading agent genuinely applies, and a deleted
# fragment resolves under NEITHER, which is precisely the failure this class
# exists to catch.
#
# Only existence in the git index is asserted, never a mode bit — a markdown
# fragment is read, never executed.
#
# WHAT IS NOT CHECKED for fragments — deliberately, each forced by a live
# false positive observed while establishing #1468's baseline:
#
#   - A bare FILENAME with no `/` (`setup.md`, `investigate.md`, `drain.md`).
#     Every one of these in the corpus is prose inside a fenced COMMENT ("see
#     04d-investigate-routing.md § Label ..."), names no directory, and so has
#     no resolution rule at all. Guessing a root false-positives immediately:
#     `setup/01c-label-recovery-refine.md` mentions `investigate.md`, which
#     lives at `agents/issue-worker/investigate.md` — nowhere near the citing
#     file, and nowhere near the plugin root either.
#   - A token rooted at a variable OTHER than `$CLAUDE_PLUGIN_ROOT` that
#     carries no `plugins/shipyard/` anchor — `$WORKTREE_PATH/.shipyard-scratch/
#     pr-body.md`, `$SCRATCH_ROOT/.shipyard-scratch/issue-body.md`. These name
#     scratch files a spec tells a worker to CREATE, and their root is
#     unresolvable from here. Same posture as a bare `scripts/` token rooted
#     off an unknown variable in the script class: skipped, not guessed at.
#   - Placeholders and globs, for the same character-class reason as scripts.
#
# ---------------------------------------------------------------------------
#
# False-positive guard: an explicit `<!-- spec-script-reference-scan: allow -->`
# line immediately before the opening fence skips that block entirely, for BOTH
# classes. It exists for a block whose `scripts/...` or `<dir>/<file>.md` token
# names a path in the AUDITED repo rather than in shipyard — `dx-catalog`'s
# setup-script and `CONTRIBUTING.md` / `.github/PULL_REQUEST_TEMPLATE.md` /
# `.claude/CLAUDE.md` probes, `marketing-auditor`'s `docs/BRAND.md` probe, and
# `comprehension-auditor`'s `docs/COMPREHENSION.md` probe are the live examples
# — or for illustrative prose in a RATIONALE file that deliberately names
# something nonexistent. The directive name is kept verbatim from #1467 rather
# than renamed per-class: one fence traversal, one directive, and the single
# pre-existing use keeps working unchanged.
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
#
# EVERY REFERENCE CLASS CARRIES ITS OWN FLOOR (#1467 established this for the
# ref matcher, #1468 extends the rule). A broken fragment matcher is exactly as
# silent as a broken script matcher, and neither the block floor nor the script
# floor would notice it drop to zero — each class is an independent matcher and
# needs an independent liveness assertion.
#
# FRAG_FLOOR is much lower than REF_FLOOR because the class genuinely is much
# smaller: the #1468 baseline measured 8 in-scope fragment references across
# the whole corpus (against 601 blocks / 267 script references). The corpus
# holds 85 raw `.md` tokens inside bash fences; the other 77 are bare filenames
# in comments, `$WORKTREE_PATH`-rooted scratch writes, or audited-repo probes —
# all three skipped or allow-directived by design (see the header). A floor of
# 5 keeps headroom for ordinary spec churn while still failing loudly on a
# matcher that breaks outright.
BLOCK_FLOOR=300
REF_FLOOR=150
FRAG_FLOOR=5

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

# _repo_rel_dir <path> — the repo-relative directory holding <path>, or the
# empty string when <path> lives outside the repo (an explicit-path invocation
# may legitimately name a fixture in /tmp). Used as the CITING-file root for
# the fragment class, which — unlike the script class — resolves relative
# paths against the file doing the citing.
_repo_rel_dir() {
  local abs
  # `pwd -P` (physical), not the logical default: `git rev-parse
  # --show-toplevel` reports a symlink-resolved path, and on macOS a repo under
  # `mktemp -d` sits at /var/... logically but /private/var/... physically.
  # Comparing a logical path against a physical repo_root silently yields "no
  # citing directory", which downgrades every relative fragment to a
  # false-positive finding.
  abs="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || { printf ''; return 0; }
  case "$abs" in
    "$repo_root") printf '' ;;
    "$repo_root"/*) printf '%s' "${abs#"$repo_root"/}" ;;
    *) printf '' ;;
  esac
}

# _scan_file <path> — prints findings to stdout, one per line:
#   <path>:<line>: <verdict> — <token> (resolved: <repo-relative path> — why)
# Prints trailing `#blocks <n>` / `#refs <n>` / `#frags <n>` lines to STDERR so
# the caller can total what was actually inspected (the anti-vacuity signal).
# Returns 0 if clean, 1 if it found something.
_scan_file() {
  local file="$1"
  local filedir
  filedir="$(_repo_rel_dir "$file")"
  awk -v FILE="$file" -v MAPFILE="$map_file" -v FILEDIR="$filedir" '
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

    # norm(p) — collapse `//`, `.` and `..` segments in a repo-relative path.
    # Returns "" when the path climbs above the repo root, which is itself an
    # unresolvable reference rather than a silent pass.
    function norm(p,   n, i, parts, stack, top, res) {
      gsub("//+", "/", p)
      n = split(p, parts, "/")
      top = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == "..") {
          if (top == 0) return ""
          top--
          continue
        }
        stack[++top] = parts[i]
      }
      res = ""
      for (i = 1; i <= top; i++) res = (i == 1) ? stack[i] : res "/" stack[i]
      return res
    }

    # frag_resolve(tok, prev) — the repo-relative path a markdown-fragment
    # token names, or "" when the token is not resolvable and must be SKIPPED
    # rather than guessed at. Sets the global FRAG_ALT to a second candidate
    # for the one genuinely ambiguous form (a bare relative path, which may be
    # rooted at either the citing file or the plugin); the caller accepts the
    # token when EITHER resolves. See the script header for why both roots are
    # legitimate and why accepting either is not matcher-loosening.
    function frag_resolve(tok, prev,   i, pre) {
      FRAG_ALT = ""

      if (substr(tok, 1, 21) == "${CLAUDE_PLUGIN_ROOT}") {
        if (prev ~ IDENT_RE) return ""
        return norm("plugins/shipyard/" substr(tok, 22))
      }
      if (substr(tok, 1, 19) == "$CLAUDE_PLUGIN_ROOT") {
        if (prev ~ IDENT_RE) return ""
        return norm("plugins/shipyard/" substr(tok, 20))
      }

      # A `plugins/shipyard/` anchor ANYWHERE in the token roots it
      # unambiguously, whatever precedes it ($PRIMARY_ROOT/..., an absolute
      # path). Guarded so `myplugins/shipyard/...` cannot masquerade as one.
      i = index(tok, "plugins/shipyard/")
      if (i > 0) {
        if (i == 1) {
          # Same rule is_tail() applies to the script class `plugins/` form:
          # a leading `.` (`../plugins/...`, relative to an unknown cwd) or an
          # identifier char (`myplugins/...`) means this is not our path.
          # Anything else — a quote, a space, a `:` after `git show <ref>` —
          # leaves the token rooted at the repo root, which is what we want.
          if (prev ~ IDENT_RE || prev == ".") return ""
          return norm(tok)
        }
        pre = substr(tok, i - 1, 1)
        if (pre == "/") return norm(substr(tok, i))
        return ""
      }

      # Rooted at a variable this scanner cannot resolve ($WORKTREE_PATH/...,
      # ${SCRATCH_ROOT}/...). Skipped, never guessed at.
      if (prev == "$" || prev == "}") return ""

      # A bare filename names no directory and therefore has no resolution
      # rule — in this corpus it is always prose inside a fenced comment.
      if (index(tok, "/") == 0) return ""

      # Mid-token: the real reference started earlier in the line.
      if (prev ~ FRAG_TAIL_RE) return ""

      # Explicitly relative — citing-file-rooted, no second candidate.
      if (substr(tok, 1, 2) == "./" || substr(tok, 1, 3) == "../") {
        return norm(FILEDIR "/" tok)
      }

      # Bare relative — genuinely ambiguous, so try both live roots.
      FRAG_ALT = norm("plugins/shipyard/" tok)
      return norm(FILEDIR "/" tok)
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
      # Fragment class (#1468). The optional `$CLAUDE_PLUGIN_ROOT` prefix keeps
      # the `$` inside the match so frag_resolve() can tell that form apart
      # from a token merely PRECEDED by some other `$VAR`; everything else is
      # an ordinary path run ending in `.md`. `<`, `>` and `*` are outside the
      # class, so placeholders and globs never form a match — same property the
      # script class relies on.
      FRAG_RE = "([$][{]?CLAUDE_PLUGIN_ROOT[}]?)?[A-Za-z0-9_./-]*[.]md"
      # Boundary guards, per matched form — see is_tail() for why the bare
      # `scripts/` form needs the stricter one. FRAG_TAIL_RE is the fragment
      # class equivalent: anything path-ish before a bare relative token means
      # the token is rooted somewhere this scanner cannot resolve.
      IDENT_RE = "[A-Za-z0-9_-]"
      BARE_TAIL_RE = "[A-Za-z0-9_./$}-]"
      FRAG_TAIL_RE = "[A-Za-z0-9_./$}-]"
      in_block = 0
      allow_this = 0
      pending_allow = 0
      found_any = 0
      blocks = 0
      refs = 0
      frags = 0
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

      # Second pass over the same line for the markdown-fragment class
      # (#1468). Kept as a separate walk rather than folded into the loop
      # above: the two classes share the fence traversal and the allow
      # directive, but nothing else — different token shape, different
      # resolution table, different assertion (existence only, no mode bit).
      rest = $0
      consumed = 0
      while (match(rest, FRAG_RE)) {
        tok = substr(rest, RSTART, RLENGTH)
        if (RSTART > 1) {
          prev = substr(rest, RSTART - 1, 1)
        } else if (consumed > 0) {
          # Start of a suffix left by a previous match — the real preceding
          # character is that match final "d", so this is mid-token.
          prev = "d"
        } else {
          prev = ""
        }

        rel = frag_resolve(tok, prev)
        if (rel != "") {
          frags++
          if (!(rel in MODE) && !(FRAG_ALT != "" && FRAG_ALT in MODE)) {
            if (FRAG_ALT != "" && FRAG_ALT != rel) {
              printf "%s:%d: dangling-fragment-reference — %s (resolved: %s or %s — neither is tracked in the git index)\n", FILE, NR, tok, rel, FRAG_ALT
            } else {
              printf "%s:%d: dangling-fragment-reference — %s (resolved: %s — not tracked in the git index)\n", FILE, NR, tok, rel
            }
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
      printf "#frags %d\n", frags > "/dev/stderr"
      exit (found_any ? 1 : 0)
    }
  ' "$file"
}

found=0
total_blocks=0
total_refs=0
total_frags=0

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
  nf="$(sed -n 's/^#frags \([0-9][0-9]*\)$/\1/p' "$err_file" | tail -1)"
  [[ -n "$nb" ]] || nb=0
  [[ -n "$nr" ]] || nr=0
  [[ -n "$nf" ]] || nf=0
  total_blocks=$((total_blocks + nb))
  total_refs=$((total_refs + nr))
  total_frags=$((total_frags + nf))
done

if [[ "$found" -eq 1 ]]; then
  echo >&2
  echo "spec-script-reference-scan: a fenced bash block names a repo path that does not resolve" >&2
  echo "(scripts: issue #1467; markdown fragments: issue #1468)." >&2
  echo "Specs in this repo are executable-by-proxy — an agent reads a fenced block and runs it" >&2
  echo "verbatim, so a dangling path is as broken as a dangling import in source." >&2
  echo "Fix by one of:" >&2
  echo "  * restoring / renaming the script or fragment so the referenced path resolves;" >&2
  echo "  * updating the spec to name the file's real current path;" >&2
  echo "  * recording the git exec bit — git update-index --chmod=+x <path> (#1395)," >&2
  echo "    then confirming with git ls-files -s <path> (expect mode 100755);" >&2
  echo "  * marking the block with an allow directive on the line immediately before its" >&2
  echo "    opening fence, when the path deliberately names something outside this repo" >&2
  echo "    (e.g. a probe against the AUDITED repo rather than against shipyard)." >&2
  echo "Do NOT loosen a matcher to turn a finding green — that is the failure mode this gate exists" >&2
  echo "to prevent. Either the reference is real and needs fixing, or it is illustrative and needs" >&2
  echo "a deliberate, documented allow directive." >&2
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
  if [[ "$total_frags" -lt "$FRAG_FLOOR" ]]; then
    echo "spec-script-reference-scan: walked $total_blocks fenced bash block(s) but extracted only $total_frags fragment reference(s) — below the $FRAG_FLOOR floor; the fragment matcher is broken, not the corpus clean (#1468)." >&2
    exit 2
  fi
fi

echo "spec-script-reference-scan: ${#candidates[@]} file(s), $total_blocks fenced bash block(s), $total_refs script reference(s) + $total_frags fragment reference(s) checked; every reference resolves (and every script is executable)."
exit 0

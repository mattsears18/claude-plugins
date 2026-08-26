#!/usr/bin/env bash
# setup-fragment-content-scan.sh — flag a test-tree content-read (grep / cat /
# the local assert_contains helper) whose target is a HARDCODED single
# `setup/<NN><letter>-<name>.md` router-fragment path, rather than something
# resolved through `setup.md`'s routing table or found by scanning across
# every `setup/*.md` file.
#
# Background (issue #1453): the router/fragment pattern (#611 / #994 / #1233)
# exists so a step's full content can move to a new fragment file once its
# parent crosses the token-budget cap — and shipyard now does this routinely
# (four splits in two sessions at filing time). A test that greps a SPECIFIC
# hardcoded fragment path for a piece of step content has baked in a belief
# about WHERE that content lives; the next split that moves it breaks the
# test in CI, after push, with no way for the dispatching worker to have
# known which suite to check locally.
#
# The concrete repro: PR #1447 split `setup/00-config-worktree.md`, moving
# step 0.56's `.shipyard-primary-root` documentation into a new
# `setup/00k-repo-root-pin.md` fragment.
# `scripts/tests/shipyard-repo-root-preamble.test.sh` check (4) had hardcoded
# `setup/00-config-worktree.md` as the origin file and broke in CI even
# though four OTHER locally-run suites were green. The fix-checks worker's
# remediation — loop across `setup/*.md` to find whichever file documents
# step 0.56 — is the pattern this scanner enforces going forward.
#
# WHAT IS FLAGGED — a content-read command (`grep`, `cat`, or this
# codebase's own `assert_contains` test helper) whose file target is either:
#
#   (a) a bash VARIABLE previously assigned a full path containing
#       `do-work/setup/<NN><letter>-<name>.md` (the shape every real
#       assignment in this corpus uses — e.g.
#       `SETUP_MD="$repo_root/plugins/shipyard/commands/do-work/setup/01-repo-recovery.md"`),
#   (b) a LITERAL string containing that same full-path shape directly on
#       the content-read line.
#
# Detection is a single-pass-per-command-family regex match against the
# tracked variable name or the literal path shape — not full shell parsing.
# In the spirit of `fence-balance-scan.sh` / `conflict-marker-scan.sh`: a
# cheap, deliberately narrow structural check.
#
# WHAT IS NOT FLAGGED — deliberately:
#
#   - `assert_file_exists "$VAR"` / `[[ -f "$VAR" ]]` — an EXISTENCE check
#     has no content-relocation risk; the file itself isn't going anywhere
#     even when a step's content inside it moves elsewhere. These commands
#     never match the `grep`/`cat`/`assert_contains` name check, so they are
#     naturally excluded.
#   - A bare `setup/<NN><letter>-<name>.md` mention that is NOT part of a
#     full `do-work/setup/...` path — this is the router-table's own
#     short-form label (`[\`setup/04f-completion-ledger.md\`](...)`), used
#     as a NEEDLE to assert the router table lists a given fragment file
#     (e.g. `assert_contains "$setup_router_path" "setup/04f-completion-ledger.md"`).
#     That is exactly the sanctioned "resolve through the router" pattern —
#     flagging it would be the opposite of what this scanner exists to
#     encourage. Detection requires the `do-work/setup/` prefix, which only
#     a REAL FILESYSTEM PATH carries.
#   - A `cat A B > C` (or similar) fixture-building line that concatenates
#     the router PLUS every fragment (`"$dir"/*.md`) into one scratch file
#     before grepping — already the router-safe pattern (several suites in
#     this corpus already do this). The presence of `>` (writing OUTPUT, not
#     reading content INTO the test) on a `cat` line exempts it.
#   - Comments and prose (`grep -n 'setup/...' <<'EOF'`-style code fixtures
#     aside) — the two content-read command names are specific enough that
#     ordinary discussion of a fragment's history/rationale never matches.
#
# OPT-OUT MARKERS (mirrors conflict-marker-scan.sh's self-excluded fixture):
#
#   - `# setup-fragment-content-scan: allow` on the flagged line itself, OR
#     on the line immediately before it — for a genuine, deliberate,
#     single-site exception.
#   - `# setup-fragment-content-scan: allow-file` anywhere in the file —
#     exempts the WHOLE file. Reserved for suites whose entire purpose IS a
#     structural assertion about one exact, deliberately-named file (a
#     rename/split regression test named after its own issue number, or a
#     suite asserting the router table's OWN shape) — see
#     `agents/issue-worker/issue-work.md`'s design-guidance citation of the
#     `compound-block-scan.sh` curated-file-list precedent for why a handful
#     of files are better exempted wholesale, visibly, than annotated line by
#     line.
#
# SCOPE: mechanical discovery over every git-tracked `*.test.sh` under
# `plugins/shipyard/scripts/tests/` — a new suite is covered the day it
# lands, with no scanner edit, so the corpus can't silently re-accumulate the
# way a hand-curated list would.
#
# Usage:
#   bash plugins/shipyard/scripts/setup-fragment-content-scan.sh            # discovered *.test.sh
#   bash plugins/shipyard/scripts/setup-fragment-content-scan.sh <path>...  # explicit files
#   bash plugins/shipyard/scripts/setup-fragment-content-scan.sh --list     # print discovered paths
#
# Exit status: 0 = clean, 1 = at least one finding (prints file:line + the
# offending target), 2 = usage / environment / discovery error.

set -u

usage() {
  cat >&2 <<'EOF'
usage: setup-fragment-content-scan.sh [--list] [path ...]
  With no args, scans every git-tracked *.test.sh under
  plugins/shipyard/scripts/tests/ (see script header for scope rationale).
  With paths, scans exactly those files. --list prints the discovered paths
  (one per line) and exits 0.
  --help itself always exits 0, distinct from the usage/environment/
  discovery-error exit 2 (#1550).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "setup-fragment-content-scan: not inside a git work tree" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"

discover() {
  local rel
  while IFS= read -r -d '' rel; do
    printf '%s\0' "$repo_root/$rel"
  done < <(git -C "$repo_root" ls-files -z -- 'plugins/shipyard/scripts/tests/*.test.sh')
}

if [[ "${1:-}" == "--list" ]]; then
  discover | tr '\0' '\n'
  exit 0
fi

candidates=()
if [[ $# -gt 0 ]]; then
  candidates=("$@")
else
  while IFS= read -r -d '' f; do
    candidates+=("$f")
  done < <(discover)
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "setup-fragment-content-scan: discovered zero *.test.sh files — the scanner is broken, not the corpus clean" >&2
  exit 2
fi

# _scan_file <path> — prints findings to stdout, one per line:
#   <path>:<line>: setup-fragment-hardcode — <what> (resolve via setup.md's
#   routing table, or scan across setup/*.md — see shipyard-repo-root-preamble.test.sh check (4))
# Prints `#fragvars <n>` to STDERR — the number of fragment-path variable
# assignments this file was found to carry — so the caller can total an
# anti-vacuity signal across the whole corpus.
# Returns 0 if clean, 1 if it found something.
_scan_file() {
  local file="$1"
  awk -v FILE="$file" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }

    BEGIN {
      # Matches a REAL filesystem path to a numbered setup fragment, e.g.
      #   .../commands/do-work/setup/01-repo-recovery.md
      #   .../commands/do-work/setup/00k-repo-root-pin.md
      # The `do-work/setup/` anchor is what distinguishes a real path from a
      # bare `setup/NNx-name.md` router-table label (which lacks it).
      FRAGPATH_RE = "do-work/setup/[0-9][0-9][a-zA-Z]?-[A-Za-z-]+\\.md"
      # A content-read command name, as a whole word.
      READ_CMD_RE = "(^|[^A-Za-z0-9_])(grep|cat|assert_contains)([^A-Za-z0-9_]|$)"
      pending_allow = 0
      allow_file = 0
      found_any = 0
      nfragvars = 0
      delete fragvars
      in_cont = 0
      logical = ""
      logical_start = 0
    }

    # File-wide opt-out: scan for it up front on every raw line (cheap, and
    # lets us short-circuit reporting at END without a second pass).
    /#[[:space:]]*setup-fragment-content-scan:[[:space:]]*allow-file/ { allow_file = 1 }

    # Backslash-line-continuation joining. A `cat A \` / `B \` / `> C` split
    # across physical lines must be evaluated as ONE logical statement — a
    # per-physical-line `>` check would miss the redirect that lives on a
    # later continuation line (issues #66/#64 of this scanners own test
    # cases: the router+fragments concat pattern used by
    # dispatch-integration-774.test.sh / external-provisioning-guard.test.sh
    # is written exactly this way). A line continues when it ends with `\`
    # (optionally followed only by whitespace, which should not occur in
    # practice but is tolerated).
    {
      raw = $0
      is_cont_line = (raw ~ /\\[[:space:]]*$/)
      piece = raw
      sub(/\\[[:space:]]*$/, "", piece)

      if (!in_cont) {
        logical_start = NR
        logical = piece
      } else {
        logical = logical " " piece
      }

      if (is_cont_line) {
        in_cont = 1
        next
      }
      in_cont = 0
    }

    {
      line = logical
      report_line = logical_start

      # A comment line whose SOLE content is the allow directive applies to
      # the NEXT logical line, not itself.
      if (line ~ /^[[:space:]]*#[[:space:]]*setup-fragment-content-scan:[[:space:]]*allow[[:space:]]*$/) {
        pending_allow = 1
        next
      }

      this_line_allow = pending_allow || (line ~ /#[[:space:]]*setup-fragment-content-scan:[[:space:]]*allow([[:space:]]|$)/)
      pending_allow = 0

      # --- Track fragment-path variable assignments -----------------------
      # VARNAME="...do-work/setup/NNx-name.md..."  (export/local/readonly ok)
      if (match(line, /^[[:space:]]*(export[[:space:]]+|local[[:space:]]+|readonly[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
        lhs = substr(line, RSTART, RLENGTH)
        if (line ~ FRAGPATH_RE) {
          varname = lhs
          sub(/^[[:space:]]*(export[[:space:]]+|local[[:space:]]+|readonly[[:space:]]+)?/, "", varname)
          sub(/=$/, "", varname)
          if (!(varname in fragvars)) {
            fragvars[varname] = 1
            nfragvars++
          }
        }
      }

      # --- Detect a content-read line -------------------------------------
      if (line ~ READ_CMD_RE) {
        # `cat A B > C` (or any `cat ... >`) is the sanctioned
        # concatenate-then-grep-the-copy pattern — never flagged, regardless
        # of what appears on the line.
        is_cat_redirect = (line ~ /(^|[^A-Za-z0-9_])cat([^A-Za-z0-9_]|$)/ && line ~ />/)

        if (!is_cat_redirect && !this_line_allow && !allow_file) {
          hit = ""
          if (match(line, FRAGPATH_RE)) {
            hit = substr(line, RSTART, RLENGTH)
          } else {
            for (v in fragvars) {
              if (index(line, "$" v) > 0) {
                hit = "$" v
                break
              }
            }
          }
          if (hit != "") {
            printf "%s:%d: setup-fragment-hardcode — %s (resolve via setup.md routing table, or scan across setup/*.md)\n", FILE, report_line, hit
            found_any = 1
          }
        }
      }
    }

    END {
      printf "#fragvars %d\n", nfragvars > "/dev/stderr"
      if (allow_file) exit 0
      exit (found_any ? 1 : 0)
    }
  ' "$file"
}

found=0
total_fragvars=0
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

for f in "${candidates[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "setup-fragment-content-scan: no such file: $f" >&2
    exit 2
  fi
  if ! _scan_file "$f" 2>"$err_file"; then
    found=1
  fi
  n="$(sed -n 's/^#fragvars \([0-9][0-9]*\)$/\1/p' "$err_file" | tail -1)"
  [[ -n "$n" ]] || n=0
  total_fragvars=$((total_fragvars + n))
done

if [[ "$found" -eq 1 ]]; then
  echo >&2
  echo "setup-fragment-content-scan: hardcoded setup/*.md fragment content-read(s) found (issue #1453)." >&2
  echo "A router/fragment split can silently relocate the content a grep/cat/assert_contains" >&2
  echo "depends on, breaking the assertion in CI with no local warning. Resolve the file" >&2
  echo "through setup.md's routing table, or scan across setup/*.md for the asserted" >&2
  echo "content (see shipyard-repo-root-preamble.test.sh check (4) for the pattern), or" >&2
  echo "annotate a deliberate exception with '# setup-fragment-content-scan: allow' /" >&2
  echo "'# setup-fragment-content-scan: allow-file'." >&2
  exit 1
fi

# Anti-vacuity: a clean verdict is only meaningful if the matcher actually
# found fragment-path variables to check in the first place — a scope
# regression (wrong discovery glob, a rename) would otherwise make every
# check "pass" vacuously, the same false-confidence trap issue #910 called
# out for the plugin-root preamble test. Only enforced on a DISCOVERY run.
if [[ $# -eq 0 && "$total_fragvars" -eq 0 ]]; then
  echo "setup-fragment-content-scan: scanned ${#candidates[@]} file(s) but found ZERO fragment-path variables — the matcher is broken, not the corpus clean." >&2
  exit 2
fi

echo "setup-fragment-content-scan: ${#candidates[@]} file(s), $total_fragvars fragment-path variable(s) tracked; no hardcoded content-reads found."
exit 0

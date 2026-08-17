#!/usr/bin/env bash
# Test: no /shipyard:do-work setup/ sub-file crosses the per-Read TOKEN cap.
#
# Issue #994: the setup/ split (#611) was sized against the 256KB single-file
# `Read` BYTE limit, but the limit that actually binds in practice is the
# per-`Read` TOKEN cap (25,000 tokens). Three of the setup/ sub-files still
# silently overflowed that cap despite sitting comfortably under 256KB —
# `Read` returned a PARTIAL view with no loud failure, so the orchestrator
# proceeded as if it had the whole file. do-work-phase-file-size.test.sh
# (issue #611) guards the 256KB byte limit repo-wide; THIS test guards the
# tighter, token-derived limit for setup/ specifically, since that's the
# directory whose router explicitly promises "every sub-file fits one Read."
#
# The threshold is a byte-count PROXY for the token cap, not an exact token
# count — computing real BPE token counts in pure bash isn't practical, and
# the byte-per-token ratio varies with content density (prose vs. code
# fences vs. tables). This repo's own overflow reports (issue #994's live
# repro plus the three files this fix re-measured) put the ratio at roughly
# 2.4-2.7 bytes/token; using the DENSEST observed ratio (~2.39 bytes/token)
# against the 25,000-token cap gives ~59,700 bytes as the point past which a
# file is genuinely at risk. 60,000 bytes rounds that to a clean number with
# a small margin baked in from the "conservative, not exact" side, matching
# the byte-count-proxy approach issue #994 itself endorses as sufficient.
# When a file sits within ~10% of this cap, verify with an actual `Read`
# call rather than trusting the proxy alone — density varies.
#
# Scope: plugins/shipyard/commands/do-work/setup/ ONLY (recursively, so any
# future sub-cluster split lands under the same guard automatically). The
# non-setup phase files (steady-state.md, dispatch-rules.md, drain.md,
# cleanup-summary.md) are NOT yet re-split against this tighter cap — that is
# tracked as separate follow-up work, not this issue's scope.
#
# Issue #1430: a file sitting within a few hundred bytes of the 60,000-byte
# cap is a tripwire — the NEXT ordinary, well-scoped edit trips CI, and the
# only way a worker finds out is by hitting the wall after already opening a
# PR (this happened twice in one session: #1427 and #1428, both against
# 06c-scope-handling-ui.md). So this test also WARNS, without failing, once a
# file crosses 95% of the cap (57,000 bytes) — naming the remaining headroom
# so a worker sees "you have N bytes left" while still editing, not after
# pushing. WARN is non-fatal (exit 0 unless something actually breaches
# MAX_BYTES); it exists to change failure TIMING, not the cap itself.
#
# Pure bash, no external dependencies. CI auto-discovers this file via
# tests.yml's `find plugins -type f -name '*.test.sh'`, so no workflow edit
# is needed.
#
# Issue #1443: `--warn-check <path>` is a reusable, non-test invocation mode
# so dispatch-rules.md's claimed_paths warn-band check can query this file's
# own MAX_BYTES/WARN_BYTES thresholds instead of duplicating them as a
# second, independently-drifting literal. Prints one of:
#   WARN <bytes> <remaining>  -- in the warn band
#   PASS <bytes>               -- under the warn band (or out of this test's
#                                  setup/-only scope, or missing/unreadable)
# and always exits 0 -- this mode never fails a build; only a bare (no-arg)
# run of this file can FAIL.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -d "$repo_root/.git" || -f "$repo_root/CHANGELOG.md" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  echo "FAIL: could not locate repo root from $here" >&2
  exit 1
fi

setup_dir="$repo_root/plugins/shipyard/commands/do-work/setup"

# Token-derived byte proxy (see header comment for the derivation).
MAX_BYTES=$((60 * 1000))
TOKEN_CAP=25000
# Warn-on-approach threshold (issue #1430): 95% of MAX_BYTES. Non-fatal —
# only MAX_BYTES failing the run.
WARN_BYTES=$((57 * 1000))

if [[ "${1:-}" == "--warn-check" ]]; then
  target="${2:-}"
  if [[ -n "$target" && -f "$target" ]]; then
    target_dir="$(cd "$(dirname "$target")" && pwd)"
    case "$target_dir/$(basename "$target")" in
      "$setup_dir"/*)
        bytes=$(wc -c < "$target" | tr -d ' ')
        if (( bytes > WARN_BYTES )); then
          echo "WARN $bytes $((MAX_BYTES - bytes))"
          exit 0
        fi
        ;;
    esac
  fi
  echo "PASS -"
  exit 0
fi

pass=0
warn=0
fail=0
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'

if [[ ! -d "$setup_dir" ]]; then
  printf '%sFAIL%s  setup dir missing: %s\n' "$RED" "$RESET" "$setup_dir" >&2
  exit 1
fi

echo "do-work setup/ phase-file TOKEN budget guard (issue #994)"
echo "  cap: ${MAX_BYTES} bytes (token-derived proxy for the ${TOKEN_CAP}-token per-Read cap)"
echo "  warn: ${WARN_BYTES} bytes (95% of cap — advisory only, issue #1430)"
echo

files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(find "$setup_dir" -type f -name '*.md' -print0 | sort -z)

if [[ ${#files[@]} -eq 0 ]]; then
  printf '%sFAIL%s  no *.md files found under %s\n' "$RED" "$RESET" "$setup_dir" >&2
  exit 1
fi

for f in "${files[@]}"; do
  rel="${f#"$repo_root"/}"
  bytes=$(wc -c < "$f" | tr -d ' ')
  if (( bytes > MAX_BYTES )); then
    printf '  %sFAIL%s  %s (%d bytes > %d cap)\n' "$RED" "$RESET" "$rel" "$bytes" "$MAX_BYTES"
    printf '    This setup/ sub-file is likely overflowing the %d-token per-Read cap\n' "$TOKEN_CAP"
    printf '    even though it may sit well under the 256KB byte limit. Split it into\n'
    printf '    a further sub-cluster file (e.g. <name>b-<topic>.md), update setup.md'"'"'s\n'
    printf '    router table, and fix every cross-file anchor reference that moved\n'
    printf '    (issue #994).\n'
    fail=$((fail+1))
  elif (( bytes > WARN_BYTES )); then
    remaining=$((MAX_BYTES - bytes))
    printf '  %sWARN%s  %s (%d bytes, %d remaining before the %d cap)\n' "$YELLOW" "$RESET" "$rel" "$bytes" "$remaining" "$MAX_BYTES"
    printf '    Approaching the token-budget cap (issue #1430) — plan to split this\n'
    printf '    file into a further sub-cluster rather than extending it further.\n'
    warn=$((warn+1))
    pass=$((pass+1))
  else
    printf '  %sPASS%s  %s (%d bytes <= %d)\n' "$GREEN" "$RESET" "$rel" "$bytes" "$MAX_BYTES"
    pass=$((pass+1))
  fi
done

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d setup/ file(s) over the token-budget proxy cap (%d under, %d of those in the warn band)\n' "$RED" "$RESET" "$fail" "$pass" "$warn" >&2
  exit 1
elif (( warn > 0 )); then
  printf '%sPASS%s  all %d setup/ file(s) under the %d-byte token-budget proxy cap (%d approaching it, see WARN above)\n' "$GREEN" "$RESET" "$pass" "$MAX_BYTES" "$warn"
  exit 0
else
  printf '%sPASS%s  all %d setup/ file(s) under the %d-byte token-budget proxy cap\n' "$GREEN" "$RESET" "$pass" "$MAX_BYTES"
  exit 0
fi

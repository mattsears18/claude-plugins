#!/usr/bin/env bash
# Test: assert-worktree-change-present.sh — the standalone, testable script
# behind issue-work.md's step 4.5 and spike.md's step 7.5 phantom-merge
# guards (issue #356).
#
# Background — issue #1340, the sibling of #1336/#1341 (which fixed the same
# failure shape in fix-rebase.md §5.7). §4.5/§7.5's guard exists to stop a
# worker that reached the end of implementation with no real change from
# opening a PR that still claims one — the PR merges, `Closes #N` closes the
# linked issue, and the backlog claims work shipped when nothing landed. It
# was prescribed as an inline snippet with TWO checks:
#
#   CHANGED_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH"...HEAD | wc -l | tr -d ' ')
#   if [ "$CHANGED_FILES" = "0" ]; then
#     WORKING_TREE_DIRTY=$(git status --porcelain | wc -l | tr -d ' ')
#     if [ "$WORKING_TREE_DIRTY" = "0" ]; then
#       echo "blocked ..."; exit 0
#     fi
#   fi
#
# Two independent, reproduced failures make that inline form unsafe, and
# unlike #1336's guard (which only had one `--name-only` comparison) this
# guard's two checks are corrupted in OPPOSITE directions:
#
#   1. The full block — git command substitutions plus a NESTED inline `if`,
#      wrapped in an even larger compound block than fix-rebase's §5.7 (the
#      reaped-escape-hatch preamble plus two nested ifs) — is deterministically
#      REFUSED by the harness's worktree-isolation Bash guard in an isolated
#      worker session (the #802 refusal class). `issue-work` and `spike`
#      workers are ALWAYS worktree-isolated, so the guard as written could
#      never execute as prescribed. Reproduced firsthand against the literal
#      block in issue-work.md §4.5.
#   2. The refusal's own remediation ("break it into plain, separate
#      commands") produces a bare `git diff --name-only <refs> | wc -l` as
#      the entirety of one Bash call — the shape a diff-rewriting shell proxy
#      (`rtk`, issue #1333) rewrites. Measured: a genuinely-empty diff comes
#      back as a single `\n` byte, so `wc -l` returns 1, not 0 — the
#      `CHANGED_FILES == 0` bail can then never fire. This is an OVER-count.
#   3. The SAME remediation applied to the second check — a bare
#      `git status --porcelain | wc -l` — is corrupted the OTHER way:
#      measured, the proxy strips the trailing newline from the raw output,
#      so `wc -l` UNDER-counts by one. A single genuinely-dirty file reads as
#      zero, which would make `WORKING_TREE_DIRTY == 0` trip on a real
#      uncommitted change.
#
# The fix extracts both comparisons into this standalone script: one plain
# `bash <script>` call the isolation guard accepts, whose internal `git`
# calls run in a separate process the proxy does not rewrite, and which
# fails LOUD — with direction-specific detection for each check — rather
# than trusting a miscounted result.
#
# These tests cover the script's own behavior: the clean cases (committed
# change present, only uncommitted change present, truly nothing), the
# indeterminate/bad-usage cases, and — the regression this issue exists to
# close — a direct reproduction of BOTH proxy-rewrite directions, asserting
# the script never returns a clean, wrong exit over either one.
#
# Uses synthetic git fixture repos (per worker-preamble § "Pin the default
# branch in git-using test fixtures").
#
# Pure bash + git + coreutils. Run with:
#
#   bash plugins/shipyard/scripts/tests/assert-worktree-change-present.test.sh

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

script="$repo_root/plugins/shipyard/scripts/assert-worktree-change-present.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

echo "assert-worktree-change-present.sh regression tests (issues #356, #1340)"
echo

if [[ -f "$script" ]]; then
  ok "scripts/assert-worktree-change-present.sh exists"
else
  bad "scripts/assert-worktree-change-present.sh exists (missing: $script)"
  echo
  printf '%sFAIL%s  %d test(s) failed (%d passed) — cannot run behavioral tests, script missing\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
fi

if [[ -x "$script" ]]; then
  ok "scripts/assert-worktree-change-present.sh has the exec bit set"
else
  bad "scripts/assert-worktree-change-present.sh has the exec bit set"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── Fixture ────────────────────────────────────────────────────────────────
# main             — base branch.
# committed-change — a branch with a real committed diff vs main.
# empty-branch     — a branch identical to main (no committed diff, and
#                    later checked with a clean working tree too).
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"

printf 'base\n' > "$repo/base.txt"
git -C "$repo" add base.txt
git -C "$repo" commit -q -m base

git -C "$repo" checkout -q -b committed-change
printf 'the change\n' > "$repo/feat.txt"
git -C "$repo" add feat.txt
git -C "$repo" commit -q -m "real change"

git -C "$repo" checkout -q -b empty-branch main

# ── (1) Committed diff present → OK, exit 0, no need to check working tree. ─
out="$(cd "$repo" && git checkout -q committed-change && bash "$script" main 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* && "$out" == *"committed=1"* ]]; then
  ok "committed diff present: exit 0, OK verdict with committed=1"
else
  bad "committed diff present: expected exit 0 + OK committed=1, got exit $status: $out"
fi

# ── (2) No committed diff, but the working tree has an uncommitted change →
# OK, exit 0 (the rare "edited but didn't stage" case §4.5 exists to allow
# through rather than false-bail). ──────────────────────────────────────────
git -C "$repo" checkout -q empty-branch
printf 'uncommitted\n' > "$repo/uncommitted.txt"
out="$(cd "$repo" && bash "$script" main 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* && "$out" == *"working-tree-dirty=1"* ]]; then
  ok "no committed diff but working tree dirty: exit 0, OK verdict with working-tree-dirty=1"
else
  bad "no committed diff but working tree dirty: expected exit 0 + OK working-tree-dirty=1, got exit $status: $out"
fi
rm -f "$repo/uncommitted.txt"

# ── (3) THE #356 SHAPE: no committed diff, clean working tree → must bail. ──
out="$(cd "$repo" && git checkout -q empty-branch && bash "$script" main 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == *EMPTY_DIFF:* ]]; then
  ok "no committed diff, clean tree: exit 1, EMPTY_DIFF verdict (issue #356)"
else
  bad "no committed diff, clean tree: expected exit 1 + EMPTY_DIFF, got exit $status: $out"
fi

# ── (4) Default post-rev is HEAD (no second argument needed). ───────────────
out="$(cd "$repo" && git checkout -q committed-change && bash "$script" main 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* ]]; then
  ok "post-rev defaults to HEAD when omitted"
else
  bad "post-rev defaults to HEAD when omitted: expected exit 0 + OK, got exit $status: $out"
fi

# ── (5) Bad usage → indeterminate, never a clean pass. ──────────────────────
out="$(cd "$repo" && bash "$script" 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* ]]; then
  ok "missing argument: exit 2, INDETERMINATE"
else
  bad "missing argument: expected exit 2 + INDETERMINATE, got exit $status: $out"
fi

# ── (6) Unresolvable ref → indeterminate, never a clean pass. ───────────────
out="$(cd "$repo" && bash "$script" no-such-ref-xyz 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* ]]; then
  ok "unresolvable ref: exit 2, INDETERMINATE"
else
  bad "unresolvable ref: expected exit 2 + INDETERMINATE, got exit $status: $out"
fi

# ── Proxy-rewrite fixtures (issue #1340) — BOTH corruption directions ──────
real_git="$(command -v git)"

# Over-counting shadow: rewrites EVERY `git diff --name-only` result the way
# #1336/#1341 measured (including a ref-vs-itself comparison, so it also
# defeats the self-check unless the blank-line shape check catches it).
fake_diff_over="$work/fake-bin-diff-over"
mkdir -p "$fake_diff_over"
cat > "$fake_diff_over/git" <<EOS
#!/usr/bin/env bash
if [ "\$1" = "diff" ] && [ "\$2" = "--name-only" ]; then
  out="\$("$real_git" "\$@")"
  if [ -z "\$out" ]; then printf '\n'; else printf '%s\n\nChanges:\n\n' "\$out"; fi
  exit 0
fi
exec "$real_git" "\$@"
EOS
chmod +x "$fake_diff_over/git"

# Under-counting shadow: strips the FINAL trailing newline from
# `git status --porcelain` output the way #1340 measured, leaving
# `git diff --name-only` untouched (isolates this check from the other).
fake_status_under="$work/fake-bin-status-under"
mkdir -p "$fake_status_under"
cat > "$fake_status_under/git" <<EOS
#!/usr/bin/env bash
if [ "\$1" = "status" ] && [ "\$2" = "--porcelain" ]; then
  out="\$("$real_git" "\$@")"
  printf '%s' "\$out"
  exit 0
fi
exec "$real_git" "\$@"
EOS
chmod +x "$fake_status_under/git"

# ── (7) Fixture sanity: the over-count shadow genuinely reproduces the
# miscount an isolated top-level call would see — a genuinely-empty diff
# comes back as 1, not 0. Without this, test (8) could pass vacuously. ──────
miscount="$(cd "$repo" && git checkout -q empty-branch && PATH="$fake_diff_over:$PATH" bash -c 'git diff --name-only main...main | wc -l | tr -d " "')"
if [[ "$miscount" == "1" ]]; then
  ok "fixture sanity: the over-count shadow miscounts an empty diff as 1 (issue #1336/#1340)"
else
  bad "fixture sanity: expected the over-count shadow to make an empty diff count as 1, got '$miscount'"
fi

# ── (8) THE OVER-COUNT REGRESSION. Under the over-count proxy, the script
# must never return a clean exit — its self-check catches the corrupted
# environment before either count is trusted. ───────────────────────────────
out="$(cd "$repo" && git checkout -q empty-branch && PATH="$fake_diff_over:$PATH" bash "$script" main 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* && "$out" == *self-check* ]]; then
  ok "over-count proxy (--name-only): exit 2, INDETERMINATE via the self-check — never a silent pass"
else
  bad "over-count proxy (--name-only): expected exit 2 + INDETERMINATE mentioning the self-check, got exit $status: $out"
fi

# ── (9) Fixture sanity for the UNDER-count direction: a genuinely-dirty tree
# (1 file) reads as 0 lines under the shadow, reproducing the measured
# under-count. Without this, test (10) could pass vacuously. ────────────────
git -C "$repo" checkout -q empty-branch
printf 'uncommitted\n' > "$repo/uncommitted.txt"
undercount="$(cd "$repo" && PATH="$fake_status_under:$PATH" bash -c 'git status --porcelain | wc -l | tr -d " "')"
if [[ "$undercount" == "0" ]]; then
  ok "fixture sanity: the under-count shadow miscounts a 1-file-dirty tree as 0 (issue #1340)"
else
  bad "fixture sanity: expected the under-count shadow to make a 1-file-dirty tree count as 0, got '$undercount'"
fi

# ── (10) THE UNDER-COUNT REGRESSION. Under the under-count proxy, a
# genuinely dirty working tree (real uncommitted work) must NOT be silently
# read as clean and false-bailed with EMPTY_DIFF — the missing-trailing-
# newline check must catch it as INDETERMINATE instead. ─────────────────────
out="$(cd "$repo" && PATH="$fake_status_under:$PATH" bash "$script" main 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* && "$out" == *"newline"* ]]; then
  ok "under-count proxy (--porcelain): exit 2, INDETERMINATE via the missing-trailing-newline check — never a false EMPTY_DIFF"
else
  bad "under-count proxy (--porcelain): expected exit 2 + INDETERMINATE mentioning 'newline', got exit $status: $out"
fi
rm -f "$repo/uncommitted.txt"

# ── (11) The script must not itself contain the vulnerable shapes: no
# `--name-only` or `--porcelain` result may be counted through a `wc -l`
# pipeline, and neither may be captured through a `$(...)` substitution. ────
# Comment lines are stripped first — this file's own header quotes the
# vulnerable snippet verbatim to explain it, which must not trip the check.
code_only="$work/script-code-only"
awk '!/^[[:space:]]*#/' "$script" > "$code_only"

if grep -qE '(name-only|porcelain).*\|.*wc' "$code_only"; then
  bad "script does not pipe a --name-only or --porcelain result into wc (the shape that miscounts under a proxy)"
else
  ok "script does not pipe a --name-only or --porcelain result into wc (the shape that miscounts under a proxy)"
fi

if grep -qE '\$\(git (diff --name-only|status --porcelain)' "$code_only"; then
  bad "script does not capture a --name-only/--porcelain result via \$(...) (which strips trailing-newline evidence)"
else
  ok "script does not capture a --name-only/--porcelain result via \$(...) (which strips trailing-newline evidence)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

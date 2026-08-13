#!/usr/bin/env bash
# Test: assert-rebase-diff-nonempty.sh — the standalone, testable script
# behind fix-rebase.md's step 5.7 post-rebase empty-diff guard.
#
# Background — issue #1336. §5.7's guard (issue #646) exists to stop a rebase
# that silently dropped a PR's entire change from being force-pushed, which
# makes GitHub auto-close the PR with no error signal. It was prescribed as an
# inline snippet:
#
#   PRE_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH...origin/$HEAD_REF" | wc -l | tr -d ' ')
#   POST_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH" HEAD | wc -l | tr -d ' ')
#   if [ "${PRE_FILES:-0}" -gt 0 ] && [ "${POST_FILES:-0}" = "0" ]; then ...
#
# Two independent, reproduced failures made that inline form unsafe:
#
#   1. The full block — git command substitutions plus an inline `if` — is
#      deterministically REFUSED by the harness's worktree-isolation Bash
#      guard in an isolated worker session (the #802 refusal class), and
#      fix-rebase workers are always worktree-isolated. So it could not run as
#      prescribed at all.
#   2. The refusal's own remediation ("break it into plain, separate
#      commands") produces a bare `git diff --name-only <refs> | wc -l` as the
#      entirety of one Bash call — precisely the invocation shape a
#      diff-rewriting shell proxy (`rtk`, issue #1333) rewrites. Measured: a
#      genuinely-empty diff comes back as a single `\n` byte, so `wc -l`
#      returns 1, the `POST_FILES == 0` bail can never fire, and the #646
#      guard is silently disabled for exactly the case it exists to catch.
#
# The fix extracts the comparison into this standalone script (the same
# pattern #826 used for assert-worktree-cwd.sh and #1175 for
# verify-added-lines-survived.sh): one plain `bash <script>` call the
# isolation guard accepts, whose internal `git diff` calls run in a separate
# process the proxy does not rewrite, and which fails LOUD rather than
# miscounting when its input doesn't look like real `--name-only` output.
#
# These tests cover the script's own behavior: the clean case, the #646
# empty-diff case, the already-empty-before case (no false bail), the
# indeterminate cases, and — the regression this issue exists to close — a
# direct reproduction of the proxy rewrite, asserting the script never returns
# a clean exit 0 over it.
#
# Uses synthetic git fixture repos (per worker-preamble § "Pin the default
# branch in git-using test fixtures" — `git init -b main` pins the default
# branch name so this runs the same on a CI runner defaulting to `master`).
#
# Pure bash + git + coreutils. Run with:
#
#   bash plugins/shipyard/scripts/tests/assert-rebase-diff-nonempty.test.sh

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

script="$repo_root/plugins/shipyard/scripts/assert-rebase-diff-nonempty.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

echo "assert-rebase-diff-nonempty.sh regression tests (issues #646, #1336)"
echo

if [[ -f "$script" ]]; then
  ok "scripts/assert-rebase-diff-nonempty.sh exists"
else
  bad "scripts/assert-rebase-diff-nonempty.sh exists (missing: $script)"
  echo
  printf '%sFAIL%s  %d test(s) failed (%d passed) — cannot run behavioral tests, script missing\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
fi

if [[ -x "$script" ]]; then
  ok "scripts/assert-rebase-diff-nonempty.sh has the exec bit set"
else
  bad "scripts/assert-rebase-diff-nonempty.sh has the exec bit set"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── Fixture ────────────────────────────────────────────────────────────────
# main            — base branch, advances after the PR branched.
# feature         — the PR's pre-rebase head; adds feat.txt (non-empty net
#                   contribution vs main).
# rebased-clean   — a correct rebase result: still adds feat.txt.
# rebased-empty   — the #646 shape: the "resolution" dropped the PR's change,
#                   so the tree is identical to main (empty net contribution).
# empty-before    — a PR that was ALREADY empty vs base before the rebase; the
#                   guard is gated on PRE > 0 so it must NOT bail here.
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"

printf 'base\n' > "$repo/base.txt"
git -C "$repo" add base.txt
git -C "$repo" commit -q -m base

git -C "$repo" checkout -q -b feature
printf 'the PR content\n' > "$repo/feat.txt"
git -C "$repo" add feat.txt
git -C "$repo" commit -q -m feature

git -C "$repo" checkout -q main
printf 'base\nmain advanced\n' > "$repo/base.txt"
git -C "$repo" add base.txt
git -C "$repo" commit -q -m "main advanced"

git -C "$repo" checkout -q -b rebased-clean main
printf 'the PR content\n' > "$repo/feat.txt"
git -C "$repo" add feat.txt
git -C "$repo" commit -q -m "rebased clean"

git -C "$repo" checkout -q -b rebased-empty main
git -C "$repo" commit -q --allow-empty -m "rebased, but the change was dropped"

git -C "$repo" checkout -q -b empty-before main
git -C "$repo" commit -q --allow-empty -m "a PR that was already empty vs base"

# ── (1) Clean case: non-empty before, non-empty after → safe to push. ───────
out="$(cd "$repo" && git checkout -q rebased-clean && bash "$script" main feature 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* ]]; then
  ok "clean rebase: exit 0, OK verdict"
else
  bad "clean rebase: expected exit 0 + OK, got exit $status: $out"
fi

# ── (2) The #646 shape: non-empty before, EMPTY after → must bail. This is
# the whole point of the guard. ─────────────────────────────────────────────
out="$(cd "$repo" && git checkout -q rebased-empty && bash "$script" main feature 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == EMPTY_DIFF:* ]]; then
  ok "collapsed-to-empty rebase: exit 1, EMPTY_DIFF verdict (issue #646)"
else
  bad "collapsed-to-empty rebase: expected exit 1 + EMPTY_DIFF, got exit $status: $out"
fi

# ── (3) Already-empty-before: the guard is gated on PRE > 0, so a PR that was
# empty vs base BEFORE the rebase must not false-bail. ──────────────────────
out="$(cd "$repo" && git checkout -q empty-before && bash "$script" main empty-before 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* ]]; then
  ok "already-empty-before-rebase: exit 0, no false bail (PRE > 0 gating holds)"
else
  bad "already-empty-before-rebase: expected exit 0 + OK, got exit $status: $out"
fi

# ── (4) Explicit post-rebase rev argument is honored (defaults to HEAD). ────
out="$(cd "$repo" && git checkout -q main && bash "$script" main feature rebased-empty 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == EMPTY_DIFF:* ]]; then
  ok "explicit post-rebase rev argument is honored"
else
  bad "explicit post-rebase rev argument is honored: expected exit 1 + EMPTY_DIFF, got exit $status: $out"
fi

# ── (5) Bad usage → indeterminate, never a clean pass. ──────────────────────
out="$(cd "$repo" && git checkout -q main && bash "$script" main 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* ]]; then
  ok "missing argument: exit 2, INDETERMINATE"
else
  bad "missing argument: expected exit 2 + INDETERMINATE, got exit $status: $out"
fi

# ── (6) Unresolvable ref → indeterminate, never a clean pass. ───────────────
out="$(cd "$repo" && git checkout -q main && bash "$script" main no-such-ref-xyz 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* ]]; then
  ok "unresolvable ref: exit 2, INDETERMINATE"
else
  bad "unresolvable ref: expected exit 2 + INDETERMINATE, got exit $status: $out"
fi

# ── Proxy-rewrite fixtures (issue #1336) ───────────────────────────────────
# Reproduce the measured `rtk` rewrite of `git diff --name-only`: an EMPTY
# result comes back as a single newline; a non-empty result comes back with a
# blank line, a `Changes:` header, and another blank line appended. Shadowing
# `git` (the same technique verify-added-lines-survived.test.sh uses) keeps
# this reproduction independent of `rtk` actually being installed in CI.
real_git="$(command -v git)"

fake_all="$work/fake-bin-all"
mkdir -p "$fake_all"
cat > "$fake_all/git" <<EOS
#!/usr/bin/env bash
# Rewrites EVERY \`git diff --name-only\` result, including a ref-vs-itself
# comparison — the faithful reproduction of the measured proxy behavior.
if [ "\$1" = "diff" ] && [ "\$2" = "--name-only" ]; then
  out="\$("$real_git" "\$@")"
  if [ -z "\$out" ]; then printf '\n'; else printf '%s\n\nChanges:\n\n' "\$out"; fi
  exit 0
fi
exec "$real_git" "\$@"
EOS
chmod +x "$fake_all/git"

fake_real_only="$work/fake-bin-real-only"
mkdir -p "$fake_real_only"
cat > "$fake_real_only/git" <<EOS
#!/usr/bin/env bash
# A narrower proxy that leaves a ref-vs-ITSELF comparison alone (so the
# script's environment self-check passes) but still rewrites the two real
# comparisons — this isolates the blank-line shape check from the self-check.
if [ "\$1" = "diff" ] && [ "\$2" = "--name-only" ] && [ "\${3:-}" != "\${4:-}" ]; then
  out="\$("$real_git" "\$@")"
  if [ -z "\$out" ]; then printf '\n'; else printf '%s\n\nChanges:\n\n' "\$out"; fi
  exit 0
fi
exec "$real_git" "\$@"
EOS
chmod +x "$fake_real_only/git"

# ── (7) Fixture sanity: prove the shadow actually reproduces the miscount the
# issue reports — the OLD inline shape counts a genuinely-empty diff as 1.
# Without this, tests (8)-(9) could pass vacuously. ─────────────────────────
miscount="$(cd "$repo" && PATH="$fake_all:$PATH" bash -c 'git diff --name-only main main | wc -l | tr -d " "')"
if [[ "$miscount" == "1" ]]; then
  ok "fixture sanity: the old inline shape miscounts an empty diff as 1 under the proxy (issue #1336)"
else
  bad "fixture sanity: expected the proxy fixture to make an empty diff count as 1, got '$miscount'"
fi

# ── (8) THE REGRESSION. Under the proxy, against a genuinely collapsed-to-
# empty rebase, the old inline guard silently passed (POST_FILES == 1, so the
# bail never fired) and the worker force-pushed, auto-closing the PR. The
# script must never return a clean exit 0 here — the environment self-check
# catches it first. ─────────────────────────────────────────────────────────
out="$(cd "$repo" && git checkout -q rebased-empty && PATH="$fake_all:$PATH" bash "$script" main feature 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* && "$out" == *self-check* ]]; then
  ok "proxy rewrite over a collapsed-to-empty rebase: exit 2, INDETERMINATE via the self-check — never a silent pass (issue #1336)"
else
  bad "proxy rewrite over a collapsed-to-empty rebase: expected exit 2 + INDETERMINATE mentioning the self-check, got exit $status: $out"
fi

# ── (9) Same corruption, but with a proxy narrow enough to slip past the
# self-check — the blank-line shape check must catch it instead. ────────────
out="$(cd "$repo" && git checkout -q rebased-empty && PATH="$fake_real_only:$PATH" bash "$script" main feature 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* && "$out" == *"blank line"* ]]; then
  ok "self-check-evading proxy: exit 2, INDETERMINATE via the blank-line shape check"
else
  bad "self-check-evading proxy: expected exit 2 + INDETERMINATE mentioning 'blank line', got exit $status: $out"
fi

# ── (10) Same narrow proxy over an otherwise-CLEAN rebase: still fails loud.
# A corrupted-looking input can't be trusted to mean "safe to push" merely
# because the counts it produces happen to be non-zero. ────────────────────
out="$(cd "$repo" && git checkout -q rebased-clean && PATH="$fake_real_only:$PATH" bash "$script" main feature 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* ]]; then
  ok "self-check-evading proxy over a clean rebase: exit 2, INDETERMINATE — no verdict from untrustworthy input"
else
  bad "self-check-evading proxy over a clean rebase: expected exit 2 + INDETERMINATE, got exit $status: $out"
fi

# ── (11) The script must not itself contain the vulnerable shape: no
# `--name-only` result may be counted through a `wc -l` pipeline, and none may
# be captured through a `$(...)` substitution (which strips the trailing
# newline that distinguishes a rewritten empty result from a real one). ────
# Comment lines are stripped first — this file's own header quotes the
# vulnerable snippet verbatim to explain it, which must not trip the check.
code_only="$work/script-code-only"
awk '!/^[[:space:]]*#/' "$script" > "$code_only"

if grep -qE 'name-only.*\|.*wc' "$code_only"; then
  bad "script does not pipe a --name-only result into wc (the shape that miscounts under a proxy)"
else
  ok "script does not pipe a --name-only result into wc (the shape that miscounts under a proxy)"
fi

if grep -qE '\$\(git diff --name-only' "$code_only"; then
  bad "script does not capture a --name-only result via \$(...) (which strips the trailing-newline evidence)"
else
  ok "script does not capture a --name-only result via \$(...) (which strips the trailing-newline evidence)"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

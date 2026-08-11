#!/usr/bin/env bash
# Test: verify-added-lines-survived.sh — the standalone, testable script
# behind fix-rebase.md's step 5.8 post-rebase line-survival guard.
#
# Background — issue #1175: step 5.8's original inline shell snippet
# (`grep -vFxf "$f" <<<"$ADDED_LINES"`, typed directly into the worker's own
# interactive Bash-tool shell) was found to silently false-negative in a
# live worker environment where that shell's `grep` is shadowed by a
# function wrapping `ugrep` (Claude Code's own read-tool integration): the
# shadowed command reported "no missing lines" for files that a direct
# exact-line comparison showed DID have missing lines. A guard whose entire
# purpose is catching silent content loss must not itself be able to
# silently pass without actually verifying — this is a verification gate in
# the one code path (fix-rebase's §4.6 conflict resolution) where shipyard
# deliberately rewrites file content automatically.
#
# The fix extracts the comparison into this standalone script, which:
#   1. Never calls `grep` for the comparison — uses `sort`/`comm`/`awk`
#      instead, and runs as a genuinely separate `bash` process so it can't
#      inherit the calling shell's own function-shadowing either.
#   2. Fails LOUD (exit 2, `INDETERMINATE:`) rather than open (a false
#      "clean" exit 0) when it cannot establish a trustworthy result — via a
#      synthetic self-check that runs before any real file is scanned.
#
# This test covers the script's own behavior directly (not just its
# presence in the markdown spec, which fix-rebase-line-survival-guard.test.sh
# already covers): the clean case, the corrupted case, the deleted-file
# case, the indeterminate-ref case, the self-check-catches-a-broken-toolchain
# case, and — the regression this issue exists to close — a direct
# reproduction of a shadowed `grep` in the calling shell, proving the script
# still detects real corruption despite it.
#
# Uses synthetic git fixture repos (per worker-preamble § "Pin the default
# branch in git-using test fixtures" — `git init -b main` pins the default
# branch name so this runs the same on a CI runner defaulting to `master`).
#
# Pure bash + git + coreutils. Run with:
#
#   bash plugins/shipyard/scripts/tests/verify-added-lines-survived.test.sh

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

script="$repo_root/plugins/shipyard/scripts/verify-added-lines-survived.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"; fail=$((fail+1)); }

assert_file_exists() {
  if [[ -f "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi
}

assert_executable() {
  if [[ -x "$1" ]]; then ok "$2"; else bad "$2 (not executable: $1)"; fi
}

echo "verify-added-lines-survived.sh regression tests (issue #1175)"
echo

assert_file_exists "$script" "scripts/verify-added-lines-survived.sh exists"
assert_executable "$script" "scripts/verify-added-lines-survived.sh has the exec bit set"

if [[ ! -f "$script" ]]; then
  echo
  printf '%sFAIL%s  %d test(s) failed (%d passed) — cannot run behavioral tests, script missing\n' "$RED" "$RESET" "$((fail+1))" "$pass" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── Fixture: a base commit, a "feature" commit that adds two lines, and a
# rebased branch we can mutate per-scenario to simulate a clean or a
# corrupted post-rebase result. ─────────────────────────────────────────────
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"

printf 'line1\nline2\nline3\n' > "$repo/f.txt"
git -C "$repo" add f.txt
git -C "$repo" commit -q -m base
base_sha="$(git -C "$repo" rev-parse HEAD)"

git -C "$repo" checkout -q -b feature
printf 'line1\nline2\nline3\nadded-a\nadded-b\n' > "$repo/f.txt"
git -C "$repo" add f.txt
git -C "$repo" commit -q -m feature
feature_sha="$(git -C "$repo" rev-parse HEAD)"

git -C "$repo" checkout -q main
printf 'zzz\nline1\nline2\nline3\n' > "$repo/f.txt"
git -C "$repo" add f.txt
git -C "$repo" commit -q -m "main advanced"

# ── (1) Clean case: rebased tree has every added line, verbatim. ───────────
git -C "$repo" checkout -q -b rebased-clean main
printf 'zzz\nline1\nline2\nline3\nadded-a\nadded-b\n' > "$repo/f.txt"
git -C "$repo" add f.txt
git -C "$repo" commit -q -m "rebased clean"

out="$(cd "$repo" && bash "$script" "$base_sha" "$feature_sha" 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* ]]; then
  ok "clean case: exit 0, OK verdict"
else
  bad "clean case: expected exit 0 + OK verdict, got exit $status: $out"
fi

# ── (2) Corrupted case: rebased tree is missing one added line ('added-b'),
# simulating exactly the #983 silent-splice failure — a well-formed,
# non-empty file that dropped content from the wrong hunk. ─────────────────
git -C "$repo" checkout -q -b rebased-corrupted main
printf 'zzz\nline1\nline2\nline3\nadded-a\n' > "$repo/f.txt"
git -C "$repo" add f.txt
git -C "$repo" commit -q -m "rebased corrupted (missing added-b)"

out="$(cd "$repo" && bash "$script" "$base_sha" "$feature_sha" 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == CORRUPTED:*f.txt* ]]; then
  ok "corrupted case: exit 1, CORRUPTED verdict names f.txt"
else
  bad "corrupted case: expected exit 1 + CORRUPTED:...f.txt..., got exit $status: $out"
fi

# ── (3) Deleted-file case: the PR kept/added the file but the rebased tree
# no longer has it at all. ──────────────────────────────────────────────────
git -C "$repo" checkout -q -b rebased-deleted main
git -C "$repo" rm -q --ignore-unmatch f.txt 2>/dev/null || true
: > "$repo/.keep"
git -C "$repo" add -A
git -C "$repo" commit -q -m "rebased deletes f.txt entirely"

out="$(cd "$repo" && bash "$script" "$base_sha" "$feature_sha" 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == *"f.txt(missing)"* ]]; then
  ok "deleted-file case: exit 1, CORRUPTED verdict flags f.txt(missing)"
else
  bad "deleted-file case: expected exit 1 + f.txt(missing), got exit $status: $out"
fi

# ── (4) Indeterminate case: an unresolvable ref must fail loud, not open. ──
out="$(cd "$repo" && bash "$script" "not-a-real-ref-at-all" "$feature_sha" 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* ]]; then
  ok "bad-ref case: exit 2, INDETERMINATE verdict (fails loud, not open)"
else
  bad "bad-ref case: expected exit 2 + INDETERMINATE:..., got exit $status: $out"
fi

# ── (5) Missing usage args: also indeterminate, not a silent no-op. ────────
out="$(cd "$repo" && bash "$script" 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* ]]; then
  ok "missing-args case: exit 2, INDETERMINATE verdict"
else
  bad "missing-args case: expected exit 2 + INDETERMINATE:..., got exit $status: $out"
fi

# ── (6) Self-check catches a broken comparison toolchain. Simulate a
# broken `comm` that always reports "no difference" — exactly the shape of
# bug that made the original grep-based check dangerous — and confirm the
# script refuses to report a clean pass, failing loud instead. ─────────────
fake_bin="$work/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/comm" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$fake_bin/comm"

out="$(cd "$repo" && PATH="$fake_bin:$PATH" bash "$script" "$base_sha" "$feature_sha" 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == *"self-check failed"* ]]; then
  ok "broken-comm case: self-check catches it, exit 2 (never a false-clean exit 0)"
else
  bad "broken-comm case: expected exit 2 + 'self-check failed', got exit $status: $out"
fi

# ── (7) The core regression this issue exists to close: reproduce a shell
# with `grep` shadowed by a broken wrapper function (mirroring the reported
# ugrep-wrapping shell function) and confirm the CORRUPTED case is still
# correctly detected — proving the script's verdict does not depend on the
# calling shell's `grep` at all. ────────────────────────────────────────────
out="$(cd "$repo" && bash -c '
  grep() { echo "SHADOWED-GREP-CALLED-THIS-SHOULD-NEVER-HAPPEN" >&2; return 1; }
  export -f grep
  bash "'"$script"'" "'"$base_sha"'" "'"$feature_sha"'"
' 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == *CORRUPTED*f.txt* && "$out" != *SHADOWED-GREP-CALLED* ]]; then
  ok "shadowed-grep regression: corruption still detected, shadowed grep never invoked"
else
  bad "shadowed-grep regression: expected exit 1 + CORRUPTED + no shadow-grep call, got exit $status: $out"
fi

# ── (8) Same shadowed-grep shell, but against the CLEAN rebase — confirms
# the shadow doesn't cause a false positive either (both directions matter:
# #1175's repro was specifically a false NEGATIVE, but a check that only
# avoids false negatives by over-flagging everything would be equally
# useless). ──────────────────────────────────────────────────────────────
out="$(cd "$repo" && git checkout -q rebased-clean && bash -c '
  grep() { echo "SHADOWED-GREP-CALLED-THIS-SHOULD-NEVER-HAPPEN" >&2; return 1; }
  export -f grep
  bash "'"$script"'" "'"$base_sha"'" "'"$feature_sha"'"
' 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* && "$out" != *SHADOWED-GREP-CALLED* ]]; then
  ok "shadowed-grep regression (clean tree): no false positive, shadowed grep never invoked"
else
  bad "shadowed-grep regression (clean tree): expected exit 0 + OK, got exit $status: $out"
fi

# ── (9)-(11): the known-rewrites exemption (issue #1215) — fix-rebase.md's
# §4.6 version-coordination carve-out deliberately rewrites specific PR-added
# lines (a manifest `.version` row, a CHANGELOG heading) as part of a
# sanctioned, deterministic resolution. A blanket per-file exemption for that
# case would blind the guard to real corruption elsewhere in the same file —
# these tests pin the narrower, per-LINE exemption: the caller-declared
# rewrite is excused, but every OTHER added line in the same file is still
# required to survive verbatim. Reuses the base_sha/feature_sha fixture
# above, whose feature commit added exactly two lines to f.txt:
# 'added-a' and 'added-b'. ───────────────────────────────────────────────────

known_rewrites="$work/known-rewrites.tsv"
printf 'f.txt\tadded-a\n' > "$known_rewrites"

# ── (9) The known-rewrite is exempted, and the OTHER added line ('added-b')
# genuinely did survive — must still pass clean, even though 'added-a' was
# rewritten to something else entirely. ─────────────────────────────────────
git -C "$repo" checkout -q -b rebased-known-rewrite-clean main
printf 'zzz\nline1\nline2\nline3\nadded-a-renumbered\nadded-b\n' > "$repo/f.txt"
git -C "$repo" add f.txt
git -C "$repo" commit -q -m "rebased: added-a renumbered (sanctioned), added-b intact"

out="$(cd "$repo" && bash "$script" "$base_sha" "$feature_sha" "$known_rewrites" 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* ]]; then
  ok "known-rewrite exemption: renamed 'added-a' exempted, exit 0 OK (untouched 'added-b' still verified present)"
else
  bad "known-rewrite exemption: expected exit 0 + OK, got exit $status: $out"
fi

# ── (10) The core pairing this issue exists to pin: the SAME known-rewrites
# file (still only exempting 'added-a') must NOT mask a genuine corruption of
# the OTHER added line ('added-b' missing) in the very same file — proving
# the exemption is narrowed to exactly the declared line, never the whole
# file. ──────────────────────────────────────────────────────────────────────
git -C "$repo" checkout -q -b rebased-known-rewrite-corrupted main
printf 'zzz\nline1\nline2\nline3\nadded-a-renumbered\n' > "$repo/f.txt"
git -C "$repo" add f.txt
git -C "$repo" commit -q -m "rebased: added-a renumbered (sanctioned), added-b MISSING (real corruption)"

out="$(cd "$repo" && bash "$script" "$base_sha" "$feature_sha" "$known_rewrites" 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == CORRUPTED:*f.txt* ]]; then
  ok "known-rewrite exemption does not mask corruption elsewhere in the same file: exit 1, CORRUPTED names f.txt"
else
  bad "known-rewrite exemption over-masked corruption: expected exit 1 + CORRUPTED:...f.txt..., got exit $status: $out"
fi

# ── (11) A known-rewrites file named on the command line but missing on disk
# is a usage error, not a silent no-op exemption — fail loud (exit 2), same
# posture as every other "can't establish a trustworthy result" case. ───────
out="$(cd "$repo" && git checkout -q rebased-clean && bash "$script" "$base_sha" "$feature_sha" "$work/does-not-exist.tsv" 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* ]]; then
  ok "missing known-rewrites file: exit 2, INDETERMINATE verdict (fails loud, not a silent no-op)"
else
  bad "missing known-rewrites file: expected exit 2 + INDETERMINATE:..., got exit $status: $out"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

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
# still detects real corruption despite it. It also covers the issue #1333
# regression: a `git diff`-rewriting shell proxy (e.g. `rtk`) silently
# replacing real diff output with a non-standard stat-like summary must make
# this script fail LOUD, never silently pass as if nothing was added.
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

# ── (12)-(13): issue #1333 — a `git diff`-rewriting shell proxy (the `rtk`
# "Rust Token Killer" hook some worker environments run) can silently
# replace a bare/singly-piped `git diff` invocation's stdout with a
# non-standard, stat-like summary: no `---`/`+++` headers, no `@@` hunks, and
# critically no leading `diff --git a/<path> b/<path>` line. Fed that
# summary, the script's awk parse would previously compute an empty
# ADDED_LINES set for every file — which reads as "nothing was added" and
# silently, permanently disables the guard for every touched file, exactly
# inverting its purpose. These tests shadow `git` itself (mirroring the
# grep-shadowing technique in (7)-(8) above) so the reproduction doesn't
# depend on `rtk` actually being installed in CI, and confirm the fix: the
# script now fails LOUD (exit 2, INDETERMINATE) instead of silently passing
# on the corrupted input. ───────────────────────────────────────────────────

fake_bin_rtk="$work/fake-bin-rtk"
mkdir -p "$fake_bin_rtk"
real_git="$(command -v git)"
cat > "$fake_bin_rtk/git" <<EOS
#!/usr/bin/env bash
# Simulate the rtk proxy hook: a \`git diff <ref1> <ref2> -- <path>\` call
# (i.e. NOT --name-only) returns a non-unified-diff, stat-like summary
# instead of real diff output — no 'diff --git' header, no +++ header, no
# @@ hunk. Every other invocation (rev-parse, cat-file, name-only diff, …)
# passes straight through to the real git binary untouched.
if [ "\$1" = "diff" ] && [ "\$2" != "--name-only" ]; then
  cat <<'RTKOUT'
 f.txt | 1 +
 1 file changed, 1 insertion(+)

Changes:

 f.txt
  @@ -1,1 +1,2 @@
  +some-line
RTKOUT
  exit 0
fi
exec "$real_git" "\$@"
EOS
chmod +x "$fake_bin_rtk/git"

# ── (12) Proxy-corrupted diff against an otherwise-CLEAN rebase: must still
# fail loud (exit 2), never a false-clean exit 0 — the corrupted-looking
# input can't be trusted to mean "nothing added" just because it parses to
# empty. ─────────────────────────────────────────────────────────────────
out="$(cd "$repo" && git checkout -q rebased-clean && PATH="$fake_bin_rtk:$PATH" bash "$script" "$base_sha" "$feature_sha" 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* && "$out" == *"diff --git"* ]]; then
  ok "rtk-proxy-style corruption (clean tree): exit 2, INDETERMINATE — fails loud instead of a false-clean pass"
else
  bad "rtk-proxy-style corruption (clean tree): expected exit 2 + INDETERMINATE mentioning 'diff --git', got exit $status: $out"
fi

# ── (13) Same proxy corruption against a genuinely CORRUPTED rebase (the
# #983 silent-splice shape from test (2)) — must still fail loud (exit 2,
# not exit 1's CORRUPTED verdict, since the corrupted *input* can no longer
# be trusted to compute a verdict at all) rather than silently reporting
# clean because the awk parse of the rewritten summary found nothing to
# flag. This is the direct regression case: before the fix, this exact
# scenario returned exit 0 "OK" — a real content-loss rebase passing as
# clean purely because the diff-rewriting proxy emptied the parse. ────────
out="$(cd "$repo" && git checkout -q rebased-corrupted && PATH="$fake_bin_rtk:$PATH" bash "$script" "$base_sha" "$feature_sha" 2>&1)"
status=$?
if [[ $status -eq 2 && "$out" == INDETERMINATE:* ]]; then
  ok "rtk-proxy-style corruption (actually-corrupted tree): exit 2, INDETERMINATE — never a silent false-clean pass over real content loss"
else
  bad "rtk-proxy-style corruption (actually-corrupted tree): expected exit 2 + INDETERMINATE:..., got exit $status: $out"
fi

# ── (14)-(17): whole-file known-rewrites exemption (issue #1445) — the
# per-LINE exemption above (9)-(11) cannot express "this file was
# regenerated, potentially every added line differs" — a content-hash
# manifest or generated module has no fixed, enumerable "the one line that
# changed." A `<path>\tFILE\t<reason>` (3-field) entry exempts the WHOLE
# named path from the added-line comparison. A fresh, isolated fixture repo
# is used so these tests can't perturb the branches/expectations above. ────

repo2="$work/repo2"
mkdir -p "$repo2"
git -C "$repo2" init -q -b main
git -C "$repo2" config user.email "test@example.com"
git -C "$repo2" config user.name "Test"

printf 'shared-base\n' > "$repo2/shared.txt"
git -C "$repo2" add shared.txt
git -C "$repo2" commit -q -m base
base2_sha="$(git -C "$repo2" rev-parse HEAD)"

# feature: adds a whole new generated-looking file (gen.json) AND a genuine,
# non-generated added line to shared.txt — the second gives every scenario
# below a real line that must still be checked normally alongside the
# whole-file-exempted gen.json.
git -C "$repo2" checkout -q -b feature2
printf '{"hash":"AAA"}\n' > "$repo2/gen.json"
printf 'shared-base\nfeature-line\n' > "$repo2/shared.txt"
git -C "$repo2" add gen.json shared.txt
git -C "$repo2" commit -q -m feature
feature2_sha="$(git -C "$repo2" rev-parse HEAD)"

# main: advances independently, never touches gen.json or shared.txt.
git -C "$repo2" checkout -q main
printf 'main-advanced\n' > "$repo2/other.txt"
git -C "$repo2" add other.txt
git -C "$repo2" commit -q -m "main advanced"

known_rewrites2="$work/known-rewrites-2.tsv"
printf 'gen.json\tFILE\tregenerated via node scripts/generate-gen.mjs\n' > "$known_rewrites2"

# ── (14) gen.json regenerated with COMPLETELY different content (simulating
# a real regeneration run), FILE-exempted; shared.txt's real added line
# genuinely survived. Must pass clean despite gen.json sharing not one byte
# with what the PR's commit originally added. ──────────────────────────────
git -C "$repo2" checkout -q -b rebased-regenerated-clean main
printf '{"hash":"ZZZ","completely":"different"}\n' > "$repo2/gen.json"
printf 'shared-base\nfeature-line\n' > "$repo2/shared.txt"
git -C "$repo2" add gen.json shared.txt
git -C "$repo2" commit -q -m "rebased: gen.json regenerated, shared.txt intact"

out="$(cd "$repo2" && bash "$script" "$base2_sha" "$feature2_sha" "$known_rewrites2" 2>&1)"
status=$?
if [[ $status -eq 0 && "$out" == OK:* ]]; then
  ok "whole-file exemption: fully-regenerated gen.json exempted, exit 0 OK (shared.txt's real added line still verified present)"
else
  bad "whole-file exemption: expected exit 0 + OK, got exit $status: $out"
fi

# ── (15) Without the FILE exemption, that exact same regenerated tree must
# read as corrupted — confirms (14) passed BECAUSE of the exemption, not
# because the guard is somehow blind to gen.json already. ──────────────────
out="$(cd "$repo2" && bash "$script" "$base2_sha" "$feature2_sha" 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == CORRUPTED:*gen.json* ]]; then
  ok "whole-file exemption baseline: same regenerated tree WITHOUT the exemption is correctly flagged CORRUPTED on gen.json"
else
  bad "whole-file exemption baseline: expected exit 1 + CORRUPTED:...gen.json..., got exit $status: $out"
fi

# ── (16) The whole-file exemption for gen.json must NOT mask a genuine
# corruption of shared.txt's own added line in the same rebase — proving the
# exemption is scoped to exactly the named path, never a blanket loosening
# of the whole comparison. ──────────────────────────────────────────────────
git -C "$repo2" checkout -q -b rebased-regenerated-other-corrupted main
printf '{"hash":"ZZZ"}\n' > "$repo2/gen.json"
printf 'shared-base\n' > "$repo2/shared.txt"   # feature-line dropped: real corruption
git -C "$repo2" add gen.json shared.txt
git -C "$repo2" commit -q -m "rebased: gen.json regenerated (fine), shared.txt corrupted (feature-line missing)"

out="$(cd "$repo2" && bash "$script" "$base2_sha" "$feature2_sha" "$known_rewrites2" 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == CORRUPTED:*shared.txt* && "$out" != *gen.json* ]]; then
  ok "whole-file exemption does not mask corruption in a DIFFERENT file: exit 1, CORRUPTED names shared.txt only"
else
  bad "whole-file exemption over-masked corruption: expected exit 1 + CORRUPTED:...shared.txt... (no gen.json), got exit $status: $out"
fi

# ── (17) The existence check still applies to a FILE-exempted path: if
# gen.json is deleted entirely from the post-rebase tree, the exemption must
# NOT suppress the "kept/added file vanished" corruption signal. ───────────
git -C "$repo2" checkout -q -b rebased-regenerated-deleted main
printf 'shared-base\nfeature-line\n' > "$repo2/shared.txt"
git -C "$repo2" add shared.txt
git -C "$repo2" commit -q -m "rebased: gen.json deleted entirely, shared.txt intact"

out="$(cd "$repo2" && bash "$script" "$base2_sha" "$feature2_sha" "$known_rewrites2" 2>&1)"
status=$?
if [[ $status -eq 1 && "$out" == *"gen.json(missing)"* ]]; then
  ok "whole-file exemption does not bypass the file-existence check: exit 1, gen.json(missing) still flagged"
else
  bad "whole-file exemption incorrectly bypassed existence check: expected exit 1 + gen.json(missing), got exit $status: $out"
fi

echo
if (( fail > 0 )); then
  printf '%sFAIL%s  %d test(s) failed (%d passed)\n' "$RED" "$RESET" "$fail" "$pass" >&2
  exit 1
else
  printf '%sPASS%s  all %d test(s) passed\n' "$GREEN" "$RESET" "$pass"
  exit 0
fi

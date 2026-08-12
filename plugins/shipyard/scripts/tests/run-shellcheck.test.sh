#!/usr/bin/env bash
# Test: run-shellcheck.sh — the pinned-shellcheck-version wrapper (issue
# #1296).
#
# Background: CI installed shellcheck via apt (an older release than most
# contributors' locally-installed shellcheck), and the two versions
# disagreed on real findings (SC2015 stopped being flagged in newer
# releases). A worker's full local battery could pass clean and still fail
# CI's required `shellcheck` gate on the identical script. run-shellcheck.sh
# is now the single executable source of truth for "which shellcheck runs"
# — every caller (the `shellcheck` CI job, and scripts/tests/shellcheck.test.sh,
# which is itself discovered by the `bash test suites` and `shell tests` CI
# jobs) invokes this wrapper instead of a bare `shellcheck` on PATH, so both
# sides resolve the identical, checksum-verified, pinned binary.
#
# This suite exercises the wrapper's decision logic WITHOUT touching the
# real network — every test stubs `curl`, `uname`, and/or a fallback
# `shellcheck` via a PATH prefix, so the suite is fast and deterministic
# regardless of what's actually installed on the machine running it. The
# one thing this suite deliberately does NOT do is validate a real
# successful download against the live GitHub Releases checksums (that's
# exercised by hand when the pin is chosen/bumped, and implicitly by the
# `shellcheck` CI job and shellcheck.test.sh's own real runs) — a
# checksum-verified download inherently can't be faked without also faking
# the checksum table, which would defeat the point of the test.
#
# Run with:
#   bash plugins/shipyard/scripts/tests/run-shellcheck.test.sh

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

script="$repo_root/plugins/shipyard/scripts/run-shellcheck.sh"

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

ok()  { pass=$((pass + 1)); echo "${GREEN}PASS${RESET}: $1"; }
bad() { fail=$((fail + 1)); echo "${RED}FAIL${RESET}: $1"; }

if [[ ! -x "$script" ]]; then
  echo "FAIL: $script not found or not executable" >&2
  exit 1
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/run-shellcheck-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

# A real script for the wrapper to lint. Deliberately has no findings — this
# suite is about the wrapper's binary-resolution logic, not shellcheck's own
# detection rules (shellcheck.test.sh already covers that end-to-end).
target="$workdir/target.sh"
cat > "$target" <<'EOF'
#!/usr/bin/env bash
echo "hello"
EOF

# --- stub helpers -----------------------------------------------------
# Each stub_* function builds a fresh bin/ dir under $workdir containing
# only the fake executables a test needs, so PATH="<stub-bin>:$real_path"
# controls exactly which real tools remain reachable (uname, tar, awk,
# shasum/sha256sum, mktemp, chmod, mv, cp, mkdir, dirname, bash all stay on
# the real PATH — only curl/shellcheck/uname get shadowed per test).

new_stub_bin() {
  local dir="$workdir/stubbin-$RANDOM"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

write_exe() {
  local path="$1"
  cat > "$path"
  chmod +x "$path"
}

# curl that always fails (simulates no network / GitHub Releases
# unreachable).
stub_curl_fail() {
  local dir="$1"
  write_exe "$dir/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
}

# curl that "succeeds" but writes garbage bytes to the -o target, so any
# checksum comparison against the real pinned sha256 fails. Used to prove
# the checksum-mismatch path is a hard failure, not a fallback trigger.
stub_curl_garbage() {
  local dir="$1"
  write_exe "$dir/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && printf 'not a real shellcheck tarball' > "$out"
exit 0
EOF
}

# curl that must NEVER be invoked — writes a sentinel file if it is, so a
# test can assert it was skipped entirely (e.g. an unsupported platform
# should never attempt a download).
stub_curl_must_not_run() {
  local dir="$1" sentinel="$2"
  write_exe "$dir/curl" <<EOF
#!/usr/bin/env bash
touch "$sentinel"
exit 7
EOF
}

# uname reporting a given (os, arch) pair, for deterministic platform_asset()
# testing independent of the machine actually running this suite.
stub_uname() {
  local dir="$1" os="$2" arch="$3"
  write_exe "$dir/uname" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -s) echo "$os" ;;
  -m) echo "$arch" ;;
  *) echo "$os" ;;
esac
EOF
}

# A fake "pinned-version" binary for the cache-hit fast path: reports
# exactly PINNED_VERSION on --version, and on any other invocation echoes
# its arguments (so a test can assert forwarding) and exits with a
# caller-chosen code.
write_fake_shellcheck() {
  local path="$1" version="$2" exit_code="${3:-0}"
  write_exe "$path" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  echo "ShellCheck - shell script analysis tool"
  echo "version: $version"
  exit 0
fi
echo "FAKE_SHELLCHECK_INVOKED_WITH:\$*"
exit $exit_code
EOF
}

# ------------------------------------------------------------------------
# Test 1: no arguments -> usage error, exit 2.
# ------------------------------------------------------------------------
out="$("$script" 2>&1)"
rc=$?
if [[ "$rc" -eq 2 && "$out" == usage:* ]]; then
  ok "no arguments -> exit 2 with a usage message"
else
  bad "no arguments -> expected exit 2 + usage message, got exit $rc: $out"
fi

# ------------------------------------------------------------------------
# Test 2: --print-asset resolves known platform combinations.
# ------------------------------------------------------------------------
check_asset() {
  local os="$1" arch="$2" expect="$3"
  local bin; bin="$(new_stub_bin)"
  stub_uname "$bin" "$os" "$arch"
  local got; got="$(PATH="$bin:$PATH" "$script" --print-asset 2>/dev/null)"
  local rc=$?
  if [[ "$got" == "$expect" && "$rc" -eq 0 ]]; then
    ok "--print-asset ($os/$arch) -> $expect"
  else
    bad "--print-asset ($os/$arch) -> expected '$expect' exit 0, got '$got' exit $rc"
  fi
}
check_asset "Darwin" "arm64"   "darwin.aarch64"
check_asset "Darwin" "x86_64"  "darwin.x86_64"
check_asset "Linux"  "x86_64"  "linux.x86_64"
check_asset "Linux"  "aarch64" "linux.aarch64"

# Unsupported platform -> "unsupported", exit 1.
bin="$(new_stub_bin)"
stub_uname "$bin" "SunOS" "sparc"
got="$(PATH="$bin:$PATH" "$script" --print-asset 2>/dev/null)"
rc=$?
if [[ "$got" == "unsupported" && "$rc" -eq 1 ]]; then
  ok "--print-asset (SunOS/sparc) -> unsupported, exit 1"
else
  bad "--print-asset (SunOS/sparc) -> expected 'unsupported' exit 1, got '$got' exit $rc"
fi

# ------------------------------------------------------------------------
# Test 3: cache-hit fast path — a cached binary already reporting the
# pinned version is used directly, WITHOUT touching curl at all, and
# arguments are forwarded verbatim.
# ------------------------------------------------------------------------
{
  cache="$workdir/cache3"
  bin="$(new_stub_bin)"
  pinned_version="$(grep -m1 '^PINNED_VERSION=' "$script" | cut -d'"' -f2)"
  cached_bin="$cache/v${pinned_version}/darwin.aarch64/shellcheck"
  mkdir -p "$(dirname "$cached_bin")"
  write_fake_shellcheck "$cached_bin" "$pinned_version" 0
  stub_uname "$bin" "Darwin" "arm64"
  sentinel="$workdir/curl-must-not-run-3.marker"
  stub_curl_must_not_run "$bin" "$sentinel"

  out="$(SHIPYARD_SHELLCHECK_CACHE_DIR="$cache" PATH="$bin:$PATH" "$script" "$target" "another-arg" 2>&1)"
  rc=$?
  if [[ -f "$sentinel" ]]; then
    bad "cache-hit fast path invoked curl when it should have used the cached binary"
  elif [[ "$rc" -eq 0 && "$out" == *"FAKE_SHELLCHECK_INVOKED_WITH:$target another-arg"* ]]; then
    ok "cache-hit fast path uses the cached pinned binary and forwards all arguments"
  else
    bad "cache-hit fast path: expected forwarded-args invocation exit 0, got exit $rc: $out"
  fi
}

# ------------------------------------------------------------------------
# Test 4: checksum mismatch on a fresh download is a hard failure (exit 4)
# — never silently falls back to a system shellcheck, even if one exists.
# ------------------------------------------------------------------------
{
  cache="$workdir/cache4"
  bin="$(new_stub_bin)"
  stub_uname "$bin" "Darwin" "arm64"
  stub_curl_garbage "$bin"
  # A system shellcheck IS present here — the mismatch must still win.
  write_fake_shellcheck "$bin/shellcheck" "99.99.99" 0

  out="$(SHIPYARD_SHELLCHECK_CACHE_DIR="$cache" PATH="$bin:$PATH" "$script" "$target" 2>&1)"
  rc=$?
  if [[ "$rc" -eq 4 && "$out" == *"CHECKSUM MISMATCH"* && "$out" != *FAKE_SHELLCHECK_INVOKED* ]]; then
    ok "checksum mismatch on download -> exit 4, never falls back to system shellcheck"
  else
    bad "checksum mismatch: expected exit 4 + CHECKSUM MISMATCH + no fallback invocation, got exit $rc: $out"
  fi
}

# ------------------------------------------------------------------------
# Test 5: download fails (offline) but a system shellcheck exists on PATH
# -> loud warning + fallback to the system binary, findings still surface.
# ------------------------------------------------------------------------
{
  cache="$workdir/cache5"
  bin="$(new_stub_bin)"
  stub_uname "$bin" "Darwin" "arm64"
  stub_curl_fail "$bin"
  write_fake_shellcheck "$bin/shellcheck" "0.11.0" 1

  out="$(SHIPYARD_SHELLCHECK_CACHE_DIR="$cache" PATH="$bin:$PATH" "$script" "$target" 2>&1)"
  rc=$?
  if [[ "$rc" -eq 1 && "$out" == *"WARNING"* && "$out" == *"0.11.0"* && "$out" == *FAKE_SHELLCHECK_INVOKED* ]]; then
    ok "download failure + system fallback present -> warns loudly and uses the fallback (exit forwarded)"
  else
    bad "download failure + fallback: expected exit 1 + WARNING + fallback invocation, got exit $rc: $out"
  fi
}

# ------------------------------------------------------------------------
# Test 6: download fails AND no system shellcheck on PATH -> exit 3
# (environment-incomplete, not a lint failure — the local-skip signal).
# ------------------------------------------------------------------------
{
  cache="$workdir/cache6"
  bin="$(new_stub_bin)"
  stub_uname "$bin" "Darwin" "arm64"
  stub_curl_fail "$bin"

  # Build a PATH containing ONLY this stub dir plus the bare minimum real
  # tools the wrapper itself needs (uname is stubbed above; curl is stubbed
  # to fail above) — critically, excluding any directory that might carry a
  # real `shellcheck`.
  real_tools_dir="$(new_stub_bin)"
  for tool in tar mktemp awk mkdir chmod mv cp dirname bash sha256sum shasum; do
    real_path="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$real_path" "$real_tools_dir/$tool"
  done

  out="$(SHIPYARD_SHELLCHECK_CACHE_DIR="$cache" PATH="$bin:$real_tools_dir" "$script" "$target" 2>&1)"
  rc=$?
  if [[ "$rc" -eq 3 && "$out" == *"nothing to run against"* ]]; then
    ok "download failure + no system fallback -> exit 3"
  else
    bad "download failure + no fallback: expected exit 3, got exit $rc: $out"
  fi
}

# ------------------------------------------------------------------------
# Test 7: unsupported platform + system fallback present -> uses the
# fallback WITHOUT ever attempting a download (platform_asset() fails
# before download_pinned_binary() would even be reachable).
# ------------------------------------------------------------------------
{
  cache="$workdir/cache7"
  bin="$(new_stub_bin)"
  stub_uname "$bin" "SunOS" "sparc"
  sentinel="$workdir/curl-must-not-run-7.marker"
  stub_curl_must_not_run "$bin" "$sentinel"
  write_fake_shellcheck "$bin/shellcheck" "1.2.3" 0

  out="$(SHIPYARD_SHELLCHECK_CACHE_DIR="$cache" PATH="$bin:$PATH" "$script" "$target" 2>&1)"
  rc=$?
  if [[ -f "$sentinel" ]]; then
    bad "unsupported platform attempted a download instead of skipping straight to fallback"
  elif [[ "$rc" -eq 0 && "$out" == *"WARNING"* && "$out" == *FAKE_SHELLCHECK_INVOKED* ]]; then
    ok "unsupported platform -> warns and falls back to system shellcheck without attempting a download"
  else
    bad "unsupported platform: expected exit 0 + WARNING + fallback invocation, got exit $rc: $out"
  fi
}

echo
echo "----------------------------------------"
echo "run-shellcheck.test.sh: ${pass} passed, ${fail} failed"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0

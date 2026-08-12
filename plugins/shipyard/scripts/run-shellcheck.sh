#!/usr/bin/env bash
# run-shellcheck.sh — invoke a PINNED shellcheck version, resolved and
# verified the same way regardless of whether the caller is CI or a
# developer's own machine.
#
# This script is the SINGLE EXECUTABLE SOURCE OF TRUTH for "which shellcheck
# runs" in this repo. Every caller — the `shellcheck` CI job
# (.github/workflows/shellcheck.yml) and the local/CI test suite
# (scripts/tests/shellcheck.test.sh, which also runs inside the `bash test
# suites` and `shell tests` CI jobs) — invokes THIS script instead of the
# bare `shellcheck` binary on PATH. Neither restates a version number.
#
# Background (issue #1296) — the "silent divergence" this closes
# --------------------------------------------------------------
# Before this script existed, every caller invoked whatever `shellcheck`
# happened to be on PATH: CI installed it fresh via an apt-get package
# install (Ubuntu 24.04's `ubuntu-latest` currently ships 0.9.0-1), while
# a developer's own machine had whatever their package manager (Homebrew,
# etc.) last installed — commonly a much newer release. The two versions do
# not agree on every finding: SC2015 ("A && B || C is not if-then-else") is
# flagged by 0.9.0 and by 0.10.0, but 0.11.0 stopped flagging the same
# pattern entirely (confirmed by hand: `shellcheck 0.11.0` returns clean,
# exit 0, on a script containing `git checkout main && git pull || true`;
# `shellcheck 0.10.0` and 0.9.0 both flag it as SC2015). A worker whose local
# `shellcheck` is 0.11.0-or-newer can run the full local battery green and
# still fail CI's `shellcheck` gate — and because `shellcheck.test.sh` also
# runs inside the `bash test suites` and `shell tests` jobs, one version
# mismatch cascades into three required-check failures at once. See the
# issue for the concrete repro: a `fix-rebase` worker's full local battery
# (140 suites + shellcheck across 196 scripts, 0 findings) still failed all
# three checks on the exact same head, costing a full `fix-checks-only`
# diagnostic dispatch to trace back to this.
#
# Why pin 0.10.0 rather than "whatever's newest" or "whatever CI's apt has"
# -----------------------------------------------------------------------
# Pinning UP to the newest release (0.11.0 as of this writing) is the LAXER
# answer for the exact finding that motivated this fix — SC2015 is a
# legitimate finding (a real `&&`/`||` compound-command bug shipped in this
# repo and was only caught because CI's older shellcheck still flagged it),
# so silently adopting the version that stops flagging it would trade a
# false-negative divergence for a permanent false-negative. Pinning to
# apt's exact 0.9.0-1 is impractical to *download* deterministically outside
# apt (and 0.9.0's GitHub release has no darwin.aarch64 asset at all — it
# predates Apple Silicon support, so an Apple Silicon developer's machine
# could never resolve it). 0.10.0 is the newest release that (a) still
# flags SC2015 on the pattern above, matching CI's current stricter
# behavior, and (b) publishes prebuilt binaries for every platform this repo's
# contributors and CI actually run on (linux.x86_64, linux.aarch64,
# darwin.x86_64, darwin.aarch64). Bump PINNED_VERSION deliberately, in its
# own PR, if a future shellcheck release is worth adopting — don't drift.
#
# How agreement is achieved: BY CONSTRUCTION, not by convention
# ---------------------------------------------------------------
# This script downloads (or reuses a previously-downloaded, checksum-verified
# copy of) the exact pinned shellcheck release for the current OS/arch from
# GitHub Releases, and executes THAT binary — never whatever `shellcheck`
# happens to be on PATH. CI no longer runs `apt-get install shellcheck` at
# all (removed from shellcheck.yml); it gets the same pinned binary this
# script would give a developer. This means "I ran shellcheck locally and it
# was clean" and "CI's shellcheck job passed" are backed by the identical
# binary, not two independently-updating ones that happen to usually agree.
#
# A worker on a machine with a newer system shellcheck does NOT need to
# manually install anything — this script does the pinning transparently.
#
# Fallback posture (when the pinned binary cannot be resolved — no network,
# GitHub Releases unreachable, or an unsupported platform): fall back to
# whatever `shellcheck` is on PATH, but print a LOUD, impossible-to-miss
# warning naming both the pinned version this repo expects and the fallback
# version actually used, so a divergence remains diagnosable in one look
# even on the degraded path. A checksum MISMATCH on a successful download,
# by contrast, is never silently downgraded to a fallback — that's a
# possible supply-chain issue, not an availability problem, and is always a
# hard failure.
#
# Usage:
#   run-shellcheck.sh <script> [<script> ...]
#     -> resolves the pinned shellcheck binary (downloading/caching it if
#        needed) and execs it with all arguments forwarded unchanged.
#
# Exit codes:
#   0    shellcheck ran and found nothing (or the caller's own scan reported
#        no findings) — forwarded verbatim from the resolved shellcheck.
#   1    shellcheck ran and reported findings — forwarded verbatim.
#   2    usage error (no arguments).
#   3    could not resolve ANY shellcheck binary — pinned download failed
#        (no network / GitHub Releases unreachable / unsupported platform)
#        AND no system `shellcheck` fallback was found on PATH either. This
#        is an environment-incomplete signal, not a lint failure — callers
#        that want "skip gracefully when shellcheck can't be resolved at
#        all" (e.g. a contributor's offline machine) branch on exit 3
#        specifically. A CI job that hits this should NOT be written to
#        treat 3 as skippable — losing network access to GitHub Releases in
#        CI is itself worth failing loudly on, matching this repo's existing
#        "fail fast rather than silently pass" convention for a misconfigured
#        glob (see shellcheck.yml's own "No shell scripts found" guard).
#   4    downloaded tarball's SHA-256 did NOT match the pinned checksum.
#        Hard failure, never silently falls back — a checksum mismatch on a
#        pinned download is treated as a possible supply-chain compromise,
#        not a transient unavailability.

set -uo pipefail

PINNED_VERSION="0.10.0"

# sha256 checksums for the exact PINNED_VERSION release tarballs, computed
# by hand against the real GitHub Releases assets at
# https://github.com/koalaman/shellcheck/releases/tag/v0.10.0 when this pin
# was chosen. Re-derive and update ALL FOUR when PINNED_VERSION changes —
# never carry a checksum forward for a version it wasn't computed against.
checksum_for_asset() {
  case "$1" in
    darwin.aarch64) printf '%s\n' "bbd2f14826328eee7679da7221f2bc3afb011f6a928b848c80c321f6046ddf81" ;;
    darwin.x86_64)  printf '%s\n' "ef27684f23279d112d8ad84e0823642e43f838993bbb8c0963db9b58a90464c2" ;;
    linux.aarch64)  printf '%s\n' "324a7e89de8fa2aed0d0c28f3dab59cf84c6d74264022c00c22af665ed1a09bb" ;;
    linux.x86_64)   printf '%s\n' "6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87" ;;
    *) return 1 ;;
  esac
}

# Map `uname -s`/`uname -m` to shellcheck's release-asset platform suffix.
# Prints nothing (and returns 1) for a platform we don't ship a checksum
# for — the caller falls back to PATH in that case rather than downloading
# an unverified binary.
platform_asset() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *) return 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) arch="aarch64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *) return 1 ;;
  esac
  printf '%s.%s\n' "$os" "$arch"
}

cache_dir() {
  printf '%s\n' "${SHIPYARD_SHELLCHECK_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/shipyard/shellcheck}"
}

# Fast path: a previously downloaded + verified binary already sitting in
# the cache, self-reporting the exact pinned version. No network touched.
try_cached_binary() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  local reported
  reported="$("$bin" --version 2>/dev/null | awk '/^version:/ {print $2}')"
  [ "$reported" = "$PINNED_VERSION" ]
}

# Download + verify + install the pinned binary for `$asset` into `$bin`.
# Returns 0 on success, 1 on a recoverable failure (network/404 — caller may
# fall back to PATH), 4 on a checksum mismatch (never recoverable — caller
# must hard-fail, not fall back).
download_pinned_binary() {
  local asset="$1" bin="$2" expected_sha
  expected_sha="$(checksum_for_asset "$asset")" || return 1

  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/shipyard-shellcheck.XXXXXX")" || return 1
  # shellcheck disable=SC2064
  # rationale: capture $stage's current value now, not at trap-fire time.
  trap "rm -rf '$stage'" RETURN

  local tarball_name="shellcheck-v${PINNED_VERSION}.${asset}.tar.xz"
  local url="https://github.com/koalaman/shellcheck/releases/download/v${PINNED_VERSION}/${tarball_name}"
  local tarball="${stage}/${tarball_name}"

  if ! curl -fsSL --max-time 60 -o "$tarball" "$url" 2>/dev/null; then
    return 1
  fi

  local actual_sha
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha="$(sha256sum "$tarball" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual_sha="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  else
    echo "run-shellcheck: neither sha256sum nor shasum is available — cannot verify the pinned download, refusing to use an unverified binary" >&2
    return 1
  fi

  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "run-shellcheck: CHECKSUM MISMATCH for ${tarball_name}" >&2
    echo "run-shellcheck:   expected sha256 ${expected_sha}" >&2
    echo "run-shellcheck:   got      sha256 ${actual_sha}" >&2
    echo "run-shellcheck: refusing to use this binary — this is a hard failure, not falling back to a system shellcheck" >&2
    return 4
  fi

  if ! tar -xf "$tarball" -C "$stage"; then
    return 1
  fi

  local extracted="${stage}/shellcheck-v${PINNED_VERSION}/shellcheck"
  [ -x "$extracted" ] || return 1

  mkdir -p "$(dirname "$bin")" || return 1
  cp "$extracted" "${bin}.tmp.$$" || return 1
  chmod +x "${bin}.tmp.$$" || return 1
  mv -f "${bin}.tmp.$$" "$bin" || return 1
  return 0
}

main() {
  # Debug/test entrypoint: print the resolved platform-asset name (or
  # "unsupported") and exit, without touching the network or executing
  # anything. Lets scripts/tests/run-shellcheck.test.sh exercise
  # platform_asset()'s OS/arch mapping deterministically by stubbing `uname`
  # on PATH, instead of only being reachable via a real download.
  if [ "${1:-}" = "--print-asset" ]; then
    if asset="$(platform_asset)"; then
      printf '%s\n' "$asset"
      exit 0
    else
      printf 'unsupported\n'
      exit 1
    fi
  fi

  if [ "$#" -eq 0 ]; then
    echo "usage: $0 <script> [<script> ...]" >&2
    exit 2
  fi

  local asset bin resolved_bin resolved_label

  if asset="$(platform_asset)"; then
    bin="$(cache_dir)/v${PINNED_VERSION}/${asset}/shellcheck"
    if try_cached_binary "$bin"; then
      resolved_bin="$bin"
      resolved_label="pinned v${PINNED_VERSION} (cached)"
    else
      local dl_rc=0
      download_pinned_binary "$asset" "$bin" || dl_rc=$?
      if [ "$dl_rc" -eq 4 ]; then
        exit 4
      elif [ "$dl_rc" -eq 0 ] && try_cached_binary "$bin"; then
        resolved_bin="$bin"
        resolved_label="pinned v${PINNED_VERSION} (freshly downloaded)"
      fi
    fi
  fi

  if [ -z "${resolved_bin:-}" ]; then
    # Either an unsupported platform, or the pinned download failed for a
    # recoverable reason (no network, GitHub Releases unreachable). Fall
    # back to PATH — loudly.
    if command -v shellcheck >/dev/null 2>&1; then
      resolved_bin="$(command -v shellcheck)"
      local fallback_version
      fallback_version="$("$resolved_bin" --version 2>/dev/null | awk '/^version:/ {print $2}')"
      resolved_label="SYSTEM FALLBACK ${fallback_version:-unknown} — could not resolve pinned v${PINNED_VERSION}"
      {
        echo "run-shellcheck: WARNING — could not resolve pinned shellcheck v${PINNED_VERSION} (no network, GitHub Releases unreachable, or unsupported platform)."
        echo "run-shellcheck: WARNING — falling back to system shellcheck ${fallback_version:-<unknown version>} at ${resolved_bin}."
        echo "run-shellcheck: WARNING — findings may diverge from CI, which pins v${PINNED_VERSION}. Re-run once network is available to get the pinned binary."
      } >&2
    else
      echo "run-shellcheck: could not resolve pinned shellcheck v${PINNED_VERSION} (no network / unsupported platform) AND no system shellcheck is on PATH — nothing to run against." >&2
      exit 3
    fi
  fi

  echo "run-shellcheck: using shellcheck ${resolved_label} at ${resolved_bin}" >&2
  exec "$resolved_bin" "$@"
}

main "$@"

#!/usr/bin/env bash
# Test: every shell script under plugins/ must pass `shellcheck` cleanly
# (warnings or higher fail the test). Mirrors the CI gate in
# .github/workflows/shellcheck.yml so a developer can run the same check
# locally before pushing.
#
# Rationale: see issue #102. Plugin shell scripts handle inputs the plugin
# treats as untrusted; a quoting / command-injection regression must not be
# allowed to land silently. The CI workflow is the primary gate; this test
# duplicates it so the local test harness (`shell-tests` job, and `bash test
# suites` — both discover this file by glob) also flags it.
#
# Runs through run-shellcheck.sh, NOT a bare `shellcheck` on PATH (issue
# #1296) — that script resolves a PINNED shellcheck version (downloading
# and checksum-verifying it from GitHub Releases if not already cached),
# the same one the CI lint job now uses instead of whatever the CI
# runner's apt package last shipped. Before this, a developer's newer
# local install could report clean while CI's older apt-installed one
# flagged a real finding (SC2015) on the identical script — see
# run-shellcheck.sh's header for the confirmed repro. Routing this test
# through the same wrapper means "this test passed locally" and "CI's
# lint job passed" are backed by the identical binary.
#
# Skip behavior: if run-shellcheck.sh cannot resolve ANY shellcheck binary at
# all — no network to fetch the pinned release AND no system `shellcheck` on
# PATH to fall back to (its exit code 3) — the test prints a warning and
# exits 0. CI always has network access to GitHub Releases, so the gate
# still fires there (a CI-side network failure there is a loud CI failure,
# not a silent skip — run-shellcheck.sh's own header documents why). We
# don't want every contributor's local `bash *.test.sh` run to fail just
# because they're offline and have never installed shellcheck.

set -u

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

# Locate the repo root by walking up from this test file until we find
# `.shellcheckrc` (or a `.git` directory as a fallback). We can't just rely on
# `git rev-parse` because the test must work inside CI's checkout AND inside
# nested worktrees.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$here"
while [[ "$repo_root" != "/" ]]; do
  if [[ -f "$repo_root/.shellcheckrc" || -d "$repo_root/.git" ]]; then
    break
  fi
  repo_root="$(dirname "$repo_root")"
done

if [[ "$repo_root" == "/" ]]; then
  printf '%sFAIL%s  could not locate repo root from %s\n' "$RED" "$RESET" "$here" >&2
  exit 1
fi

runner="$repo_root/plugins/shipyard/scripts/run-shellcheck.sh"
if [[ ! -x "$runner" ]]; then
  printf '%sFAIL%s  run-shellcheck.sh not found (or not executable) at %s\n' \
    "$RED" "$RESET" "$runner" >&2
  exit 1
fi

# Collect every *.sh under plugins/. Use a plain newline-delimited list (no
# `mapfile`) so the test works on macOS's bundled bash 3.2 too — none of the
# script paths contain whitespace, so newline splitting is safe.
scripts_list=$(cd "$repo_root" && find plugins -type f -name '*.sh' | sort)

if [[ -z "$scripts_list" ]]; then
  printf '%sFAIL%s  no shell scripts found under %s/plugins — find glob is broken.\n' \
    "$RED" "$RESET" "$repo_root" >&2
  exit 1
fi

count=$(printf '%s\n' "$scripts_list" | wc -l | tr -d ' ')
printf 'Linting %s script(s) under %s/plugins/:\n' "$count" "$repo_root"
printf '%s\n' "$scripts_list" | sed 's/^/  /'

# Run the pinned-version wrapper on all scripts as a single invocation so it
# picks up the .shellcheckrc at $repo_root exactly as a bare `shellcheck
# <scripts...>` would. `xargs` bundles the whole script list into one
# invocation (well under ARG_MAX for this repo's script count), so its exit
# code is run-shellcheck.sh's own exit code, not a synthesized batch code.
sc_rc=0
printf '%s\n' "$scripts_list" | (cd "$repo_root" && xargs "$runner") || sc_rc=$?

case "$sc_rc" in
  0)
    printf '%sPASS%s  shellcheck clean across %s script(s).\n' \
      "$GREEN" "$RESET" "$count"
    exit 0
    ;;
  3)
    # run-shellcheck.sh could not resolve ANY shellcheck binary — no network
    # to fetch the pinned release, and no system shellcheck on PATH either.
    # CI always has network, so the gate still fires there; a local
    # contributor who's offline and has never installed shellcheck
    # shouldn't be blocked by this test suite for it.
    printf '%sSKIP%s  could not resolve any shellcheck binary locally (offline, and no system shellcheck installed) — CI will still gate this.\n' \
      "$YELLOW" "$RESET"
    exit 0
    ;;
  4)
    # Pinned download's checksum did not match — a possible supply-chain
    # issue, not a lint finding. Never silently pass this.
    printf '%sFAIL%s  pinned shellcheck download failed checksum verification — see output above.\n' \
      "$RED" "$RESET" >&2
    exit 1
    ;;
  *)
    printf '%sFAIL%s  shellcheck reported findings — see above.\n' "$RED" "$RESET" >&2
    exit 1
    ;;
esac

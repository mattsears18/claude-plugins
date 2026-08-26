#!/usr/bin/env bash
# verify-new-dep-versions.sh — verify a newly-added dependency's written
# version against the authoritative registry, before `gh pr create`.
#
# Background (issue #1046, a follow-up to #1045): the shipyard:adding-
# dependencies skill (plugins/shipyard/skills/adding-dependencies/SKILL.md)
# tells a worker to look up a new dependency's current stable version before
# writing it down, across every manifest class it names. That rule is prose
# plus a PR-body convention ("record the resolved version") — nothing
# verified the claim, so a worker that silently wrote a stale/remembered
# version produced a PR indistinguishable from a compliant one.
#
# This is the phase-1 slice: parse `git diff <base>...HEAD` (or a fixture
# diff, for hermetic testing) for newly-ADDED dependency lines. Two classes
# get a hard, online, registry-comparison check:
#   - npm/npx (package.json entries, inline `npx <tool>@<version>` /
#     `pnpm dlx` / `yarn dlx` invocations) — via `npm view <pkg> version`
#   - GitHub Actions `uses: <owner>/<action>@<ref>` pins — via
#     `gh api repos/<owner>/<action>/releases/latest`
# Every other manifest class the skill names (pip, Go, Cargo, Gemfile,
# Gradle, CocoaPods, Dockerfile FROM, .nvmrc/.tool-versions) — and the two
# classes above when the npm/gh CLI or network isn't available — fall back
# to the OFFLINE check: does the PR body record a resolved version for that
# dependency, per the skill's step 3? That fallback only skips-with-note; it
# never hard-fails. Registry comparison for those remaining ecosystems is
# phase 2 (see the "Out of scope" list below).
#
# The load-bearing peer/SDK carve-out (react, react-native,
# @react-native-firebase/*, expo-*) is honored: those packages always
# skip-with-note regardless of the registry gap, because they intentionally
# track a framework-required version, not "latest". A cooldown/carve-out
# note in the PR body (mentioning the dependency alongside a word like
# "cooldown", "carve-out", "peer", "SDK", "framework-required", or
# "min-release-age") is likewise accepted as a valid explanation for an
# otherwise-unexplained gap.
#
# Usage:
#   verify-new-dep-versions.sh <base-ref> [--pr-body-file <path>]
#   verify-new-dep-versions.sh --diff-file <path> [--pr-body-file <path>]
#
#   <base-ref>          A git ref to diff HEAD against (e.g. origin/main).
#                        Ignored when --diff-file is given.
#   --diff-file <path>  Read a unified diff from this file instead of
#                        running `git diff <base-ref>...HEAD` — used by the
#                        test suite to stay hermetic (no real git history
#                        needed) and available to any caller that already
#                        has the diff text on hand.
#   --pr-body-file <path>
#                        Path to the drafted PR body (e.g. the worker's own
#                        $WORKTREE_PATH/.shipyard-scratch/pr-body.md, per
#                        issue-work.md step 5's --body-file convention).
#                        Used for the offline fallback check and for the
#                        cooldown/carve-out-note explanation. Optional —
#                        when omitted, both checks degrease to "PR body
#                        does not record a resolved version" (a note, not a
#                        failure).
#
# Exit status:
#   0 — no unexplained gap (includes every skip-with-note / pass case)
#   1 — one or more newly-added npm/npx/Actions dependencies are >=1 major
#       behind the registry's current stable version, with no peer/SDK
#       carve-out and no explanatory PR-body note
#   2 — usage / environment error
#
# Out of scope for this phase (see issue #1046's own follow-up filed
# alongside it): registry-comparison (rather than the offline PR-body-record
# check) for pip, Go, Cargo, Gemfile, Gradle, CocoaPods, Dockerfile FROM,
# and .nvmrc/.tool-versions.

set -u

usage() {
  cat >&2 <<'EOF'
usage: verify-new-dep-versions.sh <base-ref> [--pr-body-file <path>]
       verify-new-dep-versions.sh --diff-file <path> [--pr-body-file <path>]

  Verifies newly-added dependency lines in a diff against the authoritative
  registry (npm + GitHub Actions `uses:` pins, hard-online) or the PR body
  (every other manifest class, offline fallback — skip-with-note only).

  <base-ref>              git ref to diff HEAD against (git diff <ref>...HEAD)
  --diff-file <path>      read a unified diff from a file instead of git
  --pr-body-file <path>   path to the drafted PR body (offline check input)

  Exit status: 0 = clean/explained, 1 = unexplained major-version gap,
  2 = usage/environment error. --help itself always exits 0 (#1550).
EOF
}

base_ref=""
diff_file=""
pr_body_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --diff-file)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      diff_file="$2"
      shift 2
      ;;
    --pr-body-file)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      pr_body_file="$2"
      shift 2
      ;;
    --*)
      echo "verify-new-dep-versions: unknown flag: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$base_ref" ]]; then
        echo "verify-new-dep-versions: unexpected extra argument: $1" >&2
        usage
        exit 2
      fi
      base_ref="$1"
      shift
      ;;
  esac
done

if [[ -z "$diff_file" && -z "$base_ref" ]]; then
  usage
  exit 2
fi

# --- Load the diff text -----------------------------------------------
if [[ -n "$diff_file" ]]; then
  if [[ ! -f "$diff_file" ]]; then
    echo "verify-new-dep-versions: --diff-file not found: $diff_file" >&2
    exit 2
  fi
  diff_text="$(cat "$diff_file")"
else
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "verify-new-dep-versions: not inside a git work tree" >&2
    exit 2
  fi
  if ! diff_text="$(git diff "${base_ref}...HEAD" 2>/dev/null)"; then
    echo "verify-new-dep-versions: git diff ${base_ref}...HEAD failed" >&2
    exit 2
  fi
fi

# --- Load the PR body (optional) ---------------------------------------
pr_body=""
if [[ -n "$pr_body_file" && -f "$pr_body_file" ]]; then
  pr_body="$(cat "$pr_body_file")"
fi

# --- CLI availability ----------------------------------------------------
npm_available=0
command -v npm >/dev/null 2>&1 && npm_available=1
gh_available=0
command -v gh >/dev/null 2>&1 && gh_available=1

# --- Helpers ---------------------------------------------------------

# A package/action name is peer/SDK-constrained — the framework-required
# version is correct by design, never "latest". Unconditional per the
# adding-dependencies skill.
is_carveout_pkg() {
  case "$1" in
    react|react-native) return 0 ;;
    @react-native-firebase/*) return 0 ;;
    expo|expo-*) return 0 ;;
    *) return 1 ;;
  esac
}

# Extract the leading run of digits anywhere in a version string
# ("^1.2.3" -> "1", "v7.0.1" -> "7", "~4.18.0" -> "4").
major_of() {
  if [[ "$1" =~ ([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Does the PR body mention this dependency alongside an explanatory word
# (cooldown / carve-out / peer / SDK / framework-required / min-release-age)?
pr_body_explains_gap() {
  local name="$1"
  [[ -n "$pr_body" && "$pr_body" == *"$name"* ]] || return 1
  [[ "$pr_body" =~ [Cc]ooldown|[Cc]arve-?out|[Pp]eer|SDK|sdk|[Ff]ramework-required|min-release-age ]]
}

# Does the PR body record *some* version for this dependency (offline
# fallback — best-effort, never gates a hard failure on its own)?
pr_body_records_version() {
  local name="$1"
  [[ -n "$pr_body" && "$pr_body" == *"$name"* ]]
}

violations=0
declare -a added_records=()

# bash 3.2 (macOS's default /usr/bin/bash) has no associative arrays
# (`declare -A`), so track the three membership sets ("removed npm deps",
# "removed Actions pins", "removed npx invocations", "already-added keys")
# as newline-delimited strings and test membership with `grep -qxF`.
seen_added=""
removed_npm=""
removed_actions=""
removed_npx=""

set_contains() {
  local set="$1" key="$2"
  [[ -n "$set" ]] || return 1
  printf '%s\n' "$set" | grep -qxF -- "$key"
}

set_add_seen_added() { seen_added="${seen_added}${1}
"; }
set_add_removed_npm() { removed_npm="${removed_npm}${1}
"; }
set_add_removed_actions() { removed_actions="${removed_actions}${1}
"; }
set_add_removed_npx() { removed_npx="${removed_npx}${1}
"; }

# npm reserved top-level package.json keys — a version-shaped string value
# under one of these is metadata, not a dependency ("version": "1.2.3" is
# the package's OWN version, not a new dep).
is_reserved_npm_key() {
  case "$1" in
    name|version|description|main|module|browser|types|typings|license| \
    private|engines|packageManager|workspaces|homepage|repository|keywords| \
    bugs|files|publishConfig|sideEffects|type|exports|bin|os|cpu|funding| \
    contributors|style|unpkg|jsdelivr|author)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

current_file=""

while IFS= read -r line; do
  case "$line" in
    "+++ "*)
      current_file="${line#+++ }"
      current_file="${current_file#b/}"
      continue
      ;;
    "--- "*|"diff --git "*|"index "*|"@@"*)
      continue
      ;;
  esac

  sign="${line:0:1}"
  [[ "$sign" == "+" || "$sign" == "-" ]] || continue
  content="${line:1}"

  # --- npm: package.json "<name>": "<version>" -------------------------
  if [[ "$current_file" == *package.json ]]; then
    if [[ "$content" =~ ^[[:space:]]*\"([A-Za-z0-9@/_.-]+)\"[[:space:]]*:[[:space:]]*\"([\^~]?[0-9][A-Za-z0-9._+-]*)\"[[:space:]]*,?[[:space:]]*$ ]]; then
      name="${BASH_REMATCH[1]}"
      ver="${BASH_REMATCH[2]}"
      if ! is_reserved_npm_key "$name"; then
        if [[ "$sign" == "-" ]]; then
          set_add_removed_npm "${current_file}|${name}"
        else
          key="npm|${current_file}|${name}"
          if ! set_contains "$seen_added" "$key"; then
            set_add_seen_added "$key"
            added_records+=("npm|${current_file}|${name}|${ver}")
          fi
        fi
      fi
    fi
    continue
  fi

  # --- GitHub Actions: uses: <owner>/<action>@<ref> ---------------------
  case "$current_file" in
    .github/workflows/*.yml|.github/workflows/*.yaml)
      if [[ "$content" =~ uses:[[:space:]]*([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)@([A-Za-z0-9._/-]+) ]]; then
        name="${BASH_REMATCH[1]}"
        ver="${BASH_REMATCH[2]}"
        if [[ "$sign" == "-" ]]; then
          set_add_removed_actions "${current_file}|${name}"
        else
          key="actions|${current_file}|${name}"
          if ! set_contains "$seen_added" "$key"; then
            set_add_seen_added "$key"
            added_records+=("actions|${current_file}|${name}|${ver}")
          fi
        fi
        continue
      fi
      ;;
  esac

  # --- inline npx/pnpm dlx/yarn dlx <tool>@<version> ---------------------
  if [[ "$content" =~ (npx|pnpm[[:space:]]+dlx|yarn[[:space:]]+dlx)[[:space:]]+([A-Za-z0-9@/_.-]+)@([A-Za-z0-9._-]+) ]]; then
    name="${BASH_REMATCH[2]}"
    ver="${BASH_REMATCH[3]}"
    if [[ "$sign" == "-" ]]; then
      set_add_removed_npx "${current_file}|${name}"
    else
      key="npx|${current_file}|${name}"
      if ! set_contains "$seen_added" "$key"; then
        set_add_seen_added "$key"
        added_records+=("npx|${current_file}|${name}|${ver}")
      fi
    fi
    continue
  fi

  # --- Every other manifest class the skill names — offline-only -------
  [[ "$sign" == "+" ]] || continue
  case "$current_file" in
    *requirements.txt)
      if [[ "$content" =~ ^([A-Za-z0-9_.-]+)(==|>=|~=)([A-Za-z0-9.]+) ]]; then
        added_records+=("other|${current_file}|${BASH_REMATCH[1]}|${BASH_REMATCH[3]}")
      fi
      ;;
    *pyproject.toml)
      if [[ "$content" =~ ^[[:space:]]*\"?([A-Za-z0-9_.-]+)\"?[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        added_records+=("other|${current_file}|${BASH_REMATCH[1]}|${BASH_REMATCH[2]}")
      fi
      ;;
    *go.mod)
      if [[ "$content" =~ ^[[:space:]]*([a-zA-Z0-9./_-]+)[[:space:]]+v([0-9][^[:space:]]*) ]]; then
        added_records+=("other|${current_file}|${BASH_REMATCH[1]}|v${BASH_REMATCH[2]}")
      fi
      ;;
    *Cargo.toml)
      if [[ "$content" =~ ^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        added_records+=("other|${current_file}|${BASH_REMATCH[1]}|${BASH_REMATCH[2]}")
      fi
      ;;
    *Gemfile)
      gemfile_re="gem[[:space:]]+['\"]([^'\"]+)['\"]"
      if [[ "$content" =~ $gemfile_re ]]; then
        added_records+=("other|${current_file}|${BASH_REMATCH[1]}|")
      fi
      ;;
    *build.gradle|*build.gradle.kts)
      gradle_re="['\"]([^:'\"]+):([^:'\"]+):([^'\")]+)['\"]"
      if [[ "$content" =~ $gradle_re ]]; then
        added_records+=("other|${current_file}|${BASH_REMATCH[1]}:${BASH_REMATCH[2]}|${BASH_REMATCH[3]}")
      fi
      ;;
    *Podfile)
      podfile_re="pod[[:space:]]+['\"]([^'\"]+)['\"]"
      if [[ "$content" =~ $podfile_re ]]; then
        added_records+=("other|${current_file}|${BASH_REMATCH[1]}|")
      fi
      ;;
    *Dockerfile|*Dockerfile.*)
      if [[ "$content" =~ ^FROM[[:space:]]+([^[:space:]:]+):([^[:space:]]+) ]]; then
        added_records+=("other|${current_file}|${BASH_REMATCH[1]}|${BASH_REMATCH[2]}")
      fi
      ;;
    *.nvmrc|*.tool-versions)
      if [[ -n "$content" ]]; then
        added_records+=("other|${current_file}|${current_file}|${content}")
      fi
      ;;
  esac
done <<< "$diff_text"

if [[ "${#added_records[@]}" -eq 0 ]]; then
  echo "verify-new-dep-versions: no newly-added dependency lines found — nothing to verify."
  exit 0
fi

for record in "${added_records[@]}"; do
  class="${record%%|*}"
  rest="${record#*|}"
  file="${rest%%|*}"
  rest="${rest#*|}"
  name="${rest%%|*}"
  version="${rest#*|}"

  case "$class" in
    npm)
      if set_contains "$removed_npm" "${file}|${name}"; then continue; fi
      ;;
    actions)
      if set_contains "$removed_actions" "${file}|${name}"; then continue; fi
      ;;
    npx)
      if set_contains "$removed_npx" "${file}|${name}"; then continue; fi
      ;;
  esac

  if [[ "$class" == "npm" || "$class" == "npx" || "$class" == "actions" ]]; then
    if is_carveout_pkg "$name"; then
      echo "  SKIP  ${name} (${file}): peer/SDK carve-out — framework-required version, not checked against latest."
      continue
    fi

    latest=""
    resolvable=0
    if [[ "$class" == "actions" ]]; then
      if [[ "$gh_available" -eq 1 ]]; then
        latest="$(gh api "repos/${name}/releases/latest" --jq .tag_name 2>/dev/null)"
        [[ -n "$latest" ]] && resolvable=1
      fi
    else
      if [[ "$npm_available" -eq 1 ]]; then
        latest="$(npm view "$name" version 2>/dev/null)"
        [[ -n "$latest" ]] && resolvable=1
      fi
    fi

    if [[ "$resolvable" -eq 0 ]]; then
      # CLI/network unavailable (or the lookup failed) — fall back to the
      # offline PR-body-record check. Never a hard failure.
      if pr_body_records_version "$name"; then
        echo "  NOTE  ${name} (${file}): registry lookup unavailable — PR body records a resolved version, offline check passed."
      else
        echo "  NOTE  ${name} (${file}): registry lookup unavailable and PR body does not record a resolved version — skip-with-note (not a failure)."
      fi
      continue
    fi

    written_major="$(major_of "$version")"
    latest_major="$(major_of "$latest")"

    if [[ -z "$written_major" || -z "$latest_major" ]]; then
      echo "  NOTE  ${name} (${file}): could not parse a major version from '${version}' vs '${latest}' — skip-with-note."
      continue
    fi

    gap=$(( latest_major - written_major ))
    if [[ "$gap" -ge 1 ]]; then
      if pr_body_explains_gap "$name"; then
        echo "  SKIP  ${name} (${file}): ${version} is ${gap} major(s) behind ${latest}, but the PR body explains the gap (cooldown/carve-out note)."
      else
        echo "  FAIL  ${name} (${file}): ${version} is ${gap} major(s) behind the registry's current stable ${latest}, and neither the peer/SDK carve-out nor a PR-body explanation applies." >&2
        violations=$((violations + 1))
      fi
    else
      echo "  PASS  ${name} (${file}): ${version} matches the current major (latest: ${latest})."
    fi
  else
    # Every other manifest class — offline fallback only, never a hard fail.
    if pr_body_records_version "$name"; then
      echo "  NOTE  ${name} (${file}): offline check — PR body records a resolved version."
    else
      echo "  NOTE  ${name} (${file}): offline check — PR body does not record a resolved version for this dependency (phase 2 will add registry comparison for this ecosystem; see https://github.com/mattsears18/shipyard/issues/1046)."
    fi
  fi
done

if [[ "$violations" -gt 0 ]]; then
  echo >&2
  echo "verify-new-dep-versions: ${violations} newly-added dependency(ies) have an unexplained >=1-major version gap." >&2
  echo "Look up the current stable version per shipyard:adding-dependencies before opening the PR, or add a PR-body note explaining the gap (peer/SDK carve-out or supply-chain cooldown)." >&2
  exit 1
fi

echo "verify-new-dep-versions: clean — no unexplained version gaps."
exit 0

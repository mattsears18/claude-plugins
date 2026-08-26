#!/usr/bin/env bash
# spec-skill-reference-scan.sh — assert that every `shipyard:<name>` a spec
# names actually resolves to a registered asset of this plugin.
#
# Background (issue #1468). This is the third member of the
# executable-by-proxy reference family #1467 opened:
#
#   scripts   — a fenced bash block tells a worker to RUN a path
#   fragments — a fenced bash block tells a worker to READ a path
#   skills    — a spec tells a worker to LOAD an asset BY NAME   <- this file
#
# Every mode shim's dispatch instructs the worker to load a skill by name
# ("load the `shipyard:worker-preamble` skill"), and the orchestrator routes
# dispatches to agents by name (`shipyard:fix-checks-worker`) and points humans
# at commands by name (`/shipyard:do-work`). Nothing asserted that any of those
# names resolve. Renaming or deleting `plugins/shipyard/skills/<name>/` would
# leave every live `Skill` invocation of it dangling with no CI signal at all —
# the same failure class as a deleted script, one layer up, and just as silent:
# a `Skill` call that names nothing does not fail the build, it fails a worker
# mid-dispatch.
#
# WHY THIS IS A SIBLING SCRIPT rather than a third class inside
# spec-script-reference-scan.sh: that scanner's whole traversal is "walk fenced
# bash blocks." Skill names are not paths, are not confined to fences, and need
# a namespace resolver rather than a path resolver — no part of the traversal,
# the token shape, the resolution table, or the allow directive is shared.
#
# WHAT IS CHECKED — a `shipyard:<name>` token ANYWHERE in a spec (prose,
# tables, fences alike; the reference is a name, not a path, so a fence
# boundary carries no meaning for it):
#
#   shipyard:<name>    must resolve to a registered skill, command, OR agent
#   /shipyard:<name>   must resolve to a registered skill or command
#
# The `shipyard:` namespace is SHARED across all three asset kinds, so the
# resolver spans all three even though #1468 framed the class as "skill names."
# Measured at #1468's baseline: the registry holds 55 assets (9 skills, 18
# commands, 28 agents) and the corpus cites 53 distinct names across 1070
# tokens — `shipyard:worker-preamble` is a skill, `shipyard:do-work` a command,
# `shipyard:issue-worker` an agent, and `shipyard:update-roadmap` is BOTH a
# skill and a command. A scanner that assumed "skill" for every token would
# false-positive on ~44 of the 53 cited names. What it asserts instead is that
# the named asset is registered SOMEWHERE in this plugin, which is the property
# a dangling reference actually violates.
#
# The slash-prefixed form is checked more strictly because a leading `/` is
# unambiguous: it is a slash-command invocation, and agents are not
# slash-invocable. That strictness is what caught the one live defect #1468
# found — `/shipyard:investigate`, cited twice in `commands/my-turn.md` as a
# command a human should run, which has never existed as a shipyard command
# (investigate is a `/do-work` MODE).
#
# The registry is built from the git INDEX, not the disk, for the same reason
# the script scanner asserts against the index: an untracked file in one
# working tree does not ship to a plugin install.
#
#   skill    plugins/shipyard/skills/<name>/SKILL.md
#   command  plugins/shipyard/commands/<name>.md        (top level only)
#   agent    plugins/shipyard/agents/<name>.md          (top level only)
#
# "Top level only" is load-bearing: `commands/do-work/setup/04-backlog-divert.md`
# and `agents/issue-worker/issue-work.md` are internal spec fragments reached by
# a path, NOT registered assets reachable by name, so folding them into the
# registry would let a genuinely dangling name resolve against an unrelated
# nested file.
#
# WHAT IS NOT CHECKED — deliberately:
#
#   - A `shipyard:` token followed by an uppercase letter or `_`. Registered
#     asset names in this plugin are lowercase-kebab without exception.
#   - A token preceded by an identifier character or `/` preceded by one —
#     `mattsears18/shipyard:` in a URL or repo coordinate is not a reference.
#
# False-positive guard — the `shipyard:` prefix is ALSO a GitHub label
# namespace in this repo, and a label is not a plugin asset. `shipyard:no-inline`
# and `shipyard:inline-eligible` (the inline-trivial fast-path's two human
# override labels) are the live examples. A file declares such tokens with an
# explicit directive placed anywhere in it:
#
#   <!-- spec-skill-reference-scan: allow shipyard:no-inline shipyard:inline-eligible -->
#
# The directive is FILE-scoped rather than line- or block-scoped because these
# tokens appear in running prose and list items, where an HTML comment on its
# own line would break the surrounding markdown. It is deliberately not
# repo-global: a new file naming a new non-asset token must declare it, so the
# exemption cannot silently spread.
#
# SCOPE: mechanical discovery over every git-tracked `*.md` under
# `plugins/shipyard/`, matching spec-script-reference-scan.sh.
#
# Usage:
#   bash plugins/shipyard/scripts/spec-skill-reference-scan.sh            # discovered
#   bash plugins/shipyard/scripts/spec-skill-reference-scan.sh <path>...  # explicit files
#   bash plugins/shipyard/scripts/spec-skill-reference-scan.sh --registry # print the registry
#
# Exit status: 0 = clean, 1 = at least one unregistered reference (prints
# file:line + the offending token), 2 = usage / environment error /
# anti-vacuity trip.

set -u

# Anti-vacuity floors. Two of them, and the reason is the lesson #1467 learned
# the hard way: a scanner has more than one independent matcher, and a floor on
# one says nothing about the others. Here the two are the TOKEN matcher (does
# the scan still find references?) and the REGISTRY builder (does it still know
# what a registered asset is?). A registry that silently emptied would flag
# everything — loud, self-announcing. A registry that silently over-matched, or
# a token matcher that silently stopped matching, would report a clean corpus
# over zero work. Both floors sit well below the baselines measured at #1468's
# fix time (1070 tokens, 55 registered assets), so ordinary churn never trips
# them. Enforced ONLY on a discovery run.
TOKEN_FLOOR=500
REGISTRY_FLOOR=20

usage() {
  cat >&2 <<'EOF'
usage: spec-skill-reference-scan.sh [--registry] [path ...]
       spec-skill-reference-scan.sh --help
  With no args, scans every git-tracked *.md under plugins/shipyard/ (see
  script header for scope rationale). With paths, scans exactly those files.
  --registry prints the resolved asset registry (one "<kind> <name>" per line)
  and exits 0.
  --help itself always exits 0, distinct from the usage/environment-error
  exit 2 below (#1550).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "spec-skill-reference-scan: not inside a git work tree" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"

discover() {
  local rel
  while IFS= read -r -d '' rel; do
    printf '%s\0' "$repo_root/$rel"
  done < <(git -C "$repo_root" ls-files -z -- 'plugins/shipyard/*.md')
}

# The registry, as "<kind> <name>" lines. Built from `git ls-files` (the index)
# and filtered to the exact depths documented in the header — `awk` rather than
# a git pathspec because git's `*` matches `/`, so 'commands/*.md' would sweep
# in every nested spec fragment.
build_registry() {
  git -C "$repo_root" ls-files -- 'plugins/shipyard/*' | awk '
    {
      n = split($0, p, "/")
      if (n == 5 && p[3] == "skills" && p[5] == "SKILL.md") { print "skill " p[4]; next }
      if (n == 4 && p[3] == "commands" && p[4] ~ /\.md$/) {
        sub(/\.md$/, "", p[4]); print "command " p[4]; next
      }
      if (n == 4 && p[3] == "agents" && p[4] ~ /\.md$/) {
        sub(/\.md$/, "", p[4]); print "agent " p[4]; next
      }
    }
  ' | sort -u
}

case "${1:-}" in
  --registry)
    build_registry
    exit 0
    ;;
esac

candidates=()
if [[ $# -gt 0 ]]; then
  candidates=("$@")
else
  while IFS= read -r -d '' f; do
    candidates+=("$f")
  done < <(discover)
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "spec-skill-reference-scan: discovered zero files under plugins/shipyard/ — the scanner is broken, not the corpus clean" >&2
  exit 2
fi

reg_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$reg_file" "$err_file"' EXIT

build_registry > "$reg_file"
registry_n="$(wc -l < "$reg_file" | tr -d ' ')"

if [[ "$registry_n" -eq 0 ]]; then
  echo "spec-skill-reference-scan: resolved zero registered assets under plugins/shipyard/ — the registry builder is broken, not the corpus clean" >&2
  exit 2
fi

# _scan_file <path> — findings to stdout, one per line. Prints a trailing
# `#tokens <n>` line to STDERR so the caller can total what was inspected.
# Returns 0 if clean, 1 if it found something.
_scan_file() {
  local file="$1"
  awk -v FILE="$file" -v REGFILE="$reg_file" '
    BEGIN {
      while ((getline regrow < REGFILE) > 0) {
        sep = index(regrow, " ")
        if (sep > 0) {
          kind = substr(regrow, 1, sep - 1)
          name = substr(regrow, sep + 1)
          KIND[name] = (name in KIND) ? KIND[name] "," kind : kind
          if (kind == "skill" || kind == "command") SLASHABLE[name] = 1
        }
      }
      close(REGFILE)

      TOK_RE = "/?shipyard:[a-z0-9][a-z0-9-]*"
      IDENT_RE = "[A-Za-z0-9_]"
      tokens = 0
      found_any = 0
    }

    # File-scoped allow directive. Every token it names is exempt for this file
    # only — see the header for why a GitHub label sharing the `shipyard:`
    # prefix is not a plugin asset.
    /<!--[[:space:]]*spec-skill-reference-scan:[[:space:]]*allow[[:space:]]/ {
      line = $0
      while (match(line, "shipyard:[a-z0-9][a-z0-9-]*")) {
        ALLOW[substr(line, RSTART, RLENGTH)] = 1
        line = substr(line, RSTART + RLENGTH)
      }
      next
    }

    {
      rest = $0
      consumed = 0
      while (match(rest, TOK_RE)) {
        tok = substr(rest, RSTART, RLENGTH)
        if (RSTART > 1) {
          prev = substr(rest, RSTART - 1, 1)
        } else if (consumed > 0) {
          # Start of a suffix left by a previous match; the real preceding
          # character belonged to that match, so this is mid-token.
          prev = "x"
        } else {
          prev = ""
        }

        rest = substr(rest, RSTART + RLENGTH)
        consumed = 1

        slashed = (substr(tok, 1, 1) == "/")
        bare = slashed ? substr(tok, 2) : tok
        name = substr(bare, 10)

        # `mattsears18/shipyard:` (a repo coordinate) and `xshipyard:` are not
        # references. For the slashed form the guard reads the char before the
        # slash, which is what distinguishes `/shipyard:do-work` from
        # `mattsears18/shipyard:...`.
        if (prev ~ IDENT_RE) continue
        # A trailing char that continues the name means the match was truncated
        # by the lowercase-kebab class (e.g. an uppercase or `_` spelling),
        # which the header documents as out of scope rather than a finding.
        nextc = substr(rest, 1, 1)
        if (nextc ~ IDENT_RE) continue

        if (bare in ALLOW) continue

        tokens++

        if (!(name in KIND)) {
          printf "%s:%d: unregistered-skill-reference — %s (no skill, command, or agent named %s is registered in plugins/shipyard/)\n", FILE, NR, tok, name
          found_any = 1
        } else if (slashed && !(name in SLASHABLE)) {
          printf "%s:%d: non-invocable-slash-reference — %s (resolves only to a %s, which is not slash-invocable)\n", FILE, NR, tok, KIND[name]
          found_any = 1
        }
      }
    }

    END {
      printf "#tokens %d\n", tokens > "/dev/stderr"
      exit (found_any ? 1 : 0)
    }
  ' "$file"
}

found=0
total_tokens=0

for f in "${candidates[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "spec-skill-reference-scan: no such file: $f" >&2
    exit 2
  fi
  if ! _scan_file "$f" 2>"$err_file"; then
    found=1
  fi
  nt="$(sed -n 's/^#tokens \([0-9][0-9]*\)$/\1/p' "$err_file" | tail -1)"
  [[ -n "$nt" ]] || nt=0
  total_tokens=$((total_tokens + nt))
done

if [[ "$found" -eq 1 ]]; then
  echo >&2
  echo "spec-skill-reference-scan: a spec names a shipyard: asset that is not registered (issue #1468)." >&2
  echo "A spec that tells a worker to load 'shipyard:<name>' is executable-by-proxy — the worker" >&2
  echo "issues the Skill/Agent call verbatim, and a name that resolves to nothing fails mid-dispatch" >&2
  echo "with no build-time signal at all." >&2
  echo "Fix by one of:" >&2
  echo "  * restoring / renaming the skill directory, command, or agent so the name resolves;" >&2
  echo "  * updating the spec to name the asset's real current name;" >&2
  echo "  * declaring the token with a file-scoped allow directive, when it is deliberately NOT a" >&2
  echo "    plugin asset (a GitHub label sharing the shipyard: prefix is the live example):" >&2
  echo "      <!-- spec-skill-reference-scan: allow shipyard:<token> -->" >&2
  echo "Do NOT widen the resolver to turn a finding green — that is the failure mode this gate" >&2
  echo "exists to prevent." >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  if [[ "$registry_n" -lt "$REGISTRY_FLOOR" ]]; then
    echo "spec-skill-reference-scan: resolved only $registry_n registered asset(s) — below the $REGISTRY_FLOOR floor; the registry builder is broken, not the corpus clean (#1468)." >&2
    exit 2
  fi
  if [[ "$total_tokens" -lt "$TOKEN_FLOOR" ]]; then
    echo "spec-skill-reference-scan: scanned ${#candidates[@]} file(s) but matched only $total_tokens shipyard: reference(s) — below the $TOKEN_FLOOR floor; the token matcher is broken, not the corpus clean (#1468)." >&2
    exit 2
  fi
fi

echo "spec-skill-reference-scan: ${#candidates[@]} file(s), $total_tokens shipyard: reference(s) checked against $registry_n registered asset(s); every reference resolves."
exit 0

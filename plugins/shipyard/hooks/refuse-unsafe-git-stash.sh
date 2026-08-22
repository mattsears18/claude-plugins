#!/usr/bin/env bash
# PreToolUse hook — refuses the `git stash` forms that mutate, or read by
# position from, the repo-global `refs/stash` stack, while leaving the
# sanctioned tagged procedure reachable.
#
# Motivation (#1506): `refs/stash` lives in the shared `.git` COMMON dir, so
# it is not per-worktree, not per-branch, and not per-dispatch — it is one
# LIFO stack visible to and mutable by every concurrent worker in the
# repository. A bare `git stash pop` always takes `stash@{0}` regardless of
# who pushed it, so on any session running `--concurrency > 1` popping is a
# coin flip over whichever worker stashed most recently. Both failure
# directions are silent: contamination (a peer's stash rides inside your PR)
# and data loss (you mistake a peer's stash for junk and `git restore` it
# away).
#
# `shipyard:worker-preamble`'s "Never `git stash`" section (the always-loaded
# hot core, not a fragment) has told workers not to do this since #845, and
# #1224 added the concrete substitute (`git commit -m "wip: …"`) inline after
# two workers reached for stash anyway. It happened a THIRD time in #1506 —
# by a worker that named the correct substitute, unprompted, in its own
# return. The diagnosis there is the reason this hook exists: the problem is
# not that the worker lacks the knowledge, it is that a reflex fires faster
# than a recalled rule under pressure. A fourth documentation edit was not
# expected to work where the second and third didn't.
#
# Why a hook rather than a `permissions.deny` pattern (the shape #1506
# proposed): neither available deny mechanism can express the needed
# distinction.
#   * Claude Code's Bash rule matcher compiles a rule to an anchored regex in
#     which `*` becomes `.*` and every other metacharacter is escaped. There
#     is no negation operator, no character class, no alternation — so "match
#     `git stash push` but not `git stash push -m`" is not writable as one
#     pattern, and `deny` short-circuits ahead of `allow`, so an `allow`
#     carve-out cannot rescue the tagged form either.
#   * `permissions` is not a field of the plugin-manifest schema at all, so
#     the `.claude-plugin/plugin.json` block the issue proposed extending is
#     not a rule source in the first place.
# A `PreToolUse` hook has neither limit: it parses the actual argument list,
# so it can block `git stash push -u` and allow `git stash push -u -m "tag"`.
# It is also immune to a command-rewriting hook (e.g. a token-proxy that
# rewrites `git stash …` to `<proxy> git stash …`), which would launder the
# command past a pattern anchored at `git`.
#
# Decision rules — the tool must be `Bash`, and some clause of the command
# must invoke `git … stash` (any `git` global options in between; any leading
# proxy/wrapper token). That clause is then classified by its arguments:
#
#   BLOCK  bare `git stash`                     — the reflex itself
#   BLOCK  `git stash <flags>` with no `-m`     — implicit push, untagged
#   BLOCK  `git stash push|save` with no `-m`   — explicit push, untagged
#   BLOCK  `git stash pop` (any arguments)      — never acceptable; a bare pop
#                                                 takes stash@{0} unconditionally
#   BLOCK  `git stash clear` (any arguments)    — destroys EVERY worker's entries
#   BLOCK  `git stash apply|drop` with no ref,
#          or with a positional `stash@{n}`     — position, not identity
#
# What is NOT blocked — the sanctioned procedure from
# `skills/worker-preamble/git-stash-prohibition.md`, in full:
#
#   git stash push -u -m "<agent-id-or-issue-N>: <reason>"   # tagged
#   git stash list --format='%H %gs'                         # read-only
#   git stash apply <sha>                                    # by identity
#   git stash drop <sha>                                     # by identity
#
# Also not blocked: `git stash show`, `git stash branch`, any `git stash`
# subcommand this hook does not recognize (conservative — an unrecognized
# subcommand is allowed, not guessed at), and a quoted mention of a blocked
# form inside some other command (`grep "git stash pop" docs/`), which the
# quote-aware tokenizer resolves to a single opaque token rather than a `git`
# invocation.
#
# Defensive defaults: malformed JSON, missing fields, a command the tokenizer
# cannot parse (unbalanced quotes) — fall through to exit 0 rather than
# block. A buggy hook that blocked every Bash call would be far worse than
# one that occasionally misses a stash. Same posture as the sibling hooks.
#
# Contract: read PreToolUse JSON from stdin, exit 2 + stderr to block, exit 0
# otherwise. Never propagate other errors. No bypass flag.

set -u

# Belt-and-braces — any internal error falls through to "allowed".
trap 'exit 0' ERR

input=$(cat 2>/dev/null || true)

# Bail early on empty input.
if [[ -z "$input" ]]; then
  exit 0
fi

# Parse + decide with python3 — same dependency as the companion hooks.
# Outputs one of:
#   ALLOW
#   BLOCK\t<reason-tag>\t<matched-fragment>
PY_DECIDE=$(cat <<'PY'
import json, os, re, shlex, sys

raw = sys.stdin.read() or ""
try:
    d = json.loads(raw)
except Exception:
    print("ALLOW")
    sys.exit(0)

if (d.get("tool_name") or "") != "Bash":
    print("ALLOW")
    sys.exit(0)

tool_input = d.get("tool_input") or {}
cmd = tool_input.get("command") or ""

if not cmd or "stash" not in cmd:
    print("ALLOW")
    sys.exit(0)

# Quote-aware tokenization. `punctuation_chars=True` splits shell operators
# (`;`, `&&`, `||`, `|`, `(`, `)`) into their own tokens, so a command can be
# segmented into clauses without a second, quote-blind pass. A command the
# lexer cannot parse (unbalanced quote, exotic expansion) falls through to
# ALLOW rather than being guessed at.
try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    # A shell command is not a config file: `#` is an ordinary character here
    # (an issue reference, a URL fragment, a format string), and letting the
    # lexer treat it as a comment would silently truncate the token stream —
    # hiding a `git stash pop` that follows one.
    lex.commenters = ""
    tokens = list(lex)
except Exception:
    print("ALLOW")
    sys.exit(0)

PUNCT = set("();<>|&")

def is_operator(tok):
    return tok != "" and all(ch in PUNCT for ch in tok)

# Split the token stream into clauses on operator tokens.
clauses = []
current = []
for tok in tokens:
    if is_operator(tok):
        if current:
            clauses.append(current)
        current = []
    else:
        current.append(tok)
if current:
    clauses.append(current)

# `git` global options that consume a following value, so the scan does not
# mistake that value for the subcommand.
VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
              "--exec-path", "--super-prefix"}

STASH_POSITION_RE = re.compile(r'^stash@\{\d+\}$')

def has_message_flag(args):
    for tok in args:
        if tok == "-m" or tok == "--message":
            return True
        if tok.startswith("--message="):
            return True
        # Short-flag cluster or attached value: -m"tag", -mtag, -um, -mu.
        if tok.startswith("-") and not tok.startswith("--") and "m" in tok[1:]:
            return True
    return False

def stash_arg_lists(clause):
    """Yield the argument list following `stash` for every `git … stash`
    invocation in a clause. Every `git` token is considered, not just the
    first, so a wrapper form (`xargs git stash pop`) or a clause naming git
    more than once cannot hide one."""
    n = len(clause)
    for i in range(n):
        # `git`, `/usr/bin/git`, `git.exe` — but not a quoted blob that merely
        # contains the word, whose basename will not be exactly `git`.
        base = os.path.basename(clause[i])
        if base not in ("git", "git.exe"):
            continue
        j = i + 1
        while j < n and clause[j].startswith("-"):
            if clause[j] in VALUE_OPTS:
                j += 2
            else:
                j += 1
        if j < n and clause[j] == "stash":
            yield clause[j + 1:]

stash_invocations = []
for clause in clauses:
    stash_invocations.extend(stash_arg_lists(clause))

for args in stash_invocations:
    if not args:
        print("BLOCK\tbare-stash\tgit stash")
        sys.exit(0)

    positional = [a for a in args if not a.startswith("-")]
    sub = positional[0] if positional and positional[0] == args[0] else None

    if sub is None:
        # `git stash -u`, `git stash --include-untracked` — an implicit push.
        if not has_message_flag(args):
            print("BLOCK\tuntagged-implicit-push\tgit stash " + " ".join(args))
            sys.exit(0)
        continue

    if sub in ("push", "save"):
        if not has_message_flag(args[1:]):
            print("BLOCK\tuntagged-push\tgit stash " + " ".join(args))
            sys.exit(0)
        continue

    if sub == "pop":
        print("BLOCK\tpop\tgit stash " + " ".join(args))
        sys.exit(0)

    if sub == "clear":
        print("BLOCK\tclear\tgit stash " + " ".join(args))
        sys.exit(0)

    if sub in ("apply", "drop"):
        refs = [a for a in positional[1:]]
        if not refs:
            print("BLOCK\tpositional-" + sub + "\tgit stash " + " ".join(args))
            sys.exit(0)
        if any(STASH_POSITION_RE.match(r) for r in refs):
            print("BLOCK\tpositional-" + sub + "\tgit stash " + " ".join(args))
            sys.exit(0)
        continue

    # list / show / branch / create / store / anything unrecognized — allowed.
    continue

print("ALLOW")
PY
)

decision=$(printf '%s' "$input" | python3 -c "$PY_DECIDE" 2>/dev/null || true)

if [[ "${decision%%$'\t'*}" != "BLOCK" ]]; then
  exit 0
fi

reason_tag=$(printf '%s' "$decision" | cut -f2)
fragment=$(printf '%s' "$decision" | cut -f3)

cat >&2 <<EOF
BLOCKED by shipyard/hooks/refuse-unsafe-git-stash.sh.

Refused: ${fragment}
Reason:  ${reason_tag}

\`refs/stash\` lives in the SHARED \`.git\` common dir — it is not
per-worktree, not per-branch, and not per-dispatch. Every concurrent worker
in this repository sees and can mutate the same LIFO stack, and a bare
\`git stash pop\` takes \`stash@{0}\` regardless of who pushed it. Both
failure directions are silent: a peer's stash rides into your PR unnoticed,
or you mistake a peer's stash for leftover junk and destroy their
uncommitted work. See issue #1506 (the third recorded instance; the two
prior fixes were documentation-only).

Do this instead:

  # To set changes aside — worktree-local, needs no coordination:
  git commit -m "wip: <why>"        # and later: git reset --soft HEAD~1
  # (amend to a Conventional Commits subject before you push — a
  #  single-commit PR squash-merges under the COMMIT subject, not the PR
  #  title. See issue #1410.)

  # To compare against a clean tree without moving anything:
  git diff -- <path>
  git show origin/<default-branch>:<path>

If a stash is genuinely unavoidable (rare — you should be able to say why a
WIP commit is insufficient), the tagged procedure is still permitted and is
the only safe shape:

  git stash push -u -m "<agent-id-or-issue-N>: <reason>"
  git stash list --format='%H %gs'    # find YOUR entry by its message
  git stash apply <sha>               # by identity, never by stash@{n}
  git stash drop <sha>                # only after confirming it applied

See skills/worker-preamble/git-stash-prohibition.md for the full mechanism.
This hook intentionally has no bypass flag; if you believe you need one of
the refused forms, return \`blocked:\` so a human can decide.
EOF

exit 2

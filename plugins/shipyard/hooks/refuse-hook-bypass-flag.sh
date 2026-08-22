#!/usr/bin/env bash
# PreToolUse hook — refuses the flags that bypass git's commit/push hooks:
# `--no-verify` (and its `-n` short form on `git commit`), `--no-gpg-sign`,
# and `--no-commit-hooks`, on `git commit` and `git push`.
#
# Motivation (#1511): `shipyard:worker-preamble` § "Never `--no-verify`" has
# forbidden these flags since #26, and until now it told workers the
# prohibition was mechanical — *"The plugin's `permissions.deny` block in
# `plugin.json` enforces this at the harness level."* That sentence rests on
# `permissions` being a rule source at the plugin-manifest tier, which the
# evidence gathered in #1511 does not support:
#
#   * The plugins reference enumerates the `plugin.json` schema and does not
#     list `permissions`. The permissions docs enumerate the rule sources
#     (managed settings, CLI flags, project settings, local settings, user
#     settings) and list no plugin-manifest tier.
#   * The shipped CLI binary's manifest loader/schema neighbourhoods carry no
#     `permissions` reference, and there is no `pluginSettings`-style rule-
#     source label alongside `userSettings` / `projectSettings` /
#     `localSettings` / `policySettings` / `flagSettings`.
#
# That evidence is strong but NOT conclusive — confirming it needs
# `/permissions` in an interactive session, which no headless dispatch can
# run — so #1511 deliberately stops short of calling the manifest block inert,
# and this hook is deliberately written to be correct either way. If the
# manifest block turns out to be live, this hook is redundant and harmless. If
# it is inert, this hook is the only thing standing between a worker and a
# hook-bypassing commit.
#
# Note that this repository ALSO carries the same four rules in its own
# `.claude/settings.json` — the project-settings tier, which unambiguously IS
# a documented rule source. That covers sessions run inside this repo and says
# nothing about a consuming repo that installs the plugin and has no such
# settings file. The hook ships with the plugin, so it protects those repos
# too; the deny block, live or not, does not.
#
# Why a hook rather than continuing to rely on a deny pattern, independent of
# the tier question: Claude Code's Bash rule matcher compiles a rule to an
# anchored regex in which `*` becomes `.*` and every other metacharacter is
# escaped. `Bash(git commit *--no-verify*)` therefore cannot match
# `git commit -n`, cannot match a proxy-prefixed `rtk git commit --no-verify`
# (a `PreToolUse` command-rewriting hook that prefixes a token proxy is live
# on at least one machine this plugin runs on — see #1506), and cannot tell a
# real flag from the same characters inside a quoted commit message. A hook
# parses the actual argument list and has none of those limits.
#
# Decision rules — the tool must be `Bash`, and some clause of the command
# must invoke `git … commit` or `git … push` (any `git` global options in
# between; any leading proxy/wrapper token). That invocation's argument list
# is then scanned, stopping at a bare `--` and skipping the values of
# value-taking options so a flag name quoted INTO a commit message is never
# mistaken for the flag itself:
#
#   BLOCK  `--no-verify`        on commit or push
#   BLOCK  `--no-gpg-sign`      on commit or push
#   BLOCK  `--no-commit-hooks`  on commit or push
#   BLOCK  `-n` (including inside a short-flag cluster) on `git commit` only
#
# `-n` is `--no-verify` on `git commit` but `--dry-run` on `git push`, so the
# short-form scan is deliberately asymmetric: `git push -n` is a read-only
# rehearsal and stays allowed. Inside a cluster the scan stops at the first
# value-taking short option (`-C`, `-c`, `-F`, `-m`, `-t`, `-S`, `-u`), so
# `git commit -mn "msg"` — where `n` is the message, not a flag — is allowed
# while `git commit -nm "msg"` is blocked.
#
# What is NOT blocked:
#   * Every other git subcommand. `git commit`/`git push` are the two the
#     prohibition names; an unrecognized subcommand is allowed, not guessed at.
#   * `--verify`, `--no-verify-signatures`, `--gpg-sign`, and any other
#     near-miss spelling — matching is exact-token equality, never substring.
#   * A quoted mention (`grep "git commit --no-verify" docs/`), which the
#     quote-aware tokenizer resolves to one opaque token whose basename is not
#     `git`, and a flag name passed as a VALUE (`git commit -m "--no-verify"`).
#   * `-c core.hooksPath=<dir>`. Repointing the hooks path can just as easily
#     ENABLE hooks (`git -c core.hooksPath=.githooks commit`) as disable them,
#     so blocking it wholesale would refuse legitimate commands. It is a real
#     bypass route when pointed at an empty directory; it is left uncovered
#     deliberately rather than silently, and the prose rule in
#     `shipyard:worker-preamble` still forbids it as "any other flag that
#     bypasses commit hooks".
#
# The one sanctioned `--no-verify` in this plugin —
# `scripts/crash-recovery-reap.sh`'s dirty-worktree auto-commit, where the
# pre-commit gate may be exactly what hung the worker and CI is the real gate
# — runs inside that script's own bash process, never as a `Bash` tool call,
# so this hook never sees it. That is why the hook needs no bypass flag: the
# one legitimate use is already out of its field of view, and a worker that
# believes it needs one of these flags should return `blocked:` instead.
#
# Defensive defaults: malformed JSON, missing fields, a command the tokenizer
# cannot parse (unbalanced quotes) — fall through to exit 0 rather than
# block. A buggy hook that blocked every Bash call would be far worse than
# one that occasionally misses a bypass. Same posture as the sibling hooks.
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
import json, os, shlex, sys

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

# Cheap pre-filter: every blockable form needs a `git` token AND either a
# long bypass flag or a short-option cluster. Bail before tokenizing when the
# command cannot possibly match.
if not cmd or "git" not in cmd:
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
    # hiding a `git commit --no-verify` that follows one.
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
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                  "--exec-path", "--super-prefix"}

# The exact long flags this hook refuses. Matching is token equality, never
# substring, so `--no-verify-signatures` and `--verify` are unaffected.
BYPASS_FLAGS = {
    "--no-verify": "no-verify",
    "--no-gpg-sign": "no-gpg-sign",
    "--no-commit-hooks": "no-commit-hooks",
}

# Options of `git commit` / `git push` whose VALUE arrives as the next token.
# Skipping that token is what keeps `git commit -m "--no-verify"` (a flag name
# quoted into a commit message) from reading as the flag itself.
ARG_VALUE_OPTS = {
    # commit
    "-m", "--message",
    "-C", "--reuse-message",
    "-c", "--reedit-message",
    "-F", "--file",
    "-t", "--template",
    "--fixup", "--squash", "--author", "--date", "--cleanup",
    "--pathspec-from-file", "--trailer", "--untracked-files", "--gpg-sign",
    # push
    "--repo", "--receive-pack", "--exec", "-o", "--push-option",
    "--recurse-submodules",
}

# Short options of `git commit` that consume a value — either attached inside
# the cluster (`-mmsg`, `-Skeyid`, `-uno`) or as the following token. Either
# way everything after them in the cluster is a value, not a flag, so the
# `-n` scan must stop there.
COMMIT_SHORT_VALUE_CHARS = set("CcFmtSu")

def git_invocations(clause):
    """Yield (subcommand, args) for every `git … <sub>` invocation in a clause.
    Every `git` token is considered, not just the first, so a wrapper form
    (`rtk git commit …`, `sudo git push …`) or a clause naming git more than
    once cannot hide one."""
    n = len(clause)
    for i in range(n):
        # `git`, `/usr/bin/git`, `git.exe` — but not a quoted blob that merely
        # contains the word, whose basename will not be exactly `git`.
        base = os.path.basename(clause[i])
        if base not in ("git", "git.exe"):
            continue
        j = i + 1
        while j < n and clause[j].startswith("-"):
            if clause[j] in GIT_VALUE_OPTS:
                j += 2
            else:
                j += 1
        if j < n:
            yield clause[j], clause[j + 1:]

def scan(sub, args):
    """Return (reason_tag, matched_flag) for the first bypass flag in `args`,
    or None. `sub` is `commit` or `push`; the `-n` short-form scan applies to
    `commit` only, because `-n` means `--dry-run` on `push`."""
    skip_next = False
    for tok in args:
        if skip_next:
            skip_next = False
            continue
        # A bare `--` ends the option list; everything after is a pathspec.
        if tok == "--":
            return None
        if tok in BYPASS_FLAGS:
            return (BYPASS_FLAGS[tok], tok)
        if tok in ARG_VALUE_OPTS:
            skip_next = True
            continue
        # Short-option cluster, e.g. `-am`, `-nm`, `-mn`. Only `git commit`
        # spells `--no-verify` as `-n`.
        if sub == "commit" and tok.startswith("-") and not tok.startswith("--"):
            for ch in tok[1:]:
                if ch == "n":
                    return ("short-n-no-verify", tok)
                if ch in COMMIT_SHORT_VALUE_CHARS:
                    break
    return None

for clause in clauses:
    for sub, args in git_invocations(clause):
        if sub not in ("commit", "push"):
            continue
        hit = scan(sub, args)
        if hit:
            tag, flag = hit
            print("BLOCK\t%s\tgit %s … %s" % (tag, sub, flag))
            sys.exit(0)

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
BLOCKED by shipyard/hooks/refuse-hook-bypass-flag.sh.

Refused: ${fragment}
Reason:  ${reason_tag}

Commit and push hooks are the repo's own quality gate — a typecheck, a
linter, a formatter, a secret scan. Bypassing one commits work that gate
never inspected, and the bypass is invisible in the resulting diff.
\`shipyard:worker-preamble\` § "Never \`--no-verify\`" forbids these flags
outright, "even if you believe the hook failure is environmental, unrelated
to your changes, or a false positive." See issue #1511.

Do this instead:

  1. Fix the underlying cause, within the scope of your own changes.
  2. If the cause is outside your scope, return:
       blocked: pre-commit hook <NAME> failed for reason <X>
     and let the orchestrator decide.
  3. If the hook is being SKIPPED rather than failing — a husky hook without
     its executable bit, a missing node_modules — make the gate fire; see
     skills/worker-preamble/node-bootstrap.md. The fix is to run the hook,
     never to formalize the bypass.

Note that \`-n\` is \`--no-verify\` on \`git commit\` but \`--dry-run\` on
\`git push\`; only the commit spelling is refused. Legitimate forms —
\`git commit -m "…"\`, \`git commit --amend --no-edit\`, \`git push -u origin
HEAD:refs/heads/<branch>\`, \`git push --dry-run\` — are unaffected.

This hook intentionally has no bypass flag. If you believe you genuinely need
one of the refused flags, return \`blocked:\` so a human can decide.
EOF

exit 2

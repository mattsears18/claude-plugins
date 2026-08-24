#!/usr/bin/env bash
# PreToolUse hook — refuses any `Bash` invocation that irreversibly mutates
# live external state: deleting a hosted config row / secret / resource, or
# widening public access to one. Read-only external verification, creates,
# and narrowing changes all pass through untouched.
#
# Motivation (#1519): a `/shipyard:do-work` worker on another repo deleted a
# Vercel **Production** environment variable while its own fix PR was still
# open — in direct contradiction of an explicit sequencing rule in that
# repo's CLAUDE.md ("the retirement PR must land and deploy before the stored
# value is removed"). It then justified the deviation in its return string,
# *after* the action, by reasoning that the rule's precondition didn't apply.
# The reasoning happened to hold and the outcome was safe; the decision
# procedure was not. Only the harness's own permission classifier flagged it
# — nothing in this repo would have.
#
# The asymmetry #1519 identifies is what makes a mechanical layer worth it: a
# worker that writes a bad line of code produces a red check and a reviewable
# diff; a worker that deletes a production config row produces NO artifact at
# all — nothing in the PR, nothing in CI, no diff — only prose in a return
# string a human may never read. And the prose rule this hook backs is
# specifically a rule about not reasoning your way past a prose rule
# (`skills/worker-preamble/irreversible-external-action.md` rule 2), which is
# exactly the kind of rule that should not depend solely on the model reading
# and honoring it. Same stick/carrot pairing `refuse-credential-mint.sh`
# (#1166/#1170), `refuse-unsafe-git-stash.sh` (#1506), and
# `refuse-hook-bypass-flag.sh` (#1511) already use.
#
# Scope — deliberately NARROWER than the prose doctrine. This hook matches
# named hosted-platform CLIs with unambiguous destructive/widening verbs. The
# issue's own "What NOT to do" section is binding here: *"Don't fix this by
# forbidding workers from touching external systems at all … read-only
# external access is high-value and should stay. The line worth drawing is at
# irreversible mutation, not at access."* A broad rule that generated false
# blocks would push workers toward routing around the hook, which is worse
# than no hook. A command this hook does not match is NOT thereby permitted —
# the doctrine file is the contract; this is a backstop for the shapes cheap
# enough to catch mechanically.
#
# Decision rules (ANY holds to BLOCK) — matched only within one statement (not
# crossing `;`, `&&`, `|`, or a newline), same posture as
# `refuse-credential-mint.sh`, so an unrelated later command in a compound
# line can't fire a match on an earlier, harmless one:
#
#   1. `vercel ... env rm|remove` — deletes a hosted environment variable.
#      The #1519 repro verbatim.
#   2. `gh secret delete` / `gh variable delete` — deletes a GitHub Actions
#      secret or variable (the value is unrecoverable from GitHub).
#   3. `heroku config:unset`, `netlify env:unset`, `fly|flyctl secrets unset`,
#      `supabase secrets unset`, `wrangler secret delete` — the same hosted
#      config-row deletion on the other common platforms.
#   4. `gcloud secrets delete` / `gcloud secrets versions destroy`,
#      `aws secretsmanager delete-secret`, `aws ssm delete-parameter(s)`,
#      `az keyvault secret delete|purge`,
#      `firebase functions:secrets:destroy` — cloud secret-store destruction.
#   5. `terraform destroy`, or `terraform apply` carrying `-destroy` —
#      tears down managed infrastructure.
#   6. `npm unpublish` — irreversibly removes a published package version
#      from a public registry.
#   7. `... add-iam-policy-binding ... allUsers|allAuthenticatedUsers`, or
#      `gsutil iam ch ... allUsers` — widens access to the public internet.
#   8. `gh repo edit ... --visibility public` — makes a repository public.
#      You cannot un-expose what was exposed.
#
# What is NOT blocked (all deliberate):
#   - Every corresponding READ verb — `vercel env ls`, `gh secret list`,
#     `gcloud secrets list/describe`, `aws secretsmanager get-secret-value`,
#     `terraform plan`, `firebase functions:list`. None of rules 1-8 match a
#     read verb. This is the class #1519 explicitly protects.
#   - CREATE / SET verbs — `vercel env add`, `gh secret set`,
#     `heroku config:set`, `terraform apply` (without `-destroy`). A create is
#     undone by a delete; the failure mode is recoverable.
#   - NARROWING changes — `remove-iam-policy-binding`, tightening an ACL.
#     Failure mode is a broken deploy: loud, visible, revertible.
#   - Local/worktree operations — `rm`, `git reset`, `git clean`, deleting a
#     temp file. Not external state.
#   - Session-owned git artifacts — `git push --delete` of your own branch,
#     `gh pr merge --delete-branch`. The commits survive on the default
#     branch and the branch is trivially recreated; this is `auto-merge.md`'s
#     normal flow.
#   - Reversible GitHub metadata — `gh issue close`, `gh pr close`,
#     `gh issue edit --remove-label`. All undoable in one click.
#
# Deliberately out of scope (near-neighbors considered and rejected):
#   - `kubectl delete` — the target cluster is invisible from the command
#     string, and local `kind`/`minikube` usage is routine. A blanket block
#     would be mostly false positives.
#   - `docker rm` / `docker rmi` / `docker volume rm` — local by default.
#   - `aws s3 rm` — overwhelmingly used against build artifacts and caches in
#     legitimate automation; `aws s3 rb` (remove *bucket*) is closer to the
#     mark but rare enough that the prose rule carries it.
#   - `dropdb` / raw `DROP TABLE` SQL — no reliable command shape, and the
#     connection target is invisible from the string.
#   - `gh label delete` — repo metadata, recreatable in one command; this
#     repo's own CLAUDE.md already routes label deletion to an operator
#     follow-up by policy, not by tooling.
#
# Fail-safe posture (matches refuse-credential-mint.sh exactly):
#   - Tool isn't `Bash`, or the command string is empty/missing → ALLOW.
#     There is no shell command here to have mutated anything.
#   - The top-level JSON payload itself fails to parse → ALLOW. The payload
#     is harness-generated, not attacker-controlled shell text; a malformed
#     wrapper doesn't imply a destructive command is hiding inside it, and
#     blocking here would block every OTHER tool call too (we don't even know
#     the tool name).
#   - We DO have a real, non-empty Bash command string and something goes
#     wrong classifying it → BLOCK. Once we know we're looking at an actual
#     shell command about to run, an internal failure to classify it must not
#     silently pass an irreversible mutation through the hole a bug just
#     opened. A false block is rare and recoverable (retry, or return
#     `blocked:`); a silent bypass on the one class of command this hook
#     exists to catch is not.
#
# Contract: read PreToolUse JSON from stdin, exit 2 + stderr to block, exit 0
# otherwise. No bypass flag.

set -u

input=$(cat 2>/dev/null || true)

# Bail early on empty input — nothing to evaluate, and this is the harness
# framing (no Bash command exists yet), not an unparseable Bash payload.
if [[ -z "$input" ]]; then
  exit 0
fi

# Parse + decide with python3 — same dependency as the companion hooks.
# Outputs one of:
#   ALLOW
#   BLOCK\t<reason-tag>\t<matched-fragment>
PY_DECIDE=$(cat <<'PY'
import json, re, sys

raw = sys.stdin.read() or ""
try:
    d = json.loads(raw)
except Exception:
    # Malformed top-level payload — not identifiably a Bash command at all.
    # See the fail-safe posture note in the header.
    print("ALLOW")
    sys.exit(0)

if (d.get("tool_name") or "") != "Bash":
    print("ALLOW")
    sys.exit(0)

tool_input = d.get("tool_input") or {}
cmd = tool_input.get("command") or ""

if not cmd or not isinstance(cmd, str):
    print("ALLOW")
    sys.exit(0)

# From here on we KNOW this is a real, non-empty Bash command about to run.
# Any exception below is caught and treated as BLOCK, not ALLOW — the
# fail-closed half of this hook's posture (see header).
try:
    def in_quotes(text, idx):
        # True if position idx is inside a balanced single- or double-quote
        # pair starting before idx. Simple counter: backslash escapes the
        # next char. Doesn't handle shell parameter expansion. Conservative:
        # when in doubt returns False so we still inspect (safe-side
        # default) — matches the posture of the sibling hooks.
        sq = 0
        dq = 0
        i = 0
        while i < idx:
            c = text[i]
            if c == chr(92) and i + 1 < len(text):  # backslash escapes next char
                i += 2
                continue
            if c == chr(39) and dq == 0:  # single quote
                sq = 1 - sq
            elif c == chr(34) and sq == 0:  # double quote
                dq = 1 - dq
            i += 1
        return sq == 1 or dq == 1

    def real_matches(pattern):
        return [m for m in pattern.finditer(cmd) if not in_quotes(cmd, m.start())]

    # Statement-boundary wildcard: matches within one `;`/`&&`/`|`-separated
    # statement only, so an unrelated later command in a compound line can't
    # combine with an earlier, harmless one to fire a false match — same
    # technique as refuse-credential-mint.sh.
    NEG = r'[^|;&\n]*'
    # Word start guard: the token must begin a word, not sit mid-identifier.
    WS = r'(?<![A-Za-z0-9_./-])'
    # Only flag-ish/short tokens may sit between a CLI and its subcommand
    # (e.g. `vercel --scope acme env rm`). Bounded so an unrelated later word
    # in the same statement can't bridge two harmless tokens into a match.
    GAP = r'(?:\s+-[^\s|;&]+|\s+[A-Za-z0-9_./@:-]+){0,4}\s+'

    def verb(*words):
        # A standalone subcommand verb, not a fragment of a hyphenated or
        # dotted identifier. Without this guard a resource NAMED e.g.
        # `my-delete-key` would satisfy a bare `\bdelete\b` and produce a
        # false block on an otherwise read-only command.
        return (r'(?<![A-Za-z0-9_./-])(?:' + '|'.join(words)
                + r')(?![A-Za-z0-9_./-])')

    patterns = [
        # 1. Hosted environment-variable deletion — the #1519 repro.
        ("vercel-env-rm",
         re.compile(WS + r'vercel\b' + GAP + r'env' + GAP + r'(rm|remove)\b')),
        # 2. GitHub Actions secret / variable deletion.
        ("gh-secret-delete",
         re.compile(WS + r'gh\s+(secret|variable)\s+delete\b')),
        # 3. Hosted config-row deletion on the other common platforms.
        ("heroku-config-unset",
         re.compile(WS + r'heroku\b' + NEG + r'\bconfig:unset\b')),
        ("netlify-env-unset",
         re.compile(WS + r'netlify\b' + NEG + r'\benv:unset\b')),
        ("fly-secrets-unset",
         re.compile(WS + r'(fly|flyctl)\s+secrets\s+unset\b')),
        ("supabase-secrets-unset",
         re.compile(WS + r'supabase\b' + GAP + r'secrets' + GAP + r'unset\b')),
        ("wrangler-secret-delete",
         re.compile(WS + r'wrangler\b' + GAP + r'secret' + GAP + r'delete\b')),
        # 4. Cloud secret-store destruction.
        ("gcloud-secrets-destroy",
         re.compile(WS + r'gcloud\b' + GAP + r'secrets\b' + NEG
                    + verb('delete', 'destroy'))),
        ("aws-secretsmanager-delete",
         re.compile(WS + r'aws\b' + GAP + r'secretsmanager\s+delete-secret\b')),
        ("aws-ssm-delete-parameter",
         re.compile(WS + r'aws\b' + GAP + r'ssm\s+delete-parameters?\b')),
        ("az-keyvault-secret-delete",
         re.compile(WS + r'az\b' + GAP + r'keyvault\s+secret\s+(delete|purge)\b')),
        ("firebase-secrets-destroy",
         re.compile(WS + r'firebase\b' + NEG + r'\bfunctions:secrets:destroy\b')),
        # 5. Infrastructure teardown.
        ("terraform-destroy",
         re.compile(WS + r'terraform\b' + GAP + r'destroy\b')),
        ("terraform-apply-destroy",
         re.compile(WS + r'terraform\b' + GAP + r'apply\b' + NEG + r'\s-destroy\b')),
        # 6. Public-registry unpublish.
        ("npm-unpublish",
         re.compile(WS + r'npm\b' + GAP + verb('unpublish'))),
        # 7. Access widened to the public internet.
        ("iam-public-binding",
         re.compile(r'\badd-iam-policy-binding\b' + NEG
                    + r'\b(allUsers|allAuthenticatedUsers)\b')),
        ("gsutil-iam-public",
         re.compile(WS + r'gsutil\s+iam\s+ch\b' + NEG + r'\ballUsers\b')),
        # 8. Repository made public.
        ("gh-repo-visibility-public",
         re.compile(WS + r'gh\s+repo\s+edit\b' + NEG + r'--visibility[=\s]+public\b')),
    ]

    for tag, pattern in patterns:
        hits = real_matches(pattern)
        if hits:
            frag = cmd[hits[0].start():hits[0].start() + 60].strip()
            print(f"BLOCK\t{tag}\t{frag}")
            sys.exit(0)

    print("ALLOW")
except SystemExit:
    raise
except Exception:
    # Fail-closed: we know this is a real Bash command but couldn't
    # classify it. See the header's fail-safe posture note.
    print("BLOCK\terror\tinternal classification error")
PY
)

decision=$(printf '%s' "$input" | python3 -c "$PY_DECIDE" 2>/dev/null)

if [[ "${decision%%$'\t'*}" != "BLOCK" ]]; then
  exit 0
fi

reason_tag=$(printf '%s' "$decision" | cut -f2)
matched_fragment=$(printf '%s' "$decision" | cut -f3)

cat >&2 <<EOF
BLOCKED by shipyard/hooks/refuse-irreversible-external-mutation.sh.

You attempted to irreversibly mutate live external state (matched:
${reason_tag} — "${matched_fragment}").

A dispatched worker may READ any external system, and may CREATE or NARROW
against one. It must HAND BACK a DELETE or an ACCESS-WIDENING change to a
live/production surface, rather than executing it.

Why the asymmetry: a bad line of code produces a red check and a reviewable
diff. A deleted production config row produces no artifact at all — nothing
in the PR, nothing in CI, no diff to review. Issue #1519 is the verified
repro: a worker deleted a Vercel Production env var while its own fix PR was
still open, against an explicit sequencing rule in that repo's CLAUDE.md, and
explained itself only afterwards in a return string.

Concluding that a documented sequencing or safety rule's precondition doesn't
apply to your case is NOT grounds to proceed here. That belief is itself the
thing to hand back.

What IS allowed: every read verb (\`vercel env ls\`, \`gh secret list\`,
\`gcloud secrets list\`, \`terraform plan\`, …), every create/set verb, every
narrowing change, anything local to your worktree, and session-owned git
artifacts (\`gh pr merge --delete-branch\` on your own PR).

Ship the code half of your work first — commit, push, open the PR — then hand
back only the external remainder:

  blocked #<N> at <stage>: irreversible external action — <what> on <surface>;
  handed back rather than executed. Exact command: \`<command>\`

The substring "irreversible external action" is load-bearing: it routes the
bail to the \`agent-console\` label, which \`/shipyard:my-turn\` surfaces and
\`/shipyard:do-work\`'s operator phase can drive in a real browser. This is a
queued action, not a dead end.

Full doctrine: \`shipyard:worker-preamble\` §"Never irreversibly mutate live
external state" and skills/worker-preamble/irreversible-external-action.md.
This hook intentionally has no bypass flag.
EOF

exit 2

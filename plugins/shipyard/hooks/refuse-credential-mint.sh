#!/usr/bin/env bash
# PreToolUse hook — refuses any `Bash` invocation that mints a new long-lived
# cloud credential (a service-account key, an IAM access key, a service
# principal's secret) instead of merely reading/listing existing ones.
#
# Motivation (#1166 / #1170): a `/shipyard:do-work` worker on another repo ran
# `gcloud iam service-accounts keys create` against a live Firebase admin
# service account to try to unblock its own task. Only the harness's own
# permission classifier stopped the key from actually being minted — nothing
# in this repo would have caught it. #1166 closed the "the model didn't know
# it was forbidden" gap by adding a "Never create a credential" prohibition to
# `skills/worker-preamble/SKILL.md` and every per-mode file. This hook is the
# defense-in-depth half: the rule must not depend solely on the model reading
# and honoring prose, the same "stick vs carrot" pairing
# `refuse-broad-process-kill.sh` and `enforce-worktree-isolation.sh` already
# use for their own prose rules.
#
# Scope — long-lived credential MINTING only, not temporary/session tokens.
# `aws sts assume-role` / `aws sts get-session-token` mint short-lived,
# narrowly-scoped session credentials and are routine in day-to-day
# automation (role-switching in CI/CD, cross-account deploy scripts) — a
# blanket block there would be exactly the "broad rule generates false
# blocks, pushes workers toward working around the hook" failure the dispatch
# for this issue warned against. This hook targets the narrower, more
# dangerous class: a persistent secret (a JSON key file, an IAM access-key
# pair, a service-principal password) that keeps working until someone
# manually revokes it — the #1166 repro's exact shape.
#
# Decision rules (ANY holds to BLOCK) — matched only within one statement (not
# crossing `;`, `&&`, `|`, or a newline), same posture as
# `refuse-broad-process-kill.sh`'s pgrep/ps-grep rule, so an unrelated later
# command in a compound line can't fire a match on an earlier, harmless one:
#
#   1. `gcloud ... service-accounts ... keys ... create` (or `... upload`) —
#      mints (or registers) a service-account key file. Covers `gcloud iam
#      service-accounts keys create/upload` and the `alpha`/`beta` command
#      groups.
#   2. `aws ... iam ... create-access-key` — mints an IAM access-key pair.
#   3. `aws ... iam ... create-login-profile` — mints an IAM console
#      password.
#   4. `aws ... iam ... create-service-specific-credential` — mints a
#      service-specific credential (e.g. CodeCommit git credentials).
#   5. `az ... create-for-rbac` — mints a service principal + its secret
#      (`az ad sp create-for-rbac`).
#   6. `az ... credential ... create` (or `... reset`) — mints or rotates an
#      Azure AD application credential (`az ad app credential create/reset`).
#
# What is NOT blocked: every corresponding *read* subcommand — `keys list`,
# `keys describe`, `list-access-keys`, `ad sp list`, `credential list`, and
# equivalents — because none of rules 1-6 match on those verbs. Ordinary
# inspection of an existing credential's metadata must keep working; the
# prohibition is on creating/downloading a credential, not reading about one.
#
# Deliberately out of scope (near-neighbors considered and rejected):
#   - `aws sts assume-role` / `get-session-token` — temporary, narrowly-scoped
#     credentials; too routine in legitimate automation to block broadly (see
#     the Scope note above).
#   - `gcloud iam service-accounts create` (no `keys`) — creates an identity,
#     not a secret; the follow-on `keys create` is what this hook catches.
#   - `az keyvault secret set` — writes an already-known value into a vault,
#     not minting a new one; a different risk class (secret storage, not
#     secret creation) with its own false-positive surface (e.g. rotating a
#     value a human already generated out-of-band).
#   - DigitalOcean (`doctl`) has no CLI subcommand that mints an API token —
#     token creation is web-console-only, so there is no command shape to
#     block.
#
# Fail-safe posture (deliberately asymmetric — see the dispatch for #1170):
#   - Tool isn't `Bash`, or the command string is empty/missing → ALLOW. Not
#     ambiguous: there is no shell command here to have minted anything.
#   - The top-level JSON payload itself fails to parse → ALLOW, same as
#     `refuse-broad-process-kill.sh`. The payload is harness-generated, not
#     attacker-controlled shell text; a malformed wrapper doesn't imply a
#     credential-mint command is hiding inside it, and blocking here would
#     block every OTHER tool call too (we don't even know the tool name).
#   - We DO have a real, non-empty Bash command string and something goes
#     wrong classifying it (an unexpected exception in the matching logic
#     itself) → BLOCK. This is the one place this hook's posture diverges
#     from its siblings: once we know we're looking at an actual shell
#     command about to run, an internal failure to classify it must not
#     silently pass a credential-minting command through the hole a bug just
#     opened. A false block here is rare (regex matching over a string
#     doesn't normally throw) and recoverable (retry, or return `blocked:`);
#     a silent bypass on the one class of command this hook exists to catch
#     is not.
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
    # See the fail-safe posture note in the header: ALLOW here matches the
    # sibling hooks' posture and avoids blocking every other tool call.
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
    # technique as refuse-broad-process-kill.sh's pgrep/ps-grep rule.
    NEG = r'[^|;&\n]*'

    patterns = [
        ("gcloud-service-account-key",
         re.compile(r'(?<![A-Za-z0-9_])gcloud\b' + NEG + r'\bservice-accounts\b'
                     + NEG + r'\bkeys\b' + NEG + r'\b(create|upload)\b')),
        ("aws-create-access-key",
         re.compile(r'(?<![A-Za-z0-9_])aws\b' + NEG + r'\biam\b' + NEG
                     + r'\bcreate-access-key\b')),
        ("aws-create-login-profile",
         re.compile(r'(?<![A-Za-z0-9_])aws\b' + NEG + r'\biam\b' + NEG
                     + r'\bcreate-login-profile\b')),
        ("aws-create-service-specific-credential",
         re.compile(r'(?<![A-Za-z0-9_])aws\b' + NEG + r'\biam\b' + NEG
                     + r'\bcreate-service-specific-credential\b')),
        ("az-create-for-rbac",
         re.compile(r'(?<![A-Za-z0-9_])az\b' + NEG + r'\bcreate-for-rbac\b')),
        ("az-app-credential-mint",
         re.compile(r'(?<![A-Za-z0-9_])az\b' + NEG + r'\bcredential\b' + NEG
                     + r'\b(create|reset)\b')),
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
BLOCKED by shipyard/hooks/refuse-credential-mint.sh.

You attempted to mint a new long-lived cloud credential (matched:
${reason_tag} — "${matched_fragment}").

A dispatched worker must NEVER create, mint, or download a new credential —
a service-account key, an IAM access key, a service-principal secret — even
to unblock its own task. This is a real, verified near-miss: a
/shipyard:do-work worker on another repo ran
\`gcloud iam service-accounts keys create\` against a live Firebase admin
service account; only the harness's own permission classifier stopped the
key from actually being minted (issue #1166).

What IS allowed: reading/listing existing credentials — \`keys list\`,
\`keys describe\`, \`list-access-keys\`, \`ad sp list\`, \`credential list\`,
and equivalents. This hook only blocks the create/mint verbs.

If the task genuinely requires a new credential to exist, that is a human
decision, not something a worker can grant itself. Return \`blocked:\` and
let a human provision it (see \`shipyard:worker-preamble\` and
\`issue-work.md\` §4.4's external-provisioning guard for the sanctioned
hand-back path). This hook intentionally has no bypass flag.
EOF

exit 2

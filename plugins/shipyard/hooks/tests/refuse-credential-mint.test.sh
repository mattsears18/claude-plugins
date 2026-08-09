#!/usr/bin/env bash
# Test suite for hooks/refuse-credential-mint.sh.
#
# Run with:
#   bash plugins/shipyard/hooks/tests/refuse-credential-mint.test.sh
#
# Each test crafts a PreToolUse JSON payload for a Bash tool call, pipes it to
# the hook, and asserts on stderr + exit code. Exit 2 == blocked, exit 0 ==
# allowed (transparent).
#
# The hook blocks commands that MINT a new long-lived cloud credential
# (gcloud service-account keys, AWS IAM access keys/login profiles/
# service-specific credentials, Azure AD service-principal/app credentials)
# while leaving every read/list/describe equivalent untouched. See
# plugins/shipyard/hooks/refuse-credential-mint.sh for the decision rules and
# issue #1166 / #1170 for the motivating near-miss.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/../refuse-credential-mint.sh"

if [[ ! -f "$hook" ]]; then
  echo "FAIL: hook not found at $hook" >&2
  exit 1
fi

pass=0
fail=0
GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

# Helper — invoke hook with payload on stdin.
# Returns: "<exit_code>::<stderr>"
run_hook() {
  local payload="$1"
  local stderr exit_code
  stderr=$(printf '%s' "$payload" | bash "$hook" 2>&1 >/dev/null)
  exit_code=$?
  printf '%s::%s' "$exit_code" "$stderr"
}

assert_exit() {
  local result="$1"
  local want="$2"
  local label="$3"
  local got="${result%%::*}"
  if [[ "$got" == "$want" ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s (want exit %s, got %s)\n' "$RED" "$RESET" "$label" "$want" "$got"
    printf '    stderr: %s\n' "${result#*::}"
    fail=$((fail+1))
  fi
}

assert_blocked_with() {
  local result="$1"
  local needle="$2"
  local label="$3"
  local got="${result%%::*}"
  local stderr="${result#*::}"
  if [[ "$got" == "2" && "$stderr" == *"$needle"* ]]; then
    printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$label"
    pass=$((pass+1))
  else
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$label"
    printf '    want exit 2 and stderr containing %q\n' "$needle"
    printf '    got exit %s, stderr: %s\n' "$got" "$stderr"
    fail=$((fail+1))
  fi
}

mkpayload() {
  local tool="$1" cmd="$2"
  TOOL="$tool" CMD="$cmd" python3 -c '
import json, os
print(json.dumps({
    "tool_name": os.environ["TOOL"],
    "cwd": "/tmp",
    "tool_input": {"command": os.environ["CMD"]},
}))'
}

# -----------------------------------------------------------------------------
echo "== Non-Bash tools pass through transparently"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Edit 'gcloud iam service-accounts keys create key.json')")
assert_exit "$out" "0" "Edit tool with a mint-shaped string → not blocked"

out=$(run_hook "$(mkpayload Read 'aws iam create-access-key')")
assert_exit "$out" "0" "Read tool → not blocked"

# -----------------------------------------------------------------------------
echo "== gcloud service-account key minting is blocked"
# -----------------------------------------------------------------------------
# The #1166 repro, verbatim.

out=$(run_hook "$(mkpayload Bash 'gcloud iam service-accounts keys create key.json --iam-account=foo@bar.iam.gserviceaccount.com')")
assert_blocked_with "$out" "gcloud-service-account-key" "gcloud iam service-accounts keys create → blocked (the #1166 repro)"

out=$(run_hook "$(mkpayload Bash 'gcloud alpha iam service-accounts keys upload pub.pem --iam-account=foo@bar.iam.gserviceaccount.com')")
assert_blocked_with "$out" "gcloud-service-account-key" "gcloud alpha ... keys upload → blocked"

out=$(run_hook "$(mkpayload Bash 'gcloud beta iam service-accounts keys create key.json --iam-account=foo@bar.iam.gserviceaccount.com')")
assert_blocked_with "$out" "gcloud-service-account-key" "gcloud beta ... keys create → blocked"

# -----------------------------------------------------------------------------
echo "== gcloud service-account key READS are allowed"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'gcloud iam service-accounts keys list --iam-account=foo@bar.iam.gserviceaccount.com')")
assert_exit "$out" "0" "gcloud ... keys list → allowed"

out=$(run_hook "$(mkpayload Bash 'gcloud iam service-accounts keys describe KEYID --iam-account=foo@bar.iam.gserviceaccount.com')")
assert_exit "$out" "0" "gcloud ... keys describe → allowed"

out=$(run_hook "$(mkpayload Bash 'gcloud iam service-accounts list')")
assert_exit "$out" "0" "gcloud iam service-accounts list (no keys subcommand) → allowed"

out=$(run_hook "$(mkpayload Bash 'gcloud iam service-accounts create my-sa --display-name=my-sa')")
assert_exit "$out" "0" "gcloud iam service-accounts create (identity, not a key) → allowed"

# -----------------------------------------------------------------------------
echo "== aws IAM credential minting is blocked"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'aws iam create-access-key --user-name bob')")
assert_blocked_with "$out" "aws-create-access-key" "aws iam create-access-key → blocked (the #1166 repro family)"

out=$(run_hook "$(mkpayload Bash 'aws iam create-login-profile --user-name bob --password xxx')")
assert_blocked_with "$out" "aws-create-login-profile" "aws iam create-login-profile → blocked"

out=$(run_hook "$(mkpayload Bash 'aws iam create-service-specific-credential --user-name bob --service-name codecommit.amazonaws.com')")
assert_blocked_with "$out" "aws-create-service-specific-credential" "aws iam create-service-specific-credential → blocked"

# -----------------------------------------------------------------------------
echo "== aws IAM credential READS are allowed"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'aws iam list-access-keys --user-name bob')")
assert_exit "$out" "0" "aws iam list-access-keys → allowed"

out=$(run_hook "$(mkpayload Bash 'aws iam get-access-key-last-used --access-key-id AKIAEXAMPLE')")
assert_exit "$out" "0" "aws iam get-access-key-last-used → allowed"

out=$(run_hook "$(mkpayload Bash 'aws sts assume-role --role-arn arn:aws:iam::123456789012:role/foo --role-session-name bar')")
assert_exit "$out" "0" "aws sts assume-role (temporary session creds, deliberately out of scope) → allowed"

out=$(run_hook "$(mkpayload Bash 'aws sts get-session-token')")
assert_exit "$out" "0" "aws sts get-session-token (deliberately out of scope) → allowed"

# -----------------------------------------------------------------------------
echo "== az service-principal / app-credential minting is blocked"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'az ad sp create-for-rbac --name myApp')")
assert_blocked_with "$out" "az-create-for-rbac" "az ad sp create-for-rbac → blocked"

out=$(run_hook "$(mkpayload Bash 'az ad app credential create --id abc123 --key def456')")
assert_blocked_with "$out" "az-app-credential-mint" "az ad app credential create → blocked"

out=$(run_hook "$(mkpayload Bash 'az ad app credential reset --id abc123')")
assert_blocked_with "$out" "az-app-credential-mint" "az ad app credential reset → blocked"

# -----------------------------------------------------------------------------
echo "== az service-principal / app-credential READS are allowed"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'az ad sp list --display-name myApp')")
assert_exit "$out" "0" "az ad sp list → allowed"

out=$(run_hook "$(mkpayload Bash 'az ad app credential list --id abc123')")
assert_exit "$out" "0" "az ad app credential list → allowed"

out=$(run_hook "$(mkpayload Bash 'az keyvault secret set --vault-name myvault --name mysecret --value alreadyknown')")
assert_exit "$out" "0" "az keyvault secret set (storing a known value, not minting one — deliberately out of scope) → allowed"

# -----------------------------------------------------------------------------
echo "== unrelated commands pass through"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'git status')")
assert_exit "$out" "0" "git status → allowed"

out=$(run_hook "$(mkpayload Bash 'npm test')")
assert_exit "$out" "0" "npm test → allowed"

out=$(run_hook "$(mkpayload Bash 'echo "just talking about gcloud iam service-accounts keys create in a comment"')")
assert_exit "$out" "0" "mint-shaped text inside a quoted string → not blocked"

out=$(run_hook "$(mkpayload Bash "grep -r 'aws iam create-access-key' docs/")")
assert_exit "$out" "0" "grep containing a mint-shaped needle as a quoted string → not blocked"

# -----------------------------------------------------------------------------
echo "== statement-boundary isolation — an unrelated later command can't combine with an earlier one"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'gcloud iam service-accounts keys list --iam-account=foo@bar.iam.gserviceaccount.com; echo create')")
assert_exit "$out" "0" "keys list ; echo create (different statements) → allowed"

# -----------------------------------------------------------------------------
echo "== Malformed / empty payloads exit 0 (top-level parse failure — fail-open, per header)"
# -----------------------------------------------------------------------------

out=$(run_hook "not-json-at-all")
assert_exit "$out" "0" "malformed JSON → allowed"

out=$(run_hook "{}")
assert_exit "$out" "0" "empty object → allowed"

out=$(run_hook '{"tool_name":"Bash"}')
assert_exit "$out" "0" "missing tool_input → allowed"

out=$(run_hook '{"tool_name":"Bash","tool_input":{}}')
assert_exit "$out" "0" "missing command → allowed"

out=$(run_hook "")
assert_exit "$out" "0" "empty stdin → allowed"

# -----------------------------------------------------------------------------
echo "== Summary"
# -----------------------------------------------------------------------------

total=$((pass+fail))
if (( fail == 0 )); then
  printf '%s%d/%d tests pass.%s\n' "$GREEN" "$pass" "$total" "$RESET"
  exit 0
else
  printf '%s%d/%d tests pass — %d failures.%s\n' "$RED" "$pass" "$total" "$fail" "$RESET"
  exit 1
fi

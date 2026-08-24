#!/usr/bin/env bash
# Test suite for hooks/refuse-irreversible-external-mutation.sh.
#
# Run with:
#   bash plugins/shipyard/hooks/tests/refuse-irreversible-external-mutation.test.sh
#
# Each test crafts a PreToolUse JSON payload for a Bash tool call, pipes it to
# the hook, and asserts on stderr + exit code. Exit 2 == blocked, exit 0 ==
# allowed (transparent).
#
# The hook blocks commands that irreversibly mutate live external state —
# deleting a hosted config row / secret / resource, tearing down managed
# infrastructure, unpublishing a package, or widening public access — while
# leaving every read, create, narrow, local, and session-owned-git-artifact
# equivalent untouched. See
# plugins/shipyard/hooks/refuse-irreversible-external-mutation.sh for the
# decision rules and issue #1519 for the motivating repro.
#
# The ALLOW half of this suite carries as much weight as the BLOCK half:
# issue #1519's "What NOT to do" section is explicit that read-only external
# access must keep working, and a hook that over-blocks pushes workers toward
# routing around it.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/../refuse-irreversible-external-mutation.sh"

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

out=$(run_hook "$(mkpayload Edit 'vercel env rm EXPO_PUBLIC_FCM_WEB_VAPID_KEY production')")
assert_exit "$out" "0" "Edit tool with a destructive-shaped string → not blocked"

out=$(run_hook "$(mkpayload Read 'gh secret delete FOO')")
assert_exit "$out" "0" "Read tool → not blocked"

# -----------------------------------------------------------------------------
echo "== Hosted environment-variable deletion is blocked (the #1519 repro)"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'vercel env rm EXPO_PUBLIC_FCM_WEB_VAPID_KEY production')")
assert_blocked_with "$out" "vercel-env-rm" "vercel env rm <name> production → blocked (the #1519 repro, verbatim)"

out=$(run_hook "$(mkpayload Bash 'vercel env remove MY_VAR production --yes')")
assert_blocked_with "$out" "vercel-env-rm" "vercel env remove → blocked"

out=$(run_hook "$(mkpayload Bash 'vercel --scope acme env rm MY_VAR production')")
assert_blocked_with "$out" "vercel-env-rm" "vercel with an intervening global flag → still blocked"

# -----------------------------------------------------------------------------
echo "== Hosted environment-variable READS and CREATES are allowed"
# -----------------------------------------------------------------------------
# This is the class #1519 explicitly protects: read-only external verification
# is high-value and the line is drawn at irreversible mutation, not at access.

out=$(run_hook "$(mkpayload Bash 'vercel env ls production')")
assert_exit "$out" "0" "vercel env ls → allowed (read)"

out=$(run_hook "$(mkpayload Bash 'vercel env pull .env.local')")
assert_exit "$out" "0" "vercel env pull → allowed (read)"

out=$(run_hook "$(mkpayload Bash 'vercel env add MY_VAR preview')")
assert_exit "$out" "0" "vercel env add → allowed (create is reversible)"

# -----------------------------------------------------------------------------
echo "== GitHub Actions secret / variable deletion is blocked"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'gh secret delete MY_TOKEN --repo owner/name')")
assert_blocked_with "$out" "gh-secret-delete" "gh secret delete → blocked"

out=$(run_hook "$(mkpayload Bash 'gh variable delete MY_VAR --repo owner/name')")
assert_blocked_with "$out" "gh-secret-delete" "gh variable delete → blocked"

out=$(run_hook "$(mkpayload Bash 'gh secret list --repo owner/name')")
assert_exit "$out" "0" "gh secret list → allowed (read)"

out=$(run_hook "$(mkpayload Bash 'gh secret set MY_TOKEN --body xxx --repo owner/name')")
assert_exit "$out" "0" "gh secret set → allowed (create)"

# -----------------------------------------------------------------------------
echo "== Hosted config-row deletion on the other common platforms is blocked"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'heroku config:unset MY_VAR --app myapp')")
assert_blocked_with "$out" "heroku-config-unset" "heroku config:unset → blocked"

out=$(run_hook "$(mkpayload Bash 'netlify env:unset MY_VAR')")
assert_blocked_with "$out" "netlify-env-unset" "netlify env:unset → blocked"

out=$(run_hook "$(mkpayload Bash 'flyctl secrets unset MY_SECRET --app myapp')")
assert_blocked_with "$out" "fly-secrets-unset" "flyctl secrets unset → blocked"

out=$(run_hook "$(mkpayload Bash 'supabase secrets unset MY_SECRET')")
assert_blocked_with "$out" "supabase-secrets-unset" "supabase secrets unset → blocked"

out=$(run_hook "$(mkpayload Bash 'wrangler secret delete MY_SECRET --name myworker')")
assert_blocked_with "$out" "wrangler-secret-delete" "wrangler secret delete → blocked"

out=$(run_hook "$(mkpayload Bash 'heroku config:set MY_VAR=1 --app myapp')")
assert_exit "$out" "0" "heroku config:set → allowed (create)"

out=$(run_hook "$(mkpayload Bash 'wrangler secret list --name myworker')")
assert_exit "$out" "0" "wrangler secret list → allowed (read)"

# -----------------------------------------------------------------------------
echo "== Cloud secret-store destruction is blocked"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'gcloud secrets delete my-secret --project myproj')")
assert_blocked_with "$out" "gcloud-secrets-destroy" "gcloud secrets delete → blocked"

out=$(run_hook "$(mkpayload Bash 'gcloud secrets versions destroy 3 --secret=my-secret')")
assert_blocked_with "$out" "gcloud-secrets-destroy" "gcloud secrets versions destroy → blocked"

out=$(run_hook "$(mkpayload Bash 'aws secretsmanager delete-secret --secret-id prod/db')")
assert_blocked_with "$out" "aws-secretsmanager-delete" "aws secretsmanager delete-secret → blocked"

out=$(run_hook "$(mkpayload Bash 'aws ssm delete-parameter --name /prod/db/password')")
assert_blocked_with "$out" "aws-ssm-delete-parameter" "aws ssm delete-parameter → blocked"

out=$(run_hook "$(mkpayload Bash 'aws ssm delete-parameters --names /a /b')")
assert_blocked_with "$out" "aws-ssm-delete-parameter" "aws ssm delete-parameters (plural) → blocked"

out=$(run_hook "$(mkpayload Bash 'az keyvault secret delete --vault-name v --name s')")
assert_blocked_with "$out" "az-keyvault-secret-delete" "az keyvault secret delete → blocked"

out=$(run_hook "$(mkpayload Bash 'az keyvault secret purge --vault-name v --name s')")
assert_blocked_with "$out" "az-keyvault-secret-delete" "az keyvault secret purge → blocked"

out=$(run_hook "$(mkpayload Bash 'firebase functions:secrets:destroy MY_KEY --project myproj')")
assert_blocked_with "$out" "firebase-secrets-destroy" "firebase functions:secrets:destroy → blocked"

# -----------------------------------------------------------------------------
echo "== Cloud secret-store READS are allowed"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'gcloud secrets list --project myproj')")
assert_exit "$out" "0" "gcloud secrets list → allowed (read)"

out=$(run_hook "$(mkpayload Bash 'gcloud secrets versions list my-secret')")
assert_exit "$out" "0" "gcloud secrets versions list → allowed (read)"

out=$(run_hook "$(mkpayload Bash 'gcloud secrets versions access latest --secret=my-delete-key')")
assert_exit "$out" "0" "a read whose RESOURCE NAME contains 'delete' → allowed (verb-token guard)"

out=$(run_hook "$(mkpayload Bash 'aws secretsmanager get-secret-value --secret-id prod/db')")
assert_exit "$out" "0" "aws secretsmanager get-secret-value → allowed (read)"

out=$(run_hook "$(mkpayload Bash 'firebase functions:list --project myproj')")
assert_exit "$out" "0" "firebase functions:list → allowed (the read the #1519 session did correctly)"

out=$(run_hook "$(mkpayload Bash 'gcloud firestore fields ttls list --project myproj')")
assert_exit "$out" "0" "gcloud firestore fields ttls list → allowed (read)"

# -----------------------------------------------------------------------------
echo "== Infrastructure teardown is blocked; plan/apply are not"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'terraform destroy -auto-approve')")
assert_blocked_with "$out" "terraform-destroy" "terraform destroy → blocked"

out=$(run_hook "$(mkpayload Bash 'terraform apply -destroy -auto-approve')")
assert_blocked_with "$out" "terraform-apply-destroy" "terraform apply -destroy → blocked"

out=$(run_hook "$(mkpayload Bash 'terraform plan')")
assert_exit "$out" "0" "terraform plan → allowed (read)"

out=$(run_hook "$(mkpayload Bash 'terraform plan -destroy')")
assert_exit "$out" "0" "terraform plan -destroy (a preview, not a teardown) → allowed"

out=$(run_hook "$(mkpayload Bash 'terraform apply -auto-approve')")
assert_exit "$out" "0" "terraform apply → allowed (create/converge)"

# -----------------------------------------------------------------------------
echo "== Public-registry unpublish is blocked"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'npm unpublish my-pkg@1.2.3')")
assert_blocked_with "$out" "npm-unpublish" "npm unpublish → blocked"

out=$(run_hook "$(mkpayload Bash 'npm publish --access public')")
assert_exit "$out" "0" "npm publish → allowed (not this hook's concern)"

out=$(run_hook "$(mkpayload Bash 'npm run unpublish-docs')")
assert_exit "$out" "0" "npm run unpublish-docs (hyphenated script name) → allowed (verb-token guard)"

# -----------------------------------------------------------------------------
echo "== Access-widening is blocked; narrowing is not"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'gcloud projects add-iam-policy-binding myproj --member=allUsers --role=roles/viewer')")
assert_blocked_with "$out" "iam-public-binding" "add-iam-policy-binding allUsers → blocked (widening)"

out=$(run_hook "$(mkpayload Bash 'gcloud run services add-iam-policy-binding svc --member=allAuthenticatedUsers --role=roles/run.invoker')")
assert_blocked_with "$out" "iam-public-binding" "add-iam-policy-binding allAuthenticatedUsers → blocked (widening)"

out=$(run_hook "$(mkpayload Bash 'gsutil iam ch allUsers:objectViewer gs://mybucket')")
assert_blocked_with "$out" "gsutil-iam-public" "gsutil iam ch allUsers → blocked (widening)"

out=$(run_hook "$(mkpayload Bash 'gh repo edit owner/name --visibility public --accept-visibility-change-consequences')")
assert_blocked_with "$out" "gh-repo-visibility-public" "gh repo edit --visibility public → blocked (widening)"

out=$(run_hook "$(mkpayload Bash 'gcloud projects remove-iam-policy-binding myproj --member=allUsers --role=roles/viewer')")
assert_exit "$out" "0" "remove-iam-policy-binding allUsers → allowed (this NARROWS access)"

out=$(run_hook "$(mkpayload Bash 'gcloud projects add-iam-policy-binding myproj --member=user:bob@example.com --role=roles/viewer')")
assert_exit "$out" "0" "add-iam-policy-binding for a named user → allowed (not public)"

out=$(run_hook "$(mkpayload Bash 'gh repo edit owner/name --visibility private')")
assert_exit "$out" "0" "gh repo edit --visibility private → allowed (this NARROWS access)"

# -----------------------------------------------------------------------------
echo "== Local, session-owned, and reversible operations pass through"
# -----------------------------------------------------------------------------
# The doctrine's carve-outs. Over-blocking here is its own failure mode.

out=$(run_hook "$(mkpayload Bash 'rm -rf node_modules')")
assert_exit "$out" "0" "local rm → allowed"

out=$(run_hook "$(mkpayload Bash 'gh pr merge 42 --repo owner/name --squash --delete-branch')")
assert_exit "$out" "0" "gh pr merge --delete-branch (session-owned artifact) → allowed"

out=$(run_hook "$(mkpayload Bash 'git push origin --delete do-work/issue-1519')")
assert_exit "$out" "0" "git push --delete of your own branch → allowed"

out=$(run_hook "$(mkpayload Bash 'gh issue close 42 --repo owner/name')")
assert_exit "$out" "0" "gh issue close (reversible metadata) → allowed"

out=$(run_hook "$(mkpayload Bash 'gh issue edit 42 --repo owner/name --remove-label shipyard')")
assert_exit "$out" "0" "gh issue edit --remove-label → allowed"

out=$(run_hook "$(mkpayload Bash 'kubectl delete pod mypod')")
assert_exit "$out" "0" "kubectl delete (deliberately out of scope — cluster target invisible) → allowed"

out=$(run_hook "$(mkpayload Bash 'docker rm mycontainer')")
assert_exit "$out" "0" "docker rm (local) → allowed"

out=$(run_hook "$(mkpayload Bash 'git status')")
assert_exit "$out" "0" "git status → allowed"

out=$(run_hook "$(mkpayload Bash 'npm test')")
assert_exit "$out" "0" "npm test → allowed"

# -----------------------------------------------------------------------------
echo "== Quoted text and statement boundaries do not fire false matches"
# -----------------------------------------------------------------------------

out=$(run_hook "$(mkpayload Bash 'echo "do not run vercel env rm here"')")
assert_exit "$out" "0" "destructive-shaped text inside a quoted string → not blocked"

out=$(run_hook "$(mkpayload Bash "grep -rn 'gh secret delete' docs/")")
assert_exit "$out" "0" "grep containing a destructive-shaped needle as a quoted string → not blocked"

out=$(run_hook "$(mkpayload Bash 'vercel env ls production; echo rm')")
assert_exit "$out" "0" "env ls ; echo rm (different statements) → allowed"

out=$(run_hook "$(mkpayload Bash 'gh secret list --repo owner/name && echo delete')")
assert_exit "$out" "0" "secret list && echo delete (different statements) → allowed"

out=$(run_hook "$(mkpayload Bash 'gh secret list --repo owner/name; gh secret delete FOO --repo owner/name')")
assert_blocked_with "$out" "gh-secret-delete" "a destructive SECOND statement is still caught on its own"

# -----------------------------------------------------------------------------
echo "== Block message names the hand-back path, not just the prohibition"
# -----------------------------------------------------------------------------
# A worker that only learns 'no' routes around the hook or strands its work.
# The message must carry the routing substring and the ship-the-code-half rule.

out=$(run_hook "$(mkpayload Bash 'vercel env rm MY_VAR production')")
assert_blocked_with "$out" "irreversible external action" "block message names the load-bearing bail substring"

out=$(run_hook "$(mkpayload Bash 'vercel env rm MY_VAR production')")
assert_blocked_with "$out" "agent-console" "block message names the agent-console routing destination"

out=$(run_hook "$(mkpayload Bash 'vercel env rm MY_VAR production')")
assert_blocked_with "$out" "#1519" "block message cites the motivating issue"

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

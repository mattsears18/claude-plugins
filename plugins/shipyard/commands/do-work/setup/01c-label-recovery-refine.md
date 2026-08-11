# /shipyard:do-work — Setup phase · label ensure + prior-session recovery + refine

**Setup sub-phase (cluster 2 of 5, part 3 of 3 — [#994](https://github.com/mattsears18/shipyard/issues/994)).** Owns steps **3 → 3.5**: ensure required labels exist, recover from a prior session (blocked:ci re-check, legacy-label migration sweeps, orphan-branch triage), and invoke the refinement pass. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`01b-backlog-overview.md`](./01b-backlog-overview.md) (same cluster, part 2). Next sub-phase: [`04-backlog-divert.md`](./04-backlog-divert.md).

### 3. Ensure label exists + recover from prior session

#### 3a. Ensure required labels exist (idempotent)

> **Background step — stays post-relocation ([#1202](https://github.com/mattsears18/shipyard/issues/1202)).** This step runs inside the background bash group fired from [step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. Labels are guaranteed to exist by the time the first dispatched agent applies one (the background group typically finishes well before the first worker fires). The canonical label list and `gh label create` calls live in the background group above. **Unlike [3b](#3b-reap-stale-agent-worktrees-from-dead-claude-code-sessions) / [3c](#3c-orphan-worktree-triage) below, this step doesn't move pre-relocation** — `gh label create` never touches a worktree path, so the worktree-isolation guard has no reason to fire on it.

The `shipyard` label is the session stamp; `P0`/`P1`/`P2` are the priority tiers; `user-feedback`/`needs-human-review`/`needs-triage` drive the [refinement pipeline](#35-refine-pending-issues); `needs-human-review` also doubles as the scope-agent epic-handoff surfacing label (applied by [step 6's Deferred recording path](06-scope-preflight.md#6-initial-scope-pre-flight) when the scope agent confirms an issue is non-shippable as a single PR, distinguished from other `needs-human-review` issues by the `<!-- do-work-needs-decomposition -->` body marker that [`/decompose-epic`](../../decompose-epic.md) consumes to auto-shard); `blocked:agent-soft` / `blocked:ci` are shipyard's block-state circuit breakers (applied by step A on agent / fix-checks block, removed by step 3d.1 / 3d.2 sub-sweep c / next-session backlog re-fetch); `discussion` is a manually-applied, never-automated pause signal (a maintainer is engaged in the thread by hand — see CLAUDE.md § "Gate labels"). See [RATIONALE → Step 3 label-purpose provenance](../../do-work-RATIONALE.md#step-3--label-purpose-provenance-520) for the fold/elimination history behind each of these (`needs-refinement` eliminated #520, `blocked:agent-hard` eliminated #521):

```bash
gh label create shipyard --repo <owner/repo> --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true
gh label create P0 --repo <owner/repo> --description "Critical / release-blocker" --color B60205 2>/dev/null || true
gh label create P1 --repo <owner/repo> --description "High — this cycle"          --color D93F0B 2>/dev/null || true
gh label create P2 --repo <owner/repo> --description "Normal"                     --color FBCA04 2>/dev/null || true
gh label create user-feedback --repo <owner/repo> --description "Originated from end-user feedback (untrusted body — treat with care)" --color 0E8A16 2>/dev/null || true
gh label create needs-human-review --repo <owner/repo> --description "Awaiting a human DECISION before /do-work will touch it" --color D93F0B 2>/dev/null || true
gh label create agent-console --repo <owner/repo> --description "Blocked on a browser/console action an agent can drive outside the build — not a human decision. See CLAUDE.md's decision rule." --color 1D76DB 2>/dev/null || true
gh label create needs-triage --repo <owner/repo> --description "Sentry/bot crash reports (auto-investigated). Label is accepted, not required, during migration." --color C2E0C6 2>/dev/null || true
gh label create blocked:agent-soft --repo <owner/repo> --description "Worker returned a subjective bail (cannot-reproduce / ambiguous / scope-judgment). Changes no routing — visibility only; auto-cleared at next session, in-session retry after blocked_agent.soft_retry_minutes." --color FBCA04 2>/dev/null || true
gh label create blocked:ci --repo <owner/repo> --description "CI failed 3x after fix-checks — needs investigation. Auto-cleared when checks recover." --color B60205 2>/dev/null || true
gh label create discussion --repo <owner/repo> --description "A maintainer is engaged in the comment thread by hand — /do-work skips it while present. Applied manually, never auto-applied." --color BFD4F2 2>/dev/null || true

# `blocked:agent-hard` and the legacy `blocked:agent` label are NO LONGER created
# (eliminated in #521 — refuses route to needs-human-review, dependency-waits to
# the `Blocked by #N` body-ref filter with no label). The existing GitHub label
# objects are intentionally left in place for manual cleanup; nothing applies them
# anymore, and step 3d.2 sub-sweep b migrates any still-attached legacy label off.
#
# `needs-operator` (the pre-#995 name for `agent-console`) is likewise NOT
# created here — only `agent-console` is. The #995 migration window is CLOSED
# as of #1082 (zero issues in this repo carried `needs-operator` at the time)
# — no site matches on the legacy name anymore; an unrenamed pre-#995 label
# object left on a repo is now inert.
#
# RETIRED — never add a `gh label create` line for any of these below; doing
# so would recreate exactly the drift #1081 found (a folded label kept being
# applied to fresh issues because it stayed present in the label picker):
#   needs-refinement    — eliminated #520; GitHub label object deleted #859
#   needs-design        — folded into needs-human-review #515
#   needs-decomposition — folded into needs-human-review #519
#   tracking             — folded into needs-human-review #519. The label
#                          object itself was never deleted (unlike
#                          needs-refinement above), so it kept landing on new
#                          epics — #1081 additionally re-added `tracking` to
#                          04-backlog-divert.md's dispatch-exclusion
#                          enumeration as a defensive gate, on top of this
#                          file's step 3d.2 sub-sweep e migration.
#   blocked:agent        — superseded by needs-human-review / no-label #521;
#                          zero all-time usage in this repo. Object left in
#                          place for manual cleanup — see #1082.
#   blocked:agent-hard   — eliminated #521 (see above). Zero all-time usage.
#                          Object left in place for manual cleanup — #1082.
#   needs-operator       — renamed to agent-console #995; migration window
#                          closed #1082. Zero all-time usage. Object left in
#                          place for manual cleanup.
#   needs-human          — referenced in investigate.md's step-0 bail list
#                          before #1082 but the label object never existed in
#                          this repo — a dead reference, not a retired label.
#                          Removed from investigate.md; nothing to clean up
#                          on GitHub. Don't reintroduce it.
#   blocked (bare)        — superseded by needs-human-review #1082 → #1128.
#                          Never created here (zero all-time usage in this
#                          repo); the 6 open lightwork issues that carried it
#                          were migrated to needs-human-review before the
#                          step-0 bail conditions in issue-work.md,
#                          investigate.md, and spike.md were dropped. Distinct
#                          from the blocked:* family above — don't conflate.
```

#### 3b. Reap stale agent worktrees from dead Claude Code sessions

> **MOVED pre-relocation ([#1202](https://github.com/mattsears18/shipyard/issues/1202)) — no longer part of the post-relocation background group; this section is now the canonical implementation.** This sweep's `git -C <other-worktree>`-shaped operations against `agent-*` worktrees other than the orchestrator's own are refused outright once [step 0.5](00-config-worktree.md#05-move-into-the-orchestrators-worktree)'s `EnterWorktree` has isolated the session. It now runs synchronously at [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202), before relocation — which is also where the `.in_flight` guard below gets a session-state file to read from (session-state init moved to the same step, ahead of this sweep, for exactly that reason). **Resolve `CLAUDE_PLUGIN_ROOT` via step 0.3's pre-relocation compound preamble** (the `.shipyard-plugin-root` stash below is a step-0.5-and-later artifact and doesn't exist yet at this point in the session).

The harness writes a lock file at `.git/worktrees/agent-<id>/locked` containing `claude agent <id> (pid <N>)`. The lock survives the harness process exiting. Reap every agent worktree whose lock-holding PID is dead; skip ones owned by live PIDs (could be another active Claude Code instance) — **unless the lock is stale enough that a live PID is more likely a recycled one than a genuine peer** (issue [#755](https://github.com/mattsears18/shipyard/issues/755); see [`worktree-reap.sh`'s `classify-lock` docstring](../../../scripts/worktree-reap.sh) for the full rationale). `classify-lock` applies this staleness corroboration itself — no separate check is needed here.

**Bulk classify + bounded/checkpointed removal, not a per-worktree loop (issue #836).** An earlier version of this sweep looped `classify-lock` once PER worktree (one full script re-invocation, each forking its own `ps`/`stat` subprocesses) and removed every reap-eligible one unbounded. On a repo with a large accumulated backlog (the #836 repro: 60 worktrees, ~1.6GB each, ~90GB total) that loop blew its time budget before classifying a single candidate. `worktree-reap.sh reap-stale` is the single executable source of truth for both the bulk classify (one `ps` call / one self-ancestor walk / one batched `stat` for the whole batch, instead of O(n) subprocess forks) and the bounded, checkpointed removal (reaps at most `worktree_reap.max_per_session` per session, oldest-first; the on-disk backlog left behind IS the checkpoint, so a session that can't clear it all still makes forward progress and the next session's sweep continues from there). See `scripts/worktree-reap.sh`'s `classify_all` / `reap_stale` docstrings for the full algorithm.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
cd "$(git rev-parse --show-toplevel)"   # be robust to subdir invocation

# Threshold warning (issue #836 fix 4) — surface a large agent-* backlog
# in the session banner even though the per-session cap means it won't
# all clear in one pass. Two cheap reads gate the (potentially slower)
# size probe: only pay for `du` when the count actually crosses the
# threshold.
wt_count=$(find .git/worktrees -maxdepth 1 -type d -name 'agent-*' 2>/dev/null | wc -l | tr -d ' ')
warn_threshold=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get worktree_reap.warn_threshold 2>/dev/null || echo "20")
if [ "${wt_count:-0}" -gt 0 ] && [ "${wt_count:-0}" -ge "${warn_threshold:-20}" ] 2>/dev/null; then
  # `find` (not a bare `.claude/worktrees/agent-*` glob) feeds `du -sk` so
  # the zsh nomatch hazard the #335 comment above already documents for
  # the `agent-*` find loop can't fire here either. Single `du` invocation
  # over every path at once (not one call per worktree) — `du` walks the
  # same file set either way, so batching is a pure subprocess-count win,
  # same rationale as classify-all's batched `ps`/`stat`.
  reclaimable_kb=$(find .claude/worktrees -maxdepth 1 -type d -name 'agent-*' -print0 2>/dev/null \
    | xargs -0 du -sk 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
  reclaimable_human=$(( (reclaimable_kb + 1023) / 1024 ))
  cat <<EOF
⚠️  worktree backlog: ${wt_count} agent-* worktrees on disk (~${reclaimable_human} MB reclaimable),
   at or above the ${warn_threshold}-worktree warn threshold (worktree_reap.warn_threshold).
   This session's step-3b sweep reaps at most worktree_reap.max_per_session
   of them (oldest-first) — the rest are left for subsequent sessions to
   continue draining. See issue #836 if the backlog isn't shrinking session
   over session.
EOF
fi

# Detect the orchestrator's PID once and export it so classify-all's
# self-ancestor short-circuit fires reliably (issue #263) — the harness
# writes the orchestrator's PID into every dispatched agent's lock, and
# without this declaration the ancestor walk can fail to find it whenever
# an intermediate harness layer returns empty PPID.
export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" detect-orchestrator-pid)

# In-flight guard (issue #832) — snapshot the set of agent-ids this
# session currently has dispatched, BEFORE reap-stale ever consults
# classification. In-flight membership is authoritative liveness; the
# lock file's classification is only a fallback for worktrees THIS
# session doesn't own (cross-session stragglers, which is what this
# sweep exists to clean up). Branch name is NEVER a liveness signal —
# see `commands/do-work/dont.md`'s "Don't reap a live-PID worktree"
# bullet for why a name-based filter has a race window that would
# delete an in-flight agent. At the pre-relocation execution point
# (step 0.45), this session has typically dispatched nothing yet — but
# the read is cheap and correct either way, and keeps this block
# identical to the form used if a later session ever needs to re-run it.
in_flight_agent_ids=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" read \
  --session-id "<session-id>" --path .in_flight 2>/dev/null \
  | jq -r '.[]?.agent_id // empty' 2>/dev/null)
exclude_flags=()
while IFS= read -r aid; do
  [ -z "$aid" ] && continue
  exclude_flags+=(--exclude-agent-id "$aid")
done <<< "$in_flight_agent_ids"

max_per_session=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get worktree_reap.max_per_session 2>/dev/null || echo "10")

reap_output=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap-stale \
  --repo-root "$(pwd)" \
  --session-id "<session-id>" \
  --max-per-session "${max_per_session:-10}" \
  "${exclude_flags[@]}" 2>/dev/null)

# The summary line is always the LAST line of reap-stale's output —
# surface it verbatim so the reaped-vs-deferred-vs-remaining backlog is
# visible rather than silent (issue #836 fix 2's "emit a one-line count").
summary_line=$(printf '%s\n' "$reap_output" | tail -1)
echo "[setup-3b] ${summary_line}"

git worktree prune 2>/dev/null || true
```

`reap-stale`'s summary line (`summary: reaped=<R> deferred=<D> unreaped=<U> remaining=<REMAIN>`) is what surfaces in the end-of-session summary. A non-zero `unreaped` means a reap was refused (auto-mode permission classifier, a dirty worktree carrying unpushed commits, or a filesystem error); the summary pairs the count with the `/clean_gone` remediation rather than degrading silently ([#712](https://github.com/mattsears18/shipyard/issues/712)).

#### 3c. Orphan worktree triage

Scan for `do-work/*` branches whose worktrees survived step 3b (legitimate orphans from THIS session, not dead-process leftovers).

> **MOVED pre-relocation ([#1202](https://github.com/mattsears18/shipyard/issues/1202)) — no longer part of the post-relocation background group; this section is now the canonical implementation.** Both the discovery query and the handling (`git -C <path>` reads, `git worktree remove`, `git branch -D`, `git -C <path> push` — every one of them against a worktree other than the orchestrator's own) are refused once [step 0.5](00-config-worktree.md#05-move-into-the-orchestrators-worktree)'s `EnterWorktree` has isolated the session. It now runs synchronously at [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202), before relocation, right after [3b](#3b-reap-stale-agent-worktrees-from-dead-claude-code-sessions). Neither gates dispatch decisions; the discovery query is cheap and the expensive push/PR-create branch only fires when orphans exist. **Resolve `CLAUDE_PLUGIN_ROOT` via step 0.3's pre-relocation compound preamble**, same as [3b](#3b-reap-stale-agent-worktrees-from-dead-claude-code-sessions) above.

```bash
git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\//{print $2}' | sed 's|refs/heads/||'
```

For each `do-work/issue-<N>` branch found, resolve its worktree path with `git worktree list | grep "\[do-work/issue-<N>\]" | awk '{print $1}'` (`<path>` below), then inspect its state and act according to the table. Track `salvaged_count` (worktrees that produced or kept an open PR), `abandoned_count` (worktrees removed), and `stale_assigns_count` (issues whose `@me` self-assign was cleared by the fifth row's no-worktree-no-PR-no-branch sweep) — all three default to 0 and feed into the end-of-session summary.

All git/gh commands below run with `-C <path>` (or `(cd <path> && ...)` for `gh pr create`) so they operate on the orphan worktree, not the orchestrator's main checkout.

| Worktree state | How to detect | Action |
|---|---|---|
| No commits beyond base | `git -C <path> rev-list --count origin/<default-branch>..HEAD` returns `0` | `git worktree remove --force <path>` → `git branch -D do-work/issue-<N>` → `gh issue edit <N> --repo <owner/repo> --remove-assignee @me`. `abandoned_count++`. Issue flows back into the backlog on the normal fetch (step 4). |
| Only uncommitted edits, no commits | Same `rev-list` returns `0` but `git -C <path> status --porcelain` is non-empty | Same as above — partial WIP from an agent mid-edit is not coherent enough to push. `abandoned_count++`. |
| Commits ahead, not pushed | `git -C <path> rev-list --count origin/<default-branch>..HEAD` > 0 AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `git -C <path> push -u origin do-work/issue-<N>` → `gh pr list --repo <owner/repo> --head do-work/issue-<N> --json number --jq '.[0].number'`; if empty, `(cd <path> && gh pr create --repo <owner/repo> --fill --label shipyard)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, no PR open | Same `rev-list` > 0 AND `ls-remote` shows the branch AND `gh pr list --head` is empty | `(cd <path> && gh pr create --repo <owner/repo> --fill --label shipyard)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, PR open | `gh pr list --head` returns a PR number | `gh pr view <M> --repo <owner/repo> --json statusCheckRollup --jq '[.statusCheckRollup \| group_by(.name) \| map(sort_by(.completedAt // .startedAt // "") \| last) \| .[] \| select((.conclusion // .status // "") \| test("FAILURE\|ERROR\|TIMED_OUT\|CANCELLED\|ACTION_REQUIRED"))] \| length'`. If count > 0 → push `{number: <M>, ...}` onto `failed_prs`. Otherwise leave alone — auto-merge will handle it. `salvaged_count++`. Latest-per-name projection per issue [#333](https://github.com/mattsears18/shipyard/issues/333) — a naïve `.statusCheckRollup[]` walk would false-positive on stale superseded FAILUREs. |
| Branch is `[gone]` upstream | `git branch -v` shows `[gone]` next to the branch name | `(no-op — handled by end-of-session cleanup)` |
| **Self-assigned with no worktree, no PR, no branch on origin** (issue [#303](https://github.com/mattsears18/shipyard/issues/303); gated on `backlog.self_assign`, config default `false` — issue [#1248](https://github.com/mattsears18/shipyard/issues/1248)) | After the worktree loop above, run `gh issue list --repo <owner/repo> --state open --assignee @me --label shipyard --search '-linked:pr' --json number` and for each result confirm `[ ! -d <repo-root>/.claude/worktrees/agent-* ]` doesn't claim it (no worktree-on-disk this loop already touched) AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `gh issue edit <N> --repo <owner/repo> --remove-assignee @me` (leave the `shipyard` label as provenance — it's not load-bearing for re-dispatch). `stale_assigns_count++`. Next dispatch retries from scratch. |

The fifth row closes a gap where prior sessions could leave the `@me` self-assign on an issue after their on-disk worktree was cleaned up — the first four rows only see issues whose worktree is still present, so this state otherwise survives unbounded across sessions. See [RATIONALE → Step 3c stale self-assign gap](../../do-work-RATIONALE.md#step-3c--the-stale-self-assign-gap-303) for the fuller failure mode (issue #303).

**This entire row is gated on `backlog.self_assign` ([#1248](https://github.com/mattsears18/shipyard/issues/1248)).** The row exists solely to undo a self-assignment `/do-work` itself wrote — when `backlog.self_assign` is `false` (the default), the orchestrator never calls `--add-assignee @me` in the first place, so there is nothing this sweep could ever find: the `gh issue list --assignee @me` query would always come back empty (net effect: a wasted API call every session, forever). Skip the entire query + loop below when `backlog.self_assign` resolves `false`; run it unchanged when `true`.

The row's action is intentionally conservative: clear the assignment only, leave the `shipyard` label (provenance — it tells the next session this issue went through `/do-work` before), let the normal step-4 backlog fetch pick the issue back up, and let the orchestrator's normal dispatch path arrange a fresh worktree. Don't touch the issue body, don't post a comment, don't close — the issue may genuinely still be workable and the prior session's `blocked` may have been transient.

**Executable form** (the table above is the at-a-glance summary; this is what actually runs):

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
cd "$(git rev-parse --show-toplevel)"   # be robust to subdir invocation
stale_assigns_count=0
declare -a stale_assigns_numbers
git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\//{print $2}' | sed 's|refs/heads/||' | while read -r branch; do
  path=$(git worktree list | grep "\[$branch\]" | awk '{print $1}')
  [ -z "$path" ] && continue
  # Issue #739 — extract the issue number permissively so a collision-
  # fallback LOCAL branch name (`do-work/issue-<N>-<timestamp>`, produced
  # by issue-work.md §3 when a prior worktree still held the canonical
  # name — see #736/#738) still resolves to `<N>`, not the garbage
  # compound string `<N>-<timestamp>`. `canonical_branch` is what the
  # collision-fallback worker actually pushed to and opened its PR
  # against (its own local checkout may be named differently), so every
  # remote/PR lookup below must key off it, never off `$branch` verbatim.
  n=$(echo "$branch" | sed -E 's|^do-work/issue-([0-9]+).*|\1|')
  canonical_branch="do-work/issue-$n"
  ahead=$(git -C "$path" rev-list --count "origin/<default-branch>..HEAD" 2>/dev/null || echo 0)
  if [ "$ahead" -eq 0 ]; then
    # Issue #712 — non-force FIRST, force only behind evidence. `git worktree
    # remove` (no --force) refuses on a dirty tree, which is the exact safety
    # property Claude Code's auto-mode permission classifier is protecting
    # when it denies a bare `--force` as [Irreversible Local Destruction]. The
    # `ahead -eq 0` test immediately above IS the preceding, explicit check
    # that makes the escalation safe here: this worktree carries no commits
    # beyond the base branch, so nothing being force-removed exists only here.
    git worktree remove "$path" 2>/dev/null \
      || git worktree remove --force "$path" 2>/dev/null
    git branch -D "$branch" 2>/dev/null
    gh issue edit "$n" --repo <owner/repo> --remove-assignee @me 2>/dev/null || true
  else
    # Resolve against the CANONICAL remote branch name, not `$branch`
    # verbatim — a collision-fallback worker's local branch carries a
    # disambiguating suffix, but it pushes and opens its PR against
    # `do-work/issue-<N>` (see issue-work.md §3/§5). Checking `$branch`
    # here would never find that push, causing this sweep to push a
    # second, spurious remote branch and then open a duplicate PR.
    pushed=$(git ls-remote --heads origin "$canonical_branch" 2>/dev/null)
    if [ -z "$pushed" ]; then
      git -C "$path" push -u origin "HEAD:refs/heads/$canonical_branch" 2>/dev/null || true
    fi
    open_pr=$(gh pr list --repo <owner/repo> --head "$canonical_branch" --json number --jq '.[0].number' 2>/dev/null)
    if [ -z "$open_pr" ]; then
      (cd "$path" && gh pr create --repo <owner/repo> --head "$canonical_branch" --fill --label shipyard 2>/dev/null) || true
      pr_num=$(gh pr list --repo <owner/repo> --head "$canonical_branch" --json number --jq '.[0].number' 2>/dev/null)
      # #720: gate the arm behind the ungated-merge detector. This PR is a
      # PRIOR session's orphaned branch, opened with `--fill` — nothing in this
      # session ever reviewed its diff. On an ungated repo `--auto` is not a
      # queue; it direct-merges that unreviewed work immediately, and the
      # `2>/dev/null || true` makes it silent. Fail-safe: an unreadable verdict
      # resolves to `ungated` (defer), never to an immediate merge.
      if [ -n "$pr_num" ]; then
        verdict=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ungated-admin-direct-merge.sh" \
          <owner/repo> 2>/dev/null || echo ungated)
        # Resolve the merge method from config — never hardcode --merge (#989).
        auto_merge_method=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get auto_merge.method 2>/dev/null)
        case "$auto_merge_method" in squash|merge|rebase) ;; *) auto_merge_method=squash ;; esac
        if [ "$verdict" = "gated" ]; then
          # Capture stderr instead of discarding it (#850) — the same
          # missing-`workflow`-OAuth-scope block a worker's own arm can hit
          # (worker-preamble auto-merge.md step 1.1, #812) can hit this
          # setup-3c orphan-recovery arm too; `2>/dev/null || true` was
          # previously swallowing it with zero visibility.
          merge_arm_err=$(gh pr merge "$pr_num" --repo <owner/repo> --auto --${auto_merge_method} --delete-branch 2>&1 1>/dev/null) || true
          if printf '%s' "$merge_arm_err" | grep -qi "without .workflow. scope"; then
            echo "[setup-3c] PR #${pr_num} auto-merge arm blocked — gh token lacks workflow scope (#850); left OPEN unarmed"
          fi
        else
          # Leave OPEN + unarmed. The PR carries `--label shipyard` (above),
          # which is exactly the label drain's deferred-merge lander keys on —
          # so it gets merged on the first poll its checks are green, with no
          # `session_prs` plumbing needed. Do NOT block on `gh pr checks
          # --watch` here — this would stall session start, once per orphan.
          echo "[setup-3c] PR #${pr_num} left unarmed (ungated repo) — deferred to drain's merge lander (#720)"
        fi
      fi
    fi
  fi
done
# The "[setup-3c] PR #<N> auto-merge arm blocked" line above runs inside
# this piped `while read` loop (a subshell), so it cannot persist a value
# back into the enclosing shell's own variables. That's fine —
# workflow_scope_blocked_prs is orchestrator state (see do-work.md's
# "Orchestrator state" section), not a literal shell variable spanning tool
# calls: when this block's captured stdout is surfaced, append <N> to
# workflow_scope_blocked_prs for every such line, exactly as
# steady-state.md step A.1's shipped-handler already does from a worker's
# return string (issue #812 / #850).

# Row 5 — Stale @me self-assigns with no worktree, no PR, no branch
# (issue #303). Catches the state the worktree loop above CAN'T see: a
# prior session that left the @me assignment on an issue after its
# on-disk worktree was already cleaned up. Without this sweep the
# assignment survives indefinitely across sessions. Action is
# conservative: clear the assignment only, leave the `shipyard` label as
# provenance, and let the normal step-4 backlog fetch pick the issue up
# on the next dispatch.
#
# Gated on backlog.self_assign (issue #1248) — when self-assign is off
# (the default), /do-work never writes an @me assignment, so this sweep
# has nothing to find; skip the query entirely rather than pay a
# permanently-empty `gh issue list` every session.
BACKLOG_SELF_ASSIGN=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get backlog.self_assign 2>/dev/null || echo "false")
if [ "$BACKLOG_SELF_ASSIGN" = "true" ]; then
  for n in $(gh issue list --repo <owner/repo> --state open --assignee @me --label shipyard --search '-linked:pr' --json number --jq '.[].number' 2>/dev/null); do
    # If a worktree for this issue exists, the loop above already handled it;
    # skip. Extract issue numbers from every do-work worktree branch the same
    # permissive way as the loop above (#739) so a collision-fallback local
    # branch name (`do-work/issue-$n-<timestamp>`) is still recognized as
    # "already handled" instead of falling through to the assignee-clear
    # below on an issue whose worktree is alive, just suffixed.
    if git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\/issue-/{print $2}' \
      | sed -E 's|^refs/heads/do-work/issue-([0-9]+).*|\1|' | grep -qx "$n"; then
      continue
    fi
    # If a do-work branch for this issue still exists on origin, leave it
    # alone — it may belong to an open PR the `-linked:pr` filter missed
    # (e.g., draft PR linked via a different reference shape). Conservative
    # gate: only clear assignment when NOTHING in the dispatch artifacts
    # exists for this issue anymore.
    if [ -n "$(git ls-remote --heads origin "do-work/issue-$n" 2>/dev/null)" ]; then
      continue
    fi
    gh issue edit "$n" --repo <owner/repo> --remove-assignee @me 2>/dev/null || true
    stale_assigns_count=$((stale_assigns_count + 1))
    stale_assigns_numbers+=("$n")
  done
fi
```

**3d.1. Auto-clear stale `blocked:ci` labels.** The label is sticky on purpose, but a new commit on the PR's head branch means the premise ("no movement since shipyard gave up") is no longer true. Auto-clear those PRs so they flow back into step 5's failing-PR snapshot for another 3 attempts. This sweep is the *only* place `blocked:ci` is removed by the orchestrator (step A applies; 3d.1 removes; no other step touches it).

> **`--fast` skip:** When `--fast` is set, skip this entire sweep. The initial `blocked:ci` count (`fast_skip_blocked_ci`) captured in step 2's `--fast` note is sufficient for the advisory summary — stale `blocked:ci` labels persist until the next normal session. Set `cleared_ciblocked=0` and `held_ciblocked=0`.

Fire the initial PR list as part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch); per-PR `events` + `commits` lookups are a second-tier parallel batch. The serial loop below is shown for readability:

```bash
# All open PRs currently carrying blocked:ci, regardless of author. Foreign authors
# matter here too — the sweep is about the label's premise, not who owns the PR.
gh pr list --repo <owner/repo> --state open --label blocked:ci --limit 200 \
  --json number,headRefOid,headRefName \
  > /tmp/do-work-ciblocked-prs.json

cleared_ciblocked=0
held_ciblocked=0
declare -a cleared_pr_numbers
declare -a held_pr_numbers

for pr in $(jq -r '.[].number' /tmp/do-work-ciblocked-prs.json); do
  head_oid=$(jq -r --argjson n "$pr" '.[] | select(.number == $n) | .headRefOid' /tmp/do-work-ciblocked-prs.json)

  # Newest `labeled` event for blocked:ci on this PR (shipyard, a bot, or a human — doesn't matter who).
  # We're comparing "when was this label applied" against "when was the last commit on the head branch."
  label_ts=$(gh api "repos/<owner/repo>/issues/$pr/events" --paginate \
    --jq '[.[] | select(.event == "labeled" and .label.name == "blocked:ci")] | sort_by(.created_at) | last | .created_at')

  # When was the head commit authored?
  commit_ts=$(gh api "repos/<owner/repo>/commits/$head_oid" --jq '.commit.committer.date')

  if [ -z "$label_ts" ] || [ -z "$commit_ts" ]; then
    # Can't compute — leave the label alone, log advisory.
    held_ciblocked=$((held_ciblocked + 1))
    held_pr_numbers+=("$pr")
    continue
  fi

  # Compare ISO-8601 timestamps lexicographically (UTC-Z form sorts correctly).
  if [[ "$commit_ts" > "$label_ts" ]]; then
    gh pr edit "$pr" --repo <owner/repo> --remove-label blocked:ci
    cleared_ciblocked=$((cleared_ciblocked + 1))
    cleared_pr_numbers+=("$pr")
  else
    held_ciblocked=$((held_ciblocked + 1))
    held_pr_numbers+=("$pr")
  fi
done
```

Record `cleared_ciblocked` and `held_ciblocked` (plus the matching PR-number arrays). Cleared PRs flow into step 5's failing-PR snapshot naturally.

**Regression guard.** The `commit_ts > label_ts` comparison enforces "auto-clear fires only when a new commit has landed since the label was applied." If the comparison can't be computed (head branch deleted, events aged out of the ~90-day pagination window, network blip), hold — the safe default is to preserve the block. See [RATIONALE → Step 3d sweeps](../../do-work-RATIONALE.md#step-3d--the-blockedci-sweep-and-why-the-blockedagent-hard-referential-sweep-was-deleted-in-521).

**3d.2. Migrate legacy labels + sweep `blocked:agent-soft`.** Five sub-sweeps run in sequence, all before step 4's backlog fetch. Sub-sweep a (the former `blocked:agent-hard` referential clear) no longer exists — see [RATIONALE → blocked:agent-hard elimination](../../do-work-RATIONALE.md#blockedagent-hard-elimination-issue-521) for why it was deleted in [#521](https://github.com/mattsears18/shipyard/issues/521). Sub-sweep b (legacy migration) is **re-pointed** to the #521 routing; sub-sweep c (`blocked:agent-soft`) is unchanged. Sub-sweeps d/e/f ([#537](https://github.com/mattsears18/shipyard/issues/537)) migrate the remaining legacy gate labels left over from the [#515](https://github.com/mattsears18/shipyard/issues/515)/[#519](https://github.com/mattsears18/shipyard/issues/519)/[#521](https://github.com/mattsears18/shipyard/issues/521) folds: `needs-design` → `needs-human-review`; `needs-decomposition`/`tracking` → `needs-human-review` + `<!-- do-work-needs-decomposition -->` marker comment; `blocked:agent-hard` → same refuse/dependency-wait discriminator as sub-sweep b. All are idempotent one-shot-per-issue (the old label is removed, so a second pass finds nothing to migrate).

> **`--fast` skip:** When `--fast` is set, skip all five sub-sweeps. The initial label counts (`fast_skip_blocked_agent_soft`, `fast_skip_blocked_agent_legacy`, `fast_skip_legacy_needs_design`, `fast_skip_legacy_needs_decomposition`, `fast_skip_legacy_tracking`, `fast_skip_legacy_blocked_agent_hard`) captured in step 2's `--fast` note are sufficient for the advisory summary — stale labels persist until the next normal session. Set every `cleared_*`, `migrated_*`, and `held_*` counter to 0.

Fire the initial issue lists (one per label) in the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch); per-issue blocker lookups read through the [`blocker_state` cache](00b-parallelization-cache.md#08-blocker_state-cache-default-on). Serial loop shown for readability.

**Sub-sweep b — legacy `blocked:agent` migration (re-pointed per [#521](https://github.com/mattsears18/shipyard/issues/521)).** Pre-#300 sessions stamped a single `blocked:agent` label. Re-point it by the same discriminator the bail handler uses (see [RATIONALE → blocked:agent-hard elimination](../../do-work-RATIONALE.md#blockedagent-hard-elimination-issue-521)) — **presence of an open `Blocked by #N` reference**: a legacy issue with an open `Blocked by #N` is a dependency-wait → just **remove** the legacy label and let the body-ref filter gate it (no replacement label); otherwise it's an unclassifiable legacy refuse → **`needs-human-review`** (a human must look). The legacy label is removed in both branches.

```bash
# All open issues carrying the bare `blocked:agent` label (but NOT also
# blocked:agent-soft — that's already classified). Cheap: at most one extra
# gh call this session.
gh issue list --repo <owner/repo> --state open --label blocked:agent --limit 200 \
  --json number,body,labels \
  --jq '[.[] | select((.labels[].name | IN("blocked:agent-soft")) | not) | {number, body}]' \
  > /tmp/do-work-blocked-legacy-issues.json

migrated_legacy_dep=0      # → no label (dependency-wait, body-ref filter gates it)
migrated_legacy_review=0   # → needs-human-review (unclassifiable legacy refuse)
declare -a migrated_legacy_dep_numbers
declare -a migrated_legacy_review_numbers
for n in $(jq -r '.[].number' /tmp/do-work-blocked-legacy-issues.json); do
  body=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body' /tmp/do-work-blocked-legacy-issues.json)

  # Same `Blocked by #N` extraction the bail handler uses. Any reference to a
  # still-OPEN issue ⇒ dependency-wait; reads through the blocker_state cache.
  blockers=$(printf '%s' "$body" | grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
  has_open_blocker=false
  for b in $blockers; do
    state="${blocker_state[$b]:-}"
    if [ -z "$state" ]; then
      state=$(gh issue view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null \
        || gh pr view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null || echo "")
      [ -z "$state" ] && state="unresolvable"
      blocker_state[$b]="$state"
    fi
    case "$state" in OPEN) has_open_blocker=true; break ;; esac
  done

  if $has_open_blocker; then
    # Dependency-wait: drop the legacy label; the body-ref filter gates dispatch
    # and auto-clears when the referenced blocker closes. No replacement label.
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Removed legacy \`blocked:agent\` per [#521](https://github.com/mattsears18/shipyard/issues/521). This issue carries an open \`Blocked by #N\` reference, so it's gated by the \`Blocked by #N\` body-reference filter (no label needed) and becomes workable automatically when the blocker closes." 2>/dev/null || true
    migrated_legacy_dep=$((migrated_legacy_dep + 1))
    migrated_legacy_dep_numbers+=("$n")
  else
    # Unclassifiable legacy refuse: route to needs-human-review.
    gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Migrated legacy \`blocked:agent\` → \`needs-human-review\` per [#521](https://github.com/mattsears18/shipyard/issues/521). The original label predates the refuse/dependency-wait split and carries no open \`Blocked by #N\` reference, so it's treated as a refuse: a human must review before re-dispatch. If the original block was subjective (cannot-reproduce / ambiguous / scope-judgment), swap the label to \`blocked:agent-soft\` to opt into next-session auto-clear." 2>/dev/null || true
    migrated_legacy_review=$((migrated_legacy_review + 1))
    migrated_legacy_review_numbers+=("$n")
  fi
done
```

The migration runs **once per legacy issue** — after the first run there are no more bare-`blocked:agent`-labeled issues. The label itself stays registered (the `gh label create` at the top of step 3d still fires for it) so a future audit can confirm zero open issues carry it before deletion. Eventually (after a few sessions with zero legacy hits) the label can be deleted via `gh label delete blocked:agent`. (`migrated_legacy = migrated_legacy_dep + migrated_legacy_review` for the advisory summary.)

**Sub-sweep c — `blocked:agent-soft` next-session sweep.** Subjective bails from prior sessions (`cannot reproduce`, `ambiguous`, `suggested fix exceeds expected scope`, `PR already open for this issue`) are auto-cleared at next-session backlog fetch — this is the **whole point** of the soft/hard split. There's no `Blocked by #N` referential check: the label by itself is the signal that "a prior worker bailed for a subjective reason that may not hold this session." Just remove the label and let step 4 pick the issue up naturally.

```bash
# All open issues currently carrying the `blocked:agent-soft` label.
gh issue list --repo <owner/repo> --state open --label blocked:agent-soft --limit 200 \
  --json number \
  > /tmp/do-work-blocked-soft-issues.json

cleared_blocked_soft=0
declare -a cleared_blocked_soft_numbers
for n in $(jq -r '.[].number' /tmp/do-work-blocked-soft-issues.json); do
  gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-soft 2>/dev/null || true
  gh issue comment "$n" --repo <owner/repo> --body "Auto-cleared \`blocked:agent-soft\` at next-session backlog fetch — subjective bails (cannot-reproduce / ambiguous / scope-judgment) do not persist across sessions. If the underlying ambiguity is still unresolved, a fresh worker dispatch this session may re-stamp the label." 2>/dev/null || true
  cleared_blocked_soft=$((cleared_blocked_soft + 1))
  cleared_blocked_soft_numbers+=("$n")
done
```

No "held" bucket for soft labels — every soft-labeled issue is cleared at the start of every session. The re-stamping risk (worker bails for the same reason → soft label re-applied this session) is intentional: subjective bails get exactly one re-dispatch per session, and the in-session re-dispatch gate (orchestrator's `session_blocked_soft` map per [steady-state.md A.1](../steady-state.md#a1-parse-the-return-string)) prevents tight retry loops within the same session. The cost of clearing-then-immediately-re-stamping is one extra `gh issue edit` per issue per session — cheap relative to the cost of permanently hiding workable issues.

**Sub-sweep d — legacy `needs-design` migration ([#537](https://github.com/mattsears18/shipyard/issues/537)).** [#515](https://github.com/mattsears18/shipyard/issues/515) folded `needs-design` into `needs-human-review`. Consumer repos still carrying pre-fold issues with `needs-design` would otherwise pass the step-4 dispatch filter (which only excludes `needs-human-review`, not the former `needs-design`). Simple one-to-one rename: add `needs-human-review`, remove `needs-design`, post one comment. The migration is idempotent — after the first pass no issues carry `needs-design`, so subsequent sessions iterate over an empty list in O(0).

```bash
# All open issues carrying the legacy `needs-design` label.
gh issue list --repo <owner/repo> --state open --label needs-design --limit 200 \
  --json number \
  > /tmp/do-work-legacy-needs-design.json

migrated_needs_design=0
declare -a migrated_needs_design_numbers
for n in $(jq -r '.[].number' /tmp/do-work-legacy-needs-design.json); do
  # Add the current label first so the issue is never unlabelled mid-transition.
  gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
  gh issue edit "$n" --repo <owner/repo> --remove-label needs-design 2>/dev/null || true
  # <!-- do-work-legacy-needs-design --> is a provenance TRIGGER marker (persists
  # for the issue's lifetime) — it's what lets /my-turn distinguish a
  # design-gated needs-human-review from the other seven provenances that
  # land on the same label, per #1091.
  gh issue comment "$n" --repo <owner/repo> --body "<!-- do-work-legacy-needs-design -->
Migrated legacy \`needs-design\` → \`needs-human-review\` per [#537](https://github.com/mattsears18/shipyard/issues/537). The \`needs-design\` label was folded into \`needs-human-review\` in [#515](https://github.com/mattsears18/shipyard/issues/515) — \`/do-work\` now excludes \`needs-human-review\` issues from dispatch, so this issue remains gated until a human reviews and removes the label." 2>/dev/null || true
  migrated_needs_design=$((migrated_needs_design + 1))
  migrated_needs_design_numbers+=("$n")
done
```

**Sub-sweep e — legacy `needs-decomposition` / `tracking` migration ([#537](https://github.com/mattsears18/shipyard/issues/537)).** [#519](https://github.com/mattsears18/shipyard/issues/519) folded the epic-decomposition pair into `needs-human-review` + the `<!-- do-work-needs-decomposition -->` body marker. Issues still carrying the pre-fold labels would otherwise pass the step-4 filter. For each legacy epic issue: add `needs-human-review`, remove the legacy label, AND post a comment containing the `<!-- do-work-needs-decomposition -->` marker (the discriminator `/decompose-epic` uses to identify epic handoffs in the broader `needs-human-review` pool). The migration is idempotent — the legacy labels are removed on the first pass. **This sweep only runs at the START of a session, so it doesn't catch a `tracking` label applied mid-session or by a prior session's un-migrated leftover before this sweep's next run** — [`04-backlog-divert.md`'s dispatch-exclusion filter](04-backlog-divert.md#4-fetch--rank-the-backlog) also enumerates `tracking` directly as a defensive gate ([#1081](https://github.com/mattsears18/shipyard/issues/1081)), closing that window without waiting for this sweep. The two are complementary, not redundant: this sweep does the actual cleanup (label swap + marker so `/decompose-epic` and `/my-turn` can find the issue); the dispatch-time gate only prevents premature dispatch in the meantime.

```bash
# Collect all open issues carrying needs-decomposition OR tracking (but NOT already
# needs-human-review — already migrated by a prior pass or manually).
gh issue list --repo <owner/repo> --state open --label needs-decomposition --limit 200 \
  --json number,labels \
  --jq '[.[] | select((.labels[].name | IN("needs-human-review")) | not) | {number}]' \
  > /tmp/do-work-legacy-needs-decomp.json

gh issue list --repo <owner/repo> --state open --label tracking --limit 200 \
  --json number,labels \
  --jq '[.[] | select((.labels[].name | IN("needs-human-review")) | not) | {number}]' \
  >> /tmp/do-work-legacy-needs-decomp.json

# Deduplicate (an issue could carry both labels) and process each once.
migrated_needs_decomp=0
declare -a migrated_needs_decomp_numbers
for n in $(jq -r '.[].number' /tmp/do-work-legacy-needs-decomp.json | sort -un); do
  gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
  # Remove whichever legacy labels the issue carries (one or both).
  gh issue edit "$n" --repo <owner/repo> --remove-label needs-decomposition 2>/dev/null || true
  gh issue edit "$n" --repo <owner/repo> --remove-label tracking 2>/dev/null || true
  # Post the marker comment. /decompose-epic keys off <!-- do-work-needs-decomposition -->
  # to distinguish epic handoffs from other needs-human-review issues.
  gh issue comment "$n" --repo <owner/repo> --body "<!-- do-work-needs-decomposition -->
Migrated legacy \`needs-decomposition\`/\`tracking\` → \`needs-human-review\` per [#537](https://github.com/mattsears18/shipyard/issues/537). The epic-decomposition pair was folded into \`needs-human-review\` + the \`<!-- do-work-needs-decomposition -->\` marker in [#519](https://github.com/mattsears18/shipyard/issues/519). The marker above lets \`/decompose-epic\` find this issue among the broader \`needs-human-review\` pool and auto-shard it into dispatch-ready sub-issues." 2>/dev/null || true
  migrated_needs_decomp=$((migrated_needs_decomp + 1))
  migrated_needs_decomp_numbers+=("$n")
done
```

**Sub-sweep f — legacy `blocked:agent-hard` migration ([#537](https://github.com/mattsears18/shipyard/issues/537)).** [#521](https://github.com/mattsears18/shipyard/issues/521) eliminated `blocked:agent-hard`, splitting it into refuses (`needs-human-review`) and dependency-waits (no label, body-ref filter gates). Pre-#521 sessions still carry `blocked:agent-hard` on open issues. Uses the same discriminator as sub-sweep b — presence of an open `Blocked by #N` reference — to route each legacy issue. Reads through the `blocker_state` cache.

```bash
# All open issues carrying the legacy `blocked:agent-hard` label.
gh issue list --repo <owner/repo> --state open --label blocked:agent-hard --limit 200 \
  --json number,body,labels \
  --jq '[.[] | {number, body}]' \
  > /tmp/do-work-legacy-hard-issues.json

migrated_hard_dep=0      # → no label (dependency-wait, body-ref filter gates it)
migrated_hard_review=0   # → needs-human-review (unclassifiable refuse)
declare -a migrated_hard_dep_numbers
declare -a migrated_hard_review_numbers
for n in $(jq -r '.[].number' /tmp/do-work-legacy-hard-issues.json); do
  body=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body' /tmp/do-work-legacy-hard-issues.json)

  # Same `Blocked by #N` extraction as sub-sweep b.
  blockers=$(printf '%s' "$body" | grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
  has_open_blocker=false
  for b in $blockers; do
    state="${blocker_state[$b]:-}"
    if [ -z "$state" ]; then
      state=$(gh issue view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null \
        || gh pr view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null || echo "")
      [ -z "$state" ] && state="unresolvable"
      blocker_state[$b]="$state"
    fi
    case "$state" in OPEN) has_open_blocker=true; break ;; esac
  done

  if $has_open_blocker; then
    # Dependency-wait: drop the legacy label; the body-ref filter gates dispatch.
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-hard 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Removed legacy \`blocked:agent-hard\` per [#537](https://github.com/mattsears18/shipyard/issues/537) / [#521](https://github.com/mattsears18/shipyard/issues/521). This issue carries an open \`Blocked by #N\` reference, so it's gated by the \`Blocked by #N\` body-reference filter (no label needed) and becomes workable automatically when the blocker closes." 2>/dev/null || true
    migrated_hard_dep=$((migrated_hard_dep + 1))
    migrated_hard_dep_numbers+=("$n")
  else
    # Refuse: route to needs-human-review.
    gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-hard 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Migrated legacy \`blocked:agent-hard\` → \`needs-human-review\` per [#537](https://github.com/mattsears18/shipyard/issues/537) / [#521](https://github.com/mattsears18/shipyard/issues/521). The original label predates the refuse/dependency-wait split and carries no open \`Blocked by #N\` reference, so it's treated as a refuse: a human must review before re-dispatch. If the original block was subjective (cannot-reproduce / ambiguous / scope-judgment), swap the label to \`blocked:agent-soft\` to opt into next-session auto-clear." 2>/dev/null || true
    migrated_hard_review=$((migrated_hard_review + 1))
    migrated_hard_review_numbers+=("$n")
  fi
done
```

The sub-f migration runs **once per legacy issue** — after the first pass there are no more `blocked:agent-hard`-labeled issues. The label object is left registered (same rationale as `blocked:agent` in sub-sweep b) so a future audit can confirm zero open issues carry it before deletion.

**Order matters.** Sub-sweeps b → c → d → e → f run in sequence (sub-sweep a was deleted in [#521](https://github.com/mattsears18/shipyard/issues/521)). c runs after b so the soft sweep operates on the post-migration label set — a legacy `blocked:agent` issue migrated to `blocked:agent-soft` by a maintainer mid-window is swept by c on the same pass. d/e/f run after c and operate on the post-b-migration state so no issue is processed by two sweeps in the same pass (the old label is always removed before the loop ends, making each sweep idempotent and one-shot-per-issue).

### 3.5 Refine pending issues

> **`--fast` skip:** When `--fast` is set, skip this entire step. Issues matching a refinement source signal remain unrefined this session; they will be processed by the next normal `/do-work` invocation. The `fast_skip_needs_refinement` count captured in step 2's `--fast` note surfaces in the end-of-session advisory block so the user knows how many refinement tasks were deferred. Proceed immediately to step 4.

**Timing instrumentation (issue #238).** Bracket this step even when it runs with no refinement-candidate issues — the wall clock still measures the `/refine-issues` invocation overhead:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_3_5_refine_issues 2>/dev/null || true
# /refine-issues --repo <owner/repo> --concurrency <N>
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_3_5_refine_issues 2>/dev/null || true
```

When `--fast` causes this step to be **skipped entirely**, call only the `start` + `end` pair with a near-zero elapsed (both calls back-to-back), so the ledger contains a `0.0s` entry for the phase rather than a missing key. This makes cross-session aggregation consistent — the report can always average `step_3_5_refine_issues` without handling absent keys for `--fast` sessions separately.

Invoke `/refine-issues` and **wait for it to complete** before proceeding to step 4. This scans every open issue for a refinement source signal — there is no persisted `needs-refinement` gate label (eliminated in [#520](https://github.com/mattsears18/shipyard/issues/520)); candidacy is recomputed live — and branches per-issue on source signal:

- **classify+rewrite branch** (`user-feedback` label present AND body still contains the raw-feedback fenced block — the label alone is permanent origin provenance, not a live refinement flag; [#1055](https://github.com/mattsears18/shipyard/issues/1055)): classify as already-done / declined / legitimate, preserve original text in a comment, rewrite the body into the repo's issue template. Legitimate items get `needs-human-review` co-applied.
- **resolve-defaults branch** (no `user-feedback`, body has `## Open questions`): commit reasonable defaults for each question, rewrite body removing the section. Does NOT apply `needs-human-review` — trusted-author issues become dispatch-eligible in the same session.
- **fall-through branch** (no `user-feedback`, no recognizable pattern — bot-authored / bare one-liner / unrecognized): add `needs-human-review`, comment with explanation. Surfaces via `/shipyard:my-turn`. (This is the genuine no-automated-path subset only — never the auto-processable work above.)

After this step, every dispatch-ready survivor of the first two branches is either dispatch-eligible (resolve-defaults) or carries `needs-human-review` (legitimate user-feedback). The fall-through branch lands the no-pattern subset on `needs-human-review`.

```
/refine-issues --repo <owner/repo> --concurrency <do-work concurrency>
```

Pass-through args:

- **`--repo`** — same value `/do-work` is using.
- **`--concurrency`** — same value `/do-work` is using (default `1` unless overridden — see [`/do-work`'s `--concurrency` arg](../../do-work.md#args) for the rationale).
- **`--issue`** is NEVER passed from `/do-work` — refinement always operates on the full eligible set during a `/do-work` startup.
- **`--dry-run`** is NEVER passed from `/do-work` — startup refinement always commits.

The refined-and-now-`needs-human-review` issues will be picked up by the *next* `/do-work` session, after a human reviews. Step 4's backlog fetch (just below) excludes `needs-human-review` and `needs-triage`, so none leak into the dispatch queue this session. Resolve-defaults issues, however, ARE picked up this session — they become dispatch-eligible the moment the refiner removes the `## Open questions` section (no gate label to drop).

**Implementation note.** The refinement logic itself lives in `/refine-issues`. This step is a thin invocation — no duplication of the bucket spec, sentinel logic, or worker prompt template. If we later change the refinement prompt, we only update one file (`commands/refine-issues.md`).

# /shipyard:do-work — Setup phase · parallelization batch + gh caches

**Setup sub-phase (cluster 1 of 5, part 2 of 2 — [#994](https://github.com/mattsears18/shipyard/issues/994)).** Continues step **0.7** (the canonical setup-parallelization batch + background cleanup group) from [`00-config-worktree.md`](./00-config-worktree.md), then owns steps **0.8 → 0.9.1**: the `blocker_state` cache, the `gh-cached.sh` wrapper, and the `gh-batch.sh` GraphQL wrapper. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`00-config-worktree.md`](./00-config-worktree.md) (same cluster, part 1). Next sub-phase: [`01-repo-recovery.md`](./01-repo-recovery.md).

**Steps 1 → 5 are a graph of read-only `gh` calls with no data dependencies on each other.** Fire them as a single parallel burst — either one `Bash` tool call wrapping `bash -c '... & ... & wait'`, or N parallel `Bash` tool calls in one orchestrator message. A serial walk through steps 1 → 5 is the failure mode this section prevents.

**Timing instrumentation (issue #238).** The parallel batch as a whole is one timing window. Open the window just before firing the burst; close it once `wait` (or all parallel tool calls) return.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_0_7_parallel_batch 2>/dev/null || true
# ... fire all parallel gh calls ...
# ... wait for all to return ...
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_0_7_parallel_batch 2>/dev/null || true
```

**Canonical setup batch — these reads have no data dependencies:**

- **[Step 1](01-repo-recovery.md#1-resolve-repo--user)** — repo + user metadata (3 `gh` calls).
- **[Step 2](01b-backlog-overview.md#2-backlog-overview)** — issue universe (`gh issue list --state open` + `linked:pr` search). **Skipped under `--fast`** — but count refinement candidates (by source-signal scan — `user-feedback` / `## Open questions` / bot author, since the `needs-refinement` label was eliminated in [#520](https://github.com/mattsears18/shipyard/issues/520)), `blocked:ci`, `blocked:agent-soft`, and legacy `blocked:agent` issues first (see step 2's `--fast` note). (`blocked:agent-hard` was eliminated in [#521](https://github.com/mattsears18/shipyard/issues/521) — no count.)
- **[Step 3d.1](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session)** — `blocked:ci` PR list. Per-PR `events` + `commits` lookups are a second-tier parallel batch keyed off the first-tier result. **Skipped under `--fast`** (the initial `gh pr list --label blocked:ci --json number --jq 'length'` count still runs for advisory reporting — see step 3d.1's `--fast` note).
- **[Step 3d.2](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session)** — five sub-sweeps in sequence: legacy `blocked:agent` migration (re-pointed per [#521](https://github.com/mattsears18/shipyard/issues/521) — dependency-wait → no label, else → `needs-human-review`), `blocked:agent-soft` next-session sweep, and three new legacy-label migration sweeps ([#537](https://github.com/mattsears18/shipyard/issues/537)) for `needs-design` → `needs-human-review`, `needs-decomposition`/`tracking` → `needs-human-review` + decomposition marker, and `blocked:agent-hard` → same refuse/dependency-wait discriminator as sub-sweep b. (Sub-sweep a, the `blocked:agent-hard` referential clear, was deleted in [#521](https://github.com/mattsears18/shipyard/issues/521).) Per-issue blocker-state lookups (sub-sweeps b and f) read through the [`blocker_state` cache](#08-blocker_state-cache-default-on). **Skipped under `--fast`** (the initial label counts still run for advisory reporting — see step 3d.2's `--fast` note).
- **[Step 4.5a](04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup)** — main CI status (`gh run list --branch <default-branch> --limit 60`). **Skipped under `--fast`** — `main_ci.status` left as `"unknown"`.
- **[Step 4.5b](04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup)** — all-authors failing-PR count. **Skipped under `--fast`** — `failing_pr_count_all` left as `0`.
- **[Step 5](04-backlog-divert.md#5-snapshot-failing-prs)** — `@me` failing-PR snapshot.

**Background bash group (fire-and-forget from step 0.7).** The following steps are cleanup-only — they don't affect dispatch correctness and don't need to complete before the first worker fires. Fire them as a single background subshell immediately after opening the timing window, capture the PID, and let dispatch proceed without waiting:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
# Re-derive & re-export the SHIPYARD_REPO_ROOT pin from the step-0.56 stash
# (issue #1059/#1064) — every shipyard-config.sh get below (warn_threshold,
# max_per_session, auto_merge_method) would otherwise silently drop
# .shipyard/config.local.json. Exported here so the background subshell
# below inherits it.
SHIPYARD_REPO_ROOT=$(cat "$(git rev-parse --show-toplevel)/.shipyard-primary-root" 2>/dev/null)
[ -z "$SHIPYARD_REPO_ROOT" ] && SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel)"
export SHIPYARD_REPO_ROOT
(
  # 1.6 — Orphan session-file sweep (cost-ledger recovery). Cleanup-only — recovery
  # of historical ledger data is observational and doesn't affect this session's dispatch.
  # Layered protection (issue #253): the 30-min mtime floor catches files that haven't
  # been written through recently AND the `is-active` PID-liveness check skips files
  # whose owning process is still alive. Both have to fail before reap — protects
  # against the race where a peer orchestrator went quiet for >30 min (long drain,
  # CI watch) but is still actively running and will write through again.
  SESSIONS_DIR="${SHIPYARD_HOME:-$HOME/.shipyard}/sessions"
  find "$SESSIONS_DIR" -maxdepth 1 -type f -name '*.json' -mmin +30 2>/dev/null | while read -r orphan; do
    orphan_id=$(basename "$orphan" .json)
    [[ "$orphan_id" == "<session-id>" ]] && continue
    # PID-liveness gate: if the orchestrator that owns this file is still alive,
    # skip the reap regardless of mtime. is-active exits 0 when the file's .pid
    # is alive (per kill -0). Exit 1 on missing file, missing/null pid, or dead pid.
    if "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" is-active --session-id "$orphan_id" 2>/dev/null; then
      continue
    fi
    "${CLAUDE_PLUGIN_ROOT}/scripts/cost-history.sh" flush --session-id "$orphan_id" 2>/dev/null || true
    # --reap-audit (issue #281) writes one JSONL line to
    # ~/.shipyard/reap-audit.jsonl capturing the reaped session's
    # pid / repo / tokens / mtime, plus the reaper's session id and pid,
    # so a subsequent "where did my session file go?" investigation has
    # forensic data. The line lands in the same JSONL file as worktree-reap
    # audit entries (issue #284) so a reader can correlate session-file and
    # worktree reaps for the same session.
    "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" cleanup --session-id "$orphan_id" \
      --reap-audit \
      --reaper-session-id "<session-id>" \
      --reason "orphan-sweep-step-1.6" \
      --phase "setup-1.6" 2>/dev/null || true
  done

  # 1.6 (continued) — orphan atomic-write .tmp sweep (issue #858). The loop
  # above only discovers stale *.json files; a .tmp.<pid> whose target
  # .json never landed (crash mid-atomic_write, most commonly during
  # `session-state.sh init`) matches no session id the loop above could
  # hand to `cleanup --session-id`, so it would otherwise linger forever.
  # cost-history.sh's reconcile-rewrite tmp/.err files and
  # flake-registry.sh's prune-rewrite tmp file have the identical gap, with
  # no sweep anywhere for either. sweep-orphan-tmp.sh closes all three in
  # one pass, gated on the same age-floor-plus-liveness shape as above
  # (pid-embedded liveness for the two *.tmp.$$ writers; a fresh
  # cost-history.jsonl.lock protects the whole mktemp-suffixed category
  # instead, since those names carry no pid to check). Every reap is
  # logged (not silent) — see the script's own header for the full
  # rationale and 01-repo-recovery.md's step 1.6 section for the
  # human-readable writeup.
  "${CLAUDE_PLUGIN_ROOT}/scripts/sweep-orphan-tmp.sh" sweep \
    --shipyard-home "${SHIPYARD_HOME:-$HOME/.shipyard}" 2>/dev/null || true

  # 1.6.5 — Reap orphan orchestrator worktrees (issue #280). Parallel to step 1.6
  # but for the worktree dirs themselves: a `.claude/worktrees/orchestrator-<dead-id>/`
  # dir whose owning session has already terminated (file missing or PID dead).
  # Without this sweep, the worktree dirs accumulate indefinitely whenever a
  # prior session crashes before cleanup-summary.md step 6 retires its own
  # worktree — step 1.6 only cleans up session FILES; step 3b only handles
  # `agent-*` worktrees. The find-orphan-orchestrators helper applies the
  # same liveness gate step 1.6 uses (file-missing OR `is-active` exits 1),
  # so the inactivity definition stays consistent across both sweeps.
  #
  # Issue #284 — the per-reap `git worktree remove` and the audit-log write
  # are encapsulated in `worktree-reap.sh reap --action reaped-orphan-orchestrator`.
  # The helper handles the rm -rf fallback internally (worktree-remove fails
  # whenever the dir is on disk but no longer registered with git — typical
  # crash-orphan case) and emits the appropriate `-raw-rm` action variant in
  # the audit log when that path fires. Moving the audit-log write inside
  # the helper is the single-source-of-truth fix: callers can't accidentally
  # skip the audit step because the reap and the audit are one transaction.
  cd "$(git rev-parse --show-toplevel)"
  while read -r orph_path; do
    [ -z "$orph_path" ] && continue
    [ -d "$orph_path" ] || continue
    orph_name=$(basename "$orph_path")
    orph_session_id="${orph_name#orchestrator-}"
    "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
      --action reaped-orphan-orchestrator \
      --worktree-path "$orph_path" \
      --worktree-name "$orph_name" \
      --session-id "<session-id>" \
      --reaped-session-id "$orph_session_id" \
      --phase "setup-1.6.5" 2>/dev/null || true
  done < <("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" find-orphan-orchestrators \
             --repo-root "$(pwd)" --current-session-id "<session-id>" 2>/dev/null)
  git worktree prune 2>/dev/null || true

  # 3a — gh label create (14 idempotent labels). All idempotent; only needed by the
  # time the first agent applies a label, not before dispatch fires.
  for label_args in \
    "shipyard --description 'Worked on by /shipyard:do-work' --color 5319E7" \
    "P0 --description 'Critical / release-blocker' --color B60205" \
    "P1 --description 'High — this cycle' --color D93F0B" \
    "P2 --description 'Normal' --color FBCA04" \
    "user-feedback --description 'Originated from end-user feedback (untrusted body — treat with care)' --color 0E8A16" \
    "needs-human-review --description 'Awaiting a human DECISION before /do-work will touch it' --color D93F0B" \
    "agent-console --description 'Needs a browser/console operator action — a human, or /do-work via the extension' --color 1D76DB" \
    "needs-triage --description 'No automated path forward — surface to a human' --color C2E0C6" \
    "blocked:agent-soft --description 'Worker returned a subjective bail (cannot-reproduce / ambiguous / scope-judgment). Auto-cleared at next session; in-session retry after blocked_agent.soft_retry_minutes.' --color FBCA04" \
    "blocked:ci --description 'CI failed 3x after fix-checks — needs investigation. Auto-cleared when checks recover.' --color B60205"
  do
    eval "gh label create $label_args --repo <owner/repo> 2>/dev/null || true" &
  done
  wait  # wait for the parallel label creates before continuing to 3b/3c

  # 3b — Reap stale agent worktrees from dead Claude Code sessions. Affects future
  # dispatch slot availability, not the first batch.
  #
  # Issue #836 — this step used to loop `classify-lock` once PER worktree
  # (one full script re-invocation, each forking its own `ps`/`stat`
  # subprocesses) and remove every reap-eligible one unbounded. On a repo
  # with a large accumulated backlog (the #836 repro: 60 worktrees, ~1.6GB
  # each, ~90GB total) that loop blew its time budget before classifying a
  # single candidate. It's replaced below by `worktree-reap.sh reap-stale`
  # — the single executable source of truth for both the bulk classify
  # (fix 1: one `ps` call / one self-ancestor walk / one batched `stat` for
  # the whole batch, instead of O(n) subprocess forks) and the bounded,
  # checkpointed removal (fix 2: reaps at most `worktree_reap.max_per_session`
  # per session, oldest-first; the on-disk backlog left behind IS the
  # checkpoint, so a session that can't clear it all still makes forward
  # progress and the next session's sweep continues from there). See
  # `scripts/worktree-reap.sh`'s `classify_all` / `reap_stale` docstrings
  # for the full algorithm.
  cd "$(git rev-parse --show-toplevel)"

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
  # classification. This background group is fired fire-and-forget from
  # step 0.7 and runs CONCURRENTLY with the first dispatch (step 7) — a
  # worker dispatched moments earlier can already have a worktree on disk
  # whose harness-written lock names a PID that is already gone (an
  # intermediate spawn-time process, not the long-lived agent process).
  # Classification alone has no way to tell that apart from a genuinely-dead
  # lock and would call it `dead` — reap-eligible — either way. In-flight
  # membership is authoritative liveness; the lock file's classification is
  # only a fallback for worktrees THIS session doesn't own (cross-session
  # stragglers, which is what step 3b exists to clean up). Branch name is
  # NEVER a liveness signal — see `commands/do-work/dont.md`'s "Don't reap
  # a live-PID worktree" bullet for why a name-based filter has a race
  # window that would delete an in-flight agent.
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

  # 3c — Orphan worktree triage (discovery + handling). The discovery is cheap;
  # the expensive push/PR-create branch only fires when orphans exist. Neither
  # gates dispatch decisions.
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
            # --watch` here: this runs in setup's background cleanup group and a
            # block would stall session start, once per orphan.
            echo "[setup-3c] PR #${pr_num} left unarmed (ungated repo) — deferred to drain's merge lander (#720)"
          fi
        fi
      fi
    fi
  done
  # The "[setup-3c] PR #<N> auto-merge arm blocked" line above runs inside
  # this piped `while read` loop (a subshell), so it cannot persist a value
  # back into the enclosing background group's own shell variables. That's
  # fine — workflow_scope_blocked_prs is orchestrator state (see do-work.md's
  # "Orchestrator state" section), not a literal shell variable spanning tool
  # calls: when this background group's captured stdout is surfaced (at the
  # `wait $SETUP_BACKGROUND_PID` in end-of-session cleanup, or sooner if
  # inspected), append <N> to workflow_scope_blocked_prs for every such line,
  # exactly as steady-state.md step A.1's shipped-handler already does from a
  # worker's return string (issue #812 / #850).

  # 3c (row 5) — Stale @me self-assigns with no worktree, no PR, no branch
  # (issue #303). Catches the state the worktree loop above CAN'T see:
  # a prior session that left the @me assignment on an issue after its
  # on-disk worktree was already cleaned up. Without this sweep the
  # assignment survives indefinitely across sessions; the issue silently
  # passes the worker-side step-0 pre-flight (it's still assigned to
  # @me, not someone else) and gets re-dispatched against stale prior-
  # session artifacts. Action is conservative: clear the assignment only,
  # leave the `shipyard` label as provenance, and let the normal step-4
  # backlog fetch pick the issue up on the next dispatch.
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
) &
SETUP_BACKGROUND_PID=$!
```

The background group handles steps 1.6, 1.6.5, 3a, 3b, and 3c. The parallel batch (steps 1 → 5) and the foreground-serial steps (1.7, 3.5, 4 → 7) all proceed without waiting on `$SETUP_BACKGROUND_PID`. End-of-session cleanup's step 7 (`cost-history.sh flush`) must `wait $SETUP_BACKGROUND_PID` before flushing to ensure the 1.6 orphan sweep has completed — the flush and the sweep both write to `cost-history.jsonl`, and both are idempotent, but the `wait` prevents a double-flush race on the same session file.

### Classifier-denial fallback — the background group's own Bash tool call can be refused outright ([#1042](https://github.com/mattsears18/shipyard/issues/1042))

The `(...) &` block above is submitted as **one** Bash tool call. The permission classifier evaluates that whole compound text before any of it executes — a destructive verb anywhere inside it (step 3b's `reap-stale` invocation escalating to `git worktree remove --force`, step 3c's `git branch -D`) can trip a denial for the **entire** call, not just the risky line. When that happens, `SETUP_BACKGROUND_PID=$!` never runs — none of 1.6 / 1.6.5 / 3a / 3b / 3c executed, including the `⚠️ worktree backlog:` warning inside step 3b and `reap-stale`'s own internal `unreaped:` accounting. This is precisely the "sweep denied, denial invisible" failure [`dont.md`](../dont.md)'s "Don't swallow a failed or denied reap" rule ([#712](https://github.com/mattsears18/shipyard/issues/712)) already prohibits — but #712's existing wiring ([cleanup-summary.md step 5.5's `report-unreaped` scan](../cleanup-summary.md#end-of-session-cleanup)) only runs at **end of session**, and nothing today re-checks the setup-time denial specifically, so a whole-group refusal at session **start** went unreported end to end in the [#1042](https://github.com/mattsears18/shipyard/issues/1042) repro (29 worktrees stranded across multiple prior sessions, zero visibility in any summary).

**Detect the denial directly from the Bash tool's own result for the call above** — a permission denial returns as the tool result for that specific call (e.g. `Permission for this action was denied by the Claude Code auto mode classifier`), not as stdout the shell script's own `2>/dev/null || true` could have swallowed. When the background-group launch returns that instead of a normal background-launch result:

1. **Don't retry the same compound command.** Per `shipyard:worker-preamble` § "After a classifier denial" and [`dont.md`](../dont.md)'s "Don't iterate prompt wording against the permission classifier" rule, re-submitting the identical destructive-operation text (or a cosmetically-reworded version of it) is not the fix.
2. **Run the read-only verification immediately, as its own separate foreground call.** `report-unreaped` only enumerates directories — it removes nothing — so it is not a plausible denial candidate on its own, and it doesn't need to wait for anything else to finish (nothing else ran):

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   setup_reap_denial_unreaped=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" report-unreaped \
     --repo-root "$(git rev-parse --show-toplevel)" \
     --current-session-id "<session-id>" | wc -l | tr -d ' ')
   echo "setup-background-group-denied: unreaped=${setup_reap_denial_unreaped}"
   ```

   The final `echo` is load-bearing, not decorative — it's what makes the count visible in this Bash call's own tool result rather than trapped in a shell variable the process discards on exit (a shell variable set in one Bash tool call never survives to the next one).
3. **Record `setup_reap_sweep_denial`** (session-local orchestrator state — see [`orchestrator-state-reference.md`](../orchestrator-state-reference.md)) with the denial text and `setup_reap_denial_unreaped`, so [cleanup-summary.md step 5.5](../cleanup-summary.md#end-of-session-cleanup) folds it into the end-of-session `Cleanup:` line even if this session's own later reap attempts happen to succeed on unrelated worktrees and would otherwise report a clean `unreaped_worktrees == 0`.
4. **Proceed with the rest of setup unaffected.** Steps 1 → 5's parallel batch and the foreground-serial steps do not depend on the background group. A denied background group costs cleanup visibility, not dispatch correctness — do NOT fall back to running 1.6 / 1.6.5 / 3a / 3b / 3c inline on the orchestrator's own foreground thread; that reintroduces the blocking-on-cleanup cost the background group exists to avoid, for work whose entire value proposition is "best-effort, not required for this session's dispatch to proceed."

**The full execution model after this change:**

```
step 0.7 opens timing window
  ├── background group (SETUP_BACKGROUND_PID) — fire and forget:
  │     1.6   orphan session-file sweep
  │     1.6.5 orphan orchestrator-worktree sweep (issue #280)
  │     3a    gh label creates (parallel within group)
  │     3b    stale worktree reap
  │     3c   orphan worktree triage
  └── foreground parallel batch (steps 1 / 2 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5)
        └── after batch: step 1.7 → 3.5 → 4 → 4.5 aggregate → 6 → 7 (serial)
```

**Steps that MUST run after the batch (foreground, serial):**

- **[Step 1.7](01-repo-recovery.md#17-resolve-trusted-author-allowlist)** — its output (`trusted_authors`) gates step 2's bucketing and step 4's filter.
- **[Step 3.5](01c-label-recovery-refine.md#35-refine-pending-issues)** — invokes `/refine-issues`, blocks until done. **Skipped under `--fast`**.
- **[Step 4](04-backlog-divert.md#4-fetch--rank-the-backlog)** — the *filtered* backlog fetch (distinct from step 2's universe fetch). Auto-triage label-stamping depends on step 1.7 + step 2.

**Steps 6+ stay serial.** Scope pre-flight (step 6) depends on `raw_backlog` from step 4; initial pool fill (step 7) depends on `ready_issues` from step 6.

The numbered subsection order (1 → 5) is documentation layout — execution is parallel.

### 0.8 `blocker_state` cache (default-on)

Session-local map `blocker_state: { <issue-or-pr-number> → "OPEN" | "CLOSED" | "MERGED" | "unresolvable" }` shared by three setup paths:

- **[Step 2](01b-backlog-overview.md#2-backlog-overview) bucket-6** — for every `Blocked by #N` reference in a bucket-6 issue body, `gh issue view <N> --json state` (with `gh pr view <N>` fallback). Cache the result.
- **[Step 3d.2](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session) auto-clear sweep** — same lookups; read-through cache.
- **[Step 2](01b-backlog-overview.md#2-backlog-overview) bucket-7** classification — same cache.

Cache lifetime is session-scoped. The cache is a latency optimization; it never gates correctness.

**Cache-miss policy.** Query `gh issue view <N>` first; on `not found`, fall back to `gh pr view <N>`; on both failing, cache `"unresolvable"` (the consumer treats it as "not all closed" — i.e. don't auto-clear). `unresolvable` entries survive subsequent lookups — no retry burst per consumer.

### 0.9 `gh-cached.sh` wrapper (opt-in per call-site)

Within a single orchestrator session (typically 5–15 minutes), GitHub state doesn't change much except for the artifacts shipyard itself is modifying. But the orchestrator re-queries the same data across phases — `gh pr list` at the start of dispatch, again in drain, again in summary; `gh issue list` at backlog fetch and again on the lightweight backlog re-check before every dispatch. Most of those answers haven't changed. `plugins/shipyard/scripts/gh-cached.sh` is a session-scoped wrapper that caches stdout from a `gh` call keyed by its argv, with a caller-supplied TTL, so the redundant re-fetches return from disk instead of re-hitting the GitHub API. Closes [#160](https://github.com/mattsears18/shipyard/issues/160) — phase 3 of the perf umbrella [#152](https://github.com/mattsears18/shipyard/issues/152).

**Shape.** Run `gh` through the wrapper instead of calling `gh` directly:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" run \
  --session-id "<session-id>" --ttl 60 -- \
  gh-args-without-the-gh-prefix
```

The wrapper invokes `gh` itself (the argv after `--` is everything you'd normally pass to `gh`, minus the literal `gh`). Cache files live at `$SHIPYARD_HOME/cache/<session-id>/<sha256-of-argv>`. Cache hit → emits cached stdout, no network call, exit 0. Cache miss → invokes `gh`, streams stdout to disk + caller, exit mirrors `gh`. Non-zero `gh` exits are NOT cached (errors must retry naturally).

**TTL bands per query category.** Caller picks the TTL — no default, because the right freshness depends on the query:

| Query | Suggested TTL | Reasoning |
|---|---|---|
| `gh issue list --state open` (backlog universe) | **60s** | Backlog changes slowly; ephemeral edits to label/title don't change dispatch decisions |
| `gh pr list --state open` (in-flight check, drain snapshot) | **30s** | In-flight PRs change faster — new PRs, mergeStateStatus flips — but minutes of staleness still tolerable |
| `gh pr view <N> --json statusCheckRollup,mergeStateStatus` | **10s** | CI churns fast; the trust-but-verify spot-check and drain reconcile both depend on freshness |
| `gh label list` | **600s** | Labels change once per release |
| `gh api graphql` (batch status, status-rollup queries) | **10s** | Same churn class as per-PR view |
| `gh repo view --json defaultBranchRef` | **3600s** | Default branch rarely changes mid-session |
| `gh api repos/<owner/repo>/collaborators` | **3600s** | Trusted-author resolution is session-scoped already; this is belt-and-braces |

These are *suggestions*. A caller that needs harder freshness should pass a smaller TTL; a caller in a known-quiet section can pass a larger one. The wrapper is intentionally opt-in per call-site — the spec doesn't require every `gh` call to go through it. Use it for the high-volume queries the orchestrator re-runs across phases; leave one-shot queries (e.g. `gh issue view <N>` at scope pre-flight) to call `gh` directly.

**Invalidation on writes.** Whenever shipyard itself does a state-changing call (issue close, PR create, label add, assignee change), the relevant cached reads need to be flushed so subsequent reads see the new state. Two policies:

- **Conservative (default).** Flush the entire session cache after any state-changing call:
  ```bash
  export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
  "${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" invalidate --session-id "<session-id>"
  ```
  Burns one extra round of cold reads on the next refresh but never serves stale data after a write. Use this when in doubt — the cost is "one re-read per shipyard write," which is small compared to the savings on the hot read paths.
- **Targeted (advanced).** When the write affects a specific PR or issue and the caller knows which cached reads depend on that artifact, pass `--pattern <sha-prefix>` to invalidate just the matching entries. Practical use is rare — the `--pattern` surface is intentionally narrow because callers don't easily know the sha shape. Stick with the conservative policy unless profiling shows the broad flush dominates.

**End-of-session cleanup.** The cache directory at `$SHIPYARD_HOME/cache/<session-id>/` is reaped by the [End-of-session cleanup](../cleanup-summary.md#end-of-session-cleanup) sequence:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" cleanup --session-id "<session-id>"
```

Idempotent. Runs in the same cleanup chain that reaps the session state file — both are session-scoped artifacts under `$SHIPYARD_HOME`.

**Disable for debugging.** `SHIPYARD_GH_CACHE_DISABLED=1` in the environment makes every `run` invocation a live `gh` call with no read or write — useful for confirming "is the cache hiding a real change?" without touching the call-sites. The `stats` subcommand still reads whatever's already on disk; `cleanup` and `invalidate` still operate on the existing dir.

**Observability.** `gh-cached.sh stats --session-id <id>` emits `{"hits": N, "misses": N, "invalidations": N, "bytes": N}` for the session — useful in end-of-session summary blocks and for the cost-tracking ledger when measuring perf wins against the baseline.

### 0.9.1 `gh-batch.sh` GraphQL wrapper (opt-in per call-site)

Where `gh-cached.sh` reduces redundant *re-fetches* across phases, `gh-batch.sh` reduces *fan-out*: N sequential `gh pr view <M>` / `gh issue view <N>` calls collapse to a single `gh api graphql` query with aliased per-record sub-queries. Closes [#159](https://github.com/mattsears18/shipyard/issues/159) — phase 2 of the perf umbrella [#152](https://github.com/mattsears18/shipyard/issues/152).

**When to reach for it.** Any call-site that fires `gh pr view <M>` or `gh issue view <N>` in a loop over a known list of numbers is a candidate. Highest-leverage sites today:

- **[Drain phase](../drain.md#drain-protocol) per-poll re-snapshot** — `D_dirty` / `R_new` / `P_settled` reconciles read per-PR fields for a known subset of session_prs every 60s. Use `pr-status` instead of N `gh pr view <M>` calls.
- **[Step 0.8 blocker_state cache](#08-blocker_state-cache-default-on)** — populated lazily today; when N+ entries are missed at once (bucket-6/-7 cold start), `issue-state` fills the cache in one round-trip instead of N.
- **[Step 3d.2](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session) referential-blocker resolution** — the `Blocked by #N` sweep already cache-reads, but cold starts on a large stale-block backlog benefit from batching the lookups via `issue-state` + a single `pr-status` fallback for cases where the referenced number is a PR.
- **Scope pre-flight scoping batches** — when N candidates' issue bodies need a fresh state check before dispatch.

**Shape.**

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
# Batch PR status — same projection as `gh pr view <M> --json
# number,state,mergeable,mergeStateStatus,statusCheckRollup,headRefName,headRefOid`
# but for N PRs in one query. Emits one JSON object keyed by PR number string.
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-batch.sh" pr-status \
  --repo <owner/repo> \
  --numbers "142 143 144"
# → {"142": {"number":142,"state":"OPEN","mergeable":"MERGEABLE",...}, "143": {...}, "144": {...}}

# Batch issue state + labels. Same shape — keyed by issue number string.
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-batch.sh" issue-state \
  --repo <owner/repo> \
  --numbers "100,200,300"
# → {"100": {"number":100,"state":"OPEN","labels":["P1","bug"]}, ...}
```

`--numbers` accepts space- or comma-separated integers. Non-numeric tokens fail loudly (exit 64) — defense in depth against any caller injecting unvalidated user input into the GraphQL body.

**Limits and behavior.**

- **Chunked at 50 aliases per query.** GraphQL has a soft node-cost limit; the wrapper auto-splits large `--numbers` lists into chunks and merges the JSON before emitting. Override via `SHIPYARD_GH_BATCH_CHUNK_SIZE`. Typical orchestrator fan-out (drain ≤10, blocker-state cache cold-start ≤20) fits in a single chunk.
- **Missing artifacts drop silently.** A PR / issue that no longer exists (deleted, transferred, never existed) resolves to a null alias and is dropped from the output — the caller treats a missing key as "not trackable." Never fail the whole batch on one missing number.
- **Failure fails the whole batch.** `gh api graphql` failure (rate limit, 5xx, malformed query) exits 2 with stderr forwarded. No partial output is emitted — callers retry the whole batch, not individual chunks.
- **`mergeable` may return UNKNOWN.** GitHub computes it on-demand; `mergeStateStatus` (`CLEAN` / `DIRTY` / `BLOCKED` / `BEHIND` / `UNSTABLE`) is the more stable signal. Prefer `mergeStateStatus` where possible.

**Composing with `gh-cached.sh`.** The two wrappers compose cleanly: run the batch helper through the cache wrapper to get both fan-in *and* cross-phase memoization. Suggested TTL bands:

| Batch query | Suggested TTL | Reasoning |
|---|---|---|
| `gh-batch.sh pr-status` | **10s** | Same churn class as per-PR `statusCheckRollup` (10s band in [§0.9](#09-gh-cachedsh-wrapper-opt-in-per-call-site)) |
| `gh-batch.sh issue-state` | **30s** | Issue state + labels change much slower than CI |

The compose pattern (cached batch read):

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" run \
  --session-id "<session-id>" --ttl 10 -- \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/gh-batch.sh" pr-status \
    --repo <owner/repo> --numbers "142 143 144"
```

Cache hit → no GraphQL call. Cache miss → batched GraphQL call (1 round-trip for up to 50 numbers) cached for the next 10s.

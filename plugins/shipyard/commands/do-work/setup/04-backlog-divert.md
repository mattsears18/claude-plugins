# /shipyard:do-work — Setup phase · backlog fetch + divert + failing-PR snapshot

**Setup sub-phase (cluster 3 of 5).** Owns steps 4 → 5.8: fetch + rank the backlog, the main-CI / PR-pileup divert checks, the failing-PR snapshot, seeding inherited DIRTY PRs into `session_prs` for cross-session drain hand-off, and the flake-registry enforcement. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`01-repo-recovery.md`](./01-repo-recovery.md). Next: [`06-scope-preflight.md`](./06-scope-preflight.md).

### 4. Fetch + rank the backlog

**Timing instrumentation (issue #238).** Bracket this step including the auto-triage label-apply loop and client-side filter pass:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_4_backlog_fetch_and_rank 2>/dev/null || true
# ... run step 4 ...
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_4_backlog_fetch_and_rank 2>/dev/null || true
```

```bash
# Wide fetch — server-side filter is ONLY `--state open` (plus any
# `--label <L>` qualifiers passed at invocation). All eligibility checks
# move to the client-side filter pass below. See issue #332 for the
# regression this shape exists to prevent.
gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,labels,assignees,body,author,createdAt,updatedAt \
  --jq '[.[] | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}, createdAt, updatedAt}]'
```

The `--jq` projection mirrors step 2's: flatten `labels` / `assignees` to the consumed shapes (names, logins) and preserve `author.login` as the canonical shape downstream filters and step 7's `originating_author_trust` computation reference. Body stays full because the client-side filter walks it for `Blocked by #N` references. Worker-preamble §"`gh` JSON discipline" covers the convention.

Pass `--label <L>` qualifiers through as `--label <L>` (NOT `--search 'label:<L>'`) for any `--label` args supplied at invocation — the `--label` flag composes cleanly with the wide fetch above and is the canonical way to scope the universe down to a project subset.

**Why the server-side filter is intentionally wide (issue [#332](https://github.com/mattsears18/shipyard/issues/332)).** Earlier versions of this spec used a `--search` qualifier of the form `is:issue is:open -linked:pr` followed by `-label:` exclusions for each block-tier and gate label (`blocked:agent`, `blocked:agent-hard`, `wontfix`, `needs-design`, `needs-triage`, `discussion`, `needs-human-review`; the now-eliminated `needs-refinement` was also in this set before [#520](https://github.com/mattsears18/shipyard/issues/520)) to do the eligibility filter on GitHub's side. That shape silently dropped two classes of workable issues:

1. **`-linked:pr` excludes issues that ever had a linked PR opened against them**, even when that PR has since been closed, abandoned, or superseded. The resumable-work case — a prior session opened a PR that got closed before merge, the issue is still open and still self-assigned to `@me` — is exactly the bucket `-linked:pr` was supposed to NOT exclude but does. Concretely: a `lightwork` session at 2026-05-25 surfaced 14 issues from a backlog of 29 open ones; the orchestrator confidently emitted `ready=0 raw=0` and drained while 15 workable issues sat invisible to the dispatch queue. The user manually pointed out the discrepancy ("dude. there are 29 open issues!").
2. **Server-side label-exclusion qualifiers cannot encode "@me-assigned is OK, anyone-else-assigned is not"** — the search syntax has no `assignee:@me OR no:assignee` form, so the previous spec had to choose between `no:assignee` (which excludes prior-session self-assigns — the very case resumption needs) or unbounded (which over-fetches and relies on client-side dedup). The fix is to pick the second option and do all assignee gating client-side.

The fix in this revision: server-side fetch is purely `--state open` + optional `--label <L>` qualifiers (when the caller scopes to a label-bounded project subset). Every other eligibility check — author trust, assignee≠@me, blocking labels, `Blocked by #N` references, `closed-by-open-pr` membership — moves to the client-side filter pass below. The cost is one ~30-issue-larger JSON payload per setup pass; the win is no silent ~50% miss rate on the resumable-work case. The same fix lands in [drain.md's termination-assertion step 4](../drain.md#termination-assertion) (the fresh-fetch verification) and [steady-state.md step C's lightweight backlog re-check](../steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) so all three call-sites read the same universe and never disagree on what's workable.

The `author` field has two uses: (1) step 4's client-side trusted-author filter (the search-qualifier syntax has no `-author:` exclusion form, so this is necessarily client-side); (2) step 7's `originating_author_trust` dispatch-time gate (the third defense-in-depth layer). See [RATIONALE → Step 4 author field](../../do-work-RATIONALE.md#step-4--why-the-author-field-is-fetched).

**Auto-triage priority labels.** Before ranking, ensure every fetched issue carries exactly one of `P0`/`P1`/`P2`. For each issue whose `labels` array contains **none** of those three, judge severity from the title, body, and existing labels (`bug`, `security`, `a11y`, `perf`, `chore`, …) using the [audit-rubrics severity buckets](../../../skills/audit-rubrics/SKILL.md):

- `P0` — broken or unusable: runtime errors on the golden path, exposed secrets, RCE vectors, contrast failures on primary actions
- `P1` — significant friction or risk: confusing affordances, missing security headers, a11y failures on common flows, CVEs without patches
- `P2` — polish or moderate risk: spacing nits, copy improvements, low-severity CVEs with patches available, plus anything that doesn't fit P0/P1 but still merits work

When torn between two tiers, pick the lower-severity one. Apply exactly one label per issue:

```bash
gh issue edit <N> --repo <owner/repo> --add-label <Px>
```

Skip any issue that already carries one or more `P0`/`P1`/`P2` labels — preserve the human judgment that set them. Don't remove existing priority labels, and don't add a second one. Legacy `P3` labels are treated as unlabeled. See [RATIONALE → Auto-triage priority](../../do-work-RATIONALE.md#step-4--auto-triage-priority-rationale).

**This filter is the normative definition of what `/do-work` dispatches** ([#1076](https://github.com/mattsears18/shipyard/issues/1076)) — [`01b-backlog-overview.md`](./01b-backlog-overview.md#2-backlog-overview)'s bucket table is a rendering of it, and [`backlog-ownership.md`](./backlog-ownership.md) is the shared bucket→owner table both are checked against, rather than a third independently-authored description of this routing.

Client-side filter (in this exact order — each gate's drop reason should be logged so the [unfiltered_open_count](../steady-state.md#e-invariant-line-end-of-every-steady-state-turn) invariant token is auditable):

- **Drop issues whose `author.login` (lowercased) is NOT in `trusted_authors`.** This is the dispatch-time security gate — see [step 1.7](01-repo-recovery.md#17-resolve-trusted-author-allowlist) for how the set is populated. An issue filed by a stranger on a public repo lands in step 2's `Untrusted author` bucket and never enters the workable queue, even if all the other filters pass. Belt-and-suspenders with the step-2 bucket pass: step 2 surfaces the count to the user; step 4 enforces the actual drop at dispatch time. Both read the same `trusted_authors` cache so they can never disagree.

  **Bucket-0.5 handoff — label + comment newly-dropped issues so a human sees them, bounded + idempotent ([#1079](https://github.com/mattsears18/shipyard/issues/1079)).** The gate above is unchanged — this is a surfacing side effect only. Read [`04b-untrusted-author-handoff.md`](./04b-untrusted-author-handoff.md) now and run it in full immediately after the drop above: it applies `needs-human-review` + a one-line vouch-path comment to each issue this run's drop just excluded, bounded to issues newer than a persisted cross-session high-water mark (never a full-history sweep) and idempotent via a label-presence check. Runs every session — unlike [step 4.5a/4.5b](#4-fetch--rank-the-backlog), it is NOT `--fast`-skipped.

- **Drop issues carrying any of the dispatch-gate labels** — `blocked:ci`, `wontfix`, `discussion`, `needs-human-review`, `agent-console`, `tracking`. This is the client-side equivalent of the previous server-side `-label:...` qualifiers (removed in [#332](https://github.com/mattsears18/shipyard/issues/332) — see the wide-fetch rationale above). **`agent-console`** ([#608](https://github.com/mattsears18/shipyard/issues/608), renamed from `needs-operator` in [#995](https://github.com/mattsears18/shipyard/issues/995) — the legacy-name back-compat window is closed, per [#1082](https://github.com/mattsears18/shipyard/issues/1082): zero issues in this repo carried `needs-operator` at migration time, so this filter no longer recognizes the old name) marks a browser/console operator action — it is dropped from the **code-worker** dispatch queue here because it isn't code work, but by default the orchestrator drains it via the [operator phase](../operate.md) (the proactive sweep scans for `agent-console`-labeled issues), and `/my-turn` surfaces it as a human-actionable operator item; under the `--no-operate` / `--hands-off` opt-out it stays gated like `needs-human-review`. The set is deliberately enumerated, not pattern-matched — see "Why each `blocked:*` label is enumerated explicitly" below. **`needs-triage` is handled separately below** ([#556](https://github.com/mattsears18/shipyard/issues/556)) — trusted-author `needs-triage` issues are NOT dropped here; they are routed to the `investigate_candidates` queue when `triage.investigate_dispatch` is enabled (default on). Only untrusted-author `needs-triage` issues are dropped by the author-login gate above. **`blocked:agent-hard` and the legacy `blocked:agent` were dropped from this set** ([#521](https://github.com/mattsears18/shipyard/issues/521)) — the `blocked:agent-hard` label was eliminated: a refuse now carries `needs-human-review` (already in this set) and a dependency-wait carries no label (gated separately by the `Blocked by #N` body-reference rule below), so neither needs its own enumeration entry. **`needs-design` was folded into `needs-human-review`** ([#515](https://github.com/mattsears18/shipyard/issues/515)) — the binary-backlog migration's phase-1 slice collapsed the inert human-gate `needs-design` (a pure dispatch-exclusion + `/my-turn`-surfacing label with no auto-processing machinery) into `needs-human-review`, so it no longer appears here; `needs-human-review` covers the design-gated case. **`needs-decomposition` was folded into `needs-human-review`** ([#519](https://github.com/mattsears18/shipyard/issues/519)) — applied by [step 6's Deferred recording path](06-scope-preflight.md#6-initial-scope-pre-flight); the epic handoff carries the `<!-- do-work-needs-decomposition -->` body marker for `/decompose-epic`. **`tracking` is enumerated here as a defensive gate, not just a fold artifact** ([#1081](https://github.com/mattsears18/shipyard/issues/1081)) — the label object was never deleted, so it keeps landing on fresh epics; see [RATIONALE](../../do-work-RATIONALE.md#needs-decomposition--tracking--needs-human-review--body-marker-issue-519). **`needs-refinement` was eliminated entirely** ([#520](https://github.com/mattsears18/shipyard/issues/520)) — the binary-backlog phase-2 slice retired the persisted refinement gate; `/refine-issues` now detects refinement candidates by live source-signal scan as a pre-dispatch pass (step 3.5), so by the time the dispatch fetch runs there is no persisted refinement-gate state to exclude (auto-processable refinement work was already handled this session; the genuine no-automated-path subset landed on `needs-human-review`, which is already in this set). Excluding `needs-human-review` here is what stops `/do-work` from re-scoping the same epic every session (the scope-agent re-validation in [drain.md 5.b](../drain.md#5b--re-validate-scope-agent-and-cached-diagnosis-entries) removes the label if a fresh pass finds the issue ready, so a slicing-miss defer can still recover). **`blocked:agent-soft` is intentionally NOT in this set** (soft-blocked issues auto-clear at next-session backlog fetch — that's the entire point of the soft/hard split per #300; the in-session [soft-bail filter](../steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) handles the same-session retry-window case).
- **Route investigate-mode candidates to `investigate_candidates`** (gated on `triage.investigate_dispatch`). Trusted-author issues that match a **live detection scan** — bot-shaped author, symptom-shaped body, or (still accepted during the migration window) carrying `needs-triage` — are routed to `investigate_candidates` instead of `raw_backlog`. Read [`04d-investigate-routing.md`](./04d-investigate-routing.md) now and run it in full: it defines the three signals, the jq predicate, and the config-gated routing/drop behavior ([#1090](https://github.com/mattsears18/shipyard/issues/1090), generalizing [#556](https://github.com/mattsears18/shipyard/issues/556)'s label-only routing).

  `investigate_candidates` is a separate ordered list (FIFO, priority order within the list: `P0` > `P1` > `P2` > unlabeled, then staleness). It is populated here and consumed by the steady-state decision tree's step 1.5. Like `raw_backlog`, it starts empty at the top of step 4 and is finalized before step 4.5.
- Drop issues assigned to a user **other than** the gh-authenticated user (they own it). `@me`-assigned issues PASS — that's the resumable-work case (a prior session self-assigned the issue but didn't ship it), and the entire point of [#332](https://github.com/mattsears18/shipyard/issues/332)'s rework is to keep that case visible to the dispatch queue.
- Drop issues whose body contains `Blocked by #N` where #N is still open.
- **Drop issues whose body's FIRST LINE is a `<!-- do-work-blocked-until: YYYY-MM-DD -->` marker whose date is still in the future ([#1161](https://github.com/mattsears18/shipyard/issues/1161)).** This is the **time-gate** — the one dispatch-gate shape none of the existing mechanisms cover: work that isn't blocked on a human decision, an external dependency, an open `#N`, an untrusted author, or a non-shippable epic, but purely on a calendar date (a documented migration-window criterion, a scheduled quarantine deadline). Compare `YYYY-MM-DD` against **today's UTC calendar date** (`date -u +%F`) — drop while `today < date`, admit once `today >= date`. Like the `Blocked by #N` filter immediately above, this is **self-clearing**: no label is applied, no sweep reconciles it, and the issue simply re-enters the workable queue the instant the date elapses on the next backlog fetch — the same properties that made the `Blocked by #N` body-reference filter preferable to the eliminated `blocked:agent-hard` label ([#521](https://github.com/mattsears18/shipyard/issues/521)). **Position discipline, line 1 only ([#1168](https://github.com/mattsears18/shipyard/issues/1168))** — a marker anywhere else (mid-paragraph, backticked, fenced, or quoted) is NOT live and MUST NOT gate dispatch; it's always written on line 1, never mid-body ([recording path](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes)). A marker on line 1 with an unparseable date is still **not blocked** (fail open, unchanged). No marker on line 1 → unaffected.
- **Drop issues that have an open linked PR authored by `@me` AND that PR is healthy.** The "healthy" qualifier is load-bearing: a closed/abandoned PR (the resumable case) does NOT lock the issue against re-dispatch, and an open-but-failing PR is in the orchestrator's [`failed_prs` / fix-checks bucket](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) rather than the issue's. Build the set **once per setup pass** from open PRs' `closingIssuesReferences` field — the structural projection GitHub itself uses to decide which issues auto-close on merge — joined against `author.login == @me` and `mergeStateStatus ∈ {CLEAN, HAS_HOOKS, UNSTABLE}` (i.e. no failing checks):

  ```bash
  CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
  export CLAUDE_PLUGIN_ROOT
  # Build the "open, @me-authored, healthy" closing set once per setup pass.
  # Drop the candidate issue if any healthy @me-authored open PR has it in
  # closingIssuesReferences. The healthy gate uses the same latest-per-name
  # rollup projection issue #333 added so a re-triggered green check doesn't
  # false-positive as still-failing.
  open_pr_numbers=$(gh pr list --repo <owner/repo> --state open --author @me --limit 200 \
    --json number --jq '[.[].number] | join(" ")')
  closed_by_open_healthy_pr=$("${CLAUDE_PLUGIN_ROOT}/scripts/gh-batch.sh" pr-status \
    --repo <owner/repo> --numbers "$open_pr_numbers" \
    | jq '[.[] | select(
        .mergeStateStatus == "CLEAN"
        or .mergeStateStatus == "HAS_HOOKS"
        or .mergeStateStatus == "UNSTABLE"
      )
      | select(
        ([(.statusCheckRollup // [])
         | group_by(.name)
         | map(sort_by(.completedAt // .startedAt // "") | last)
         | .[]
         | select(.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "TIMED_OUT")
        ] | length) == 0
      )
      | .closingIssueNumbers[]
    ] | unique')
  # Then, for each candidate issue #N, drop if jq -e ".[] | select(. == <N>)" matches.
  ```

  Why the substring-search form was removed (issue [#301](https://github.com/mattsears18/shipyard/issues/301)): the previous implementation fired three `gh pr list --search 'in:body "Closes #<N>"'` queries per candidate and dropped the issue on any hit. That's a substring match against PR bodies, not a semantic check — release PRs commonly list closed-by-this-release issues in their CHANGELOG bodies, and each `Closes #<N>` line in such a manifest silently suppressed the referenced issue from the workable queue even though the PR isn't actually closing it on merge. `closingIssuesReferences` is GitHub's authoritative signal for "does this PR auto-close this issue?" — it matches exactly the issues that will auto-close, with no false positives on CHANGELOG manifests, meta-issue PRs that quote closed children, or comment-quoted PRs. Cost: one `gh pr list` + one batched GraphQL call (vs N×3 search calls); accuracy: exact match against GitHub's own closing-link definition.

  Why the `@me` + healthy join was added (issue [#332](https://github.com/mattsears18/shipyard/issues/332)): the previous `closed-by-open-pr` check joined against every open PR regardless of author or health, so an open PR by another author claiming to close issue #N — or an open `@me`-authored PR that was sitting red with no fix-checks worker assigned — both excluded #N from the dispatch queue. The first case is overreach (other authors can't lock our queue); the second case re-introduces exactly the [#332](https://github.com/mattsears18/shipyard/issues/332) failure mode the wide-fetch rework was designed to prevent (an abandoned/red PR shouldn't hide its issue from the workable queue indefinitely).

  Cache for the duration of step 4 — open PRs don't change between filter passes within a single setup invocation.

**Why each `blocked:*` label is enumerated explicitly.** GitHub's search syntax (which `gh issue list --search` passes through) does NOT support label-name glob patterns — `-label:blocked:*` does not match `blocked:agent-hard` or `blocked:ci`; it's treated as a literal label name `blocked:*` which doesn't exist. The same constraint applies to the client-side jq filter — every block-tier label that should hide an issue from the workable queue must appear as its own literal name. **`blocked:agent-hard` and the legacy `blocked:agent` are no longer in the filter** ([#521](https://github.com/mattsears18/shipyard/issues/521)) — the `blocked:agent-hard` label was eliminated; a refuse carries `needs-human-review` (which IS excluded, enumerated below) and a dependency-wait carries no label (it's hidden by the separate `Blocked by #N` body-reference drop, not by a label match). `blocked:agent-soft` is intentionally NOT excluded — soft-blocked issues auto-clear at next-session backlog fetch (the whole point of the soft/hard split is that subjective bails don't permanently hide work). `blocked:ci` is a PR-side label so it has no effect on issue search (issues never carry it) — included in the enumeration for defense in depth in case a future revision applies it to issues too. `needs-human-review` is enumerated for the same literal-name reason — it's a `needs-*` gate label, not a `blocked:*` one, but the same "no glob patterns" constraint applies, so it must appear by its exact name in both the search qualifier and the client-side jq filter. **`needs-triage` is intentionally NOT in the drop-label enumeration** ([#556](https://github.com/mattsears18/shipyard/issues/556)) — trusted-author `needs-triage` issues are re-routed to `investigate_candidates` above rather than dropped; only untrusted-author `needs-triage` issues are dropped (by the author-login gate, which runs before this label filter). When `triage.investigate_dispatch == "false"`, the re-routing step skips and such issues are silently dropped, which is the pre-#556 behavior. The former `needs-decomposition` ([#498](https://github.com/mattsears18/shipyard/issues/498)) is folded into `needs-human-review` and needs no entry of its own. **`tracking` ([#501](https://github.com/mattsears18/shipyard/issues/501)) is enumerated anyway, as a defensive gate against the label object never being deleted** ([#1081](https://github.com/mattsears18/shipyard/issues/1081)) — see [RATIONALE](../../do-work-RATIONALE.md#needs-decomposition--tracking--needs-human-review--body-marker-issue-519). If future block tiers are added (`blocked:external`, `blocked:design`, etc.), enumerate each one here.

Sort the survivors (non-`needs-triage` issues only — `needs-triage` issues were already siphoned off to `investigate_candidates` above):

1. **Prioritized label** (only if `--prioritize-label` was passed): issues carrying that label come first. Issues without it fall to the next tier.
2. **Priority label**: `P0` > `P1` > `P2` > unlabeled. Convention: `P0` = critical/release-blocker, `P1` = high (this cycle), `P2` = normal. After the step-4 auto-triage pass, the `unlabeled` tier should normally be empty — it remains as a safety net for issues triage somehow skipped, and as the fallback bucket for legacy `P3` labels. If an issue carries multiple priority labels, rank by the highest one present.
3. **Type**: `bug` > `fix(...)` titles > `feat(...)` titles > `chore(...)` > everything else.
4. **Staleness**: oldest `updatedAt` first within the same tier — stale work counts.

This ordered list is the initial `raw_backlog`. If empty AND no failing PRs exist (next step) → loop ends immediately; report "backlog empty" and stop. Note: `investigate_candidates` being non-empty does NOT constitute a non-empty raw_backlog — the two queues are independent, and the loop continues even when `raw_backlog` is empty but `investigate_candidates` has entries (the step 1.5 dispatch step handles those).

### 4.5 Divert checks (main CI + PR pileup)

> **`--fast` skip:** When `--fast` is set, skip both 4.5a and 4.5b. Leave `main_ci.status = "unknown"` and `failing_pr_count_all = 0`. `divert_queue` stays empty. The user accepts the risk of dispatching into a red `main` or a ≥10-PR pileup — this is the documented tradeoff in the `--fast` arg description. The step-D periodic refresh does NOT run divert checks either when `--fast` was set (to preserve the latency savings for the full session). Note the skip in the end-of-session `--fast was used` advisory block.

Two repo-health conditions can preempt all normal work. Run these checks at setup, repopulate `divert_queue`, then continue. The same checks re-run during the periodic refresh (step D).

Both reads (4.5a and 4.5b) are part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — fire them in parallel with steps 1 / 2 / 3d.1 / 3d.2 / 5. The aggregation logic (per-workflow grouping in 4.5a, rollup filtering in 4.5b) runs locally on the JSON returned from each call; no further network I/O is needed.

**4.5a — Main CI status.** Determine whether main is currently healthy by looking at *each workflow's* most-recent COMPLETED run on `<default-branch>`. Main is green only when every workflow's last completed run was a success. Evaluate at **per-workflow** granularity — never aggregate across workflows on a single commit, and never filter `--status completed` in the `gh run list` call (it hides in-progress workflows). See [RATIONALE → Step 4.5a CI aggregation](../../do-work-RATIONALE.md#step-45a--why-per-workflow-ci-aggregation-matters) for the failure modes this prevents.

```bash
# Most recent 60 runs on the default branch (any status — DO NOT filter --status completed)
gh run list --repo <owner/repo> --branch <default-branch> \
  --limit 60 \
  --json databaseId,conclusion,status,displayTitle,headSha,url,createdAt,workflowName

# Branch protection — used to scope the red-gating set to required workflows only.
# 404 is the expected response on repos without branch protection (open-source forks,
# personal repos that never configured it); fall through to "all workflows gate".
gh api "repos/<owner/repo>/branches/<default-branch>/protection/required_status_checks" \
  --jq '.checks // [] | map(.context)' 2>/dev/null
```

Compute per-workflow status, then aggregate:

1. Group runs by `workflowName`. Within each group, keep `gh`'s newest-first `createdAt` order.
2. For each workflow, find its most recent run whose `status == "completed"` AND whose `conclusion != "cancelled"`. That's the workflow's current health:
   - `conclusion in {success, skipped, neutral}` → workflow is **green**
   - `conclusion in {failure, timed_out, startup_failure, action_required}` → workflow is **red**
   - no qualifying completed run in the window (only `in_progress` / `queued` / `waiting` / `requested`, or every completed run in the window was `cancelled`) → workflow is **pending**

   `cancelled` runs are skipped over rather than treated as a verdict because the common cause on actively-developed repos is GitHub's concurrency-group auto-cancellation when a newer commit lands on the same branch (the *supersession* case) — that is normal traffic, not a CI failure, and the next non-cancelled run on a newer SHA carries the actual verdict. Hung-then-timeout cancellations and manual cancellations are also non-actionable by `fix-main-ci` (there's no "fix" for a manual cancel; only the next run's verdict matters), so the same skip-and-keep-looking rule applies uniformly across all cancellation causes. If every completed run for a workflow in the 60-run window is `cancelled`, the workflow's status falls through to **pending** and step-D's next refresh re-evaluates once a non-cancelled run completes. Closes [#261](https://github.com/mattsears18/shipyard/issues/261).
3. Resolve the **required-workflows set** that gates red aggregation. Closes [#262](https://github.com/mattsears18/shipyard/issues/262) — non-required workflows (post-release recovery helpers, infrastructure-state probes, scheduled cleanup jobs) commonly fail for reasons unrelated to code health and shouldn't trigger a `fix-main-ci` divert. Resolution order (first match wins; later layers override the same field per the standard config merge):
   - **Config: explicit list.** If `main_ci.required_workflows` is set to a non-empty array in the effective merged config, that list IS the required set. Match against each workflow's `workflowName` exactly (case-sensitive).
   - **Config: `all-workflows` mode.** If `main_ci.aggregation_mode == "all-workflows"`, every workflow gates (the pre-#262 behavior). Skip the branch-protection probe.
   - **Branch protection (default behavior, `main_ci.aggregation_mode == "branch-protection"`).** Read `repos/<owner/repo>/branches/<default-branch>/protection/required_status_checks.checks[].context` (the `.context` field is the check-run name GitHub matches against, which equals the workflow name when the workflow has a single job — the common case). The returned list IS the required set. If the API returns 404 (no branch protection rule), an empty list, or any error, fall through to **all-workflows** (the safety default — when there's no signal that any workflow is non-required, gate on everything, matching pre-#262 behavior). When the rule does exist but the protected branch isn't the default branch in this repo (rare), the 404 fall-through still applies.

   Match each workflow's status to the required set. The required set splits workflows into two buckets:
   - **Gating bucket** — workflows whose name is in the required set. These are the only workflows that contribute to `main_ci.status` red.
   - **Informational bucket** — workflows NOT in the required set. Their per-workflow status (green/red/pending) is still computed and surfaced (see `non_required_red_workflow_names` below) so the user retains visibility into infra-health failures, but they do NOT cause a `fix-main-ci` divert.

4. Aggregate to a single `main_ci.status` using the **gating bucket only**:
   - any **gating** workflow is **red** → `main_ci.status = "red"`. Use the *most recent* red run across all red gating workflows as `earliest_red_run_*` (most actionable for the fix-main-ci dispatch). Collect **all** red gating-workflow names into `red_workflow_names` (sorted alphabetically).
   - else any **gating** workflow is **pending** → `main_ci.status = "pending"`
   - else every **gating** workflow is **green** → `main_ci.status = "green"`
   - else (no gating runs at all in the window, or the gating set is empty) → `main_ci.status = "unknown"`

Cache `{ status, earliest_red_run_id, earliest_red_run_url, earliest_red_sha, earliest_red_workflow_name, red_workflow_names, red_workflow_count, required_workflow_names, required_workflow_source, non_required_red_workflow_names, non_required_red_workflow_count, checked_at: now }` in `main_ci`.

- `earliest_red_workflow_name` — the `workflowName` of the most recent red gating run (the same run whose `databaseId` is `earliest_red_run_id`). Used by the status line to show a single name in the compact format.
- `red_workflow_names` — sorted list of all red gating workflow names. Used by the banner to show the full list.
- `red_workflow_count` — `red_workflow_names.length`. Used by the status line truncation logic.
- `required_workflow_names` — sorted list of the resolved required set. Empty array when the source was `all-workflows` (no filter applied). Used by the end-of-session debug surfaces and `/shipyard:status`.
- `required_workflow_source` — one of `config-list`, `config-all-workflows`, `branch-protection`, `branch-protection-fallback-all-workflows`. Tells the maintainer where the gating set came from. The last value means a branch-protection probe was attempted but produced no usable list (404, empty, or error) — useful for diagnosing "why is `red_workflow_names` showing infra workflows?" on a repo that DOES have branch protection (e.g. wrong default branch, missing token scope).
- `non_required_red_workflow_names` — sorted list of red workflow names that are NOT in the required set. Surfaced in the status line and banner so the user still sees infra failures even though they don't divert. Empty when the source was `all-workflows`.
- `non_required_red_workflow_count` — `non_required_red_workflow_names.length`.

- If `main_ci.status == "green"` → clear any `fix-main-ci` entry from `divert_queue`. **Also reset the attempt counter** ([#589](https://github.com/mattsears18/shipyard/issues/589)): for every signature in `main_ci_fix_attempts` whose workflow is *not* currently in `red_workflow_names`, delete the entry (the fix worked — main is green on that workflow, so the next time it reds it starts a fresh attempt cycle). A signature still in `red_workflow_names` keeps its counter.
- If `main_ci.status == "red"` → **before enqueueing, check the per-signature attempt cap** ([#589](https://github.com/mattsears18/shipyard/issues/589)). Read `main_ci.max_fix_attempts` from the merged config (default 3). Let `sig = earliest_red_workflow_name` and `att = main_ci_fix_attempts[sig].attempts // 0`:
  - If `att >= max_fix_attempts` (or `main_ci_fix_attempts[sig].escalated == true`) → **do NOT enqueue a `fix-main-ci` divert** for this signature. Set `main_ci_fix_attempts[sig].escalated = true`. This is the circuit breaker: the same workflow has been "fixed" `max_fix_attempts` times and each fix passed on its own PR run but left main's merge-commit red — the strong signal of a flaky CI-only test (a deterministic regression would fail the PR run too). Fire the **flake-escalation banner** (see [scope-preflight.md step 6.5's banner spec](06c-scope-handling-ui.md#state-change-banners--make-divert-events-impossible-to-miss)) once per signature on the transition into `escalated`, and surface `main:🔴 (<workflow-summary>, run <id>) · flake-escalated: <sig> (<att> fix attempts, each green-on-PR/red-on-merge)` in the status line. The escalation recommends quarantine (`test.fixme` / skip) + a tracking issue, or human CI-side investigation. Do NOT auto-retry — a human must intervene (same posture as a `blocked main-ci-fix` return).
  - Else (`att < max_fix_attempts`) → enqueue `{ kind: "fix-main-ci", target: "main", earliest_red_run_id, earliest_red_run_url, earliest_red_sha, earliest_red_workflow_name, red_workflow_names, red_workflow_count }` into `divert_queue` — unless an entry is already in `divert_queue` OR an `in_flight` slot is already working `kind: "fix-main-ci"` (don't double-dispatch the diversion).
- If `main_ci.status == "pending"` → don't enqueue; the next step-D refresh re-evaluates once a run completes.
- If `main_ci.status == "unknown"` → don't enqueue.

**Never** report `main_ci.status = "green"` on the basis of a single successful workflow run. The status line must derive from the per-workflow aggregate above.

#### Post-main-CI-fix branch-refresh — un-stick session PRs carrying a stale failing required check ([#993](https://github.com/mattsears18/shipyard/issues/993))

GitHub does **not** re-run a PR's already-completed required check just because the PR's base branch went from red to green — without a new commit or an explicit branch update, a PR that recorded a `FAILURE` while `main` was broken keeps that stale conclusion forever, even though the underlying cause is now fixed and a fresh run would pass. Left unhandled, this permanently strands every `session_prs` entry that happened to run its required checks during the `main`-red window: `mergeStateStatus` reads `MERGEABLE` and auto-merge is armed, but the stale check will never re-run on its own, so the PR sits `BLOCKED` indefinitely — even though a `fix-main-ci` dispatch already landed the remedy and `main` is green again. See [RATIONALE → Stale-red vs genuinely-red](../../do-work-RATIONALE.md#stale-red-vs-genuinely-red-993) for the session repro that motivated this (a 7-PR merge train left `BLOCKED` forever after the diversion that unblocked it had already merged).

**Fires immediately after the `main_ci.status == "green"` bullet above, and only on a genuine transition into green** — never on every green evaluation, because a PR carrying a check that's failing against the *current, already-fixed* `main` must NOT get a masking re-run. Before overwriting the cached `main_ci` object with this evaluation's result, capture its existing `.status` as `previous_main_ci_status` (an absent/first-run cache counts as non-green). The refresh below runs only when `previous_main_ci_status != "green"` AND the freshly-computed `main_ci.status == "green"`.

```bash
# Only fires on a red/pending/unknown → green transition.
if [ "$previous_main_ci_status" != "green" ]; then
  # The fix's merge commit — main's current HEAD, now that it's green.
  fix_commit_sha=$(gh api "repos/<owner/repo>/commits/<default-branch>" --jq '.sha')
  fix_commit_date=$(gh api "repos/<owner/repo>/commits/<default-branch>" --jq '.commit.committer.date')

  for pr in $session_prs; do
    pr_snapshot=$(gh pr view "$pr" --repo <owner/repo> --json state,mergeStateStatus,statusCheckRollup --jq '
      {state, mergeStateStatus,
       checks: [.statusCheckRollup | group_by(.name) | map(sort_by(.completedAt // .startedAt // "") | last) | .[]]}')
    state=$(echo "$pr_snapshot" | jq -r '.state')
    merge_state=$(echo "$pr_snapshot" | jq -r '.mergeStateStatus')

    # Skip merged/closed PRs, and skip DIRTY — that's fix-rebase's territory,
    # not this gate's (see the guard note below).
    [ "$state" != "OPEN" ] && continue
    [ "$merge_state" = "DIRTY" ] && continue

    # Any latest-per-name check that's a hard failure AND completed BEFORE the
    # fix landed is a stale-red carried over from the broken main — not a
    # genuine failure against the current (fixed) base.
    has_stale_red=$(echo "$pr_snapshot" | jq --arg cutoff "$fix_commit_date" '
      [.checks[] | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
                  | select((.completedAt // .startedAt // "9999") < $cutoff)] | length > 0')
    [ "$has_stale_red" != "true" ] && continue

    # Once per PR per fix, never in a loop — update-branch writes a merge
    # commit, so repeated calls against the same fix churn history for
    # nothing. stale_check_refresh_done persists for the rest of the session.
    if [ "${stale_check_refresh_done[$pr]:-}" = "$fix_commit_sha" ]; then
      continue
    fi

    gh pr update-branch "$pr" --repo <owner/repo> || true
    stale_check_refresh_done[$pr]="$fix_commit_sha"
    echo "[stale-check-refresh] PR #$pr carried a required-check FAILURE that predates <default-branch>'s fix commit $fix_commit_sha (fixed at $fix_commit_date) — ran gh pr update-branch to re-trigger checks against the fixed base (#993)"
  done
fi
```

**Guards, matching the issue's suggested fix exactly:**

- **Only for PRs whose failing check predates the fix.** A PR whose latest failing run completed *after* `fix_commit_date` already ran against the fixed base and is genuinely red — running `gh pr update-branch` there would mask a real failure behind a fresh run rather than surface it. The `completedAt < fix_commit_date` comparison (latest-per-name, the same de-duplication convention used throughout [drain.md](../drain.md#drain-protocol) and [steady-state.md](../steady-state.md#a1-parse-the-return-string)) is what tells stale-red apart from genuinely-red.
- **Once per PR per fix, never in a loop.** `stale_check_refresh_done[<pr>]` records the `main` SHA the refresh already ran against for that PR; it prevents a second re-poll from calling `update-branch` again for the same fix before the freshly-triggered check has had a chance to complete.
- **Skip DIRTY PRs.** Those belong to `fix-rebase`, not this gate — `gh pr update-branch` rebases a DIRTY branch onto the new base as a side effect, which is a different, already-bookkept code path (`rebase_success_counts`, `rebase_blocked_prs` in [drain.md](../drain.md#drain-protocol)). Leaving DIRTY PRs to that existing mechanism avoids double-counting a rebase outside its owning bookkeeping.

**Session-scoped state.** `stale_check_refresh_done` is a per-session map (`<pr-number> → <sha>`), initialized empty at session start alongside the other per-session structures ([the `do-work.md` orchestrator-state struct list](../../do-work.md#orchestrator-state)). It is never persisted across sessions — a fresh session re-evaluates from scratch, which is safe because the dedup only prevents redundant `update-branch` calls within a single continuous drive of the same fix.

This mechanism is **evaluated at every call site that runs 4.5a** — session setup and [step D's periodic refresh](../steady-state.md#d-periodic-refresh) — so it fires automatically the first time either path observes the red→green transition; no separate wiring is needed at either call site. See [drain.md's post-main-CI-fix branch-refresh](../drain.md#post-main-ci-fix-branch-refresh-drain-phase-993) for the corresponding drain-phase health read — drain does not enqueue new `divert_queue` work, but it still needs to observe this same transition so a fix that lands *during* drain un-sticks the PRs it stranded, rather than leaving the whole merge train `BLOCKED` for the next session to discover.

**4.5b — Failing-PR pileup.** Count open PRs across **all authors** whose check rollup contains a hard failure:

```bash
gh pr list --repo <owner/repo> --state open --limit 200 \
  --json number,title,author,headRefName,statusCheckRollup
```

Filter to PRs where the **latest run per check name** has `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` (or `state` for legacy check-runs). Count distinct PR numbers → `failing_pr_count_all`. Cache the count and the matching PR numbers (`failing_prs_all_authors`).

**Use the latest-per-name projection, not a naïve rollup walk** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). `statusCheckRollup` returns the union of every check run for the PR's head SHA, including superseded runs — a check that ran, failed, was re-triggered, and passed appears twice (one FAILURE + one SUCCESS). A naïve `.statusCheckRollup[] | select(.conclusion=="FAILURE")` walk false-positives on every such PR, silently inflating `failing_pr_count_all` past the divert-threshold (`>= 10`) and triggering an unnecessary `fix-failing-prs-batch` divert against a pileup that has already cleared. De-duplicate by `name` and take the most recent entry per check (by `completedAt`, fallback `startedAt`) before checking for hard failures:

```bash
failing_pr_numbers=$(gh pr list --repo <owner/repo> --state open --limit 200 \
  --json number,title,author,headRefName,statusCheckRollup \
  --jq '[.[] | select(
    [.statusCheckRollup
     | group_by(.name)
     | map(sort_by(.completedAt // .startedAt // "") | last)
     | .[]
     | select((.conclusion // .state // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
    | length > 0) | .number]')
failing_pr_count_all=$(echo "$failing_pr_numbers" | jq 'length')
```

- If `failing_pr_count_all >= 10` → enqueue `{ kind: "fix-failing-prs-batch", target: "pr-pileup", failing_pr_numbers: [...] }` into `divert_queue` — unless one is already enqueued OR `in_flight`.
- If `failing_pr_count_all < 10` → clear any `fix-failing-prs-batch` entry from `divert_queue`.

Both checks are cheap (two `gh` calls) and the cached results power the status line in step 5.5. Don't re-run them per dispatch — only at setup and at step D's periodic refresh.

### 5. Snapshot failing PRs

> **Lazy-load when `concurrency == 1`.** At C=1 the orchestrator runs sequentially — at most one slot is ever in flight. The failing-PR set is only relevant when there's a free moment to dispatch a fix-checks worker, and a free moment is guaranteed to exist whenever the single slot returns and all queues are empty. Skip this query at setup and defer it to the first idle turn in the steady-state loop (step D's Failed-PR scan). Set `failed_prs = []` at startup. The `-label:blocked:ci` filter note still applies when the deferred query eventually runs.

This read is part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — fire it in parallel with steps 1 / 2 / 3d.1 / 3d.2 / 4.5a / 4.5b. The filtering / deduping logic runs locally on the returned JSON.

```bash
gh pr list --repo <owner/repo> --state open --author @me \
  --search '-label:blocked:ci -is:draft' \
  --json number,title,headRefName,statusCheckRollup,mergeStateStatus \
  --limit 100
```

Filter to PRs where the **latest run per check name** has `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` (or `state` for legacy check-runs). Ignore `PENDING` / `IN_PROGRESS` — those are still running and auto-merge will catch them.

**Use the latest-per-name projection, not a naïve rollup walk** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). Same reasoning as step 4.5b above: `statusCheckRollup` returns every check run for the head SHA, and stale FAILURE entries superseded by later SUCCESS would otherwise re-enqueue PRs into `failed_prs` that are actually green. The orchestrator then dispatches a fix-checks worker, which returns `noop: already green` — wasted dispatch slot and tokens. De-duplicate first:

```bash
failed_pr_numbers=$(gh pr list --repo <owner/repo> --state open --author @me \
  --search '-label:blocked:ci -is:draft' \
  --json number,title,headRefName,statusCheckRollup,mergeStateStatus \
  --limit 100 \
  --jq '[.[] | select(
    [.statusCheckRollup
     | group_by(.name)
     | map(sort_by(.completedAt // .startedAt // "") | last)
     | .[]
     | select((.conclusion // .state // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
    | length > 0)]')
```

Each entry → push onto `failed_prs`, **deduped against entries already in `failed_prs`** (step 3c may already have enqueued some). These are the highest-priority work items *after* `divert_queue` because a red PR you opened last session won't auto-merge no matter how many new issues you ship. Note: this query is `@me`-scoped on purpose — `failed_prs` is for fix-checks work on PRs *you authored*. The all-authors count from step 4.5b feeds the divert decision, not this queue.

The `-label:blocked:ci` filter is still correct because [step 3d's auto-clear sweep](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session) already ran — refreshed PRs are unlabeled by 3d and flow through normally; only genuinely-stuck PRs still carry the label here. See [RATIONALE → Step 5 filter correctness](../../do-work-RATIONALE.md#step-5--why-the--labelblockedci-filter-is-still-correct).

### 5.7 Seed inherited DIRTY PRs into `session_prs` (cross-session drain hand-off)

Closes [#373](https://github.com/mattsears18/shipyard/issues/373) — the **cross-session DIRTY-PR blackhole**. The end-of-session drain's [`D_dirty` set](../drain.md#drain-protocol) — the only place `/shipyard:do-work` dispatches a fix-rebase worker — is computed from `session_prs`, and `session_prs` is populated *only* by step A's `shipped` reconciles (PRs this session opened) plus pre-existing `@me` PRs that fix-checks touched this session. A PR left `DIRTY` by a *prior* session is neither: this session didn't open it, and if it's DIRTY-but-green there's no failing check for the step-5 scan to enqueue into `failed_prs`, so no fix-checks worker ever touches it. Net effect: an inherited DIRTY PR is invisible to the drain forever — steady-state never dispatches fix-rebase (it's drain-only by design), and drain never sees the PR (it's not in `session_prs`). The PR sits DIRTY across every subsequent session until a human rebases it manually. Observed in `mattsears18/lightwork` across five consecutive sessions (PRs #1355, #1361, #1364, #1371 stranded 24+ hours).

This step closes the loop with the minimum-surgery shim from the issue's suggested behavior: snapshot the inherited DIRTY PRs authored by `@me` and seed them into `session_prs` at setup, so the existing drain machinery owns them. The drain's per-poll `D_dirty` classifier then dispatches a fix-rebase worker for each (subject to the same `--concurrency` cap, `rebase_blocked_prs` gate, and 3-successful-rebase rate cap that govern session-opened DIRTY PRs). No new dispatch surface, no change to the steady-state-never-dispatches-fix-rebase rule — the inherited PRs simply join the set the drain already watches.

**This is a divergence from the issue's literal mechanic** ("append `failed_prs` entries whose `mergeStateStatus == \"DIRTY\"` to `session_prs`"). `failed_prs` holds only red-check PRs; the repro PRs were DIRTY-but-green, so they were never in `failed_prs` to begin with. Seeding from `failed_prs` alone would miss exactly the PRs the issue is about. The correct source is a direct DIRTY-PR query, projected the same `@me` + healthy-checks way the drain's `D_dirty` set is.

This read is part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it can fire in parallel with steps 1 / 2 / 3d.1 / 3d.2 / 4.5a / 4.5b / 5. Query `@me`-authored open PRs and keep those whose `mergeStateStatus == "DIRTY"` AND whose latest-run-per-name check rollup has **no** hard failure (the drain's [`D_dirty` definition](../drain.md#drain-protocol) — a PR that's both DIRTY *and* red is fix-checks work, not rebase work, and the step-5 scan already enqueued it):

```bash
inherited_dirty_pr_numbers=$(gh pr list --repo <owner/repo> --state open --author @me \
  --search '-is:draft' \
  --json number,mergeStateStatus,statusCheckRollup \
  --limit 200 \
  --jq '[.[]
    | select(.mergeStateStatus == "DIRTY")
    | select(
        [.statusCheckRollup
         | group_by(.name)
         | map(sort_by(.completedAt // .startedAt // "") | last)
         | .[]
         | select((.conclusion // .state // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
        | length == 0)
    | .number]')
```

Append each number to `session_prs`, **deduped** against entries already there (a PR this session opened and that has since gone DIRTY is already in `session_prs` — don't double-add). The dedup also means re-running this step is idempotent. Do NOT mark these PRs in any other queue (`failed_prs`, `ready_issues`, `divert_queue`) — `session_prs` membership is the entire mechanism; the drain's existing classifier does the rest.

**Why seed at setup rather than re-query in drain.** The drain's [initial snapshot](../drain.md#drain-protocol) is documented as "the set of PRs the orchestrator opened this session" plus fix-checks-touched PRs — keeping that definition narrow (it's the per-session ownership boundary that prevents the drain from babysitting unrelated authors' PRs forever). Seeding `session_prs` at setup is the explicit, auditable hand-off: the orchestrator is *adopting* these inherited DIRTY PRs into the current session's ownership set, which is exactly the semantic the issue asks for. The drain code stays unchanged; only the membership of the set it reads grows.

> **Lazy-load when `concurrency == 1`** — same carve-out as [step 5](#5-snapshot-failing-prs). At C=1 the inherited-DIRTY snapshot can defer to the first idle turn alongside the step-5 failed-PR scan; the drain only consumes `session_prs` at end-of-session, so seeding it any time before drain entry is sufficient. When deferred, [steady-state step D's failed-PR scan](../steady-state.md#d-periodic-refresh) runs this query in the same sub-step (it's the same `@me` open-PR list, just a different projection) and seeds `session_prs` then. Set the snapshot aside at startup and let step D pick it up.

### 5.75 Seed inherited draft PRs (draft-PR recovery)

Closes #1069 — a draft PR is invisible to the step-5 scan (checks read SKIPPED, not red) and to 5.7's DIRTY seed (`mergeStateStatus` is usually CLEAN). Read [`04c-draft-pr-recovery.md`](./04c-draft-pr-recovery.md) now and run it in full: classify inherited `@me` draft PRs, auto-ready the safe ones, hand back the rest, record both for the summary.

### 5.8 Enforce the flake registry (chronic-flake escalation)

Closes [#385](https://github.com/mattsears18/shipyard/issues/385) — phase 2 of the cross-PR flake registry. [Phase 1](#5-snapshot-failing-prs) (issue #378, `scripts/flake-registry.sh`) shipped the data layer: each `fix-checks-only` worker records a flake event when it concludes a failure was a flake, and `flake-registry.sh crossed` names which (workflow, job, test) flakes have crossed the escalation threshold (≥ `rerun_threshold` events spanning ≥ `distinct_prs_threshold` distinct PRs within `window_days`). Phase 1 deliberately stopped at "name the crossed flakes." This step is the **enforcement consumer** — it reads `crossed` and performs the three configured escalation actions so a chronic flake gets root-caused instead of silently re-run forever. Also closes [#863](https://github.com/mattsears18/shipyard/issues/863): the `--prune-window-days` flag on the `flake-enforce.sh enforce` call below is the scheduled prune this step was missing — see that call's comment for the wiring.

**Gate on `flake_registry.enabled`.** Skip this step entirely unless the effective config has `flake_registry.enabled == true` (it defaults to `false`, preserving pre-#378 behavior). The check is one config read against the already-loaded `EFFECTIVE_CONFIG` (step 0.4):

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
FLAKE_ENABLED=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get flake_registry.enabled 2>/dev/null || echo false)
if [ "$FLAKE_ENABLED" = "true" ]; then
  # Read crossed flakes and enforce the per-row actions. The helper computes
  # `crossed` itself (passing the configured window/thresholds through), files
  # a deduped tracking issue per crossed flake, writes the crossed key to
  # <repo-root>/.shipyard/flake-suspects.txt, and labels affected PRs blocked:ci
  # — each action idempotent so re-running across sessions doesn't duplicate
  # side effects. --repo-root MUST be the PRIMARY checkout, not the
  # orchestrator worktree (issue #1059) — .shipyard/flake-suspects.txt is
  # gitignored, so a fresh orchestrator worktree checked out from
  # origin/<default-branch> never contains a suspects file a prior session
  # wrote; pointing this call at the orchestrator worktree would silently
  # restart flake tracking from empty every session instead of accumulating
  # across them. Use the SHIPYARD_REPO_ROOT pin stashed in step 0.56, not
  # `git rev-parse --show-toplevel` (which resolves to wherever cwd
  # currently is — the orchestrator worktree, post-relocation).
  #
  # --prune-window-days (issue #863): flake-registry.sh has always shipped a
  # `prune` subcommand, but nothing ever called it — with flake_registry
  # enabled, ~/.shipyard/flake-registry.jsonl grew unbounded forever. This is
  # the scheduled call: once per session, gated on the same
  # `flake_registry.enabled` flag as the rest of this step, opted into
  # flake-enforce.sh's own --prune-window-days flag so a bare `enforce`
  # invocation elsewhere (tests, manual runs) still leaves the registry
  # untouched by default. PRUNE_WINDOW_DAYS reads flake_registry.
  # prune_window_days (default 90 — generous; the registry is cheap to keep).
  PRUNE_WINDOW_DAYS=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get flake_registry.prune_window_days 2>/dev/null || echo 90)
  case "$PRUNE_WINDOW_DAYS" in ''|*[!0-9]*) PRUNE_WINDOW_DAYS=90 ;; esac
  # Re-derive the SHIPYARD_REPO_ROOT pin from the step-0.56 stash rather than
  # `git rev-parse --show-toplevel` (issue #1059) — the latter resolves to
  # the orchestrator worktree post-relocation, not the primary checkout
  # where the gitignored flake-suspects.txt persists across sessions.
  FLAKE_REPO_ROOT=$(cat "$ORCH_WT/.shipyard-primary-root" 2>/dev/null)
  [ -z "$FLAKE_REPO_ROOT" ] && FLAKE_REPO_ROOT="$(git rev-parse --show-toplevel)"
  "${CLAUDE_PLUGIN_ROOT}/scripts/flake-enforce.sh" enforce \
    --repo "<owner/repo>" \
    --repo-root "$FLAKE_REPO_ROOT" \
    --prune-window-days "$PRUNE_WINDOW_DAYS" \
    2>&1 | sed 's/^/[flake-enforce] /' || echo "[flake-enforce] advisory: enforce pass errored; continuing setup"
fi
```

**Read site: setup, once per session.** The issue's open question ("setup once per session vs. per-dispatch") resolves to **setup** — it's the cheapest site and the registry escalation state changes slowly (a flake crosses the threshold over days, not within a single session's dispatch cadence). The one piece of mid-session freshness that matters — a flake escalated by *this* session's own `fix-checks-only` recording — is still honored without a per-dispatch enforce pass, because the `stop-auto-rerunning` consumer (fix-checks-only's [pre-rerun suspects check](../../../agents/issue-worker/fix-checks-only.md#fix-loop)) re-reads `.shipyard/flake-suspects.txt` on every dispatch. So a flake that crosses mid-session is suppressed by the next fix-checks worker even though the issue-filing / PR-labeling actions ran only at setup. Per-dispatch enforcement of the issue-filing and labeling actions is a deliberate non-goal for this slice; see the issue's scope notes.

**Idempotence is load-bearing here.** `/do-work` re-runs setup every session. The enforce helper dedupes all three actions: `file-tracking-issue` skips when an OPEN issue already carries the flake's `flake-key=<...>` marker; `stop-auto-rerunning` skips a key already in the suspects file; `apply-blocked-ci` skips a PR already labeled `blocked:ci`. A session that finds no newly-crossed flakes (or only already-enforced ones) makes zero GitHub writes. The added prune call (#863) is separately idempotent — pruning to the same window twice in a row is a no-op rewrite the second time — and fire-and-forget: `flake-enforce.sh` logs a `prune advisory` line and continues into the rest of enforcement if the prune itself fails, so a housekeeping hiccup never blocks the escalation actions this step exists for.

This step is **independent of the parallelization batch** (it shells out to a local helper that itself calls `gh`, rather than being a single projectable `gh` query the orchestrator can co-fire). Run it after the failing-PR snapshots (steps 5 / 5.7) so the `blocked:ci` labels it applies are visible to any subsequent `-label:blocked:ci`-filtered query in the same session. It's also fine to defer to the first idle turn at C=1 alongside the other lazy-loaded snapshots — the escalation state isn't time-critical within a session.

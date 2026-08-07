---
description: Walk the human through everything that genuinely needs a person — decisions and judgment calls /do-work can't complete. Collects every open decision across all gated issues in one uninterrupted run, batch-records them, then walks the remaining action items one at a time until the human-only queue is empty. Interactive and human-facing; pairs with /shipyard:do-work as the human-driven counterpart.
argument-hint: [--repo owner/repo] [--all] [--limit N] [--chrome-prompt]
---

# /my-turn

Answer *"what do you need from me right now?"* by **getting you through the human-only backlog in one session** (issue [#635](https://github.com/mattsears18/shipyard/issues/635)) — **every open decision first, asked back-to-back with no work in between**, then one batched commit that records them all, then the remaining action items walked one at a time until the queue is empty (issue [#1070](https://github.com/mattsears18/shipyard/issues/1070)). The queue is deliberately narrow: **only items that genuinely require a human** — a decision, a judgment call, anything that **cannot** be completed by `/shipyard:do-work`. Code work and browser-completable operator actions (close a superseded PR, paste a CI secret, toggle a non-security console setting) belong to the operator layer, not here, and are filtered out (see [Human-only queue filter](#human-only-queue-filter)).

**`/my-turn` is a router, not an investigator** (issue [#1073](https://github.com/mattsears18/shipyard/issues/1073)). It answers *what needs you and where to look* — never *why something is broken*. Root-causing a failure (reading CI logs, drilling into a run's jobs, tracing a stack trace) is `/shipyard:do-work`'s work, not this command's, regardless of how high the item ranks — see [Performance budget → Per-item investigation ceiling](#performance-budget) for the concrete bound and [Don't](#dont) for the rule this promise cashes out to.

**Answering is decoupled from acting.** You should never sit waiting on Claude between two of your own answers — no comment gets posted, no label gets edited, and no codebase gets re-read mid-run. See [Walkthrough mode](#walkthrough-mode-default) for the three phases.

This is the **human counterpart** to the two autonomous loops — the three-command division of labor:

| Command | Role | Loops? |
|---|---|---|
| [`/shipyard:do-work`](./do-work.md) | Autonomous continuous loop — **code work only** | yes (autonomous) |
| [`/shipyard:do-work`](./do-work.md) (operator-inclusive by default) | The `/do-work` loop **plus** driving Chrome to complete browser-completable operator actions | yes (autonomous) |
| **`/my-turn`** (this command) | Surface **only** genuinely human-required items; collect every open decision in one run, batch-record them, then walk the remaining action items until the human-only queue is empty | yes (interactive, human-paced) |

**`/my-turn` stays human-facing and non-autonomous.** It dispatches no *mutating* agents and shares none of `/do-work`'s worker/execution machinery — the autonomous loop is `/do-work`'s job, and `/my-turn` is the deliberately separate human-paced counterpart. (Its one concurrency carve-out is [Phase 1](#phase-1--collect-no-mutation-no-work)'s **read-only** bulk context pass, which may fan out readers to prepare the questions; see [Don't](#dont).) The only state it mutates is what the human directs by answering: for a [decision-gated issue](#decision-gated-walkthrough) it reuses the mutating sibling [`/shipyard:resolve-decisions`](./resolve-decisions.md)' interactive walkthrough (restate → options → recommendation → record the answers + clear the gate, per [#566](https://github.com/mattsears18/shipyard/issues/566)) — with the record step [deferred](./resolve-decisions.md#firing-mode--immediate-default-vs-deferred-batch-caller) to a single batched commit. Everything else is surfaced for the human to act on; the command advances when *they* finish an item, not when an agent does.

Pass `--chrome-prompt` to switch into **chrome-prompt mode**: the entire visible output is a single copy-paste-ready prompt block for the [Claude for Chrome browser extension](https://chrome.google.com/webstore/detail/claude-for-chrome), with unmistakable copy dividers and nothing else above or below it (no walkthrough prompts, no ranked list). The user highlights the block, pastes it into the extension, and the extension acts. This is text-emission only — no MCP, no Claude Code execution; the deliverable is the prompt itself. (Distinct from `/do-work`, which drives Chrome directly.)

Pairs with [`/shipyard:do-work`](./do-work.md) — that one is the agent-driven loop (Claude works the backlog autonomously); this one is the human-driven counterpart (the user works through what the loops *couldn't* resolve). For the autonomous loop that ALSO drives browser-completable operator actions, see [`/shipyard:do-work`](./do-work.md) (operator-inclusive by default; explicitly `/do-work`).

**Bucket ownership.** `/do-work` and `/my-turn` are meant to jointly partition the backlog with no gap and no overlap. [`do-work/setup/backlog-ownership.md`](./do-work/setup/backlog-ownership.md) is the canonical bucket→owner table both commands are checked against — this file's [survey passes](#survey-passes) and [Human-only queue filter](#human-only-queue-filter) implement `/my-turn`'s slice of it (issue [#1076](https://github.com/mattsears18/shipyard/issues/1076)).

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional, default: cwd's repo via `gh repo view --json nameWithOwner -q .nameWithOwner`). If not in a repo, ask via `AskUserQuestion`.
- **--all** (optional, default off): render the **full ranked list** as a static, non-interactive snapshot instead of walking the queue. Without this flag (and without an explicit `--limit N > 1`), the command runs the **interactive advancing walkthrough** — it walks you through the human-only queue one item at a time, advancing until it's empty (see [Walkthrough mode](#walkthrough-mode-default)). Use `--all` when you want to *see* the whole human-blocked backlog at a glance without being walked through it. In `--chrome-prompt` mode, mirrors this same single-vs-all behavior: without `--all`, the prompt covers only the #1 action; with `--all`, the prompt covers all human-blocked actions batched into a single extension prompt.
- **--limit N** (optional, default `25` *when the list renders*): cap the printed list at N items. Only meaningful in list mode — i.e. when `--all` is passed, or when `--limit N` is given with `N > 1` (which itself opts into list-snapshot mode). `--limit 1` surfaces only the top-ranked item as a one-shot snapshot (no advancing walkthrough). Items beyond the cap are summarized as `… and <K> more (rerun with --limit <K+N> to see all)`. In `--chrome-prompt` mode, `--limit` caps the number of actions included in the batched prompt when combined with `--all`.
- **--chrome-prompt** (optional, default off): switch into **chrome-prompt mode** — the entire visible output is a single copy-paste-ready prompt block suitable for the Claude for Chrome browser extension. The output is prompt-only: no walkthrough, no ranked list, no preamble. The copy region is marked with unmistakable dividers. After the prompt block, a clearly-separated section lists anything that cannot be done by the extension or by Claude (manual/external steps, things needing maintainer auth, judgment calls the user must make personally); this section is omitted entirely when empty. See [Chrome-prompt mode](#chrome-prompt-mode---chrome-prompt) for the full render spec. **Composes with `--all`**: without `--all`, the prompt is built from the #1-ranked action only; with `--all`, all human-blocked actions are batched into one prompt.

**Mode resolution.** The command runs in one of three modes:

- **Walkthrough mode (default)** — no `--all`, no `--limit N` with `N > 1`, and no `--chrome-prompt`. Run the three phases (see [Walkthrough mode](#walkthrough-mode-default)): **collect** every decision across all decision-gated issues with no mutation in between, **commit** them in one batch, then **walk** the remaining action items one at a time until the queue is empty. This is the default because the command's promise is to *get you through* the human-only backlog, not just print it — and because answering N decisions shouldn't cost N round-trips of waiting.
- **List-snapshot mode** — `--all` is present, OR `--limit N` is given with `N > 1`, AND `--chrome-prompt` is NOT present. Print the full ranked list as a static snapshot (capped at `--limit`, default `25`), no walkthrough. `--all` with no `--limit` shows every item. Use this to *eyeball* the human-blocked backlog without being walked through it.
- **Chrome-prompt mode** — `--chrome-prompt` is present. The entire output is a single copy-paste-ready prompt block (see [Chrome-prompt mode](#chrome-prompt-mode---chrome-prompt)). `--all` and `--limit` still govern how many actions are included in the prompt, but the outer render is always prompt-only.

`--all` and `--limit` compose within list-snapshot and chrome-prompt modes: `--chrome-prompt --all --limit 10` builds a batched chrome-prompt covering the top 10 human-blocked actions. In `--limit 1` snapshot mode and chrome-prompt-without-`--all` mode, `--limit` has no effect (only one item is surfaced).

## Setup

### 1. Resolve repo

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # if --repo omitted
```

### 2. Resolve the authenticated user

The "me" in "what do you need from me right now?" is whoever the local `gh` is authenticated as — the survey ranks items by *that user's* relationship to each PR/issue (requested reviewer, assignee, mentioned in comment, etc.). Resolve once at setup:

```bash
gh api user --jq .login   # → $ME
```

If `gh` is not authenticated, abort with a clear error directing the user to `gh auth login`.

### 3. Resolve the `needs-triage` human-ownership config gate ([#1077](https://github.com/mattsears18/shipyard/issues/1077))

`needs-triage` is `/shipyard:do-work`'s by default — a trusted-author issue carrying it is routed to `investigate_candidates` and dispatched via investigate mode, so under the default config there is nothing for `/my-turn` to surface (see [`backlog-ownership.md` bucket 5](./do-work/setup/backlog-ownership.md#ownership-table)). `triage.investigate_dispatch: false` is the **one** configuration under which the label becomes genuinely human-owned (the pre-#556 skip-and-surface behavior). Resolve it once at setup so Pass B's `needs-triage` signal below knows whether to fire:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
investigate_dispatch=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get triage.investigate_dispatch 2>/dev/null || echo "true")
```

### 4. Resolve the stale-undispatched-issue threshold ([#1078](https://github.com/mattsears18/shipyard/issues/1078))

Pass B's "authored by `$ME`, never dispatched" signal (below) gates on an age threshold so a freshly-filed issue that simply hasn't had its turn isn't misread as a misconfiguration. Resolve it once at setup — the `CLAUDE_PLUGIN_ROOT` export is repeated here rather than assumed carried over from step 3, since shell variables don't survive across separate tool calls:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
stale_undispatched_days=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get my_turn.stale_undispatched_days 2>/dev/null)
[[ "$stale_undispatched_days" =~ ^[0-9]+$ ]] || stale_undispatched_days=7
```

### 5. Resolve the per-item investigation-depth ceiling ([#1073](https://github.com/mattsears18/shipyard/issues/1073))

[Phase 3](#phase-3--walk-the-rest)'s per-item action derivation is capped at a small, fixed number of tool calls beyond the survey projection (see [Performance budget → Per-item investigation ceiling](#performance-budget)) so ranking an item highly is never license to root-cause it. Resolve the ceiling once at setup — the `CLAUDE_PLUGIN_ROOT` export is repeated here rather than assumed carried over from step 4, since shell variables don't survive across separate tool calls:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
max_diagnostic_reads_per_item=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get my_turn.max_diagnostic_reads_per_item 2>/dev/null)
[[ "$max_diagnostic_reads_per_item" =~ ^[0-9]+$ ]] || max_diagnostic_reads_per_item=1
```

Default `1` — at most one extra read beyond the survey projection per item (e.g. a single `gh pr view` on the item's own number for a field Pass A's list projection omitted). `0` disables the extra read entirely — the rendered action must come from the survey projection alone, or the item renders in its [degraded form](#performance-budget). Raising it is an explicit per-repo opt-in to deeper per-item grounding; it never licenses reading CI logs, drilling into a run's jobs, or otherwise establishing *root cause* — the [Don't diagnose](#dont) rule is unconditional regardless of this value.

## Survey passes

Run each of the following passes in parallel (one batch of `gh` calls in a single message). Each pass produces a list of candidate items; the final ranking step merges them.

### Pass A — Open PRs

```bash
gh pr list --repo <owner/repo> --state open --limit 200 \
  --json number,title,url,isDraft,author,createdAt,updatedAt,labels,reviewDecision,reviewRequests,mergeStateStatus,statusCheckRollup,headRefName
```

From this projection, derive per-PR signals:

- **PR awaiting `$ME`'s review** — `reviewRequests` contains `$ME` (direct) OR `$ME` is on a team in `reviewRequests` (skip the team-lookup for v1; direct match only). `reviewDecision` is `REVIEW_REQUIRED`. Highest-leverage human action — `$ME` is literally what's blocking merge.
- **PR with `blocked:ci` label** — the orchestrator's 3-attempt fix-loop ran out; needs manual investigation.
- **PR with `mergeStateStatus: DIRTY`** that has been DIRTY for `>24h` — rebase didn't auto-fire, or auto-merge isn't armed.
- **Draft PR last updated >7 days ago** — stale; either finish or close.
- **PR with `CHANGES_REQUESTED` `reviewDecision` authored by `$ME`** — the user submitted a PR that someone (human or bot) asked for changes on; the ball is back on their court.

### Pass B — Open issues

```bash
gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,url,author,assignees,createdAt,updatedAt,labels,comments \
  --jq '[.[] | . + {comments: (.comments | map({author: .author.login, body: (.body[:280]), createdAt}) | .[-3:])}]'
```

The `comments` projection keeps only the last 3 comments on each issue, and each comment is trimmed to its first 280 chars + author login + createdAt. The Pass B signals only inspect the most-recent comment author (`@<$ME>` ping detection) and the first chunk of its body (substring match for `?` and the mention shape) — keeping the full comment history per issue (or full bodies) burns tool-result tokens for fields nothing reads. Worker-preamble §"`gh` JSON discipline" covers the convention.

From this projection, derive per-issue signals:

- **Issue with `needs-human-review` label** — `/shipyard:do-work` is skipping it until a human signs off. Two canonical cases now share this label: (1) refined user-feedback issues awaiting maintainer approval, and (2) **design-gated issues** blocked on a human design decision before they're agent-workable. `/shipyard:do-work` deliberately **excludes** `needs-human-review` from dispatch (see the client-side filter in [`do-work/setup.md`](./do-work/setup.md) step 4, [`do-work/drain.md`](./do-work/drain.md), and [`do-work/steady-state.md`](./do-work/steady-state.md)), so without a `/my-turn` signal a human-gated issue is invisible to both loops and stacks up in the backlog with no path to a human — exactly what `/my-turn` exists to surface. The reviewer **is the user** (or, more precisely: a maintainer; the survey assumes `$ME` is one). For a design-gated issue the human action is to make the design call (or break the issue into a design spike + an implementation issue so the impl half becomes dispatch-eligible). (Design-gate provenance — formerly the `needs-design` label — in [RATIONALE → Label-lifecycle provenance](./do-work-RATIONALE.md#needs-design--needs-human-review-issue-515-binary-backlog-phase-1).)
- **Issue with `needs-human-review` + a `<!-- do-work-untrusted-author-review -->` comment — external-author trust review** ([#1079](https://github.com/mattsears18/shipyard/issues/1079)). A third `needs-human-review` case, distinct from the refined-feedback and design-gate ones above: `/shipyard:do-work`'s bucket-0.5 security gate (`author.login` NOT in `trusted_authors`) drops the issue from dispatch — that gate is unchanged and never relaxes here — and the label is purely the surfacing side effect, applied once per issue by [`04`'s bucket-0.5 handoff](./do-work/setup/04-backlog-divert.md#4-fetch--rank-the-backlog). The sentinel comment is what distinguishes this case from the other two `needs-human-review` populations, and it already states the concrete action: render it directly rather than re-deriving it. The human decision is one of three: **vouch** (add the author to `.shipyard/trusted-authors.txt`, or re-file the issue under a trusted account — both documented in the sentinel comment), **triage without vouching** (work it by hand, outside `/do-work`), or **close** (spam / out of scope). This is the category the [Human-only queue filter](#human-only-queue-filter) already listed by name — "external-author trust review" — before this fix populated it.
- **Issue with the `agent-console` label** ([#608](https://github.com/mattsears18/shipyard/issues/608), renamed from `needs-operator` in [#995](https://github.com/mattsears18/shipyard/issues/995) — **treat an issue still carrying the legacy `needs-operator` name identically**, since it's the same gate under its pre-rename label object until the repo migrates it) — blocked on a **browser/console operator action**, not a decision: paste a CI secret, flip a provider-console toggle, close a superseded PR, or another action completable by manipulating a browser. **This is `/do-work`'s job, not `/my-turn`'s** ([#635](https://github.com/mattsears18/shipyard/issues/635)). The operator can be **a human OR Claude**, and `/shipyard:do-work` (operator-inclusive by default) drives these in the user's real Chrome via the extension — so under the three-command division of labor an `agent-console` item is **excluded from `/my-turn`'s human-only walkthrough queue** (see [Human-only queue filter](#human-only-queue-filter)). `/my-turn` does NOT walk these items; at most it surfaces a single one-line pointer (`<N> browser-completable operator action<s> — run /shipyard:do-work to have Claude complete them`) so the user knows they exist and which command drains them. Distinguish from `needs-human-review` (a genuine human *decision*, which Claude can't make and which `/my-turn` DOES walk) — `agent-console` is a mechanical action the operator layer can perform, so it doesn't belong in the human-only queue.
- **Issue with `needs-triage` label, only when `$investigate_dispatch == "false"`** ([#1077](https://github.com/mattsears18/shipyard/issues/1077)) — under the default (`triage.investigate_dispatch: true`, resolved once in [Setup step 3](#3-resolve-the-needs-triage-human-ownership-config-gate-1077)), `/shipyard:do-work` routes a trusted-author `needs-triage` issue to `investigate_candidates` and dispatches it via investigate mode itself, so there is nothing for a human to do here and this signal correctly stays silent (see [`backlog-ownership.md` bucket 5](./do-work/setup/backlog-ownership.md#ownership-table)). When `investigate_dispatch` is `false`, `/shipyard:do-work` drops `needs-triage` issues outright instead of routing them — the pre-#556 skip-and-surface behavior — so the label has no other consumer and becomes genuinely human-owned. The human action is a single decision: set a priority + type label and remove `needs-triage` (or close as out of scope, or leave it gated pending more thought).
- **Issue with the legacy `needs-refinement` label** (stale — the label was eliminated; `/shipyard:refine-issues` no longer applies or reads it, detecting candidates by source-signal scan instead — provenance in [RATIONALE → Label-lifecycle provenance](./do-work-RATIONALE.md#needs-refinement-eliminated-issue-520)). If any open issue still carries `needs-refinement`, it's a leftover from before the migration — surface it so the user can remove the label (the GitHub label object was intentionally left for manual cleanup). The issue's actual refinement, if needed, now happens automatically via the signal scan; the stale label is purely a housekeeping nudge.
- **Issue with `needs-human-review` + the `<!-- do-work-needs-decomposition -->` body marker** — a `/do-work` scope agent confirmed the epic is non-shippable as a single PR. (Epic-handoff provenance — formerly the dedicated `needs-decomposition` label, re-keyed onto `needs-human-review` + this marker — in [RATIONALE → Label-lifecycle provenance](./do-work-RATIONALE.md#needs-decomposition--tracking--needs-human-review--body-marker-issue-519).) (The marker is what distinguishes an epic-decomposition handoff from every *other* `needs-human-review` issue — refined user-feedback, external-author, design-gated — which surface via the generic `needs-human-review` bucket above; render this one as the more-specific "epic awaiting decomposition" action when the marker is present.) If there's **no** `<!-- do-work-decompose-agent -->` idempotency sentinel in any comment, `/shipyard:decompose-epic` hasn't been run yet — the user can run it to auto-shard the epic into dispatch-ready sub-issues (for `Multi-PR sequence:` / `Missing dependency:` evidence classes). If a sentinel comment **is** present and reads `couldn't auto-decompose:`, the epic is a genuine human-decomposition handoff (non-mechanical evidence class, or too big to shard cleanly) — the user decomposes it by hand. Either way the epic is blocked on the user, not on Claude.
- **Agent refuses surface via the `needs-human-review` bucket above.** A worker that hard-bails for a pure security / scope / prompt-injection *refuse* (no open `Blocked by #<M>` reference) carries `needs-human-review`, so the "Claude gave up; a human must actually look" signal is already covered by the `needs-human-review` signal above — it doesn't need its own bucket. The bail comment (`steady-state.md`'s bail handler writes a `Worker returned blocked: <reason>. Classified as needs-human-review` comment) records *why*, so cite it in the rendered action when the issue's `needs-human-review` arrived via an agent refuse rather than the refinement / external-author / design-gate paths. A **dependency-wait** (body has ≥1 `Blocked by #<M>` reference) carries no label at all — the `Blocked by #<M>` body-reference filter auto-clears it the instant the blocker closes (it becomes a plain workable issue with no human action needed), so there is nothing for `/my-turn` to surface. (Provenance — the former `blocked:agent-hard` label and clearable-hard-block signal, both eliminated — in [RATIONALE → Label-lifecycle provenance](./do-work-RATIONALE.md#agent-refuses-surface-via-needs-human-review-dependency-waits-carry-no-label-issue-521).)
- **Issue with `needs-human-review` + the `<!-- do-work-classifier-undispatchable -->` body marker** ([#953](https://github.com/mattsears18/shipyard/issues/953)) — categorically different from the agent-refuse bucket immediately above, even though both carry `needs-human-review`: here **no worker ever ran**. The Claude Code harness's own auto-mode permission classifier refused the orchestrator's dispatch call outright, on both permitted attempts ([#718](https://github.com/mattsears18/shipyard/issues/718)'s one-corrective-re-dispatch-then-stop contract), so there is no implementation attempt, no code read, and no worker bail reasoning to review — only the fact that dispatch itself was refused. Render this distinctly from an agent-refuse ("a worker tried and gave up because <reason>"): the action here is "either do this work by hand, or make a permission-policy call that would let the classifier allow it" — there is no bail reasoning to summarize because none exists. Do not conflate this with the ordinary `needs-human-review` bucket above by citing a nonexistent worker rationale.
- **Issue authored by `$ME`, no linked PR, no `needs-human-review` label, no `shipyard` label, NOT self-assigned to `$ME`, and `createdAt` older than `$stale_undispatched_days` days** ([#1078](https://github.com/mattsears18/shipyard/issues/1078)) — the precise "`/do-work` never claimed this" signal, not merely "no PR yet." The old predicate (authored-by-`$ME` + no-linked-PR + no `needs-human-review`, with nothing else) is a **tautology on a solo-maintainer repo**: it's true of every workable issue `/do-work` simply hasn't reached yet, which is the normal steady state of a healthy backlog — a live measurement against a real repo found it would have surfaced the *entire* undispatched backlog, including issues a concurrent `/do-work` session was actively working at that exact moment. `/do-work` stamps the `shipyard` session-stamp label and self-assigns `@me` (the soft lock — see [`inline-trivial.md`](./do-work/inline-trivial.md) § "the `shipyard` label is the session stamp") on **every** issue it dispatches, before implementation begins — so the ABSENCE of *both* is the actual "`/do-work` never touched this" evidence, not the absence of a linked PR alone (which is equally true of an issue sitting in the dispatch queue mid-session, or one two minutes old). The age threshold is what keeps a just-filed issue from false-positiving before `/do-work` has had a chance to reach it. Implementation: `assignees` does NOT contain `$ME` AND `labels` does NOT contain `shipyard` AND `labels` does NOT contain `needs-human-review` AND `createdAt` is more than `$stale_undispatched_days` days in the past (config `my_turn.stale_undispatched_days`, default 7, resolved once at [Setup step 4](#4-resolve-the-stale-undispatched-issue-threshold-1078)). All four fields already ride the Pass B projection above — no added `gh` call. (`blocked:agent-soft` issues already carry the `shipyard` label from the worker that bailed on them, so the label conjunct alone excludes them — they auto-clear at next-session backlog fetch and don't need user triage. A dependency-wait carries no `shipyard` label either and auto-clears the instant its blocker closes; if one sits past the age threshold, it's because its blocker has been open that long too — a legitimate housekeeping nudge to check the blocker, not a misfire of this signal.)
- **Issue assigned to someone other than `$ME`, with `updatedAt` >30 days old** ([#1076](https://github.com/mattsears18/shipyard/issues/1076)) — `/shipyard:do-work` intentionally skips any issue assigned to another user (see [`backlog-ownership.md` bucket 1](./do-work/setup/backlog-ownership.md#ownership-table)), so on a solo-maintainer repo a stale assignment was reaching nobody before this signal existed. Implementation: `assignees` is non-empty, does NOT contain `$ME`, and `updatedAt` is more than 30 days in the past — the assignee has gone quiet. The action is to reassign to `$ME`, unassign so `/shipyard:do-work` can pick it up, or ping the assignee. An issue assigned to another user that's still fresh (`updatedAt` ≤30d) is NOT surfaced — the assignee may simply be actively working it.
- **Issue where the last comment was authored by someone other than `$ME` AND the comment text contains `?` or `@<$ME>`** — someone asked a question or pinged the user; awaiting response. Implementation: walk `comments` newest-first, find the last non-`$ME` comment, check for `?` substring or `@<login>` mention of `$ME`.

### Pass C — Unanswered review comments on `$ME`'s PRs

Open PRs authored by `$ME` may have review comments awaiting reply. `gh pr list` doesn't return review-comment threads; use a per-PR follow-up only for PRs that aren't already surfaced in Pass A's higher-priority buckets, capped at the 20 most-recently-updated. For each:

```bash
gh api repos/<owner/repo>/pulls/<M>/comments --jq '.[] | {id, user: .user.login, body, created_at, in_reply_to_id}'
```

Surface the PR if there's an unresolved review comment thread where the last comment is from a non-`$ME` author. (v1 heuristic — GitHub's API doesn't expose the `resolved` flag on classic review comments; "last commenter not `$ME`" is a reasonable proxy.)

## Human-only queue filter

After the passes collect candidates and **before** ranking, drop everything that isn't genuinely blocked on a *human* — anything `/shipyard:do-work` can complete on its own ([#635](https://github.com/mattsears18/shipyard/issues/635)). This is the filter that makes `/my-turn`'s queue mean *"only what needs you, the person"* rather than *"everything not yet done."* Under the three-command division of labor:

- **`/do-work` owns code work** — issues an autonomous code worker can implement. These never enter `/my-turn`'s queue in the first place (a workable, ungated issue is `/do-work`'s; the passes above already only collect human-blocked signals), and the [Don't](#dont) rules keep them out.
- **`/do-work` owns browser-completable operator actions** — `agent-console` items, and any item whose next step is a mechanical browser/console action Claude can drive in the user's real Chrome (close a superseded PR, paste a CI secret, toggle a non-security console setting, post an unambiguous reply). **Exclude these from the walkthrough queue.** They are surfaced — if any exist — only as a single one-line pointer (see [the operator pointer](#operator-pointer-line) in Output), never walked.
- **`/do-work` owns CI recovery on the default branch** — a dedicated `fix-main-ci` worker mode exists exactly for red main / failing CI with no fix-main-ci PR open. That's `/do-work`'s condition to catch on its own; it never enters `/my-turn`'s queue.
- **`/my-turn` owns genuine human-required items** — and *only* these survive into the ranked queue: a `needs-human-review` decision/judgment call (design call, product/schema decision, epic-decomposition handoff a human must do by hand, an agent-refuse a human must adjudicate, external-author trust review), a `needs-triage` issue **only when `triage.investigate_dispatch: false`** (under the default it's `/do-work`'s, dispatched via investigate mode — see the Pass B bucket above and [#1077](https://github.com/mattsears18/shipyard/issues/1077)), a PR awaiting `$ME`'s review, an unanswered question / `@$ME` ping, a `blocked:ci` PR needing human eyes, and the housekeeping signals (stale draft, DIRTY PR, `CHANGES_REQUESTED`, stale assigned-to-other issues, stale never-claimed-by-`/do-work` own-authored issues). These are the things no automation can finish for the user.

**The discriminator is "can `/do-work` complete it without a human decision?"** If yes → it's the operator layer's, filtered out (pointer only). If it needs a person to *decide* or *judge* something no automation can — it stays. A `needs-human-review` item that is *also* a security/access-control console toggle (which the operator layer hands back rather than drives, per [#626](https://github.com/mattsears18/shipyard/issues/626)) still needs the human, so it stays in the queue.

The remaining (human-only) candidates are what the [Ranking](#ranking) step orders and the [Walkthrough](#walkthrough-mode-default) consumes.

## Ranking

Merge the human-only candidates (those surviving the [Human-only queue filter](#human-only-queue-filter)) into a single ranked list. Each item carries a priority tier and, within its tier, a **leverage score** (highest-leverage first) with `createdAt` ascending (oldest first) as the final tie-breaker — see [Secondary sort](#secondary-sort--leverage-score-then-age-issue-565). The leverage score, not raw age, is what determines the order the [walkthrough](#walkthrough-mode-default) advances through — and which item leads (issue [#565](https://github.com/mattsears18/shipyard/issues/565)).

### Priority tiers

Ranking runs over the **human-only candidates that survive the [Human-only queue filter](#human-only-queue-filter)** — `agent-console` / browser-completable items are already filtered out (they're `/do-work`'s, surfaced only via the [operator pointer](#operator-pointer-line)), so they do NOT appear in any tier below.

- **P0 — blocking other work**
  - PRs awaiting `$ME`'s review (any age) — `$ME` is literally what's stopping merge
  - Issues with `needs-human-review` label — `/shipyard:do-work` is skipping them (this now includes design-gated issues — see the Pass B bucket above)
  - Issues with `needs-triage`, only when `triage.investigate_dispatch: false` ([#1077](https://github.com/mattsears18/shipyard/issues/1077)) — same "blocked on a human, `/do-work` won't touch it" shape as `needs-human-review` above (see the Pass B bucket above); absent under the default config

- **P1 — decisions**
  - PRs with `blocked:ci` (3-attempt orchestrator fix-loop exhausted, needs human eyes)
  - (Agent refuses carry `needs-human-review` and surface under the **P0** `needs-human-review` bucket above; cite the worker's bail comment in the rendered action so the refuse reason is visible. See the Pass B agent-refuses bucket above for provenance.)
  - Issues still carrying the legacy `needs-refinement` label (stale — eliminated; remove the label — see the Pass B bucket above)
  - Issues with `needs-human-review` + the `<!-- do-work-needs-decomposition -->` body marker (a scope agent confirmed the epic is non-shippable as a single PR — run `/shipyard:decompose-epic` to auto-shard the mechanical cases, or decompose by hand if a `couldn't auto-decompose:` sentinel comment is already present; see the Pass B bucket above)
  - Open review comment threads on `$ME`'s PRs awaiting reply
  - Issues where the last comment was a question or `@$ME` mention from someone else

- **P2 — housekeeping**
  - PRs with `mergeStateStatus: DIRTY` >24h (rebase didn't auto-fire)
  - Draft PRs stale >7 days (finish or close)
  - (A dependency-wait carries no label and auto-clears via the `Blocked by #<M>` body-reference filter when its blocker closes, so there's no leftover label for a human to remove — see the Pass B agent-refuses bucket above for provenance.)
  - `CHANGES_REQUESTED` on `$ME`'s open PRs (the user owes the reviewer a response)
  - Issues assigned to someone other than `$ME`, stale >30 days (see the Pass B bucket above — [#1076](https://github.com/mattsears18/shipyard/issues/1076))
  - Issues authored by `$ME`, never claimed by `/do-work`, stale >`$stale_undispatched_days` days ([#1078](https://github.com/mattsears18/shipyard/issues/1078)) — a "check your labels" nudge, not a blocking decision (see the Pass B bucket above)

### Secondary sort — leverage score, then age (issue [#565](https://github.com/mattsears18/shipyard/issues/565))

Within each tier, sort by a **leverage score descending** (highest-leverage first), and break ties by `createdAt` ascending (oldest first). **Leverage is the primary within-tier key; age is only the tie-breaker.** This is the fix for [#565](https://github.com/mattsears18/shipyard/issues/565): the old flat `createdAt`-ascending secondary sort made the *stalest* item the head of the queue, which on a P0 tier dominated by long-lived `needs-human-review` issues regularly surfaced an auto-undecomposable epic — the *least* actionable item — first, directly contradicting the command's "highest-leverage thing blocked on you" promise. Oldest-first is a reasonable *tie-breaker*, but it is not a *leverage* signal, and the order the secondary sort produces is the order the [walkthrough](#walkthrough-mode-default) advances through (and the one item a `--limit 1` snapshot renders).

**The leverage score is derived entirely from signals the survey passes A–C already collect** — no new `gh` calls, no new round-trips. Higher score = higher leverage = a human action that unblocks the most downstream work for the least effort. Note the operator-console class (paste a CI secret, flip a provider toggle) is no longer scored here at all — it's filtered out by the [Human-only queue filter](#human-only-queue-filter) as `/do-work`'s work. Rank within a tier by this order (4 = highest leverage, 1 = lowest):

1. **Score 4 — pure-decision item.** The human action is a single decision that flips the item to dispatch-eligible / mergeable: a `needs-human-review` issue whose body enumerates product / schema / design questions with **no** external-console, on-device, or external-dependency requirement; an external-author trust-review issue (the `<!-- do-work-untrusted-author-review -->` sentinel — the decision is vouch / triage-by-hand / close, a single templated call, per [#1079](https://github.com/mattsears18/shipyard/issues/1079)); a `needs-triage` issue (only when `triage.investigate_dispatch: false`) needing just a priority + type label to become dispatch-eligible; a PR awaiting `$ME`'s review; an issue where the last comment is a direct question or `@$ME` ping awaiting a one-line answer. One human call converts the item to workable-by-`/do-work` (or merges it) — the highest leverage per unit of effort, so these float to the top of their tier.
2. **Score 3 — quick human action.** A bounded, fast human step that isn't a pure decision but that no automation can take for the user: reply to a review comment thread with a substantive answer, make a small judgment call documented inline, delete a stale branch or flip a GitHub setting that the operator layer was unable to drive (e.g. a security/access-control toggle the operator layer hands back per [#626](https://github.com/mattsears18/shipyard/issues/626)). Bounded and unblocking, slightly slower than a one-line decision. (Pure mechanical operator-console actions are NOT here — they're the operator layer's and filtered out.)
3. **Score 2 — on-device / multi-party verification.** The action needs a device, a build, or coordination with another party (run a build through TestFlight, verify an on-device flow, get a second person to confirm). Higher effort and higher latency.
4. **Score 1 — auto-undecomposable epic / parking-lot umbrella.** A `needs-human-review` issue carrying the `<!-- do-work-needs-decomposition -->` body marker **and** a `couldn't auto-decompose:` sentinel comment (`/decompose-epic` already determined it can't be mechanically sharded). A by-hand decomposition is *real work*, not a "next step" — these are low-leverage **as a single human action** by definition, so they **sink** to the bottom of their tier rather than floating to the top on age alone. This is the exact item the [#565](https://github.com/mattsears18/shipyard/issues/565) repro surfaced as a false first item (the 4-week-stale `epic(aso)` #540).

Items that match none of the above (e.g. a stale draft PR, a `CHANGES_REQUESTED` PR, a `mergeStateStatus: DIRTY` PR) take a **neutral middle score (2)** so the leverage ordering only *re-orders* the clear high/low-leverage cases and otherwise falls back to the age tie-breaker — it never invents urgency for a housekeeping item. The score is a within-tier ordering signal only; it never moves an item across tiers (a P2 pure-decision item does not outrank a P0 epic).

**Worked example (the [#565](https://github.com/mattsears18/shipyard/issues/565) repro).** A P0 tier with 19 `needs-human-review` issues: under the old oldest-first sort, the 4-week-stale auto-undecomposable `epic(aso)` #540 ranked #1 and was walked first. Under leverage-then-age, #540 scores 1 (auto-undecomposable epic) and sinks; a pure-decision issue like "feature blocked on 7 product/schema decisions the user can answer in minutes" scores 4 and floats to the top of P0 — so the walkthrough starts with the genuinely highest-leverage human action, restoring the headline promise.

Surface a single age string per item regardless of leverage score — `<N>d` for ≥1 day, `<N>h` for ≥1 hour, else `<N>m`.

### Dedup

An item may match multiple signals (e.g. a PR is both `blocked:ci` AND DIRTY); collapse to a single rendered row, keep the highest-priority signal, list the secondary signals in the "why" column.

### Release-please / version-bump PRs (discretionary)

A release-please / version-bump PR is a **manual gate, not a blocker.** The commits it releases are already on the default branch; the PR only bumps version + changelog, and nothing downstream cascades from it — it doesn't block other PRs, CI, or development, and release-please keeps rolling more commits into it while it sits open. Recognize one by the same heuristic `/shipyard:do-work` uses for its auto-merge exception: a `chore(release):` title prefix **or** a `release-please--*` head branch.

Such a PR is **discretionary housekeeping** — rank it at the **bottom of P2**, never P0/P1, regardless of which Pass-A signal it matched. A CLEAN release PR is "ready to ship whenever you want," not "blocked on you," so promoting it conflates *highest-ranked human-only item* with *blocking other work* — the exact false-urgency this de-prioritization prevents.

**Exception — promote only on a concrete downstream dependency.** If another open item explicitly waits on the release shipping — it carries `Blocked by #<release-PR>` in its body, or otherwise references the version going live — the release PR is genuinely gating tracked work and MAY rank up to the tier of the work it unblocks. Absent such an edge, it stays discretionary.

## Output

Print to the terminal. **No file artifact** — the walkthrough is interactive and ephemeral; the user acts on each item as it surfaces. The output format is intentionally terse: the user asked for "what do I need to do" — not "what's the state of the repo." Cut the framing, lead with the verb.

The render depends on the resolved mode (see [Args → Mode resolution](#args)):

### Walkthrough mode (default)

When neither `--all` nor `--limit N > 1` is given, **get the human through the entire human-only queue in one session** ([#635](https://github.com/mattsears18/shipyard/issues/635)) — but in three phases, not one interleaved loop ([#1070](https://github.com/mattsears18/shipyard/issues/1070)). Every **question** is asked first, back-to-back; every **mutation** fires afterward in one batch; the items that need the human to *do* something rather than *decide* something are walked last.

**Why the split.** The command's promise is to *get you through* the human-only backlog. The pre-[#1070](https://github.com/mattsears18/shipyard/issues/1070) loop honored that but paid for it in latency: after the maintainer answered the last decision on one issue, the flow posted a comment and edited labels — GitHub round-trips — *before* the next issue's first question rendered, and it re-grounded each recommendation in fresh codebase reads at ask-time. The maintainer's own framing:

> I would prefer that the my-turn command simply collect any input that it needs from me — FOR ALL ISSUES — and then get to work. that way I don't have to sit and wait for the work to be implemented before moving on to the next thing that needs my input.

So: **collect every answer with nothing in between, then act.**

#### Phase 1 — Collect (no mutation, no work)

**Partition the ranked human-only queue** into two disjoint sets:

- **Decision-gated items** — leverage-score-4 pure-decision `needs-human-review` issues with answerable enumerated decisions (see [Decision-gated walkthrough](#decision-gated-walkthrough) for the exact trigger surface). These are Phase 1's.
- **Everything else** — PRs awaiting review, unanswered questions, `blocked:ci`, epic-decomposition handoffs, housekeeping. These are **set aside untouched** for [Phase 3](#phase-3--walk-the-rest).

Then, **before asking anything**, run **one bulk context pass** that gathers everything the whole collect run will need: every decision-gated issue's body and comment thread, and the codebase grounding behind *all* the recommendations. Doing this once up front — rather than per-decision at ask-time — is what removes the wait between questions. This pass **may fan out parallel read-only research agents** (see the narrowed no-agent rule in [Don't](#dont)); it performs no mutation of any kind.

Then ask. **Rules for the collect run:**

- **No GitHub mutation fires during Phase 1.** No `gh issue comment`, no `gh issue edit`, no label change, no reply posted. The reused `/shipyard:resolve-decisions` walkthrough runs in its [deferred firing mode](./resolve-decisions.md#firing-mode--immediate-default-vs-deferred-batch-caller) — it yields the decision set as a value instead of recording it.
- **Group independent decisions; ask dependent ones singly.** Batch up to 4 **mutually independent** decisions into a single `AskUserQuestion` call. A decision whose options depend on an earlier answer — the carry-forward edge that [`resolve-decisions.md` part 4](./resolve-decisions.md#the-per-decision-walkthrough) makes load-bearing — is asked **alone, in source order**, with the locked answers echoed forward as constraints. Batching removes the *work* between questions, never the *sequencing* carry-forward needs.
- **Order by issue, issues by rank.** Walk issue-by-issue in the existing [ranked](#ranking) order so related decisions stay adjacent and the maintainer isn't context-switched between unrelated features mid-run.
- **Journal every answer immediately.** Append each answer to `~/.shipyard/my-turn-<repo-slug>.json` the moment it's given — a local file write, not a network call, so it costs no perceptible latency. This is the crash-safety boundary: a session that dies mid-collect has lost nothing, and a re-invocation detects the journal and offers to **resume** (continue collecting) or **commit** (fire Phase 2 on what's already answered). Keep the per-issue answered/skipped state in the journal, not just the answers — Phase 2 needs it to pick the right branch.
- **Mid-run controls still apply.** `resolve-decisions`' controls are unchanged: "help me think through this one" detours and re-elicits the same decision; "skip this one" records it unresolved; "stop / we'll finish later" halts the collect run. A halt goes straight to Phase 2 with whatever was answered.

#### Phase 2 — Commit (all mutation, batched)

Replay the journal and fire every issue's [record step](./resolve-decisions.md#record--unblock) together. Per issue, apply exactly the branch an immediate run would have:

- **Every decision answered** → post the structured `<!-- shipyard-resolve-decisions -->` decisions comment and **remove the gate label**; the issue is now dispatch-ready.
- **Any decision skipped, or the run halted before the issue finished** → post the **partial** comment and **leave the gate label on**. This is `resolve-decisions`' partial-run rule, generalized per-issue: batching changes *when* the record fires, never *what* it decides.

Then print a one-block summary — which issues are now dispatch-ready, which stayed gated and why — and **stop**. `/my-turn` dispatches no code workers and does not chain into `/do-work`; the maintainer runs `/shipyard:do-work` when they want the newly-unblocked work implemented.

Clear the journal only after the batch has been recorded successfully. If a record call fails, leave the journal intact and say which issues did not land — losing a maintainer's answered decision set is far worse than a duplicate comment, and the `<!-- shipyard-resolve-decisions -->` sentinel already makes a re-run idempotent.

#### Phase 3 — Walk the rest

Now walk the non-decision items set aside in Phase 1 — **one at a time, advancing until the queue is empty**, exactly as before:

1. **Surface the top item.** Render the highest-ranked remaining item as a focused `→ Now:` directive (format below).
2. **Walk it.**
   - **PR awaiting `$ME`'s review** → surface the PR URL and the diff summary, and prompt the user to review; when they've approved / requested changes, the item is done.
   - **Unanswered question / `@$ME` ping** → surface the question and the thread URL; the user posts their reply (or asks Claude to draft one for them to send) — `/my-turn` does not post on the user's behalf unless they direct it as part of the walkthrough.
   - **`blocked:ci` PR / epic to decompose by hand / housekeeping (stale draft, DIRTY, `CHANGES_REQUESTED`)** → surface the concrete next step and the URL, and point at the dedicated command where one applies (`/shipyard:decompose-epic` for a mechanically-shardable epic, `/shipyard:do-work` for a `blocked:ci` PR). Derive the next step from the survey projection alone, within the [per-item investigation ceiling](#per-item-investigation-ceiling-1073) — do not read CI logs or drill into a failing run's jobs to name the root cause; when the ceiling would be exceeded, render the [degraded form](#per-item-investigation-ceiling-1073) instead (see [Don't → Don't diagnose](#dont)). The user acts; the item is done when they say so.
3. **Confirm done, then advance.** When the user signals the current item is handled (submitted the review, posted the reply, closed the PR — or they say "skip" / "next"), **immediately advance to the next-ranked item** and repeat from step 1. Do NOT exit after one item; do NOT require the user to re-invoke the command.
4. **Terminate when the queue is empty.** Print the [empty state](#empty-state) confirmation and stop cleanly. See [Termination contract](#termination-contract) for the exact exit conditions.

**When a phase is empty, skip it silently.** No decision-gated issues → go straight to Phase 3. Nothing but decisions → Phase 2's summary is the last thing printed. Never announce a phase that has no work in it.

**The headline render** for the current [Phase 3](#phase-3--walk-the-rest) item (Phase 1 renders no `→ Now:` directive — it is a question run, not an item walk):

```
→ Now: answer the 7 product/schema decisions blocking the orgs feature (#1816)
  https://github.com/owner/repo/issues/1816
  (unblocks the orgs epic — 3 issues are Blocked by this)

  [1 of 6 human-only items]
```

When the action's next step lives in a **third-party console** (e.g. a security/access-control toggle the operator layer handed back), append the provider deep link on its own indented line below the GitHub artifact URL (see [Third-party console deep links](#third-party-console-deep-links)):

```
→ Now: enable the OAuth redirect URI a human must sign off (#74)
  https://github.com/owner/repo/issues/74
  https://console.firebase.google.com/project/<project>/authentication/providers
```

Rules for the per-item headline render:

- **`→ Now:` line.** The `→ Now: ` prefix, then the **imperative action** (verb-first, sentence-case, same shape as the list-mode action — see [Rendering rules](#rendering-rules)), then the artifact ref `(#<num>)` in parentheses at the end. This is the one mandatory line.
- **URL line.** The clickable GitHub artifact URL on its own indented line directly below.
- **Third-party console deep link (when applicable).** When the action's actual work happens in a provider console the human must operate (Meta / Firebase / Vercel / App Store Connect / Apple Developer / Play Console / GCP / GitHub settings), append the most-specific-reachable provider deep link on its own indented line below the artifact URL, derived per [Third-party console deep links](#third-party-console-deep-links). Falls back to the provider's top-level console when the specific page isn't derivable; omit when no console is involved. (A *mechanical* console action would have been filtered out as the operator layer's; what reaches here is a console step that needs the human's judgment or sign-off.)
- **Dependency / unblocks context (optional).** If the current item *unblocks* other tracked work (e.g. an issue whose closure is referenced by `Blocked by #<N>` on another open item), append one indented parenthetical line naming what it unblocks: `(unblocks #<N>)` / `(then <downstream> can go out)`. This tells the user *why* this is the next step. Derive it from the same signals the ranking uses (the dependency edges in Pass A/B); if there's no downstream dependency, omit the line.
- **Progress footer.** Append a blank line then `[<i> of <N> human-only items]` so the user always sees where they are in the walkthrough. When the current item is the last, render `[last human-only item]`.
- **Release-please / version-bump PR as a queue item.** A discretionary release PR (per [Ranking → Release-please / version-bump PRs](#release-please--version-bump-prs-discretionary)) is ranked at the bottom of P2, so it's only ever walked *after* every genuinely-blocking item — and only when something downstream blocks on the release shipping (the same exception that lets it rank up). If the release PR is the *only* human-blocked item, don't render a false-urgency directive — render the discretionary phrasing instead and terminate (there's no action *blocked on you*, just an open option):

  ```
  Nothing blocking you — the release PR #<num> is ready to ship whenever you want.
    https://github.com/owner/repo/pull/<num>
  ```

#### Decision-gated walkthrough

A **decision-gated** issue is a `needs-human-review` issue that scores leverage **4** as a *pure-decision item* because its body (or a scope-preflight comment) enumerates **answerable** blocking decisions (a numbered "Blocking decisions before any code can be written" list, an `## Open questions` / `## Open product/schema questions` heading, a `<!-- do-work-human-decision-required -->` marker, or a `design`-gated set of questions). This is the trigger surface [Phase 1](#phase-1--collect-no-mutation-no-work) partitions on, and its decisions are walked by **reusing `/shipyard:resolve-decisions`' interactive flow** ([#566](https://github.com/mattsears18/shipyard/issues/566), [#635](https://github.com/mattsears18/shipyard/issues/635)) — the one place `/my-turn` mutates GitHub, and exactly the mutation `/shipyard:resolve-decisions` already owns, not a reinvention.

Reuse the [per-decision walkthrough](./resolve-decisions.md#the-per-decision-walkthrough) verbatim: for each blocking decision, emit the 5-part format (restated question → concrete options with trade-offs → **a clear recommendation with reasoning** → lock + carry-forward → room to clarify before locking). Honor its mid-walkthrough controls ("help me think through this one", "skip this one", "stop / we'll finish later") and its partial-run rule (a skipped or halted decision-set does NOT clear the gate). **Don't re-implement that flow here — invoke its spec** so the two commands stay in lockstep.

**Run it in [deferred firing mode](./resolve-decisions.md#firing-mode--immediate-default-vs-deferred-batch-caller)** ([#1070](https://github.com/mattsears18/shipyard/issues/1070)): the walkthrough yields its decision set as a value and records **nothing**. `/my-turn` journals it and fires [resolve-decisions' Record + unblock](./resolve-decisions.md#record--unblock) for every collected issue together in [Phase 2](#phase-2--commit-all-mutation-batched). A `gh issue comment` or `gh issue edit` landing between two of the maintainer's answers is exactly the latency [#1070](https://github.com/mattsears18/shipyard/issues/1070) removes — the standalone `/resolve-decisions --issue N` path still records immediately, since with one issue there is nothing to batch.

Rules for the decision-gated item:

- **Only for a genuinely decision-gated item.** Walk decisions only when the current item is a leverage-score-4 pure-decision `needs-human-review` issue with answerable decisions present. Do **NOT** treat an epic-decomposition handoff (`<!-- do-work-needs-decomposition -->` — that's `/shipyard:decompose-epic`'s job, score 1), an `external-dependency` defer (`<!-- do-work-external-dependency -->` — that's the operator layer's, already filtered out), a classifier-undispatchable hand-back (`<!-- do-work-classifier-undispatchable -->` — [#953](https://github.com/mattsears18/shipyard/issues/953); there is no enumerated decision to walk, only "do it by hand or grant a policy exception"), or an external-author trust gate as decision-gated — those carry `needs-human-review` but enumerate no answerable decisions, so there's nothing to walk; surface them as a plain "what to do next" item and let the user act. **Clearing `needs-human-review` on a classifier-undispatchable item is not itself a fix** — nothing about the issue's content changed, so a bare label-clear followed by re-dispatch will most likely hit the same classifier denial again; only clear the label once the human has actually done the work by hand, or made an explicit permission-policy call that changes what a future dispatch attempt will look like.
- **The batched decisions record is the only mutation.** Posting the decisions comments and removing the gate labels happen in [Phase 2](#phase-2--commit-all-mutation-batched), and only for decisions the human actually answered — `/my-turn` performs no *other* mutation (no `gh pr edit`, no `gh issue close`, no posting on the user's behalf outside the decisions record). The mutation is what the human directed by working through the decisions; that's the human-facing boundary, not a violation of it. Deferring it to a batch changes the timing, not the boundary.
- **Only for a genuinely decision-gated item — and only its own decisions.** Phase 1 collects decisions **only** from issues that pass the trigger surface above. Never invent a question for an issue that enumerates none just to give the batch more to ask; an issue with no answerable decisions belongs to [Phase 3](#phase-3--walk-the-rest).
- **List-snapshot mode.** In `--all` / `--limit N > 1` snapshot mode there is no walkthrough — the decision-gated item renders its normal action row plus a one-line `→ run /shipyard:resolve-decisions --issue <N> to walk these` pointer, since the snapshot is a static view, not an interactive session.

### List-snapshot mode (`--all`, or `--limit N > 1`)

Print the full ranked list as a static snapshot — **no phased run, no questions, no mutation**; this mode exists to let the user *eyeball* the human-only backlog at a glance. Lead with the verb; same terse, framing-free shape as before. Format:

```
1. #142 review and approve or request changes  <https://github.com/owner/repo/pull/142>
2. #155 read refined body, set priority label, remove needs-human-review  <https://github.com/owner/repo/issues/155>
3. #148 investigate failing check (`gh pr checks 148 --watch`), fix or escalate  <https://github.com/owner/repo/pull/148>
4. #161 reply to @<other-login>'s question or close if stale  <https://github.com/owner/repo/issues/161>
5. #134 finish draft and mark ready-for-review, or close (11d stale)  <https://github.com/owner/repo/pull/134>

1 blocked:ci PR
```

<a id="operator-pointer-line"></a>**Operator pointer line.** When the [Human-only queue filter](#human-only-queue-filter) excluded one or more `agent-console` / browser-completable items, append a single one-line pointer below the structural footer so the user knows those items exist and which command drains them (never list them individually — they aren't `/my-turn`'s work):

```
6 browser-completable operator actions excluded — run /shipyard:do-work to have Claude complete them
```

This pointer is the *only* trace of operator items in `/my-turn` output. It renders in list-snapshot mode (below the structural footer) and, in [walkthrough mode](#walkthrough-mode-default), once at the end when the queue empties (alongside the empty-state confirmation) — never as a walked item.

### Chrome-prompt mode (`--chrome-prompt`)

When `--chrome-prompt` is present, the **entire visible output** is a single copy-paste-ready prompt block. Nothing appears above the opening divider line and nothing appears below the closing divider line except the optional "can't be automated" section. The user highlights from the first divider line to the last, pastes the whole thing into the Claude for Chrome browser extension, and the extension acts — no further reading or interpretation required.

**Survey, the [Human-only queue filter](#human-only-queue-filter), and ranking run identically.** The same passes A–C run, the queue is filtered to human-only items, the same priority tiers and leverage scores apply, and `--all` / `--limit` govern which actions are included (top-1 without `--all`; all ranked items with `--all`, capped at `--limit`). The only difference is the render — chrome-prompt mode emits a one-shot prompt, not an advancing walkthrough.

**Prompt construction.** The body of the pasted prompt is self-contained instructions telling the extension what to do — concrete enough that the extension can act without re-deriving anything:

- For each included action: the imperative action sentence (verb-first, sentence-case), the GitHub artifact URL, and — when applicable — the third-party console deep link (same derivation as the standard render). The extension can navigate to URLs; include them literally.
- Enough context to identify each item unambiguously: PR or issue number, what to click, what to decide, what text to type (e.g. for a review: whether to approve or request changes).
- When covering multiple actions (`--all`), present them as a numbered list inside the prompt body, ordered by the same ranking used by the standard render.

**Layout.** Print exactly this structure, with no other content outside the dividers and the trailing section:

```
                                               (one blank line)
──────────────── COPY THE PROMPT BELOW ────────────────
                                               (one blank line)
<the full pasteable prompt for the Claude Chrome extension>
                                               (one blank line)
──────────────── COPY THE PROMPT ABOVE ────────────────
                                               (one blank line)

⚠️  Can't be automated (do these yourself):
- <item>
```

Rules for each layout element:

- **Divider lines.** Use exactly `──────────────── COPY THE PROMPT BELOW ────────────────` and `──────────────── COPY THE PROMPT ABOVE ────────────────` (em-dashes `─`, U+2500, repeated). The labels are capitalised; the dashes form a full-width visual rule. One blank line on each interior side of the dividers.
- **Prompt body.** Self-contained, complete instructions. No meta-commentary ("here is what you should do"), no output-format instructions to the reader — write to the extension as if it were receiving the instructions directly. Use the present-tense imperative ("Go to ...", "Open ...", "Click ...", "Review ..."). Include all URLs. For decision-gated items, enumerate the specific decisions to make and any context the extension needs to recommend or resolve them.
- **"Can't be automated" section.** Appears after the closing divider, separated by one blank line. The `⚠️  Can't be automated (do these yourself):` header is followed by a bullet list of items that are out of reach for the browser extension: actions requiring physical device access, external-service credentials the extension doesn't have, real-world coordination with a third party, or judgment calls explicitly flagged as needing the user's personal decision. **Omit the section entirely** (header and all) when there are no such items — do not emit an empty section or a "none" bullet. The classification heuristic: an action is browser-doable if it consists of navigation + clicking + typing in a browser tab using the user's session; it is NOT browser-doable if it requires out-of-browser credentials, a native device (TestFlight, on-device build), a third party's manual action, or a purely personal judgment the user must own.
- **Empty state in chrome-prompt mode.** When passes A–C return zero items, emit the same empty-state text as normal mode but wrap it in the dividers so the output shape is consistent:

  ```
                                                 (one blank line)
  ──────────────── COPY THE PROMPT BELOW ────────────────
                                                 (one blank line)
  Nothing on your plate — backlog is clean. No actions for the Chrome extension right now.
                                                 (one blank line)
  ──────────────── COPY THE PROMPT ABOVE ────────────────
  ```

**What chrome-prompt mode does NOT emit:**

- No `→ Now:` prefix or directive, and no interactive walkthrough — chrome-prompt mode is a one-shot text emission, not the phased run.
- No ranked numbered list above or outside the dividers.
- No tier headers, signal labels, or remainder footer.
- No operator pointer line (`agent-console` items are filtered out before the prompt is built; the chrome-prompt output is for the extension to act on, not a terminal nudge).
- No inline decision walkthrough (the `/shipyard:resolve-decisions` flow is a terminal-interactive affordance; the chrome-prompt output goes to the extension, not into an interactive session).
- No structural footer line (`<N> blocked:ci PRs`).

**Distinction from `/do-work`.** The `--chrome-prompt` flag is text-emission only: Claude emits a prompt string and stops. No `chrome-devtools-mcp` calls, no browser automation, no MCP connection. The Claude for Chrome extension is a separate agent that receives the text and operates independently. `/do-work` (operator-inclusive by default) covers the complementary mode where Claude Code itself drives the browser via MCP — do not conflate the two.

### Termination contract

The phased run is the only mode that continues until a queue is exhausted, so it needs a defined exit ([#635](https://github.com/mattsears18/shipyard/issues/635)). It **terminates cleanly** when any of:

- **Both queues are empty** — every decision was collected and committed, and every [Phase 3](#phase-3--walk-the-rest) item has been walked (handled or skipped). Print the [empty state](#empty-state) confirmation, plus the [operator pointer line](#operator-pointer-line) if any `agent-console` items were filtered out, and stop.
- **The user stops it** — the user says "stop" / "that's enough" / "done for now" at any point. **Where the halt lands matters:**
  - **During [Phase 1](#phase-1--collect-no-mutation-no-work)** → do **not** discard the answers already given. Proceed directly to [Phase 2](#phase-2--commit-all-mutation-batched) and commit them, applying the per-issue answered/partial branch, then report what landed and how many decisions remain uncollected (`<K> decisions left — rerun /my-turn to continue`). Skipping Phase 2 on a halt would throw away work the maintainer already did.
  - **During Phase 3** → halt immediately; confirm what's been handled and how many items remain (`<K> human-only items left — rerun /my-turn to continue`), and stop.
- **Only a discretionary release PR remains** — render the "ready to ship whenever you want" phrasing (see [walkthrough mode](#walkthrough-mode-default)) and stop, since there's no action *blocked on you*.

**A halted or skipped decision set still follows the partial-run rule** — the gate is NOT cleared unless every blocking decision on that issue was answered.

The run does NOT re-run the survey passes after each item by default — it consumes the up-front ranked queue. **Re-derive only on a defined refresh:** the natural one is **after Phase 2**, since committing decisions plausibly changed the queue (an unblocked issue may be what another item was `Blocked by`); re-run the passes once there before starting Phase 3. Also re-derive if the user reports they completed something out-of-band. Don't re-survey between questions or on every Phase 3 step — that burns the [performance budget](#performance-budget) and reorders the queue under the user mid-session.

### Rendering rules

These apply to the **list-snapshot** items and to the action sentence inside the walkthrough's `→ Now:` directive.

Per item — **one line by default**:

- **Index** (1-based, monotonic across the entire list) followed by `.`
- **Artifact ref** — `#<num>` only (no `PR`/`Issue` prefix — the URL discloses the type; the number is the disambiguator).
- **Imperative action** — verb-first, sentence-case, no trailing period. This is the only mandatory content. Examples: `review and approve or request changes`, `investigate failing check, fix or escalate`, `reply to question or close`, `make the design call (see thread) or break into spike + impl`, `enable Email/Password in Firebase Console for <project>`, `set real values for placeholder secrets via firebase functions:secrets:set --project test`, `review the refuse reason in the comment; clear, re-scope, or close` (agent-refuse `needs-human-review`, per [#521](https://github.com/mattsears18/shipyard/issues/521)), `vouch for @<author> (add to .shipyard/trusted-authors.txt or re-file), triage by hand, or close` (external-author trust review, per [#1079](https://github.com/mattsears18/shipyard/issues/1079)).
- **Stale suffix** (optional) — append `(<N>d stale)` only when the item's age crosses a threshold worth flagging: **≥7d** for any item, or **≥1d** for `awaiting your review` (the highest-leverage block). Default: no age string. The point is a flag, not a metric.
- **URL** — clickable `<https://...>` at end of line so terminals render it as a hyperlink. Two spaces before the URL for visual separation.
- **Third-party console deep link** (optional) — when the item's action's next step lives in a provider console (Meta / Firebase / Vercel / App Store Connect / Apple Developer / Play Console / GCP / GitHub settings), append the most-specific-reachable provider deep link `<https://...>` after the GitHub artifact URL (two spaces before it), derived per [Third-party console deep links](#third-party-console-deep-links). Falls back to the provider's top-level console when the specific page isn't derivable. Omit when no third-party console is involved. Example: `6. #74 create a Test User on the test Meta app 982594884358918  <https://github.com/owner/repo/issues/74>  <https://developers.facebook.com/apps/982594884358918/roles/test-users/>`.

**Drop by default:**

- **Title restatement.** The action sentence carries the artifact's intent in active voice; the title is reference, not headline. Include only when the action genuinely doesn't disambiguate without it (rare — e.g. `#42 review (auth refactor)` to distinguish from `#43 review (logging migration)` when several PRs are queued).
- **Per-item signal labels** (`needs-human-review`, `blocked:ci`, `awaiting your review`, `DIRTY`). The action sentence already encodes the signal; the label is metadata on the artifact for users who want the receipt.
- **Tier headers** (`P0 — blocking other work`, etc.). Items are already ranked; the position is the priority. Internal ranking still uses P0/P1/P2 (see [Ranking](#ranking)) — the tiers just don't render.
- **The opening `HUMAN ACTIONS NEEDED — …` banner.** Redundant — the user just typed the slash command.

**Multi-line items.** Only when the next action genuinely doesn't fit on one line *and* breaking it loses information. Follow-up lines are indented and still action-shaped (continuation of the verb), never framing or restatement.

**Optional footer line** — one line, terse, at the bottom of the list. Surface only if there are open `blocked:ci` PRs (`<N> blocked:ci PRs`). Skip entirely if there's nothing structural worth flagging. Never a paragraph; never a recap of items already in the list.

### Third-party console deep links

When the next action's actual work happens in a **third-party provider console** ([#523](https://github.com/mattsears18/shipyard/issues/523)) — the user has to create a test user in the Meta App Dashboard, enable an auth provider in the Firebase Console, paste a secret into a GitHub repo's Actions settings, submit a build in App Store Connect, etc. — the rendered action **MUST** append a clickable deep link to the **most specific reachable page**, derived from identifiers already in hand (app ID, project ID, bundle ID, team/owner slug, etc.). The information needed to build the link is almost always already present in the issue/PR body, a comment, or the repo's config — turning it into a URL costs the user one navigation they'd otherwise do by hand, across a provider UI with many nested pages.

This applies to **all three modes**: the walkthrough `→ Now:` headline (the deep link goes on the indented URL line, *in addition to* the GitHub artifact URL — see [Walkthrough mode](#walkthrough-mode-default)), the list-snapshot rows (the deep link is appended after the GitHub artifact URL — see [Rendering rules](#rendering-rules)), and the chrome-prompt body (include the URL literally in the prompt text so the extension can navigate directly — see [Chrome-prompt mode](#chrome-prompt-mode---chrome-prompt)).

**Provider URL templates.** Substitute the bracketed identifiers from the action's context. Extend this table as new providers/actions surface — it's a starting set, not a closed list:

| Provider | Action | URL template |
|---|---|---|
| Meta App Dashboard | Test Users | `https://developers.facebook.com/apps/<APP_ID>/roles/test-users/` |
| Meta App Dashboard | App settings / basic | `https://developers.facebook.com/apps/<APP_ID>/settings/basic/` |
| Firebase Console | Auth users | `https://console.firebase.google.com/project/<PROJECT_ID>/authentication/users` |
| Firebase Console | Auth providers | `https://console.firebase.google.com/project/<PROJECT_ID>/authentication/providers` |
| Vercel | Project | `https://vercel.com/<TEAM>/<PROJECT>` |
| App Store Connect | App | `https://appstoreconnect.apple.com/apps/<APP_ID>` |
| Apple Developer | Identifiers | `https://developer.apple.com/account/resources/identifiers/list` |
| Play Console | App dashboard | `https://play.google.com/console/u/0/developers/<DEV_ID>/app/<APP_ID>/app-dashboard` |
| GCP Console | Project | `https://console.cloud.google.com/home/dashboard?project=<PROJECT_ID>` |
| GitHub | Repo Actions secrets | `https://github.com/<owner>/<repo>/settings/secrets/actions` |

**Fallback when the specific page isn't derivable.** If a required identifier is missing (you know it's a Firebase auth task but the body never names the `<PROJECT_ID>`), link the provider's **top-level console** rather than no link at all — a one-hop landing page still beats prose-only navigation:

| Provider | Top-level fallback |
|---|---|
| Meta App Dashboard | `https://developers.facebook.com/apps/` |
| Firebase Console | `https://console.firebase.google.com/` |
| Vercel | `https://vercel.com/dashboard` |
| App Store Connect | `https://appstoreconnect.apple.com/apps` |
| Apple Developer | `https://developer.apple.com/account/` |
| Play Console | `https://play.google.com/console/` |
| GCP Console | `https://console.cloud.google.com/` |
| GitHub | `https://github.com/<owner>/<repo>` |

**Derivation rules:**

- **Use identifiers already in hand — never fabricate one to fill a template.** Pull `<APP_ID>` / `<PROJECT_ID>` / `<owner>`/`<repo>` from the action's context (the issue or PR body that produced the item, a comment, the resolved repo). If you can only partially fill a template (e.g. the provider and a project ID but not the exact sub-page), link the deepest page you *can* fully construct, then fall back up the hierarchy — most-specific-reachable wins, but a guessed identifier is worse than the fallback (a wrong deep link sends the user to someone else's app).
- **Read-only constraint still holds.** Deriving the link is pure string construction from data already surveyed; it adds no `gh` mutation and no new API round-trip. Do **not** call out to a provider API to *discover* a missing identifier — that's scope creep and may require credentials the command doesn't have. Missing identifier ⇒ top-level fallback, full stop.
- **One deep link per action.** If an action plausibly touches two consoles, link the one where the *next* step happens; don't stack multiple provider links on one directive.

### Internal fields (used for ranking, not rendered)

The ranking step still needs the underlying signals to produce the order — they just don't appear in the rendered output. The internal projection per item carries:

- **Tier** — P0 / P1 / P2 (see [Ranking](#ranking)).
- **Leverage score** — 4 / 3 / 2 / 1 (see [Secondary sort](#secondary-sort--leverage-score-then-age-issue-565)), derived from the same survey signals. The **primary** within-tier sort key (descending); not rendered. Issue [#565](https://github.com/mattsears18/shipyard/issues/565).
- **Why-on-user** — the signal name that fired (`awaiting your review`, `blocked:ci`, `needs-human-review`, etc.). Used by the ranking + dedup logic; not rendered unless multiple signals merged into one row produced a non-obvious action verb, in which case a single inline `(also: <signal>)` suffix is permitted.
- **Age** — `createdAt` for new items, `updatedAt` for label-change items (v1 heuristic: use the older of the two; under-counts but never over-counts). The **tie-breaker** within a leverage score (oldest first); also triggers the stale suffix.
- **URL** — surfaces unmodified.

### Empty state

If the human-only queue is empty — passes A–C returned zero human-only items, or the [walkthrough](#walkthrough-mode-default) just exhausted the queue — print a single friendly one-liner and exit cleanly. **Unchanged across modes** — the empty state is identical whether the queue started empty or the walkthrough drained it, and whether or not `--all` / `--limit` is passed. No banner, no multi-line prose — this is the one case where the answer to "what do I need to do" is actively "nothing," and the rendering should mirror the content. If `agent-console` items were filtered out, append the [operator pointer line](#operator-pointer-line) below it so the user knows the operator layer still has work.

```
Nothing on your plate — backlog is clean. Try /shipyard:audit to surface fresh work, or take a break.
```

### Limit overflow (list-snapshot mode only)

In **list-snapshot mode**, if the ranked list has more items than `--limit`, print the first `--limit` items then:

```
  … and <K> more (rerun with --limit <K+N> to see all)
```

This overflow line is list-snapshot-mode only. In [walkthrough mode](#walkthrough-mode-default) there's no overflow — the loop walks every human-only item in turn, so nothing is hidden behind a cap; the `[<i> of <N> human-only items]` progress footer is the "how much is left" signal instead.

## Performance budget

The full survey should complete in well under 10 seconds for a backlog of ~100 PRs and ~200 issues:

- Pass A + Pass B: two parallel `gh` calls, each ~1–2s
- Pass C: capped at 20 per-PR follow-ups, run in parallel, ~3s total

If a backlog blows the budget, `--limit` already provides a knob; otherwise file an issue for a future v2 that uses GraphQL to collapse Passes A+B+C into one round-trip.

**[Phase 1](#phase-1--collect-no-mutation-no-work)'s bulk context pass is budgeted separately, and deliberately front-loads cost.** It runs once, after the survey and before the first question, and it may fan out read-only readers in parallel. Its budget is *not* "as fast as possible" but "all of it before the maintainer is asked anything" — the metric that matters is the gap between two consecutive answers, which should be **zero** tool calls in the steady case. Spending a few extra seconds up front to buy that is the trade [#1070](https://github.com/mattsears18/shipyard/issues/1070) makes; re-reading the codebase between two questions to save it is exactly the anti-pattern. **This front-loading is scoped to grounding a *decision* the human is about to be asked to make** — a design tradeoff, a scope call, the recommendation behind a decision-gated issue's options. It is not, and must never be read as, license to establish *why* a [Phase 3](#phase-3--walk-the-rest) item (a red check, a `blocked:ci` PR) broke; that's diagnosis, and the ceiling below governs it regardless of how much budget Phase 1 spent.

### Per-item investigation ceiling ([#1073](https://github.com/mattsears18/shipyard/issues/1073))

The survey passes' own budget above governs *collection*. This governs what happens **after** an item is ranked and its rendered action is being written — the gap the original v1 budget left open, and the one an agent under pressure to write a genuinely useful `→ Now:` line has every incentive to fill by digging deeper.

**The ceiling: deriving any single item's rendered action costs zero additional tool calls beyond the survey projection in the steady case, and never more than `$max_diagnostic_reads_per_item` (default `1`, resolved once at [Setup step 5](#5-resolve-the-per-item-investigation-depth-ceiling-1073)).** The survey projection is Passes A–C's own `gh` output, plus — for a decision-gated issue only — [Phase 1](#phase-1--collect-no-mutation-no-work)'s bulk context pass. One extra read means exactly one: e.g. a single `gh pr view` on the item's own number for a field the list projection didn't request. It never means reading CI logs, drilling into a run's jobs (`gh run view --json jobs`, `gh api .../actions/runs/<id>/jobs`), tracing a stack trace, or otherwise walking multiple `gh` calls to reconstruct *why* something failed — that is root-causing, and root-causing an item is always out of scope for `/my-turn` regardless of how it's ranked (see [Don't → Don't diagnose](#dont)).

**This applies to every item, in every mode (walkthrough, list-snapshot, chrome-prompt), to every signal in [Ranking](#ranking) today, and to any signal added later.** The bound is structural — expressed as a ceiling on tool calls, not as a list of signals to be careful with — so it doesn't need updating every time a new label or PR state is added to the survey. A P0 item is the strongest possible "invest here" signal the ranking produces; the ceiling is what stops that signal from being read as license to keep digging until the action sentence feels satisfying.

**Degraded render — when the ceiling would be exceeded.** Stop and render exactly what the survey established instead of continuing to investigate: the known signal, the artifact URL, and a pointer to the command that owns going deeper (`/shipyard:do-work`, `/shipyard:decompose-epic`, `/shipyard:investigate`). For example, a `blocked:ci` PR whose failure isn't legible from the check-rollup name alone renders as `#148 investigate failing check — run /shipyard:do-work to have Claude diagnose and fix it <url>`, never a line naming the specific failing step or error string pulled from a log. The degraded form is not a failure state or a fallback to apologize for — it is the correct, complete render for an item whose diagnosis is someone else's job. See [Rendering rules](#rendering-rules) for how this composes with the one-line-by-default render shape.

## Don't

- **Don't diagnose — surface** ([#1073](https://github.com/mattsears18/shipyard/issues/1073)). An item's rendered action must be derivable from the survey passes' own projection plus, at most, the [per-item investigation ceiling](#per-item-investigation-ceiling-1073)'s one extra read — never by reading CI logs, drilling into a run's jobs, tracing a stack trace, or otherwise establishing *why* something failed. `/my-turn` establishes *that* an item needs the human and *where* to look; it never establishes *root cause* — that's `/shipyard:do-work`'s job (or `/shipyard:investigate`'s), and doing it here spends the human's wall-clock producing something they didn't ask for. This is unconditional regardless of priority tier: ranking an item **P0** is the strongest "invest here" signal the command produces, and it is exactly the signal that tempts an agent to keep digging past the ceiling to write a satisfying action line — resist it. When the concrete next step can't be written within the ceiling, render the [degraded form](#per-item-investigation-ceiling-1073) (known signal + artifact URL + owning command) instead of investigating further.
- **Don't mutate beyond what the human directs, and don't mutate during [Phase 1](#phase-1--collect-no-mutation-no-work) at all.** The *only* mutation `/my-turn` performs is the [batched decisions record](#phase-2--commit-all-mutation-batched) (post the `<!-- shipyard-resolve-decisions -->` decisions comment + remove the gate label), and only because the human worked through the decisions — it's the reused `/shipyard:resolve-decisions` mutation, the human-directed outcome of the walkthrough, not autonomous action ([#566](https://github.com/mattsears18/shipyard/issues/566), [#635](https://github.com/mattsears18/shipyard/issues/635)). **It fires in Phase 2, never mid-question** ([#1070](https://github.com/mattsears18/shipyard/issues/1070)) — a GitHub round-trip between two of the maintainer's answers is the latency the phase split exists to remove. **Everything else stays hands-off:** no `gh pr edit`, no `gh issue close`, no labels changed on other issues, no comments posted on the user's behalf outside the decisions record.
- **Don't dispatch mutating agents or share `/do-work`'s worker/execution machinery.** `/my-turn` is human-facing and human-paced — the autonomous loop (code workers, the operator phase, parallel worktrees) is `/shipyard:do-work` / `/do-work`'s job. `/my-turn` never spawns a code worker, never opens a PR, never drives the browser, and never dispatches an agent that mutates anything. If the user wants Claude to *work* the items, they run `/shipyard:do-work` (autonomous code loop **+** browser operation, operator-inclusive by default) separately.
  - **Read-only research agents are permitted, and only in [Phase 1](#phase-1--collect-no-mutation-no-work)'s bulk context pass** ([#1070](https://github.com/mattsears18/shipyard/issues/1070)). Once the mutations move to Phase 2, gathering issue bodies and codebase grounding is what's left of the wait — fanning that out in parallel is the difference between a snappy question run and a slow one. Such an agent may **read only**: no file writes, no `gh` mutation, no browser, no PR. The rule this narrows is "no *autonomous* work," not "no concurrency" — a read-only reader produces context for a human to decide on, which is precisely what `/my-turn` is for.
- **Don't chain into `/do-work`.** [Phase 2](#phase-2--commit-all-mutation-batched) ends by naming which issues are now dispatch-ready and stopping. Kicking off implementation because decisions just got unblocked would make `/my-turn` autonomous and start burning tokens the maintainer didn't ask for; running `/shipyard:do-work` is their call and their keystroke.
- **Don't surface items `/do-work` can complete.** Code work and browser-completable `agent-console` operator actions are filtered out by the [Human-only queue filter](#human-only-queue-filter) — `/my-turn`'s queue is human-decision / judgment-call items only. At most, a single [operator pointer line](#operator-pointer-line) notes that operator-completable items exist and which command drains them; they are never walked as `/my-turn` items.
- **Don't scan other repos.** Current repo only. Cross-repo digest is a future v2; for v1 the user can re-run with `--repo` in different cwds.
- **Don't write a report file.** v1 is terminal-only. If the user wants persistence, they can pipe via shell redirection from outside the slash-command UI; that's their concern, not the command's. Add `--output <path>` later if useful.
- **Don't surface PRs / issues authored by bots** (Dependabot, Renovate, etc.) unless they specifically request review from `$ME` — those auto-update PRs are noise in a "human action needed" list and have their own automation handling them.
- **Don't present an open release-please / version-bump PR as a top-priority "next action."** A manual gate is discretionary, not blocking — the commits it releases are already on the default branch and nothing downstream cascades from it. Surface it as housekeeping (bottom of P2 — see [Ranking → Release-please / version-bump PRs](#release-please--version-bump-prs-discretionary)); only let it rank up or lead the walkthrough when something downstream explicitly blocks on the release shipping. When it's the only human-blocked item, prefer the "release is ready whenever you want" phrasing over a false-urgency directive.
- **Don't include items where the next action is obviously Claude's, not the user's.** A PR with failing checks but NOT carrying `blocked:ci` is still inside `/shipyard:do-work`'s fix-loop — surfacing it would tell the user to step on the orchestrator's work. The `blocked:ci` label is the explicit "Claude gave up, human must" signal; absence of it means leave it alone.
- **Don't deep-dive on team membership for review requests.** v1 matches `$ME` directly against `reviewRequests`; team-via-membership lookups would add an extra `gh api` round-trip per PR and are out of scope. Users on teams will still see direct review requests in v1; team-level requests roll up via the GitHub UI's notification stream, which the user has anyway.
- **Don't repeat work `/shipyard:do-work`'s upfront summary already does.** `/do-work`'s step 2 prints a buckets table with workable / skipped / blocked counts. That's a *backlog snapshot*; `/my-turn` is a *human-actions list*. They share inputs but have different shapes — don't try to merge them.
- **Don't add framing back to the output.** No tier headers (`P0 — blocking other work`), no opening banner (`HUMAN ACTIONS NEEDED — …`), no closing prose paragraph (`Main CI on main is green, two PRs are still draining…`), no per-item title restatements, no per-item signal-label lines, no per-item age lines (except the stale suffix described in [Rendering rules](#rendering-rules)). The user asked for "what do I need to do" in imperative voice — every line of framing pushes the verb further down the screen. When in doubt: would removing this line lose any *action* information? If no, remove it.
- **Don't sort the within-tier order by age alone.** The within-tier secondary sort is **leverage score first, age only as the tie-breaker** (see [Secondary sort](#secondary-sort--leverage-score-then-age-issue-565)). A flat `createdAt`-ascending sort makes the *stalest* item lead the walkthrough — which on a `needs-human-review`-dominated P0 tier regularly surfaces an auto-undecomposable epic (the least actionable item) first, contradicting the command's "highest-leverage" promise (issue [#565](https://github.com/mattsears18/shipyard/issues/565)). Oldest-first is the tie-breaker, not the ranking signal.
- **Don't dump the full ranked list by default, and don't stop after one item.** The default render is the phased run ([collect](#phase-1--collect-no-mutation-no-work) → [commit](#phase-2--commit-all-mutation-batched) → [walk](#phase-3--walk-the-rest)), which continues until both queues are empty. Don't print a static 20-line backlog (that reintroduces the prioritization burden the command exists to remove; that's opt-in via `--all` / `--limit N > 1`), and **don't exit after surfacing one item** — the pre-[#635](https://github.com/mattsears18/shipyard/issues/635) "single-action" behavior forced a re-invoke per action and defeated the point of ranking the whole queue. The only exception is the [empty state](#empty-state).
- **Don't interleave collecting with acting.** This is the [#1070](https://github.com/mattsears18/shipyard/issues/1070) regression to guard against, and it reappears in subtle forms: recording issue A's decisions before asking issue B's first question, re-reading the codebase between two questions to ground the next recommendation, or slipping a PR-review item into the middle of the question run because it ranked higher. All three put the maintainer back to waiting mid-thought. **Every question first, then every mutation, then the action items** — if a step would make the human wait on Claude between two answers, it belongs in Phase 1's bulk context pass or in Phase 2, not between the questions.
- **Don't ask a dependent decision inside a batched `AskUserQuestion` call.** Grouping is for **mutually independent** decisions only. When an answer constrains a later question's options, that later question must be asked alone and after — [`resolve-decisions`' carry-forward](./resolve-decisions.md#the-per-decision-walkthrough) is the whole reason the walkthrough is sequential, and batching a dependent pair silently discards it to save one round-trip.
- **Don't discard journaled answers.** Answers live in `~/.shipyard/my-turn-<repo-slug>.json` from the moment they're given. Never abandon the run without firing [Phase 2](#phase-2--commit-all-mutation-batched) on what was collected — not on a halt, not on an error, not on a re-invocation. Clear the journal only after the records land; if a record call fails, keep it and say which issues didn't commit. Re-running is safe (the `<!-- shipyard-resolve-decisions -->` sentinel is idempotent); losing a maintainer's decisions is not.
- **In `--chrome-prompt` mode, don't emit anything outside the dividers except the "can't be automated" section.** The entire output must be highlightable as one clean copy region. Any preamble, status line, `→ Now:` directive, walkthrough prompt, or trailing prose outside the defined layout breaks the copy flow and defeats the mode's purpose. The "can't be automated" section is intentionally after the closing divider — it is for the human's eyes, not for the extension to execute, and it must not be inside the prompt body.
- **In `--chrome-prompt` mode, don't run the inline decision walkthrough or any interactive prompt.** The interactive [decision-gated walkthrough](#decision-gated-walkthrough) is a terminal-interactive affordance for the human at the terminal — it has no place in a one-shot prompt destined for the browser extension. Chrome-prompt mode is exclusively for extension consumption; terminal-only and interactive affordances are suppressed.
- **Don't call any MCP browser tools or attempt to drive the browser.** `/my-turn` never drives the browser — not in `--chrome-prompt` mode (which emits a text prompt and stops; browser execution is the Claude for Chrome extension's job when the user pastes the prompt) and not in walkthrough mode (it surfaces items for the human; it does not act). Driving the browser directly is `/do-work`'s scope, not this command's.

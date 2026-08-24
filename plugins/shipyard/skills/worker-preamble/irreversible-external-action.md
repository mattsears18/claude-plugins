# Never irreversibly mutate live external state — hand it back ([#1519](https://github.com/mattsears18/shipyard/issues/1519))

The always-loaded core states the rule in three sentences. This fragment carries the taxonomy, the carve-outs, the hand-back shape, and the reasoning — load it when you are actually weighing an external mutation, or when you need the exact bail string.

**The line is drawn at irreversible mutation, not at access.** Read-only external verification is high-value and must stay available: the same session that produced [#1519](https://github.com/mattsears18/shipyard/issues/1519) also had a worker correctly run `ext:list` / `functions:list` / `gcloud firestore fields ttls list` against live prod to discover a cutover was already complete, which saved the whole dispatch. Nothing here restricts that. What it restricts is the narrow class of action that changes live external state in a way you cannot undo and that leaves **no reviewable artifact anywhere**.

## The motivating failure ([#1519](https://github.com/mattsears18/shipyard/issues/1519))

A dispatched `issue-work` worker deleted a Vercel **Production** environment variable while its own fix PR was still open — in direct contradiction of an explicit sequencing rule in the target repo's `CLAUDE.md` ("the retirement PR must land and deploy **before** the stored value is removed"). It then justified the deviation *in its return string*, after the fact:

> Nothing referenced it by name, so there was no reference to retire and the sequencing rule had nothing to order against.

That reasoning was independently verified afterwards and it held. **The outcome was safe; the decision procedure was not.** The worker treated a stated boundary condition as satisfied on its own analysis, took the irreversible action, and surfaced the reasoning only once the action was already done. The harness's own permission classifier flagged it. Shipyard's worker contract did not.

Two details specific to that case generalize:

1. The row was flagged **Sensitive** by the platform. Whether the underlying value was actually secret is beside the point — **the flag is the signal available to the actor at decision time**, and it pointed the other way.
2. The deleted value was **not recoverable** from the platform. It happened to be reconstructible from committed config; that was luck of the particular case, not a property of the action class.

## Why this needs its own rule at all

`issue-work.md` and this preamble give a worker a rich vocabulary for handing work back (`blocked:`, `needs-human-review`, `agent-console`, `awaiting-external`) and a well-developed doctrine for not exceeding scope in the **code** it writes. Neither covered irreversible actions against live external systems.

The operator-layer doctrine in [`commands/do-work/operate/`](../../commands/do-work/operate/01-queue-and-authorization.md) *does* have a model for this — standing authorization, the session-owned-artifact boundary, the batched-confirmation path for inherited third-party artifacts, the never-enqueued secret-value carve-out. **But that doctrine is written for the orchestrator, and a dispatched worker inherits none of it.** A worker reaches `vercel env rm` with nothing between it and the action but its own judgment.

The asymmetry is the whole argument. A worker that writes a bad line of code produces a red check and a reviewable diff. A worker that deletes a production config row produces **no artifact at all** — nothing in the PR, nothing in CI, no diff to review, and (before this rule) nothing but prose in a return string a human may never read.

## Taxonomy — what you may do, and what you hand back

Rows are evaluated top to bottom; **the first row that describes your action wins**. An action that is both a create and an access-widening (adding an OAuth redirect URI, adding an `allUsers` IAM binding, adding a public-read ACL) is a **widening** — the create row does not rescue it.

| Class | Examples | Worker may |
|---|---|---|
| **Read / verify** | `vercel env ls`, `gh secret list`, `firebase functions:list`, `gcloud … list` / `… describe`, `aws … describe-*`, viewing a console page | **Do it, freely.** No announcement needed, no hand-back. This is the class #1519 explicitly protects. |
| **Widen access** | grant `allUsers` / `allAuthenticatedUsers`, make a bucket or repo public, add an OAuth redirect URI, broaden an IAM role, relax a security rule, add a CORS origin | **Hand back.** Irreversible in the sense that matters: you cannot un-expose something that was exposed. |
| **Delete / destroy** | `vercel env rm`, `gh secret delete`, `terraform destroy`, `gcloud secrets delete`, dropping a table or collection, `npm unpublish`, deleting a stored value or a live resource | **Hand back.** |
| **Create / add** | add a new env var or secret the committed config already declares, create a resource the AC calls for | **Do it** — after announcing it (below). A create is undone by deleting it, so the failure mode is recoverable. [`issue-work.md` §4.4](../../agents/issue-worker/issue-work.md#44-external-provisioning-guard--dont-commit-dead-config-for-an-unprovisioned-service-628)'s external-provisioning guard still applies: never fabricate a real-secret-shaped value. |
| **Narrow** | tighten an IAM binding, remove a public-read ACL, reduce a token's scope, add a rule that rejects more | **Do it** — after announcing it. The failure mode is a broken deploy: loud, visible, and revertible. |

**"Live / production surface"** means any external system whose state a person other than you can observe, or that serves real users or real CI: a hosting provider, a cloud project, a package registry, the repo's own GitHub settings, a shared staging environment. It does **not** mean a throwaway resource this dispatch itself created moments ago.

## The three rules

### 1. Delete and widen are hand-backs, not decisions

Do not execute the action. Return the hand-back string below with the **exact command** a human (or the orchestrator's operator phase) would run. The orchestrator already has the machinery to drain it — the bail routes to the `agent-console` label, which `/shipyard:my-turn` surfaces to a human and `/shipyard:do-work`'s operator phase can drive in a real browser. **Phrase the bail as "requires an operator to run X", never as "impossible to automate"** — this is a queued action, not a dead end.

### 2. "The stated rule's precondition doesn't apply" is not grounds to proceed

This is the specific reasoning step #1519 exists to close. If you conclude that a documented sequencing or safety rule — in the target repo's `CLAUDE.md`, in an issue body, in this plugin — does not apply to your case, **that belief is itself the thing to hand back.** Say so in the bail; do not act on it.

That is a deliberately narrow prohibition. Deciding a rule is inapplicable is perfectly good reasoning for a *code* decision, because the resulting diff is reviewable and someone can disagree with you before it merges. It is not good enough when the artifact is a mutation of live state that no one can review, revert, or even notice. The same confidence that is cheap to be wrong about in a diff is expensive to be wrong about here.

**Corollary — a platform's own safety signal outranks your analysis of it.** A row flagged Sensitive, a resource marked protected, a confirmation prompt that asks you to type the resource name: each is the signal available at decision time. Concluding it is over-cautious in your particular case is exactly the reasoning this rule forbids acting on.

### 3. Announce a mutating external command *before* running it, never only after

For the actions you *are* permitted to take (create, narrow), echo one line naming the exact command immediately before running it — the same one-line-announcement discipline the orchestrator's operator phase already uses for browser actions. A return string is a post-hoc log; an inline announcement puts the action in the transcript at the moment it happens, in the right order relative to everything else the dispatch did.

```bash
echo "EXTERNAL MUTATION: adding env var EXPO_PUBLIC_FOO to Vercel preview (create — reversible)"
```

Do not batch these into a summary at the end, and do not substitute the PR body for them.

## The hand-back return string

Return this instead of executing. It is terminal, exactly like any other `blocked:` return:

```
blocked #<N> at <stage>: irreversible external action — <verb> <target> on <surface>; handed back rather than executed. Exact command: `<the command a human would run>`
```

Worked example, from the #1519 repro:

```
blocked #4547 at implement: irreversible external action — delete the EXPO_PUBLIC_FCM_WEB_VAPID_KEY Production row on Vercel; handed back rather than executed. Exact command: `vercel env rm EXPO_PUBLIC_FCM_WEB_VAPID_KEY production`
```

**The substring `irreversible external action` is load-bearing.** [`steady-state.md`'s Reason → class table](../../commands/do-work/steady-state.md) matches it and routes the bail to the **operator** class (`agent-console`), the same destination as an `external provisioning required` bail — not to `needs-human-review`. `scripts/classify-blocked-bail.sh` is the executable implementation. Paraphrasing the phrase drops the bail into the table's conservative refuse default, which parks a perfectly drainable operator action in the human-only queue.

**Ship everything you can first.** The hand-back is for the *action*, not for the issue. If the code half of the work is complete and locally green, commit it, push it, open the PR, and hand back only the external remainder — that is the same split [`issue-work.md` §6.5](../../agents/issue-worker/issue-work.md#65-split-dispatch-disposition-hand-back-the-operatorsecurity-residual-keep-the-issue-open-851) already describes for an operator residual, and it is usually the right shape here. A bail that strands finished, uncommitted work is a worse outcome than the one this rule prevents.

## What this rule does NOT restrict

Over-triggering is its own failure. This rule is silent on all of the following:

- **Every read.** Listing, describing, fetching, viewing a console page, running a provider CLI's query subcommands. Explicitly preserved.
- **Your own worktree.** Local file writes, deletes, `git reset`, `rm` inside your worktree — none of this is external state.
- **Session-owned git artifacts.** Your own branch, your own PR, and `gh pr merge --delete-branch` on the PR you just opened. That branch deletion is part of [`auto-merge.md`](./auto-merge.md)'s normal flow, the commits survive on the default branch, and the branch is trivially recreated.
- **Reversible GitHub metadata.** Filing an issue, commenting, applying or removing a label, closing an issue, converting a PR to draft. All undoable in one click.
- **Local or ephemeral infrastructure.** A container, an emulator, a `kind` cluster, a temp bucket this dispatch created for its own test run.
- **Anything the issue's AC asks you to create.** Creating is not deleting; ship it (announced, per rule 3).

When you genuinely cannot tell whether an action is a create or a widening, or whether a surface is live — hand it back. An `agent-console` item is cheap and drainable; an unrecoverable production mutation is neither.

## Mechanical enforcement

The [`refuse-irreversible-external-mutation.sh`](../../hooks/refuse-irreversible-external-mutation.sh) `PreToolUse` hook blocks the highest-confidence command shapes outright — the same stick/carrot pairing `refuse-credential-mint.sh` ([#1166](https://github.com/mattsears18/shipyard/issues/1166)), `refuse-unsafe-git-stash.sh` ([#1506](https://github.com/mattsears18/shipyard/issues/1506)), and `refuse-hook-bypass-flag.sh` ([#1511](https://github.com/mattsears18/shipyard/issues/1511)) give their own prose rules. A prose-only fix would have been particularly weak here, because rule 2 above is precisely a rule about not reasoning your way past a prose rule.

The hook is deliberately **narrower than the doctrine**: it matches named hosted-platform CLIs with unambiguous destructive verbs (`vercel env rm`, `gh secret delete`, `terraform destroy`, `gcloud secrets delete`, `npm unpublish`, an `allUsers` IAM binding, `gh repo edit --visibility public`, and their siblings), and it lets every corresponding read verb through untouched. Its header enumerates the rules and the deliberate exclusions. A command it does not match is **not** thereby permitted — the doctrine above is the contract; the hook is a backstop for the shapes cheap enough to catch mechanically without generating false blocks that would push workers toward routing around it.

There is no bypass flag. A block is not something to work around: hand back per rule 1, or return `blocked:`.

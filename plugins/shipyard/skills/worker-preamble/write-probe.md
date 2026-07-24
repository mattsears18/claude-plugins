# Worker-preamble fragment — Write-capability probe

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md)). Load this immediately after the [step-0 cwd fail-fast](./SKILL.md#step-0-cwd-fail-fast--assert-youre-actually-in-your-worktree-486) passes, before any other work — issue [#895](https://github.com/mattsears18/shipyard/issues/895).

The [step-0 cwd fail-fast](./SKILL.md#step-0-cwd-fail-fast--assert-youre-actually-in-your-worktree-486) proves your shell's working directory resolves to your own isolated worktree. It proves nothing about whether the harness will actually let you `Edit`/`Write`/`MultiEdit`/`NotebookEdit` a file there — that's a *separate* per-session guard, gated on the harness's own "background isolation" state, which is orthogonal to `cwd`.

## Why this exists

Issue [#895](https://github.com/mattsears18/shipyard/issues/895) found this guard rejects every write from a `Workflow`-substrate-dispatched worker in **both** of the orchestrator's possible isolation states — a catch-22 neither [#486](https://github.com/mattsears18/shipyard/issues/486) nor [#825](https://github.com/mattsears18/shipyard/issues/825) had covered, since both of those only tested (or only needed to fix) the cwd itself:

- **Parent session not yet isolated** — every write is refused outright: `This subagent's parent bg session hasn't isolated yet, so writes to the shared checkout are blocked. Re-spawn this agent with isolation: "worktree", or have the parent call EnterWorktree before spawning.`
- **Parent session isolated via `EnterWorktree`** — every write is refused too, but the guard's own suggested fix is unreachable: it silently redirects to the *orchestrator's* worktree instead of the worker's: `This session is now isolated in <orchestrator worktree path>. Edit the worktree copy of this file instead of the shared-checkout path.`

Neither state is fixable from inside a worker dispatch, and there is no sanctioned workaround: a Bash-write workaround (writing files via `Bash` instead of `Edit`/`Write`, since the guard only covers the latter) was tried in #895's repro and the *dispatch instructing it* was independently refused by the harness's own permission classifier as an isolation-guard bypass. Do not attempt it.

**Under the default `Agent`-tool dispatch shape** (`isolation: "worktree"`, restored as the default in [#830](https://github.com/mattsears18/shipyard/issues/830)) neither state occurs — the harness provisions and owns the worktree directly, so this probe is a cheap no-op there. It is load-bearing only when a dispatch actually used the documented `Workflow`-substrate **alternate** shape (`dispatch-rules.md`'s "Workflow-substrate dispatch — an alternate dispatch shape").

## Write-capability probe

Implementing the entire fix and only discovering the write-block at the final commit wastes the whole dispatch (#895's repro: ~150k tokens, ~6 minutes, on one such dispatch). Probe first:

Use the `Write` tool itself — not `Bash` — to write a small scratch file inside your own worktree (`<WORKTREE_PATH>/.shipyard-write-probe`). Using `Write` is the point: `Bash` writes are not covered by this guard at all and would tell you nothing about whether `Edit`/`Write` will work later in the dispatch, when you actually need them.

- **Succeeds** → the harness will let you write here for the rest of the dispatch. Leave the probe file or overwrite it — it's an untracked dotfile, so the step-5 `git add <specific paths>` (never `-A`) never picks it up. Proceed with the dispatch normally.
- **Rejected** with either harness error text above → you are in the confirmed-non-functional state #895 documents. Do not retry the probe (it will not resolve) and do not fall back to a `Bash`-write workaround (see above — that path is refused independently). Return immediately, without doing any further work:

  > `blocked: workflow-substrate dispatch cannot write files — harness bg-isolation write guard rejected Edit/Write in this session (see #895); re-dispatch via the Agent-tool default shape ("isolation": "worktree")`

This is a `blocked:` return, not `reaped:` — like the [#486](https://github.com/mattsears18/shipyard/issues/486) cwd-mispin case, the failure is a deterministic property of *this dispatch's* isolation state, not retryable infrastructure noise. The orchestrator's reconcile classifies it into `needs-human-review` per [#521](https://github.com/mattsears18/shipyard/issues/521), surfacing the harness-level limitation for a human rather than silently re-enqueueing a dispatch that would fail the identical way.

## Scope

Run both checks, in order: the [step-0 cwd fail-fast](./SKILL.md#step-0-cwd-fail-fast--assert-youre-actually-in-your-worktree-486) first (cheap, `Bash`-only, catches a mispinned working directory per #486), then this probe (confirms the write path itself, per #895). Passing one does not imply passing the other — they guard two independent harness mechanisms.

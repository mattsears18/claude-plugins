---
name: mode-shim-preamble
description: Shared scaffold every /shipyard:do-work mode-shim agent (`shipyard:issue-worker` and its six per-mode siblings — fix-checks-worker, fix-rebase-worker, fix-main-ci-worker, fix-pr-batch-worker, investigate-worker, spike-worker) loads — the two-shape worktree-isolation contract, the identical worker-preamble bullet list, and the mode→shim→model mapping table. Referenced by all 7 agents instead of each re-inlining the same ~15-20 lines of boilerplate. Closes #879.
---

# Mode-shim preamble (every `/shipyard:do-work` mode-shim agent)

The scaffold every one of the seven `agents/issue-worker.md` + `agents/{fix-checks,fix-rebase,fix-main-ci,fix-pr-batch,investigate,spike}-worker.md` files shares, independent of which mode it dispatches. Each shim's own `.md` file references this skill by name instead of repeating the language verbatim, and keeps only what's genuinely unique to it: its frontmatter identity (`name`, `description`, `model` — **never** touched by this skill), its own model-choice reasoning sentence, its per-mode `--label shipyard` / auto-merge caveat bullets, its wrong-shim fail-safe string, and its "Per-mode spec" pointer to the canonical `agents/issue-worker/<mode>.md` file.

This skill composes with `shipyard:worker-preamble` (the actual rule bodies — worktree discipline, the hook-bypass prohibition, the auto-merge/snapshot pattern, the return-contract discipline) and with each mode's own per-mode file under `agents/issue-worker/`. Neither of those is owned by this skill; this skill owns only the *scaffold around* them — the parts of a shim's own `.md` file that were byte-for-byte (or near-byte-for-byte) identical across all seven regardless of mode.

## Worktree isolation contract — the two dispatch shapes

**However a shim was dispatched, it must be running in an isolated git worktree.** `shipyard:worker-preamble` § "Worktree discipline" is the single source of truth for the *rules that follow* from that; this section is the single source of truth for *which dispatch shape produced the isolation* and how each shape guarantees it:

- **`Agent` tool (the default shape for all seven modes, as of [#825](https://github.com/mattsears18/shipyard/issues/825); also how a human hand-dispatches any shim, and how `shipyard:verify-worker` is always dispatched).** Must carry `isolation: "worktree"` — agent-definition frontmatter has no `isolation:` field, so the caller is responsible. The harness provisions and cwd-pins the worktree in response. [`hooks/enforce-worktree-isolation.sh`](../../hooks/enforce-worktree-isolation.sh) hard-fails a dispatch of any guarded shim that omits it. A new worktree-isolated `Agent`-dispatched worker must be added to the hook's guarded set in lockstep (see the file header for the list).
- **`Workflow` substrate (an alternate shape, restorable on evidence — see [#825](https://github.com/mattsears18/shipyard/issues/825)).** The Dynamic Workflows `agent()` primitive has no isolation option, so the orchestrator pre-provisions the worktree with `git worktree add` and passes the path as the work unit's `worktreePath`; the dispatch prompt's first instruction is a `cd` into it. **Anchor there before any other tool call**, then run the step-0 verification. A prompt that supplies no worktree path is a caller bug — return `blocked` with stage `worktree-anchor` rather than working from an unpinned cwd. The same hook hard-fails such a dispatch before it starts.

Either way, this shim's own `subagent_type` (its frontmatter `name:` — e.g. `shipyard:fix-checks-worker`) is what the hook's guarded set matches against, and what `/shipyard:do-work`'s default `Agent`-tool dispatch names directly. **`/shipyard:do-work` dispatches this shim by name again, as the default shape ([#825](https://github.com/mattsears18/shipyard/issues/825)).** This shim was briefly not a dispatch target ([#791](https://github.com/mattsears18/shipyard/issues/791), when the orchestrator routed every `mode:`-driven worker through the `Workflow` substrate exclusively), and [#825](https://github.com/mattsears18/shipyard/issues/825) restored the `Agent`-tool path as the default after the `Workflow` substrate proved unable to complete a single file write (see [`dispatch-rules.md`](../../commands/do-work/dispatch-rules.md#agent-tool-dispatch--the-default-dispatch-shape-825) for the repro). The `Workflow` substrate ([`workflows/do-work-dispatch.workflow.js`](../../workflows/do-work-dispatch.workflow.js)) remains a documented alternate shape, whose `agent()` primitive takes no `subagent_type` — it pre-provisions the worktree and passes the path as `worktreePath` instead, and the built prompt's first instruction is a `cd` into it. Either way, the `isolation: "worktree"` requirement applies to the default `Agent`-tool shape, and the hook enforces it.

**Not every worker shim in this plugin needs worktree isolation.** [`shipyard:decompose-worker`](../../agents/decompose-worker.md) is a related but structurally different agent — it decomposes a confirmed epic into sub-issues via read-only codebase inspection plus GitHub API writes, never touches code, and is deliberately dispatched via the `Agent` tool **without** `isolation: "worktree"` and **without** a `mode:` value. It is not an eighth row in the mapping below and must not be added to `enforce-worktree-isolation.sh`'s guarded set — see that file's own "Why a separate agent file" section for the reasoning.

## Shared worker-preamble bullets

Every shim's own "Shared rules — load first" section keeps this identical lead-in and close, plus its own bullet list built from `shipyard:worker-preamble`:

> Before doing anything else, **load the `shipyard:worker-preamble` skill**. That skill carries the rules every worker mode shares:
>
> - Worktree discipline (never `cd` outside your worktree; never use `gh pr checkout`; never `git switch` to the default branch on return).
> - The worktree-reaped escape hatch (`WORKTREE_PATH` capture + pre-write directory check).
> - The absolute prohibition on `--no-verify` / `--no-gpg-sign` / `--no-commit-hooks` / any hook-bypass flag.
> - The return-contract discipline (no narrative status updates; run everything synchronously to a terminal state before returning).
>
> The worker-preamble skill is the single source of truth for those rules.

The four bullets above are identical across all seven shims and are the ones this skill standardizes. **Two more bullets belong in each shim's own file, not here** — the `--label shipyard` requirement and the auto-merge/snapshot pattern — because their wording carries genuine per-mode content (e.g. fix-checks-only is the one mode that DOES `--watch` CI; fix-rebase and fix-checks-only never open a *new* PR at all; spike's bullet covers both `gh pr create` and `gh issue create`). Keep those two in the agent file, sandwiched between the lead-in and the close above.

## Mode → shim → model mapping

Claude Code subagents take their model from frontmatter — the `model:` field is read once per agent definition and applies to every invocation of that subagent. `shipyard:issue-worker`'s router handles `mode: issue-work`; each sibling shim exists so its mode can run on the model best fit for its workload, while the per-mode behavioral spec stays in one place (`agents/issue-worker/<mode>.md`).

| Mode                     | Shim agent                     | Model  | Reason                                                                                                          |
|--------------------------|---------------------------------|--------|-------------------------------------------------------------------------------------------------------------------|
| `issue-work`             | `shipyard:issue-worker`         | default (session model) | Full reasoning required — implement, test, ship a PR. Carries no `model:` frontmatter; the effective default comes from the resolved `models.issue_work` config value the orchestrator passes as the dispatch's `model` param. |
| `fix-checks-only`        | `shipyard:fix-checks-worker`    | haiku  | Pattern-match the failing log, apply targeted fix. |
| `fix-rebase`             | `shipyard:fix-rebase-worker`    | sonnet | Conflict-resolution judgment (stale-vs-semantic), not just git mechanics — Haiku mis-judged it ([#854](https://github.com/mattsears18/shipyard/issues/854)). |
| `fix-main-ci`            | `shipyard:fix-main-ci-worker`   | sonnet | Broader investigation (no PR context to anchor the failure). |
| `fix-failing-prs-batch`  | `shipyard:fix-pr-batch-worker`  | sonnet | Cross-PR pattern-spotting across up to 5 representative failures. |
| `investigate`            | `shipyard:investigate-worker`   | sonnet | Disposition judgment (fix / needs-human-review / auto-close) with no PR context to anchor it. |
| `spike`                  | `shipyard:spike-worker`         | none (session default; Fable 5 opt-in via `models.spike`) | Open-ended design-doc authorship and feasibility judgment — the same reasoning tier `issue-work` needs, not the narrow pattern-matchable shape the five cost-optimized shims are tuned for. |

If a cost-optimized shim's success rate drops measurably (contract-violation rate climbs, its mode's attempt cap fires more often), bump that shim's `model:` field up a tier. The escalation-fallback pattern (cheap tier → expensive tier on retry) is a follow-up, not implemented here.

## What this skill does NOT cover

- **Frontmatter** (`name`, `description`, `model`) — each shim's registered identity as a dispatchable `subagent_type`. Never move this into a skill; the orchestrator and hand dispatches bind to the exact `subagent_type` string, and `enforce-worktree-isolation.sh`'s guarded set matches against it too.
- **The per-mode behavioral spec** (`agents/issue-worker/<mode>.md`) — the issue-handling lifecycle, fix-loop semantics, trivial-conflict-or-bail policy, author-trust gating, return-string vocabulary. That's the entire point of having seven separate agents rather than one generic one.
- **The wrong-shim fail-safe string** (`blocked: wrong shim — <name> dispatched for mode <X>; refusing to guess`) — each shim's own literal name is load-bearing content, kept in the agent file.
- **The `--label shipyard` and auto-merge/snapshot bullets** in each shim's "Shared rules" section — see "Shared worker-preamble bullets" above for why these two stay per-file.
- **The per-mode model-choice reasoning sentence** (why *this* mode gets *this* tier, beyond the one-line table reason above) — each shim keeps its own fuller paragraph when it has one (e.g. `fix-rebase-worker`'s #854 postmortem, `spike-worker`'s "why no model pin" essay). The table here is the quick-reference; the fuller narrative is domain content that stays put.

When in doubt: if a line's content differs meaningfully by mode, it stays in the agent file; if it's identical scaffold regardless of mode, it belongs here.

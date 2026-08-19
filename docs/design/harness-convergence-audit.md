# Harness convergence audit — what Claude Code now owns, and what shipyard must stop duplicating

**Date:** 2026-08-18
**Harness measured against:** Claude Code **v2.1.234** (installed locally)
**Primary sources:** [`code.claude.com/docs/en/worktrees`](https://code.claude.com/docs/en/worktrees), [`code.claude.com/docs/en/sub-agents`](https://code.claude.com/docs/en/sub-agents), the [`anthropics/claude-code` CHANGELOG](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)

## Why this document exists

Shipyard grew during an era when the harness provided none of the isolation, lifecycle, or containment guarantees an autonomous multi-agent loop needs. It built them itself. The harness has since shipped its own versions of nearly all of them — and shipyard kept its scaffolding, because **nothing in the repo ever asks whether a rule is still necessary.**

Every failure in shipyard's history was attributed to *"missing instruction."* Never to *"the model was worse then"* or *"the harness didn't support this yet."* So every incident added a rule and nothing ever expired. This audit is the missing expiry pass.

The governing principle from here on:

> **Do not reimplement, wrap, or police anything the harness already guarantees. When the harness and shipyard both enforce a rule, delete shipyard's copy.**

## Part 1 — What the harness now provides

### 1.1 Worktree isolation is declarative

`isolation: worktree` is a **supported frontmatter field on a subagent definition**:

```yaml
---
name: refactorer
description: Applies mechanical refactors across many files
isolation: worktree
---
```

Shipyard's specs asserted the opposite — `verify-worker.md` stated *"agent-definition frontmatter doesn't support an `isolation:` default, so the caller is responsible."* **That is now false**, and it was the entire load-bearing justification for the `enforce-worktree-isolation.sh` PreToolUse hook.

### 1.2 The harness enforces containment with four checks

Quoting the worktrees documentation directly — while a session or subagent is isolated:

| Check | What it blocks |
|---|---|
| **File edits** | An `Edit`, `Write`, or `NotebookEdit` targeting a path in the main checkout |
| **Command working directory** | A Bash/PowerShell/Monitor command whose cwd resolves to the main checkout, or that can't be verified to stay outside it |
| **Git redirects** | A command redirecting git into the main checkout via `git -C`, `--git-dir`, `GIT_DIR`, `GIT_WORK_TREE`, or a `cd` into the main checkout |
| **Command shape** | Any Bash/Monitor command it can't statically verify stays inside the worktree — explicitly including **brace expansion** and **heredocs with unquoted delimiters**. *"You can't turn this check off."* |

Enforcement *"covers every subagent Claude spawns from the isolated session"* and applies interactively and in the background.

**This is a superset of what shipyard's isolation hooks enforced.**

### 1.3 The command-shape refusal is now documented behavior

Shipyard carried a 228-line reverse-engineered controlled experiment (`bash-refusal-triggers.md`, a lettered A–L test matrix) establishing that `"${VAR}/x"` is refused while `"$VAR/x"` is allowed. It took four consecutive issues (#1182 → #1277 → #1289 → #1291), each misdiagnosing the axis, to isolate.

That behavior is now one documented paragraph. **Reverse-engineered notes on undocumented harness internals are a liability, not an asset** — they cannot be kept accurate, and no shipyard test can detect their drift. Cite the doc; never re-derive it.

### 1.4 Worktree reaping is a harness-owned periodic sweep

- Each subagent worktree is **auto-removed** when the subagent finishes without changes.
- A **periodic sweep** removes subagent and background-session worktrees older than `cleanupPeriodDays`, skipping any that still hold work (changed/untracked files, unpushed commits).
- Claude runs `git worktree lock` on a worktree while its agent runs, **releasing it when the agent finishes**.
- **The sweep releases the lock of a session whose process has exited** (v2.1.210), so a killed background session no longer strands a locked worktree.

That last point is decisive. `worktree-reap.sh` (4,311 lines) exists, per its own header, because *"the harness writes the orchestrator's PID into every dispatched agent's lock file … a strict liveness check defers EVERY worktree the orchestrator itself owns."* It parses Claude Code's internal lock-file format and walks `/proc` ancestry to work around that. **The harness now handles stale-lock release itself.**

### 1.5 Subagent frontmatter replaces hand-rolled dispatch plumbing

| Frontmatter field | Replaces |
|---|---|
| `isolation: worktree` | the dispatch-side enforcement hook |
| `model` (alias or full id; `inherit` default) | per-mode shim files that exist only to pin a model |
| `effort` (`low`…`max`) | prose asking for more/less deliberation |
| `maxTurns` | hand-rolled turn budgets |
| `permissionMode` | prose about what to auto-accept |
| `skills` | prose instructing a worker to "load skill X first" |
| `memory`, `background`, `mcpServers`, `disallowedTools` | assorted bespoke wiring |

Model aliases resolve to *"the newest allowed version of that family"* — so `model: opus` auto-tracks the current Opus and cannot go stale the way a pinned `claude-opus-4-8` did.

### 1.6 Other convergence worth noting

- **Concurrency cap**: subagents are capped at a default of 20 concurrent (v2.1.217).
- **Nested subagents**: depth 3 by default (v2.1.221).
- **Transcript retention**: subagent transcripts persist separately and auto-delete per `cleanupPeriodDays`.
- **Auto-compaction**: applies to subagents with the same logic as the main conversation.
- **Destructive-git containment**: v2.1.210 and v2.1.222 specifically fixed worktree-isolated subagents being able to run git-mutating/destructive commands against the main repo.
- **Todo/task tools** are no longer served to Opus 4.8, Sonnet 5, and newer models (v2.1.232).

## Part 2 — The cut list

Verdicts: **CUT** (harness-owned, delete), **THIN** (partially redundant), **KEEP** (genuinely shipyard's job).

### Tier 1 — isolation enforcement (this PR)

| Surface | Lines | Verdict | Harness replacement |
|---|---|---|---|
| `hooks/enforce-worktree-isolation.sh` + test | 615 | **CUT** | `isolation: worktree` frontmatter (§1.1) |
| `hooks/enforce-edit-scope.sh` + test | 412 | **CUT** | file-edit check (§1.2) |
| `scripts/assert-worktree-cwd.sh` + tests | 485 | **CUT** | cwd check (§1.2) |
| `commands/do-work/bash-refusal-triggers.md` | 228 | **CUT** | documented command-shape check (§1.3) |
| `skills/worker-preamble/compound-command-refusal.md` | 83 | **CUT** | same |

Replaced by: `isolation: worktree` added to all 8 worker/verifier agent definitions, and a short pointer to the official docs.

**Finding turned up while executing the cut:** `enforce-worktree-isolation.sh` was wired in `hooks.json` under the **`Agent` matcher only**. Roughly half the script — its `Workflow`-substrate branch, which blocked a work unit carrying no `worktreePath` — could therefore never fire in production; it was exercised solely by `legacy-agent-dispatch-retired-791.test.sh` calling the script directly. That is a worked example of the failure mode this audit is about: a guard with its own test suite, cited across several spec files as a live guarantee, that the harness never actually invoked. **A test that calls a hook directly proves nothing about whether the hook is wired.**

### Tier 2 — worktree reaping (shipped 4.46.0)

Four of the surfaces the first draft of this table marked **CUT** were re-examined during execution and **kept** — one of them only after the cut had already been made and a dangling-subcommand scan caught the dependency. Recording both the verdicts and the reversals, because the reversals are the more useful record:

| Surface | Lines | Verdict |
|---|---|---|
| `worktree-reap.sh` sweeping subcommands — `sweep-stale-agents`, `reap-orphan-orchestrators`, `reap-session-worktrees`, `sweep-tombstones` | 662 | **CUT** — the harness's periodic sweep removes subagent and background-session worktrees and releases the locks of exited sessions (§1.4) |
| `reap-stale` + `classify-all` | 651 | **CUT, then RESTORED.** `disk-space-guard.md` reuses `reap-stale` as its *mid-session* reclamation valve under live disk pressure. Deleting it leaves the guard able to detect a full disk but not reclaim. The *scheduled* session-start pass (step 3b) is what the harness supersedes; the on-demand mechanism is not. **Found by a dangling-subcommand scan, not by the 164-suite run** — the same blind spot as [#1467](https://github.com/mattsears18/shipyard/issues/1467). |
| their test sections in `worktree-reap.test.sh` | 930 | **CUT** |
| setup steps 1.6.5 + 3b, `01d-orphan-orchestrator-worktree-reap.md`, `cleanup-summary.md` step 3.0 | ~200 | **CUT** — the orchestrator no longer runs sweeps the platform runs for it |
| `classify-lock` + its PID/ancestry helpers | 436 | **KEPT — needs ablation, not argument.** This is the *gate* that prevents removing a worktree a live peer owns. Every other cut here makes shipyard *stop removing things* (worst case: worktrees linger a little longer until the harness sweep). Removing this gate would make shipyard remove things *less carefully* — worst case is destroyed work. Different risk class, different evidence bar. |
| `crash-recovery-reap.sh` + test | 1,090 | **KEPT.** Its header marks it load-bearing crash recovery, and its invariant is "never reap before inspecting" — a worker can stop mid-flight with a correct, uncommitted diff on disk. It *recovers* work, not merely removes worktrees; the harness sweep skips such worktrees but does not surface them. |
| `session-end-reap.sh` + `hooks/reap-on-session-end.sh` | 277 | **KEPT.** v1 scope is stale `worktree-agent-*` **branch refs**, not worktree directories. The harness sweep removes directories and never touches git refs, so there is no overlap at all — the first draft of this table was simply wrong about what this script does. |
| `{pre-dispatch,drain-pre-dispatch,shipped-immediate}-branch-reap.sh` | 947 | **KEPT** — branch deletion, plus they consume `classify-lock` |

**The line that actually matters, generalized:** *cut the machinery that stops doing something; keep the machinery that stops something bad from happening, until you have evidence.* Three of the four keeps above are on that side of the line.

### Tier 3 — model-capability scar tissue (needs ablation evidence, not argument)

| Surface | Lines | Verdict |
|---|---|---|
| `skills/worker-preamble/` (22 fragments) | 1,784 | **THIN hard** — most teach a frontier model habits it already has |
| 28 `assert-*`/`detect-*`/`verify-*` "behavior police" scripts | 6,249 | **THIN** — each needs an ablation run to justify |
| per-mode shim agents (7 files) | — | **THIN** — they exist mostly to pin a model, which frontmatter now does |

### KEEP — genuinely shipyard's job

These are **coordination** problems, not intelligence or isolation problems. A better model and a better harness do not obsolete them:

- Label routing, gate labels, the binary backlog
- Trust boundaries for untrusted authors; `refuse-credential-mint.sh`
- Auto-merge policy and the version-coordination protocol
- The worker-return schema and structured reconcile (subagents have **no** native structured output)
- Cross-session bookkeeping: cost ledger, flake registry, session state
- `hooks/guard-primary-checkout.sh` — **initially cut, then restored.** The harness's four checks apply only *while a session is already isolated in a worktree*. This hook covers the case they never reach: a session working **directly in the primary checkout** with no worktree at all (the #482 collision). Not redundant; keep.
- `refuse-broad-process-kill.sh` (no harness equivalent)
- `git-stash-prohibition` — the stash stack is shared across worktrees via the common `.git`, which the harness explicitly *permits* writes to

## Part 3 — The standing rule

Add to the repo's conventions, and apply on every harness/model upgrade:

1. **Before adding a rule, check whether the harness already enforces it.** If it does, the correct change is zero lines.
2. **Never encode undocumented harness internals.** If behavior isn't in the docs, file an upstream question — don't reverse-engineer it into the spec.
3. **Every guard must name what it catches that the harness doesn't.** A guard that can't answer that is deleted.
4. **Re-run this audit on every Claude Code minor and every model generation.** Convergence is continuous; the spec must shrink as the platform grows.
5. **Prefer ablation to argument.** To decide whether a rule is still needed, delete it and run a real session. Evidence, not prose.

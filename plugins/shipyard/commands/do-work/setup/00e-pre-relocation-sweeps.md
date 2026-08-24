# /shipyard:do-work — Setup phase · pre-relocation sweeps

**Setup sub-phase fragment, loaded from [`00-config-worktree.md`](./00-config-worktree.md)'s step-0.45 pointer — part of the ordered per-session walk, not a conditional deep-link.** Runs BEFORE step 0.5's `EnterWorktree` relocation, while cwd is still the primary checkout. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`00-config-worktree.md`](./00-config-worktree.md) (steps 0.3 → 0.4). Next: back to [`00-config-worktree.md`](./00-config-worktree.md#05-move-into-the-orchestrators-worktree) for step 0.5.

### 0.45 Pre-relocation: session-state init + the worktree-cross-referencing sweeps ([#1202](https://github.com/mattsears18/shipyard/issues/1202))

**Run this BEFORE `EnterWorktree` ([step 0.5](00-config-worktree.md#05-move-into-the-orchestrators-worktree)) — while cwd is still the primary checkout and the harness's worktree-isolation guard has not yet activated for this session.** Registering isolation activates the guard that refuses a `git -C <other-worktree>` command, which is what a cross-worktree sweep is built from. Running the sweep first sidesteps the conflict entirely. See [#1202](https://github.com/mattsears18/shipyard/issues/1202) for the original repro.

**Worktree *reaping* is no longer shipyard's job — only branch triage is.** Claude Code runs its own periodic sweep that removes subagent and background-session worktrees once they pass `cleanupPeriodDays`, skips any that still hold work (changed or untracked files, unpushed commits), holds a `git worktree lock` for the lifetime of each running agent, and releases the lock of a session whose process has exited. That last guarantee is the one shipyard's own stale-worktree machinery existed to work around. The two sweeps that used to run here — the orphan orchestrator-worktree reap (former step 1.6.5) and the stale agent-worktree reap (former step 3b) — were **deleted** rather than kept as a redundant second implementation. See [`docs/design/harness-convergence-audit.md`](../../../../../docs/design/harness-convergence-audit.md) for the full verdict and [Claude Code's worktree cleanup](https://code.claude.com/docs/en/worktrees#clean-up-subagent-and-background-session-worktrees) for the guarantee itself.

**What remains here is branch work, which the harness never touches.** Git *branches* are outside the harness's sweep entirely — it removes worktree directories, never refs. So the orphan `do-work/*` branch triage (step 3c) stays, along with the session-state initialisation the ordered walk below depends on.

Run, in this exact order, all still resolving `CLAUDE_PLUGIN_ROOT` via the **pre-relocation** compound preamble ([00-config-worktree.md's step 0.3](00-config-worktree.md#03-claude_plugin_root-re-export-preamble-every-bash-tool-call)'s form — the post-relocation `.shipyard-plugin-root` stash doesn't exist yet at this point in the session) and `<session-id>` directly (no `.shipyard-session-id` stash needed either — that's a [step 0.55](00f-session-id-storage.md#055-session-id-storage-per-worktree-not-tmp) artifact written after relocation; the id itself is already known as the current Claude Code session identifier, independent of any file):

1. **[Step 1](01-repo-recovery.md#1-resolve-repo--user)** — resolve `<owner/repo>`, the `gh`-authenticated user, and `<default-branch>`. Cache all three.
2. **[Step 1.3](01-repo-recovery.md#13-detect-the-silent-direct-merge-repo-shape-admin--ungated-merge-config)** — the ungated-merge-shape detector + `$EFFECTIVE_CONCURRENCY` clamp.
3. **[Step 1.36](01-repo-recovery.md#136-detect-ci-executor-pool-capacity-and-clamp-toward-it-1141)** — the CI-runner-pool detector + second `$EFFECTIVE_CONCURRENCY` clamp.
4. **[Step 1.5](01-repo-recovery.md#15-initialise-the-session-state-file)** — `session-state.sh init` + the `.ci_capacity` write-through.
5. **[Step 3c](01c-label-recovery-refine.md#3c-orphan-worktree-triage)** — the orphan `do-work/*` branch triage, via `worktree-reap.sh triage-orphan-branches` ([#1365](https://github.com/mattsears18/shipyard/issues/1365)), as **two** calls: a `--dry-run` plan first, then the real sweep ([#1518](https://github.com/mattsears18/shipyard/issues/1518)). Run both here **synchronously (foreground), not backgrounded** — a foreground call keeps the pre-relocation ordering trivially verifiable rather than depending on a background job's survival across the later `EnterWorktree` call. **The `--max-prs` cap is what makes that foreground requirement obtainable at all**: before #1518 the sweep's runtime was a function of the candidate set size with no bound, so on any repo with an accumulated backlog it exceeded the 120s foreground timeout, got moved to the background, and kept opening and arming PRs *after* the tool call had returned — across exactly the `EnterWorktree` boundary this step exists to stay on one side of.

**Literal invocation for step 5 ([#1455](https://github.com/mattsears18/shipyard/issues/1455)).** Deriving the call from prose alone costs one refused tool call per mismatch, every session. `worktree-reap.sh`'s own top-level `usage()` block (`-h`/`--help`) is the normative source if this drifts.

Resolve `<repo-root>` once, as its own plain `Bash` call, and reuse the literal path it returns (shell variables don't survive across separate `Bash` tool calls):

```bash
git rev-parse --show-toplevel
```

`<owner/repo>` and `<default-branch>` are already known from [step 1](01-repo-recovery.md#1-resolve-repo--user) above.

**Step 5 — `triage-orphan-branches`.** Requires `--repo-root`, `--repo`, AND `--default-branch` — it needs the default branch to diff each candidate worktree against, and `--repo` to open/query PRs. `--session-id` is accepted-and-ignored here for CLI symmetry (issue [#1400](https://github.com/mattsears18/shipyard/issues/1400)) but is NOT required — omit it or pass it, either is fine.

**5a — the dry-run plan (read-only, always first).** Performs no writes at all; prints the candidate count, then one `[k/N] <action> <branch> — <why>` line per candidate:

```bash
<plugin-root>/scripts/worktree-reap.sh triage-orphan-branches --repo-root <repo-root> --repo <owner/repo> --default-branch <default-branch> --dry-run
```

**Read the plan before running 5b.** The `candidates: <N>` header is the blast radius, knowable *before* the first write rather than reconstructed afterwards from the terminal `summary:` line. A plan that looks wrong for the repo — dozens of `salvage` rows on a repo you expect to have one or two stranded branches — is a signal to stop and inspect by hand, not to proceed. That is the judgment call the pre-#1518 shape gave nowhere to make.

**5b — the real sweep.** Bounded by `--max-prs` (default **3**), and every salvaged PR is opened as a **draft with auto-merge not armed**:

```bash
<plugin-root>/scripts/worktree-reap.sh triage-orphan-branches --repo-root <repo-root> --repo <owner/repo> --default-branch <default-branch>
```

Do **not** pass `--max-prs 0` (unlimited) or `--arm-auto-merge` from this call site. Both exist for a human running the sweep by hand against a repo they are actively watching; neither is appropriate for an unattended pre-dispatch sweep, which is the exact shape [#1518](https://github.com/mattsears18/shipyard/issues/1518) exists to bound.

If 5b's output ends with a `cap-reached: <N> candidate(s) remaining, not actioned; ...` line, that is **normal and expected** on a repo with an accumulated backlog — not an error, and not something to retry with a raised cap in the same session. The un-actioned worktrees are untouched and a later session's sweep picks them up. Note the count in the session log and continue to step 0.5.

Salvaged PRs are drafts, so they are invisible to [drain's own open-PR query](../drain.md) (which filters `-is:draft`): they neither stall the drain loop nor get landed by its deferred-merge lander. A human marks one ready for review after auditing the branch it salvaged.

The caller must resolve `--repo-root` in its own, separate `Bash` call rather than in the same block as either sweep invocation — a data-flow-dependent refusal risk documented in [Claude Code's command-shape check](https://code.claude.com/docs/en/worktrees#how-claude-code-enforces-isolation).

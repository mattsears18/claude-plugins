On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "Never `git stash`"). Load this only if you are actually about to run `git stash` — most dispatches never reach for it at all, since the core rule (you have your own isolated worktree and your own branch, so there is never a legitimate reason to stash) is the correct default. This fragment is the mechanism explanation plus the one narrow, isolating procedure for the rare case stashing is genuinely unavoidable.

## The mechanism, so this is understood rather than merely obeyed

(and so a future editor doesn't relax the prohibition in `SKILL.md`)

Worktree isolation covers *checkouts* — every worker's `git worktree add`'d directory has its own working tree and its own branch. It does **not** cover `git stash`: every stash entry lives under `refs/stash` in the shared `.git` — the **common** dir every linked worktree shares (the same `git-common-dir` the step-0 cwd fail-fast reads to detect a primary-checkout mispin). So the stash stack is not per-worktree, not per-branch, not per-dispatch — it is one shared LIFO stack visible to and mutable by **every concurrent worker in the repository**. A bare `git stash pop` always takes `stash@{0}`, regardless of who pushed it — on any session running `--concurrency > 1`, popping is a coin flip over whichever worker pushed most recently.

**Both failure directions are silent, and worse than the worktree-reap hazard in [#838](https://github.com/mattsears18/shipyard/issues/838)/[#841](https://github.com/mattsears18/shipyard/issues/841)** (there, a crashed worker at least leaves a completion notification to inspect or a leftover directory to recover from; here there is neither): **silent contamination** — you pop another worker's stash, don't notice, and commit + push its in-progress changes inside your own PR (the changes are usually locally valid, so CI passes and the PR auto-merges, landing unrelated work under the wrong issue with the wrong `Closes` reference); or **silent data loss** — you pop another worker's stash, decide the diff looks like "unrelated junk" left over in a recycled worktree slot, and `git restore` it away, destroying the victim worker's uncommitted work with nothing left to recover.

## If stashing is genuinely unavoidable

(rare enough that you should be able to name why your own worktree + branch aren't sufficient before reaching for this), use the isolating form and never the bare pop:

```bash
# Push with an identifying message — never a bare `git stash` / `git stash push` with no -m.
git stash push -m "<agent-id-or-issue-N>: <reason>"
# Pop by EXPLICIT ref resolved from that message — never bare `git stash pop`, which always takes stash@{0} regardless of who pushed it.
git stash list
# → find the entry whose message matches your own <agent-id-or-issue-N>, note its ref (e.g. stash@{2})
git stash apply stash@{2}   # apply, not pop — leaves the entry in the stack until you confirm
# ... verify the working tree now matches what you expect, then only ...
git stash drop stash@{2}    # after confirming it's yours and applied cleanly
```

`apply`-then-`drop` by matched ref is the only safe shape. Bare `git stash pop` is never acceptable in a worker dispatch, even as a "just this once" shortcut — it operates on `stash@{0}` unconditionally, which may belong to a different, still-running worker.

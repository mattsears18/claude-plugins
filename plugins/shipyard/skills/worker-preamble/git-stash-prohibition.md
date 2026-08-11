On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "Never `git stash`"). Load this only if you are actually about to run `git stash` — most dispatches never reach for it at all, since the core rule (you have your own isolated worktree and your own branch, so there is never a legitimate reason to stash) is the correct default. This fragment is the mechanism explanation plus the one narrow, isolating procedure for the rare case stashing is genuinely unavoidable.

## The mechanism, so this is understood rather than merely obeyed

(and so a future editor doesn't relax the prohibition in `SKILL.md`)

Worktree isolation covers *checkouts* — every worker's `git worktree add`'d directory has its own working tree and its own branch. It does **not** cover `git stash`: every stash entry lives under `refs/stash` in the shared `.git` — the **common** dir every linked worktree shares (the same `git-common-dir` the step-0 cwd fail-fast reads to detect a primary-checkout mispin). So the stash stack is not per-worktree, not per-branch, not per-dispatch — it is one shared LIFO stack visible to and mutable by **every concurrent worker in the repository**. A bare `git stash pop` always takes `stash@{0}`, regardless of who pushed it — on any session running `--concurrency > 1`, popping is a coin flip over whichever worker pushed most recently.

**Both failure directions are silent, and worse than the worktree-reap hazard in [#838](https://github.com/mattsears18/shipyard/issues/838)/[#841](https://github.com/mattsears18/shipyard/issues/841)** (there, a crashed worker at least leaves a completion notification to inspect or a leftover directory to recover from; here there is neither): **silent contamination** — you pop another worker's stash, don't notice, and commit + push its in-progress changes inside your own PR (the changes are usually locally valid, so CI passes and the PR auto-merges, landing unrelated work under the wrong issue with the wrong `Closes` reference); or **silent data loss** — you pop another worker's stash, decide the diff looks like "unrelated junk" left over in a recycled worktree slot, and `git restore` it away, destroying the victim worker's uncommitted work with nothing left to recover.

## The substitute — lead with a WIP commit, not a stash

`SKILL.md`'s prohibition now pairs with this substitute inline, but the reasoning behind *why it's the right default* lives here. Issue [#1224](https://github.com/mattsears18/shipyard/issues/1224) found two workers in one session reaching for a bare `git stash`/`git stash pop` anyway — both had internalized "don't stash" but not "do this instead," so under time pressure the reflexive command won. In your own isolated worktree, on your own branch, `git commit` is strictly safer than any stash form and needs zero coordination with peers: `git commit -m "wip: <why>"` to set changes aside, `git reset --soft HEAD~1` to get them back unstaged when you're ready. To diff against a clean tree without moving anything, `git diff -- <path>` or `git show origin/<default>:<path>` never touches the working tree at all. Reach for an actual stash only when neither of those covers the need.

## If stashing is genuinely unavoidable

(rare enough that you should be able to name why a WIP commit isn't sufficient before reaching for this), use the isolating form and never the bare pop:

```bash
# Push with -u (captures untracked files too) and an identifying message —
# never a bare `git stash` / `git stash push` with no -m.
git stash push -u -m "<agent-id-or-issue-N>: <reason>"
# Capture the entry's SHA by tag, not by position — positions shift as peers push/drop.
git stash list --format='%H %gs'
# → find the line whose message matches your own <agent-id-or-issue-N>, note its SHA
git stash apply <sha>   # apply by SHA, not pop, and never by stash@{n} position — leaves the entry in the stack until you confirm
# ... verify the working tree now matches what you expect, then only ...
git stash drop <sha>    # after confirming it's yours and applied cleanly; re-resolve stash@{n} from the SHA/tag if drop needs it, never assume a position
```

`apply`-then-`drop` by matched SHA/tag is the only safe shape. Bare `git stash pop` is never acceptable in a worker dispatch, even as a "just this once" shortcut — it operates on `stash@{0}` unconditionally, which may belong to a different, still-running worker. This is also the shape one of the #1224 workers recovered correctly with under real pressure: it matched its stash entry to its own branch HEAD, restored via `git stash apply <specific-sha>` — never a bare `pop` — verified the resulting diff was byte-identical to what it expected, and dropped only that one entry. That worked; reaching for the stash in the first place was still the avoidable step — the WIP-commit substitute above exists so the recovery is never needed at all.

# Spike: does `fix-rebase.md` §5.7's empty-diff guard miscount under a diff-rewriting proxy?

**Issue:** [#1336](https://github.com/mattsears18/shipyard/issues/1336)
**Date:** 2026-08-13
**Conclusion:** **Viable — and the guard was genuinely, live-vulnerable.** The issue filed itself as a P3 theoretical risk that its author *could not* reproduce against the spec's prescribed usage. That negative result was correct as far as it went, but incomplete: it tested a strict subset of the prescribed block. Testing the whole block reveals a second failure that turns the theoretical risk into a live one.

## Problem / question

`fix-rebase.md` §5.7 is the worker-side root fix for [#646](https://github.com/mattsears18/shipyard/issues/646): a rebase whose conflict resolution silently discards the PR's entire change leaves an empty diff vs base, and force-pushing that state makes GitHub auto-close the PR with no error signal. The shipped work is simply lost.

The guard was prescribed as an inline snippet:

```bash
PRE_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH...origin/$HEAD_REF" | wc -l | tr -d ' ')
POST_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH" HEAD | wc -l | tr -d ' ')
if [ "${PRE_FILES:-0}" -gt 0 ] && [ "${POST_FILES:-0}" = "0" ]; then
  git rebase --abort 2>/dev/null || true
  echo "blocked rebase #<M>: rebase produced an empty diff (conflict resolution dropped the PR's change) — needs manual rebase"
  exit 0
fi
```

While investigating [#1333](https://github.com/mattsears18/shipyard/issues/1333) (a `git diff`-rewriting shell proxy — `rtk`, "Rust Token Killer" — silently rewriting `git diff` output in some worker environments), #1336's author found that this `--name-only | wc -l` pattern miscounts **when run in isolation**: a genuinely-empty diff counts as `1`, not `0`, so the `POST_FILES == 0` bail could never fire. But they could not reproduce it against the block as prescribed, and filed it as theoretical rather than folding a fix into #1333's PR.

**The question:** is §5.7 actually vulnerable as the spec prescribes it, or only in an artificial isolated-call variant?

## Method

Everything below was measured firsthand in a **worktree-isolated worker session** — the same environment a real `fix-rebase` dispatch runs in (`shipyard:fix-rebase-worker` is in [`enforce-worktree-isolation.sh`](../../plugins/shipyard/hooks/enforce-worktree-isolation.sh)'s guarded set). Every command was issued through the Bash tool exactly as a worker would issue it, because *the invocation shape is the variable under test* — running these from a normal terminal would not reproduce either effect.

## Findings

### 1. The isolated-call miscount reproduces — and is worse than reported

| Invocation (entirety of one Bash tool call) | Output | True answer |
|---|---|---|
| `git diff --name-only HEAD HEAD \| od -c` | `\n` (1 byte) | 0 bytes |
| `git diff --name-only HEAD HEAD \| wc -l` | `1` | `0` |
| `git diff --name-only HEAD~1 HEAD \| wc -l \| tr -d ' '` | `9` | `6` |

A `--name-only` result is not merely padded by one blank line when empty — against a **non-empty** diff the proxy appends a blank line, a `Changes:` header, and another blank line, inflating a true count of 6 to 9. So `PRE_FILES` is inflated too; it is only `POST_FILES` that matters for the bail, and there the inflation is fatal: `0` becomes `1`, and `POST_FILES == "0"` can never be true.

Controls ruling out other explanations:

- `printf '' | od -c` → no output. The newline genuinely originates on the `git diff` side, not from harness output-wrapping.
- `rtk proxy git diff --name-only HEAD HEAD | od -c` (documented raw passthrough) → no output.
- `rtk git diff --name-only HEAD HEAD | od -c` → `\n`. The proxy is the cause.
- `git diff --name-only HEAD HEAD > file` then `od -c file` → 0 bytes. A **file redirect** is not rewritten.

### 2. The two assignments alone really are safe — #1336's own repro holds

Running just the two `PRE_FILES=` / `POST_FILES=` lines plus an `echo`, as one Bash call:

```
PRE_FILES=[6] POST_FILES=[0]
```

Correct on both. This is exactly what #1336 reported, and it is why the issue was filed as theoretical.

### 3. But the full §5.7 block never gets to run

The prescribed block is not two assignments — it is two assignments **plus the `if`**. Run verbatim as one Bash call, that is deterministically **refused** (2/2 attempts) by the harness's worktree-isolation Bash guard:

> This agent is isolated in the worktree …, but this command is too complex to verify that it stays inside the worktree; **break it into plain, separate commands**. Refusing to run it …

Discriminating controls:

| Shape | Result |
|---|---|
| 2 git command substitutions + `echo` (3 statements, no `if`) | accepted |
| `if` over two literal variables, no command substitution | accepted |
| 2 git command substitutions + inline `if` (**the prescribed §5.7 block**) | **refused** |

The trigger is the *combination* of git command substitutions with an inline `if` — the same refusal class [#802](https://github.com/mattsears18/shipyard/issues/802) already documents ("a single call built from command substitutions, `cd` subshells, and an inline `if`"). #802 fixed that shape for the step-0 cwd check and never swept §5.7.

### 4. The refusal's own remediation is the vulnerable shape

This is what closes the loop. The refusal message tells the worker to *"break it into plain, separate commands"* — and doing so produces:

```bash
git diff --name-only "origin/$DEFAULT_BRANCH" HEAD | wc -l | tr -d ' '
```

as the entirety of one Bash call. Measured: **`1`**, for a genuinely-empty diff. So the sanctioned recovery path from the refusal lands precisely on the miscounting shape from finding (1), where the `POST_FILES == "0"` bail can never fire and the #646 guard is silently disabled for exactly the case it exists to catch.

The two failures are not independent risks that might each be tolerable — they compose into a single deterministic path: *prescribed shape refused → decompose as instructed → guard silently inert → force-push an empty diff → PR auto-closed, work lost, worker returns `rebased #<M>` (success)*.

### 5. A script-internal invocation is immune

The same two counts, run inside `bash <script>`:

```
script-internal: EMPTY_LINES=0 EMPTY_BYTES=0 NONEMPTY_LINES=6
```

Correct on both — consistent with [PR #1337](https://github.com/mattsears18/shipyard/pull/1337)'s finding that script-internal `git diff` calls are not rewritten. And a single `bash <script> <args>` call is a plain command the isolation guard accepts, so one change fixes both failures at once.

## Options considered

| Option | Verdict |
|---|---|
| **A. Route the diffs through a scratch file** (#1336's first suggestion) | Fixes the miscount — a redirect is not rewritten (measured) — but does nothing about finding (3). The block still has command substitutions plus an `if`, so it is still refused and still decomposed by hand. Treats the symptom. |
| **B. Add a #1337-style "does this look like real output" shape check inline** (#1336's second suggestion) | Correct instinct, wrong placement. Adding a shape check makes the block *more* complex, so it is refused *more* readily — and once decomposed, whether the shape check survives the decomposition is up to the worker doing the decomposing. |
| **C. Extract the guard into a standalone script, invoked as one plain command** | **Chosen.** A single `bash <script>` call is accepted by the isolation guard (no decomposition, so finding (4) never triggers), and its internal `git diff` calls are not rewritten (so finding (1) never triggers). It also makes the guard directly unit-testable, which an inline markdown snippet can never be. Established precedent in this repo twice over: [#826](https://github.com/mattsears18/shipyard/issues/826) (`assert-worktree-cwd.sh`) and [#1175](https://github.com/mattsears18/shipyard/issues/1175) (`verify-added-lines-survived.sh`) extracted inline snippets for structurally identical reasons. |
| **D. Do nothing — document the risk only** | Rejected once finding (3) landed. This is no longer theoretical: the prescribed form does not execute, and its documented recovery path is the vulnerable one. |

Option C additionally carries the fail-loud posture #1175 established: the script refuses to emit a verdict it cannot trust, rather than silently computing one from corrupted input. Three layers:

1. **File redirects, not pipelines or `$(...)` captures.** A `$(...)` capture strips trailing newlines — which would erase the single-`\n` artifact that distinguishes a rewritten empty result from a real one. The evidence has to survive to be checked.
2. **Shape check.** Real `git diff --name-only` output is a newline-terminated list of non-empty path lines and never contains a blank line. Any blank line ⇒ `INDETERMINATE`, not a count.
3. **Environment self-check.** `git diff --name-only <base> <base>` — a ref against itself — must produce zero bytes. This probes the exact corruption mode directly, before any real comparison is trusted.

## What ships now

- **`plugins/shipyard/scripts/assert-rebase-diff-nonempty.sh`** — the extracted guard. Exit 0 `OK:` / exit 1 `EMPTY_DIFF:` / exit 2 `INDETERMINATE:`.
- **`plugins/shipyard/agents/issue-worker/fix-rebase.md` §5.7** — rewritten to invoke the script as one plain command, with the exit-2 result explicitly handled as a bail (never a pass), and the reasoning above recorded inline so a future editor doesn't re-inline it.
- **`plugins/shipyard/scripts/tests/assert-rebase-diff-nonempty.test.sh`** — 14 behavioral tests over synthetic git fixtures, including a shadowed-`git` reproduction of the proxy rewrite. Test (7) asserts the fixture genuinely reproduces the miscount (`wc -l` returns 1 for an empty diff) so tests (8)-(10) cannot pass vacuously.
- **`plugins/shipyard/scripts/tests/fix-rebase-empty-diff-guard.test.sh`** — updated to assert the script invocation, plus new assertions that the vulnerable inline shape is *gone* and that exit 2 is treated as a bail. Verified to fire against the pre-fix spec.

## What's deferred

**The same shape guards the phantom-merge check, in two more specs.** `issue-work.md` §4.5 and `spike.md` §7.5 both compute `CHANGED_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH"...HEAD | wc -l | tr -d ' ')` inside an even larger compound block (nested `if`s plus the reaped-escape-hatch preamble) — the same refusal-prone shape, the same miscount on decomposition, and the same failure direction (the `== "0"` bail never fires, so an empty PR gets opened and its `Closes #N` corrupts the backlog — the [#356](https://github.com/mattsears18/shipyard/issues/356) hazard).

Those sites also contain a second, *differently*-signed instance worth its own measurement: `WORKING_TREE_DIRTY=$(git status --porcelain | wc -l | tr -d ' ')`. Measured here, the proxy **strips** the trailing newline from `git status --porcelain` (raw: 4 lines / 253 bytes; proxied: 3 lines / 252 bytes), so that count **under**counts by one — a 1-file dirty tree reads as `0`. The `--name-only` case over-counts and the `--porcelain` case under-counts, which means a blanket "add 1" or "subtract 1" correction is not a fix and each consumer needs checking on its own terms.

Deferring rather than folding in: those are a different guard with a different issue lineage (#356, not #646), and expanding this PR to rewrite `issue-work.md`'s always-loaded spec would trade a tightly-scoped, well-evidenced fix for a broad one. Filed as a follow-on.

## Generalizable lesson

Two rules this spike supports, both already latent in `shipyard:worker-preamble`:

1. **A spec's prescribed shell block is only correct if a worker can actually *run* it.** A block that the harness refuses is not "the prescribed usage" — the prescribed usage is whatever the worker does *after* the refusal, which is by definition unspecified. Any guard whose failure mode is silent should be a script invocation, not a compound inline block, for that reason alone.
2. **When testing whether a prescribed snippet is vulnerable, run the *whole* snippet.** #1336's negative result came from testing the two assignments without the `if` — a reasonable-looking simplification that removed the exact token that changed the outcome. The falsification has to target the artifact as written.

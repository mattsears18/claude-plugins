# Worker-preamble fragment — Multi-line `--body` payloads: use `--body-file`, never a heredoc command substitution

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "PR-creation contract"). Load this whenever a worker mode needs to pass a multi-line `--body` to `gh pr create`, `gh issue create`, `gh pr comment`, or `gh issue comment` — issue [#979](https://github.com/mattsears18/shipyard/issues/979).

## The refusal

**`gh pr create` / `gh issue create` / `gh pr comment` / `gh issue comment` with `--body "$(cat <<'EOF' ... EOF)"` is refused by the worktree-isolation `Bash` guard**, in a worktree-isolated session, with the same `"too complex to verify that it stays inside the worktree; break it into plain, separate commands"` message the guard uses for other compound shapes. This is reproduced twice against real dispatches (`mattsears18/lightwork` #3200 and #3333) and a third time live during this fix's own authoring — the guard refuses it whether the body closes an issue, comments on one, or is read-only in every other respect. **A worker that retries the identical heredoc shape, or treats the refusal as its own mistake, burns turns on a command that cannot succeed** — it is a classifier-policy boundary, not a syntax problem.

## The fix: write the body to a dotdir inside your own worktree, then pass `--body-file <path>`

Use `$WORKTREE_PATH/.shipyard-scratch/<name>.md` as the scratch location (re-derive `WORKTREE_PATH` per the usual before-write discipline — see [`reaped-escape-hatch.md`](./reaped-escape-hatch.md)):

```bash
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
mkdir -p "$WORKTREE_PATH/.shipyard-scratch"
```

Then write the body's content with the **`Write` tool** (not a `Bash` heredoc — this sidesteps the refusal entirely, and avoids every shell-quoting hazard a PR body containing backticks, `$`, or embedded quotes would otherwise trigger) to `$WORKTREE_PATH/.shipyard-scratch/<name>.md` (e.g. `pr-body.md`, `verify-gate-comment.md` — pick a name that won't collide if you write more than one body in the same dispatch). Pass the file as a **plain, single-purpose** `Bash` call:

```bash
gh pr create --repo <owner/repo> --label shipyard \
  --head "${REMOTE_BRANCH:-do-work/issue-<N>}" \
  --title "<conventional commit title>" \
  --body-file "$WORKTREE_PATH/.shipyard-scratch/pr-body.md"
```

Then clean up immediately — the file has done its job the moment the `gh` call above returns:

```bash
rm -rf "$WORKTREE_PATH/.shipyard-scratch"
```

## Why a worktree-root dotdir, not `/tmp` and not the per-worktree git directory

**Not `/tmp`.** `Write`-ing to `/tmp/...` is rejected outright by the `enforce-edit-scope.sh` sibling hook ("you attempted to edit a file OUTSIDE your isolated worktree") — correct policy, but it rules out the obvious alternative.

**Not the per-worktree git directory either, despite looking like the ideal answer.** `$(git rev-parse --git-dir)` (which the [step-0 cwd fail-fast](./SKILL.md#step-0-cwd-fail-fast--assert-youre-actually-in-your-worktree-486) already established differs from `git rev-parse --git-common-dir` for a linked worktree) resolves to a path *outside* the worktree's own directory tree — e.g. `<primary-checkout>/.git/worktrees/<name>` — and `enforce-edit-scope.sh` checks `os.path.commonpath` against the worktree ROOT directory (`.claude/worktrees/agent-<id>/`) specifically. A `Write` call there is **rejected by that hook** with the identical "you attempted to edit a file OUTSIDE your isolated worktree" message, even though the location is logically scoped to this worktree and never shared with a sibling — confirmed by testing it directly during this fix's own authoring. Don't use it for anything the `Write` tool needs to touch.

**A worktree-root dotdir is the answer that actually works with `Write`.** `$WORKTREE_PATH/.shipyard-scratch/` is inside `.claude/worktrees/agent-<id>/`, so `enforce-edit-scope.sh` allows it — the same precedent [`write-probe.md`](./write-probe.md)'s `.shipyard-write-probe` dotfile already relies on. The tradeoff: unlike the git-dir approach, this location **does** show up in `git status --porcelain` as an untracked `??` entry until removed (confirmed by testing) — it is not automatically invisible to git the way a `.git/`-internal path would be. Two things keep that harmless: (1) `git add <specific paths>` (never `-A`, per every mode's commit step) never picks up a path you didn't name, so it can't ride into a commit by accident; (2) the `rm -rf` cleanup step above removes it before the pre-PR-create / post-PR-create diff-sanity checks run, so there's nothing left to see. Do the cleanup — don't rely on step (1) alone as your only safety net.

## Scope

This applies to every multi-line `--body` a worker mode writes, not just the resolving `gh pr create` — issue-work's verify-gate comment, external-trust-gate comment, split-dispatch disposition comment, and verification-status comment; fix-checks-only's and other modes' PR comments; the incremental-progress-posting pattern in [`reaped-escape-hatch.md`](./reaped-escape-hatch.md). Anywhere a per-mode file still shows a `$(cat <<EOF ... EOF)` body inline, treat it as documentation of *what the body should say*, not the literal command shape to run — write the content to the scratch file and pass `--body-file` instead.

**A genuinely one-line body needs none of this.** `--comment "<one sentence>"` (no command substitution) is never refused — reserve the scratch-file dance for bodies that actually span multiple lines. And note `gh issue close` has no `--comment-file` flag at all, so a closing comment that must stay short is the right call anyway, not a workaround.

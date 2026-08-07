# Worker-preamble fragment — `.shipyard-scratch/`: the sanctioned general-purpose worker scratch directory

On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "Scratch directory"). Load this whenever a worker mode needs **any** ephemeral, non-diff artifact inside its own worktree — a `gh` multi-line `--body-file` payload, a helper script for a refused compound command (see [`compound-command-refusal.md`](./compound-command-refusal.md)), a loop's input file, a redirect target, or captured command output — issues [#979](https://github.com/mattsears18/shipyard/issues/979) and [#1058](https://github.com/mattsears18/shipyard/issues/1058).

`$WORKTREE_PATH/.shipyard-scratch/` started life narrowly, as a `--body-file` staging spot for the refusal documented below. It is now the **single sanctioned scratch dir for every worker mode, for any purpose** — the directory itself, the self-ignoring seed step, and the write-then-clean sequence are identical regardless of what you're putting in it.

## Seed the directory — write its own `.gitignore` first, before anything else

The very first artifact you put in `.shipyard-scratch/` each dispatch is a `.gitignore` file containing a single line, `*`. Use the **`Write` tool** (not `mkdir` + a `Bash` echo) — `Write` auto-creates the parent directory, and `enforce-edit-scope.sh` already permits this path because it resolves under your worktree root:

```
Write $WORKTREE_PATH/.shipyard-scratch/.gitignore  (content: a single line, "*")
```

Once that file exists, the directory is **self-ignoring**: git treats every path under it as ignored for the rest of the dispatch, so `git status --porcelain` stays clean no matter what you write there next, and `git add <specific paths>` (never `-A`) can't sweep any of it in by accident even if you forget to remove it. This is a self-contained fix scoped to `.shipyard-scratch/` alone — it never touches the target repo's own tracked `.gitignore`.

Everything else you write afterward — a `pr-body.md`, a helper script, a captured-output file — is a plain `Write` (or `Bash` redirect) call into the same directory, no further ceremony:

```bash
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
# .shipyard-scratch/.gitignore already exists from the seed step above.
```

## Use 1 — multi-line `--body` payloads (the original case, #979)

**`gh pr create` / `gh issue create` / `gh pr comment` / `gh issue comment` with `--body "$(cat <<'EOF' ... EOF)"` is refused by the worktree-isolation `Bash` guard**, in a worktree-isolated session, with the same `"too complex to verify that it stays inside the worktree; break it into plain, separate commands"` message the guard uses for other compound shapes. This is reproduced twice against real dispatches (`mattsears18/lightwork` #3200 and #3333) and a third time live during this fix's own authoring — the guard refuses it whether the body closes an issue, comments on one, or is read-only in every other respect. **A worker that retries the identical heredoc shape, or treats the refusal as its own mistake, burns turns on a command that cannot succeed** — it is a classifier-policy boundary, not a syntax problem.

The fix: write the body's content with the **`Write` tool** (not a `Bash` heredoc — this sidesteps the refusal entirely, and avoids every shell-quoting hazard a body containing backticks, `$`, or embedded quotes would otherwise trigger) to `$WORKTREE_PATH/.shipyard-scratch/<name>.md` (e.g. `pr-body.md`, `verify-gate-comment.md` — pick a name that won't collide if you write more than one body in the same dispatch). Pass the file as a **plain, single-purpose** `Bash` call:

```bash
gh pr create --repo <owner/repo> --label shipyard \
  --head "${REMOTE_BRANCH:-do-work/issue-<N>}" \
  --title "<conventional commit title>" \
  --body-file "$WORKTREE_PATH/.shipyard-scratch/pr-body.md"
```

## Use 2 — a helper script for a refused compound loop or redirect (#1058)

The worktree-isolation `Bash` guard also refuses plain **read-only** compound commands — a `for`/`while` loop, a multi-command `&&` chain, a shell redirect — with the identical "too complex to verify" message, even when the command never touches `git` and never names a path outside the worktree. See [`compound-command-refusal.md`](./compound-command-refusal.md) for the full decomposition guidance; the short version: prefer decomposing into plain, separate commands first, and only when a loop or redirect is genuinely unavoidable, `Write` a helper script into `$WORKTREE_PATH/.shipyard-scratch/` and invoke it as **one plain command** using a literal absolute or worktree-relative path — never `$PWD` (the #1058 repro shows `$PWD` alone triggers the refusal even though the identical absolute path is accepted).

## Cleanup — best-effort, not blocking

```bash
rm -rf "$WORKTREE_PATH/.shipyard-scratch"
```

Run this when convenient, once the scratch dir has done its job — but treat it as **best-effort / non-blocking**, not a required step. The `.gitignore` seed above is what actually guarantees a clean `git status`; the `rm -rf` is housekeeping on top of that guarantee, not a substitute for it. A failed or skipped `rm -rf` — permission-denied, a reaped worktree, anything else — is cosmetic and is never a reason to return `blocked:`. Don't retry it, don't treat its failure as a task blocker, and don't let it gate a commit, push, or return.

## Why a worktree-root dotdir, not `/tmp` and not the per-worktree git directory

**Not `/tmp`.** `Write`-ing to `/tmp/...` is rejected outright by the `enforce-edit-scope.sh` sibling hook ("you attempted to edit a file OUTSIDE your isolated worktree") — correct policy, but it rules out the obvious alternative. `enforce-edit-scope.sh`'s own BLOCK message names `.shipyard-scratch/` as the sanctioned redirect.

**Not the per-worktree git directory either, despite looking like the ideal answer.** `$(git rev-parse --git-dir)` (which the [step-0 cwd fail-fast](./SKILL.md#step-0-cwd-fail-fast--assert-youre-actually-in-your-worktree-486) already established differs from `git rev-parse --git-common-dir` for a linked worktree) resolves to a path *outside* the worktree's own directory tree — e.g. `<primary-checkout>/.git/worktrees/<name>` — and `enforce-edit-scope.sh` checks `os.path.commonpath` against the worktree ROOT directory (`.claude/worktrees/agent-<id>/`) specifically. A `Write` call there is **rejected by that hook** with the identical "you attempted to edit a file OUTSIDE your isolated worktree" message, even though the location is logically scoped to this worktree and never shared with a sibling — confirmed by testing it directly during this fix's own authoring. Don't use it for anything the `Write` tool needs to touch.

**A worktree-root dotdir is the answer that actually works with `Write`.** `$WORKTREE_PATH/.shipyard-scratch/` is inside `.claude/worktrees/agent-<id>/`, so `enforce-edit-scope.sh` allows it — the same precedent [`write-probe.md`](./write-probe.md)'s `.shipyard-write-probe` dotfile already relies on. Before the `.gitignore` seed step above ([#1058](https://github.com/mattsears18/shipyard/issues/1058)), this location showed up in `git status --porcelain` as an untracked `??` entry until removed by an explicit `rm -rf` — that was the only thing keeping it out of a stray `git add`. The seed step removes that dependency: the directory is now invisible to git from the moment `.gitignore` lands, and the `rm -rf` is cleanup, not a safety mechanism.

## Scope

This applies to every worker-mode artifact that shouldn't ride in the PR diff — not just multi-line `--body` payloads. Issue-work's verify-gate comment, external-trust-gate comment, split-dispatch disposition comment, and verification-status comment; fix-checks-only's and other modes' PR comments; the incremental-progress-posting pattern in [`reaped-escape-hatch.md`](./reaped-escape-hatch.md); any helper script or loop-input file from [`compound-command-refusal.md`](./compound-command-refusal.md)'s decomposition guidance. Anywhere a per-mode file still shows a `$(cat <<EOF ... EOF)` body inline, treat it as documentation of *what the body should say*, not the literal command shape to run — write the content to the scratch file and pass `--body-file` instead. Anywhere a per-mode file's own `rm -rf "$WORKTREE_PATH/.shipyard-scratch"` example predates the `.gitignore` seed step, treat the sequence in this fragment — seed the `.gitignore` first, clean up best-effort — as authoritative.

**A genuinely one-line body needs none of the `--body-file` dance.** `--comment "<one sentence>"` (no command substitution) is never refused — reserve the scratch-file approach for bodies that actually span multiple lines. And note `gh issue close` has no `--comment-file` flag at all, so a closing comment that must stay short is the right call anyway, not a workaround.

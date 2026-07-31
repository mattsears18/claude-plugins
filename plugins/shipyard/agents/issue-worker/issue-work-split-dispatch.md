# issue-work.md § 6.5 — Split-dispatch disposition: hand back the operator/security residual, keep the issue open ([#851](https://github.com/mattsears18/shipyard/issues/851))

On-demand fragment of [`issue-work.md`](./issue-work.md). Loaded only when that file's §6.5 stub says the dispatch prompt's Context block carries an "Operator residual" paragraph — see [#980](https://github.com/mattsears18/shipyard/issues/980) for why this content moved out of the always-loaded core (it's a rare split-dispatch carve-out, not the common resolving-PR path).

**Run this step only when the dispatch prompt's Context block carries an "Operator residual" paragraph** (set by [scope-preflight's operator-slice carve-out](../../commands/do-work/setup/06b-scope-carveouts.md#operator-slice-carve-out--ship-the-code-slice-hand-back-only-the-operator-remainder-851), or an explicit human-authored split instruction naming the residual directly). When absent — the common case — **skip directly to step 7** (in `issue-work.md`); nothing below applies and behavior is unchanged.

You are here because this PR ships only the phase-1 code slice; issue `#<N>` itself is not resolved. §5.85's trigger shape (3) already required you to reference `#<N>` with a bare URL (never a closing keyword) and to run the leak-verification loop treating `#<N>` as the protected issue — confirm that ran and passed before continuing. Auto-merge is now armed (or the PR merged directly on the ungated path per §6.a) — post the disposition comment and apply the residual label:

```bash
# <M> = this PR's number. <phase_1_scope> / <operator_residual> come verbatim
# from the dispatch prompt's Context block. <merge-state> is "merged" if the
# post-arm snapshot (below, borrowed one-shot read from step 7) already shows
# state MERGED, otherwise "auto-merge armed".
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
mkdir -p "$WORKTREE_PATH/.shipyard-scratch"
```

Write this content (with the `Write` tool) to `$WORKTREE_PATH/.shipyard-scratch/split-disposition-comment.md` (a heredoc `--body "$(cat <<EOF ... EOF)"` is refused per [#979](https://github.com/mattsears18/shipyard/issues/979) — `shipyard:worker-preamble` § "Multi-line `--body` payloads"):

```
## Split disposition — code slice shipped, <operator|security> slice handed back

**Shipped:** <phase_1_scope> via PR #<M> (<merge-state>).

**Handed back:** <operator_residual>

This issue is being labeled `<needs-operator|needs-human-review>` and left OPEN pending that action.
```

Then:

```bash
gh issue comment <N> --repo <owner/repo> --body-file "$WORKTREE_PATH/.shipyard-scratch/split-disposition-comment.md"
rm -rf "$WORKTREE_PATH/.shipyard-scratch"
```

Choose the residual label from the dispatch prompt's `operator_residual_security_sensitive` framing (mirrored from `operate/02-execution-and-playbooks.md`'s [Claude-safe-vs-hand-back table](../../commands/do-work/operate/02-execution-and-playbooks.md#claude-safe-to-auto-drive-vs-hand-back-securityaccess-control) when you need to re-derive it): `needs-operator` for a plain browser/console action, `needs-human-review` when the residual is itself a security/access-control mutation (per [#848](https://github.com/mattsears18/shipyard/issues/848)'s relabel rule — see this repo's `CLAUDE.md` § `needs-operator`). Apply it **ensure-then-label-then-verify**, the same idiom scope-preflight's own label application uses — never a bare `--add-label` that silently depends on label-creation having landed:

```bash
GATE_LABEL="needs-operator"   # or "needs-human-review" per the choice above
gh label create "$GATE_LABEL" --repo <owner/repo> \
  --description "Operator/human review gate applied by a split-dispatch hand-back" 2>/dev/null || true
gh issue edit <N> --repo <owner/repo> --add-label "$GATE_LABEL"
```

If either the comment or the label call errors (rate limit, permission), log an advisory and retry once; if it still fails, don't block your return on it — note the failure in your step-8 return string so the orchestrator can retry the labeling.

**Do NOT apply `needs-human-review`/`needs-operator` to the PR** — only to the issue. The PR itself already merged or has auto-merge armed; the gate label belongs on the still-open issue that carries the unshipped residual.

Once this fragment's disposition is applied, return to [`issue-work.md`](./issue-work.md) and continue at step 7, then return via step 8's `partial` return shape.

# issue-work.md § 5.9 — Independent adversarial verification (opt-in gate)

On-demand fragment of [`issue-work.md`](./issue-work.md). Loaded only when that file's §5.9 stub says `verify_gate: on` is present in the dispatch prompt — see [#980](https://github.com/mattsears18/shipyard/issues/980) for why this content moved out of the always-loaded core (it is off by default, so most dispatches never need it).

The PR is open and every mechanical guard (§5.7 / §5.8 / §5.85) has passed, but auto-merge is **not yet armed**. This is the "verify" in find → implement → **verify** → merge: before you arm the merge, an *independent* agent adversarially checks that your change actually and completely resolves the issue. You believe it does — that's exactly why the check has to come from a skeptic that isn't you.

Dispatch the verifier as a nested subagent via the `Agent` tool. It is the one sanctioned nested dispatch in the do-work loop:

- `subagent_type: "shipyard:verify-worker"` — pinned to **Opus 4.8** in its shim frontmatter (the strong, harder-to-fool tier this gate reserves for its highest-stakes judgment — [#784](https://github.com/mattsears18/shipyard/issues/784)). The tier is overridable per-role via `models.verify`: resolve it the same way the orchestrator resolves every dispatch's model, and pass it as the `Agent` call's `model` parameter (omit `model` when the resolution is empty so the Opus 4.8 frontmatter default applies). **Reuse the literal plugin-root value already resolved at `shipyard:worker-preamble`'s step-0 in place of `${CLAUDE_PLUGIN_ROOT}` below instead of re-deriving it here ([#965](https://github.com/mattsears18/shipyard/issues/965)):**

  ```bash
  export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
  verify_model=$("${CLAUDE_PLUGIN_ROOT}/scripts/resolve-dispatch-model.sh" verify 2>/dev/null)
  # verify_model non-empty (opus/sonnet/haiku/fable) → set model: "<verify_model>" on the Agent call;
  # empty → omit the model parameter so verify-worker.md's opus frontmatter default applies.
  ```
- `isolation: "worktree"` (**mandatory** — the isolation hook hard-fails the dispatch otherwise; the verifier reads the PR via `gh`, so an empty worktree is fine)
- prompt naming `mode: verify` and carrying: the PR number `<M>`, the issue number `<N>`, `<owner/repo>`, and the acceptance criteria / reproduction summary you read in step 2.

> **`mode: verify`** — Adversarially verify that PR #`<M>` in `<owner/repo>` correctly and completely resolves issue #`<N>` before it auto-merges. Acceptance criteria / reproduction to check the diff against: `<AC summary from step 2>`. **Load the `shipyard:worker-preamble` skill, then `agents/issue-worker/verify.md`.** Return a single verdict line: `verified: <basis>` or `not-verified: <specific refutation>`.

Read the verifier's single-line verdict and branch:

- **Verdict starts with `verified:`** → the change cleared independent review. **Proceed to step 6** (in `issue-work.md`) and arm auto-merge exactly as normal.
- **Verdict starts with `not-verified:`** → do **NOT** arm auto-merge. Gate the PR for a human, carrying the verifier's reasoning verbatim so the maintainer sees *why*:

  ```bash
  gh pr edit <M> --repo <owner/repo> --add-label needs-human-review
  WORKTREE_PATH="$(git rev-parse --show-toplevel)"
  mkdir -p "$WORKTREE_PATH/.shipyard-scratch"
  ```

  Write this content (with the `Write` tool) to `$WORKTREE_PATH/.shipyard-scratch/verify-gate-comment.md` (a heredoc `--body "$(cat <<EOF ... EOF)"` is refused per [#979](https://github.com/mattsears18/shipyard/issues/979) — `shipyard:worker-preamble` § "Multi-line `--body` payloads"):

  ```
  Independent verification did not pass — this PR will not auto-merge until a maintainer reviews it.

  **Verifier verdict:** <the not-verified reason, verbatim>

  This is the do-work adversarial-verify gate (`verify_gate.enabled`): an independent agent judged the change against the issue's acceptance criteria before merge and could not confirm it. A human should confirm or correct.
  ```

  Then:

  ```bash
  gh pr comment <M> --repo <owner/repo> --body-file "$WORKTREE_PATH/.shipyard-scratch/verify-gate-comment.md"
  rm -rf "$WORKTREE_PATH/.shipyard-scratch"
  ```

  Then return the step-8 blocked string: `blocked #<N> at verify: <the not-verified reason>`. The orchestrator's step-A reconcile classifies a `blocked … at verify:` return into `needs-human-review` per [#521](https://github.com/mattsears18/shipyard/issues/521), so no new reconcile branch is needed.

**Fail open — never let the gate strand a PR.** If the nested dispatch is *refused* by the harness (nested spawning is off by default: `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` must be `≥1` — see [`verify-worker.md`](../verify-worker.md) § "Nested-dispatch prerequisite"), or the verifier returns a `not-verified:` line whose reason is `verifier worktree reaped mid-run` (a non-verdict, not a real refutation), do **not** silently arm auto-merge as if verified, and do **not** hard-block the loop. Instead label `needs-human-review`, comment that the gate could not run (`Verify gate could not run: <reason>; a maintainer should review before merge`), and return `blocked #<N> at verify: gate could not run — <reason>`. This keeps the safety posture (unverified never auto-merges) without letting a misconfigured depth setting wedge the session — the operator fixes the env var and re-runs. A dispatch that *succeeds* but yields no parseable `verified:`/`not-verified:` prefix is treated the same way (non-verdict → human review).

Once this fragment's branch resolves, return to [`issue-work.md`](./issue-work.md) and continue at the step it named (6, or the blocked return in 8).

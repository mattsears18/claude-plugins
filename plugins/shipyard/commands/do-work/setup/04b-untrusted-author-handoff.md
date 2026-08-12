# /shipyard:do-work — Setup phase · bucket-0.5 untrusted-author handoff

**Setup sub-phase fragment, loaded from [`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)'s trusted-author drop bullet — not part of the ordered per-session walk.** Owns the surfacing side effect on the step-4 trusted-author security gate: labeling + commenting a newly-dropped issue so a human sees it, bounded and idempotent. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md).

### Bucket-0.5 handoff ([#1079](https://github.com/mattsears18/shipyard/issues/1079))

Before this fix, step 4's `author.login` NOT-in-`trusted_authors` drop applied no label and posted no comment, so `/shipyard:my-turn` — which has no author-trust signal of its own — never learned the issue existed. A stranger's issue reached no human by any path: never dispatched (correct — the gate is a security boundary, not a triage hint), never labeled (invisible to every label-driven sweep), never surfaced (the actual defect).

**The gate itself does not change.** Every untrusted-author issue is still unconditionally dropped from the workable dispatch queue — this fragment adds only a *surfacing* side effect on top of that drop. For each issue the gate just dropped this run, apply `needs-human-review` and post a one-line comment naming the vouch path, so the issue rides `/my-turn`'s **already-working** bucket-5.5 path (see [`backlog-ownership.md`](./backlog-ownership.md#ownership-table)) instead of `/my-turn` gaining a second, independently-computed trust signal of its own. That second-signal shape (`/my-turn` reading `.shipyard/trusted-authors.txt` directly) was issue #1079's rejected Option B — duplicating the trust computation in a second place is exactly how two commands' routing silently drifts apart, the same failure class [`backlog-ownership.md`](./backlog-ownership.md) exists to prevent structurally.

**Bound the write to issues newer than the last session's high-water mark.** An unauthenticated stranger can trigger this label write just by filing the issue — it's a write on an issue they already created, at a rate GitHub already limits, but the write itself shouldn't re-sweep the full untrusted-author history every session. Persist the mark **across sessions**, not in the per-session state file (`$SHIPYARD_HOME/sessions/<id>.json`, reaped at end-of-session and unable to hold cross-session state):

```bash
SHIPYARD_HOME_DIR="${SHIPYARD_HOME:-$HOME/.shipyard}"
mkdir -p "$SHIPYARD_HOME_DIR"
HW_FILE="$SHIPYARD_HOME_DIR/untrusted-author-highwater.json"
[ -f "$HW_FILE" ] || echo '{}' > "$HW_FILE"
HIGHWATER=$(jq -r --arg k "<owner/repo>" '.[$k] // 0' "$HW_FILE")
```

`$HW_FILE` is a small JSON object keyed by `<owner/repo>` → the highest issue number this repo's bucket-0.5 handoff has already processed. It is deliberately global (`$SHIPYARD_HOME`, not a repo-local file) because the orchestrator's own worktree is per-session (`.claude/worktrees/orchestrator-<session-id>`) and would not persist the mark across sessions the way `$SHIPYARD_HOME` does — the same reasoning that puts `cost-history.jsonl` and `flake-registry.jsonl` at this same path rather than in the repo.

For each issue this run's author-login gate just dropped with `number > HIGHWATER`:

- **Idempotent — skip if already labeled.** If the issue's already-fetched `labels` array already contains `needs-human-review` (from a prior partially-completed run, or any other path — e.g. a maintainer applied it by hand), skip both the label-add and the comment. This is the guard for the case where labeling succeeded on a prior run but the high-water write below didn't land (a crash between the two, or a worktree reap mid-loop).
- Otherwise:

  ```bash
  gh label create needs-human-review --repo <owner/repo> \
    --description "Awaiting human review — see /shipyard:my-turn" --color 5319E7 2>/dev/null || true
  gh issue edit <N> --repo <owner/repo> --add-label needs-human-review
  gh issue comment <N> --repo <owner/repo> --body "<!-- do-work-untrusted-author-review -->
  Author \`@<login>\` is not in \`trusted_authors\`, so this issue is excluded from \`/do-work\` dispatch — a security gate, not a triage hint (see [step 2](./01b-backlog-overview.md#2-backlog-overview)). A maintainer must vouch before it becomes dispatch-eligible: add \`@<login>\` to \`.shipyard/trusted-authors.txt\`, or re-file this issue's body under a trusted account. Surfaced here for review by \`/shipyard:my-turn\`."
  ```

  The `<!-- do-work-untrusted-author-review -->` sentinel is what `/shipyard:my-turn` matches to render this as the distinct "external-author trust review" action (see [`my-turn.md`](../../my-turn.md) Pass B) rather than a generic `needs-human-review` item — it's also a second, comment-level idempotency signal, redundant with (but cheaper to check than) the label-presence guard above.

Then advance the high-water mark to the **highest issue number across the full untrusted-author set dropped this run** — not only the just-labeled subset. An already-labeled issue (the skip branch above) still needs to advance the mark, or every subsequent session would re-fetch and re-check it forever even though there's nothing left to do:

```bash
# NEW_HW = max issue number across this run's untrusted-author drop set,
# or the current HIGHWATER unchanged if that set is empty.
if [ "$NEW_HW" -gt "$HIGHWATER" ]; then
  TMP_HW="$(mktemp "$HW_FILE.XXXXXX")"
  jq --arg k "<owner/repo>" --argjson v "$NEW_HW" '.[$k] = $v' "$HW_FILE" > "$TMP_HW" && mv -f "$TMP_HW" "$HW_FILE"
fi
```

The atomic-write shape (`mktemp` + `mv -f`) mirrors the same pattern `session-state.sh`, `cost-history.sh`, and `flake-registry.sh` all use for their own persisted state files — see [`01-repo-recovery.md`'s orphan atomic-write `.tmp` sweep note](./01-repo-recovery.md#16-reap-orphan-session-files-cost-ledger-recovery) for why the pattern matters (a crash mid-write leaves a `.tmp.<rand>` orphan next to the real file rather than a half-written target). `scripts/sweep-orphan-tmp.sh` does not yet know about this specific `.tmp` pattern (it currently covers `session-state.sh` / `cost-history.sh` / `flake-registry.sh`'s own literal orphan shapes) — a crash mid-write here leaves a harmless, easily-identifiable stray file rather than corrupting `$HW_FILE` itself (the `mv -f` only replaces the target on a fully-written temp file).

**Skip entirely** (no file touch, no `gh` calls) when this run's untrusted-author drop set is empty. **Runs every session** — unlike [step 4.5a/4.5b](./04-backlog-divert.md#4-fetch--rank-the-backlog)'s main-CI / PR-pileup divert checks, this fragment is part of step 4's core client-side filter and is NOT skipped under `--fast`.

**Acceptance criteria this closes (issue #1079):**

- A bucket-0.5 issue now reaches the human queue — via `/my-turn`'s existing `needs-human-review` bucket-5.5 path, with no new signal for `/my-turn` to compute.
- The security gate itself is unchanged — untrusted issues still never reach the dispatch queue; this fragment only runs on issues the gate already dropped.
- `/my-turn`'s previously-declared-but-unpopulated "external-author trust review" category (see [`my-turn.md`'s Human-only queue filter](../../my-turn.md#human-only-queue-filter)) is now genuinely populated.
- The labeling is bounded (the high-water mark) and idempotent (the label-presence check + the sentinel comment), never a full-history sweep.
- The rendered action names the vouch path (`.shipyard/trusted-authors.txt` / re-file) directly in the comment, so the maintainer doesn't have to look it up.

# /shipyard:do-work — Step 6, PR-collision cache-reuse + semantic premise re-validation

Deep-linked from [`06-scope-preflight.md`](./06-scope-preflight.md#pr-collision-cache-reuse-check-1448)'s PR-collision cache-reuse check and from [`drain.md` 5.b](../drain.md#5b--re-validate-scope-agent-and-cached-diagnosis-entries)'s `blocked-by-in-flight-pr` backstop — read this file only when you reach one of those pointers, not as part of the ordered per-session walk.

## Why this exists

[#1429](https://github.com/mattsears18/shipyard/issues/1429) shipped the auto-requeue half of "treat `blocked-by-in-flight-pr` as a requeue signal": a self-clearing `<!-- do-work-blocked-by-prs: N,M -->` body marker plus `backlog-filter.sh classify`'s `--pr-collision-verdicts` map drop the issue from the workable set while any listed PR is still `OPEN` and re-admit it — to a **fresh** scope-agent pass — the instant every listed PR resolves. That PR deliberately did NOT ship the cost-avoidance half: reusing the original scope agent's cached ready-shape scope to skip the fresh dispatch entirely. Shipping that half alone, without re-validating the specific claim the original `evidence_pointer` cited, would reproduce the exact stale-premise bug [#1426](https://github.com/mattsears18/shipyard/issues/1426) diagnosed (lightwork#4148 — an acceptance criterion depending on a claim the holding PR had deleted): the merged PR resolved the file collision, but also silently invalidated the reason the issue's fix made sense in the first place. This file ([#1448](https://github.com/mattsears18/shipyard/issues/1448)) is that follow-up — the cache-reuse mechanism AND the safety gate it requires, shipped together, never one without the other.

## Persistence — the `<!-- do-work-blocked-by-prs-scope -->` comment marker

`would_be_ready_scope` (see [06-scope-preflight.md](./06-scope-preflight.md#6-initial-scope-pre-flight)'s Deferred shape docs) is a field on the scope agent's **in-memory** return — it does not survive past the current dispatch turn on its own. Because the marker that gates re-admission is stateless (`classify` re-derives eligibility from live GitHub state on every fetch, potentially in a **different session** than the one that deferred the issue), the cached scope must be persisted somewhere durable and content-addressable: an issue comment, mirroring the `cached-diagnosis` mechanism the [Scope-result freshness check](06-scope-preflight.md#scope-result-freshness-check-skip-dispatch-when-a-fresh-diagnosis-comment-exists) already uses for every other class.

**Write side** ([06c-scope-handling-ui.md](06c-scope-handling-ui.md) step 4e): when the scope agent's `blocked-by-in-flight-pr` return carries a `would_be_ready_scope`, validate its shape the same way a plain ready return's `files`/`phase_1_scope` are validated (non-empty `files` array; `phase_1_scope`, when present, a non-empty string). A `would_be_ready_scope` that fails this check is dropped silently (logged, not rejected outright — the defer itself is still valid without it; only the cache-reuse optimization is unavailable for this cycle). When valid, post ONE additional comment (alongside — never replacing — the existing step-4e body-marker write), tagged:

```
<!-- do-work-blocked-by-prs-scope -->
Cached ready-shape scope for a blocked-by-in-flight-pr defer (issue #1448).

blocking_prs: [N, ...]
evidence_pointer: <verbatim from the deferred return>
would_be_ready_scope: <JSON, verbatim from the deferred return>
```

This comment is a pure cache write — it does not affect dispatch eligibility (the body marker already does that) and does not get a freshness window; the premise re-validation below is what keeps a stale cache from being trusted, not a time-based expiry.

## Trigger

A `raw_backlog` candidate reaches this check when its body's first line still carries `<!-- do-work-blocked-by-prs: N,M -->` (the marker is never removed by the resolution — `classify` only stops treating it as gating, per [#1429](https://github.com/mattsears18/shipyard/issues/1429)'s design) AND every listed PR is currently `MERGED`/`CLOSED`. This is true both for a same-session re-admission (a step-D refresh notices a blocking PR just merged) and a cross-session one (a fresh `/do-work` invocation's first backlog fetch finds the blocker already resolved).

## Procedure

1. **Cache lookup.** Fetch the issue's comments (reuse the step-0 projection if still in context, else `gh issue view <N> --repo <owner/repo> --json comments`). Find the newest comment whose body opens with `<!-- do-work-blocked-by-prs-scope -->`. **None found → no cache; skip this entire check, fall through to normal scope-agent dispatch** (byte-for-byte the pre-#1448 behavior).

2. **Shape/consistency check.** Parse `blocking_prs`, `evidence_pointer`, `would_be_ready_scope` from the comment body. If the comment's `blocking_prs` set doesn't match (isn't a superset of) the body marker's current PR list — the marker was edited since the comment was posted (e.g. a re-diagnosis found an additional holding PR) — treat the cache as stale; fall through to normal scope-agent dispatch.

3. **Classify the collision shape from `evidence_pointer`.** Per the `blocked-by-in-flight-pr` class's citation rule (the In-flight-PR-collision carve-out, [06b-scope-carveouts.md](06b-scope-carveouts.md)'s scoping-agent prompt instruction, and [06-scope-preflight.md](06-scope-preflight.md#6-initial-scope-pre-flight)'s Deferred shape docs), two citation shapes:
   - **Textual-only** (`Blocked by in-flight PR: #N holds <path>`, no quoted claim) — there is no semantic premise to invalidate; a file collision that resolved by merging carries no claim-dependency risk. **Skip straight to step 5 (safe to reuse).**
   - **Semantic** (`Blocked by in-flight PR: #N <deletes|rewrites|alters|removes> the "<claim>" ... this issue's AC <requires|depends on>`) — extract the quoted `<claim>` text verbatim. Continue to step 4.

4. **Premise re-validation (semantic collisions only) — the mandatory safety gate.** For each PR in `blocking_prs`, fetch its merged diff scoped to the files named in `would_be_ready_scope.files` (falling back to the PR's full diff if that list is empty or the files don't overlap):

   ```bash
   gh pr diff <N> --repo <owner/repo> -- <would_be_ready_scope.files...>
   ```

   Search the diff for the extracted `<claim>` text (case-insensitive substring match, tolerant of minor whitespace differences — this is the same targeted `git diff`/`git show` check the issue's own body prescribes, not a full-repo re-read):

   - **Claim text appears on a removed line (`-` prefix, excluding `---` file headers) and does NOT reappear on any added line (`+` prefix)** — the predicted deletion happened exactly as the original scope agent anticipated. The premise the deferred issue's fix depended on (that the claim currently exists needing correction) **no longer holds**. **Do NOT reuse the cache — fall through to normal scope-agent dispatch.** This is the #1426 case: dispatching from the stale cache here would ship a fix against a claim that's already gone.
   - **Claim text is absent from removed lines entirely, OR reappears on an added line (moved/reworded but substantively present)** — the predicted collision did not materialize as evidence_pointer described (review changed the final diff, or the scope agent's prediction was imprecise). The premise is **unchanged from what the original scope agent assessed** — safe to reuse. Continue to step 5.
   - **Ambiguous** (the diff can't be fetched, the claim text search is inconclusive, ellipsized text, multiple non-matching candidate locations) — **fail-safe to NOT reuse.** Never guess "safe" on an inconclusive read; fall through to normal scope-agent dispatch. This mirrors the fail-safe-to-gated posture `pr_collision_verdict` and `eval-recheck-probe.sh` already use elsewhere in this codebase.

5. **Reuse.** Promote the candidate directly to `ready_issues` using the cached `would_be_ready_scope.files` / `would_be_ready_scope.phase_1_scope` — identical to a plain scope-agent ready return, with **no scope-agent dispatch this turn**. If a `deferred_issues` entry for this issue is still held in working memory (same-session re-admission), remove it. Log: `[scope-preflight] #<N> PR-collision cache-reuse — premise re-validated (<textual-only|semantic-confirmed-unchanged>), skipping scope-agent dispatch`. The dispatched worker still re-derives its implementation from current code per its own untrusted-input posture ([`issue-work.md` step 2](../../../agents/issue-worker/issue-work.md)) — this optimization only skips the *scoping* re-read, never the worker's own verification.

**When NOT to reuse (falls through to normal scope-agent dispatch in every case):** no cached comment found; `blocking_prs` mismatch between the comment and the current marker; a semantic claim confirmed deleted by the merge; any ambiguous/inconclusive diff read. A fresh scope-agent dispatch is always the safe default — this check exists purely to skip it when reuse is *demonstrably* safe, never to force a skip.

## `drain.md` 5.b — the backstop path

The trigger above covers the common case: a `raw_backlog` candidate re-admitted at an ordinary backlog fetch. [`drain.md` 5.b](../drain.md#5b--re-validate-scope-agent-and-cached-diagnosis-entries) still re-validates a `deferred_issues` entry recorded via a path that predates the marker, or where the marker write itself failed — when its `blocking_prs` re-probe finds every PR now `MERGED`/`CLOSED`, run this same procedure (steps 1–5 above) before deciding between "promote to `ready_issues` via the cached scope" and "route to a fresh scope-agent dispatch." The two call sites share one procedure so the semantics can't drift between the ordinary-fetch path and the pre-drain backstop.

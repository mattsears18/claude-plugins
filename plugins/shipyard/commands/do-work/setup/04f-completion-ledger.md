# /shipyard:do-work — Setup phase · completion ledger (issue #1250)

Fragment of step **4** ([`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)) and of [`drain.md`'s termination assertion](../drain.md#termination-assertion). Deep-link from **both** exit points that used to assert "backlog empty" (or an equivalent "queues empty" conclusion) from arithmetic alone — the setup-time early exit and the end-of-drain summary. Not part of the ordered per-session walk; loaded only when either of those exit points is reached.

## Why this exists

A session that reports "nothing left to do" while a dozen or more issues sit open **looks exactly like success**, which is what makes it the loop's most expensive failure mode — nothing retries and no alarm fires. Three independent structural holes produced it (issue [#1250](https://github.com/mattsears18/shipyard/issues/1250)):

1. The setup early exit asserted "backlog empty" from the post-filter `raw_backlog` count alone, with no comparison against the pre-filter fetch — any defect in the six-clause client-side filter converted directly into a confident false completion.
2. [`drain.md`'s termination assertion](../drain.md#termination-assertion) checked `in_flight`, `failed_prs`, and `ready_issues`, but never `raw_backlog` — an issue fetched and ranked but never promoted to `ready_issues` was simultaneously "already known" (subtracted in the net-new diff) and "not ready" (invisible to the ready-issues check), and therefore invisible to every gate.
3. Both of the above reasoned purely over internal queues, never over the world — "queues empty" and "the filter erased the work" were indistinguishable in the output.

The maintainer's stated goal — run until **zero open issues** — is not reachable (some issues are genuinely gated on a human decision, an external dependency, or a calendar date) and a loop that tried would never terminate. The achievable, testable invariant this ledger implements instead:

> A session may not report completion while **any dispatchable issue remains**, and when it does report completion it must **account for every open issue by number and reason**.

That is "zero *unexplained* open issues," not "zero open issues." An issue that's genuinely gated is fine to leave open, as long as the ledger names it and why.

## The bucket taxonomy

Every open issue lands in **exactly one** bucket. The set was validated against a live 34-issue backlog (`mattsears18/lightwork`) across three corrective passes — the corrections themselves (a missed time-gate bucket, then a misfiled `agent-console` item) are why bucket assignment below is keyed to an **explicit, named signal on the issue**, never inferred:

| # | Bucket | Signal (mechanical, no judgment) | Counts as |
| --- | --- | --- | --- |
| 1 | In flight this session | number is a key in the `in_flight` map | in progress |
| 2 | PR open, awaiting merge | number in the healthy `closed_by_open_healthy_pr` set ([`04`'s own join](./04-backlog-divert.md#4-fetch--rank-the-backlog)) or in `session_prs` with a non-failing rollup | in progress |
| 3 | PR open, checks failing | number's linked PR is in `failed_prs` | in progress (fix-checks owns it) |
| 4 | Human-gated | labels include `needs-human-review`, `discussion`, `wontfix`, or `tracking` | parked — needs a human |
| 5 | Operator queue | labels include `agent-console` | **dispatchable** by the operator phase — see the correction below |
| 6 | Blocked by open sibling | body contains `Blocked by #N` and `#N` is still `OPEN` | parked — self-clearing |
| 7 | Time-gated | body's first line is a `<!-- do-work-blocked-until: YYYY-MM-DD -->` marker with a date still in the future | parked — self-clearing; an **expired** marker flips the issue to bucket 9, never stays in bucket 7 |
| 8 | Investigate queue | number in `investigate_candidates` | **dispatchable** — routed, not yet worked |
| 9 | Untrusted author | `author.login` (lowercased) not in `trusted_authors` | parked — needs allowlist vouching |
| 10 | Dispatchable | number in `raw_backlog` or `ready_issues`, or passes every filter above with no matching signal | **must be 0 at a completion claim** — a non-zero count here means the session is stopping short, not finishing |
| 11 | Unaccounted | matches none of the above | **always a defect** — see the load-bearing rule below |

**Correction — `agent-console` is bucket 5, not bucket 4.** `agent-console` marks work an agent performs *outside the build* (a cloud console, a deploy platform, a store listing); `/do-work` drains it itself via the [operator phase](../operate.md) by default. It is dispatchable, by a different worker, not parked for a human — folding it into the human-gated bucket undercounts what's actually workable and was the taxonomy's own first miscount (issue #1250's live-backlog validation). **Exception:** under `--no-operate` / `--hands-off`, the operator phase never runs, so bucket 5 collapses into bucket 4 for that session — state which case applies when rendering the ledger, don't assume.

**Correction — time-gated is its own bucket, not silently dispatchable.** A first pass at this taxonomy omitted bucket 7 entirely and misreported gated issues as dispatchable. The `do-work-blocked-until` marker is self-clearing by design (no label, no sweep needed) — the ledger just has to actually read it, on line 1 only, exactly as [`04`'s own filter](./04-backlog-divert.md#4-fetch--rank-the-backlog) does.

## The load-bearing rule

**If any open issue cannot be placed in a bucket, that is a filter defect. Report it loudly and do NOT terminate.** This is what makes the failure self-diagnosing instead of silent: any future change that starts erasing issues from the workable queue surfaces as a growing bucket 11, by construction, instead of silently shrinking bucket 10 to zero. Never force an unaccounted issue into a parked bucket to make the ledger look clean — a guessed placement reproduces exactly the miscounting this ledger exists to catch (both prior corrections above were miscounts in the safe-looking direction, i.e. *more* parked than reality).

A non-zero bucket 10 (dispatchable) at exit is **not automatically a defect** — a session can legitimately stop on a bound (token budget, `--max-*`, an explicit user `stop`). But such a stop must **name the bound**, never claim completion. Render the terminal message as one of exactly two honest shapes:

- `0 dispatchable of <total> open — complete, see ledger` — only when bucket 10 AND bucket 11 are both 0.
- `<N> dispatchable of <total> open — stopped on <bound>, see ledger` — bucket 10 is non-zero, or bucket 11 is non-zero (in which case `<bound>` is `unaccounted issues — filter defect, see below`).

Never print a bare "backlog empty" / "nothing left to do" from queue-emptiness alone; always render through this ledger.

## Building the ledger — no new `gh` calls

The ledger is computed entirely from data the caller already has: the fresh open-issue fetch ([step 4](./04-backlog-divert.md#4-fetch--rank-the-backlog)'s wide fetch at setup time, or [`drain.md` termination step 4](../drain.md#termination-assertion)'s fresh-fetch verification at drain time) joined against the orchestrator-state queues (`in_flight`, `failed_prs`, `ready_issues`, `raw_backlog`, `investigate_candidates`, `deferred_issues`, `trusted_authors`) and the already-computed `closed_by_open_healthy_pr` set. Walk the fetch's issue list once; for each issue, test the eleven signals **in the table's order** and stop at the first match — the order matters because a few signals could otherwise double-match (e.g. an issue in `raw_backlog` that also carries a stale `agent-console` label from a prior session belongs to bucket 5, checked before bucket 10). An issue that falls through every test lands in bucket 11.

Render as a fixed-width table (mirroring [`cleanup-summary.md`'s existing bucket-breakdown shape](../cleanup-summary.md#end-of-session-summary)) or, on a small backlog, the compact inline form from the issue's own worked example:

```
34 open · 14 dispatchable
  10 → PR open, awaiting merge
   4 → human-gated                    #3191 #3833 #3838 #3913
   1 → operator queue (agent-console) #3790
   4 → blocked by open sibling        #3903 #3904 #3908 #3909
   2 → time-gated                     #3605 (2026-10-01)  #2691 (2026-11-01)
  13 → dispatchable by a code worker
   1 → dispatchable via operator phase
```

## Where this is invoked

- **[`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)'s early exit** — when `raw_backlog` is empty and no failing PRs exist, build the ledger from the fetch that just ran (Hole 1's fix — this makes the "empty" claim traceable instead of asserted).
- **[`drain.md`'s termination assertion](../drain.md#termination-assertion)**, step 4's fresh-fetch verification — build the ledger from the same fresh fetch before concluding the net-new set is empty (Hole 2 + 3's fix — `raw_backlog` and `investigate_candidates` are load-bearing signals in the table above, not an afterthought subtraction).
- **[`cleanup-summary.md`'s End-of-session summary](../cleanup-summary.md#end-of-session-summary)** — the bucket-breakdown table already there is the user-facing rendering of this same ledger; its `Workable` row is bucket 10, and an `Unaccounted` row (when non-zero) renders bucket 11.

## Composes with, does not implement

**[#1247](https://github.com/mattsears18/shipyard/issues/1247) has landed** — the bucket-assignment logic above calls the shared [`scripts/backlog-filter.sh classify`](../../../scripts/backlog-filter.sh) rather than re-testing each signal inline; see that step's own invocation for the exact shape.

**[#1246](https://github.com/mattsears18/shipyard/issues/1246) has also landed**, but only at two of this ledger's own two invocation-adjacent call sites — [`drain.md`'s termination assertion](../drain.md#termination-assertion) stamps `unfiltered_open_count` / `me_assigned_open` / `last_fresh_fetch` immediately before building the ledger from the same fresh fetch, and [steady-state.md step C](../steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) stamps them on every dispatch. At the **drain-termination** invocation, `<total>` and `unfiltered_open_count` are computed from the identical fetch in the same step — read `unfiltered_open_count` from session state directly there rather than re-deriving a `length` count, so the ledger's header and the invariant line can never silently disagree with each other about the size of the same universe. **At the [`04-backlog-divert.md`'s early exit](./04-backlog-divert.md#4-fetch--rank-the-backlog) invocation — setup time, before step 7's initial pool fill — the token has NOT yet been stamped** (its documented initial value is `0` until the first re-check runs; see [`session-state-file.md`](../session-state-file.md)), so `<total>` there MUST still be derived by `length`-counting the fetch directly, exactly as before. Don't blindly wire both call sites to the session-state field — only the drain-termination one has a freshly-stamped value to read.

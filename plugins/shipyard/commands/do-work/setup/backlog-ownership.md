# /shipyard:do-work — Backlog bucket ownership

**The single source of truth for "who owns this issue?"** (issue [#1076](https://github.com/mattsears18/shipyard/issues/1076)). Every open issue in the backlog lands in exactly one bucket (first-match-wins, per [`01b-backlog-overview.md`](./01b-backlog-overview.md#2-backlog-overview)'s ordered list), and every bucket has exactly one owner: `/do-work`, `/my-turn`, another shipyard command, or an explicit **`nobody (by design)`** with a stated reason. `nobody (by design)` is a *decision* — writing the reason down is what tells it apart from a bucket that reaches nobody by accident.

## Normative source, and what this table is

[`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)'s **client-side filter** is the normative definition of what `/do-work` actually dispatches — it's the code path that runs every session. [`01b-backlog-overview.md`](./01b-backlog-overview.md#2-backlog-overview)'s per-issue bucket table is a **rendering** of that filter for the upfront session summary. This file exists so the Owner column has exactly one home, instead of being re-described independently in each of `01b`, `04`, and `/my-turn` — the original defect #1076 fixes: three descriptions of the same routing, never cross-checked, silently drifted apart.

[`scripts/tests/backlog-ownership-coverage.test.sh`](../../../scripts/tests/backlog-ownership-coverage.test.sh) enforces two invariants mechanically, on every PR:

1. **Coverage.** Every bucket row below has a non-empty Owner, and every `nobody`-owned row has a stated reason in Notes. A bucket added here without an owner fails the suite.
2. **Structural agreement.** Every bucket `#` here appears in `01b`'s own bucket table (and vice versa) — a bucket one file knows about and the other doesn't is exactly the drift class #1076 found (the `agent-console` bucket was missing from `01b` entirely before this fix). Every label token cited here (`` `wontfix` ``, `` `agent-console` ``, ...) is asserted to be textually present in `04`'s client-side filter, so a label renamed or dropped from the dispatcher without updating this table fails loudly.

This is a **structural** check, not a full semantic-equivalence check — it does not compare `01b`'s prose description of a bucket's *disposition* against `04`'s actual runtime behavior word-for-word. Bucket 5 was the motivating example for that gap: `01b` and `04` used to describe `needs-triage`'s handling in language that read differently even though both cited the same underlying behavior. [#1077](https://github.com/mattsears18/shipyard/issues/1077) reconciled the wording — `01b`'s bucket-5 row now states the trusted/untrusted split and the `triage.investigate_dispatch` config dependency directly, matching `04`'s client-side filter — so this table's Owner cell (`/do-work`, per the corrected tally in #1076) and `01b`'s prose no longer disagree.

## Ownership table

| # | Bucket | Criteria (label / condition) | `/do-work` disposition | Owner | Notes |
|---|---|---|---|---|---|
| 0.5 | Untrusted author | `author.login` NOT in `trusted_authors` | dropped, no label applied | **nobody** | Gap — tracked in #1079 |
| 1 | Assigned to others | `assignees` contains a user other than `@me` | dropped | **`/my-turn`** | P2 housekeeping when the assignee has no activity for >30d (see [`my-turn.md`](../../my-turn.md) Pass B) — was a gap before #1076 |
| 2 | In flight | issue number in the `linked:pr` set | owned, tracked via its PR | **`/do-work`** | |
| 3 | Won't fix | carries `wontfix` | dropped | **nobody (by design)** | `wontfix` means no path forward — reaching nobody is the intended outcome |
| 4 | Discussion | carries `discussion` | dropped | **nobody (by design)** | A maintainer is already engaged in the thread by hand; not an oversight — was indistinguishable from one before #1076 |
| 5 | Needs triage | carries `needs-triage` | trusted-author → routed to `investigate_candidates` and dispatched via investigate mode when `triage.investigate_dispatch` is `true` (default); untrusted-author → dropped (folds into 0.5) | **`/do-work`** (default) — **`/my-turn`** only when `triage.investigate_dispatch: false` | `investigate_dispatch: false` restores the pre-#556 skip-and-surface behavior and is the *only* config under which this bucket is human-owned (#1077). `/my-turn`'s Pass B carries a `needs-triage` signal gated on that same config value — resolved once at setup (see [`my-turn.md`](../../my-turn.md) Setup step 3) — so it fires only in that narrow case and stays silent under the default. |
| 5.4 | Awaiting refinement | source-signal match (see `01b`) | processed by `/refine-issues` at session startup | **`/do-work`** (via `/refine-issues`) | |
| 5.5 | Awaiting human review | carries `needs-human-review` | dropped | **`/my-turn`** | The one originally-clean handoff |
| 5.6 | Agent-console (operator action) | carries `agent-console` (legacy `needs-operator`) | dropped from code-worker dispatch | **`/do-work`** (operator phase) | `/my-turn` surfaces one pointer line only, never walks it individually |
| 6 | Blocked (soft label) | carries `blocked:agent-soft` | workable — NOT excluded | **`/do-work`** | Auto-clears at next session |
| 7 | Blocked (body reference) | body matches `Blocked by #N`, #N still open | dropped | **`/do-work`** | Auto-clears the instant the blocker closes |
| 8 | Workable | everything else | dispatched | **`/do-work`** (implements) + **`/my-turn`** (surfaces "authored by `$ME`, no linked PR" as a triage signal) | Overlap — tracked in #1078 |

## Reading this table

- **Bold Owner** is who acts on the issue next. `nobody (by design)` is a deliberate dead-end, not a gap — the Notes column always states why, and the coverage test rejects a `nobody` row with empty Notes.
- A row whose Notes cites an open tracking issue (#1078 / #1079) is a **known, separately-scoped** gap or overlap, not something this table or its coverage check papers over. Resolving one of those issues means updating that row's Owner/Notes here, not re-deriving the table from scratch. **#1077 (bucket 5's `01b`-vs-`04` wording mismatch) was one of these and is now resolved** — the row's Owner/Notes above reflect the reconciled routing, including the narrow `investigate_dispatch: false` human-ownership case.
- Issue [#1076](https://github.com/mattsears18/shipyard/issues/1076) is what gave buckets **1** and **4** their first real, stated owner. The three higher-value cells (0.5, 5, 8) were deliberately left as open, separately-tracked gaps rather than folded into that same PR — see the issue's own scope note. Bucket 5's wording gap is closed by #1077; 0.5 and 8 remain open (#1079 / #1078).

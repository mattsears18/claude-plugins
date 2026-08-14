# /shipyard:do-work — Setup phase · `tracking`'s provisional-gate justification requirement

Fragment of step **4** ([`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)) — deep-link only, from `04`'s "Drop issues carrying any of the dispatch-gate labels" bullet, specifically the `tracking` member of that set. Not part of the ordered per-session walk; loaded only when that bullet is reached.

## Why `tracking` needs its own rule ([#1364](https://github.com/mattsears18/shipyard/issues/1364))

The other four labels in the drop-label set — `blocked:ci`, `wontfix`, `discussion`, `needs-human-review` — are settled, intentional gates with a stated, permanent owner in [`backlog-ownership.md`](./backlog-ownership.md#ownership-table). Label presence alone is sufficient justification for those: a human (or a documented automated path) applied the label deliberately, so seeing it is enough to drop the issue.

`tracking` is different. It's documented in that same ownership table as a *defensive* gate ([#1081](https://github.com/mattsears18/shipyard/issues/1081)) against the label object never being fully migrated to `needs-human-review` — not a settled routing decision on its own. A `tracking` label can be stale, leftover from a workflow that predates the migration, with no live content in the issue body actually requiring human judgment. Dropping every `tracking`-labeled issue on label presence alone, the same way the other four are dropped, risks silently parking workable issues that happen to still carry the old label.

## The rule, stated once

**`tracking` alone is a PROVISIONAL member of the drop-label set, and a provisional gate may not fire on label presence alone.**

The script's `has_tracking_justification()` requires the issue body to carry at least one recognized human-owned signal before it will drop the issue on `tracking` grounds:

- a `Decision required` heading
- an `Options` heading
- a `Blocked by #N` reference

## The two verdict shapes this produces

- **Justified** — at least one signal matched. The script emits the plain `{"verdict":"gate","reason":"tracking","evidence_pointer":"<matched signal>"}` shape, identical in structure to the other four settled gates.
- **Unjustified** — no signal matched. The issue is still dropped (a `tracking` label is a strong enough prior that a false-negative auto-dispatch is the worse failure mode — re-dispatching a genuinely-tracking issue as workable code work is worse than parking a stale one), but the script emits `{"verdict":"gate","reason":"tracking-unjustified"}` instead — a distinct, greppable reason with no fabricated `evidence_pointer`. The drop is **surfaced, not silently indistinguishable from every other justified gate**.

[`04f-completion-ledger.md`](./04f-completion-ledger.md#the-bucket-taxonomy)'s census renders `tracking-unjustified` issues as their own sub-line under the Human-gated bucket rather than folding them into the flat count — so a session with a pile of unjustified `tracking` drops is visible in the summary, not averaged away.

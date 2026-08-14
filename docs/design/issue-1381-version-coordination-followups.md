# Spike: are land-time bump / placeholder-resolve / `changelog.d` fragments worth doing on top of #1380's in-process DIRTY resolver?

**Issue:** [#1381](https://github.com/mattsears18/shipyard/issues/1381)
**Date:** 2026-08-14
**Conclusion:** **Not viable / not recommended — do nothing further.** All three structural directions are either mechanically blocked by this repo's own `main` ruleset, empirically counterproductive, or a rerun of a mechanism this repo already built and deliberately deleted. Direction 4 (#1380) is the right and sufficient answer. No follow-on sub-issues filed.

## Problem / question

Every PR in this repo cuts its own release: it bumps `plugins/shipyard/.claude-plugin/plugin.json`'s `.version` row and prepends a `### <version> — <date>` entry to `CHANGELOG.md`. The version is allocated at **dispatch** time, so when a sibling PR merges first, every other in-flight PR goes DIRTY on those two rows. [#1377](https://github.com/mattsears18/shipyard/issues/1377) measured the cost: one session spent 8 of 25 dispatches (~32%, ~1.11M input tokens) on the mechanical renumber.

[#1380](https://github.com/mattsears18/shipyard/pull/1380) shipped **direction 4** — resolve the collision in-process instead of dispatching a whole `fix-rebase` worker. #1381 asks whether any of the three *structural* alternatives #1377 deferred is worth building **on top of** that:

1. **Land-time bump** — PR carries no version; a post-merge automation cuts the bump directly on `main`.
2. **Placeholder + merge-time resolve** — PR writes `0.0.0-pending` / `### UNRELEASED`; a merge-time hook substitutes the real version.
3. **`changelog.d/` fragments** — each PR adds a uniquely-named fragment file; a release step assembles `CHANGELOG.md`.

Re-litigating direction 4 is explicitly out of scope. The question is only whether the **residual** justifies a structurally larger change.

## Method

1. Read the *shipped* direction-4 code (`scripts/resolve-manifest-only-dirty.sh` on PR #1380's branch — the PR is still open, so it is not on `main` yet) and both of its call sites, rather than the issue's prose description of it.
2. Queried this repo's live `main` ruleset via the GitHub API for bypass actors and rules.
3. Ran a scratch-repo git experiment to test direction 2's central premise directly, rather than reasoning about it.
4. Traced [#691](https://github.com/mattsears18/shipyard/issues/691)'s retired backfill machinery to check whether direction 2 or 3 re-creates it.

## Findings

### 0. What direction 4 actually does — and what residual it leaves

`scripts/resolve-manifest-only-dirty.sh` is wired at **both** DIRTY-handling call sites, not just the drain:

- `commands/do-work/drain.md` per-poll action 2 — tried **first**, ahead of the pre-dispatch head-branch reap, the CI-minute gates, and any worker dispatch.
- `commands/do-work/steady-state.md`'s mid-session `merge == "DIRTY"` branch — tried before the #1034 mid-session `fix-rebase` dispatch.

It runs the rebase in an ephemeral `git worktree add --detach` under `.shipyard-scratch/`, resolves the manifest `.version` row (gated by a *structural* check: both sides' full manifest, version field blanked via `jq`, must be byte-identical) and a single-hunk CHANGELOG top-insert, runs four safety nets (`conflict-marker-scan`, `changelog-monotonicity-scan`, `assert-rebase-diff-nonempty`, `verify-added-lines-survived`), and force-pushes with a lease. Anything wider defers to the normal `fix-rebase` dispatch, unchanged.

The **cost of a resolved collision is therefore ~zero model tokens** — a few seconds of shell in the orchestrator's own process. What remains is:

- **One CI re-run per collision.** The force-push produces a new head SHA, so all five required checks re-run. This is paid in self-hosted runner minutes, not tokens.
- **The deferral cases** — a multi-hunk CHANGELOG conflict (a PR that also edited an older entry), a manifest conflict touching a second key, or any wider conflict. These still cost a `fix-rebase` dispatch, but they are exactly the cases that need judgment anyway.

That residual is the entire thing directions 1–3 would be bought to remove.

### 1. Mechanics rule out directions 1 and 2 outright

Both directions require an automation to write a commit to `main` after a PR merges. This repo forbids that, with no exceptions configured:

```
$ gh api repos/mattsears18/shipyard/rulesets/16669759 --jq '{bypass_actors, rules: [.rules[] | {type}]}'
{"bypass_actors":[],"rules":[{"type":"deletion"},{"type":"non_fast_forward"},
 {"type":"pull_request"},{"type":"required_status_checks"}]}
```

`bypass_actors` is **empty**. The ruleset applies to `~DEFAULT_BRANCH` and carries a `pull_request` rule plus five required status checks. No actor — a GitHub Actions workflow's `GITHUB_TOKEN`, the orchestrator, or even a repo admin — can push a bump or resolve commit directly to `main`. This is the `GH013: Changes must be made through a pull request` wall CLAUDE.md already documents, confirmed live rather than assumed.

There are exactly two ways around it, and both are worse than the problem:

- **Add a bypass actor.** This creates an unreviewed write path to `main` that skips all five required checks — precisely the ungated-merge shape [`scripts/detect-ungated-admin-direct-merge.sh`](../../plugins/shipyard/scripts/detect-ungated-admin-direct-merge.sh) exists to detect, and that #438 / #465 / #598 / #602 / #645 / #716 were filed to close. Trading a hard-won branch-protection invariant for a P3 overhead reduction is not a trade this repo should make.
- **Have the resolver open a second PR.** This repo **already built that**, and deleted it. #691's retired backfill machinery had exactly this fallback — an auto-merged `do-work/changelog-backfill-<M>` PR per shipped PR — and it was retired for PR-volume churn plus PR-number consumption that shifted worker version predictions off-by-one. Rebuilding it for a different token would recreate the same failure.

A third shape worth naming and dismissing: the resolver could push the real version to the **PR's own branch** just before merging (feature branches carry no ruleset). But a new push is a new head SHA, so it forces a **second full CI cycle on every PR** — where today only the *colliding* minority pays that. That makes the common case worse to improve the rare one, and it doesn't even eliminate the race: another PR can merge during the second CI cycle.

### 2. Direction 2's central premise is empirically false — and adopting it would regress #1380

Direction 2's stated pro is that "the placeholder text is textually *identical* across every open PR … so a rebase's manifest/CHANGELOG hunks are non-conflicting no-ops." Half of that is true. The CHANGELOG half is not.

Measured with a scratch git repo (two branches off a common base, each prepending a new entry block, then `git rebase`):

| Experiment | Setup | Result |
|---|---|---|
| 1 | Both sides prepend a **byte-identical** `### UNRELEASED — 2026-08-14` heading with differing body prose | **CONFLICTED** |
| 2 (control) | Both sides prepend a *differing* version heading (today's shape) | **CONFLICTED** |
| 3 | Both sides set the manifest to a **byte-identical** `"version": "0.0.0-pending"`, plus an unrelated file each | **CLEAN** |

So the placeholder buys a clean auto-merge on the manifest `.version` row (experiment 3) and buys **nothing** on the CHANGELOG (experiment 1).

Worse, it changes the CHANGELOG conflict into a **strictly harder shape**. Because the heading line is now shared, git merges it and pushes the conflict *inside* the entry body. The measured result, reproduced verbatim below except that each conflict-marker line is indented two spaces so this file stays clean under the repo's own `conflict markers` required check:

```
### UNRELEASED — 2026-08-14

  <<<<<<< HEAD
Branch A did a thing.
  =======
Branch B did a different thing.
  >>>>>>> 76402e7 (b)

### 1.0.0 — 2026-08-01
```

One heading, two competing bodies. The correct resolution is not a concatenation — it is a **restructure**: split into two separate entry blocks and assign each a different version. Today's shape (two distinct `### <version>` headings) is at least a deterministic "take both blocks, newest first," which is exactly what `fix-rebase.md` §4.6 and `resolve-manifest-only-dirty.sh` already do.

This is the decisive point: **the new shape fails direction 4's own gate.** `resolve-manifest-only-dirty.sh`'s `extract_single_hunk` gate requires *both* sides' conflicting content to begin with a `### ` heading line. Under direction 2 neither side would — the heading is shared and unconflicted, and the conflicting content is prose. The script would `defer "changelog-conflict-outside-top-insert"` on **every** collision, falling through to a full `fix-rebase` worker dispatch. Adopting direction 2 would therefore **reinstate the exact ~1.11M-token cost #1377 measured and #1380 eliminated.**

Direction 2 could be salvaged as "placeholder in the manifest only, keep real version headings in the CHANGELOG" — but then the CHANGELOG heading still needs a version at write time, which is the thing the placeholder existed to remove. It is circular.

### 3. #691 is direct precedent against direction 2

Direction 2 introduces a token whose value is unknown when the worker writes it and is patched in later by automation. That is precisely the mechanism [#691](https://github.com/mattsears18/shipyard/issues/691) removed, on a maintainer decision, in release 2.6.0:

> Per-entry PR numbers were never load-bearing … yet they were the root cause of a whole bug family: worker PR-number prediction (#690), the orchestrator's CHANGELOG-backfill machinery (#581 / #583) and its two mis-target hardenings (#700 / #704), plus one `do-work/changelog-backfill-<M>` PR per shipped PR (PR-volume churn + PR-number consumption that shifted worker predictions off-by-one). Per the maintainer's Option-3 decision, the number is dropped at the source … so there is nothing to backfill.

Five bug issues from one placeholder mechanism, plus per-PR churn. Direction 2 is that mechanism with `version` substituted for `PR #`. The decision recorded in #691 — *eliminate the unknown-at-write-time value rather than build machinery to resolve it* — applies unchanged.

### 4. Direction 3 clears the #691 concern but doesn't pay for itself

#1381 asks specifically whether direction 3's fragment-assembly step re-introduces #691's backfill machinery. **It does not.** Post-#691 CHANGELOG entries carry no unknown-at-write-time token — a fragment under `changelog.d/` would be authored complete by the worker, and the `### <version> — <date>` heading would be authored by the assembler at assembly time. Nothing is written-then-patched, so there is no backfill.

The direction fails for two other reasons:

- **It leaves the majority of the measured cost untouched.** The manifest `.version` row is a single shared line in a single shared file no matter how the CHANGELOG is organized. Direction 3 must be paired with direction 1, 2, or the already-shipped direction 4 to close that side — and if it's paired with direction 4, direction 4 is already handling the CHANGELOG case too, so the fragments add nothing.
- **The assembly step hits the same wall or breaks existing readers.** If assembled `CHANGELOG.md` stays committed, something must land the assembly commit — the protected-`main` problem from Finding 1, verbatim. If it becomes a generated artifact materialized only at release time, three consumers that read the file directly break: `plugins/shipyard/scripts/changelog-monotonicity-scan.sh`, `plugins/shipyard/scripts/conflict-marker-scan.sh`, and `.github/workflows/conflict-markers.yml` (a required status check).

## Options considered

| Option | Verdict |
|---|---|
| **Do nothing further** (direction 4 alone) | **Chosen.** The residual is one CI re-run per collision, paid in runner minutes. |
| Direction 1 — land-time bump | Rejected on mechanics (Finding 1). Also the most invasive: it inverts CLAUDE.md's release contract, strips bump authorship from four worker specs, and weakens per-PR release provenance. |
| Direction 2 — placeholder + merge-time resolve | Rejected on mechanics (Finding 1), on measurement (Finding 2 — it would regress #1380), and on precedent (Finding 3). |
| Direction 3 — `changelog.d/` fragments | Rejected (Finding 4). Clears the #691 concern but doesn't touch the manifest row and breaks or blocks on the assembly step. |
| Add a GitHub Actions bypass actor to unblock 1 or 2 | Rejected — recreates the ungated-write-path-to-`main` shape six prior issues exist to prevent. |
| Resolve on the PR branch just before merge | Rejected — forces a second full CI cycle on *every* PR to spare the colliding minority, and doesn't close the race. |

## Conclusion

**Not viable / not recommended.** #1377's own severity framing ("nothing is broken, this is pure overhead") and #1381's P3 are correct, and direction 4 already converted the expensive part of that overhead — model tokens — into a few seconds of shell. What is left costs CI minutes, and every structural alternative to it costs either a hole in branch protection, a rerun of a deleted mechanism, or a measured regression of the fix that already landed.

The relevant comparison is not "residual overhead vs. zero." It is "residual overhead vs. the cost and risk of removing it," and on this repo that cost includes weakening the `main` ruleset. CLAUDE.md already declines `strict_required_status_checks_policy: true` for a closely-related reason — it would force a rebase on nearly every PR at this repo's merge volume. The same judgment applies here.

## Decomposition plan

**Empty.** The conclusion is "don't build any of the three," so there is no follow-on work to file. Direction 4 is shipped and wired at both call sites; nothing in this spike identified a gap in it.

## What ships now vs. deferred

- **Ships now:** this design doc, plus a decision-of-record entry in [`plugins/shipyard/commands/do-work-RATIONALE.md`](../../plugins/shipyard/commands/do-work-RATIONALE.md) so the `/do-work` specs carry the "why not" alongside the machinery it applies to.
- **Deferred:** nothing. No sub-issues filed.

## Generalizable lesson

Two, both cheap to re-apply:

1. **Test a "these two edits won't conflict" claim with git, not with reasoning.** Direction 2's premise was plausible and stated confidently in the issue, and it took one scratch repo and three `git rebase` invocations to show it was half-wrong in a way that would have regressed the fix it was meant to build on.
2. **Check the branch ruleset before designing anything that writes to the default branch.** `bypass_actors: []` is a one-line API query that eliminated two of three candidate directions before any design work was needed.

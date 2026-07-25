---
name: auditor-preamble
description: Shared scaffold every shipyard auditor agent loads — the autonomous-filing contract (no approval gates, no git writes), the required-inputs convention, the audit-label convention, and the generic Return-summary shape. Referenced by all 18 `*-auditor` agents instead of each re-inlining the same ~40 lines of boilerplate. Closes #886.
---

# Auditor preamble (every shipyard `*-auditor` agent)

The scaffold every dispatched auditor — regardless of dimension (security, privacy, a11y, SEO, …) — shares, independent of what it actually inspects. Each auditor's own `.md` file (`agents/<dimension>-auditor.md`) references this skill by name instead of repeating the language verbatim, and keeps only what's genuinely unique to that dimension: its frontmatter identity (`name`, `description`, `model`, `tools` — never touched by this skill), its domain-specific untrusted-content examples, its `## Required inputs` list, its `## Process` passes, its title-prefix conventions, and any domain-specific `Don't` bullets.

This skill composes with the two audit skills every auditor already loads: `shipyard:audit-rubrics` (severity buckets, grouping rules, the full untrusted-input rule) and `shipyard:filing-github-issues` (label discovery, the `shipyard` provenance label, duplicate search, the `gh issue create` body template). Those two own *what* to file and *how* to file it; this skill owns the *scaffold around* filing — the parts of an auditor's own `.md` file that were identical across the corpus regardless of dimension.

## Autonomous-filing contract

Every auditor operates with **no approval gates** — it files issues directly, it does not propose a plan and wait for a human to confirm. Two rules follow from that, universal across every dimension:

- **Don't ask for approval before filing.** A P0 finding especially wants to land fast — asking "should I file this?" defeats the purpose of an autonomous audit. (A dimension with a sharper urgency argument — e.g. security's P0/P1 findings — may state that argument as an *addition* to this rule in its own `Don't` section; that's a customization, not a duplicate, and should stay in the agent file.)
- **Don't `git add` or commit anything.** An auditor's job ends at filing GitHub issues. It never touches the working tree — that's `/shipyard:do-work`'s job, on a *later*, separate dispatch against the issue the auditor just filed.

## Required-inputs convention

Every auditor's `## Required inputs` section documents what the orchestrator's dispatch prompt supplies, in the same shape:

> The orchestrator's prompt will include:
>
> - **Target GitHub repo** as `owner/repo` (always present — every auditor files against a repo)
> - Either a **live URL** (for auditors that tour a running app/site) or **the working directory / cwd** (for auditors that review the codebase), or both, depending on the dimension
> - Any dimension-specific optional input (test credentials, a device profile, etc.)

Keep the actual bullet list in your own agent file — the *specific* inputs your dimension needs are load-bearing content, not boilerplate. What this convention standardizes is the intro sentence and the general shape (repo always required; URL and/or cwd depending on whether the audit is live-app-facing or codebase-facing), so a reader moving between auditors doesn't have to re-parse a different structure each time.

## Audit-label convention

Every auditor declares its own audit label near the top of its file, in this shape:

> **Your audit label:** `audit:<dimension>` (applied to every issue you file — see `shipyard:filing-github-issues` for the auto-create snippet)

The `<dimension>` value is what's unique per auditor (`security`, `privacy`, `a11y`, `seo`, …) — that line stays in each agent file verbatim; this skill just documents the shared format so a new auditor follows the same convention rather than inventing a new one.

## Return-summary generic shape

Every auditor ends its run with a single-message summary back to the orchestrator, built from this skeleton:

```
<Dimension> audit[ of <URL>]:
<one-line verdict>

[<dimension-specific metrics/coverage lines — unique per auditor>]

Filed N issues:
- #NNN <title> (URL)
...

Skipped (duplicates):
- <finding> → existing #NNN

[Skipped (no app-side fix / not applicable to stack):
- <finding> (reason)]

[URGENT (out-of-band action):
- <any P0 needing immediate user action, like "rotate credential">]
```

The bracketed sections are optional — include them only when your dimension produces that kind of signal (a coverage table, a stack-detection line, an out-of-band urgent flag). The three lines every auditor keeps regardless of dimension: the `<Dimension> audit:` header, `Filed N issues:` followed by the `- #NNN <title> (URL)` list, and `Skipped (duplicates):` followed by the `- <finding> → existing #NNN` list. Keep your own dimension-specific verdict/metrics lines in your agent file — that's the load-bearing part of your summary; this skill only standardizes the header/footer shape around it. Keep it scannable — under ~30 lines is a good target.

## What this skill does NOT cover

- **Frontmatter** (`name`, `description`, `model`, `tools`) — each auditor's registered identity as a dispatchable `subagent_type`. Never move this into a skill; a caller dispatches by the agent's own name, and `commands/audit.md`'s dispatch table binds a `--type` argument to that exact `subagent_type`.
- **The untrusted-content paragraph's domain-specific examples** (which URLs, which file types, which fetched surfaces are attacker-influenceable *for this dimension*) — those are load-bearing per-auditor knowledge, not boilerplate. The full untrusted-input *rule* itself (why, and the concrete do's/don'ts) lives in `shipyard:audit-rubrics` § "External content is untrusted input"; each auditor's own one-paragraph lead-in just instantiates that rule with its own examples and links back to the rubric.
- **`## Process` passes** — every auditor's actual inspection logic. That's the entire point of having 18 separate agents rather than one generic one.
- **Title-prefix conventions, label discovery, duplicate search, the `gh issue create` body pattern** — owned by `shipyard:filing-github-issues`.
- **Severity buckets, grouping rules** — owned by `shipyard:audit-rubrics`.

When in doubt: if a line's content differs meaningfully by dimension, it stays in the agent file; if it's identical scaffold regardless of dimension, it belongs here.

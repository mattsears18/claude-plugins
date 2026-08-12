---
description: Bring the repo's milestone roadmap current — assign a milestone to every open issue that lacks one, author new phases where the backlog has outgrown the existing ones, check each phase's stated bet against reality, detect issue dependencies, and surface judgment calls a human should make.
argument-hint: [--repo owner/repo] [--dry-run]
---

# /shipyard:update-roadmap

Run the [`shipyard:update-roadmap`](../skills/update-roadmap/SKILL.md) skill against the current repo's open backlog and its GitHub Milestones. Closes [#1240](https://github.com/mattsears18/shipyard/issues/1240).

This command is a **thin invocation wrapper** — every rule that governs what gets applied directly vs. proposed, the cold-start authoring procedure, the honesty checks, and the dependency-detection sweep live in the skill itself. Read it before running this command by hand; this file only owns argument resolution and the top-level control flow.

**Orchestrator-only.** This command (and the skill it runs) must never be invoked from inside a dispatched `/shipyard:do-work` worker's own turn — see `shipyard:worker-preamble`'s [`milestone-prohibition.md`](../skills/worker-preamble/milestone-prohibition.md) fragment for the worker-side half of this boundary, and the skill's own ["Who runs this"](../skills/update-roadmap/SKILL.md#who-runs-this) section for why. Invoke this command directly (a human running `/shipyard:update-roadmap`), or from a scheduled periodic trigger (`/loop 1d /shipyard:update-roadmap`) — never from a worker's dispatch prompt.

## When to use

- Periodically, to keep the roadmap from decaying quietly — wire it into `/loop` (`/loop 1d /shipyard:update-roadmap`) for a recurring sweep with no webhook setup, the same pattern `/shipyard:audit-scheduled` and `/shipyard:eas-watch` use.
- By hand any time the backlog has grown enough that "what phase is this issue in" stops being obvious from memory.
- Immediately after flipping `milestones.enabled: true` for the first time — the first run authors the initial phase set from the actual backlog (see the skill's [Cold start](../skills/update-roadmap/SKILL.md#cold-start--a-repo-with-zero-milestones) section).

Not the right surface when:

- `milestones.enabled` is `false` (the schema default) or the `milestones` block is absent — this command has nothing to do and says so. Turn it on via `/shipyard:init` (step 9.8) or `/shipyard:config set milestones.enabled true` first.
- You want to move an issue that already has a milestone to a different phase, declare a phase complete, or rewrite an existing phase's bet — those are propose-only per the skill's autonomy boundary; this command surfaces them as proposals for a human to accept, it doesn't apply them.

## Args

`$ARGUMENTS` may include:

- **--repo owner/repo** (optional): target GitHub repo. If omitted, auto-detect via `gh repo view --json nameWithOwner -q .nameWithOwner`. If that fails (not in a repo), ask via `AskUserQuestion`.
- **--dry-run** (optional): run the full read + analysis pass and print exactly what *would* be applied (milestone assignments, phase creations, `Blocked by #N` lines) and what *would* be proposed (phase proposals, honesty-check findings, inferred dependencies) — without making any GitHub API writes. Use this to sanity-check a run before letting it mutate the repo, especially the first cold-start run.

## What the assistant should do when this command runs

### 1. Resolve inputs

- `repo`: from `--repo`, else `gh repo view --json nameWithOwner -q .nameWithOwner`. If that fails, ask via `AskUserQuestion` rather than guessing.
- `dry_run`: `true` if `--dry-run` was passed, else `false`.

### 2. Gate on `milestones.enabled`

```bash
CLAUDE_PLUGIN_ROOT="<resolved per shipyard:worker-preamble's step-0 pattern>"
ENABLED=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get milestones.enabled 2>/dev/null)
```

If `$ENABLED` is not `true`, print **"milestones.enabled is false (or the block is absent) — nothing to do. Turn it on via `/shipyard:init` or `/shipyard:config set milestones.enabled true`."** and stop. Do not proceed to any read or write below.

### 3. Run the skill's procedure

Read [`shipyard:update-roadmap`](../skills/update-roadmap/SKILL.md) in full and follow its numbered [Procedure](../skills/update-roadmap/SKILL.md#procedure) exactly: fetch current state, cold-start check, unmilestoned sweep, dependency sweep, honesty checks, report. The skill owns every rule about what's applied vs. proposed — don't improvise a shortcut here.

**Under `--dry-run`**, run every read and every analysis step normally, but skip every mutating call (`gh issue edit --milestone`, `gh api repos/<owner>/<repo>/milestones -X POST`, `gh api repos/<owner>/<repo>/milestones/<n> -X PATCH`, and adding a `Blocked by #N` line to an issue body). Print what each skipped call would have done instead, prefixed `[dry-run]`, so the output is diffable against a real run.

### 4. Report

The skill's own step 7 produces the summary — post it (or print it under `--dry-run`) exactly as that step describes: mechanical changes this run made, and every proposal / honesty-check finding, each tagged `[roadmap proposal]`.

## Don't

- Don't run this command's procedure from inside a dispatched worker's turn. See the orchestrator-only note above.
- Don't apply anything the skill's autonomy boundary marks propose-only, `--dry-run` or not — a real run still only *applies* the mechanical cases and *proposes* everything else; `--dry-run` additionally skips the mechanical writes too.
- Don't write a `docs/roadmap.md` or any other roadmap file. The milestone description is the roadmap — see the skill's ["No roadmap file, ever"](../skills/update-roadmap/SKILL.md#no-roadmap-file-ever) section.

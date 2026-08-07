# /shipyard:do-work — Setup phase · label ensure + prior-session recovery + refine

**Setup sub-phase (cluster 2 of 5, part 3 of 3 — [#994](https://github.com/mattsears18/shipyard/issues/994)).** Owns steps **3 → 3.5**: ensure required labels exist, recover from a prior session (blocked:ci re-check, legacy-label migration sweeps, orphan-branch triage), and invoke the refinement pass. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`01b-backlog-overview.md`](./01b-backlog-overview.md) (same cluster, part 2). Next sub-phase: [`04-backlog-divert.md`](./04-backlog-divert.md).

### 3. Ensure label exists + recover from prior session

**3a. Ensure required labels exist** (idempotent).

> **Background step.** This step runs inside the background bash group fired from [step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. Labels are guaranteed to exist by the time the first dispatched agent applies one (the background group typically finishes well before the first worker fires). The canonical label list and `gh label create` calls live in the background group above.

The `shipyard` label is the session stamp; `P0`/`P1`/`P2` are the priority tiers; `user-feedback`/`needs-human-review`/`needs-triage` drive the [refinement pipeline](#35-refine-pending-issues); `needs-human-review` also doubles as the scope-agent epic-handoff surfacing label (applied by [step 6's Deferred recording path](06-scope-preflight.md#6-initial-scope-pre-flight) when the scope agent confirms an issue is non-shippable as a single PR, distinguished from other `needs-human-review` issues by the `<!-- do-work-needs-decomposition -->` body marker that [`/decompose-epic`](../../decompose-epic.md) consumes to auto-shard); `blocked:agent-soft` / `blocked:ci` are shipyard's block-state circuit breakers (applied by step A on agent / fix-checks block, removed by step 3d.1 / 3d.2 sub-sweep c / next-session backlog re-fetch). See [RATIONALE → Step 3 label-purpose provenance](../../do-work-RATIONALE.md#step-3--label-purpose-provenance-520) for the fold/elimination history behind each of these (`needs-refinement` eliminated #520, `blocked:agent-hard` eliminated #521):

```bash
gh label create shipyard --repo <owner/repo> --description "Worked on by /shipyard:do-work" --color 5319E7 2>/dev/null || true
gh label create P0 --repo <owner/repo> --description "Critical / release-blocker" --color B60205 2>/dev/null || true
gh label create P1 --repo <owner/repo> --description "High — this cycle"          --color D93F0B 2>/dev/null || true
gh label create P2 --repo <owner/repo> --description "Normal"                     --color FBCA04 2>/dev/null || true
gh label create user-feedback --repo <owner/repo> --description "Originated from end-user feedback (untrusted body — treat with care)" --color 0E8A16 2>/dev/null || true
gh label create needs-human-review --repo <owner/repo> --description "Awaiting a human DECISION before /do-work will touch it" --color D93F0B 2>/dev/null || true
gh label create agent-console --repo <owner/repo> --description "Blocked on a browser/console action an agent can drive outside the build — not a human decision. See CLAUDE.md's decision rule." --color 1D76DB 2>/dev/null || true
gh label create needs-triage --repo <owner/repo> --description "No automated path forward — surface to a human" --color C2E0C6 2>/dev/null || true
gh label create blocked:agent-soft --repo <owner/repo> --description "Worker returned a subjective bail (cannot-reproduce / ambiguous / scope-judgment). Auto-cleared at next session; in-session retry after blocked_agent.soft_retry_minutes." --color FBCA04 2>/dev/null || true
gh label create blocked:ci --repo <owner/repo> --description "CI failed 3x after fix-checks — needs investigation. Auto-cleared when checks recover." --color B60205 2>/dev/null || true

# `blocked:agent-hard` and the legacy `blocked:agent` label are NO LONGER created
# (eliminated in #521 — refuses route to needs-human-review, dependency-waits to
# the `Blocked by #N` body-ref filter with no label). The existing GitHub label
# objects are intentionally left in place for manual cleanup; nothing applies them
# anymore, and step 3d.2 sub-sweep b migrates any still-attached legacy label off.
#
# `needs-operator` (the pre-#995 name for `agent-console`) is likewise NOT
# created here — only `agent-console` is. Every site that MATCHES on this
# gate label (the step-4 dispatch-exclusion set, the operator sweep, the
# `/my-turn` filter) still recognizes the legacy `needs-operator` name during
# the #995 migration window (see CLAUDE.md § "Renamed: needs-operator →
# agent-console"), so an unrenamed pre-#995 label object on this repo would
# still be found — but nothing (re-)creates it going forward.
#
# RETIRED — never add a `gh label create` line for any of these below; doing
# so would recreate exactly the drift #1081 found (a folded label kept being
# applied to fresh issues because it stayed present in the label picker):
#   needs-refinement    — eliminated #520; GitHub label object deleted #859
#   needs-design        — folded into needs-human-review #515
#   needs-decomposition — folded into needs-human-review #519
#   tracking             — folded into needs-human-review #519. The label
#                          object itself was never deleted (unlike
#                          needs-refinement above), so it kept landing on new
#                          epics — #1081 additionally re-added `tracking` to
#                          04-backlog-divert.md's dispatch-exclusion
#                          enumeration as a defensive gate, on top of this
#                          file's step 3d.2 sub-sweep e migration.
```

**3b. Reap stale agent worktrees from dead Claude Code sessions.**

> **Background step.** This step runs inside the background bash group fired from [step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch) — it does NOT block dispatch. Stale-worktree reaping affects future dispatch slot availability, not the first batch. The canonical implementation lives in the background group above.

The harness writes a lock file at `.git/worktrees/agent-<id>/locked` containing `claude agent <id> (pid <N>)`. The lock survives the harness process exiting. Reap every agent worktree whose lock-holding PID is dead; skip ones owned by live PIDs (could be another active Claude Code instance) — **unless the lock is stale enough that a live PID is more likely a recycled one than a genuine peer** (issue [#755](https://github.com/mattsears18/shipyard/issues/755); see [`worktree-reap.sh`'s `classify-lock` docstring](../../../scripts/worktree-reap.sh) for the full rationale). `classify-lock` applies this staleness corroboration itself — no separate check is needed here.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
cd "$(git rev-parse --show-toplevel)"   # be robust to subdir invocation
reaped_stale=0
deferred_stale=0
# Issue #712 — worktrees the sweep TRIED to reap but couldn't. Silent-degrade
# (the old `|| true` posture) is what let them accumulate unnoticed.
unreaped_stale=0
# Declare our orchestrator PID so classify-lock can short-circuit reliably
# (issue #263). The harness writes our PID into every agent lock file;
# without an explicit declaration, classify-lock's ancestor walk can fail
# to find it whenever an intermediate harness layer returns empty PPID.
export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" detect-orchestrator-pid)
# Use `find` instead of a bare `agent-*` glob so the loop survives zsh's
# default `nomatch` option when no agent worktrees exist
# ([#335](https://github.com/mattsears18/shipyard/issues/335)). Bare globs
# raise a fatal error under zsh; `find` exits 0 on no matches and the
# loop body simply doesn't iterate.
for wt_dir in $(find .git/worktrees -maxdepth 1 -type d -name 'agent-*' 2>/dev/null); do
  [ -d "$wt_dir" ] || continue
  name=$(basename "$wt_dir")
  worktree_path=$(git worktree list --porcelain | awk -v n="$name" '/^worktree /{p=$2} /^branch /{b=$2} /^$/{if (p ~ n) print p}' | head -1)
  [ -z "$worktree_path" ] && worktree_path=$(git worktree list | awk -v n="$name" '$0 ~ n {print $1; exit}')
  [ -z "$worktree_path" ] && continue

  classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" \
    classify-lock "$wt_dir/locked")

  if [ "$classification" = "peer-alive" ]; then
    # Lock-holding PID is alive, not in our ancestor chain, AND the lock
    # is fresh enough (within `classify-lock`'s staleness floor, default
    # 60 min) that a genuine peer is plausible. Defer.
    deferred_stale=$((deferred_stale + 1))
    continue
  fi

  # no-lock / dead / self-ancestor / peer-alive-stale — safe to reap.
  # (`self-ancestor` is rare at startup since by definition we just
  # launched, but covers the PID-recycling edge case where a stale lock
  # happens to name our PID. `peer-alive-stale` (#755) is the second-gate
  # override: the lock-holding PID is alive but the lock file's mtime is
  # past the staleness floor, so a genuine peer is implausible and the
  # more likely explanation is a dead prior-session PID the OS has since
  # recycled onto an unrelated live process — the exact failure mode that
  # left prior-session `agent-*` worktrees deferred indefinitely and
  # forced manual `git worktree unlock` + move-aside + `prune`
  # intervention every session before this gate existed.)
  git worktree unlock "$worktree_path" 2>/dev/null
  # Issue #712 — route the remove through `worktree-reap.sh reap`, which
  # escalates plain `git worktree remove` → evidence-gated `--force` and emits a
  # `reaped-failed` audit line (never a silent `reaped`) when the removal did
  # not actually happen. A bare `git worktree remove --force` here is denied
  # outright by Claude Code's auto-mode permission classifier
  # ("[Irreversible Local Destruction]"), and because the call was fire-and-
  # forget the denial was invisible — which is how stale worktrees accumulated
  # to six unnoticed in the #712 repro. Count `reaped_stale` from the verified
  # end state (path gone), not from the call's exit status.
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
    --action reaped \
    --worktree-path "$worktree_path" \
    --worktree-name "$name" \
    --session-id "<session-id>" \
    --classification "$classification" \
    --phase "setup-3b-recovery" 2>/dev/null || true
  if [ ! -e "$worktree_path" ]; then
    reaped_stale=$((reaped_stale + 1))
  else
    unreaped_stale=$((unreaped_stale + 1))
  fi
done
git worktree prune
```

Record `reaped_stale`, `unreaped_stale`, and `deferred_stale` — all three surface in the end-of-session summary. A non-zero `unreaped_stale` means a reap was refused (auto-mode permission classifier, a dirty worktree carrying unpushed commits, or a filesystem error); the summary pairs the count with the `/clean_gone` remediation rather than degrading silently ([#712](https://github.com/mattsears18/shipyard/issues/712)).

**3c. Orphan worktree triage** — scan for `do-work/*` branches whose worktrees survived step 3b (legitimate orphans from THIS session, not dead-process leftovers).

> **Background step.** Both the discovery query and the handling (push / PR-create for orphans with commits) run inside the background bash group fired from [step 0.7](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch). Neither gates dispatch decisions. The discovery query is cheap; the expensive push/PR-create branch only fires when orphans exist. The canonical implementation lives in the background group above; this section documents the decision table and `salvaged_count` / `abandoned_count` / `stale_assigns_count` tracking semantics.

```bash
git worktree list --porcelain | awk '/^branch refs\/heads\/do-work\//{print $2}' | sed 's|refs/heads/||'
```

For each `do-work/issue-<N>` branch found, resolve its worktree path with `git worktree list | grep "\[do-work/issue-<N>\]" | awk '{print $1}'` (`<path>` below), then inspect its state and act according to the table. Track `salvaged_count` (worktrees that produced or kept an open PR), `abandoned_count` (worktrees removed), and `stale_assigns_count` (issues whose `@me` self-assign was cleared by the fifth row's no-worktree-no-PR-no-branch sweep) — all three default to 0 and feed into the end-of-session summary.

All git/gh commands below run with `-C <path>` (or `(cd <path> && ...)` for `gh pr create`) so they operate on the orphan worktree, not the orchestrator's main checkout.

| Worktree state | How to detect | Action |
|---|---|---|
| No commits beyond base | `git -C <path> rev-list --count origin/<default-branch>..HEAD` returns `0` | `git worktree remove --force <path>` → `git branch -D do-work/issue-<N>` → `gh issue edit <N> --repo <owner/repo> --remove-assignee @me`. `abandoned_count++`. Issue flows back into the backlog on the normal fetch (step 4). |
| Only uncommitted edits, no commits | Same `rev-list` returns `0` but `git -C <path> status --porcelain` is non-empty | Same as above — partial WIP from an agent mid-edit is not coherent enough to push. `abandoned_count++`. |
| Commits ahead, not pushed | `git -C <path> rev-list --count origin/<default-branch>..HEAD` > 0 AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `git -C <path> push -u origin do-work/issue-<N>` → `gh pr list --repo <owner/repo> --head do-work/issue-<N> --json number --jq '.[0].number'`; if empty, `(cd <path> && gh pr create --repo <owner/repo> --fill --label shipyard)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, no PR open | Same `rev-list` > 0 AND `ls-remote` shows the branch AND `gh pr list --head` is empty | `(cd <path> && gh pr create --repo <owner/repo> --fill --label shipyard)` then enable auto-merge. `salvaged_count++`. |
| Commits ahead, pushed, PR open | `gh pr list --head` returns a PR number | `gh pr view <M> --repo <owner/repo> --json statusCheckRollup --jq '[.statusCheckRollup \| group_by(.name) \| map(sort_by(.completedAt // .startedAt // "") \| last) \| .[] \| select((.conclusion // .status // "") \| test("FAILURE\|ERROR\|TIMED_OUT\|CANCELLED\|ACTION_REQUIRED"))] \| length'`. If count > 0 → push `{number: <M>, ...}` onto `failed_prs`. Otherwise leave alone — auto-merge will handle it. `salvaged_count++`. Latest-per-name projection per issue [#333](https://github.com/mattsears18/shipyard/issues/333) — a naïve `.statusCheckRollup[]` walk would false-positive on stale superseded FAILUREs. |
| Branch is `[gone]` upstream | `git branch -v` shows `[gone]` next to the branch name | `(no-op — handled by end-of-session cleanup)` |
| **Self-assigned with no worktree, no PR, no branch on origin** (issue [#303](https://github.com/mattsears18/shipyard/issues/303)) | After the worktree loop above, run `gh issue list --repo <owner/repo> --state open --assignee @me --label shipyard --search '-linked:pr' --json number` and for each result confirm `[ ! -d <repo-root>/.claude/worktrees/agent-* ]` doesn't claim it (no worktree-on-disk this loop already touched) AND `git ls-remote --heads origin do-work/issue-<N>` is empty | `gh issue edit <N> --repo <owner/repo> --remove-assignee @me` (leave the `shipyard` label as provenance — it's not load-bearing for re-dispatch). `stale_assigns_count++`. Next dispatch retries from scratch. |

The fifth row closes a gap where prior sessions could leave the `@me` self-assign on an issue after their on-disk worktree was cleaned up — the first four rows only see issues whose worktree is still present, so this state otherwise survives unbounded across sessions. See [RATIONALE → Step 3c stale self-assign gap](../../do-work-RATIONALE.md#step-3c--the-stale-self-assign-gap-303) for the fuller failure mode (issue #303).

The row's action is intentionally conservative: clear the assignment only, leave the `shipyard` label (provenance — it tells the next session this issue went through `/do-work` before), let the normal step-4 backlog fetch pick the issue back up, and let the orchestrator's normal dispatch path arrange a fresh worktree. Don't touch the issue body, don't post a comment, don't close — the issue may genuinely still be workable and the prior session's `blocked` may have been transient.

**3d.1. Auto-clear stale `blocked:ci` labels.** The label is sticky on purpose, but a new commit on the PR's head branch means the premise ("no movement since shipyard gave up") is no longer true. Auto-clear those PRs so they flow back into step 5's failing-PR snapshot for another 3 attempts. This sweep is the *only* place `blocked:ci` is removed by the orchestrator (step A applies; 3d.1 removes; no other step touches it).

> **`--fast` skip:** When `--fast` is set, skip this entire sweep. The initial `blocked:ci` count (`fast_skip_blocked_ci`) captured in step 2's `--fast` note is sufficient for the advisory summary — stale `blocked:ci` labels persist until the next normal session. Set `cleared_ciblocked=0` and `held_ciblocked=0`.

Fire the initial PR list as part of the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch); per-PR `events` + `commits` lookups are a second-tier parallel batch. The serial loop below is shown for readability:

```bash
# All open PRs currently carrying blocked:ci, regardless of author. Foreign authors
# matter here too — the sweep is about the label's premise, not who owns the PR.
gh pr list --repo <owner/repo> --state open --label blocked:ci --limit 200 \
  --json number,headRefOid,headRefName \
  > /tmp/do-work-ciblocked-prs.json

cleared_ciblocked=0
held_ciblocked=0
declare -a cleared_pr_numbers
declare -a held_pr_numbers

for pr in $(jq -r '.[].number' /tmp/do-work-ciblocked-prs.json); do
  head_oid=$(jq -r --argjson n "$pr" '.[] | select(.number == $n) | .headRefOid' /tmp/do-work-ciblocked-prs.json)

  # Newest `labeled` event for blocked:ci on this PR (shipyard, a bot, or a human — doesn't matter who).
  # We're comparing "when was this label applied" against "when was the last commit on the head branch."
  label_ts=$(gh api "repos/<owner/repo>/issues/$pr/events" --paginate \
    --jq '[.[] | select(.event == "labeled" and .label.name == "blocked:ci")] | sort_by(.created_at) | last | .created_at')

  # When was the head commit authored?
  commit_ts=$(gh api "repos/<owner/repo>/commits/$head_oid" --jq '.commit.committer.date')

  if [ -z "$label_ts" ] || [ -z "$commit_ts" ]; then
    # Can't compute — leave the label alone, log advisory.
    held_ciblocked=$((held_ciblocked + 1))
    held_pr_numbers+=("$pr")
    continue
  fi

  # Compare ISO-8601 timestamps lexicographically (UTC-Z form sorts correctly).
  if [[ "$commit_ts" > "$label_ts" ]]; then
    gh pr edit "$pr" --repo <owner/repo> --remove-label blocked:ci
    cleared_ciblocked=$((cleared_ciblocked + 1))
    cleared_pr_numbers+=("$pr")
  else
    held_ciblocked=$((held_ciblocked + 1))
    held_pr_numbers+=("$pr")
  fi
done
```

Record `cleared_ciblocked` and `held_ciblocked` (plus the matching PR-number arrays). Cleared PRs flow into step 5's failing-PR snapshot naturally.

**Regression guard.** The `commit_ts > label_ts` comparison enforces "auto-clear fires only when a new commit has landed since the label was applied." If the comparison can't be computed (head branch deleted, events aged out of the ~90-day pagination window, network blip), hold — the safe default is to preserve the block. See [RATIONALE → Step 3d sweeps](../../do-work-RATIONALE.md#step-3d--the-blockedci-sweep-and-why-the-blockedagent-hard-referential-sweep-was-deleted-in-521).

**3d.2. Migrate legacy labels + sweep `blocked:agent-soft`.** Five sub-sweeps run in sequence, all before step 4's backlog fetch. Sub-sweep a (the former `blocked:agent-hard` referential clear) no longer exists — see [RATIONALE → blocked:agent-hard elimination](../../do-work-RATIONALE.md#blockedagent-hard-elimination-issue-521) for why it was deleted in [#521](https://github.com/mattsears18/shipyard/issues/521). Sub-sweep b (legacy migration) is **re-pointed** to the #521 routing; sub-sweep c (`blocked:agent-soft`) is unchanged. Sub-sweeps d/e/f ([#537](https://github.com/mattsears18/shipyard/issues/537)) migrate the remaining legacy gate labels left over from the [#515](https://github.com/mattsears18/shipyard/issues/515)/[#519](https://github.com/mattsears18/shipyard/issues/519)/[#521](https://github.com/mattsears18/shipyard/issues/521) folds: `needs-design` → `needs-human-review`; `needs-decomposition`/`tracking` → `needs-human-review` + `<!-- do-work-needs-decomposition -->` marker comment; `blocked:agent-hard` → same refuse/dependency-wait discriminator as sub-sweep b. All are idempotent one-shot-per-issue (the old label is removed, so a second pass finds nothing to migrate).

> **`--fast` skip:** When `--fast` is set, skip all five sub-sweeps. The initial label counts (`fast_skip_blocked_agent_soft`, `fast_skip_blocked_agent_legacy`, `fast_skip_legacy_needs_design`, `fast_skip_legacy_needs_decomposition`, `fast_skip_legacy_tracking`, `fast_skip_legacy_blocked_agent_hard`) captured in step 2's `--fast` note are sufficient for the advisory summary — stale labels persist until the next normal session. Set every `cleared_*`, `migrated_*`, and `held_*` counter to 0.

Fire the initial issue lists (one per label) in the [setup parallelization batch](00-config-worktree.md#07-setup-parallelization-contract-fire-once-batch); per-issue blocker lookups read through the [`blocker_state` cache](00b-parallelization-cache.md#08-blocker_state-cache-default-on). Serial loop shown for readability.

**Sub-sweep b — legacy `blocked:agent` migration (re-pointed per [#521](https://github.com/mattsears18/shipyard/issues/521)).** Pre-#300 sessions stamped a single `blocked:agent` label. Re-point it by the same discriminator the bail handler uses (see [RATIONALE → blocked:agent-hard elimination](../../do-work-RATIONALE.md#blockedagent-hard-elimination-issue-521)) — **presence of an open `Blocked by #N` reference**: a legacy issue with an open `Blocked by #N` is a dependency-wait → just **remove** the legacy label and let the body-ref filter gate it (no replacement label); otherwise it's an unclassifiable legacy refuse → **`needs-human-review`** (a human must look). The legacy label is removed in both branches.

```bash
# All open issues carrying the bare `blocked:agent` label (but NOT also
# blocked:agent-soft — that's already classified). Cheap: at most one extra
# gh call this session.
gh issue list --repo <owner/repo> --state open --label blocked:agent --limit 200 \
  --json number,body,labels \
  --jq '[.[] | select((.labels[].name | IN("blocked:agent-soft")) | not) | {number, body}]' \
  > /tmp/do-work-blocked-legacy-issues.json

migrated_legacy_dep=0      # → no label (dependency-wait, body-ref filter gates it)
migrated_legacy_review=0   # → needs-human-review (unclassifiable legacy refuse)
declare -a migrated_legacy_dep_numbers
declare -a migrated_legacy_review_numbers
for n in $(jq -r '.[].number' /tmp/do-work-blocked-legacy-issues.json); do
  body=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body' /tmp/do-work-blocked-legacy-issues.json)

  # Same `Blocked by #N` extraction the bail handler uses. Any reference to a
  # still-OPEN issue ⇒ dependency-wait; reads through the blocker_state cache.
  blockers=$(printf '%s' "$body" | grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
  has_open_blocker=false
  for b in $blockers; do
    state="${blocker_state[$b]:-}"
    if [ -z "$state" ]; then
      state=$(gh issue view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null \
        || gh pr view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null || echo "")
      [ -z "$state" ] && state="unresolvable"
      blocker_state[$b]="$state"
    fi
    case "$state" in OPEN) has_open_blocker=true; break ;; esac
  done

  if $has_open_blocker; then
    # Dependency-wait: drop the legacy label; the body-ref filter gates dispatch
    # and auto-clears when the referenced blocker closes. No replacement label.
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Removed legacy \`blocked:agent\` per [#521](https://github.com/mattsears18/shipyard/issues/521). This issue carries an open \`Blocked by #N\` reference, so it's gated by the \`Blocked by #N\` body-reference filter (no label needed) and becomes workable automatically when the blocker closes." 2>/dev/null || true
    migrated_legacy_dep=$((migrated_legacy_dep + 1))
    migrated_legacy_dep_numbers+=("$n")
  else
    # Unclassifiable legacy refuse: route to needs-human-review.
    gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Migrated legacy \`blocked:agent\` → \`needs-human-review\` per [#521](https://github.com/mattsears18/shipyard/issues/521). The original label predates the refuse/dependency-wait split and carries no open \`Blocked by #N\` reference, so it's treated as a refuse: a human must review before re-dispatch. If the original block was subjective (cannot-reproduce / ambiguous / scope-judgment), swap the label to \`blocked:agent-soft\` to opt into next-session auto-clear." 2>/dev/null || true
    migrated_legacy_review=$((migrated_legacy_review + 1))
    migrated_legacy_review_numbers+=("$n")
  fi
done
```

The migration runs **once per legacy issue** — after the first run there are no more bare-`blocked:agent`-labeled issues. The label itself stays registered (the `gh label create` at the top of step 3d still fires for it) so a future audit can confirm zero open issues carry it before deletion. Eventually (after a few sessions with zero legacy hits) the label can be deleted via `gh label delete blocked:agent`. (`migrated_legacy = migrated_legacy_dep + migrated_legacy_review` for the advisory summary.)

**Sub-sweep c — `blocked:agent-soft` next-session sweep.** Subjective bails from prior sessions (`cannot reproduce`, `ambiguous`, `suggested fix exceeds expected scope`, `PR already open for this issue`) are auto-cleared at next-session backlog fetch — this is the **whole point** of the soft/hard split. There's no `Blocked by #N` referential check: the label by itself is the signal that "a prior worker bailed for a subjective reason that may not hold this session." Just remove the label and let step 4 pick the issue up naturally.

```bash
# All open issues currently carrying the `blocked:agent-soft` label.
gh issue list --repo <owner/repo> --state open --label blocked:agent-soft --limit 200 \
  --json number \
  > /tmp/do-work-blocked-soft-issues.json

cleared_blocked_soft=0
declare -a cleared_blocked_soft_numbers
for n in $(jq -r '.[].number' /tmp/do-work-blocked-soft-issues.json); do
  gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-soft 2>/dev/null || true
  gh issue comment "$n" --repo <owner/repo> --body "Auto-cleared \`blocked:agent-soft\` at next-session backlog fetch — subjective bails (cannot-reproduce / ambiguous / scope-judgment) do not persist across sessions. If the underlying ambiguity is still unresolved, a fresh worker dispatch this session may re-stamp the label." 2>/dev/null || true
  cleared_blocked_soft=$((cleared_blocked_soft + 1))
  cleared_blocked_soft_numbers+=("$n")
done
```

No "held" bucket for soft labels — every soft-labeled issue is cleared at the start of every session. The re-stamping risk (worker bails for the same reason → soft label re-applied this session) is intentional: subjective bails get exactly one re-dispatch per session, and the in-session re-dispatch gate (orchestrator's `session_blocked_soft` map per [steady-state.md A.1](../steady-state.md#a1-parse-the-return-string)) prevents tight retry loops within the same session. The cost of clearing-then-immediately-re-stamping is one extra `gh issue edit` per issue per session — cheap relative to the cost of permanently hiding workable issues.

**Sub-sweep d — legacy `needs-design` migration ([#537](https://github.com/mattsears18/shipyard/issues/537)).** [#515](https://github.com/mattsears18/shipyard/issues/515) folded `needs-design` into `needs-human-review`. Consumer repos still carrying pre-fold issues with `needs-design` would otherwise pass the step-4 dispatch filter (which only excludes `needs-human-review`, not the former `needs-design`). Simple one-to-one rename: add `needs-human-review`, remove `needs-design`, post one comment. The migration is idempotent — after the first pass no issues carry `needs-design`, so subsequent sessions iterate over an empty list in O(0).

```bash
# All open issues carrying the legacy `needs-design` label.
gh issue list --repo <owner/repo> --state open --label needs-design --limit 200 \
  --json number \
  > /tmp/do-work-legacy-needs-design.json

migrated_needs_design=0
declare -a migrated_needs_design_numbers
for n in $(jq -r '.[].number' /tmp/do-work-legacy-needs-design.json); do
  # Add the current label first so the issue is never unlabelled mid-transition.
  gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
  gh issue edit "$n" --repo <owner/repo> --remove-label needs-design 2>/dev/null || true
  gh issue comment "$n" --repo <owner/repo> --body "Migrated legacy \`needs-design\` → \`needs-human-review\` per [#537](https://github.com/mattsears18/shipyard/issues/537). The \`needs-design\` label was folded into \`needs-human-review\` in [#515](https://github.com/mattsears18/shipyard/issues/515) — \`/do-work\` now excludes \`needs-human-review\` issues from dispatch, so this issue remains gated until a human reviews and removes the label." 2>/dev/null || true
  migrated_needs_design=$((migrated_needs_design + 1))
  migrated_needs_design_numbers+=("$n")
done
```

**Sub-sweep e — legacy `needs-decomposition` / `tracking` migration ([#537](https://github.com/mattsears18/shipyard/issues/537)).** [#519](https://github.com/mattsears18/shipyard/issues/519) folded the epic-decomposition pair into `needs-human-review` + the `<!-- do-work-needs-decomposition -->` body marker. Issues still carrying the pre-fold labels would otherwise pass the step-4 filter. For each legacy epic issue: add `needs-human-review`, remove the legacy label, AND post a comment containing the `<!-- do-work-needs-decomposition -->` marker (the discriminator `/decompose-epic` uses to identify epic handoffs in the broader `needs-human-review` pool). The migration is idempotent — the legacy labels are removed on the first pass. **This sweep only runs at the START of a session, so it doesn't catch a `tracking` label applied mid-session or by a prior session's un-migrated leftover before this sweep's next run** — [`04-backlog-divert.md`'s dispatch-exclusion filter](04-backlog-divert.md#4-fetch--rank-the-backlog) also enumerates `tracking` directly as a defensive gate ([#1081](https://github.com/mattsears18/shipyard/issues/1081)), closing that window without waiting for this sweep. The two are complementary, not redundant: this sweep does the actual cleanup (label swap + marker so `/decompose-epic` and `/my-turn` can find the issue); the dispatch-time gate only prevents premature dispatch in the meantime.

```bash
# Collect all open issues carrying needs-decomposition OR tracking (but NOT already
# needs-human-review — already migrated by a prior pass or manually).
gh issue list --repo <owner/repo> --state open --label needs-decomposition --limit 200 \
  --json number,labels \
  --jq '[.[] | select((.labels[].name | IN("needs-human-review")) | not) | {number}]' \
  > /tmp/do-work-legacy-needs-decomp.json

gh issue list --repo <owner/repo> --state open --label tracking --limit 200 \
  --json number,labels \
  --jq '[.[] | select((.labels[].name | IN("needs-human-review")) | not) | {number}]' \
  >> /tmp/do-work-legacy-needs-decomp.json

# Deduplicate (an issue could carry both labels) and process each once.
migrated_needs_decomp=0
declare -a migrated_needs_decomp_numbers
for n in $(jq -r '.[].number' /tmp/do-work-legacy-needs-decomp.json | sort -un); do
  gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
  # Remove whichever legacy labels the issue carries (one or both).
  gh issue edit "$n" --repo <owner/repo> --remove-label needs-decomposition 2>/dev/null || true
  gh issue edit "$n" --repo <owner/repo> --remove-label tracking 2>/dev/null || true
  # Post the marker comment. /decompose-epic keys off <!-- do-work-needs-decomposition -->
  # to distinguish epic handoffs from other needs-human-review issues.
  gh issue comment "$n" --repo <owner/repo> --body "<!-- do-work-needs-decomposition -->
Migrated legacy \`needs-decomposition\`/\`tracking\` → \`needs-human-review\` per [#537](https://github.com/mattsears18/shipyard/issues/537). The epic-decomposition pair was folded into \`needs-human-review\` + the \`<!-- do-work-needs-decomposition -->\` marker in [#519](https://github.com/mattsears18/shipyard/issues/519). The marker above lets \`/decompose-epic\` find this issue among the broader \`needs-human-review\` pool and auto-shard it into dispatch-ready sub-issues." 2>/dev/null || true
  migrated_needs_decomp=$((migrated_needs_decomp + 1))
  migrated_needs_decomp_numbers+=("$n")
done
```

**Sub-sweep f — legacy `blocked:agent-hard` migration ([#537](https://github.com/mattsears18/shipyard/issues/537)).** [#521](https://github.com/mattsears18/shipyard/issues/521) eliminated `blocked:agent-hard`, splitting it into refuses (`needs-human-review`) and dependency-waits (no label, body-ref filter gates). Pre-#521 sessions still carry `blocked:agent-hard` on open issues. Uses the same discriminator as sub-sweep b — presence of an open `Blocked by #N` reference — to route each legacy issue. Reads through the `blocker_state` cache.

```bash
# All open issues carrying the legacy `blocked:agent-hard` label.
gh issue list --repo <owner/repo> --state open --label blocked:agent-hard --limit 200 \
  --json number,body,labels \
  --jq '[.[] | {number, body}]' \
  > /tmp/do-work-legacy-hard-issues.json

migrated_hard_dep=0      # → no label (dependency-wait, body-ref filter gates it)
migrated_hard_review=0   # → needs-human-review (unclassifiable refuse)
declare -a migrated_hard_dep_numbers
declare -a migrated_hard_review_numbers
for n in $(jq -r '.[].number' /tmp/do-work-legacy-hard-issues.json); do
  body=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .body' /tmp/do-work-legacy-hard-issues.json)

  # Same `Blocked by #N` extraction as sub-sweep b.
  blockers=$(printf '%s' "$body" | grep -oiE 'blocked by[[:space:]]+(#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*)' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
  has_open_blocker=false
  for b in $blockers; do
    state="${blocker_state[$b]:-}"
    if [ -z "$state" ]; then
      state=$(gh issue view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null \
        || gh pr view "$b" --repo <owner/repo> --json state -q .state 2>/dev/null || echo "")
      [ -z "$state" ] && state="unresolvable"
      blocker_state[$b]="$state"
    fi
    case "$state" in OPEN) has_open_blocker=true; break ;; esac
  done

  if $has_open_blocker; then
    # Dependency-wait: drop the legacy label; the body-ref filter gates dispatch.
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-hard 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Removed legacy \`blocked:agent-hard\` per [#537](https://github.com/mattsears18/shipyard/issues/537) / [#521](https://github.com/mattsears18/shipyard/issues/521). This issue carries an open \`Blocked by #N\` reference, so it's gated by the \`Blocked by #N\` body-reference filter (no label needed) and becomes workable automatically when the blocker closes." 2>/dev/null || true
    migrated_hard_dep=$((migrated_hard_dep + 1))
    migrated_hard_dep_numbers+=("$n")
  else
    # Refuse: route to needs-human-review.
    gh issue edit "$n" --repo <owner/repo> --add-label needs-human-review 2>/dev/null || true
    gh issue edit "$n" --repo <owner/repo> --remove-label blocked:agent-hard 2>/dev/null || true
    gh issue comment "$n" --repo <owner/repo> --body "Migrated legacy \`blocked:agent-hard\` → \`needs-human-review\` per [#537](https://github.com/mattsears18/shipyard/issues/537) / [#521](https://github.com/mattsears18/shipyard/issues/521). The original label predates the refuse/dependency-wait split and carries no open \`Blocked by #N\` reference, so it's treated as a refuse: a human must review before re-dispatch. If the original block was subjective (cannot-reproduce / ambiguous / scope-judgment), swap the label to \`blocked:agent-soft\` to opt into next-session auto-clear." 2>/dev/null || true
    migrated_hard_review=$((migrated_hard_review + 1))
    migrated_hard_review_numbers+=("$n")
  fi
done
```

The sub-f migration runs **once per legacy issue** — after the first pass there are no more `blocked:agent-hard`-labeled issues. The label object is left registered (same rationale as `blocked:agent` in sub-sweep b) so a future audit can confirm zero open issues carry it before deletion.

**Order matters.** Sub-sweeps b → c → d → e → f run in sequence (sub-sweep a was deleted in [#521](https://github.com/mattsears18/shipyard/issues/521)). c runs after b so the soft sweep operates on the post-migration label set — a legacy `blocked:agent` issue migrated to `blocked:agent-soft` by a maintainer mid-window is swept by c on the same pass. d/e/f run after c and operate on the post-b-migration state so no issue is processed by two sweeps in the same pass (the old label is always removed before the loop ends, making each sweep idempotent and one-shot-per-issue).

### 3.5 Refine pending issues

> **`--fast` skip:** When `--fast` is set, skip this entire step. Issues matching a refinement source signal remain unrefined this session; they will be processed by the next normal `/do-work` invocation. The `fast_skip_needs_refinement` count captured in step 2's `--fast` note surfaces in the end-of-session advisory block so the user knows how many refinement tasks were deferred. Proceed immediately to step 4.

**Timing instrumentation (issue #238).** Bracket this step even when it runs with no refinement-candidate issues — the wall clock still measures the `/refine-issues` invocation overhead:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_3_5_refine_issues 2>/dev/null || true
# /refine-issues --repo <owner/repo> --concurrency <N>
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_3_5_refine_issues 2>/dev/null || true
```

When `--fast` causes this step to be **skipped entirely**, call only the `start` + `end` pair with a near-zero elapsed (both calls back-to-back), so the ledger contains a `0.0s` entry for the phase rather than a missing key. This makes cross-session aggregation consistent — the report can always average `step_3_5_refine_issues` without handling absent keys for `--fast` sessions separately.

Invoke `/refine-issues` and **wait for it to complete** before proceeding to step 4. This scans every open issue for a refinement source signal — there is no persisted `needs-refinement` gate label (eliminated in [#520](https://github.com/mattsears18/shipyard/issues/520)); candidacy is recomputed live — and branches per-issue on source signal:

- **classify+rewrite branch** (`user-feedback` label present AND body still contains the raw-feedback fenced block — the label alone is permanent origin provenance, not a live refinement flag; [#1055](https://github.com/mattsears18/shipyard/issues/1055)): classify as already-done / declined / legitimate, preserve original text in a comment, rewrite the body into the repo's issue template. Legitimate items get `needs-human-review` co-applied.
- **resolve-defaults branch** (no `user-feedback`, body has `## Open questions`): commit reasonable defaults for each question, rewrite body removing the section. Does NOT apply `needs-human-review` — trusted-author issues become dispatch-eligible in the same session.
- **fall-through branch** (no `user-feedback`, no recognizable pattern — bot-authored / bare one-liner / unrecognized): add `needs-human-review`, comment with explanation. Surfaces via `/shipyard:my-turn`. (This is the genuine no-automated-path subset only — never the auto-processable work above.)

After this step, every dispatch-ready survivor of the first two branches is either dispatch-eligible (resolve-defaults) or carries `needs-human-review` (legitimate user-feedback). The fall-through branch lands the no-pattern subset on `needs-human-review`.

```
/refine-issues --repo <owner/repo> --concurrency <do-work concurrency>
```

Pass-through args:

- **`--repo`** — same value `/do-work` is using.
- **`--concurrency`** — same value `/do-work` is using (default `1` unless overridden — see [`/do-work`'s `--concurrency` arg](../../do-work.md#args) for the rationale).
- **`--issue`** is NEVER passed from `/do-work` — refinement always operates on the full eligible set during a `/do-work` startup.
- **`--dry-run`** is NEVER passed from `/do-work` — startup refinement always commits.

The refined-and-now-`needs-human-review` issues will be picked up by the *next* `/do-work` session, after a human reviews. Step 4's backlog fetch (just below) excludes `needs-human-review` and `needs-triage`, so none leak into the dispatch queue this session. Resolve-defaults issues, however, ARE picked up this session — they become dispatch-eligible the moment the refiner removes the `## Open questions` section (no gate label to drop).

**Implementation note.** The refinement logic itself lives in `/refine-issues`. This step is a thin invocation — no duplication of the bucket spec, sentinel logic, or worker prompt template. If we later change the refinement prompt, we only update one file (`commands/refine-issues.md`).

# issue-work.md § 5.85 — Post-PR-create non-close parent/epic leak verification

On-demand fragment of [`issue-work.md`](./issue-work.md). Loaded only when that file's §5.85 stub says the trigger condition is met — see [#980](https://github.com/mattsears18/shipyard/issues/980) for why this content moved out of the always-loaded core.

Closes [#624](https://github.com/mattsears18/shipyard/issues/624) — the **silent-epic-close** failure mode, the inverse of §5.8's stuck-open. This guard is the *enforcement* of the bare-URL-phrasing guidance in [§5](./issue-work.md#5-commit--push--pr); §5.8 asserts the dispatched issue `#<N>` *is* a closing reference, this step asserts a "do NOT close" issue `#<E>` is *not*.

**When this step applies.** Whenever this PR must reference — but NOT close — some issue `#<E>` on merge. Three shapes trigger it: (1) a **parent/epic relationship** named in the dispatch prompt or issue body — phrasing like *"do NOT close #<E>"*, *"reference but don't close #<E>"*, *"Part of #<E>"* / *"Parent epic #<E>"*; (2) **`#<E>` is the dispatched issue itself**, when you're opening a *secondary/auxiliary* PR that ships partial or adjacent value without resolving the dispatch — e.g. a `blocked`-shaped investigation outcome where you additionally shipped a valuable but non-resolving docs/runbook change (the [#893](https://github.com/mattsears18/shipyard/issues/893) repro); (3) **a scope-preflight operator-slice split dispatch** ([#851](https://github.com/mattsears18/shipyard/issues/851)) — the dispatch prompt's Context block carries an "Operator residual" paragraph (set when [scope-preflight's operator-slice carve-out](../../commands/do-work/setup/06b-scope-carveouts.md#operator-slice-carve-out--ship-the-code-slice-hand-back-only-the-operator-remainder-851) found a phase-1 code slice inside an otherwise-`needs-operator`/security-flavored `needs-human-review` candidate). Shape (3) is a special case of shape (2) — `#<N>`, the dispatched issue itself, is the protected issue, because this PR ships only the code slice and an operator/security action still remains on the SAME issue; treat it exactly like shape (2) below, then continue to §6.5 ([`issue-work-split-dispatch.md`](./issue-work-split-dispatch.md)) after auto-merge is armed. Collect every such `#<E>` into a set of *protected issues*. If no non-close relationship is in scope (the common case — most PRs are the single resolving PR for their dispatched issue), **skip this step entirely**; it's a no-op. This step never applies to the dispatched issue's own *resolving* PR — that one is supposed to close `#<N>` via `Closes #<N>` per §5, and shape (3) is explicitly the exception: this PR is NOT that issue's resolving PR, even though it's dispatched against the same number.

**Prevention — never name a protected-issue-referencing PR's branch `do-work/issue-<E>` (or any `issue-<E>`-shaped variant).** [#893](https://github.com/mattsears18/shipyard/issues/893) isolated a *branch-naming* hazard distinct from the body/commit-text hazard below: GitHub's own "Create a branch" UI auto-links a branch literally named `do-work/issue-<E>` to issue `#<E>`, and in the repro that link registered in `closingIssuesReferences` **independent of the PR body or commit-message text** — it survived a full body rewrite, a commit-message rewrite + force-push, and even a close+reopen, and only cleared once the PR was abandoned for a fresh, neutrally-named branch. If you already know before opening the PR that it must not close `#<E>`, don't give its branch an `issue-<E>`-shaped name even when `<E>` happens to be the number you were dispatched against — pick a neutral name instead (e.g. `docs/<short-topic>`), off the default branch. This sidesteps the remediation loop below entirely; it's cheaper than recovering from the leak.

**The mechanism the remediation loop guards.** GitHub can promote a bare `#<E>` token (in the PR body, a squashed-commit message, or a CHANGELOG entry that rides the merge) into `closingIssuesReferences` even with no closing keyword — so the merge auto-closes the protected issue. The §5 prevention is to phrase the reference as a bare URL; this step verifies the prevention took and, if it leaked, escalates through three remediation tiers.

**After `gh pr create` and before arming auto-merge in [§6](./issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust)**, for each protected issue `#<E>` assert it is absent from the PR's `closingIssuesReferences`. If it leaked, run the tiers below **in order and don't stop early** — the [#893](https://github.com/mattsears18/shipyard/issues/893) repro showed a leak surviving a single body-rewrite-and-reverify (what an earlier version of this step stopped at) as well as a follow-up commit-message rewrite, so a worker that re-verifies once and declares victory, or that gives up after one rewrite and jumps straight to `needs-human-review`, is not exercising the full documented recovery path:

```bash
# Re-derive WORKTREE_PATH per worker-preamble § "Worktree-reaped escape hatch".
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
if [ ! -d "$WORKTREE_PATH" ] || [ "$(git rev-parse --show-toplevel 2>/dev/null)" != "$WORKTREE_PATH" ]; then
  LAST_PUSH=$(git log -1 --format='%H' 2>/dev/null | head -c 12)
  echo "reaped: my worktree was reaped while I was running — re-dispatch required (last push: ${LAST_PUSH:-none})"
  exit 0
fi

# <E> is each protected issue number collected above. Run this block per issue.
CURRENT_PR=<pr-num>
LEAKED=$(gh pr view "$CURRENT_PR" --repo <owner/repo> --json closingIssuesReferences \
  --jq "[.closingIssuesReferences[]?.number] | index(<E>) != null")

# --- Tier 1: rewrite the PR body to bare-URL form. ---
if [ "$LEAKED" = "true" ]; then
  CURRENT_BODY=$(gh pr view "$CURRENT_PR" --repo <owner/repo> --json body --jq '.body')
  # Replace bare #<E> tokens with the full-URL form (which does NOT auto-close).
  PATCHED_BODY=$(printf '%s' "$CURRENT_BODY" \
    | sed -E "s@#<E>@https://github.com/<owner>/<repo>/issues/<E>@g")
  gh pr edit "$CURRENT_PR" --repo <owner/repo> --body "$PATCHED_BODY"

  LEAKED=$(gh pr view "$CURRENT_PR" --repo <owner/repo> --json closingIssuesReferences \
    --jq "[.closingIssuesReferences[]?.number] | index(<E>) != null")
fi

# --- Tier 2: also rewrite the HEAD commit message. A bare #<E> token riding
# in a squashed-commit message is a SEPARATE vector from the body — a
# body-only rewrite can leave this one untouched. ---
if [ "$LEAKED" = "true" ]; then
  CURRENT_MSG=$(git log -1 --format='%B')
  if printf '%s' "$CURRENT_MSG" | grep -qE "#<E>([^0-9]|\$)"; then
    PATCHED_MSG=$(printf '%s' "$CURRENT_MSG" \
      | sed -E "s@#<E>@https://github.com/<owner>/<repo>/issues/<E>@g")
    git commit --amend -m "$PATCHED_MSG"
    git push --force-with-lease origin "HEAD:refs/heads/${REMOTE_BRANCH:-do-work/issue-<N>}"
  fi

  LEAKED=$(gh pr view "$CURRENT_PR" --repo <owner/repo> --json closingIssuesReferences \
    --jq "[.closingIssuesReferences[]?.number] | index(<E>) != null")
fi

# --- Tier 3: escape hatch — abandon this branch/PR and reopen from a NEUTRAL
# branch name. If the leak survives tiers 1+2 with a CONFIRMED-clean body and
# commit message, the branch name itself is the likely persistent trigger
# (#893) — no further body/commit edit on THIS branch will clear it, so don't
# loop tiers 1/2 again; move straight to a fresh branch. ---
if [ "$LEAKED" = "true" ]; then
  gh pr close "$CURRENT_PR" --repo <owner/repo> \
    --comment "Closing — closingIssuesReferences kept registering #<E> even with a confirmed-clean body and commit message (#893). Reopening from a neutrally-named branch to clear the leaked link."

  NEUTRAL_BRANCH="docs/issue-<N>-followup-$(date +%s)"
  git checkout -B "$NEUTRAL_BRANCH" "origin/$DEFAULT_BRANCH"
  git cherry-pick <original-commit-sha>   # or recreate the same file changes directly
  git push -u origin "$NEUTRAL_BRANCH"

  gh pr create --repo <owner/repo> --head "$NEUTRAL_BRANCH" --label shipyard \
    --title "<same title>" --body "$PATCHED_BODY"

  CURRENT_PR=$(gh pr list --repo <owner/repo> --head "$NEUTRAL_BRANCH" --json number --jq '.[0].number')
  LEAKED=$(gh pr view "$CURRENT_PR" --repo <owner/repo> --json closingIssuesReferences \
    --jq "[.closingIssuesReferences[]?.number] | index(<E>) != null")
fi

# If the protected issue is already CLOSED (e.g. an admin ungated direct-merge
# fired before this check ran, or an earlier tier's PR merged before you
# closed it), reopen it — regardless of which tier finally cleared LEAKED.
EPIC_STATE=$(gh issue view <E> --repo <owner/repo> --json state --jq '.state')
if [ "$EPIC_STATE" = "CLOSED" ]; then
  gh issue reopen <E> --repo <owner/repo> \
    --comment "Reopened: a PR auto-closed this issue via a leaked closing reference (#624 / #893). It was meant to *reference* this issue, not close it."
fi

if [ "$LEAKED" = "true" ]; then
  echo "blocked #<N> at parent-epic-leak-verify: even a fresh, neutrally-named branch still registers #<E> as a closing reference — manual triage required (PR: <url>)"
  gh pr edit "$CURRENT_PR" --repo <owner/repo> --add-label needs-human-review || true
  exit 0
fi
```

**Why bare URL rather than deleting the mention.** The reference is *wanted* — the PR legitimately should link the protected issue for traceability; it just must not *close* it. The bare-URL form (`https://github.com/<owner>/<repo>/issues/<E>`) renders a clickable link that GitHub does NOT promote into `closingIssuesReferences`, so it keeps the traceability while dropping the closing semantics. Don't strip the reference entirely.

**Why tier 3 (a fresh branch) can succeed when tiers 1–2 (rewriting the existing branch) don't.** Tiers 1 and 2 fix every *text*-based vector — the body and the commit message — but the [#893](https://github.com/mattsears18/shipyard/issues/893) repro's confirmed-clean body (`gh pr view --json body --jq '.body | test("#<E>")'` → `false`) and confirmed-clean commit message still left `closingIssuesReferences` populated, which points at the **branch name itself** as a third, independent vector not covered by rewriting either text field. Abandoning the branch — not just editing its content — is the only thing that cleared the link in the repro; a fourth or fifth rewrite attempt on the same branch is not expected to do better than the first two.

**Why reopen on already-merged.** On a repo where an admin direct-merge can fire before this check runs (the `merged-direct-ungated` path), the merge may have already closed the protected issue by the time you verify — regardless of which tier you're in when that happens. Reopening `#<E>` restores it so it isn't orphaned and `/my-turn` keeps surfacing it if further review is needed. The body/branch remediation still matters even post-merge — it stops a *future* re-merge or backport from re-closing it.

This step runs **after** §5.8 (the dispatched-issue closing-link verification) and **before** §6 arms auto-merge, so a protected issue can never ride an armed auto-merge to a silent close. It runs unconditionally regardless of `originating_author_trust` whenever a protected issue is in scope.

Once this fragment's procedure completes (leak cleared, or escalated to `needs-human-review`), return to [`issue-work.md`](./issue-work.md) and continue at §5.9 (or §6 if §5.9 doesn't apply).

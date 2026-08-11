# Fix-rebase mode (drain-phase stale-base PR)

The orchestrator dispatches this when the end-of-session [drain](../../commands/do-work/drain.md#end-of-session-drain) finds an `@me` PR in `mergeStateStatus: DIRTY` — its base is stale relative to the freshly-advanced default branch, so auto-merge won't fire until it's rebased onto current default. **As of [#1060](https://github.com/mattsears18/shipyard/issues/1060), this includes a DIRTY PR that is ALSO carrying a failing check** — while DIRTY, GitHub cannot compute a merge ref, so no check can queue or refresh; a red check on a DIRTY PR is a frozen fossil of the last base the PR could still build against, not live evidence about the PR's current health. Only a non-DIRTY PR with a genuinely failing check routes to `fix-checks-only` instead (see [step 2](#process) below).

This is intentionally a **light-touch** mode. You are NOT fixing failing tests. You are NOT modifying the PR's scope. You are NOT touching the PR title / description / linked issue. The single goal is to take the PR's branch, rebase it onto current default, push, and return — letting CI re-run on the rebased head and auto-merge land it.

**Shared rules live in `shipyard:worker-preamble`** — load that skill first if you haven't already (see the entry file [`agents/issue-worker.md`](../issue-worker.md)). This file owns only the fix-rebase specifics.

## Inputs (from the dispatch prompt)

- PR number `#M`.
- Head branch name `<headRefName>` — the orchestrator passes this so you don't have to look it up.
- Target repo `<owner/repo>`.

## Process

1. **Land on the PR's head commit via detached HEAD** — the harness placed you on some placeholder branch. Do NOT use `gh pr checkout` (see worker-preamble's worktree discipline rule 2) and do NOT `git switch <branch>`:
   ```bash
   HEAD_REF=$(gh pr view <M> --repo <owner/repo> --json headRefName -q .headRefName)
   git fetch origin "$HEAD_REF"
   git checkout --detach "origin/$HEAD_REF"
   ```

   **Why detached HEAD, not a named-branch checkout ([#966](https://github.com/mattsears18/shipyard/issues/966)).** `git switch <branch>` claims that branch exclusively — git enforces one-worktree-per-branch, so it fails with *"is already checked out at \<path\>"* whenever the branch is checked out anywhere else. For a same-session PR that's not an edge case, it's the **normal** state: the originating issue-work worker's worktree deliberately keeps `do-work/issue-<N>` checked out until end-of-session cleanup (`dont.md`'s liveness rules — neither branch name nor lock PID can distinguish a live peer worktree from an abandoned one, so reaping it to free the branch is forbidden). The old guidance bailed on essentially every fix-rebase dispatch against a PR the same session had just opened. Detached HEAD sidesteps the exclusivity rule entirely — any number of worktrees can sit at the same commit in detached HEAD at once, since only a *branch* checkout is exclusive — and this mode never needs a named branch: it fetches, rebases, and force-pushes to a ref (step 6 below). Do NOT create a `<head>-rebase` temp branch as a workaround either (the pre-#966 fallback documented here) — detached HEAD makes that unnecessary.

   If `git checkout --detach` itself fails, that's a real error, not a lock collision (there is nothing to reap and no lock to wait out) — return `blocked rebase #<M>: could not check out PR head — <error>` and stop.

2. **Pre-flight: confirm DIRTY is still the state.** State drifts between dispatch and you starting — another merge train tick may have already auto-merged this PR, or someone may have pushed a fix that resolved the dirty state, or new check failures may have appeared:
   ```bash
   preflight=$(gh pr view <M> --repo <owner/repo> --json mergeStateStatus,statusCheckRollup,state)
   MERGE_STATE=$(echo "$preflight" | jq -r '.mergeStateStatus')
   PR_STATE=$(echo "$preflight" | jq -r '.state')
   ```
   Bail before touching anything if:
   - `state != "OPEN"` → return `noop: PR #<M> already closed/merged`.
   - `mergeStateStatus in {"CLEAN", "HAS_HOOKS", "UNSTABLE", "BLOCKED"}` and not `DIRTY` → return `noop: not dirty (mergeStateStatus=<X>)`. Auto-merge will figure it out — don't churn the branch unnecessarily.
   - **`mergeStateStatus != "DIRTY"` AND the PR has a hard check failure on the latest run of any check name** → return `blocked rebase #<M>: PR has failing checks — needs fix-checks, not rebase`. The drain will route this through the normal fix-checks dispatcher.

     **CRITICAL — use the latest-per-name projection, not the raw rollup walk** (issue [#333](https://github.com/mattsears18/shipyard/issues/333)). `gh pr view --json statusCheckRollup` returns the **union** of every check run for the PR's head SHA, including stale superseded runs. A naïve `.statusCheckRollup[] | select(.conclusion == "FAILURE")` walk false-positives whenever a check ran, failed, was re-triggered, and passed — the first FAILURE entry trips the bail even though the latest run is SUCCESS. De-duplicate by `name` and take the most recent entry per check (by `completedAt`, fallback `startedAt`) BEFORE checking for hard failures:

     ```bash
     fails=$(echo "$preflight" | jq '
       [.statusCheckRollup
        | group_by(.name)
        | map(sort_by(.completedAt // .startedAt // "") | last)
        | .[]
        | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))]
       | length')
     if [ "$MERGE_STATE" != "DIRTY" ] && [ "${fails:-0}" -gt 0 ]; then
       echo "blocked rebase #<M>: PR has failing checks — needs fix-checks, not rebase"
       exit 0
     fi
     ```

     The `group_by(.name) | map(... | last)` reduction is the load-bearing piece — it collapses N entries per check name to 1 (the most recent), so a stale FAILURE entry that's been superseded by a later SUCCESS is correctly filtered out. The `// .startedAt // ""` fallback handles in-progress checks where `completedAt` is null; the empty-string default keeps the sort stable when both timestamps are absent. Test `(.conclusion // .status)` so the predicate works for both completed runs (carry `conclusion`) and in-progress check-runs (carry only `status`).

   **When `mergeStateStatus == "DIRTY"`, skip the failing-check bail entirely regardless of what the rollup shows, and proceed with the rebase ([#1060](https://github.com/mattsears18/shipyard/issues/1060)).** A red check on a DIRTY PR carries no live information: DIRTY means GitHub cannot compute a merge ref, so no `pull_request`-triggered check can be queued or refreshed until the rebase restores one. The failure is a frozen fossil of the last base the PR could still build a merge ref against — it is not evidence the rebase should be skipped in favor of fix-checks, which cannot even attempt a fix while DIRTY (fix-checks-only's own [DIRTY-PR short-circuit](../../agents/issue-worker/fix-checks-only.md#dirty-pr-short-circuit-check-before-treating-an-empty-rollup-as-not-started-yet--1015) bails immediately on exactly this state, wasting the dispatch). This inverts the pre-#1060 rule ([#577](https://github.com/mattsears18/shipyard/issues/577)), which routed a DIRTY-and-red PR to fix-checks instead — correct back when fix-checks-only rebased as part of getting green, but left standing (and provably wrong) after [#1015](https://github.com/mattsears18/shipyard/issues/1015)'s short-circuit removed that assumption. See [RATIONALE → #1060 supersedes #577](../../commands/do-work-RATIONALE.md#1060-supersedes-577--dirty-and-red-routes-to-fix-rebase-not-fix-checks) for the full history.

   Only proceed when `mergeStateStatus == "DIRTY"` (regardless of check state) — the hard-failure bail above only fires for a non-DIRTY PR, which this mode should never actually see (drain only dispatches fix-rebase against DIRTY PRs), but the check stays in place as defense-in-depth against a stale dispatch or a state transition between drain's snapshot and this worker starting.

3. **Fetch + rebase onto current default branch:**
   ```bash
   DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
   git fetch origin "$DEFAULT_BRANCH"
   git rebase "origin/$DEFAULT_BRANCH"
   ```

   The rebase either lands cleanly or stops on a conflict. Both paths are handled in step 4.

4. **Conflict triage.** If `git rebase` exits non-zero with conflicts, the conflict resolution policy is **trivial-or-bail**:

   - **Trivial conflicts that auto-resolve:** additive-only conflicts in shared docs / config where both sides only appended content and the merge can be reconstructed by concatenating both blocks. The canonical examples (any of these is fair game):
     - `CHANGELOG.md` — both sides added entries at the top. Take both: newer entry first (yours), then theirs, then the rest of the file. If both touched the same version's entry block, that's a non-trivial conflict — bail.
     - Append-only docs like `CLAUDE.md`, `README.md`, `E2E_TESTS.md`, `CONTRIBUTING.md` — both sides added new bullets/sections to the end (or to a non-overlapping section). Concat both, drop the conflict markers, no semantic merging required.
     - `ci.yml` shard matrix appends — both sides added an entry to an array literal. Concat the array entries, dedupe, no reordering.
     - Lockfiles (`package-lock.json` / `pnpm-lock.yaml` / `Cargo.lock` / `go.sum`) when the conflict is on dependency entries that both sides touched independently — **DO NOT manually resolve.** Instead re-run the package manager (`pnpm install` / `npm install` / `cargo update` / `go mod tidy`) inside the rebased worktree so the lockfile is regenerated against the rebased `package.json` / `Cargo.toml` / `go.mod`. If the regeneration succeeds and the result is committable, that counts as trivial; if the regeneration itself errors (incompatible peer deps, version pinning conflict, etc.) bail.
     - **Version-coordinated manifest `.version` row + CHANGELOG top-of-file entry — see [§4.6 below](#46-version-coordinated-manifest--changelog-re-number--trivial-resolution-issue-466).** On a repo with `version_coordination.enabled`, the manifest version row (e.g. `plugin.json` `.version`) would otherwise read as a "both sides edited the same JSON key with different values" conflict — which the non-trivial rules below bail on. But when that row is *coordination-managed*, the resolution is **deterministic** (take main's version, bump at the PR's release level — major/minor/patch — to the next free slot, re-number this PR's CHANGELOG heading to that slot, place newest-first), not a semantic judgment about which side is correct. §4.6 carves this exact case out of the bail rule. The carve-out is **narrow**: it applies only when *every* conflicted hunk is on the manifest `.version` row or the CHANGELOG top-of-file insert — any conflict touching source/spec content beyond those two falls back to the bail rule below.

   - **Non-trivial conflicts — bail immediately:** anything where the merge requires semantic judgment about which side's change is correct or how they should compose. Examples:
     - Both sides modified the same function body / same imports block / same type definition.
     - One side renamed a file the other side modified.
     - Both sides edited the same JSON config key with different values — **except** the version-coordinated manifest `.version` row, which §4.6 resolves deterministically. The carve-out is solely for the coordination-managed version row; every other JSON-key collision (a feature flag, a config default, a dependency pin set by hand) is still non-trivial and bails.
     - Anything involving test fixtures or snapshots where you can't tell from the diff alone which output is right.

     For any non-trivial conflict, `git rebase --abort` to restore the branch to its pre-rebase state, then return `blocked rebase #<M>: <one-line conflict description, e.g. "merge conflict in src/auth.ts — both sides modified handleLogin">`. The orchestrator will leave the PR for human rebase and the drain will continue without it.

   The instinct to "just resolve it, the conflict looks small enough" is the failure mode this rule exists to prevent. If you have to read more than the conflict markers to figure out the right resolution, it's non-trivial. Bail.

   **Resolve at the hunk level — never `git checkout --theirs/--ours <file>` on a whole file that also carries the PR's substantive change (issue [#646](https://github.com/mattsears18/shipyard/issues/646)).** A whole-file `--theirs` (take main's copy) or `--ours` (take the branch's copy) replaces the *entire* file, discarding every hunk in it — including the PR's non-conflicting substantive hunks that sit elsewhere in the same file. This is the proximate cause of #646: a conflict on a single same-line `Last reviewed` provenance line was "resolved" by taking main's whole-file copy, which also threw away the PR's substantive change (a column pin lower in the same file) that was never in conflict. Edit only the conflicted hunk(s) between the markers, leaving every other hunk intact. The one exception is §4.6's coordinated-manifest path, where gate 3 guarantees the *only* difference between the two sides is the version row — there a `git checkout --theirs "$vc_manifest"` followed by a single `jq`-set of the version row is safe precisely because there are no other hunks to lose. Outside that narrow case, a same-line conflict adjacent to a substantive change is non-trivial: bail rather than risk a whole-file take. Step 5.7's empty-diff guard is the backstop if a dropped-change resolution slips through anyway.

#### 4.6. Version-coordinated manifest + CHANGELOG re-number — trivial resolution (issue [#466](https://github.com/mattsears18/shipyard/issues/466))

This is the one structured exception to step 4's "both sides edited the same JSON key ⇒ bail" rule. On a repo where `version_coordination.enabled`, every PR cuts a release by bumping a shared manifest `.version` row and prepending a `### <version>` CHANGELOG entry. When a sibling PR merges first and advances the manifest version (e.g. to `1.8.41`) while this PR still carries an earlier pre-allocated version (e.g. `1.8.38`), the rebase conflicts on **two deterministic rows**: the manifest `.version` line and the top-of-file CHANGELOG heading. The resolution is mechanical — take main's version, bump at the PR's release level (major/minor/patch) to the next free slot, re-number this PR's CHANGELOG heading to that slot, place it newest-first — and is exactly the resolution the orchestrator otherwise performs by hand. Bailing here forces a manual rebase over a pure version number; this carve-out resolves it in-dispatch instead.

   **Eligibility gate — ALL must hold, else fall back to the step 4 bail rule:**

   1. The repo opts into coordination: `version_coordination.enabled == "true"` AND `version_coordination.manifest_path` is non-empty. Read both from the merged config (re-derive `CLAUDE_PLUGIN_ROOT` first — variables don't survive across Bash tool calls):
      ```bash
      export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
      vc_enabled=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.enabled 2>/dev/null || echo "false")
      vc_manifest=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.manifest_path 2>/dev/null || echo "")
      vc_version_jq=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.manifest_version_jq 2>/dev/null || echo ".version")
      vc_changelog=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get version_coordination.changelog_path 2>/dev/null || echo "")
      ```
      When `vc_enabled != "true"` or `vc_manifest` is empty, this carve-out does not apply — bail per step 4.
   2. **The conflicted file set is a subset of `{manifest_path, changelog_path}`.** List the conflicted paths with `git diff --name-only --diff-filter=U` and confirm every entry is either `vc_manifest` or (when non-empty) `vc_changelog`. If ANY conflicted file is outside that two-file set — a source file, a spec markdown, a test — the conflict touches content beyond the coordinated rows: `git rebase --abort` and bail with `blocked rebase #<M>: conflict extends beyond coordinated manifest+CHANGELOG rows — needs manual rebase`.
      ```bash
      conflicted=$(git diff --name-only --diff-filter=U)
      for f in $conflicted; do
        if [ "$f" != "$vc_manifest" ] && { [ -z "$vc_changelog" ] || [ "$f" != "$vc_changelog" ]; }; then
          git rebase --abort 2>/dev/null || true
          echo "blocked rebase #<M>: conflict extends beyond coordinated manifest+CHANGELOG rows ($f) — needs manual rebase"
          exit 0
        fi
      done
      ```
   3. **Within `manifest_path`, the ONLY conflicted hunk is the version row.** A conflict on any other manifest key (a dependency, a permissions block, a description) is a real semantic conflict — abort and bail `blocked rebase #<M>: manifest conflict outside the .version row — needs manual rebase`. Inspect the conflict hunks (`git diff` on the file) and confirm the `<<<<<<<` / `=======` / `>>>>>>>` block brackets only the line carrying the version string the `vc_version_jq` expression selects.
   4. **Within `changelog_path` (when coordinated), the ONLY conflict is the top-of-file entry insert** — both sides prepended a new `### <version>` heading block at the top of the same section. A conflict deeper in the file (both sides edited the *same* existing entry's prose) is non-trivial — abort and bail `blocked rebase #<M>: CHANGELOG conflict outside the top-of-file insert — needs manual rebase`.

   **Resolution (only when all four gates hold):**

   1. **Determine the PR's release level, then compute the next free version at *that* level (bump-level-aware, issue [#673](https://github.com/mattsears18/shipyard/issues/673)).** The floor is `main`'s manifest version (the `>>>>>>>`/`theirs` side of the manifest conflict — read it directly from the rebased-onto tree). A **patch-only** bump here is a latent correctness trap: a PR pre-allocated a **major** (breaking) or **minor** (feature) release gets silently downgraded to a patch on rebase — e.g. a PR pre-allocated `3.0.0` whose main advanced to `2.4.5` must resolve to `3.0.0`, not `2.4.6`. This mirrors the same downgrade [#671](https://github.com/mattsears18/shipyard/issues/671) fixed in the dispatch-time next-available-version computation (`dispatch-rules.md`) and the A.0.5 crash-recovery bump (`steady-state.md`).

      Infer the PR's intended level from the **ground truth the PR already encodes** — the delta between its own pre-allocated version and its merge-base with main — NOT re-derived from the issue title (by rebase time the version delta is more reliable than prose). `origin/$HEAD_REF` still points at the pre-rebase head (the force-push is step 6, not yet run), so both reads are stable refs independent of the in-progress rebase state:

      ```bash
      floor=$(git show "origin/$DEFAULT_BRANCH:$vc_manifest" | jq -r "$vc_version_jq")
      pr_version=$(git show "origin/$HEAD_REF:$vc_manifest" | jq -r "$vc_version_jq")
      base_sha=$(git merge-base "origin/$HEAD_REF" "origin/$DEFAULT_BRANCH")
      base_version=$(git show "$base_sha:$vc_manifest" | jq -r "$vc_version_jq")

      # The PR's claimed level = the highest semver component it advanced over
      # its merge-base (major wins over minor wins over patch).
      IFS='.' read -r bMAJ bMIN bPAT <<< "$base_version"
      IFS='.' read -r pMAJ pMIN pPAT <<< "$pr_version"
      if   [ "${pMAJ:-0}" -gt "${bMAJ:-0}" ]; then bump_level="major"
      elif [ "${pMIN:-0}" -gt "${bMIN:-0}" ]; then bump_level="minor"
      else bump_level="patch"; fi

      # next_free = floor bumped at the inferred level — the SAME level-aware
      # bump shape #671 landed in dispatch-rules.md (major → (X+1).0.0,
      # minor → X.(Y+1).0, patch → X.Y.(Z+1)); higher levels zero the lower
      # components per semver.
      IFS='.' read -r fMAJ fMIN fPAT <<< "$floor"
      case "$bump_level" in
        major)   next_free="$((fMAJ + 1)).0.0" ;;
        minor)   next_free="${fMAJ}.$((fMIN + 1)).0" ;;
        patch|*) next_free="${fMAJ}.${fMIN}.$((fPAT + 1))" ;;
      esac
      ```

      Use `next_free`, NOT this PR's stale pre-allocated version (which sits below the floor — that's why the rebase conflicted). (If a later sibling already claimed `next_free` and this PR would collide again, the next rebase pass re-runs this resolution against the new floor — each pass advances to the next free slot at the PR's level.) Per #671's "the floor is the hard constraint, the level is the PR's" principle, the benign edge case where the merge-base delta *over*-estimates the level (a patch PR that was pre-allocated above an in-flight minor sibling's floor at dispatch time) bumps one level too high but never below the floor and never collides — strictly safer than the downgrade this fixes.
   2. **Write the resolved manifest.** Set the `.version` row to `next_free`. Take main's side for every other key (there are none in conflict per gate 3, so a plain `git checkout --theirs "$vc_manifest"` followed by a single `jq`-set of the version row is the cleanest mechanical resolution — or hand-edit the one conflicted line to the computed value and delete the markers).
   3. **Re-number + reorder the CHANGELOG entry (when coordinated).** This PR's CHANGELOG block keeps its prose but its `### <old-version> — <date>` heading is renumbered to `### <next-free-version> — <date>`, and the block is placed **newest-first**: above main's newly-merged top entry. The result must be strictly descending by version with no out-of-order or duplicate `###` headings. (A naïve CHANGELOG "take both" concat would leave this PR's stale lower-versioned entry *below* main's — that out-of-order entry is exactly the bug the issue calls out; re-number + hoist to the top fixes it.)
   4. `git add "$vc_manifest"` (and `"$vc_changelog"` when coordinated), then `git rebase --continue`.
   5. **Record the exact PR-added lines this resolution deliberately rewrites, so step 5.8's line-survival guard doesn't misread the sanctioned renumbering as corruption ([#1215](https://github.com/mattsears18/shipyard/issues/1215)).** Step 5.8 asserts every line the PR's own commit(s) added is still present verbatim, somewhere, in the post-rebase file — and this resolution *intentionally* violates that for exactly two lines: the manifest `.version` row (bumped from the PR's stale pre-allocated version to `next_free`) and the CHANGELOG's own top-of-file heading (renumbered to match). Left unhandled, step 5.8 will flag both coordinated files as `CORRUPTED` on **every** dispatch that takes this path — not a rare edge case, since every PR cuts a release on a coordination-enabled repo, so a sibling merge DIRTYs the version row on essentially every concurrent PR.

      The fix is NOT to exempt either coordinated file wholesale — that would blind 5.8 to genuine corruption elsewhere in the same file (e.g. one of the CHANGELOG entry's own untouched body lines silently mangled by the merge, or a source-of-truth key elsewhere in the manifest). Instead, write the *specific* pre-rebase added-line text this step is about to replace to a known-rewrites file, using the git refs (unaffected by the working-tree writes in items 2–3 above, so this can run at any point in this step):

      ```bash
      WORKTREE_PATH="$(git rev-parse --show-toplevel)"
      mkdir -p "$WORKTREE_PATH/.shipyard-scratch"
      printf '*\n' > "$WORKTREE_PATH/.shipyard-scratch/.gitignore"  # self-ignoring (worker-preamble § "Scratch directory")

      KNOWN_REWRITES="$WORKTREE_PATH/.shipyard-scratch/vc-known-rewrites.tsv"
      : > "$KNOWN_REWRITES"

      # The manifest's PR-added line contains its pre-allocated version string
      # ($pr_version, computed in item 1 above) — extract it from the
      # pre-rebase diff so the recorded text is exactly what ADDED_LINES will
      # compute, never a hand-reconstructed guess.
      manifest_line=$(git diff "$base_sha" "origin/$HEAD_REF" -- "$vc_manifest" \
        | awk '/^\+\+\+/{next} /^\+/{line=substr($0,2); if (line ~ /[^ \t]/) print line}' \
        | grep -F -- "$pr_version" || true)
      [ -n "$manifest_line" ] && printf '%s\t%s\n' "$vc_manifest" "$manifest_line" >> "$KNOWN_REWRITES"

      # The CHANGELOG's PR-added heading is the top-of-file `### <version>`
      # line — gate 4 above already confirmed the only conflict is the
      # top-of-file insert, so this is unambiguous.
      if [ -n "$vc_changelog" ]; then
        changelog_line=$(git diff "$base_sha" "origin/$HEAD_REF" -- "$vc_changelog" \
          | awk '/^\+\+\+/{next} /^\+/{line=substr($0,2); if (line ~ /[^ \t]/) print line}' \
          | grep -E '^### ' | head -1 || true)
        [ -n "$changelog_line" ] && printf '%s\t%s\n' "$vc_changelog" "$changelog_line" >> "$KNOWN_REWRITES"
      fi
      ```

      **If either extraction comes back empty** (the `grep` found no matching added line — an unexpected shape for a resolution that just passed all four eligibility gates), leave that file's entry out of `$KNOWN_REWRITES` rather than guessing. Step 5.8 then checks that file's full added-line set unexempted, which is the safe direction: it can only make the guard *stricter* on a shape it doesn't recognize, never looser. A stricter-than-necessary bail here is recoverable (a human rebases by hand); a loosened exemption on the wrong lines is not.

   After resolving, fall through to step 5 (clean-tree check) and **step 5.5 (the [#436](https://github.com/mattsears18/shipyard/issues/436) conflict-marker assertion) — which is non-negotiable here**: the version-row + CHANGELOG hand-resolution is precisely the "take both, drop the markers" shape that can leave a stray `=======` / `>>>>>>>` line behind. Step 5.5's `git grep` for surviving markers is the safety net that turns a botched re-number into a clean `blocked rebase` instead of a poisoned force-push. Do not skip it.

5. **Verify the working tree is clean after resolution.** Every conflict was either auto-resolvable or you bailed in step 4. If you got here with `git status` showing nothing staged/unstaged but the rebase didn't complete, something is off — bail with `blocked rebase #<M>: rebase ended in inconsistent state`.

   ```bash
   git status --porcelain   # must be empty
   git rev-parse HEAD       # should NOT equal origin/$DEFAULT_BRANCH (you'd have nothing to push)
   ```

   If the rebase produced zero new commits because the branch was already a fast-forward of default (rare — would mean `mergeStateStatus` was lying), return `noop: not dirty (already fast-forward)`. No push needed.

5.5. **Assert no conflict markers survived the resolution — bail if any remain (issue [#436](https://github.com/mattsears18/shipyard/issues/436)).** A `git status`-clean working tree is NOT sufficient proof that a trivial auto-resolution (step 4) actually removed every conflict marker: a "take both blocks, drop the markers" CHANGELOG concat that leaves a stray `=======` or `>>>>>>> <sha>` line still stages clean and commits clean. Before the force-push, grep the rebased tree for the anchored conflict-marker pattern and refuse to push if any line matches:

   ```bash
   if git grep -nE '^(<{7}|={7}|>{7})( |$)' -- . ; then
     git rebase --abort 2>/dev/null || true
     echo "blocked rebase #<M>: conflict markers remain after resolution — needs manual rebase"
     exit 0
   fi
   ```

   The regex is exactly seven of `<` / `=` / `>` at line start followed by a space or end-of-line — the same pattern the repo's `conflict-marker-scan.sh` CI gate (and the `check-merge-conflict` pre-commit hook) use, so a worker that passes this assertion also passes the CI gate. `git grep` exits 0 (and prints the offending `file:line`) when it finds a match, so the `if` branch fires exactly when a marker survived; bail with `blocked rebase` rather than force-pushing the corruption. This is the worker-side half of issue #436's two-layer defense — the CI gate (`.github/workflows/conflict-markers.yml`) is the repo-side catch-net for any path that bypasses this assertion (a non-shipyard force-push, a manual merge), and this assertion stops a fix-rebase dispatch from being the thing that needs catching.

   The original poison-the-main incident was caught only because a *later* manual rebase inherited the markers; the green CI run that merged the corrupted CHANGELOG had no gate that greps for markers. This assertion + the CI gate close that hole from both ends.

5.6. **Assert no released CHANGELOG headings were deleted by the resolution — bail if any are missing (issue [#555](https://github.com/mattsears18/shipyard/issues/555)).** The conflict-marker assertion in step 5.5 catches *unresolved* markers; it cannot catch a *resolved-wrong* merge that silently deletes whole `### <version>` heading blocks. This is the failure mode from issue #555: PR #552 and #553 resolved their CHANGELOG conflicts correctly (no markers survived) yet both dropped released entries (`### 1.9.10` and `### 1.9.9`) from main. The loss was only noticed when a human eyeballed the file during a later manual rebase.

   Before the force-push, run the monotonicity scan to confirm every `### <version>` heading that existed on the rebase base (`origin/$DEFAULT_BRANCH`) is still present in the resolved CHANGELOG:

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   # (variables don't survive across Bash tool calls, so this is re-derived here)
   scanner="${CLAUDE_PLUGIN_ROOT}/scripts/changelog-monotonicity-scan.sh"
   if [[ -f "$scanner" ]]; then
     if ! bash "$scanner" "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
       git rebase --abort 2>/dev/null || true
       echo "blocked rebase #<M>: deleted released CHANGELOG heading(s) after conflict resolution — needs manual rebase (https://github.com/mattsears18/shipyard/issues/555)"
       exit 0
     fi
   fi
   ```

   This assertion is the worker-side half of issue #555's two-layer defense — the CI gate (`changelog-monotonicity-scan.sh` run against the PR head in `tests.yml`) is the repo-side catch-net for any path that bypasses this assertion. Together they mirror the #436 two-layer pattern: this assertion stops a fix-rebase dispatch from being the thing that silently drops entries; the CI gate catches anything that slips through.

   A CHANGELOG with a `changelog-monotonicity-scan: allow` directive opts out of the scan (useful for test fixtures that construct synthetic CHANGELOGs). If the scanner binary isn't present (non-shipyard repo, older plugin installation), skip silently — the CI gate is the load-bearing layer.

5.7. **Post-rebase empty-diff guard — bail if the conflict resolution dropped the PR's change (issue [#646](https://github.com/mattsears18/shipyard/issues/646)).** The conflict-marker assertion (step 5.5) catches *unresolved* markers and the monotonicity scan (step 5.6) catches deleted CHANGELOG headings — but neither catches a resolution that **silently discards the PR's entire substantive change**, collapsing the branch to an empty diff vs base. This is the silent-data-loss failure mode from issue #646: a `fix-rebase` worker resolved a same-line provenance conflict by taking main's side **wholesale** (a whole-file `--theirs`, discarding the PR's non-conflicting substantive hunk in the same file), the net diff vs base went empty, the force-push **auto-closed the PR** (GitHub auto-closes a PR whose head force-pushes to an empty-diff state), and the worker returned `rebased #<M>` (success) — so the shipped work was lost with no `blocked` signal. The #646 repro: PR #2165 (a PostHog Region-column pin) force-pushed to an empty diff, auto-closed, and its issue reverted to OPEN; the change had to be redone from scratch.

   **Before the force-push, compare the PR's net contribution vs base before and after the rebase. If it was non-empty before and is empty after, the resolution dropped the change — bail instead of pushing.** `origin/$HEAD_REF` still points at the pre-rebase head (the force-push is step 6, not yet run), so it's the pre-rebase baseline; the local rebased `HEAD` is based directly on `origin/$DEFAULT_BRANCH`, so its two-dot diff vs that base **is** the PR's net contribution:

   ```bash
   # Pre-rebase net contribution (the original head's change vs the rebased-onto base).
   PRE_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH...origin/$HEAD_REF" | wc -l | tr -d ' ')
   # Post-rebase net contribution (the rebased head's change vs the same base).
   POST_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH" HEAD | wc -l | tr -d ' ')
   if [ "${PRE_FILES:-0}" -gt 0 ] && [ "${POST_FILES:-0}" = "0" ]; then
     git rebase --abort 2>/dev/null || true
     echo "blocked rebase #<M>: rebase produced an empty diff (conflict resolution dropped the PR's change) — needs manual rebase"
     exit 0
   fi
   ```

   **Never force-push a branch whose net change vs base vanished.** Bailing leaves `origin/$HEAD_REF` and the PR untouched (the PR stays DIRTY for a human to rebase by hand) — the safe outcome whether the emptiness came from a dropped change (the data loss to prevent) or from the change having already landed on main via a sibling PR (in which case a human closes the PR cleanly rather than letting a silent force-push auto-close it). The guard is gated on `PRE_FILES > 0` so a PR that was *already* empty before the rebase doesn't false-bail. This assertion runs for **both** the conflict-resolved path and the clean-rebase path — a clean rebase whose result is empty is just as much a silent auto-close hazard. This is the worker-side root fix for #646; never resolve a conflict in a way that can produce this state in the first place (see the hunk-level resolution rule in step 4).

5.8. **Assert every line the PR's own commit added is still present verbatim, per touched file — bail if any went missing (issue [#983](https://github.com/mattsears18/shipyard/issues/983)).** Steps 5.5–5.7 catch, respectively: unresolved conflict markers, deleted CHANGELOG headings, and a whole-PR diff that went empty. None of them catch a narrower and more insidious failure: `git rebase` can report **"Auto-merging \<file\>"** — a clean 3-way merge, zero conflict markers, steps 5.5/5.6/5.7 all pass — while still silently splicing content from the *wrong* hunk into the result. This happens most readily in a file with high internal repetition (many structurally-identical blocks — e.g. repeated `uses:` / `id:` / `with:` step blocks in a CI workflow) combined with a large line-offset shift on the default-branch side (a big refactor landed on main between when the PR branched and when it rebased): diff3/patience matching can mismatch context anchors and merge a hunk against the wrong twin. The result is a file that is textually well-formed (no markers, non-empty, no CHANGELOG loss) but **semantically wrong** — a load-bearing per-job distinction silently collapsed to one variant, with explanatory comments replaced by plausible-looking but mismatched text. See issue #983 for the full repro (a lightwork PR's four-job CI cache split was silently flattened to one variant across three jobs, with the corresponding pinned regression test correspondingly weakened, purely from a "clean" rebase).

   **The check is generic and mechanical — it never inspects *which* file or *what* the content means.** It only asserts a structural invariant: every line the PR's own commit(s) added, relative to the pre-rebase merge-base, must still be found verbatim somewhere in that same file after the rebase. `origin/$HEAD_REF` still points at the pre-rebase head (the force-push is step 6, not yet run) and `origin/$DEFAULT_BRANCH` is the branch being rebased onto, so the merge-base between them is the PR's original branch point — stable regardless of which conflict-resolution path (clean auto-merge, or step 4's trivial hand-resolution) got you here.

   **The check runs as a standalone, testable script, not an inline snippet re-typed per worker ([#1175](https://github.com/mattsears18/shipyard/issues/1175)).** The original inline invocation here piped the added lines into a `grep` call combining the `-v` / `-F` / `-x` / `-f <pattern-file>` flags — typed directly into the worker's own interactive Bash-tool shell. In at least one live worker environment that shell's `grep` is shadowed by a function wrapping `ugrep`, and the shadowed command silently **false-negatived**: it reported "no missing lines" for files that genuinely had missing lines. See [`verify-added-lines-survived.sh`](../../scripts/verify-added-lines-survived.sh) — it avoids `grep` for the comparison entirely (uses `sort`/`comm`/`awk` instead), runs as a genuinely separate `bash` process so it can't inherit the calling shell's function shadowing either, and runs a synthetic self-check before trusting any verdict, failing loud (`exit 2`, `INDETERMINATE:`) rather than reporting a false-clean pass when the comparison mechanism itself can't be trusted in the current environment. Do not re-inline the check — call the script:

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"

   MERGE_BASE=$(git merge-base "origin/$HEAD_REF" "origin/$DEFAULT_BRANCH")

   # If §4.6 fired this dispatch and recorded a known-rewrites file (item 5
   # of its resolution recipe), pass it as the third argument so the two
   # specific lines it deliberately rewrote are narrowly exempted — every
   # other line either coordinated file added is still checked normally.
   # When §4.6 never fired (or its extraction came back empty), no such file
   # exists and this call is byte-for-byte the pre-#1215 unconditional check.
   WORKTREE_PATH="$(git rev-parse --show-toplevel)"
   KNOWN_REWRITES=""
   CANDIDATE_KNOWN_REWRITES="$WORKTREE_PATH/.shipyard-scratch/vc-known-rewrites.tsv"
   [ -f "$CANDIDATE_KNOWN_REWRITES" ] && KNOWN_REWRITES="$CANDIDATE_KNOWN_REWRITES"

   VERIFY_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-added-lines-survived.sh" "$MERGE_BASE" "origin/$HEAD_REF" ${KNOWN_REWRITES:+"$KNOWN_REWRITES"} 2>&1)
   VERIFY_STATUS=$?

   if [ "$VERIFY_STATUS" != "0" ]; then
     git rebase --abort 2>/dev/null || true
     echo "blocked rebase #<M>: line-survival check did not pass ($VERIFY_OUTPUT) — needs manual rebase (https://github.com/mattsears18/shipyard/issues/983)"
     exit 0
   fi
   ```

   **Exit 0 is the only "safe to proceed" result.** The script's exit 1 (`CORRUPTED:<files>` — a real mismatch found) and exit 2 (`INDETERMINATE: <reason>` — the check couldn't establish a trustworthy result at all, e.g. an unresolvable ref or a broken `sort`/`comm` in this environment) are both bail conditions here — never branch on exit 1 vs 2 to decide whether to proceed; only exit 0 does.

   **Why exact-line matching, not a semantic diff.** The check deliberately doesn't try to understand the file's structure or meaning — that would require per-file domain knowledge, which is exactly what this guard must NOT hard-code. Exact verbatim survival of every added line is a cheap, universal, false-positive-resistant proxy: legitimate further edits from other trivial-conflict resolution (step 4) still leave the PR's own added lines intact, because those lines were never in conflict in the first place. A false positive here (an added line legitimately reworded by a later, unrelated commit already on the PR branch before this rebase) is rare and cheap to recover from — one `blocked rebase` and a human eyeballs the diff; a false negative (silent corruption slipping through) is the failure mode from #983, with no error signal at all and a real functional regression landing behind a green CI run.

   **Why this runs unconditionally, for every touched file, regardless of path — with exactly one narrow, per-line exception ([#1215](https://github.com/mattsears18/shipyard/issues/1215)).** Unlike step 4.6's manifest/CHANGELOG carve-out, this guard makes no attempt to classify a *file* as "safe" up front — a file this PR modified only lightly can be just as vulnerable to a mismatched-context splice as a file it changed heavily, and pre-selecting "files worth checking" would reintroduce the exact per-file judgment this guard exists to avoid. The cost of checking every touched file is a handful of cheap `git diff` / `sort` / `comm` calls — far below the cost of a silent regression landing on `main`.

   The one exception is item 5 of step 4.6's resolution recipe: when that carve-out fires, it *by construction* rewrites the manifest `.version` row and the CHANGELOG's own top-of-file heading away from what the PR's commits originally added — a deliberate, sanctioned edit, not corruption, but indistinguishable from corruption to a guard that only ever compares "was this exact line added, is it still here verbatim." Rather than weakening this guard to skip `vc_manifest`/`vc_changelog` wholesale (which would blind it to real corruption elsewhere in either file — e.g. an untouched CHANGELOG body line silently mangled by the same rebase), step 4.6 item 5 records the *exact two lines* it is about to rewrite, and this step passes that record to `verify-added-lines-survived.sh` as an optional third argument. The script only ever exempts the specific line text named — every other line either coordinated file's PR commits added is still required to survive verbatim, exactly as before. When step 4.6 never fired (the common non-coordination-carve-out path, or a plain clean rebase with no conflicts at all), no known-rewrites file exists and this call is byte-for-byte the original unconditional, file-blind check — the exception only ever narrows the guard for the one call site that both introduces the rewrite and can prove exactly what it rewrote.

6. **Push the rebased branch.** This is a fast-forward-incompatible operation (rebase rewrites commit SHAs), so a force push with lease is required. You're in detached HEAD (per step 1), so push `HEAD` explicitly to the remote branch ref rather than relying on an upstream:
   ```bash
   git push --force-with-lease origin "HEAD:refs/heads/$HEAD_REF"
   ```

   `--force-with-lease` (not plain `--force`) refuses the push if someone else pushed to the branch between your `git fetch` and your `git push` — it checks the remote ref (`refs/heads/$HEAD_REF`, resolved from the push destination) against your locally-known `origin/$HEAD_REF`, which step 1's fetch established as the baseline. That's the safety net against clobbering a concurrent author push — bail with `blocked rebase #<M>: head branch moved during rebase — retry next session` if the lease check rejects.

   If step 4.6's item 5 wrote a `.shipyard-scratch/vc-known-rewrites.tsv`, clean it up now (best-effort, non-blocking per worker-preamble § "Scratch directory"): `rm -rf "$WORKTREE_PATH/.shipyard-scratch" 2>/dev/null || true`.

7. **Return one line.** No `gh pr edit`, no `gh pr merge --auto` re-call (auto-merge was already armed when the PR was opened; rebasing doesn't un-arm it), no `--watch`, and — per `shipyard:worker-preamble` § "Return-contract discipline" ([#529](https://github.com/mattsears18/shipyard/issues/529)) — no arming a `run_in_background` process / `Monitor` / background-waiter and returning a non-terminal narrative before it resolves. Run the rebase synchronously to a terminal state and return exactly one of the strings below. The drain phase's next per-poll snapshot will see the PR transition out of DIRTY:
   - `rebased #<M>` — rebase succeeded, branch was force-pushed, drain phase resumes monitoring it.
   - `noop: not dirty (<reason>)` — pre-flight (step 2) found the PR was no longer DIRTY by the time you started; reason is the actual `mergeStateStatus` or `state` value observed.
   - `blocked rebase #<M>: <reason>` — conflict was non-trivial, head branch moved under you, or some other deterministic failure. The drain will leave this PR alone for the rest of the session and surface it in the end-of-session summary as a still-DIRTY PR needing human attention.

## Hard rules

- One rebase attempt per dispatch. If the first attempt blocks, return `blocked` — do NOT retry. The drain will move on; a human (or the next session) can pick it up.
- Never `gh pr merge` manually. Auto-merge was armed when the PR was first opened (or by the orchestrator's reconcile after a fix-checks). Rebasing a green-or-pending PR is sufficient to re-arm the merge train; manual merging would skip the merge train's protection against last-second base drift.
- Never edit the PR's title, body, or labels. The PR's existing description references the original commits — a rebase preserves their content, not necessarily their SHAs, but the human-readable summary stays correct.
- Never close the linked issue from this dispatch. The PR's body already has the `Closes #N` line; merging the rebased branch closes the issue automatically.
- **Leave your worktree checked out at the PR's head commit when you return** (not `main` / the default branch). Detached HEAD is the expected state in this mode — you never need to be on a named branch. See worker-preamble's worktree discipline rule 3.

## Don't

- **Don't resolve a non-trivial merge conflict.** The trivial-or-bail rule exists because rebase-mode dispatches happen during the drain phase, when the orchestrator is winding down and the goal is keeping the merge train moving — not authoring code. A merge conflict that requires reading more than the conflict markers is a signal that the rebase needs a human (or a fresh issue-mode dispatch in a future session). `git rebase --abort` and return `blocked rebase`. The instinct to "just figure out which side wins, it looks small" is the failure mode this rule prevents — semantic merges in a drain context don't have the test scaffolding or review attention they need to be correct.
- **Don't `gh pr merge` manually.** Auto-merge was armed when the PR was originally opened (in issue-work mode's step 6, or by the orchestrator's reconcile after a fix-checks-only dispatch). Force-pushing a rebased branch doesn't un-arm auto-merge — the next green CI run on the rebased head will trigger it. Manually calling `gh pr merge` would bypass the merge train's protection against last-second base drift; the auto path is what should resolve the PR.
- Don't `--watch` checks. Push the rebased branch, return one line, let the drain's next poll observe the state transition.
- **Don't open a `Monitor`/poll loop to watch CI to completion instead of returning ([#753](https://github.com/mattsears18/shipyard/issues/753)).** Push the rebased branch and return immediately — never start a `Monitor` sub-task or a backgrounded CI watch and wait for the rebased head to go green before returning. See `shipyard:worker-preamble` § "Return-contract discipline".
- Don't retry on `blocked rebase`. One dispatch, one rebase attempt — the drain doesn't re-dispatch within the same session.
- **Never create a credential.** See `shipyard:worker-preamble` § "Never create a credential" — a missing credential is a hand-back, not something to route around ([#1166](https://github.com/mattsears18/shipyard/issues/1166)).

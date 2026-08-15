# /shipyard:do-work — Setup phase · immediate pre-relocation re-read on staleness

**Setup sub-phase fragment, loaded from [`00-config-worktree.md`](./00-config-worktree.md)'s step-0.42 pointer — conditionally part of the ordered per-session walk: every session reaches the step-0.42 pointer, but this fragment's body is a no-op unless step 0.4's staleness check fired.** When it does fire, runs BEFORE step 0.45 (and BEFORE step 0.5's `EnterWorktree` relocation), while cwd is still the primary checkout. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`00-config-worktree.md`](./00-config-worktree.md) (step 0.4). Next: back to [`00-config-worktree.md`](./00-config-worktree.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202) for step 0.45.

### 0.42 Immediate fresh re-read on staleness ([#1351](https://github.com/mattsears18/shipyard/issues/1351))

**Migration-window backstop as of [#1386](https://github.com/mattsears18/shipyard/issues/1386).** [Step 0.41's staleness gate](./00-config-worktree.md#041-staleness-gate--self-heal-the-primary-checkout-or-refuse-to-run-1386) now either fast-forwards the primary checkout (and restarts setup from step 0.3, with `$SHIPYARD_PLUGIN_ROOT_STALE` unset on the second pass) or stops the session — so on any checkout carrying 0.41, this step is structurally unreachable. It stays in place for the bounded one-time window in which a primary checkout is stale enough to predate 0.41 itself, and reaches this step via a 0.42 pointer it *does* have. That is the same one-level-deep property #1351 documents below; 0.41 exists precisely because that property is recursive and can only be broken at step 0.4's check, the one anchor present in every copy back to [#907](https://github.com/mattsears18/shipyard/issues/907).

**No-op unless `$SHIPYARD_PLUGIN_ROOT_STALE` was set at [step 0.4](./00-config-worktree.md#04-check-the-repo-level-opt-in-shipyardconfigjson) — then run this now, before step 0.45, not deferred to step 0.6.** [Step 0.4](./00-config-worktree.md#04-check-the-repo-level-opt-in-shipyardconfigjson)'s staleness check and [step 0.6](./00-config-worktree.md#06-re-read-stale-spec-files-1191)'s fresh re-read (fragment [`00d-reread.md`](./00d-reread.md)) were each individually correct but had an ordering hole between them ([#1351](https://github.com/mattsears18/shipyard/issues/1351)): step 0.6 only runs **post-relocation**, but [step 0.45](./00-config-worktree.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202) (added by [#1202](https://github.com/mattsears18/shipyard/issues/1202)) must run **before** `EnterWorktree` — so on a primary checkout stale enough to predate #1202, the orchestrator reaches step 0.45's position having read only the stale `00-config-worktree.md`, which contains no step-0.45 pointer at all, relocates at step 0.5 without ever running it, and only discovers 0.45 existed at step 0.6 — too late, the worktree-isolation guard is already active and every `git -C <other-worktree>` command the sweeps need is now refused. The staleness that triggers the hole is the same staleness that hides the fix, so it's self-concealing and gets worse the longer the primary checkout has drifted.

**The fix needs only `CLAUDE_PLUGIN_ROOT` (already resolved) and the `git fetch` step 0.4 already ran — no relocation required.** `git show` reads a tracked blob straight out of the fetched remote ref; it doesn't touch the primary checkout's working tree, so it's safe to run here, before `EnterWorktree`:

```bash
if [ -n "$SHIPYARD_PLUGIN_ROOT_STALE" ]; then
  for SY_REREAD_REL in \
    "plugins/shipyard/commands/do-work/dont.md" \
    "plugins/shipyard/commands/do-work/setup.md" \
    "plugins/shipyard/commands/do-work/setup/00-config-worktree.md"
  do
    SY_REREAD_LOCAL="$SHIPYARD_PRIMARY_CHECKOUT_ROOT/$SY_REREAD_REL"
    SY_REREAD_FRESH=$(git show "origin/$STALENESS_DEFAULT_BRANCH:$SY_REREAD_REL" 2>/dev/null)
    if [ -z "$SY_REREAD_FRESH" ]; then
      echo "warn: could not fetch fresh $SY_REREAD_REL via git show — step 0.6 is the remaining backstop" >&2
      continue
    fi
    printf '%s\n' "===== fresh origin/$STALENESS_DEFAULT_BRANCH:$SY_REREAD_REL ====="
    printf '%s\n' "$SY_REREAD_FRESH"
    # Fix 3 (#1351): flag any step heading in the 0.40-0.49 range gained by
    # the fresh copy that the stale on-disk copy doesn't have — that's
    # exactly the window a step must fall in to need pre-relocation timing
    # (anything >= 0.5 is safely picked up later, once CLAUDE_PLUGIN_ROOT
    # re-resolves to the fresh orchestrator worktree at step 0.5).
    SY_NEW_STEPS=$(diff -u "$SY_REREAD_LOCAL" <(printf '%s\n' "$SY_REREAD_FRESH") 2>/dev/null \
      | grep -E '^\+### 0\.4[0-9]' || true)
    if [ -n "$SY_NEW_STEPS" ]; then
      echo "advisory: $SY_REREAD_REL gained pre-relocation step heading(s) this session's stale copy didn't have (#1351):" >&2
      printf '%s\n' "$SY_NEW_STEPS" | sed 's/^\+/  - /' >&2
      SY_STEPS_LIST=$(printf '%s' "$SY_NEW_STEPS" | sed 's/^\+### //' | tr '\n' ',' | sed 's/,$//')
      SHIPYARD_PRERELOC_STEP_CAUGHT="${SHIPYARD_PRERELOC_STEP_CAUGHT:+$SHIPYARD_PRERELOC_STEP_CAUGHT; }$SY_STEPS_LIST"
    fi
  done
fi
```

**Treat the fresh output above — not the stale on-disk copies already read into context — as authoritative for the rest of pre-relocation setup.** In particular: if the advisory fired, a step numbered between 0.4 and 0.5 exists in the fresh spec that this session hasn't run yet. Read (via the same `git show origin/$STALENESS_DEFAULT_BRANCH:<repo-relative-path>` form — the target fragment file may not exist on disk locally at all yet, exactly the #1202/00e case) and execute that step now, in its documented position, before continuing to [step 0.45](./00-config-worktree.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202). `SHIPYARD_PRERELOC_STEP_CAUGHT` is session-local working memory (not mirrored to the session-state file) — set only when this catch fires, read by [cleanup-summary.md's end-of-session summary](../cleanup-summary.md#end-of-session-summary) so a caught-and-run step is visible in the session record, not silently invisible the way a missed one used to be.

**If `git show` failed for a file** (network hiccup, `origin` unreachable) — the per-file `warn:` above already named it. Step 0.6 is the remaining backstop for that file once relocation completes and reads become cheap local `Read` calls again, but note: a pre-relocation-window step (0.4x) that step 0.6 discovers **after** `EnterWorktree` has already run is a genuine miss, not merely a delayed catch — see [`00d-reread.md`'s advisory](./00d-reread.md) for how that case is surfaced.

**Return to [`00-config-worktree.md`'s step 0.45](./00-config-worktree.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202) once this step completes.**

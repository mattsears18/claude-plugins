# /shipyard:do-work — Setup phase · orphan orchestrator-worktree reap detail

**Setup sub-phase fragment, loaded from [`01-repo-recovery.md`](./01-repo-recovery.md#165-reap-orphan-orchestrator-worktrees)'s step-1.6.5 stub pointer (and from [`00e-pre-relocation-sweeps.md`](./00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202)'s step-5, which is where this sweep actually executes) — not part of the ordered per-session walk.** Owns the full step-1.6.5 detail: sweep `.claude/worktrees/` for orphaned `orchestrator-<dead-session-id>/` directories left behind by prior sessions that crashed before reaching cleanup. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md).

### 1.6.5 Reap orphan orchestrator worktrees

> **MOVED pre-relocation ([#1202](https://github.com/mattsears18/shipyard/issues/1202)) — no longer part of the post-relocation background group; this section is now the canonical implementation.** This sweep's `git -C <other-worktree>` operations and `worktree-reap.sh reap --worktree-path <other-worktree>` calls are refused outright by the harness's worktree-isolation guard once [step 0.5](00-config-worktree.md#05-move-into-the-orchestrators-worktree)'s `EnterWorktree` call has isolated the session (*"this command redirects git to the shared checkout via -C. Refusing it"*) — and the mandatory pre-reap inspection for unpushed work ([#838](https://github.com/mattsears18/shipyard/issues/838)) is exactly the kind of `git -C` read the guard blocks, so there is no safe degradation available at runtime: the guard doesn't merely block the reap, it blocks the safety check that makes reaping safe. [Step 0.5's `EnterWorktree` call was itself mandated (#844)](00-config-worktree.md#05-move-into-the-orchestrators-worktree) to fix a *different* problem (a background-job session's `Edit`/`Write` calls being refused pre-isolation) — so the two fixes were in direct, unresolvable conflict as long as this sweep ran after relocation. The fix: run it BEFORE relocation instead, at [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202), while cwd is still the primary checkout and the guard has no isolated session to enforce against.

**Sweep `.claude/worktrees/` for `orchestrator-<dead-session-id>/` directories left behind by prior sessions that crashed before reaching [`cleanup-summary.md`'s step 6 (orchestrator-worktree reap)](../cleanup-summary.md#end-of-session-cleanup).** Companion to [step 1.6](01-repo-recovery.md#16-reap-orphan-session-files-cost-ledger-recovery), which reaps orphan session *files*; this step reaps the *worktrees* themselves. Neither sweep was sufficient on its own:

- **Step 1.6** only deletes the session JSON from `$SHIPYARD_HOME/sessions/`. The worktree dir under the repo's `.claude/worktrees/` is untouched, so a dead session's worktree dir accumulates indefinitely.
- **Step 3b** only reaps `agent-*` worktrees (the per-dispatched-agent isolation worktrees). It scopes intentionally — `orchestrator-*` worktrees have different lock semantics and historically were retired by the owning session's own cleanup-summary step 6.

When a prior session crashed *between* step 7→8 (cost-history flush + session-file cleanup) and step 6 (orchestrator-worktree reap), the session file is gone but the worktree lingers. See [RATIONALE → Step 1.6.5 production trace](../../do-work-RATIONALE.md#step-165--orphan-orchestrator-worktree-production-trace-280) for the incident that surfaced this gap (issue #280).

The discovery uses [`session-identity.sh find-orphan-orchestrators`](../../../scripts/session-identity.sh), which applies the same liveness gate as step 1.6 — `is-active` exits 0 if the owning session's PID is alive, exit 1 otherwise (missing file, missing/null pid, dead pid). Both the worktree-sweep and the session-file-sweep treat "file missing" as inactive: the common case for the bug is that prior cleanup got far enough to flush + delete the session file but stopped short of reaping its own worktree.

**The id tested for liveness is the candidate's OCCUPANT, not its directory name ([#1232](https://github.com/mattsears18/shipyard/issues/1232)).** A directory named `orchestrator-<id>` only records who *created* the worktree — [step 0.5's](00-config-worktree.md#05-move-into-the-orchestrators-worktree) `EnterWorktree` call refuses to create a second isolated worktree for an already-isolated session, so a second `/do-work` run in one already-isolated Claude session reuses the existing worktree directory under a freshly-derived session id ([step 0.55](00f-session-id-storage.md)), and from that moment the directory's name and its live occupant are permanently out of sync for the rest of that session's life. Reading the name alone — the pre-#1232 behavior — misclassified a **live** session's own cwd as reap-eligible and this step's `git worktree remove --force` (with its `rm -rf` fallback) destroyed it mid-run, including anything uncommitted. `find-orphan-orchestrators` now reads `<candidate>/.shipyard-session-id` — the same stash `derive-session-id` above already trusts exclusively (#365/#513) — and tests *that* id for both the current-session exclusion and the liveness check; it falls back to the name-embedded id only when the stash is missing/unreadable AND the candidate directory is otherwise completely empty (nothing to lose either way). Any other candidate with an unreadable stash is skipped outright — never emitted — mirroring the fail-closed `unknown` verdict [#1206](https://github.com/mattsears18/shipyard/issues/1206) gave `classify-lock`: a missed reap only costs disk, a wrong reap costs a running session's uncommitted work.

**Resolve `CLAUDE_PLUGIN_ROOT` via step 0.3's pre-relocation compound preamble** (the `.shipyard-plugin-root` stash below is a step-0.5-and-later artifact and doesn't exist yet at this point in the session — this section is now the canonical implementation, executed at [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202)):

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
cd "$(git rev-parse --show-toplevel)"
while read -r orph_path; do
  [ -z "$orph_path" ] && continue
  [ -d "$orph_path" ] || continue
  orph_name=$(basename "$orph_path")
  orph_session_id="${orph_name#orchestrator-}"
  # Issue #284 — `worktree-reap.sh reap` handles BOTH the git-worktree-remove
  # attempt AND the rm -rf fallback internally, and emits the appropriate
  # action variant (`reaped-orphan-orchestrator` vs the `-raw-rm` suffix)
  # in a single audit-log line.
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
    --action reaped-orphan-orchestrator \
    --worktree-path "$orph_path" \
    --worktree-name "$orph_name" \
    --session-id "<session-id>" \
    --reaped-session-id "$orph_session_id" \
    --phase "setup-1.6.5" 2>/dev/null || true
done < <("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" find-orphan-orchestrators \
           --repo-root "$(pwd)" --current-session-id "<session-id>" 2>/dev/null)
git worktree prune 2>/dev/null || true
```

**Audit-log shape** — same `~/.shipyard/reap-audit.jsonl` as steps 3 / 3b, but with a distinct `action` value so the source is traceable. The helper emits these variants for us (issue #284 moved the JSONL writes into [`worktree-reap.sh reap`](../../../scripts/worktree-reap.sh) — see step 3b for the same pattern):

- `action: "reaped-orphan-orchestrator"` — successful `git worktree remove --force`.
- `action: "reaped-orphan-orchestrator-raw-rm"` — fallback when the worktree was unregistered with git (raw dir left after a crash); resolved via `rm -rf`. The helper chooses between these automatically; the caller passes the same `--action reaped-orphan-orchestrator` and the helper picks the right line based on which path actually succeeded.
- `action: "reaped-orphan-orchestrator-failed"` — emitted only when BOTH `git worktree remove` and `rm -rf` failed (the dir is somehow non-removable — permissions, mount issue). Surfaces the failure for traceability rather than swallowing it silently.
- Each line carries a `reaped_session_id` field (the embedded session id of the orphan) and `phase: "setup-1.6.5"` so a future debugger can correlate against the prior session's run.

The fallback to raw `rm -rf` is load-bearing: `git worktree remove` fails when the worktree dir is on disk but `.git/worktrees/<name>/` metadata has already been pruned (or was never registered — e.g., a manual `mv` left an `orchestrator-*` dir without git tracking it). Without the fallback, the dir would linger across an unbounded number of subsequent `/do-work` sessions. See [RATIONALE → Step 1.6.5 production trace](../../do-work-RATIONALE.md#step-165--orphan-orchestrator-worktree-production-trace-280) for why this specific failure mode matters in practice.

**Skip condition.** Like step 1.6, this sweep is skipped entirely when `SHIPYARD_KEEP_SESSIONS=1` — the user is explicitly opting to keep historical state, and worktree dirs are part of that state.

**Concurrency safety.** This step's discovery (`find-orphan-orchestrators`) already excludes the current session by id, so there's no race against the orchestrator's own worktree regardless of whether it runs pre-relocation (this step, per #1202) or in the same pass as [step 1.6](01-repo-recovery.md#16-reap-orphan-session-files-cost-ledger-recovery) (its pre-#1202 position) — the helper filters `<current-session-id>` from its output before emitting paths either way. A concurrent peer `/do-work` orchestrator in another terminal *can* race here: if peer A is the dead session whose worktree we want to reap, and peer B started up at the exact same wall-clock second, peer B's `is-active` check might see A's pid as alive (because A hasn't yet finished crashing) and skip the reap. That's the conservative outcome — A's worktree gets cleaned up by the next session that starts after A's pid is actually gone. The race never produces a wrongful reap.

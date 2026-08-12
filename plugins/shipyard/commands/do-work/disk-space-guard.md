# /shipyard:do-work — Disk-space backpressure check (issue #1261)

**Loaded from [`steady-state.md`'s step C](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action), right before the dispatch rules are applied — not part of the ordered per-session walk.** Split out from `steady-state.md` itself ([#611](https://github.com/mattsears18/shipyard/issues/611)'s phase-file size cap — `steady-state.md` was already within ~150 bytes of the 245760-byte cap on `main` before this check existed, the same pressure [`invariant-line.md`](./invariant-line.md) exists to relieve, per the still-open [#1237](https://github.com/mattsears18/shipyard/issues/1237)). Router: [`steady-state.md`](./steady-state.md). Sidebar: [`dont.md`](./dont.md).

**Run before filling ANY freed slot, same posture as the [queue-depth backpressure check](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) that precedes it in step C.** A long session accumulates one `agent-*` worktree per dispatch. [A.0.5](./steady-state.md#a05-post-return-worktree-reap-for-crashed--narrative-non-terminal-returns-fires-before-a1s-return-string-parsing) / A.1's `shipped`-immediate reap / [step B's per-completion reap](./steady-state.md#b-release-the-slot) / [dispatch-rules.md §2d's pre-dispatch reap](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) are each individually correct, but the #1261 repro showed the disk can still fill mid-session regardless — a session that reaped 43 stale worktrees at setup still accumulated ~20 new ones over ~20 dispatches (roughly one survivor per dispatch) across a single ~4.5h run, driving a shared host to `ENOSPC` and taking its self-hosted CI runner pool down with it.

**This check is a backstop for whatever gap lets the per-completion reap points fall behind — never a replacement for any of them, and it must never weaken [#832](https://github.com/mattsears18/shipyard/issues/832)'s in-flight-liveness guard or [#836](https://github.com/mattsears18/shipyard/issues/836)'s never-infer-from-branch-name guard to get there.** It reuses `worktree-reap.sh reap-stale` unmodified — the same bounded, in-flight-safe, oldest-first sweep [setup step 3b](./setup/01c-label-recovery-refine.md#3b-reap-stale-agent-worktrees-from-dead-claude-code-sessions) already runs once at session start — so both guards are enforced by construction, not re-derived here: `reap-stale` excludes any worktree whose agent-id is currently `.in_flight` **before** classification is even consulted (auto-derived from `--session-id`'s own session-state file per [#1147](https://github.com/mattsears18/shipyard/issues/1147), no manual exclude-list bookkeeping needed), and its classification path (`classify-all`) is lock-file-liveness-only — it never reads a worktree's branch name.

Read `worktree_reap.disk_free_floor_mb` (config default `10240` MB / 10 GiB) and probe free space on the volume holding `.claude/worktrees` via the `worktree-reap.sh disk-check` subcommand:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SHIPYARD_REPO_ROOT=$(cat "$REPO_ROOT/.shipyard-primary-root" 2>/dev/null)
[ -z "$SHIPYARD_REPO_ROOT" ] && SHIPYARD_REPO_ROOT="$REPO_ROOT"
export SHIPYARD_REPO_ROOT

floor_mb=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get worktree_reap.disk_free_floor_mb 2>/dev/null || echo "10240")
disk_probe=$("$CLAUDE_PLUGIN_ROOT/scripts/worktree-reap.sh" disk-check \
  --path "${REPO_ROOT}/.claude/worktrees" --floor-mb "${floor_mb:-10240}" 2>/dev/null)
disk_free_mb=$(printf '%s\n' "$disk_probe" | sed -n 's/^free_mb=\([a-z0-9]*\) .*/\1/p')
disk_low=$(printf '%s\n' "$disk_probe" | sed -n 's/.* low=\([a-z]*\)$/\1/p')

if [ "${disk_low:-false}" = "true" ]; then
  max_per_session=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get worktree_reap.max_per_session 2>/dev/null || echo "10")
  disk_sweep_out=$("$CLAUDE_PLUGIN_ROOT/scripts/worktree-reap.sh" reap-stale \
    --repo-root "$REPO_ROOT" \
    --session-id "<session-id>" \
    --max-per-session "${max_per_session:-10}" 2>/dev/null)
  disk_sweep_summary=$(printf '%s\n' "$disk_sweep_out" | tail -1)
  echo "[disk-guard] free=${disk_free_mb}MB < floor=${floor_mb}MB — ran reap-stale: ${disk_sweep_summary}"

  # Re-probe for the invariant-line token below — the sweep may have
  # reclaimed enough to clear the low reading, or may not have (the cap
  # was already reached, or every eligible worktree was peer-alive and
  # deferred). Either way, report what's actually true post-sweep.
  disk_probe=$("$CLAUDE_PLUGIN_ROOT/scripts/worktree-reap.sh" disk-check \
    --path "${REPO_ROOT}/.claude/worktrees" --floor-mb "${floor_mb:-10240}" 2>/dev/null)
  disk_free_mb=$(printf '%s\n' "$disk_probe" | sed -n 's/^free_mb=\([a-z0-9]*\) .*/\1/p')
fi
```

**This check never blocks or delays dispatch itself** — unlike the CI queue-depth check above it, it doesn't park the slot when the floor is crossed; it only interposes a bounded, already-safe reclaim sweep in front of the normal dispatch flow. If the sweep can't recover enough space (the cap was already reached this session, or every eligible worktree was genuinely peer-alive), dispatch still proceeds this turn — the still-low `disk_free_mb` reading is what makes the smell visible on [step E's invariant line](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn) for a human to act on (raise the floor, free host disk, lower `concurrency`), rather than silently discovering it via a worker's own `ENOSPC` failure. `worktree_reap.disk_free_floor_mb: 0` disables the guard entirely (the probe still runs and reports, but `low` never trips).

`disk_free_mb` — the `<N>` or `unknown` from whichever probe ran last above — feeds directly into step E's `disk_free_mb=` invariant-line token; no separate read is needed there. See [step E's own paragraph](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn) for the token's divergence-smell and missing-token-is-a-contract-violation rules — this file owns the mechanism, step E owns the token's meaning on the invariant line itself.

Return to [`steady-state.md`'s step C](./steady-state.md#c-dispatch-a-replacement-if-work-remains--mandatory-action) and apply the dispatch rules to pick the next job.

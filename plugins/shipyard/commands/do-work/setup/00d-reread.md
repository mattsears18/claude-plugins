# /shipyard:do-work — Setup phase · post-relocation re-read of pre-relocation spec files

**Setup sub-phase fragment, loaded from [`00-config-worktree.md`](./00-config-worktree.md#06-re-read-stale-spec-files-1191)'s step-0.6 pointer — not part of the ordered per-session walk except when step 0.4's staleness warning fired.** Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md).

## Why this exists ([#1191](https://github.com/mattsears18/shipyard/issues/1191))

`dont.md`, `setup.md`, and `00-config-worktree.md` are necessarily read from the PRIMARY checkout — the orchestrator can't relocate into its own worktree until it has read [step 0.5](./00-config-worktree.md#05-move-into-the-orchestrators-worktree)'s instructions for doing so. When [step 0.4](./00-config-worktree.md#04-check-the-repo-level-opt-in-shipyardconfigjson)'s dogfooding staleness check fires (the primary checkout is behind `origin/<default-branch>`), those already-read spec files are confirmed stale — not merely "stale going forward." Step 0.5's relocation re-resolves `CLAUDE_PLUGIN_ROOT` for *later* reads, but nothing before this step told the orchestrator to re-read what it had already consumed. A phase file whose prose changed since (a routing rule, a defer class, a label rename) would otherwise run silently unchanged for the rest of the session, with no further warning.

**Repro:** a session against a 59-commit-stale primary checkout produced 5 consecutive refused Bash calls, because it was still executing the pre-[#1181](https://github.com/mattsears18/shipyard/issues/1181) form of step 0.3's compound `CLAUDE_PLUGIN_ROOT` preamble — unaware the stale copy it read had already been superseded at `origin/<default-branch>`.

## Action — discard the in-context copies, `Read` them fresh

By this point `CLAUDE_PLUGIN_ROOT` has already been re-resolved post-relocation (step 0.5) and stashed at `.shipyard-plugin-root`; that stash — not step 0.4's pre-relocation value — is the source for these re-reads:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
```

Then `Read` (not `cat` — these are spec files the orchestrator reasons over, not text to pipe) each of the three files below, treating the fresh content as authoritative and superseding whatever was read pre-relocation:

- `$CLAUDE_PLUGIN_ROOT/commands/do-work/dont.md`
- `$CLAUDE_PLUGIN_ROOT/commands/do-work/setup.md`
- `$CLAUDE_PLUGIN_ROOT/commands/do-work/setup/00-config-worktree.md`

Three `Read` calls — cheap, and only on the dogfooding-and-stale path. Steps 0.3/0.4 themselves already ran and are not re-executed, only re-read for their *current* text; any behavioral difference between the stale and fresh copies (a routing rule, a defer class, a label rename, a preamble-shape fix like #1181's) governs from this point forward.

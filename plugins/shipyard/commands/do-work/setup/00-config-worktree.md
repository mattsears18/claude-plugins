# /shipyard:do-work — Setup phase · config + worktree

**Setup sub-phase (cluster 1 of 5, part 1 of 2 — [#994](https://github.com/mattsears18/shipyard/issues/994)).** Owns the Lightweight C=1 index, the run-once Setup preamble, and steps 0.3 → 0.7 (intro): `CLAUDE_PLUGIN_ROOT` re-export, repo-level opt-in check, orchestrator-worktree relocation, per-worktree session-id storage, and the start of the fire-once parallelization contract. The rest of step 0.7 (the canonical batch + background cleanup group), the `blocker_state` cache, and the `gh-cached.sh` / `gh-batch.sh` wrappers continue in **[`00b-parallelization-cache.md`](./00b-parallelization-cache.md)** — this file was split into two once it grew past the per-`Read` token cap on its own ([#994](https://github.com/mattsears18/shipyard/issues/994); the original single-file split from [#611](https://github.com/mattsears18/shipyard/issues/611) was sized against the 256KB byte limit, not the 25k-token `Read` cap that actually binds). Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Next: [`00b-parallelization-cache.md`](./00b-parallelization-cache.md) (same cluster, part 2) → [`01-repo-recovery.md`](./01-repo-recovery.md).

## Lightweight C=1 path — what's skipped and what stays

Default `--concurrency` is `1`, and at C=1 a substantial chunk of the orchestrator's parallel-coordination machinery is **already skipped** by per-step gates throughout the spec. This section is a single index of those gates so a reader doesn't have to grep across the phase files to assemble the picture — every entry below is implemented by the linked spec callout, not by this section. Closes [#347](https://github.com/mattsears18/shipyard/issues/347).

**The C=1 path is the default.** No flag, no config opt-in — pass `--concurrency 1` (or omit `--concurrency` entirely; `1` is the default) and the gates below fire automatically.

### What's skipped at C=1

| Skipped at C=1 | Why | Owning callout |
|---|---|---|
| Parallel setup batch (`step_0_7_parallel_batch` timing window, the fire-once-batch read burst, pre-population of a candidate pool) | At C=1 there's only one slot — no peer agents to coordinate against and no benefit from pre-populating a pool of more than one candidate. Steps 1 → 5 run serially instead. | [step 0.7](#07-setup-parallelization-contract-fire-once-batch) |
| Initial failing-PR snapshot (step 5) | The failing-PR set is only relevant when there's a free slot to dispatch a fix-checks worker against it, and at C=1 the slot is guaranteed to be free between dispatches. Defer the query to the first idle turn in steady-state's step D. | [step 5](04-backlog-divert.md#5-snapshot-failing-prs) |
| Batched initial scope pre-flight (step 6's `2 × concurrency` pre-flight) | At C=1 pre-flighting 2 candidates upfront is wasted token spend — by the time the single slot returns, rankings may have shifted and pre-flighted decisions are stale. Pre-flight only the top candidate immediately before each dispatch instead. | [step 6](06-scope-preflight.md#6-initial-scope-pre-flight) |
| Initial pool fill burst (step 7's parallel `Agent` burst across N slots) | The "pool" is a single slot. Dispatch exactly one worker via the same dispatch rules; no `run_in_background: true` needed. | [step 7](07-pool-fill.md#7-initial-pool-fill) |
| Path-collision check (step C's `claimed_paths.hard` ∩ `in_flight` pass) | The check is a pure overhead pass that always resolves to "no collision" because `in_flight` is either empty or holds exactly one slot (the current worker, which has already been released by step B before step C runs). | [steady-state.md step C — Hard collision](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) |
| Soft-cap counter (the `--soft-collision-concurrency` tier) | No main-concurrency cap to burst past and no peer slots to share a path with. Don't track `claimed_paths.soft`, don't decrement on return, don't consult the soft cap. | [steady-state.md step C — Soft collision](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) |
| Section-aware lockfile-collision check (`lockfile_sections` claim-and-check) | No peer slots and no contention on any lockfile section — the check always resolves to "no collision." The scope pre-flight still returns `lockfile_sections` in its ready shape so the session-state schema remains valid, but the orchestrator ignores the field at dispatch time. | [steady-state.md step C — Section-aware lockfile rule](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) |
| Rolling scope-refill background burst (step D's `2 × concurrency` background scope agents) | The just-in-time per-dispatch scope call (above) is the C=1 equivalent. `scope_bg_count` stays `0` and the per-dispatch JIT call is synchronous. | [step 6 C=1 note](06-scope-preflight.md#6-initial-scope-pre-flight) (see also the in-state struct ref at [`scope_bg_count`](../../do-work.md#orchestrator-state)) |

### What stays at C=1

These steps are **not** gated by concurrency — they fire identically at C=1 and C≥2:

- **Worktree relocation (step 0.5).** The orchestrator runs in its own isolated worktree at every concurrency level. This is the lock against `/do-work` running concurrently in the user's primary checkout (the threat the [worktree-isolation contract](../dont.md) names), and the safety property is independent of how many workers the orchestrator dispatches.
- **Config opt-in check (step 0.4).** The merged 4-layer config is read once at session start regardless of concurrency — defaults / pricing / model overrides / auto-merge policy all apply at C=1 too.
- **Session-state init (step 0.45, moved pre-relocation — [#1202](https://github.com/mattsears18/shipyard/issues/1202)) + every write-through.** The session-state JSON file is the durable record that [`/shipyard:status`](../../status.md), the orphan session-file sweep, the cost-tracking comments, and a future `--resume <session-id>` flag all read from. The mirror fires whether the session has one slot or four.
- **Trusted-author allowlist (step 1.7) + bucket 0.5 + step 4 client-side filter.** Author trust is the security gate against prompt-injection from stranger-authored issues. It fires before dispatch at every concurrency level; lowering it for "single-trusted-author personal repo" sessions would defeat the defense-in-depth posture documented in [`dont.md`'s security boundary](../dont.md).
- **Pre-relocation synchronous sweep ([step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202)).** The orphan orchestrator-worktree sweep (1.6.5), the stale agent-worktree reap (3b), and the orphan `do-work/*` branch triage (3c) — every sweep that performs a cross-worktree `git -C <other-worktree>` operation — now runs synchronously BEFORE `EnterWorktree` (step 0.5), at every concurrency level, per [#1202](https://github.com/mattsears18/shipyard/issues/1202). See step 0.45 for why: post-relocation, the worktree-isolation guard refuses exactly these operations.
- **Background cleanup group (the `(...) &` subshell in step 0.7).** Now carries only the two sweeps that touch no worktree paths — the orphan session-*file* sweep (1.6) and label create (3a) — running in a single background subshell at every concurrency level. Skipping them at C=1 would mean orphan session files from earlier C=1 crashes accumulate forever (issue [#280](https://github.com/mattsears18/shipyard/issues/280)).
- **Per-step setup-timing brackets** (`setup-timing.sh start` / `end` calls in steps 0.5, 1.7, 3.5, 4, 6). These are the data source for the [#258](https://github.com/mattsears18/shipyard/issues/258) measurement umbrella and the cross-session perf ledger — kept at every level. The only `setup-timing` call that's skipped at C=1 is the `step_0_7_parallel_batch` window itself (there's nothing to time when the batch doesn't run).
- **Backlog fetch + rank + triage (step 4), divert checks (step 4.5).** The dispatch queues still need to exist and stay current at C=1; only the parallel coordination over the *fill* changes.
- **Drain + cleanup + end-of-session summary.** Drain semantics are identical at C=1 — the per-poll merge-train watcher, the fix-rebase dispatch for `D_dirty`, the progress-based exit + `max_drain_hours` ceiling, the end-of-session HTML report — all apply unchanged.

### When the inline-trivial fast path **also** fires (orthogonal to C=1)

The C=1 path above is about *what the orchestrator does for any candidate at C=1*. The [inline-trivial fast path](../inline-trivial.md) is a **separate, orthogonal** dispatch-time optimization that fires for *some candidates* (typos, dep-bumps, doc-only, comment-only, config-tweak — pattern-matched) when `inline_trivial.enabled == true` in config. Inline-trivial works at every concurrency level, requires opt-in via config (default OFF), and is **conservative-by-default** with strict eligibility rules (body ≤ 200 chars, no headings, no long code fences, no disqualifying labels, trusted author). Don't confuse the two: C=1 is "the orchestrator runs sequentially with no parallel-coordination overhead"; inline-trivial is "for this specific candidate, the orchestrator runs the work inline instead of dispatching a worker." A session can be C=1 with inline-trivial off (the default), C=1 with inline-trivial on, C≥2 with inline-trivial off, or C≥2 with inline-trivial on — every combination is valid and the two optimizations stack.

### When to pick C=1 vs C≥2

C=1 is the default and the right choice for most personal-repo backlogs because the dominant failure mode is the manifest / version-row hard collision documented in the [thin entry's `--concurrency` flag docs](../../do-work.md#args). Pick `--concurrency 2+` only when realized parallelism is genuinely real — a feature-development backlog against a service with no per-PR version bump, where two workers can land truly independent changes simultaneously without colliding on `package.json` or `CHANGELOG.md`. The [#268](https://github.com/mattsears18/shipyard/issues/268) dogfooding rationale walks through the empirical observation that drove the default.

## Setup (run once)

### 0.3 `CLAUDE_PLUGIN_ROOT` re-export preamble (every Bash-tool call)

**The harness does not propagate `$CLAUDE_PLUGIN_ROOT` into the Bash-tool subprocess shells.** Verified deterministically against this repo as `do-work-20260525T142439Z-64308` ([#354](https://github.com/mattsears18/shipyard/issues/354)): the env var that's documented as the canonical "where is the installed plugin" pointer expands to the **empty string** inside every Bash-tool call. The very first templated invocation of `/shipyard:do-work` — step 0.4's `"$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" exists` — therefore evaluates as `/scripts/shipyard-config.sh` and exits 127 (`no such file or directory`). Every subsequent script invocation in setup / steady-state / drain / cleanup-summary / inline-trivial would fail the same way.

This is the same class of harness-env friction as [#322](https://github.com/mattsears18/shipyard/issues/322) (`$WORKTREE_PATH` not persisting across Bash tool calls): each Bash tool call is hermetic — variables you set in call N are NOT visible in call N+1, and `export` in call N does not persist. Setting the env var once at session start doesn't help.

**The fix is an idempotent preamble at the top of every Bash snippet that references `$CLAUDE_PLUGIN_ROOT/scripts/...`:**

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
```

Semantics:

- **When the harness DOES set `$CLAUDE_PLUGIN_ROOT`** (slash-command launch contexts, future harness fixes, manual `export` for testing) — the `${VAR:-default}` short-circuits and the export is a no-op. Subsequent `$CLAUDE_PLUGIN_ROOT/scripts/...` calls resolve to the harness-provided installed-plugin path.
- **When the harness does NOT set it** (the observed steady-state for every Bash-tool call inside this orchestrator) — the fallback **probes two install layouts in order** before defaulting:
  1. **Repo-local** (`<repo>/plugins/shipyard`) — but only when that path actually carries a `scripts/` subdir. This is the dogfooding case: shipyard's own checkout (or a worktree of it) runs the spec from the same repo it's orchestrating against, so the repo-local plugin source IS the tree to execute. The `-d "$R/plugins/shipyard/scripts"` guard is load-bearing — it's what lets the probe *fall through* on a consumer repo instead of resolving to a non-existent path. **Kept unconditionally** (issue [#883](https://github.com/mattsears18/shipyard/issues/883)) — [#907](https://github.com/mattsears18/shipyard/issues/907) is the governing decision on whether this layer survives, and it kept it (adding a staleness *warning*, not removing the layer), so dropping it here would contradict that decision.
  2. **Authoritative installed path** (`installPath` for `shipyard@shipyard` in `$HOME/.claude/plugins/installed_plugins.json`) — the consumer-install case, done *correctly* ([#681](https://github.com/mattsears18/shipyard/issues/681)). `installed_plugins.json` records the exact directory of the loaded install (under `cache/<marketplace>/<plugin>/<version>/`), and it resolves identically for the maintainer's own dogfooding-adjacent installs and for any marketplace consumer — it isn't a special case. Guarded by `-d "$I/scripts"` so a malformed/partial entry falls through to the final default rather than being trusted blindly. **This layer alone replaces the former layers 2+3** (issue [#883](https://github.com/mattsears18/shipyard/issues/883) — see the collapse rationale below).
  3. **Repo-local anyway** (the final `else echo "$R/plugins/shipyard"` branch) — when neither layer above resolves, fall back to the repo-local path so error messages name a meaningful (if missing) location rather than the empty string.

**Collapsed from four layers to two ([#883](https://github.com/mattsears18/shipyard/issues/883)).** The preamble used to also glob `$HOME/.claude/plugins/marketplaces/*/plugins/shipyard` as a third layer, hardened against a shadowing `.bak` sibling and a version-mismatched marketplace checkout ([#681](https://github.com/mattsears18/shipyard/issues/681), [#417](https://github.com/mattsears18/shipyard/issues/417)) — that layer only ever mattered when `installed_plugins.json` was unreadable or missing the `shipyard@shipyard` entry. In practice `installed_plugins.json` is populated by the harness's own plugin manager for every install method (marketplace-add-then-install, dev-linked, or otherwise) — verified directly against this maintainer's own install (`installed_plugins.json`'s `installPath` resolves to the loaded `cache/shipyard/shipyard/<version>/` directory with a real `scripts/` subdir) before this collapse landed, per the [#883 decision comment](https://github.com/mattsears18/shipyard/issues/883)'s explicit "verify layer 2 resolves across install methods before deleting layer 3" instruction. Removing the marketplace-glob layer drops ~350 bytes per occurrence (~696 → ~345 for the fallback-only bytes, ~403 total with the surrounding guards) while keeping the one layer (`installed_plugins.json`) that's both authoritative and universal. The residual risk — `installed_plugins.json` itself missing or corrupted — degrades to the repo-local-anyway fallback (a meaningful, if likely-missing, error path) rather than a silent wrong pick; this is the same fail-safe posture the old layer 4 already had, just reached one layer sooner.

**Helper-script extraction was proposed and rejected — do not re-propose it.** [#883](https://github.com/mattsears18/shipyard/issues/883) was originally scoped as "ship `scripts/resolve-plugin-root.sh`, replace each of the 66 inlined copies with a 2-line `source` call." A scoping pass rejected this: every occurrence of this preamble is an ad-hoc Bash-tool block executed in a **fresh, hermetic subshell** — nothing persists between calls (the same constraint this section's opening paragraph documents, citing [#354](https://github.com/mattsears18/shipyard/issues/354)). To `source "$CLAUDE_PLUGIN_ROOT/scripts/resolve-plugin-root.sh"`, a block must first *locate* that script — which requires the identical repo-local/installed-path probe the helper was meant to replace. The circularity is the general case, not a corner case: there is no shortcut that lets a fresh subshell find a helper script without re-deriving `$CLAUDE_PLUGIN_ROOT` first. A resolve-once-and-cache-to-disk scheme would sidestep the circularity but is a materially different, higher-risk design (cross-session and concurrent-worker cache collisions, invalidation) that doesn't help a freshly-dispatched worker's first call — the scoped fix here is shrinking the inlined form in place, not extracting it.

**Echo the resolved value once, at this step ([#681](https://github.com/mattsears18/shipyard/issues/681)).** The variable is load-bearing for the whole session — every `$CLAUDE_PLUGIN_ROOT/scripts/*.sh` call routes through it — yet it resolves *invisibly*, so a fallback that picked the wrong directory (a stale `.bak` copy, a version-mismatched marketplace checkout) is undetectable from the session log. The first real usage (step 0.4) therefore prints the resolved path to stderr immediately after the preamble: `echo "resolved CLAUDE_PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT" >&2`. One line, once — enough for an operator (or a later reader of the transcript) to confirm the session ran against the intended install. Do NOT repeat the echo in every block; the one at step 0.4 covers the session.

**Defense in depth — the helpers also self-locate.** Every script under `plugins/shipyard/scripts/*.sh` resolves sibling-script paths via `BASH_SOURCE[0]`, not via `$CLAUDE_PLUGIN_ROOT`. The preamble only fixes layer 1 (how the orchestrator *invokes* a script); layer 2 (how a script finds its peers) was already correct. Together the two layers mean a templated invocation works regardless of how the harness configures (or fails to configure) the env var.

**Spell the variable UNBRACED at every invocation site — `"$CLAUDE_PLUGIN_ROOT/scripts/foo.sh"`, never the braced `"${VAR}/..."` form ([#1308](https://github.com/mattsears18/shipyard/issues/1308)).** A braced expansion is refused outright by the worktree-isolation guard in any isolated session, and **the braces are the trigger** — not statement count, loop/pipe shape, block length, or command position. **[`bash-refusal-triggers.md`](../bash-refusal-triggers.md) owns the full rule**, the experiment isolating it, and the companion `$(cmd)`-in-argument-position trigger. Enforced by [`claude-plugin-root-preamble.test.sh`](../../../scripts/tests/claude-plugin-root-preamble.test.sh) checks (3b)/(3c).

**This compound preamble is PRE-RELOCATION ONLY** ([#1181](https://github.com/mattsears18/shipyard/issues/1181)) — steps 0.3, 0.4, and the pre-`EnterWorktree` timing bracket atop [step 0.5](#05-move-into-the-orchestrators-worktree) are the only orchestrator blocks that still carry it, since those run before isolation. The identical one-liner is **refused** post-isolation, for the precise reason #1308 isolated: a `${VAR:-default}` modifier expansion has no unbraced spelling, so this one preamble cannot be de-braced the way every invocation site above was — hence the stash below. **Every other orchestrator-phase block** — step 0.5's post-relocation resolution onward, here and in `steady-state.md` / `drain.md` / `cleanup-summary.md` / `inline-trivial.md` / `dispatch-rules.md` / the rest of `setup/` — instead reads the `.shipyard-plugin-root` stash step 0.5 writes, via `CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null); export CLAUDE_PLUGIN_ROOT`. Worker-side files (`agents/issue-worker/*.md`, `skills/worker-preamble/*.md`) keep the compound form unconditionally — a dispatched worker's own `agent-*` worktree has no such stash, and gets the resolved literal via its dispatch prompt instead ([#965](https://github.com/mattsears18/shipyard/issues/965)). Regression-guarded by [`scripts/tests/claude-plugin-root-preamble.test.sh`](../../../scripts/tests/claude-plugin-root-preamble.test.sh) (accepts either form per file scope). **This callout was scoped to the `CLAUDE_PLUGIN_ROOT` preamble specifically — see [`dont.md`'s general post-relocation compound-block rule](../dont.md#post-relocation-bash-blocks-must-be-plain-single-purpose-commands-1277) ([#1277](https://github.com/mattsears18/shipyard/issues/1277)) for the same "decompose, don't re-run the compound form" principle applied to every OTHER post-relocation multi-statement block (loops, pipes, `if`/`case` wrappers), plus the decompose-vs-extract-to-a-script decision rule and the regression scanner.**

### 0.4 Check the repo-level opt-in (`shipyard.config.json`)

**Run this BEFORE the worktree relocation.** The check is a single `shipyard-config.sh exists` call against the user's primary checkout — read-only, no writes, so the worktree-isolation rule doesn't apply yet.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
# Echo the resolved value once (#681): it's load-bearing for the whole session
# yet resolves invisibly, so a wrong pick (stale .bak, version-mismatched
# marketplace checkout) would otherwise be undetectable from the log.
echo "resolved CLAUDE_PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT" >&2

# Record the resolved plugin root's own commit, when it's a git-tracked
# checkout (issue #907) — "which version of the spec ran?" is otherwise
# unanswerable after the fact. A no-op ("unknown") for a non-git install
# layout; never a hard failure.
SHIPYARD_PLUGIN_ROOT_SHA=$(git -C "$CLAUDE_PLUGIN_ROOT" rev-parse --short HEAD 2>/dev/null)
[ -z "$SHIPYARD_PLUGIN_ROOT_SHA" ] && SHIPYARD_PLUGIN_ROOT_SHA="unknown"
echo "resolved CLAUDE_PLUGIN_ROOT commit=$SHIPYARD_PLUGIN_ROOT_SHA" >&2

cd "$(git rev-parse --show-toplevel)"

# Capture the PRIMARY checkout's own root now, while cwd is still there
# (issue #1059). Step 0.5 relocates the session into a fresh orchestrator
# worktree checked out from origin/<default-branch> — which, by construction,
# cannot contain gitignored files like .shipyard/config.local.json. Echoing
# (not just computing) this path is what lets it survive as a literal value
# the orchestrator carries into step 0.5's SHIPYARD_REPO_ROOT pin, the same
# way the CLAUDE_PLUGIN_ROOT resolution above is echoed once and reused as a
# literal rather than a shell variable that can't survive the next Bash call.
SHIPYARD_PRIMARY_CHECKOUT_ROOT="$(pwd)"
echo "resolved SHIPYARD_PRIMARY_CHECKOUT_ROOT=$SHIPYARD_PRIMARY_CHECKOUT_ROOT" >&2

# Dogfooding staleness check (issue #907): when CLAUDE_PLUGIN_ROOT resolved
# REPO-LOCAL (layer 1 above — this repo IS the plugin source, the
# do-work-orchestrating-shipyard's-own-repo case), the resolved copy is
# whatever commit the PRIMARY checkout happens to sit at — which can be
# arbitrarily far behind origin/<default-branch>, with nothing else in the
# session surfacing that. The repro this closes: a session read a
# 49-commit-stale copy of dispatch-rules.md for its entire run (including a
# filed issue asserting a spec claim) with no warning anywhere. This check
# does NOT apply to a consumer install (layers 2-4) — there, CLAUDE_PLUGIN_ROOT
# points at a distinct installed/marketplace checkout with its own update
# cadence (`/shipyard:update`), not this repo's own history.
if [ "$CLAUDE_PLUGIN_ROOT" = "$(pwd)/plugins/shipyard" ]; then
  STALENESS_DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
  if [ -n "$STALENESS_DEFAULT_BRANCH" ]; then
    git fetch origin "$STALENESS_DEFAULT_BRANCH" --quiet 2>/dev/null || true
    SHIPYARD_PLUGIN_ROOT_BEHIND=$(git rev-list --count "HEAD..origin/$STALENESS_DEFAULT_BRANCH" 2>/dev/null)
    if [ -n "$SHIPYARD_PLUGIN_ROOT_BEHIND" ] && [ "$SHIPYARD_PLUGIN_ROOT_BEHIND" -gt 0 ] 2>/dev/null; then
      SHIPYARD_PLUGIN_ROOT_STALE="$SHIPYARD_PLUGIN_ROOT_BEHIND commit(s) behind origin/$STALENESS_DEFAULT_BRANCH (primary checkout at $SHIPYARD_PLUGIN_ROOT_SHA)"
      cat <<EOF >&2
warning: this repo's primary checkout is $SHIPYARD_PLUGIN_ROOT_BEHIND commit(s) behind origin/$STALENESS_DEFAULT_BRANCH.

  CLAUDE_PLUGIN_ROOT resolved repo-local to commit $SHIPYARD_PLUGIN_ROOT_SHA.
  Every spec file read this session is that stale copy, now INVALIDATED
  (#907; step 0.6 re-reads it, #1191). Run 'git pull --ff-only'. Step 0.5
  re-resolves CLAUDE_PLUGIN_ROOT and runs its own staleness assertion
  (#1167) — 0.3/0.4 only.
EOF
    fi
  fi
fi

"$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" exists
case $? in
  0)
    # Repo is shipyard-initialized — load the merged config so subsequent
    # steps can read tunables like trust.authors, auto_merge.policy, etc.
    #
    # `load` can itself fail: a `shipyard.config.json` (or
    # `.shipyard/config.local.json`) that's present but schema-invalid makes
    # `load` exit non-zero (70 = schema validation failed; 65 = internal
    # helper failure) with EMPTY stdout. Capturing stdout alone would set
    # `EFFECTIVE_CONFIG=""` and every downstream `shipyard-config.sh get`
    # would silently fall back to built-in defaults — the user's per-repo
    # trust list / auto-merge policy / cost-tracking knobs all ignored for
    # the rest of the session with NO warning (issue #367). Capture the exit
    # code and stderr, and surface a loud warning on failure.
    CONFIG_LOAD_STDERR=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" load 2>&1 1>/tmp/shipyard-effective-config.$$)
    CONFIG_LOAD_RC=$?
    if [ "$CONFIG_LOAD_RC" -eq 0 ]; then
      EFFECTIVE_CONFIG=$(cat /tmp/shipyard-effective-config.$$)
    else
      # Schema-invalid (or otherwise unloadable) config. Fall back to
      # built-in defaults — but LOUDLY, and record the failure so the
      # end-of-session summary surfaces it (the silent-degrade is the
      # actual bug #367 flags as more important than the regex breadth).
      EFFECTIVE_CONFIG=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" load 2>/dev/null < /dev/null) || EFFECTIVE_CONFIG=""
      # The loader's stderr already names each rejected field on its own
      # indented line (e.g. `  .auto_merge.policy: value bogus not in
      # enum [...]`). Extract just those lines and `; `-join them. POSIX
      # `[[:space:]]` (not `\s`) so the grep matches on BSD grep too; awk
      # for the join (NOT `paste -d '; '` — `paste`'s -d is a cycled list
      # of single-char delimiters, so '; ' would alternate `;` then ` `).
      REJECTED_FIELDS=$(printf '%s\n' "$CONFIG_LOAD_STDERR" \
        | grep -E '^[[:space:]]+\.' \
        | sed 's/^[[:space:]]*//' \
        | awk 'NR>1{printf "; "} {printf "%s", $0} END{if (NR>0) print ""}')
      [ -z "$REJECTED_FIELDS" ] && REJECTED_FIELDS="(loader exit $CONFIG_LOAD_RC; see stderr above)"
      cat <<EOF
warning: shipyard.config.json failed schema validation (loader exit $CONFIG_LOAD_RC).

  Rejected: $REJECTED_FIELDS

  Your per-repo config is NOT being applied — every config read this session
  (trust.authors, auto_merge.policy, cost_tracking.*, ci.*, etc.) falls back
  to built-in defaults. Fix the rejected field(s) and re-run, or run
  /shipyard:config validate to see the full report.
EOF
      # Note: EFFECTIVE_CONFIG above re-runs `load` to recover the merged
      # defaults+user layers; on a hard schema failure in the repo/local
      # layer that re-run also exits non-zero, leaving EFFECTIVE_CONFIG="".
      # Downstream `shipyard-config.sh get` calls each independently fall
      # back to defaults, so an empty EFFECTIVE_CONFIG is safe (not
      # load-bearing) — but the warning above is the user-facing signal.
      SHIPYARD_CONFIG_SCHEMA_FAILURE="$REJECTED_FIELDS"
    fi
    rm -f /tmp/shipyard-effective-config.$$ ;;
  1)
    # Repo is NOT shipyard-initialized. Warn loudly and continue with
    # built-in defaults — but record the unconfigured state so the
    # end-of-session summary surfaces it for the user. The hard refusal
    # gate ships in a later release once /shipyard:init is widely used
    # (issue #165's risk-mitigation section explicitly defers it).
    cat <<'EOF'
warning: this repo is not shipyard-initialized.

  No shipyard.config.json found at the repo root. Running with built-in
  defaults — auto_merge.policy=trusted-only, no per-repo trust list, etc.

  To opt in (recommended for shared / team repos):
    /shipyard:init

  To suppress this warning, run with --no-config (built-in defaults only).
  A future release will refuse to dispatch without shipyard.config.json
  unless --force is passed.
EOF
    EFFECTIVE_CONFIG=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" load)
    SHIPYARD_UNCONFIGURED=1 ;;
esac
```

`EFFECTIVE_CONFIG` is the merged result of all layers (defaults < user-global < repo < local). Subsequent steps that previously hardcoded a value should now read it via `jq` from `$EFFECTIVE_CONFIG` or via a fresh `shipyard-config.sh get <path>` call. The migration of hardcoded values is incremental — this PR introduces the loader; downstream issues (#156, #157, #160, #163) will swap each hardcoded value for a config read.

**The `exists == 0` but `load` fails branch ([#367](https://github.com/mattsears18/shipyard/issues/367)).** A repo can be shipyard-initialized (`exists` returns 0) yet have a `shipyard.config.json` that fails schema validation — a typo'd enum value, an unknown top-level key, a missing required field. Before #367 the `case 0)` branch captured `load`'s stdout unconditionally; on a schema failure stdout is empty and the exit code (70) was discarded, so `EFFECTIVE_CONFIG` silently became `""` and every downstream `shipyard-config.sh get` fell back to built-in defaults with no warning — the user's per-repo trust list, auto-merge policy, and cost-tracking knobs all quietly ignored for the entire session. The branch above now captures the loader's exit code and stderr, prints a **loud one-line warning naming the rejected field(s)** plus which config keys are defaulting as a result, and records the failure detail in the session-local `SHIPYARD_CONFIG_SCHEMA_FAILURE` variable so the [end-of-session summary](../cleanup-summary.md#end-of-session-summary) surfaces the same line. The fall-through to defaults is unchanged (still conservative-by-design — `auto_merge.policy=trusted-only`, trust resolution via the live collaborators API); the only behavioral change is that the degrade is now *visible* at both step 0.4 and end-of-session.

`SHIPYARD_CONFIG_SCHEMA_FAILURE` is session-local working memory (like `SHIPYARD_UNCONFIGURED`) — not mirrored to the session-state file. It's set only on the schema-failure path; when unset, the end-of-session summary omits the `Config:` line entirely (silence is the right default for a clean config load). Treat the two as mutually-exclusive-ish in practice: `SHIPYARD_UNCONFIGURED=1` means no `shipyard.config.json` at all, while `SHIPYARD_CONFIG_SCHEMA_FAILURE` means one is present but invalid.

**`SHIPYARD_PLUGIN_ROOT_SHA` and `SHIPYARD_PLUGIN_ROOT_STALE` ([#907](https://github.com/mattsears18/shipyard/issues/907)).** Session-local working memory variables (not mirrored to session-state file). `SHIPYARD_PLUGIN_ROOT_SHA` records the short commit sha the resolved `CLAUDE_PLUGIN_ROOT` sits at. `SHIPYARD_PLUGIN_ROOT_STALE` is set in the dogfooding case when the primary checkout is behind `origin/<default-branch>`. Issue [#1167](https://github.com/mattsears18/shipyard/issues/1167) found post-relocation worktrees landing stale despite `baseRef: fresh`, so step 0.5 now runs an explicit [post-relocation staleness assertion](#05-move-into-the-orchestrators-worktree).

**`.shipyard-plugin-root-version` stash ([#1304](https://github.com/mattsears18/shipyard/issues/1304)).** Step 0.5 also writes the resolved `CLAUDE_PLUGIN_ROOT`'s own `.claude-plugin/plugin.json` `.version` to `.shipyard-plugin-root-version` in the orchestrator worktree — a start-of-session snapshot for [cleanup-summary.md's end-of-session drift check](../cleanup-summary.md#end-of-session-summary) to diff against a fresh re-resolution, surfacing a mid-session plugin update (the harness's own plugin manager can silently bump the installed version while a session is live) instead of leaving it invisible for the rest of the run.

Flags interpreted here:

- `--force` / `--no-config` — skip the warn and continue with built-in defaults. Equivalent for now; once the hard-refusal gate ships, `--force` will be the explicit "I know this repo is unconfigured" opt-out.
- `--strict` — refuse to dispatch if `shipyard.config.json` is missing. Early-adopter opt-in for the future-default behavior.

```bash
case "${1:-}" in
  --strict)
    if [ "$SHIPYARD_UNCONFIGURED" = "1" ]; then
      echo "/shipyard:do-work --strict: shipyard.config.json is required"
      echo "  run /shipyard:init to bootstrap, or drop --strict to fall back to defaults"
      exit 1
    fi ;;
  --no-config|--force) : ;;  # already handled above
esac
```

### 0.45 Pre-relocation: session-state init + the worktree-cross-referencing sweeps ([#1202](https://github.com/mattsears18/shipyard/issues/1202))

**Run this BEFORE `EnterWorktree` (step 0.5 below) — while cwd is still the primary checkout and the harness's worktree-isolation guard has not yet activated for this session.** Load [`00e-pre-relocation-sweeps.md`](./00e-pre-relocation-sweeps.md) now — it owns the full step: session-state init (steps 1 / 1.3 / 1.36 / 1.5, moved here from `01-repo-recovery.md`) plus the three worktree-cross-referencing sweeps (1.6.5 / 3b / 3c) that perform `git -C <other-worktree>` operations the isolation guard refuses once step 0.5 below has run. See that file for the full rationale ([#1202](https://github.com/mattsears18/shipyard/issues/1202)) and the exact command sequence.

### 0.5 Move into the orchestrator's worktree

**Before any other setup, the orchestrator MUST relocate every write into a dedicated worktree.** The user's primary checkout is strictly read-only for the rest of the session. The hard rule: every *write* (`Edit`, `Write`, `git commit`, `git reset`, `git branch <new>`, label setup, README/CHANGELOG/CLAUDE.md tweaks, `plugin.json` version bumps, etc.) goes through the orchestrator worktree. Read-only operations (`git status`, `gh issue list`, `gh pr view`, `find`, `grep`, `git worktree list`, `gh run list`, label-existence checks via `gh label list`, etc.) MAY run in either checkout.

**By the time this step runs, [step 0.45](00e-pre-relocation-sweeps.md#045-pre-relocation-session-state-init--the-worktree-cross-referencing-sweeps-1202) has already resolved repo/concurrency, initialized session-state, and run the orphan-orchestrator-worktree / stale-agent-worktree / orphan-branch sweeps — all while cwd was still this primary checkout.** That ordering is deliberate and load-bearing, not incidental: this step's `EnterWorktree` call is exactly what activates the guard those sweeps cannot run under (see 0.45's rationale for the full conflict, in [`00e-pre-relocation-sweeps.md`](./00e-pre-relocation-sweeps.md)). Don't reorder 0.45 to run after this step "for tidiness" — doing so silently reintroduces the [#1202](https://github.com/mattsears18/shipyard/issues/1202) regression (#844's isolation fix disabling #280's orphan-worktree reclamation).

**Primary path — call `EnterWorktree`, not raw `git worktree add` ([#844](https://github.com/mattsears18/shipyard/issues/844)).** A raw `git worktree add "$ORCH_WT" "origin/$DEFAULT_BRANCH"` plus a `cd`/`-C "$ORCH_WT"` convention satisfies `Bash` — the shell genuinely operates inside the new directory — but it does **not** register the session as isolated with the harness. When `/shipyard:do-work` runs as a **background job**, the harness's write guard gates every `Edit`/`Write` call on the session having isolated via the `EnterWorktree` tool specifically; a raw `git worktree add` never flips that flag. The result is that every subsequent `Edit`/`Write` in the orchestrator's own session gets refused — including this repo's own per-PR release bump to `plugin.json` and the matching `CHANGELOG.md` entry — and the failure surfaces late, at the first `Edit` call, only *after* the rest of setup has already run. **This rationale is load-bearing — without it, a future editor will "simplify" this back to raw git and reintroduce the bug.** This is the **orchestrator-side** instance of the harness-isolation gap [#825](https://github.com/mattsears18/shipyard/issues/825) documented on the **worker** side (fixed there by dispatching workers with `Agent`-tool `isolation: "worktree"`, restored as the default dispatch shape in [#830](https://github.com/mattsears18/shipyard/issues/830)) — the orchestrator has no dispatcher to hand isolation to, so it has to call the isolating tool itself.

**Timing instrumentation (issue #238).** Bracket this step with `setup-timing.sh start` / `end` calls. Both are fire-and-forget (`2>/dev/null || true`) — never let a timing failure abort setup.

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_0_5_worktree 2>/dev/null || true
```

Create (or reuse) the orchestrator's worktree under `.claude/worktrees/orchestrator-<session-id>` from the tip of the default branch. `<session-id>` is the current Claude Code session identifier — stable across the run, distinct from each dispatched agent's `<id>`.

**New worktree — fetch first, then call the `EnterWorktree` tool directly (not `Bash`).** Fetching before the tool call keeps `origin/<default-branch>` current ([#1167](https://github.com/mattsears18/shipyard/issues/1167); see also the post-relocation assertion below):

```bash
DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
git fetch origin "$DEFAULT_BRANCH"
```

- `EnterWorktree` with `name: "orchestrator-<session-id>"`.
- The tool's default `worktree.baseRef` setting (`fresh`) branches from `origin/<default-branch>` — the same tip-of-default-branch starting point the raw-git form below targets, so no extra configuration is needed for the common case.

**Reusing an existing worktree** (a prior session already created `.claude/worktrees/orchestrator-<session-id>` under this exact session id — the resume/retry case): `EnterWorktree` with `path: ".claude/worktrees/orchestrator-<session-id>"` — the tool's documented path-entry form for switching into a worktree that already exists, rather than creating a second one. `EnterWorktree` only relocates the session into the directory; it does not refresh stale content, so immediately after entering, still fetch and hard-reset to origin's tip exactly as the fallback form below does:

```bash
DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
git fetch origin "$DEFAULT_BRANCH"
git checkout "$DEFAULT_BRANCH"
git reset --hard "origin/$DEFAULT_BRANCH"
```

Both `EnterWorktree` forms resolve to the same path, `.claude/worktrees/orchestrator-<session-id>`, so every downstream consumer that keys off that path is unaffected by which mechanism created it — `session-identity.sh derive-session-id`'s newest-by-mtime `orchestrator-*` glob ([#513](https://github.com/mattsears18/shipyard/issues/513)), the [step-1.6.5 orphan-orchestrator sweep](01-repo-recovery.md#165-reap-orphan-orchestrator-worktrees) ([#280](https://github.com/mattsears18/shipyard/issues/280)), the [`.shipyard-session-id` stash convention](00f-session-id-storage.md#055-session-id-storage-per-worktree-not-tmp) ([#365](https://github.com/mattsears18/shipyard/issues/365)), and [cleanup-summary's step-6 reap](../cleanup-summary.md#end-of-session-cleanup) of the orchestrator's own worktree all still resolve correctly.

**One deliberate behavioral difference — branch, not detached HEAD.** `EnterWorktree` creates the new worktree **on a branch** (`worktree-orchestrator-<session-id>`), whereas the raw-git fallback below produces a **detached HEAD**. Call this out explicitly rather than let it be an accident of mechanism: the branch is harmless for how the orchestrator actually uses the worktree (every write still lands as an explicit commit the orchestrator controls) and is arguably an improvement — the orchestrator has a branch to commit to if it ever needs one. This file adopts the branch as the documented default rather than fighting the tool's shape; a reader relying on the orchestrator worktree being detached (it never was, under this primary path) should update that assumption.

**If `EnterWorktree` errored rather than simply not existing, don't drop straight to the fallback below.** A repo-level `WorktreeCreate` hook rejecting the harness's payload is the most common cause, and it has its own recovery that preserves harness isolation — which the raw-git-only fallback below does not. Read [`00c-worktree-recovery.md`](./00c-worktree-recovery.md) first ([#1066](https://github.com/mattsears18/shipyard/issues/1066)).

**Last-resort fallback — raw `git worktree add`, for environments where `EnterWorktree` is genuinely unavailable, or where the fragment's recovery above also failed.** Not every invocation shape has the tool (e.g. an older Claude Code build, or a harness variant that only exposes `Bash`). This form satisfies `Bash`'s cwd but, per the rationale above, does **not** register isolation with the harness — on a background-job session, expect `Edit`/`Write` calls to be refused after using this path:

```bash
# Run this once from the user's primary checkout (the only write to .git/worktrees/ that the primary will see this session)
cd "$(git rev-parse --show-toplevel)"   # be robust to subdir invocation
ORCH_WT=".claude/worktrees/orchestrator-<session-id>"
DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)

# If a prior session left this exact path around, reuse it after refreshing to origin's tip.
if [ -d "$ORCH_WT" ] && git worktree list --porcelain | grep -q "^worktree $(pwd)/$ORCH_WT$"; then
  git -C "$ORCH_WT" fetch origin "$DEFAULT_BRANCH"
  git -C "$ORCH_WT" checkout "$DEFAULT_BRANCH"
  git -C "$ORCH_WT" reset --hard "origin/$DEFAULT_BRANCH"
else
  git fetch origin "$DEFAULT_BRANCH"
  git worktree add "$ORCH_WT" "origin/$DEFAULT_BRANCH"
fi
```

**From this point on, every subsequent `Bash` / `Edit` / `Write` tool call in the orchestrator's session runs with `<repo-root>/.claude/worktrees/orchestrator-<session-id>` as cwd.** Under the primary `EnterWorktree` path this is automatic — the tool relocates the session's cwd as part of entering. Under the raw-git fallback, prepend `cd "$ORCH_WT" && ` (or pass `-C "$ORCH_WT"` to git) for any command whose effect lands on disk or on a branch ref. Either way, the user's primary checkout's HEAD MUST NOT change during this session — if you find yourself running a write-class command in the primary checkout, back up, switch to the orchestrator worktree, retry. See [RATIONALE → Why a dedicated worktree](../../do-work-RATIONALE.md#step-05--why-a-dedicated-orchestrator-worktree) for the failure modes this prevents.

**Decompose, don't re-run the compound preamble ([#1181](https://github.com/mattsears18/shipyard/issues/1181)).** Step 0.3's one-liner is pre-relocation-only — refused post-isolation: "too complex to verify that it stays inside the worktree." Resolve via separate plain commands (same shape as `shipyard:worker-preamble`'s [`assert-worktree-cwd-fallback.md`](../../../skills/worker-preamble/assert-worktree-cwd-fallback.md)), then stash the result so later blocks read it back instead of re-resolving:

```bash
git rev-parse --show-toplevel
```

Call the result `TOPLEVEL` (= `$ORCH_WT`). Then:

```bash
test -d "<TOPLEVEL>/plugins/shipyard/scripts"
```

Exit 0 → resolved value `<TOPLEVEL>/plugins/shipyard`. Exit non-zero → run `jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json"` (result `INSTALL_PATH`), then `test -d "<INSTALL_PATH>/scripts"` — exit 0 → `<INSTALL_PATH>`; otherwise → `<TOPLEVEL>/plugins/shipyard`. Same two-layer probe as step 0.3, decomposed.

Stash it, then finish by reading it back (hermetic across calls):

```bash
printf '%s\n' "<resolved CLAUDE_PLUGIN_ROOT literal>" > .shipyard-plugin-root
```

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# Re-echo the resolved value + commit sha (#907) — naturally the
# ORCHESTRATOR WORKTREE's own plugins/shipyard, superseding step 0.4's
# pre-relocation resolution against the primary checkout.
echo "resolved CLAUDE_PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT (post-relocation)" >&2
SHIPYARD_PLUGIN_ROOT_SHA=$(git -C "$CLAUDE_PLUGIN_ROOT" rev-parse --short HEAD 2>/dev/null)
[ -z "$SHIPYARD_PLUGIN_ROOT_SHA" ] && SHIPYARD_PLUGIN_ROOT_SHA="unknown"
echo "resolved CLAUDE_PLUGIN_ROOT commit=$SHIPYARD_PLUGIN_ROOT_SHA (post-relocation)" >&2
# Stash the resolved plugin's own VERSION too (#1304) — the mid-session
# drift signal end-of-session cleanup compares against a fresh re-resolution.
# A consumer install (layer 2) can be silently updated by the harness's own
# plugin manager mid-session, splitting "which spec the worker reads" from
# "which scripts/*.sh it invokes" (both keyed off this same stale stash) with
# no warning anywhere. Never fatal — an unreadable plugin.json degrades to
# "unknown", same posture as SHIPYARD_PLUGIN_ROOT_SHA above.
SHIPYARD_PLUGIN_ROOT_VERSION=$(jq -r '.version // empty' "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
[ -z "$SHIPYARD_PLUGIN_ROOT_VERSION" ] && SHIPYARD_PLUGIN_ROOT_VERSION="unknown"
printf '%s\n' "$SHIPYARD_PLUGIN_ROOT_VERSION" > .shipyard-plugin-root-version
echo "resolved CLAUDE_PLUGIN_ROOT version=$SHIPYARD_PLUGIN_ROOT_VERSION (post-relocation)" >&2
# Close the step_0_5_worktree timing window.
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_0_5_worktree 2>/dev/null || true
```

**Post-relocation staleness assertion ([#1167](https://github.com/mattsears18/shipyard/issues/1167)).** The orchestrator worktree's `baseRef: fresh` setting should branch from `origin/<default-branch>`'s tip, but a session against a repo carrying a `WorktreeCreate` hook found the resulting worktree far behind, with no warning — the orchestrator triaged against stale state. Assert the base explicitly instead of trusting tool semantics silently:

```bash
DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || true
ORCH_WT_BEHIND=$(git rev-list --count "HEAD..origin/$DEFAULT_BRANCH" 2>/dev/null)
if [ -n "$ORCH_WT_BEHIND" ] && [ "$ORCH_WT_BEHIND" -gt 0 ] 2>/dev/null; then
  cat <<EOF >&2
warning: the orchestrator worktree is $ORCH_WT_BEHIND commit(s) behind origin/$DEFAULT_BRANCH (issue #1167).
  Remedy: git fetch origin "$DEFAULT_BRANCH" && git reset --hard "origin/$DEFAULT_BRANCH"
EOF
fi
```

This is a warning, not a hard fail — the orchestrator can still recover per the remedy. This assertion runs at every install layout, unlike step 0.4's dogfooding-only check, because it verifies `EnterWorktree`'s base-ref resolution.

**Prefer the orchestrator worktree for spec reads too, not just bash script invocations ([#907](https://github.com/mattsears18/shipyard/issues/907)).** Once this step has re-resolved `CLAUDE_PLUGIN_ROOT` against the orchestrator worktree, treat **that** path — not the pre-relocation value from [step 0.4](#04-check-the-repo-level-opt-in-shipyardconfigjson) — as the canonical source for any further spec-file read this session. The orchestrator worktree is fresh from `origin/<default-branch>`'s tip (per this step, and verified by the [post-relocation assertion](#05-move-into-the-orchestrators-worktree) above), so spec reads will be current rather than the stale primary-checkout copy.

End-of-session cleanup also runs from the orchestrator worktree, and reaps the orchestrator's own worktree last — see [End-of-session cleanup](../cleanup-summary.md#end-of-session-cleanup) below.

### 0.55 Session-id storage (per-worktree, not /tmp)

**The session id MUST be stashed at `<orch-worktree>/.shipyard-session-id`, NOT at any globally-shared path like `/tmp/shipyard-session-id.txt`.** Closes [#365](https://github.com/mattsears18/shipyard/issues/365). Load [`00f-session-id-storage.md`](./00f-session-id-storage.md) now — it owns the full step: why the stash must be per-worktree (not `/tmp`), the write-then-read-back mechanism, the newest-by-mtime derive helper ([#513](https://github.com/mattsears18/shipyard/issues/513)), and the `session-state.sh` cross-repo write guard.

### 0.56 Pin `SHIPYARD_REPO_ROOT` to the primary checkout ([#1059](https://github.com/mattsears18/shipyard/issues/1059))

**Every config read after step 0.5's relocation silently loses the `.shipyard/config.local.json` layer.** `shipyard-config.sh`'s `repo_root()` resolves via `git rev-parse --show-toplevel` from cwd unless `SHIPYARD_REPO_ROOT` overrides it. [Step 0.4](#04-check-the-repo-level-opt-in-shipyardconfigjson)'s `EFFECTIVE_CONFIG` is unaffected (it runs pre-relocation), but every OTHER config read this session — a fresh `shipyard-config.sh get`, or a helper like `resolve-dispatch-model.sh` / `flake-enforce.sh` — resolves against cwd at call time, which post-relocation is the orchestrator worktree: a fresh `origin/<default-branch>` checkout with no gitignored files. `.shipyard/config.local.json` silently drops out with no warning — and not just for `models.*`: `trust.authors`, `auto_merge.policy`, `concurrency.*`, `cost_tracking.*`, `ci.*`, `flake_registry.*` all revert too.

**Pin it here, reusing step 0.55's fix (#1182)** — `SHIPYARD_PRIMARY_CHECKOUT_ROOT` doesn't survive this call's hermetic boundary; substitute the literal step 0.4 echoed to stderr, worktree-relative:

```bash
printf '%s\n' "<primary-root literal, 0.4>" > .shipyard-primary-root
export SHIPYARD_REPO_ROOT="<primary-root literal, 0.4>"
```

**Every subsequent orchestrator Bash block calling `shipyard-config.sh` (directly or via `resolve-dispatch-model.sh` / `flake-enforce.sh`) should re-derive and export it from the stash** — hermetic Bash-tool calls don't carry shell state forward (see [step 0.3](#03-claude_plugin_root-re-export-preamble-every-bash-tool-call)):

```bash
SHIPYARD_REPO_ROOT=$(cat .shipyard-primary-root 2>/dev/null)
export SHIPYARD_REPO_ROOT
```

**Scope: orchestrator session only — never propagate into a dispatched worker.** `SHIPYARD_REPO_ROOT` redirects the whole repo config layer. A worker's own `agent-*` worktree must resolve its own config against its own cwd; inheriting this pin would silently misdirect it. Never add `SHIPYARD_REPO_ROOT` to a dispatch prompt.

**Originally shipped as a phase-1 slice** — the pin at its origin plus the one known-affected consumer ([step 5.8's flake-registry enforcement](04-backlog-divert.md#58-enforce-the-flake-registry-chronic-flake-escalation)). Every other post-relocation call site across `steady-state.md` / `dispatch-rules.md` — including the per-dispatch model resolution — was swept in the same shape shortly after ([#1064](https://github.com/mattsears18/shipyard/issues/1064)), and `scripts/tests/shipyard-repo-root-preamble.test.sh` now mechanically discovers every `*.md` file under `commands/do-work/` and asserts every bash block calling `shipyard-config.sh` / `resolve-dispatch-model.sh` carries the re-export preamble — a *new* call site is covered automatically the moment it's added, with nothing to remember to extend ([#1105](https://github.com/mattsears18/shipyard/issues/1105)).

**Still-live gap this closed only partially — a per-call-site preamble depends on every live orchestrator session actually running it, every single call.** [#1263](https://github.com/mattsears18/shipyard/issues/1263)'s repro reproduced exactly this: a bare `resolve-dispatch-model.sh fix-checks-only` invocation from the orchestrator worktree, with no re-exported pin, silently fell back to the built-in default rather than the repo's configured override — even though the documented dispatch-site call carries the preamble. Documentation compliance and runtime compliance are different guarantees; a passing regression test on the *spec* doesn't prove every live *session* followed it every time. `scripts/resolve-dispatch-model.sh` now resolves the `.shipyard-primary-root` stash **internally** as a second line of defense (its own `ensure_repo_root_pin()`, run at the top of every subcommand): when `SHIPYARD_REPO_ROOT` is unset, it reads the stash file at cwd's git toplevel itself before falling through to `shipyard-config.sh`'s own default resolution — so a caller of this script (documented or not, preamble-following or not) still resolves `models.<mode>` against the pinned primary checkout. This is safe to apply unconditionally: the stash file only ever exists in the orchestrator's own worktree (a plain `>` redirect at pin time above, never `git add`ed), so a dispatched worker's separate `agent-*` worktree structurally can never pick it up — the "never propagate into a dispatched worker" scope boundary holds without the script needing to know which kind of caller it is. **This fix is scoped to `resolve-dispatch-model.sh` only, not `shipyard-config.sh` itself** — a shared config-repo-root helper would be the more DRY location, but `scripts/shipyard-config.sh` is a contested surface with in-flight sibling PRs at the time of #1263's fix, so the fallback lives in the one script the issue's own repro named rather than the file every config read funnels through; a future consolidation is open territory. The per-call-site preamble above is kept as the documented, explicit path (and the regression test still enforces it) — the internal fallback is redundant-by-design belt-and-suspenders, not a replacement for it.

**Drift warning — defense in depth for un-swept call sites.** Fires only when the primary checkout's local layer exists and changes the merged result (re-derived from stash files, not shell vars — #1182):

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
PINNED_ROOT=$(cat .shipyard-primary-root 2>/dev/null)
if [ -n "$PINNED_ROOT" ] && [ -f "$PINNED_ROOT/.shipyard/config.local.json" ]; then
  UNPINNED_CONFIG=$(SHIPYARD_REPO_ROOT="$(pwd)" "$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" load 2>/dev/null)
  PINNED_CONFIG=$(SHIPYARD_REPO_ROOT="$PINNED_ROOT" "$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" load 2>/dev/null)
  if [ "$UNPINNED_CONFIG" != "$PINNED_CONFIG" ]; then
    echo "warning: .shipyard/config.local.json in the primary checkout changes the effective config (issue #1059). SHIPYARD_REPO_ROOT is pinned for THIS session, but a call site that skips re-exporting it (see above) will still read the un-pinned config. Verify trust/auto-merge/model behavior this session." >&2
  fi
fi
```

### 0.6 Re-read stale spec files (#1191)

No-op unless step 0.4 warned of staleness — then these spec files are invalidated. See [`00d-reread.md`](./00d-reread.md).

### 0.7 Setup parallelization contract (fire-once-batch)

> **Skip the parallel batch when `concurrency == 1` — but keep the background cleanup group.** At C=1 there is only ever one slot — no peer agents to coordinate against and no benefit from pre-populating a pool of more than one candidate. Skip the parallel batch (steps 1 → 5) entirely and run them serially. Step 5's failing-PR snapshot is also deferred (see [Step 5](04-backlog-divert.md#5-snapshot-failing-prs)); step 6's scope pre-flight is just-in-time (see [Step 6](06-scope-preflight.md#6-initial-scope-pre-flight)); step 7 fires exactly one dispatch (see [Step 7](07-pool-fill.md#7-initial-pool-fill)). Steps that are still required at C=1:
>
> - **Foreground**: worktree setup (step 0.5), config check (step 0.4), session-state init (step 1.5), trusted-author allowlist (step 1.7), backlog overview (step 2), refine pass (step 3.5), backlog fetch + rank (step 4), divert checks (step 4.5).
> - **Background cleanup group** (the `(...) &` subshell below — also fires at C=1): orphan session-file sweep (step 1.6), orphan orchestrator-worktree sweep ([step 1.6.5](01-repo-recovery.md#165-reap-orphan-orchestrator-worktrees)), label create (step 3a), agent-worktree reap (step 3b), orphan-branch triage (step 3c). These are independent of dispatch coordination — they're recovery work for state stranded by prior crashed sessions, and skipping them at C=1 would mean orphan files / worktrees from earlier C=1 crashes accumulate forever (issue #280 — the failure mode where a single-slot user's machine accrues unreaped orchestrator worktrees across crash-and-restart cycles).
>
> What IS skipped at C=1 is purely the *parallel coordination* machinery — the `step_0_7_parallel_batch` timing window, the fire-once-batch read burst, the pre-population of a candidate pool. The background group `(...) &` itself still fires; its contents are cleanup and never racing with the (single) dispatch slot. Readers should be able to see this gate as the explicit boundary between "C≥2 parallel setup with read burst" and "C=1 serial setup with read calls" — the cleanup background group is on the same side of the gate in both modes.
>
> **Per-step timing brackets stay required at every concurrency level.** The `setup-timing.sh start` / `end` brackets in steps 0.5, 1.7, 3.5, 4, and 6 are NOT "skip when C=1" — they're the data source for the #258 measurement umbrella and the cross-session perf ledger. The only `setup-timing` call that's skipped at C=1 is the `step_0_7_parallel_batch` window itself (the parallel batch isn't run, so there's nothing to time). Step 6.8's explicit `flush` call also stays required at every concurrency level — though [issue #283](https://github.com/mattsears18/shipyard/issues/283) added auto-flush hooks in `session-state.sh update` and `cost-history.sh flush` as defense in depth, so a forgotten 6.8 no longer silently drops the data.


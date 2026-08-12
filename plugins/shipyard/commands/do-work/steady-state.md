# /shipyard:do-work — Steady state (event-driven)

The dispatch loop. The orchestrator wakes when an agent completes; each notification is one turn with the shape `reconcile → release → dispatch (or prove idle) → invariant line`. Held up by [setup](./setup.md) at startup; hands off to [drain → termination](./drain.md) when the **dispatch** queues empty out. An empty dispatch pool ends this loop but is **not** session completion ([#662](https://github.com/mattsears18/shipyard/issues/662)): the drain then **drives the tail** — every session PR to **merged** (or a confirmed external dependency the agent cannot perform) — and the session is complete only when the drain's [full-completion assertion](./drain.md#termination-assertion) holds.

The thin entry [`commands/do-work.md`](../do-work.md) owns the hot [orchestrator-state struct list](../do-work.md#orchestrator-state) and a pointer to the [session state file](../do-work.md#session-state-file) (cold long-tail detail split into [`orchestrator-state-reference.md`](./orchestrator-state-reference.md) and [`session-state-file.md`](./session-state-file.md)); this file owns the actual steady-state-loop semantics and refresh triggers. The dispatch decision tree consulted by step 7 and step C lives in [`dispatch-rules.md`](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) — load it on demand when filling a slot. The browser-operator hooks live in [`operate/04-steady-state-hooks.md`](./operate/04-steady-state-hooks.md#operator-layer-hooks-into-the-steady-state-loop) (this file's A.1 / D steps call into them on every run except under the `--no-operate` / `--hands-off` opt-out — the operator layer is default-on since [#661](https://github.com/mattsears18/shipyard/issues/661)).

## Steady state (event-driven)

When an agent completes, the harness notifies you. Each notification is one orchestrator turn. In that turn:

### Turn contract (read this first, every turn)

Every steady-state turn has the shape `reconcile → [mid-session unblock re-eval] → release → dispatch (or prove idle) → invariant line`. The **last** thing you do every turn is exactly one of:

1. **Issue one or more dispatch calls** to fill freed slots — `Agent` tool calls (`subagent_type` + `isolation: "worktree"`) under the default shape, or `Workflow` tool calls under the alternate shape (see [dispatch-rules.md's two dispatch shapes](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c)) — then print the invariant line below the tool call(s).
2. **Print the structured idle-proof line** (defined in step E) showing every queue is empty and every slot is in flight or legitimately parked.

Never end the turn with prose. No "Next: …" narration, no status recap, no "I'll watch for returns and refill" promise. That recap sentence IS the bug — it gives the model a graceful exit from a turn whose dispatch obligation hasn't been met.

### A. Reconcile the return

The agent's last line tells you what happened.

**Invariant: only the agent's own terminal return line reconciles a slot — never a live PR-state read taken alone ([#1235](https://github.com/mattsears18/shipyard/issues/1235)).** A PR observed as `MERGED` with green checks (via step D's periodic refresh, the merge-method-drift check below, or any ad-hoc `gh pr view`/`gh issue view`) means the merge train finished, not that the dispatched worker's own post-push verification has completed — a `fix-checks-only` worker's normal tail (push → watch the rollup settle → verify → return) routinely overlaps with auto-merge firing. Do not treat a `MERGED` observation, by itself, as license to run this step's parse, release the slot in step B, or reap the worktree — the worker may still be executing, and doing so empties `.in_flight` (the very guard [`dont.md`](./dont.md) relies on) before the worker has actually returned. Wait for the worker's own terminal string, or a formal stall/crash detection ([A.0.5](#a05-post-return-worktree-reap-for-crashed--narrative-non-terminal-returns-fires-before-a1s-return-string-parsing)).

#### A.−1. Reconcile-once gate — skip phantom re-fires (MANDATORY — first thing in the turn)

**This gate is the first thing the orchestrator does on a wake — before A.0's token attribution, before A.1's return-string parsing, before anything else.** Closes [#317](https://github.com/mattsears18/shipyard/issues/317).

The Claude Code harness wakes the orchestrator by wrapping each agent chat-completion message in a `<task-notification>` envelope. After an agent emits its real return text (the line step A.1 parses), it can emit one or more wind-down acknowledgments (`"Done."`, `"Acknowledged."`, `"Monitor task completed."`, etc.) that the harness wraps in **additional** `task-notification` events with the same `task-id` — observed for long-running (>5 min) fix-checks-only and fix-rebase workers on `dowork-20260524T190234-73953`. Each phantom carries `tool_uses: 0`, a tiny `duration_ms` (~1–3 s), a small token delta, and `status: completed`. Without a gate, every phantom triggers a full A → E turn against an already-reconciled agent:

- A.0 double-bumps the per-PR cost ledger.
- A.1 attempts to re-handle a `shipped` / `green` / `blocked` return that was already labeled / commented / branch-reaped on the first turn (idempotent for some sites, not all).
- B re-releases an already-released slot.
- C dispatches a "replacement" worker against a slot that wasn't actually empty.
- D fires another refresh.

**The gate.** Extract the incoming `task-notification`'s `task-id` (the same value that lands in `.in_flight.<slot>.agent_id` on dispatch — the harness uses one id end-to-end). Check `reconciled_agent_ids`:

```bash
incoming_task_id="<task-id from the harness notification>"
if [[ -n "${reconciled_agent_ids[$incoming_task_id]:-}" ]]; then
  echo "[phantom-notification] task-id=$incoming_task_id already reconciled; skipping A.0/A.1/B/C/D this turn (#317)"
  # End the turn HERE — no invariant line, no tool call, nothing else.
  # The phantom notification is harness noise; the orchestrator's working
  # memory and the session-state file are both already correct.
  return
fi
```

The skip is **silent at the user-facing layer beyond the one advisory line** — no invariant line, no dispatch tool call, no session-state write-through. Step E's invariant-line requirement does NOT apply to a phantom-skipped turn (the turn is, by definition, a no-op against state). This is the **one documented exception** to the "every turn ends with either a tool call or the invariant line" rule from the turn contract above.

**Write into `reconciled_agent_ids` at the end of A.1.** Once a return has been parsed and A.1's per-mode handling has run (the `shipped` / `green` / `blocked` / `errored` / `reaped` / `noop` branches all converge here), append the just-reconciled agent's id to the set BEFORE proceeding to step B:

```bash
reconciled_agent_ids[<agent-id>]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

The timestamp value is informational (it lets a debug pass tell when the agent was first reconciled); only the key's presence is load-bearing for the gate above.

Use a set (not a dispatch-time `.in_flight`-membership check) so a phantom re-fire is distinguishable from a real fresh completion, and let it grow unevicted for the session. See [RATIONALE → Reconcile-once gate design choices](../do-work-RATIONALE.md#reconcile-once-gate-design-choices-317) for why a set beats a bookkeeping check and why unbounded growth is fine.

**Set keying — `agent_id` (the harness `task-id`), not the slot id.** The slot id (e.g. `slot1`) is reused as workers come and go; the agent id is unique per dispatch. Use the agent id so the set survives slot reuse across the session.

**Logging discipline — one line per phantom.** The advisory above (`[phantom-notification] task-id=$incoming_task_id ...`) is the only output the gate produces. Don't add to the line per-phantom; if the same task-id phantoms three times, three identical advisory lines is the correct behavior (the operator can grep + count by id to size the harness noise across a session).

**Cost-tracking interaction.** Phantom notifications carry their own small `<usage>` block. By skipping A.0, the gate intentionally drops those phantom-only tokens from the session ledger. The alternative — bumping with `--issue` / `--pr` scope and the small delta — would double-attribute against PRs that are already finished. The phantom tokens are harness-overhead, not work-attributable; dropping them from per-PR / per-issue buckets is correct. The orchestrator-side overhead bump (the `bump-tokens` call without `--issue` / `--pr`) is similarly skipped — adopting the "harness noise is not the session's cost" stance.

**Failure mode — incoming notification has no parseable `task-id`.** If the wake event genuinely lacks an extractable id (the harness changed shape, the payload is malformed), the safe fallback is to **proceed with A.0** as a real reconcile — phantom-mis-recognition (treating a real return as a phantom) is much more damaging than phantom-as-real (one extra bump-tokens + one extra reconcile attempt against a no-op return). Log `[phantom-notification] could not extract task-id from wake event; treating as real reconcile` and continue.

**Variant — a phantom that carries a *different, still-in-flight* sibling's terminal outcome (MANDATORY pre-skip check — [#530](https://github.com/mattsears18/shipyard/issues/530)).** The pure silent-`return` above is correct only for a **genuine wind-down phantom** — one whose body asserts nothing reconcilable (`"Done."`, `"Acknowledged."`) or names only the already-reconciled target. But the harness has been observed to **cross-wire a still-in-flight sibling worker's only completion notification onto a reaped worker's `task-id`**: the phantom's `task-id` is already in `reconciled_agent_ids`, yet its *body* asserts a terminal outcome (`shipped #<N> via PR #<M>`, `green #<M>`, etc.) for a **different** target that maps to a slot still live in `.in_flight`. Pure-skip there would **strand the in-flight sibling** — its real completion arrived only as this phantom, so the slot would hang unreconciled until end-of-session with no other notification ever coming.

See [RATIONALE → Cross-wired phantom repro](../do-work-RATIONALE.md#cross-wired-phantom-repro-530) for the session repro that motivated this check.

**The pre-skip check.** Before the silent `return`, parse the phantom's body for a terminal return string naming a PR/issue. If it names a target tied to a **currently in-flight** slot (`.in_flight.<slot>` whose `issue` / `pr` matches), do NOT silent-skip — run the [trust-but-verify probe](dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) (issue `state` + PR `mergeStateStatus`) for that slot's target, and if ground truth confirms the asserted outcome, **reconcile the in-flight sibling from verified state** (fall through to A.0/A.1 against the in-flight slot's `agent_id`, not the phantom's reaped id) — then write the *sibling's* id into `reconciled_agent_ids`. Only fall through to the silent `return` when the body is a genuine wind-down (asserts nothing reconcilable, or names only the already-reconciled target, or names a target whose ground-truth probe does NOT confirm a terminal outcome):

```bash
if [[ -n "${reconciled_agent_ids[$incoming_task_id]:-}" ]]; then
  # #530: a reconciled task-id can still carry a *sibling's* cross-wired
  # completion. Inspect the body before silently skipping.
  sibling_slot="$(slot_in_flight_matching_phantom_body "$phantom_body")"   # PR/issue named in body ∩ .in_flight target
  if [[ -n "$sibling_slot" ]]; then
    # Trust-but-verify the in-flight sibling's target against GitHub ground truth.
    if ground_truth_confirms_terminal "$sibling_slot"; then
      echo "[phantom-notification] task-id=$incoming_task_id reconciled, but body asserts a terminal outcome for in-flight slot=$sibling_slot; verifying ground truth and reconciling the sibling from verified state (#530)"
      # Reconcile the IN-FLIGHT sibling (its agent_id), NOT the phantom's reaped id:
      # fall through to A.0/A.1 keyed on .in_flight.$sibling_slot.agent_id,
      # then reconciled_agent_ids[<sibling agent_id>]=<ts> at the end of A.1.
      reconcile_in_flight_slot_from_ground_truth "$sibling_slot"
      return   # the sibling's A.0→A.1→B→C→D ran; this turn is no longer a no-op
    fi
    # Ground truth did NOT confirm — treat as a genuine wind-down phantom, skip.
  fi
  echo "[phantom-notification] task-id=$incoming_task_id already reconciled; skipping A.0/A.1/B/C/D this turn (#317)"
  return
fi
```

The verification gate is what keeps this safe: the phantom's *narrative* is untrusted (it's harness-cross-wired text, not a return the orchestrator dispatched), so it only **triggers** a ground-truth probe — it never reconciles on the body's word alone. A phantom whose body names an in-flight target but whose GitHub state does NOT confirm the asserted outcome falls back to the silent skip (the sibling is genuinely still working; its real notification will arrive later). This preserves [#317](https://github.com/mattsears18/shipyard/issues/317)'s double-reconcile protection (the phantom's *own* reaped id is never re-reconciled) while closing the strand-the-sibling hole.

#### A.0. Attribute the dispatch's token usage (MANDATORY — before any return-string parsing)

**This step is not optional.** Before parsing the agent's return string, before any of the per-mode handling below, **attribute the dispatch's token usage to the session ledger**. Without this call, the per-session `.tokens` block, the per-issue / per-PR attribution buckets, the durable PR cost-comment, and the cross-session ledger at `~/.shipyard/cost-history.jsonl` all stay empty — and the perf umbrella ([#152](https://github.com/mattsears18/shipyard/issues/152)) becomes unmeasurable. See [issue #197](https://github.com/mattsears18/shipyard/issues/197) for the regression that prompted this becoming step A.0 instead of a buried mention in the write-through table.

Extract the `usage` payload from the dispatch tool result — the harness emits it as a `<usage>` block in the task-notification message that wakes this turn. The strict-path block has the shape:

```
<usage>
  input_tokens: <int>
  output_tokens: <int>
  cache_read_input_tokens: <int>
  cache_creation_input_tokens: <int>
  total_tokens: <int>
  duration_ms: <int>
</usage>
```

#### A.0 required preamble — cwd-independent session-id derive (MANDATORY — closes [#548](https://github.com/mattsears18/shipyard/issues/548))

**Every A.0 bash call MUST be preceded by this preamble in the same Bash tool call** — without it, a reconcile-turn cwd-leak (the harness relocates the orchestrator's cwd into the just-returned agent's `agent-*` worktree) makes session-id derivation read the wrong directory and silently lose token attribution, the `session_prs` append, and the cost comment for the turn. This solves a different problem than the reap blocks' `STABLE_DIR` cwd anchor ([#497](https://github.com/mattsears18/shipyard/issues/497)) — reading the session-id file correctly, not avoiding a doomed-directory delete; the two compose. See [RATIONALE → A.0 preamble mandate](../do-work-RATIONALE.md#a0-preamble-mandate-548) for the full failure chain, repro, and how the defenses compose.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# Derive the session id from the NEWEST orchestrator-* worktree's stash.
# cwd-independent given the explicit --repo-root (immune to the #477 cwd-leak
# that fires on reconcile turns). See setup.md §0.55 for the full rationale.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SESSION_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" derive-session-id \
  --repo-root "$REPO_ROOT" 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
# Loud abort when both derive paths return empty — cascading exit-64s from
# empty --session-id are silently mis-read as success; a loud log line + skip
# makes the cwd-leak immediately visible in the turn transcript (#548).
if [ -z "$SESSION_ID" ]; then
  echo "[session-id-derive] empty — aborting A.0 turn writes; check for #477 cwd-leak (orchestrator cwd may be inside an agent-* worktree)"
  # Leave tokens_attributed=false; set A05_DISPATCH_TOKENS=0 so A.0.5's
  # wasted-dispatch accounting sees 0 tokens rather than an unbound variable.
  A05_DISPATCH_TOKENS=0
fi
```

Run this preamble block **once per Bash tool call** that contains an A.0 `bump-tokens` invocation — Bash tool calls are hermetic (variables from call N do not survive to call N+1), so each call that needs `SESSION_ID` must re-derive it.

#### Strict path — full input/output/cache breakdown (preferred)

**Pass all four token counts through to `bump-tokens` separately** — never collapse them into `--input <total_tokens>`. Output tokens are priced at 5× input on every Anthropic model the pricing table covers, and `cache_read_input_tokens` are priced at 10% of input. Collapsing the breakdown understates real session cost by 20-50% and makes prompt-cache hit-rate invisible. See [#225](https://github.com/mattsears18/shipyard/issues/225) for the regression that prompted this requirement (the previous spec allowed a "`total_tokens` alone is enough for first-pass attribution" fallback that callers took universally, leaving every per-invocation record with `output: 0` and `cache_*: 0`).

Invoke (after the A.0 required preamble above — `SESSION_ID` is already set):

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# Guard: skip if preamble failed to derive SESSION_ID (loud log already emitted above).
if [ -n "$SESSION_ID" ]; then
"${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" bump-tokens \
  --session-id "$SESSION_ID" \
  --issue <N>            `# present for issue-work and fix-checks-only on issue-anchored PRs` \
  --pr <M>               `# present for fix-checks-only, fix-rebase, fix-main-ci, fix-failing-prs-batch (and issue-work after it shipped)` \
  --input <input_tokens> \
  --output <output_tokens> \
  --cache-read <cache_read_input_tokens> \
  --cache-creation <cache_creation_input_tokens> \
  --mode <mode> --model <model-id> \
  --allow-degraded-init --degraded-init-repo "<owner/repo>"
fi
```

All four `--input` / `--output` / `--cache-read` / `--cache-creation` flags are **required** on the strict path — pass `0` explicitly if the harness reports the field as missing or zero (rare), don't omit the flag. Both `--issue` and `--pr` are optional from the helper's perspective — pass whichever the dispatch surfaced. `bump-tokens` will route the attribution into `.tokens.totals` always, into `.tokens.per_issue[<N>]` if `--issue` is present, and into `.tokens.per_pr[<M>]` if `--pr` is present.

#### Degraded path — total-only fallback (when the harness `<usage>` block lacks the breakdown)

The strict path requires the harness to emit `input_tokens` / `output_tokens` / `cache_read_input_tokens` / `cache_creation_input_tokens` in the sub-agent `<usage>` block. On some Claude Code harness versions (observed on Opus 4.7, 2026-05-23 — see [issue #279](https://github.com/mattsears18/shipyard/issues/279)) the block only emits **three** fields — `total_tokens`, `tool_uses`, `duration_ms` — with no input/output/cache split. The strict path cannot run; without a fallback, A.0 silently skips attribution session-wide, every cost-tracking comment renders `$0`, and the perf-umbrella ([#152](https://github.com/mattsears18/shipyard/issues/152)) becomes unmeasurable.

When the `<usage>` block has `total_tokens` but no breakdown, fall back to the **degraded path** rather than skipping the bump entirely:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# Guard: skip if preamble failed to derive SESSION_ID (loud log already emitted above).
if [ -n "$SESSION_ID" ]; then
"${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" bump-tokens \
  --session-id "$SESSION_ID" \
  --issue <N> --pr <M> \
  --input <total_tokens>          `# total_tokens lands in --input; other token flags MUST be omitted` \
  --mode <mode> --model <model-id> \
  --allow-degraded-init --degraded-init-repo "<owner/repo>" \
  --degraded-total-only
fi
```

`--degraded-total-only` is mutually exclusive with non-zero `--output` / `--cache-read` / `--cache-creation` — passing those alongside is rejected with exit 64. It also requires `--input <total_tokens>` to be **non-zero** ([#320](https://github.com/mattsears18/shipyard/issues/320)): `--input 0` is the orchestrator copy-paste trap (pasting the breakdown-fields default into the degraded path and silently recording $0 across every dispatch in the session), and the helper rejects it with exit 64. The bump lands in `.tokens.totals.input` (and the per-issue / per-PR buckets if scoped); the per-invocation entry is stamped `degraded: true`, and `.tokens.degraded_attribution_count` increments by 1 so the [end-of-session summary](./cleanup-summary.md#end-of-session-summary) can surface a banner.

The end-of-session banner [branches on the ratio](./cleanup-summary.md#end-of-session-summary) of `degraded_attribution_count` to `per_invocation.length` ([#295](https://github.com/mattsears18/shipyard/issues/295)) — an all-degraded session gets the "this harness path is total-tokens-only" framing, a mixed session gets a per-dispatch ratio. The orchestrator does NOT need to compute or pass the ratio at A.0 time — both counters are already in the session state file by the time cleanup-summary renders.

Degraded attribution produces an unreliable-but-non-zero cost figure rather than skipping the bump entirely, on the principle that some signal beats zero signal — a skipped bump would render `$0` on every cost-tracking comment, read by the operator as "no work happened" rather than "attribution data lost." **This is not a clean under-count** ([#1035](https://github.com/mattsears18/shipyard/issues/1035)): pricing the whole `total_tokens` figure at the input rate overstates it against any real cache-read tokens folded in (cache reads are far cheaper than input) and understates it against any real output tokens folded in (output is several times pricier than input) — the two errors don't cancel predictably, so the degraded figure is directionally unknown, not merely low. See [RATIONALE → Degraded-path tradeoff](../do-work-RATIONALE.md#degraded-path-tradeoff-279) for the full reasoning and the original repro.

Per #225's no-collapse rule still holds for callers that *have* the breakdown — `--degraded-total-only` is reserved for the case where the harness genuinely doesn't expose the four counts.

**One-line warning on first degraded hit per session.** The first time A.0 falls back to the degraded path in a given session, log a single advisory line:

```
[bump-tokens] <usage> block lacks input/output/cache breakdown — falling back to --degraded-total-only (cost will under-count; #279)
```

**Subsequent degraded bumps in the same session must NOT re-log this advisory** — at `--concurrency 2+` it'd produce one line per dispatch, drowning the steady-state turn output. Track the first-hit-per-session state in orchestrator working memory (a boolean flag — same scope as the `tokens_attributed` flag), set it the first time the path is taken, and skip the log on subsequent degraded bumps. The session-level `.tokens.degraded_attribution_count` in the state file is the durable counter; the one-line log is the operator-visible signal.

The `--allow-degraded-init --degraded-init-repo "<owner/repo>"` pair is **required** on every `bump-tokens` call (closes [#253](https://github.com/mattsears18/shipyard/issues/253)'s cost-tracking workaround). It makes the helper resilient to a file-disappear-mid-session event — if a concurrent `/do-work` session's orphan-sweep reaped this session's state file, the helper auto-recreates a fresh state file marked with `.degraded_recovery_at` and proceeds with the bump rather than erroring exit-3. Cost data from before the disappear is lost, but every bump from the disappear forward lands somewhere durable. Without the flag pair, the orchestrator silently loses cost attribution for every subsequent reconcile turn (the failure mode the workaround fixes).

The `--model` value should be the harness-reported model id verbatim — `bump-tokens` resolves dated suffixes (`claude-haiku-4-5-20251001`) and bare aliases (`opus` / `sonnet` / `haiku`) against the pricing table internally (see #226).

**Set the per-turn `tokens_attributed` flag to `true`** the moment `bump-tokens` returns successfully — step E's invariant line surfaces it for compliance auditing. On a turn where `bump-tokens` errors, leave the flag `false`, log `[bump-tokens] attribution failed: <exit code>; continuing`, and proceed with reconcile anyway. The dollar-cost data point is lost but the dispatch loop keeps moving; the flag's purpose is to make the gap visible, not to gate forward progress.

**If the dispatch had no `usage` payload at all** (the entire `<usage>` block is missing — distinct from the #279 case where the block exists but only carries `total_tokens`; a true full-payload-missing event is much rarer), still proceed to A.1; log `[bump-tokens] no usage payload in dispatch result; skipping attribution` and leave `tokens_attributed=false`. Same don't-block-on-observational-data posture as the helper-error path. The degraded-total-only path above handles the more common case where the block exists but lacks the four breakdown fields.

Once A.0 has fired (or its skip has been logged), proceed to A.0.5.

#### A.0.5. Post-return worktree reap for crashed / narrative-non-terminal returns (fires BEFORE A.1's return-string parsing)

Closes [#358](https://github.com/mattsears18/shipyard/issues/358). The reap path in [step B](#b-release-the-slot) (added in [#334](https://github.com/mattsears18/shipyard/issues/334)) covers every clean completion — but on a **crash return** (the worker's `claude` subprocess died with an API socket error, an internal harness error, or any other abnormal termination), two failure modes can let the worktree linger:

1. The agent's `claude` subprocess **remained alive after the harness reported completion**, which makes `classify-lock` return `peer-alive` when the lock PID is the still-alive agent subprocess (not the orchestrator). A.0.5 force-reaps this case too, same as step B, but still matters independently since it fires *before* A.1, closing the window sooner, and performs the crash-specific committed-but-unpushed recovery salvage below, which step B's reap never attempts. See [RATIONALE → Dogfooding repro for lingering agent subprocess](../do-work-RATIONALE.md#dogfooding-repro-for-lingering-agent-subprocess) for the session that surfaced this and the pre-#771 history.
2. The orchestrator may skim past step B's reap block when the return string is unparseable narrative ("API Error: ...", "Routine progress.", "shard 3/3 passes") — treating the whole turn as "errored, record and continue" without exercising the reap. The spec calls step B's reap unconditional, but the in-context "this turn was a crash, the reconcile path is degenerate" signal can easily override the discipline.

Both failure modes leave the worktree path unreusable for the remainder of the session; the next setup-3b pass at session start eventually reaps, but the cost in the interim is one stuck slot per crash. This step is the in-session safety net: a **crash-aware reap that fires before A.1** explicitly because the agent is non-recoverable and the lingering subprocess (if any) is dead weight — `peer-alive` does not justify deferring on a crash return the way it does on a clean completion.

**This section is the single shared contract for every shape of "a worker stopped without a terminal return" — the failure class [#838](https://github.com/mattsears18/shipyard/issues/838) and [#833](https://github.com/mattsears18/shipyard/issues/833) both report, extending [#813](https://github.com/mattsears18/shipyard/issues/813).** They differ only in what triggers the non-terminal stop, and both funnel through the same detect → inspect → (resume | recover-and-reap) flow below:

- The harness reports `status: completed` but the return text is pending-intent narrative outside the terminal vocabulary (#813 / #838 — e.g. *"Waiting for the background test run to complete."*). Covered by the **stalled-worker detection and resume** subsection immediately below.
- The harness reports `status: completed` with a return that's genuinely crash-like (an API error, an empty string, or a narrative that leaves nothing resumable) — the original #358 case. Covered by the **crash / narrative-non-terminal detection** subsection further down.
- The harness reports **`status: failed`** via the stall watchdog (*"no progress for 600s (stream watchdog did not recover)"*) — #833. This status is, on its own, sufficient to route through the inspect-before-reap flow below regardless of what the notification's accompanying `result` text says — see the mechanical terminal-prefix check's `harness_status` guard.

**Never reap before inspecting — this is the load-bearing safety property.** Whenever either signal fires, the worktree gets `git log --oneline origin/<default>..HEAD` and `git status --porcelain` read *before* any `git worktree remove`, exactly as the "mechanical check that grounds the judgment call" below already does for the pending-intent case. Everything past that inspection — resume vs. salvage-and-reap vs. drop-clean — is recovery *policy*; the inspection itself is not optional on any of the three triggers above.

**None of these three is `blocked`.** `blocked` stays reserved for a worker's own deliberate, terminal `blocked: <reason>` return (A.1's handling below) — a worker that stops non-terminally or gets killed by the stall watchdog made no such deliberate call, so none of the paths in this section apply a `blocked:*` label. The outcome class this section produces is `stalled` (pending-intent path) or a plain crash-recovery reap (everything else) — see the `stalled_dispatches` ledger ([`orchestrator-state-reference.md`](./orchestrator-state-reference.md#cold-orchestrator-state-structures)) for how every occurrence, regardless of trigger, is recorded for the end-of-session summary.

**Stalled-worker detection and resume — the FIRST check inside this step, before the crash-detection paths below ([#813](https://github.com/mattsears18/shipyard/issues/813)).** A narrative, future-tense return is not always a crash. A worker that finished its real work but suspended itself awaiting a `Monitor` / backgrounded-process notification it can never receive (the harness only re-wakes a task that has a *live foreground* call outstanding — a task that went idle awaiting a background child has already ended, per `shipyard:worker-preamble` § "Run all work synchronously to a terminal state") looks identical to a crash by the terminal-prefix check below, but its worktree is very often complete and one `git commit` away from shipping. Reaping it outright via the crash-recovery path further down either force-commits with `--no-verify` — discarding the worker's own hook-validated commit path — or, if the worktree happens to hold no diff, simply throws real, expensive work away for a fresh re-dispatch to redo from scratch. Neither is correct when the worker can instead just be told to stop waiting and finish. **This is a distinct, non-terminal outcome — call it `stalled`** — and it is NOT `blocked`: `blocked` is reserved for a worker's own deliberate, terminal `blocked: <reason>` return (see [A.1's `blocked #<N>` handling](#a1-parse-the-return-string) below), and routing a stalled worker's pending-but-recoverable work through the `blocked` label/comment machinery would mislabel near-complete work as a dead end. This paragraph is the discriminator that routes to **resume** instead of reap; everything from "**Detection — what counts as a crash…**" onward remains the fallback for genuine crashes and exhausted resumes.

**The judgment call — pending intent, not a keyword list.** Read the return text the way a human reviewer would: does it describe an outcome that already happened (a `shipped`/`green`/`blocked`/etc. terminal, or a genuine crash signature like `API Error:` or an empty string), or does it describe a plan contingent on something that has NOT happened yet — future tense ("I'm now waiting for…", "I'll proceed to…", "once it reports green, I'll…"), a numbered to-do list of steps not yet taken, or any other framing that names an intention rather than a completed action? The latter is **pending intent**. This is a judgment call the orchestrator makes by reading the text, not a regex/keyword match — a worker's own phrasing varies, and a brittle keyword list is both easy to evade by accident and expensive to keep current. Treat any return that reads as "I'm about to…" / "next I will…" / "waiting for X, then I'll Y" as pending-intent, regardless of the exact wording.

**The mechanical check that grounds the judgment call.** Pending-intent language alone is not sufficient to resume — the worker's worktree must still exist AND hold recoverable work, otherwise there is nothing to resume and the case degenerates into the plain crash-like path below. This is the same worktree-state probe step 1 of the "Recovery semantics, in order" list below already performs — run it early, before deciding between resume and reap:

```bash
ahead_count=$(git -C "$worktree_path" rev-list --count "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "0")
dirty=$(git -C "$worktree_path" status --porcelain 2>/dev/null)
```

- `ahead_count > 0` (committed-but-unpushed work) **OR** `dirty` is non-empty (uncommitted edits) → **resume-worthy.** The worker did real work; it just suspended itself instead of finishing it. Proceed to the resume path below.
- `ahead_count == 0` **AND** `dirty` is empty → **not resume-worthy**, no matter how pending-intent the text reads. There is nothing on disk to preserve — this is exactly today's dispatch-refused shape (see [dispatch-rules.md's "leave no `.in_flight` slot behind and let the next turn's slot-fill retry the candidate"](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c)): drop the slot and let step C's next fill retry the candidate fresh. Fall through to the ordinary crash-like detection/reap below — it will find nothing to recover, just reap, and record the `stalled_dispatches` entry itself (see the ledger append at the bottom of the crash-recovery block).

**The resume path — prefer resuming the SAME agent over a fresh dispatch, and never re-arm the same background wait ([#838](https://github.com/mattsears18/shipyard/issues/838), [#833](https://github.com/mattsears18/shipyard/issues/833)).** When pending-intent AND resume-worthy both hold, do NOT run the crash-recovery auto-commit-and-reap path below. A resume preserves the worker's transcript and its worktree in place; re-dispatching from scratch redoes work already paid for, and the pre-dispatch reap that precedes a fresh dispatch would delete the recoverable work first. Instead:

1. **Bound it first — retry cap 1 per target per session.** Track `stalled_resume_counts[<slot-target>]` (keyed by the slot's issue/PR number — same convention as `main_ci_fix_attempts`) in orchestrator working memory, initialized to 0 the first time a slot's target is seen. If the count is already `>= 1`, do NOT resume again — this target already had its one resume. **Hand it back** by falling through to the crash-recovery path below, which still salvages any committed/dirty work into a PR (see "Recovery semantics, in order" further down) — it just does so via auto-commit-and-push rather than a second live resume. A target that stalls twice is genuinely wedged; looping resumes on it wastes tokens without addressing the underlying cause.
2. Otherwise, increment `stalled_resume_counts[<slot-target>]` by 1 and **gather the orchestrator's own reading of the worktree BEFORE composing the resume message.** The stalled agent's last self-report is not trustworthy about how far it actually got — it may have been mid-sentence when the stall watchdog killed it. Run, read-only, against `$worktree_path`:
   ```bash
   git -C "$worktree_path" fetch origin "$DEFAULT_BRANCH" 2>/dev/null || true
   git -C "$worktree_path" log --oneline "origin/${DEFAULT_BRANCH}..HEAD"
   git -C "$worktree_path" status --porcelain
   # When version_coordination is enabled, also read the manifest's current
   # on-disk version so the resume message states it rather than guessing.
   gh pr list --repo <owner/repo> --state open --head "do-work/issue-<N>" \
     --json number --jq '.[0].number // empty'
   ```
   Fold the literal output of each into the resume message: commits present/absent (with SHAs and subject lines), dirty paths (the porcelain listing verbatim), the manifest version currently on disk, and whether a PR already exists for the branch. This reading — not the worker's own prior narrative — is what the resume message asserts as ground truth.
3. **Resume the SAME agent when one is live and addressable; otherwise re-enter the SAME worktree with a fresh call.** The two dispatch shapes this repo uses have different resume primitives, and the choice between them is mechanical, not a preference:
   - **`Agent`-tool dispatch (`isolation: "worktree"`, a live background subagent with an `agent_id`)** — send a follow-up message to that exact agent via `SendMessage` targeting its `agent_id`. This is the preferred path where available: it resumes the agent's own transcript in place, so it already has full context of what it did and why — the orchestrator only supplies the verified worktree reading from step 2 and the instructions below. **This is the path validated live in this session**: worker `#826`'s dispatch stalled with its deliverable uncommitted, was resumed via `SendMessage` carrying the orchestrator's own worktree reading, and shipped cleanly as PR #834.
   - **`Workflow`-substrate dispatch (an `agent()` call — the default per [#791](https://github.com/mattsears18/shipyard/issues/791))** — `agent()` is a one-shot call with no documented resume/follow-up primitive (see [`workflows/README.md`](../../workflows/README.md)), so there is no live agent to message. The closest equivalent is a **fresh `agent()` call into the SAME worktree and branch** — do not `git worktree add` again and do not create a new branch; the prompt itself carries the resume framing and the step-2 reading.

   Either way, the message/prompt:
   - States plainly that this is a **resume**, not a fresh start, and **opens with the orchestrator's own verified reading from step 2** — not a request for the worker to re-derive it.
   - Instructs the worker to **stop waiting on any background process or `Monitor` subscription** — that mechanism cannot notify it again inside a resume — and to **re-run the blocking command (the test suite, the long-running check) synchronously in the foreground**, reading its exit status directly, exactly as `shipyard:worker-preamble`'s "Run all work synchronously to a terminal state" rule already requires of every dispatch.
   - **Explicitly forbids arming a NEW background process for any LATER step in the same resumed dispatch, not only re-waiting on the one it's being resumed from ([#1111](https://github.com/mattsears18/shipyard/issues/1111)).** The instruction above stops the worker re-subscribing to the *specific* wait it was killed on; on its own it doesn't say anything about a *different* operation later in the same turn. The #1111 repro shows the gap concretely: a `fix-checks-only` worker resumed for a backgrounded CI-verification wait, correctly stopped waiting on that one — then went on to background its next `git commit` (tracked via a fresh `Monitor`) and stalled a second time on the same target. One resume telling a worker to stop waiting on a specific thing does not reliably generalize to "don't background anything else either" — the resume message has to say so.
   - Tells the worker to then proceed through its mode's normal terminal steps (commit, push, open the PR, or continue past whatever step the step-2 reading shows is next) once the foreground command completes, and to return one of its mode's normal terminal strings.

   **Canned resume-message template ([#1054](https://github.com/mattsears18/shipyard/issues/1054), strengthened by [#1111](https://github.com/mattsears18/shipyard/issues/1111)) — fill in the bracketed fields from step 2's verified reading rather than improvising prose per incident:**
   ```
   RESUME (not a fresh start) — target #<slot-target>, worktree <worktree_path>, branch <branch>.

   Verified state (orchestrator's own reading, not your prior narrative):
   - commits ahead of origin/<default>: <count> <SHAs + subject lines, or "none">
   - working tree: <clean | dirty: `<porcelain listing>`>
   - manifest version on disk: <version>
   - open PR for this branch: <#M | none>

   Stop waiting on any background process or Monitor subscription now — it cannot
   notify you again inside this resume. This applies for the REST of this
   dispatch, not only the thing you were waiting on: do not arm a NEW background
   process either (a `run_in_background` Bash call, a Monitor, a backgrounded
   commit or pre-commit hook) for any later step — a worker resumed once has been
   observed re-backgrounding a different operation and stalling a second time on
   the same target (#1111). If you were blocked on a long-running command, re-run
   it synchronously in the foreground and read its exit status directly. Then
   proceed through your mode's normal terminal steps from the verified state
   above (commit if not yet committed, push, open the PR, arm auto-merge) and
   return one of your mode's normal terminal strings — not a narrative.
   ```
4. Log `[reconcile-A.0.5-resume] slot=<slot-id> target=#<slot-target> stalled resume attempt 1/1 via <SendMessage|fresh-agent()-call> into existing worktree <worktree_path> (#838/#833)` and append a `stalled_dispatches` entry (see [`orchestrator-state-reference.md`](./orchestrator-state-reference.md#cold-orchestrator-state-structures)) with `outcome: "resumed"`. Mirror it via `session-state.sh record-stall --outcome resumed` too ([#1302](https://github.com/mattsears18/shipyard/issues/1302)), same fire-and-forget / `session_state_degraded_since` handling as the crash-recovery append above — `--resumed-pr` is omitted here since the shipped PR isn't known yet; the file-mirrored entry's `resumed_pr` stays `null` even after step 5 backfills the working-memory copy (the typed subcommand only appends, it has no update-in-place — the working-memory struct and the end-of-session summary remain the fidelity source for the eventual PR number). End this turn's A.0.5 handling for this slot — the resume becomes the slot's new in-flight agent (for a `SendMessage` resume, `.in_flight.<slot>.agent_id` is unchanged since it's the same agent; for a fresh `agent()` call, update it to the new call's id). Its own completion re-enters this same reconcile flow on its own wake, subject to the same detection and the now-exhausted retry cap.
5. When the resume itself later returns a genuine terminal string, A.1's normal per-mode handling processes it exactly as if it had arrived on the first attempt — `stalled` is invisible to A.1's return vocabulary once it resolves; update the `stalled_dispatches` entry's `resumed_pr` field to the shipped PR number, if any. If the resume stalls again, the cap (step 1) is now exhausted — the NEXT stalled (or `status: failed`) wake for that target falls through to the ordinary crash-recovery path below and its own `stalled_dispatches` entry records `outcome: "handed-back"`.

Resume beats the crash-recovery reap for this specific shape — the reap path is heavy-handed for a worker that's provably still resumable. See [RATIONALE → Resume vs. crash-recovery reap](../do-work-RATIONALE.md#resume-vs-crash-recovery-reap-813) for why, and the #813 repro this section formalizes.

**Detection — what counts as a crash / narrative-non-terminal return (the fallback for genuine crashes and exhausted resumes).** The stalled-worker check above already handles the pending-intent-with-resumable-worktree case. Everything below applies to what's left: returns with no pending-intent reading at all (an actual crash signature), stalled returns that found nothing resumable or already exhausted the resume cap, and **any dispatch where the harness itself reports `status: failed`** — the stall watchdog ("no progress for 600s (stream watchdog did not recover)", the [#833](https://github.com/mattsears18/shipyard/issues/833) trigger). A `status: failed` notification routes here **unconditionally**, regardless of what its `result`/return text says — the watchdog firing means the agent never reached its own terminal return, so even text that happens to start with a terminal-looking prefix (a coincidence, not a real completion) must not short-circuit the inspection. The agent's last-line return text fails the terminal-prefix check when the harness status is `failed`, OR when the text does NOT start with any of:

- `shipped` (issue-work, fix-main-ci, fix-failing-prs-batch happy path)
- `green` (fix-checks-only happy path)
- `noop:` (every mode's benign-no-op variant)
- `blocked` (every mode's deterministic-failure variant)
- `rebased` (fix-rebase happy path)
- `reaped:` (the worker's own "my worktree was reaped" escape hatch from `shipyard:worker-preamble`)

When the return text fails the prefix check, treat it as crash-like and proceed with the reap. Common crash-like shapes:

- `API Error: ...` / `Error: ...` — Anthropic API errors, harness-side errors.
- Empty string / single whitespace — the subprocess died before emitting any final message.
- Narrative status updates (`"Routine progress.", "shard 3/3 passes."`, `"Waiting for monitor..."`) — contract violation per [`shipyard:worker-preamble` § Return-contract discipline](../../skills/worker-preamble/SKILL.md#return-contract-discipline), but observationally indistinguishable from a crash for reap purposes.

**Pre-reap recovery check — save committed and uncommitted work before discarding the worktree ([#493](https://github.com/mattsears18/shipyard/issues/493), [#495](https://github.com/mattsears18/shipyard/issues/495)).** Before reaping a crashed worker's worktree, check whether the worker left any work that hasn't reached `origin` yet. Two cases apply: (a) the worker committed locally but hadn't pushed yet, and (b) the worker's working tree is dirty (edits staged or unstaged, never committed). Either way the worker completed expensive work that a full redo would duplicate. The recovery converts a mid-run stall or watchdog kill from "lose N edits + redo from scratch" into "salvage + push + open PR for the work already done."

**Version-coordination bump during recovery ([#575](https://github.com/mattsears18/shipyard/issues/575)).** When `version_coordination.enabled` is true and a `manifest_path` is configured, the crashed worker may not have reached its own release-bump step (the worker crashes mid-implementation, before adding the manifest version bump + CHANGELOG entry). The recovery path checks whether the manifest version row in the worktree is unchanged from `origin/<default>` — if so, the recovery computes `next_available_version` — **bump-type-aware ([#671](https://github.com/mattsears18/shipyard/issues/671))**, inferring major/minor/patch from the recovered issue's Conventional Commits title/body so a breaking-change or feature issue isn't stamped with a semver-wrong patch — and folds the bump + a minimal CHANGELOG stub into the auto-commit (dirty-worktree path) or as an additional commit (committed-but-unpushed path) before pushing. This guarantees the recovered PR carries the release bump the crashed worker never reached. The bump is **best-effort / fire-and-forget**: if the computation fails (manifest read fails, `jq` missing, coordination disabled), the recovery still pushes the PR as-is and logs a loud `[reconcile-A.0.5-recovery] WARNING: recovered PR has no version bump — manual release bump required` advisory so the operator can patch it before merge. **Non-version-coordinated repos are unaffected** — when `version_coordination.enabled` is false or `manifest_path` is empty, the helper is a no-op and the recovery proceeds exactly as before.

**Recovery semantics, in order:**

1. `git -C <worktree_path> rev-list --count origin/<default>..HEAD` — if the count is **> 0**, the worker committed work that hasn't been pushed; jump to step 1.5. If the count is **0**, no commit landed yet — check whether the working tree is dirty (`git -C <worktree_path> status --porcelain` non-empty). If the working tree is dirty and the branch is `do-work/issue-<N>`, run the version-coordination bump check (step 1.5) to inject the bump into the working tree before staging, then auto-commit all changes with `--no-verify` (the pre-commit gate may be exactly what hung the worker; CI is the real gate) and then push normally (step 2). Log the commit SHA and a `[reconcile-A.0.5-recovery] dirty-worktree auto-commit` prefix. If both `rev-list --count == 0` AND `status --porcelain` is empty, there is no work to recover; proceed directly to the reap.

1.5. **Version-coordination bump check** (fires in both the committed-but-unpushed and dirty-worktree recovery paths, before any push): when `version_coordination.enabled` and a `manifest_path` are configured, compare the manifest version in the worktree's HEAD (or working tree, for the dirty path) against `origin/<default>`'s version. If they match (the worker never reached the bump step), compute the next available version and apply the bump: write the new version into the manifest file using `manifest_version_jq`, then prepend a `### <version> — <YYYY-MM-DD>` stub entry to `changelog_path` (when configured) referencing the recovered issue + PR. For the dirty-worktree path, apply these file edits before `git add -A` so they fold into the auto-commit. For the committed-but-unpushed path, apply these file edits and create an additional bump commit on top of the existing commits before pushing. When the bump can't be computed (manifest read fails, jq absent, version_coordination disabled), skip the bump and log the advisory; recovery continues as before.
2. If count **> 0** (or a dirty-worktree auto-commit just landed), the worker committed at least one commit before crashing. Reaching a commit means either pre-commit hooks passed (the commit is hook-validated) or the recovery committed with `--no-verify` (CI is the safety net). Attempt to push the branch to origin:
   ```bash
   git -C "$worktree_path" push origin "do-work/issue-<N>" 2>&1
   ```
   Log success or failure. If the push fails (network still down, permissions issue, the branch is already on origin ahead of this commit), continue to step 3 rather than reaping silently — a failed push still leaves the local commit recoverable by a human inspection of the worktree before it's removed.
3. After a successful push, check whether an open PR already exists for the branch. If no PR exists, create one using the normal issue-work PR template (`Closes #<N>` keyword, `--label shipyard`, `--auto`). If a PR already exists (the worker pushed but crashed before creating the PR), create the PR against the existing branch. If PR creation fails, log it and proceed to the reap anyway — the commit is now on origin and the branch is recoverable via the GitHub UI.
4. Append the recovered PR number to `session_prs` so the cost-tracking, drain, and end-of-session summary paths all see it as a session-opened PR. Then arm auto-merge **behind the ungated-merge pre-check** ([#720](https://github.com/mattsears18/shipyard/issues/720)) — the same [issue-work §6.a](../../agents/issue-worker/issue-work.md#6-enable-auto-merge-gated-on-originating_author_trust) gate, routed through the one executable detector rather than restated: run [`detect-ungated-admin-direct-merge.sh`](../../scripts/detect-ungated-admin-direct-merge.sh); resolve `auto_merge.method` (default `squash` — never hardcode `--merge`, issue [#989](https://github.com/mattsears18/shipyard/issues/989)) via `"${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get auto_merge.method`, falling back to `squash` on an empty/invalid read; on `gated` call `gh pr merge <M> --repo <owner/repo> --auto --${AUTO_MERGE_METHOD} --delete-branch`, and on `ungated` **leave the PR OPEN and unarmed** so [drain's deferred-merge lander](./drain.md#deferred-merge-lander-merge-unarmed-green-session-prs--720) merges it on the first poll its checks are green (the `session_prs` append above is what hands it to the lander). Snapshot `state` and `autoMergeRequest` exactly as step 7 of issue-work.md directs; emit a `[reconcile-A.0.5-recovery] #<N> crash-recovered via PR #<M> (auto-merge: <...>, checks: <...>)` log line. **The `gated` branch's `--auto` call captures stderr rather than discarding it ([#850](https://github.com/mattsears18/shipyard/issues/850))** — when it matches the missing-`workflow`-OAuth-scope signature (`worker-preamble § "Auto-merge + snapshot-and-return pattern"` step 1.1, fragment [`auto-merge.md`](../../skills/worker-preamble/auto-merge.md), issue [#812](https://github.com/mattsears18/shipyard/issues/812)) it logs `[reconcile-A.0.5-recovery] PR #<M> auto-merge arm blocked — gh token lacks workflow scope` — append `<M>` to the session-local [`workflow_scope_blocked_prs`](../do-work.md#orchestrator-state) list on that line exactly as [step A.1's `shipped` handler](#a1-parse-the-return-string) already does from a worker's return string, so a crash-recovered PR's arm failure reaches the same end-of-session banner instead of vanishing into the `2>/dev/null` this branch used before.

   **Why this site must gate, and why it must not block.** A crash-recovered PR is the **least-validated diff in the system** — the dirty-worktree path auto-commits with `--no-verify` (the pre-commit gate may be exactly what hung the worker), so CI is quite literally the only thing that ever inspects it. Arming `--auto` on an ungated repo lands that unvalidated diff on the default branch immediately, and because every recovery step is fire-and-forget (`2>/dev/null || true`) it does so **silently**. But this runs on the orchestrator's reconcile hot path, so the worker-style blocking `gh pr checks --watch` is not available — a multi-minute block here stalls every in-flight dispatch. Deferring to drain's lander gates the merge on green without blocking anything.
5. Then proceed to the reap. The recovery does not skip the reap — the worktree is still a crashed agent's directory and needs to be cleaned up.

**Scope: recovery applies to issue-work crash returns only.** The issue number `<N>` and the branch name `do-work/issue-<N>` are both in-flight metadata for issue-work dispatches. Synthetic-divert modes (fix-main-ci, fix-failing-prs-batch) and fix-checks-only / fix-rebase dispatches use different branch-naming conventions and don't have a single issue to recover against — don't attempt recovery for them. Check the in-flight slot's `kind` field (per the [in_flight schema](../do-work.md#orchestrator-state)): if it is not `issue` (the value issue-work dispatches carry), skip the recovery check and proceed directly to the reap. The issue number to recover against is the slot's `target` field.

**Fire-and-forget posture for recovery.** Every recovery step (push, PR-create, auto-merge arm, `session_prs` append) suffixes `2>/dev/null || true` or uses a `|| log_advisory; continue` pattern. A failed recovery step is not a reason to abort the reconcile turn — the reap still happens, the slot still gets released. The recovery is best-effort: if network is still down or the branch is force-pushed over by a concurrent session, the commit may be lost, but the reconcile loop continues intact. Log each recovery step's outcome at `[reconcile-A.0.5-recovery]` prefix so the operator can inspect what happened for each crashed worker.

**The reap.** Derive the worktree path from the slot's `agent_id` (still in `.in_flight.<slot-id>.agent_id` at this point — slot release is step B, which runs later). Classify the lock, then:

- `no-lock` / `dead` / `self-ancestor` → reap normally. Same shape as step B but with `--phase reconcile-A.0.5` so the audit log distinguishes the crash-recovery reap from the per-completion sweep.
- `peer-alive` → **still reap.** On a crash return the agent is non-recoverable by definition, so letting a still-alive subprocess hold the lock until step B's later pass runs is the failure mode #358 documented. The reap fires anyway and the audit-log entry records `classification: "peer-alive"` so the operator can see the override happened; `git worktree unlock` + `git worktree remove --force` succeed regardless of subprocess state. See [RATIONALE → A.0.5 peer-alive force-reap](../do-work-RATIONALE.md#a05-peer-alive-force-reap-771) for why this remains independently load-bearing alongside step B's own force-reap.

**Skip silently on clean terminal returns** — when the prefix check passes (`shipped` / `green` / `noop:` / `blocked` / `rebased` / `reaped:`), do NOT run this step. Step B's per-completion reap is the right path for clean returns; running A.0.5 too would double-call into `classify-lock` for the common case and waste tool calls. The skip is a no-op — proceed directly to A.1.

**Extracted to [`scripts/crash-recovery-reap.sh`](../../scripts/crash-recovery-reap.sh) (issue [#1291](https://github.com/mattsears18/shipyard/issues/1291), the deliberately-deferred follow-up to #1289) — the block below is a translation, not a rewrite.** At ~420 lines (crash-recovery reap, and an embedded version-bump helper function) this was by a wide margin the single largest and most complex block in the whole corpus — the exact "too large to do safely in one PR" case #1289's own scope guidance sanctioned deferring at the time, the same judgment #1277's worker exercised for the two blocks #1289 itself went on to resolve. The script's own header comment restates the two invariants that govern any future edit here — never reap before inspecting, and the is_terminal gate is a genuine no-op path, not a shortcut — and preserves every recovery branch, every fire-and-forget guard, and every log-line prefix exactly as they read here before extraction. `${a05_bump_applied:+...}` in the dirty-worktree commit message is a pre-existing bug carried over unchanged (it checks non-empty, not `= true`, so the "release bump" suffix appears even when no bump was applied, since `a05_bump_applied` is always the literal string `"true"` or `"false"`) — tracked as a separate follow-up rather than fixed in this extraction, per the "don't change behavior while reshaping" rule.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# The agent's last-line return text from the harness notification, and the
# harness task-notification's own status field ("completed" or "failed") —
# the orchestrator already has both in working memory for A.1's parse
# below. slot-id/agent-id/repo/slot-kind/slot-issue are the same
# .in_flight.<slot-id> fields and dispatch-target values used throughout
# this file's other reap sites.
crash_result=$("${CLAUDE_PLUGIN_ROOT}/scripts/crash-recovery-reap.sh" reap \
  --repo <owner/repo> \
  --slot-id <slot-id> \
  --agent-id <agent-id> \
  --slot-kind "${.in_flight[<slot-id>].kind}" \
  --slot-issue "${.in_flight[<slot-id>].target}" \
  --return-text "<the agent's last-line return text, trimmed>" \
  --harness-status "<the harness task-notification's status field>")
```

Parse `crash_result` — either `terminal=true` (clean terminal return; nothing else ran — no reap, no recovery, no side effect of any kind, matching "Skip silently on clean terminal returns" above; proceed directly to A.1) or `terminal=false worktree_path=<path> worktree_name=<name> classification=<c-or-empty> lock_pid=<pid-or-empty> session_id=<sid-or-unknown> recovered_pr=<M-or-empty>` (a crash/narrative-non-terminal/harness-failed return; the script already ran the full pre-reap recovery and force-reaped the worktree). On `terminal=false` with a non-empty `recovered_pr`, append it to `session_prs` — that array is orchestrator in-session working memory, not something a stateless script invocation can own — so the cost-tracking, drain, and end-of-session summary paths all see it as a session-opened PR (mirrors step A.1's `session_prs+=` for a `shipped` return). Hold onto every other field for the separate verify call and the wasted/stalled bookkeeping immediately below.

    **Verify the reap above actually happened — as its OWN, separate Bash tool call ([#1274](https://github.com/mattsears18/shipyard/issues/1274)).** Skip this call entirely when `crash_result` was `terminal=true` — there was no reap to verify. The `2>/dev/null || true` inside the script is fire-and-forget against an ordinary filesystem race, but it cannot surface a classifier denial: when Claude Code's auto-mode permission classifier denies the reap call outright (a real, reproduced outcome against `.claude/worktrees/agent-*` — see the issue), the ENTIRE Bash tool call is refused before any of its own code runs, so no audit line is ever written and the denial is indistinguishable from success to anything that only inspects this call's own exit path. A verification step written *inside* the same call would never run either — it has to be a genuinely separate call the orchestrator issues next, regardless of what the reap call above returned. This one performs no destructive operation (a read plus, at most, an audit-log JSONL append), so it should never itself be denied. Substitute the literal `worktree_path` / `worktree_name` / `classification` / `lock_pid` / `session_id` values parsed from `crash_result` above (shell variables don't survive across Bash tool calls, but the orchestrator composing this call still has them):

    ```bash
    CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
    export CLAUDE_PLUGIN_ROOT
    if [ -e "$worktree_path" ]; then
      "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
        --action reaped-failed \
        --worktree-path "$worktree_path" \
        --worktree-name "$worktree_name" \
        --session-id "${session_id:-unknown}" \
        --classification "$classification" \
        --reason "reap-attempt-unverified — possible classifier denial (#1274)" \
        --lock-pid "$lock_pid" \
        --phase "reconcile-A.0.5" 2>/dev/null || true
      echo "[reconcile-A.0.5] worktree still present after reap attempt — reaped-failed recorded (#1274); will surface in end-of-session Cleanup line"
    fi
    ```

    Skip the block below too when `crash_result` was `terminal=true` — both the wasted-dispatch and stalled-dispatch bookkeeping only apply to an actual crash-recovery reap. `recovered_pr` here is the field parsed from `crash_result` above; `harness_status` / `slot_issue` / `slot_kind` are the same literal values already passed as `--harness-status` / `--slot-issue` / `--slot-kind` to the script call. Both `stalled_dispatches` and the wasted-dispatch counters are orchestrator in-session working memory — not something the stateless script invocation can own — so they're recorded here, not inside the script:

    ```bash
    # Wasted-dispatch accounting (#529). A crash-like / narrative-non-terminal
    # return that left NO recoverable work (no committed-but-unpushed branch,
    # no dirty working tree → recovered_pr empty) is a fully-wasted dispatch:
    # the worker armed a background waiter / returned a progress narrative and
    # produced zero output, so this reap fully discards it and step C will
    # re-dispatch the issue from scratch. Surface its cost in the end-of-session
    # summary's `Wasted dispatches (#529)` line rather than absorbing it
    # silently. A return that DID leave recoverable work (recovered_pr set above)
    # produced shippable output and is NOT counted. Tokens come from the A.0
    # attribution already computed for this dispatch.
    if [ -z "${recovered_pr:-}" ]; then
      # ${A05_DISPATCH_TOKENS} is the `total_tokens` the A.0 attribution
      # extracted from this dispatch's <usage> block earlier in the turn
      # (0 if the block was absent — the rarer full-payload-missing case).
      wasted_narrative_dispatches=$(( ${wasted_narrative_dispatches:-0} + 1 ))
      wasted_narrative_tokens=$(( ${wasted_narrative_tokens:-0} + ${A05_DISPATCH_TOKENS:-0} ))
      echo "[reconcile-A.0.5] wasted dispatch (#529): non-terminal narrative, no recoverable work; counted (total now ${wasted_narrative_dispatches})"
    fi

    # Stalled-dispatch ledger (#838/#833) — record every reap this block
    # performs, mirroring dispatch_denials (#718) / operator_denials (#746).
    # This is the single append point for the crash-recovery fallback path
    # (both a genuine crash AND a resume-cap-exhausted second stall land
    # here); the "resumed" outcome is appended separately at the resume
    # path's own step 4, since a resume returns early and never reaches
    # this block. Distinguish trigger and outcome:
    stalled_trigger="non-terminal-return"
    [ "$harness_status" = "failed" ] && stalled_trigger="harness-failed"
    if [ -n "${recovered_pr:-}" ]; then
      stalled_outcome="handed-back"
    else
      stalled_outcome="dropped-clean"
    fi
    stalled_dispatches+=("{\"target\":\"#${slot_issue:-unknown}\",\"mode\":\"${slot_kind:-unknown}\",\"trigger\":\"${stalled_trigger}\",\"outcome\":\"${stalled_outcome}\",\"resumed_pr\":${recovered_pr:-null},\"detected_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}")
    echo "[reconcile-A.0.5] stalled_dispatches entry recorded: target=#${slot_issue:-unknown} trigger=${stalled_trigger} outcome=${stalled_outcome}"
    ```

    **Mirror the same entry to the durable session-state file** ([#1302](https://github.com/mattsears18/shipyard/issues/1302)) via the typed `record-stall` subcommand — a single-entry, all-scalar-args call, never a hand-built `.stalled_dispatches = [...]` `--set` literal (that shape is exactly what got denied outright by Auto Mode's classifier in the #1302 repro). Fire-and-forget: never block this turn on it.

    ```bash
    CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
    export CLAUDE_PLUGIN_ROOT
    RESUMED_PR_ARG=()
    [ -n "${recovered_pr:-}" ] && RESUMED_PR_ARG=(--resumed-pr "$recovered_pr")
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" record-stall \
      --session-id "$session_id" --expected-repo "<owner/repo>" \
      --target "#${slot_issue:-unknown}" --mode "${slot_kind:-unknown}" \
      --trigger "$stalled_trigger" --outcome "$stalled_outcome" \
      "${RESUMED_PR_ARG[@]}" \
      2>/tmp/do-work-record-stall-err.log \
      || { echo "[session-state] record-stall denied or failed: $(cat /tmp/do-work-record-stall-err.log)"; session_state_degraded_since="${session_state_degraded_since:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }
    ```

    If this call is itself denied or fails, log the advisory and hold the session-local `session_state_degraded_since` timestamp per [step E's `state=degraded` definition](#e-invariant-line-end-of-every-steady-state-turn) — do not retry, do not treat it as a reason to skip the working-memory `stalled_dispatches` append above.

**Fire-and-forget discipline.** Every command suffixes `2>/dev/null` and / or `|| true` so a filesystem race (the worktree was already reaped by a concurrent path, the lock file is gone, etc.) cannot abort the reconcile turn. If the reap silently fails, step B's per-completion sweep is the next safety net and end-of-session cleanup is the ultimate one. The same discipline applies to the pre-reap recovery steps — a failed push or PR-create is logged but never blocks the reconcile turn.

**cwd-anchor-before-reap invariant (issue [#497](https://github.com/mattsears18/shipyard/issues/497)).** Every reap block in this file — A.0.5 here, the [A.1 `shipped`-immediate reap (#282)](#a1-parse-the-return-string), [step B's per-completion reap (#334)](#b-release-the-slot), and [step C 2d's pre-dispatch reap (#368)](#c-dispatch-a-replacement-if-work-remains--mandatory-action) — opens with a `cd "${STABLE_DIR:-/}"` that anchors the shell to a stable directory **before** any `git worktree remove --force` / `git worktree prune` runs. The hazard it closes: the harness can leak the orchestrator's Bash-tool cwd into the very `agent-*` worktree the block is about to remove (the same `isolation: "worktree"` cwd-leak class as [#452](https://github.com/mattsears18/shipyard/issues/452) / [#477](https://github.com/mattsears18/shipyard/issues/477)). Once `git worktree remove --force` deletes that directory, **every** subsequent bare git command in the same block — the `prune`, any follow-up `fetch`/`log` — dies with `fatal: Unable to read current working directory`, silently half-failing the reap (and, on the reconcile turn, skipping the post-merge CI watch — exactly the `merged-direct-ungated` path where that watch matters most). The anchor must be derived **cwd-independently** via the #477 porcelain idiom (`git worktree list --porcelain`'s `orchestrator-*` entry, falling back to the first `worktree ` entry = the primary), and it must run **while cwd is still valid** — i.e., before the remove, not after. Note that `git rev-parse --show-toplevel` can NOT be used to recover a block whose cwd is *already* deleted (git resolves its own cwd before reading anything, so it fails first); the `cd` therefore has to pre-empt the deletion rather than react to it. `cd /` is the last-resort floor — any extant directory works, since the reap itself operates on absolute paths.

**Session-id derive in reap blocks (issue [#548](https://github.com/mattsears18/shipyard/issues/548)).** Each reap block additionally derives `SESSION_ID` cwd-independently *after* the `STABLE_DIR` cd anchor. This is a **separate** concern from the filesystem anchor: the cwd anchor prevents `git worktree remove` from corrupting the shell's cwd; the session-id derive prevents the reap's `--session-id` from coming up empty when cwd leaked to an agent worktree (which has no `.shipyard-session-id` stash). The reap blocks pass `--session-id "${SESSION_ID:-unknown}"` so the audit-log entry still lands (with the `unknown` sentinel visible in the log) even when the derive fails, rather than cascading an exit-64 that reads as silent success.

**Interaction with step B.** Step B still fires on every completion path — A.0.5 does NOT replace it. The duplicate-reap is harmless: the `reap` helper's `git worktree remove --force` against a path A.0.5 already removed is a silent no-op. The point of A.0.5 is to take the reap action *earlier in the turn* on crash-like returns — closing the window sooner than waiting for step B's own pass (which, per [#771](https://github.com/mattsears18/shipyard/issues/771), now also force-reaps `peer-alive` rather than deferring it) — not to remove the per-completion sweep.

**Audit-log shape.** Entries this step writes carry `"phase":"reconcile-A.0.5"` so an operator inspecting `~/.shipyard/reap-audit.jsonl` can distinguish crash-recovery reaps from step B's per-completion sweep (`"phase":"steady-state-B-completion"`), the A.1 shipped-immediate reap (`"phase":"steady-state-A1-shipped"`), the setup-3b stale-worktree pass (no `phase`), and the cleanup-summary end-of-session sweep (no `phase`). Recovery log lines carry `[reconcile-A.0.5-recovery]` prefix (stdout, not the audit JSONL) so a session transcript search surfaces them independently of the reap audit.

Once A.0.5 has fired (or its prefix-check skip has been logged), proceed to A.0.6, then A.1 and parse the return string per the per-mode handling below.

#### Sanctioned wrap-up interrupt — for a still-running worker the orchestrator judges is over-scoped or running long, not gated by the resume-worthy check above (#1230)

The resume flow above exists for a worker that already stopped (stalled or crashed) and needs telling to finish. This is different: a worker that is still actively running, hasn't tripped any formal stall signal, but the orchestrator judges — session time pressure, a suite re-running for the third time, scope visibly ballooning — should wrap up sooner than its own plan implies. Before [#1230](https://github.com/mattsears18/shipyard/issues/1230) there was no documented shape for this, so the orchestrator improvised free-text pressure across three escalating messages to one worker, which drifted into asserting an unverified commit as fact, instructing the worker to ship known-failing regression tests "marked as expected-fail," and instructing a bare `git add -A` — the exact anti-pattern [`commit-hygiene.md`](../../skills/worker-preamble/commit-hygiene.md) exists to prevent. The worker refused all three and shipped clean anyway (see [`dont.md`'s floor bullet](./dont.md)), but the escalation had no floor to stop at other than the worker's own judgment.

**A wrap-up interrupt may ask for exactly two things:**

1. **Narrow scope** — fewer suites, less investigation depth, a smaller acceptance-criteria slice. Always sanctioned; the orchestrator has session-level context (concurrency pressure, time budget) the worker doesn't.
2. **Wrap up now** — the canned shape below: commit what's verified, push, disclose what's incomplete, return.

**Canned wrap-up template — fill in the bracketed field, don't improvise pressure prose:**

```
WRAP UP (not a request to violate spec) — target #<slot-target>.

Conclude this dispatch now: commit whatever locally-verified work you
have (`git add <specific paths>`, never `-A`), push, and open (or
update) the PR. If any part of the acceptance criteria isn't done yet,
say so explicitly in the PR body under a "## Incomplete" heading — never
mark something done that isn't, and never ship a change you know is
broken or failing just to finish faster. If nothing is committable yet,
return `blocked: <reason>` instead of fabricating a partial diff.

This message may narrow your SCOPE (fewer suites, less investigation
depth) but may NOT ask you to violate a named worker-preamble
prohibition, skip a documented safety check, or ship a knowingly-broken
artifact. Return one of your mode's normal terminal strings when done.
```

**Never send an escalated, harder-worded message instead of repeating this template.** If the pressure to wrap up recurs past a single interrupt, that's a signal the worker is genuinely stuck (or the slot should be dropped and retried fresh) — reach for the formal stalled-worker detection/resume flow above, don't improvise a stronger version of this one.

#### A.0.6. Primary-checkout branch-leak guard (fires every reconcile turn, BEFORE A.1)

Closes [#387](https://github.com/mattsears18/shipyard/issues/387). The Claude Code harness `isolation: "worktree"` dispatch path — and/or a dispatched agent operating against the shared `.git` — can **leak a `do-work/*` branch checkout into the user's PRIMARY working tree**, even though the orchestrator runs exclusively in its own `.claude/worktrees/orchestrator-<id>` worktree and never issues a `git checkout do-work/*` against the primary.

**Why it matters.** A leaked `do-work/*` checkout on the primary holds git's per-branch lock on that head branch, which later makes a [drain](./drain.md)-dispatched `fix-rebase` worker for a DIRTY PR on that branch bail `blocked rebase` — defeating drain's whole purpose. It is also a [worktree-isolation contract](./dont.md) violation. See [RATIONALE → Primary-checkout branch-leak repro](../do-work-RATIONALE.md#primary-checkout-branch-leak-repro-387) for the reflog evidence.

**The guard.** Root cause is harness behavior shipyard can't change, so this is a defensive assert-and-restore. Fire it every reconcile turn (here) AND at [drain entry](./drain.md#end-of-session-drain). It is **read-mostly**: the common case (primary already on the default branch) costs two `git -C` reads and writes nothing.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT

# The primary checkout is the repo root that contains .claude/worktrees/.
# Derive it INDEPENDENT of cwd (issue #452): `git rev-parse --show-toplevel`
# returns whatever worktree the shell's cwd is in, and the harness can
# silently relocate the orchestrator's cwd into a *dispatched agent's*
# `agent-*` worktree on a reconcile turn (same class of harness env-leak as
# #387/#322/#354, but hitting the orchestrator's own cwd). A cwd-derived
# strip that only handles `orchestrator-*` then leaves PRIMARY_CHECKOUT
# pointing at the agent worktree, and this guard mutates the wrong tree
# while emitting a phantom restore line. `git worktree list --porcelain`'s
# FIRST `worktree ` entry is ALWAYS the primary (the main working tree),
# regardless of which linked worktree the cwd happens to be in — all linked
# worktrees share one worktree list. Fall back to the cwd-strip only if the
# porcelain read comes up empty (non-worktree layout). Read-only `git -C`.
PRIMARY_CHECKOUT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
if [ -z "$PRIMARY_CHECKOUT" ]; then
  PRIMARY_CHECKOUT="$(git rev-parse --show-toplevel)"
  case "$PRIMARY_CHECKOUT" in
    */.claude/worktrees/orchestrator-*) PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/orchestrator-*}" ;;
    */.claude/worktrees/agent-*)        PRIMARY_CHECKOUT="${PRIMARY_CHECKOUT%/.claude/worktrees/agent-*}" ;;
  esac
fi

DEFAULT_BRANCH=$(gh repo view <owner/repo> --json defaultBranchRef -q .defaultBranchRef.name)
PRIMARY_BRANCH=$(git -C "$PRIMARY_CHECKOUT" symbolic-ref --short -q HEAD 2>/dev/null || echo "<detached>")

if [ "$PRIMARY_BRANCH" != "$DEFAULT_BRANCH" ]; then
  # The primary leaked off the default branch. Two cases:
  if [ -z "$(git -C "$PRIMARY_CHECKOUT" status --porcelain 2>/dev/null)" ]; then
    # CLEAN tree → lossless restore. Move it back to the default branch and
    # fast-forward. `--ff-only` can't clobber anything (no local edits exist).
    git -C "$PRIMARY_CHECKOUT" checkout "$DEFAULT_BRANCH" 2>/dev/null \
      && git -C "$PRIMARY_CHECKOUT" pull --ff-only 2>/dev/null || true
    echo "[primary-leak] restored primary from $PRIMARY_BRANCH to $DEFAULT_BRANCH (#387)"
    primary_leak_restores=$((primary_leak_restores + 1))
  else
    # DIRTY tree → do NOT auto-restore. Uncommitted edits on the leaked
    # branch might be real user work; a checkout could strand or clobber it.
    # Surface a loud warning and skip — the operator decides.
    echo "[primary-leak] WARNING: primary checkout is on $PRIMARY_BRANCH (not $DEFAULT_BRANCH) AND has uncommitted changes; NOT auto-restoring (possible real edits). Restore manually with: git -C \"$PRIMARY_CHECKOUT\" checkout $DEFAULT_BRANCH (#387)"
    primary_leak_dirty_skips=$((primary_leak_dirty_skips + 1))
  fi
fi
```

**Counters.** Increment `primary_leak_restores` on a clean restore and `primary_leak_dirty_skips` on a dirty skip — both members of the session-local `primary_leak_counters` map (see [`orchestrator-state-reference.md`](./orchestrator-state-reference.md)). The [end-of-session summary](./cleanup-summary.md#end-of-session-summary) surfaces the combined friction count when either is non-zero (silent on quiet sessions, per the `ci_session_counters` precedent).

**Read-only against the primary — the one sanctioned exception.** [`dont.md`](./dont.md) forbids *writes* to the primary checkout. A `git -C <primary> checkout <default>` is a write to the primary's HEAD — but it is the **corrective** write that undoes a harness-leaked write, restoring the primary to the read-only-from-shipyard's-perspective state the contract assumes. It fires only when the primary is already off the default branch (the contract is already violated) AND the tree is clean (the restore is provably lossless). The dirty path never writes — it warns and defers to the human. This is the narrow carve-out `dont.md` documents; do not generalize it into "shipyard may move the primary's HEAD."

**Fire-and-forget discipline.** Every command suffixes `2>/dev/null` and / or `|| true` so a filesystem race or a primary checkout that isn't where the path-derivation expects (e.g. a non-standard worktree layout) cannot abort the reconcile turn. If the path derivation produces something that isn't a git repo, the `git -C` reads return empty / error and the guard no-ops.

**cwd-independent derivation (issue [#452](https://github.com/mattsears18/shipyard/issues/452)).** The harness can silently relocate the orchestrator's own Bash-tool cwd into a just-returned **agent's** `agent-*` isolation worktree on a reconcile turn. Always derive the primary from `git worktree list --porcelain`'s first `worktree ` entry — always the main working tree regardless of which linked worktree the cwd is in — with the cwd-strip retained only as a fallback for a layout where the porcelain read comes up empty. See [RATIONALE → Primary-checkout derivation bug (#452)](../do-work-RATIONALE.md#primary-checkout-derivation-bug-452) for the phantom-restore failure mode this replaced.

Once A.0.6 has run, proceed to A.1.

#### A.1. Parse the return string

**Worker returns reach this step as free text either way, not parsed here directly.** Under the default `Agent`-tool shape, a `mode:`-driven worker returns the free-text terminal string directly — there's nothing to translate. Under the `Workflow`-substrate alternate, the worker returns a **structured** result validated against [`schemas/worker-return.schema.json`](../../schemas/worker-return.schema.json), and that result is **translated into free text before reaching this step, not parsed here directly** — the dispatch step converts it into the exact free-text terminal string this step's vocabulary is written against, using [dispatch-rules.md's Workflow-substrate section](./dispatch-rules.md#workflow-substrate-dispatch--an-alternate-dispatch-shape-825)'s translation table (one row per mode/outcome combination). By the time control reaches this step there is exactly one return vocabulary regardless of shape — the free-text one every branch below reads. Don't re-parse a structured object here; if a translation was needed, it already happened upstream. (The translation shim was introduced with [#788](https://github.com/mattsears18/shipyard/issues/788) / [#789](https://github.com/mattsears18/shipyard/issues/789) so the whole reconcile could stay shape-agnostic during the Dynamic Workflows migration, and it's why the free-text vocabulary remains the reconcile's stable interface under either shape today.) **This is also why the optional `worktree_path` isolation check ([#1221](https://github.com/mattsears18/shipyard/issues/1221)) does not live here** — it needs the still-structured result, which only exists one step upstream, at [dispatch-rules.md step 4's translation](./dispatch-rules.md#workflow-substrate-dispatch--an-alternate-dispatch-shape-825); by A.1 it's already collapsed to free text with no `worktree_path` carried through.

**A `stalled` return is not classified here — and it is never `blocked` ([#813](https://github.com/mattsears18/shipyard/issues/813)).** A narrative, non-terminal return exhibiting *pending intent* (future tense / a numbered plan / "waiting for") is a distinct, non-terminal outcome named `stalled`, detected and handled at [step A.0.5's stalled-worker check](#a05-post-return-worktree-reap-for-crashed--narrative-non-terminal-returns-fires-before-a1s-return-string-parsing) — which runs BEFORE this step, on every reconcile turn. That check either **resumes** the same worker in place (when the worktree holds recoverable work and the per-target retry cap of 2 hasn't been hit) or falls through to A.0.5's ordinary crash-recovery/reap path (when there's nothing resumable, or the cap is exhausted). By the time this step runs, a `stalled` return has therefore already been converted into either a fresh in-flight dispatch (this turn's A.0.5 handling ends there — A.1 never sees it) or one of this step's ordinary terminal branches (typically `shipped`, via A.0.5's crash-recovery auto-commit-and-push; occasionally a plain reap with nothing to classify here, when the worktree held no diff to recover). **`stalled` must never fall through to the `blocked #<N>` branch below.** `blocked` is reserved for a worker's own deliberate, terminal `blocked: <reason>` return — conflating a pending-intent narrative with `blocked` would mislabel near-complete, resumable work (`needs-human-review` or a soft label) as a dead end, exactly the mis-handling [#813](https://github.com/mattsears18/shipyard/issues/813) identified in the spec's literal reading before this paragraph existed.

**Persist the return record before any per-mode handling below — the mechanical gate `worktree-reap.sh` enforces ([#1237](https://github.com/mattsears18/shipyard/issues/1237)).** A reap this step (or step B, or a later turn's pre-dispatch reap) issues below only succeeds when `.returned_agent_ids[<agent-id>]` is set in this session's state — proof THIS agent's own terminal return reached the reconcile, not merely that some other signal (a PR observed `MERGED`) looked like completion. A.0.5's crash-recovery reap and the end-of-session sweeps are the documented exceptions and pass `--bypass-return-check` instead, because by construction the agent they reap never reached this line. Write the record once here, for every mode, before any branch below runs:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SESSION_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" derive-session-id \
  --repo-root "$REPO_ROOT" 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
agent_id="${.in_flight[<slot-id>].agent_id}"
"${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" update --session-id "${SESSION_ID:-unknown}" \
  --set ".returned_agent_ids[\"${agent_id}\"] = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
  >/dev/null 2>&1 || true
```

Fire-and-forget, same posture as every other write-through in this file — a failed write just means a later reap fails closed (leaves the worktree for a subsequent sweep) rather than fails open. See [`worktree-reap.sh`](../../scripts/worktree-reap.sh)'s `reap` docstring and [RATIONALE → Enforcing the merged-PR-is-not-worker-done invariant](../do-work-RATIONALE.md#enforcing-the-merged-pr-is-not-worker-done-invariant-issue-1237) for the full call-site classification.

For **issue work** (`shipped` / `blocked` / `errored`):

- **shipped #<N> via PR #<M>** — checks may be `green`, `pending`, or `failing`. Record. **Append `<M>` to `session_prs`** (the set the [end-of-session drain](./drain.md#end-of-session-drain) watches). Don't act on `pending`/`failing` here — periodic triage (step D) will catch failures next time it runs.

  **Verify the armed merge method — don't trust the worker's own claim ([#989](https://github.com/mattsears18/shipyard/issues/989)).** A worker can arm auto-merge with the wrong method (`--merge` instead of the configured `--squash`, or vice versa) despite every per-mode spec resolving `auto_merge.method` before its own `gh pr merge` call — the #989 repro shows this is **intermittent**: two workers in the same session both mis-armed `mergeMethod: MERGE` while every sibling PR that session correctly armed `SQUASH`. The worker's return string never carries the armed method, so there's nothing to parse here — re-read the PR directly and correct it before moving on. Skip this check entirely for a `disposition:`/`verified:` return (no PR) and for `auto-merge: gated — external-author origin`, `auto-merge: unarmed — policy-override: <control>` ([#1088](https://github.com/mattsears18/shipyard/issues/1088) — intentionally never armed), or `auto-merge: unavailable*` (nothing armed to check).

  ```bash
  CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
  export CLAUDE_PLUGIN_ROOT
  # Re-derive the SHIPYARD_REPO_ROOT pin (issue #1059/#1064).
  SHIPYARD_REPO_ROOT=$(cat "$(git rev-parse --show-toplevel)/.shipyard-primary-root" 2>/dev/null)
  [ -z "$SHIPYARD_REPO_ROOT" ] && SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel)"
  export SHIPYARD_REPO_ROOT
  EXPECTED_METHOD=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get auto_merge.method 2>/dev/null)
  case "$EXPECTED_METHOD" in squash|merge|rebase) ;; *) EXPECTED_METHOD=squash ;; esac

  # Two direct --jq reads (never a shared snapshot piped through a second
  # jq/tr) — avoids a pipe spanning a shell command boundary. jq's own
  # ascii_downcase replaces the separate `| tr '[:upper:]' '[:lower:]'` stage.
  PR_STATE=$(gh pr view <M> --repo <owner/repo> --json state --jq '.state // empty' 2>/dev/null || echo "")
  ACTUAL_METHOD=$(gh pr view <M> --repo <owner/repo> --json autoMergeRequest \
    --jq '(.autoMergeRequest.mergeMethod // empty) | ascii_downcase' 2>/dev/null || echo "")

  if [ "$PR_STATE" = "OPEN" ] && [ -n "$ACTUAL_METHOD" ] && [ "$ACTUAL_METHOD" != "$EXPECTED_METHOD" ]; then
    echo "[merge-method-drift] PR #<M> armed with mergeMethod=${ACTUAL_METHOD} (expected ${EXPECTED_METHOD}) — correcting (#989)"
    # `gh pr merge --auto --<method>` against an ALREADY-ARMED PR is a SILENT
    # no-op (exits 0, changes nothing) — must disable the queue first, then
    # re-arm with the correct method. This is the exact disable-then-rearm
    # dance #989's repro documents; skipping the disable leaves the wrong
    # method in place with no error to signal it.
    gh pr merge <M> --repo <owner/repo> --disable-auto 2>/dev/null || true
    gh pr merge <M> --repo <owner/repo> --auto --${EXPECTED_METHOD} --delete-branch 2>/dev/null || true
    CORRECTED=$(gh pr view <M> --repo <owner/repo> --json autoMergeRequest \
      --jq '(.autoMergeRequest.mergeMethod // empty) | ascii_downcase' 2>/dev/null || echo "")
    if [ "$CORRECTED" = "$EXPECTED_METHOD" ]; then
      echo "[merge-method-drift] PR #<M> corrected to mergeMethod=${EXPECTED_METHOD}"
    else
      echo "[merge-method-drift] PR #<M> correction did NOT take (now reads '${CORRECTED}') — flagging for manual check"
      gh pr comment <M> --repo <owner/repo> --body "Auto-merge method drift detected (mergeMethod=${ACTUAL_METHOD}, expected ${EXPECTED_METHOD}) and the automatic disable-then-rearm correction did not take. Please verify the armed merge method manually before this PR lands (#989)." 2>/dev/null || true
    fi
  elif [ "$PR_STATE" = "MERGED" ] && [ -n "$ACTUAL_METHOD" ]; then
    : # Already landed via the ungated-admin-direct path or a manual gated-manual
      # merge — mergeMethod on a merged PR reflects the merge that already
      # fired, and there's nothing left to correct post-hoc. Silent no-op.
  fi
  ```

  This check runs unconditionally on every `shipped` reconcile, not just the ones whose return string looked suspicious — the whole point is that the worker's own return gives no signal either way, so the only reliable source is GitHub's own state.

  **`auto-merge: unavailable — gh token lacks workflow scope` suffix ([#812](https://github.com/mattsears18/shipyard/issues/812)) — append to `workflow_scope_blocked_prs`, don't post a per-PR advisory.** When the reconciled return carries this exact suffix (distinct from the generic `auto-merge: unavailable — needs manual merge`), append `<M>` to the session-local [`workflow_scope_blocked_prs`](../do-work.md#orchestrator-state) list in addition to the normal `session_prs` append above — everything else about the `shipped` handling (cost-tracking comment, immediate worktree reap) proceeds unchanged. Do NOT post a comment on the PR explaining the cause, and do NOT treat it as a per-PR failure needing its own remediation note — the cause is a deterministic, session-wide token precondition, so the [end-of-session summary](./cleanup-summary.md#end-of-session-summary) surfaces it exactly once for the whole list rather than repeating the same explanation on every workflow-touching PR. The PR stays OPEN and unarmed in `session_prs`; the drain phase watches it exactly like any other unarmed-but-otherwise-normal PR (it will sit pending-merge until a human runs `gh auth refresh -h github.com -s workflow` and re-arms it — this is expected, not a drain bug).

  **Local-only-CI repos: the merge gate fires at drain, not here ([#643](https://github.com/mattsears18/shipyard/issues/643)).** On a repo where the merge-blocking status is posted by a manually-run command (config `merge_gate.command` non-empty — e.g. `npm run ci:report`) rather than by cloud CI that auto-runs on push, a shipped PR's checks stay `pending` until that command runs against the PR's HEAD. Nothing about the `shipped` reconcile changes — `--auto` is armed exactly as on a cloud-CI repo — but the gate command runs **per shipped PR, paced to `merge_gate.max_unmerged_ahead`, in the [end-of-session drain](./drain.md#local-only-ci-merge-gate)**, which is where `--auto` then fires. When `merge_gate.command` is empty (the default), this is moot — cloud-CI behavior is unchanged.

  **Then post a cost-tracking comment on the resulting PR — gated on `cost_tracking.comment_on_pr` ([#855](https://github.com/mattsears18/shipyard/issues/855)).** The session-state file's `.tokens.per_pr[<M>]` bucket was populated by every `bump-tokens` call made while the worker was in flight (see [Cost-tracking write-through](./session-state-file.md#cost-tracking-write-through)). Before posting, read the effective `cost_tracking.comment_on_pr` value — same shell-out-to-`shipyard-config.sh` pattern [setup's flake-registry gate](./setup/04-backlog-divert.md#58-enforce-the-flake-registry-chronic-flake-escalation) uses for `flake_registry.enabled` — and skip the post entirely when it's `false`. This is independent of the ledger-write gate `cost-history.sh flush` enforces on `cost_tracking.enabled` (issue #855): a user might want the local `~/.shipyard/cost-history.jsonl` record but not a public, on-the-PR token/cost comment on a shared or externally-visible repo, so the two knobs are checked separately rather than one implying the other. When `comment_on_pr` is true (or unset — the schema default), read it as a Markdown body via the helper and post on the PR with edit-or-create semantics keyed on the `<!-- do-work-cost-tracking -->` sentinel:

  ```bash
  CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
  export CLAUDE_PLUGIN_ROOT
  # Re-derive the SHIPYARD_REPO_ROOT pin (issue #1059/#1064).
  SHIPYARD_REPO_ROOT=$(cat "$(git rev-parse --show-toplevel)/.shipyard-primary-root" 2>/dev/null)
  [ -z "$SHIPYARD_REPO_ROOT" ] && SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel)"
  export SHIPYARD_REPO_ROOT
  # cost_tracking.comment_on_pr opt-out (#855) — checked first, cheaply,
  # before any session-id derivation or gh call. Defaults to true (fail
  # OPEN on a config-read error) so a read failure never silently swallows
  # the comment the schema default says should post.
  COMMENT_ON_PR=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get cost_tracking.comment_on_pr 2>/dev/null)
  if [ "$COMMENT_ON_PR" = "false" ]; then
    echo "[cost-tracking] cost_tracking.comment_on_pr=false; skipping PR comment for PR #<M> (#855)"
  else
  # Derive the session id cwd-independently (immune to the #477 cwd-leak that
  # fires on reconcile turns — see A.0 required preamble and setup.md §0.55).
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
  SESSION_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" derive-session-id \
    --repo-root "$REPO_ROOT" 2>/dev/null)
  [ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
  if [ -z "$SESSION_ID" ]; then
    echo "[session-id-derive] empty — skipping A.1 cost-comment post; check for #477 cwd-leak (#548)"
  else
  # 1. Read the cost summary as a Markdown comment body.
  BODY=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" read-tokens \
    --session-id "$SESSION_ID" --pr <M> --format comment)

  # 2. Look up the existing sentinel comment (if any) so we can edit
  # in-place instead of posting duplicates each time the cost grows
  # (e.g. across a fix-checks-only follow-up dispatch on the same PR).
  # Use the REST listing endpoint, not `gh pr view --json comments` —
  # the latter returns each comment's GraphQL node-id (e.g.
  # `IC_kwDONOH3Js8AAAAB...`), which the PATCH endpoint below does NOT
  # accept; PATCH requires the numeric REST comment id that
  # `/repos/<o/r>/issues/<M>/comments` returns as `.id`. See #264.
  EXISTING=$(gh api "/repos/<owner/repo>/issues/<M>/comments?per_page=100" \
    --jq '[.[] | select(.body | startswith("<!-- do-work-cost-tracking -->"))][0].id // empty')

  if [ -n "$EXISTING" ]; then
    gh api -X PATCH "/repos/<owner/repo>/issues/comments/$EXISTING" \
      -f body="$BODY" >/dev/null
  else
    gh pr comment <M> --repo <owner/repo> --body "$BODY" >/dev/null
  fi
  fi
  fi
  ```

  The hook fires on every `shipped` reconcile — issue-work, fix-main-ci, fix-failing-prs-batch. On a synthetic-divert `shipped main-ci-fix` / `shipped pr-batch-fix` return there's no originating issue, but the PR still gets the comment via the same `read-tokens --pr <M>` slice. For `external`-author PRs that are gated on `needs-human-review`, post the comment regardless — the cost is real whether or not the PR auto-merges. The edit-in-place semantics mean a follow-up fix-checks-only dispatch on the same PR will *update* the existing sentinel comment with the cumulative cost, not stack duplicate comments.

  **Don't post a separate cost comment on the originating issue.** GitHub's auto-close mechanism links the issue to the closing PR; readers click through to the PR to see the cost. Posting on both surfaces double-counts in feed scans and creates two places that have to stay consistent across fix-checks follow-ups. The PR is the single source of truth for this session's cost on the artifact.

  If either `gh` call errors (rate limit, permission denied), log `[cost-comment] PR #<M> post failed: <reason>; continuing` and proceed. Cost-tracking is observational — never block dispatch on a comment-post failure.

  **Then reap the agent's worktree immediately — don't wait for end-of-session cleanup.** Closes [#282](https://github.com/mattsears18/shipyard/issues/282): the worker's local branch `do-work/issue-<N>` and worktree directory lingering until end-of-session cleanup is what locks subsequent same-session fix-rebase dispatches out of `git switch <head>` (git enforces one-worktree-per-branch). Reaping immediately on `shipped` frees the PR's head branch right when the merge train might next want to rebase it. The worker has already returned (this is what `shipped` IS), so its worktree is no-longer-live by definition — the classify-lock pass still runs as defensive belt-and-suspenders, but the expected classification is `dead` (process gone) or `self-ancestor` (lock held the orchestrator's PID per the harness convention).

  **Force-reap even on `peer-alive` here.** A `shipped` return is the worker's terminal contract: the agent subprocess has exited, the PR is on the remote, the worktree has no further purpose — deferring on `peer-alive` here would cause the same drain-phase `blocked: branch locked in another worktree` failures A.0.5 exists to avoid (see [§A.0.5](#a05-post-return-worktree-reap-for-crashed--narrative-non-terminal-returns-fires-before-a1s-return-string-parsing)). Audit the reap with `--classification peer-alive-force` so the override is visible in `~/.shipyard/reap-audit.jsonl`. See [RATIONALE → Force-reap on peer-alive (#576/#771)](../do-work-RATIONALE.md#force-reap-on-peer-alive-576771) for the failure-mode history.

  **Extracted to [`scripts/shipped-immediate-branch-reap.sh`](../../scripts/shipped-immediate-branch-reap.sh) (issue #1289) — the block below is a translation, not a rewrite.** The inline form was a `for wt_dir in .../agent-*` loop wrapping several pipes — the same shapes the worktree-isolation guard refuses post-relocation. Same family as dispatch-rules.md §2d's and drain.md's extractions; the script's own header comment restates why this site deliberately skips the #832 in-flight guard (it targets exactly one worktree, unique per issue number by construction) and preserves every classification branch exactly as it read here before extraction:

  ```bash
  CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
  export CLAUDE_PLUGIN_ROOT
  reap_result=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipped-immediate-branch-reap.sh" reap --issue <N>)
  ```

  Parse `reap_result` — either `reaped=false session_id=<id>` (no matching worktree found) or `reaped=true worktree_path=<path> worktree_name=<name> classification=<local_classification> lock_pid=<pid> session_id=<id>`. On `reaped=true`, hold onto the values for the separate verify call immediately below.

  **Verify the reap above actually happened — as its OWN, separate Bash tool call ([#1274](https://github.com/mattsears18/shipyard/issues/1274)).** Same reasoning as A.0.5's own verify step: a classifier denial of the reap call above kills the whole tool call before any code in that same call can run, so a check bundled into it would never execute either — it has to be a genuinely separate call. This one performs no destructive operation, so it should never itself be denied. Skip entirely when `reap_result` was `reaped=false`. Substitute the literal `worktree_path` / `worktree_name` / `classification` / `lock_pid` / `session_id` values parsed from `reap_result` above (shell variables don't survive across Bash tool calls, but the orchestrator composing this call still has them):

  ```bash
  CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
  export CLAUDE_PLUGIN_ROOT
  if [ -n "${worktree_path:-}" ] && [ -e "$worktree_path" ]; then
    "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
      --action reaped-failed \
      --worktree-path "$worktree_path" \
      --worktree-name "$worktree_name" \
      --session-id "${session_id:-unknown}" \
      --classification "$classification" \
      --reason "reap-attempt-unverified — possible classifier denial (#1274)" \
      --lock-pid "$lock_pid" \
      --phase "steady-state-A1-shipped" 2>/dev/null || true
    echo "[steady-state-A1-shipped] worktree still present after reap attempt — reaped-failed recorded (#1274); will surface in end-of-session Cleanup line"
  fi
  ```

  The reap and local-branch drop are **fire-and-forget** — every command suffixes `2>/dev/null` and / or `|| true` so a filesystem race (the worktree was already reaped by a concurrent path, the lock file is gone, etc.) cannot abort the steady-state loop. If the reap silently fails for any reason, end-of-session cleanup is still the safety net. The end-of-session pass is intentionally NOT removed — it remains the ultimate sweep for any agent worktree that this immediate-reap path missed (blocked / errored returns, etc.).

  **Audit-log shape.** The JSONL entries this step writes carry `"phase":"steady-state-A1-shipped"` so an operator inspecting `~/.shipyard/reap-audit.jsonl` can distinguish steady-state reaps from end-of-session reaps (which omit `phase` — see [`cleanup-summary.md`'s reap loop](./cleanup-summary.md#end-of-session-cleanup)). The `phase` suffix is appended by the `reap` helper natively (issue #284).

- **verified #<N> (bugs filed: <count>, residual: <agent-console|needs-human-review — issue left open|none — closed as verified>[, incidental PR: #<M>])** — the worker ran [§6.6's verification disposition](../../agents/issue-worker/issue-work.md#66-verification-disposition-run-the-auditor-file-bugs-disposition--without-a-pr-852): dispatched the auditor named in `verification_slice`, filed any `bug` issues for real findings, posted a verification-status comment, and dispositioned `#<N>` itself. **No *resolving* PR was opened for `#<N>` — do NOT append anything to `session_prs` on `#<N>`'s account.** Record. When `residual` is `none — closed as verified`, the worker already closed `#<N>`; no further action. Otherwise the worker already applied the `agent-console`/`needs-human-review` label and left `#<N>` OPEN — no auto-retry, `/my-turn` will surface it.

  **Optional `incidental PR: #<M>` token** ([#1044](https://github.com/mattsears18/shipyard/issues/1044)) — the fragment's narrow coverage-only exception fired: a small, non-closing (`Refs #<N>`, no closing keyword) PR landed missing test coverage. Unlike the base shape above, **DO append `<M>` to `session_prs`** — it's a real PR on the remote with its own checks/merge lifecycle and needs the same drain/summary treatment as any other session PR; the "no PR was opened" sentence above describes `#<N>`'s own resolution only, not this separate, incidental PR. `<M>`'s presence or absence has no bearing on `#<N>`'s own disposition — handle both independently.

  Reap the agent's worktree via step B (same immediate-reap path as `shipped`, since the worker's worktree held no unpushed commits either way — any incidental-PR branch was already pushed as part of opening it).

- **reaped: my worktree was reaped while I was running** — the worker's worktree was torn down mid-run by the cleanup logic. This is external-infrastructure noise, NOT a logic failure. **Do NOT add `blocked:agent`.** Instead:
  1. Log the event: `[reap-recovery] #<N> worktree reaped mid-run (last push: <hash>); re-enqueuing for fresh dispatch.`
  2. Re-add `<N>` to `raw_backlog` (deduped; if already in `ready_issues` or `in_flight`, skip — the issue is already being handled). The next dispatch cycle will pick it up with a fresh worktree.
  3. When `backlog.self_assign: true` ([#1248](https://github.com/mattsears18/shipyard/issues/1248)), remove `@me`: `gh issue edit <N> --repo <owner/repo> --remove-assignee @me 2>/dev/null || true`.
  4. Look for a `<!-- shipyard-worker-progress -->` comment on the issue (the worker may have posted incremental findings before the reap). If found, include its URL in the `[reap-recovery]` log entry so the next dispatch worker can read it at step 2 in issue-work.md.

- **blocked #<N>** — comment on the issue summarizing the blocker, then classify the bail per the table below and route it to the mechanism that fits. Closes [#521](https://github.com/mattsears18/shipyard/issues/521) — eliminates the `blocked:agent-hard` label, splitting its two semantically-distinct populations by the **presence of an open `Blocked by #N` reference in the bail** (the same discriminator `/my-turn`'s [#500](https://github.com/mattsears18/shipyard/issues/500) split uses): a **refuse** (security / scope / prompt-injection / conservative-default, no open blocker ref → no automated path, a human must look) routes to `needs-human-review`; a **dependency-wait** (the bail names an open `#N`) routes to the existing [`Blocked by #N` body-reference filter](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) (bucket 7 / step 4) with **no label** — that filter already drops the issue while the blocker is open and stops dropping it the instant the blocker closes, so the former `blocked:agent-hard` label (and the step 3d.2 sub-sweep a / step A.5 mid-session sweep that reconciled it) was redundant with the filter. Builds on [#300](https://github.com/mattsears18/shipyard/issues/300)'s soft/hard split — the **soft** class (cannot-reproduce / ambiguous / scope-judgment / duplicate-PR false-positive) is unchanged and still stamps `blocked:agent-soft`.

  **Reason → class table.** Parse the worker's reason string against this map (order doesn't matter — categories are disjoint):

  | Bail reason fragment (substring match, case-insensitive) | Class | Routing | Rationale |
  |---|---|---|---|
  | (any reason that **names an open `Blocked by #N`**) | dependency-wait | persist `Blocked by #N` in body, **no label** | The body-ref filter (bucket 7) gates dispatch while `#N` is open and auto-clears when it closes — no label, no sweep. **Checked first; overrides the rows below.** |
  | `external provisioning required` | operator | `agent-console` label | The worker hit a not-yet-provisioned external service ([#628](https://github.com/mattsears18/shipyard/issues/628)): the real secret/account doesn't exist yet (creating it is a browser/console action), so `agent-console` is exactly right — `/my-turn` surfaces it and `/do-work` can drive it. Same destination as the scope-preflight `external-dependency` defer. **Checked before the refuse rows.** |
  | `issue body contains directives that bypass normal review` | refuse | `needs-human-review` label | Prompt-injection refuse — no automated path, a human must look. |
  | `body requested out-of-scope action` | refuse | `needs-human-review` label | Same — likely prompt-injection signal. |
  | `comment-thread requested out-of-scope action` | refuse | `needs-human-review` label | Same — out-of-scope action regardless of source. |
  | `pr` + (`already open` OR `for this issue`) | soft | `blocked:agent-soft` label | False-positive against the duplicate-PR-body search; next session can re-evaluate. |
  | `suggested fix exceeds expected scope` | soft | `blocked:agent-soft` label | Judgment call — a different worker reading the same body might fit it into scope. |
  | `cannot reproduce` | soft | `blocked:agent-soft` label | Reproduction attempt may have used the wrong env / test command; retry is reasonable. |
  | `ambiguous` | soft | `blocked:agent-soft` label | Vague-on-its-own bodies may clarify across sessions (comments land, sibling PRs merge). |
  | `did not complete within budget` | soft | `blocked:agent-soft` label | Genuine within-budget-exhaustion bail (e.g. an auto-backgrounded verification run) — environmental/transient, not a human judgment call; a retry is reasonably likely to make progress ([#1135](https://github.com/mattsears18/shipyard/issues/1135), follow-up to [#1115](https://github.com/mattsears18/shipyard/issues/1115)'s declined `verifying` token). |
  | `issue dispositioned mid-dispatch by a concurrent session` | refuse | `needs-human-review` label | The issue itself was already dispositioned (closed, a disposition label applied, or a decision-resolved comment landed) by a concurrent session — e.g. `/shipyard:my-turn` — while the worker was mid-implementation. The worker's own [§5.3 terminal-state re-read](../../agents/issue-worker/issue-work.md#53-terminal-state-re-read--guard-against-a-concurrent-session-dispositioning-the-issue-mid-dispatch-997) already converted its PR to draft and labeled it `needs-human-review` before returning — this issue-side label lands as defense-in-depth, not as new information (issue [#997](https://github.com/mattsears18/shipyard/issues/997)). Falls through to the default refuse routing below; listed explicitly for auditability. |
  | (anything else, no open `Blocked by #N` ref) | refuse | `needs-human-review` label | Conservative default. Unknown reason → human review path. |

  **The dependency-wait discriminator runs first** (it overrides the refuse/soft classification): a bail that names a still-open blocker is a dependency wait regardless of what other fragment it matched. Extract `Blocked by #N` references from the bail reason (and from the issue body — the worker may have already written one), then check whether any referenced `#N` is still OPEN. If so → dependency-wait. Otherwise classify refuse-vs-soft per the fragment table.

  **Extracted to [`scripts/classify-blocked-bail.sh`](../../scripts/classify-blocked-bail.sh) (issue #1289) — the block below is a translation, not a rewrite.** The dependency-wait discriminator's blocker-reference resolution is a data-dependent `for b in $blocker_refs` loop with an internal `gh issue view || gh pr view` fallback per candidate, plus several pipe chains elsewhere in the classification — the same shapes the worktree-isolation guard refuses post-relocation. The script performs the full classification AND its associated label/comment mutations (the two are the same atomic decision in the original block); every branch — dependency-wait, operator, refuse-vs-soft, and the #1279 decision-freshness re-gate suppression — is preserved exactly as it read here before extraction:

  ```bash
  CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
  export CLAUDE_PLUGIN_ROOT
  bail_class=$("${CLAUDE_PLUGIN_ROOT}/scripts/classify-blocked-bail.sh" classify \
    --repo <owner/repo> --issue <N> --reason "<the worker's reason string, lowercased>")
  ```

  Parse `bail_class` — one of five shapes: `class=dependency-wait open_blocker=<N>`, `class=operator label=agent-console`, `class=soft label=blocked:agent-soft now=<ISO8601>`, `class=refuse label=needs-human-review`, or `class=refuse label=none reason=decision-already-recorded-after-escalation`. On `class=soft`, record the in-memory bookkeeping the script itself cannot hold: `session_blocked_soft[<N>] = <now>` — that map is orchestrator in-session working memory (the same class of conceptual state as `session_prs` / `in_flight` throughout this spec, not something a stateless script invocation can persist), read by step C's lightweight backlog re-check to skip issues within `blocked_agent.soft_retry_minutes` of their last bail (default 30). The other four outcomes need no further orchestrator action — the script already applied the matching label and posted the matching comment.

  A refuse routes to `needs-human-review` (not a dedicated block label) because it has no automated recovery path — a human must look, same semantics `/my-turn` already surfaces. **Why a provisioning bail routes to `agent-console`:** `external provisioning required` is a concrete browser/console action, not a decision, and not auto-recoverable — same destination as the scope-preflight `external-dependency` defer. A dependency-wait needs no label because the `Blocked by #N` body-reference filter ([setup.md step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) / bucket 7) is already the complete mechanism. Soft labels don't survive to next session (setup.md step 3d.2 sub-sweep c clears them at every session start) and gate only in-session re-dispatch via `session_blocked_soft[<N>]` for `blocked_agent.soft_retry_minutes` (default 30). See [RATIONALE → Blocked-reason routing table rationale](../do-work-RATIONALE.md#blocked-reason-routing-table-rationale-521628) for the full reasoning behind each routing choice.

  **The `<!-- do-work-agent-refuse -->` marker on the refuse comment is a provenance discriminator for `/my-turn`** (issue [#1091](https://github.com/mattsears18/shipyard/issues/1091)) — it lets the human-review render cite the actual bail reason without re-deriving it from prose. It is NOT applied to the soft-block comment (that lands on `blocked:agent-soft`, not `needs-human-review`, and auto-clears every session — no marker needed).

  **The freshness check inside the refuse branch above is a re-escalation guard, not a substitute for reading the thread ([#1279](https://github.com/mattsears18/shipyard/issues/1279)).** It only trips when a PRIOR `<!-- do-work-agent-refuse -->` comment exists on this issue AND a `<!-- shipyard-resolve-decisions -->` / `<!-- do-work-decision-resolved -->` sentinel landed after it — i.e. this is a *repeat* of an escalation a human already answered, not this issue's first refuse. A decision-resolved comment that predates the prior escalation (or an issue with no prior refuse at all) does not suppress anything; see [`decision-freshness-check.md`](../../skills/worker-preamble/decision-freshness-check.md)'s "Guard the other direction" for why an issue can legitimately need human input twice. The two sentinels are already treated as equivalent elsewhere in this repo — [`setup/06-scope-preflight.md`'s Signal B](./setup/06-scope-preflight.md) established the same equivalence for the scope-preflight diagnosis path (issue [#962](https://github.com/mattsears18/shipyard/issues/962)) — this reuses that fact rather than introducing a third marker.

- **errored** — record in the session log, continue.

For **fix-checks work** (`green` / `noop` / `blocked`):

**Fabrication pre-check — run on every fix-checks-only return before parsing into any of the branches below ([#1205](https://github.com/mattsears18/shipyard/issues/1205)).** The live spot-check below (under the `green #<M>` bullet) is deliberately scoped to `green`/`noop` only — `pending` and `dirty` are documented as honest, non-overclaiming dispositions and are NOT second-guessed by design ([#985](https://github.com/mattsears18/shipyard/issues/985)/[#987](https://github.com/mattsears18/shipyard/issues/987)/[#1015](https://github.com/mattsears18/shipyard/issues/1015)). But a worker willing to fabricate a `green` citation is equally capable of fabricating a plausible-looking `pending`/`dirty` one, and those are trusted at face value — so the live-verify asymmetry alone leaves a gap for exactly the disposition class the API-cost tradeoff was designed to skip. Two independent occurrences in one evening (session `do-work-20260810T221957Z-35757` against PR #1199; session `do-work-20260811T001132Z-67304` against PR #1209 — the second citing a rollup-verified timestamp ~2 minutes AFTER the reconcile itself observed ground truth, alongside prose in the *same* return admitting "the CI may be running... should resolve once the new run completes") showed the tell doesn't need an API call to catch. Before branching on the disposition below, run this two-part check against the worker's **raw return** (its full final message, not just the terminal line):

1. **Future-timestamp check.** Extract every `YYYY-MM-DDTHH:MM:SSZ`-shaped timestamp the return cites and compare each against `date -u +%Y-%m-%dT%H:%M:%SZ` read right now. Any cited timestamp strictly later than the current time cannot be a real observation — there was nothing to observe yet.
2. **Self-contradiction check.** Scan the return for hedging language sitting alongside a definitive `green`/`noop` claim — phrases like `may be running`, `should resolve`, `once the ... (run|CI) completes`, `may still`, `could still`, `hasn't (finished|completed)`. A `green`/`noop` return whose own prose admits checks might still be in flight is self-contradictory on its face, independent of any live check.

**If either check trips**, do not take the claimed disposition (whichever one it is — `green`, `noop`, `pending`, or `dirty`) at face value. Run the same live `gh pr view` spot-check the `green` path below already runs (latest-per-name rollup + `mergeStateStatus`) and classify off that live result instead of the worker's claim. Log `[fix-checks-fabrication-tell] PR #<M> return failed pre-check (<future-timestamp|self-contradiction>): "<offending fragment>" — forcing live verification regardless of claimed disposition.` This costs one extra `gh pr view` call only on the rare return that trips a tell — every ordinary honest return (the overwhelming majority) is unaffected, and the documented `pending`/`dirty` non-second-guessing behavior below is unchanged when neither check trips.

**A third, structural tell — scoped to `green`/`noop` only, since only those returns carry a citable SHA ([#1211](https://github.com/mattsears18/shipyard/issues/1211)).** See the "Head-SHA citation check" under the `green #<M>` bullet below: a `green`/`noop` return's `@<head-SHA>` token is mechanically compared against the PR's live `headRefOid` on the SAME `gh pr view` call the trust-but-verify spot-check already makes. This doesn't widen `pending`/`dirty`'s non-second-guessing default (neither carries a SHA to check) — it's an additional, cheap, string-comparison-only integrity signal on top of the two prose-scanning checks above, for the one disposition pair that's already unconditionally live-verified regardless.

- **green #<M>** / **noop: already green #<M>** — PR is fine, continue. (PR is already in `session_prs` from whenever it was first opened or first fixed — no re-add needed.) **Refresh the cost-tracking comment** for `<M>` so the cumulative total includes this fix-checks dispatch's tokens (A.0 bumped them into `.tokens.per_pr[<M>]`). Same edit-or-create semantics as the `shipped` hook:

  ```bash
  CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
  export CLAUDE_PLUGIN_ROOT
  # Derive the session id cwd-independently (immune to the #477 cwd-leak that
  # fires on reconcile turns — see A.0 required preamble and setup.md §0.55).
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
  SESSION_ID=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" derive-session-id \
    --repo-root "$REPO_ROOT" 2>/dev/null)
  [ -z "$SESSION_ID" ] && SESSION_ID=$(cat "$REPO_ROOT/.shipyard-session-id" 2>/dev/null)
  if [ -z "$SESSION_ID" ]; then
    echo "[session-id-derive] empty — skipping A.1 cost-comment refresh; check for #477 cwd-leak (#548)"
  else
  # 1. Read the cost summary as a Markdown comment body (now includes the
  # cumulative total across the original ship + every fix-checks follow-up).
  BODY=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" read-tokens \
    --session-id "$SESSION_ID" --pr <M> --format comment)

  # 2. Edit the existing sentinel comment in place if one exists; otherwise
  # create one. The PATCH path is the hot path here — a green return on a
  # PR that was originally shipped this session will always have a
  # sentinel comment to update. Use the REST listing endpoint for the
  # same reason as the shipped hook above: `gh pr view --json comments`
  # returns GraphQL node-ids that the PATCH endpoint rejects with 404,
  # which silently falls through to the create branch and stacks
  # duplicate cost-tracking comments. See #264.
  EXISTING=$(gh api "/repos/<owner/repo>/issues/<M>/comments?per_page=100" \
    --jq '[.[] | select(.body | startswith("<!-- do-work-cost-tracking -->"))][0].id // empty')

  if [ -n "$EXISTING" ]; then
    gh api -X PATCH "/repos/<owner/repo>/issues/comments/$EXISTING" \
      -f body="$BODY" >/dev/null
  else
    gh pr comment <M> --repo <owner/repo> --body "$BODY" >/dev/null
  fi
  fi
  ```

  No-ops on a PR that never had a sentinel comment posted (no existing comment to update, no `shipped` event to anchor a fresh post — `EXISTING` is empty and the create path posts the first comment with just this fix-checks pass's tokens). Same comment-post-error policy as the `shipped` hook: log `[cost-comment] PR #<M> refresh failed: <reason>; continuing` and proceed.

  **Head-SHA citation check ([#1211](https://github.com/mattsears18/shipyard/issues/1211)) — run BEFORE the trust-but-verify spot-check below, on the same `gh pr view` call.** As of #1211, a `green #<M> @<head-SHA> (...)` / `noop: already green #<M> @<head-SHA> (...)` return carries the full head SHA (`headRefOid`) the worker observed the rollup at. Extract it from the worker's raw return (the token immediately after `#<M>`, e.g. `@a1b2c3d4...`):

  - **SHA present** — fold `headRefOid` into the SAME query the trust-but-verify spot-check already runs (zero extra round-trips; see below) and compare mechanically. **A mismatch is treated exactly like a fabrication-tell trip** — do not take ANY part of the claimed disposition at face value; classify strictly off the live `latest` result the spot-check below computes anyway (never off the worker's claim). Log `[fix-checks-sha-mismatch] PR #<M> cited head SHA <cited> but the PR's live head is <actual> — treating the claim as unverified, classifying from live rollup/mergeStateStatus.` This is a structural, string-comparison-only check — cheaper than re-deriving the rollup, and it catches a plausible-looking fabricated citation with no rollup-count or timestamp tell of its own (the residual gap #1205's two string-scan pre-checks left open).
  - **SHA absent** (a pre-#1211 worker prompt, or a malformed return) — do NOT reject the return outright and do NOT skip verification. Log `[fix-checks-sha-missing] PR #<M> green/noop return omitted the head-SHA citation (pre-#1211 shape or malformed) — proceeding on the unconditional live spot-check below (unchanged behavior).` The trust-but-verify spot-check already runs unconditionally on every `green`/`noop` return regardless of citation, so a SHA-less return is never trusted further than a cited-and-matching one — fail toward MORE verification, never less.

  **Trust-but-verify before accepting `green`.** The agent's `green` claim is load-bearing — downstream code treats green PRs as settled. Spot-check the **latest run per check name** (issue [#333](https://github.com/mattsears18/shipyard/issues/333) — `statusCheckRollup` returns every check run for the head SHA including superseded runs; a stale FAILURE entry that's been re-triggered and now passes would incorrectly downgrade the worker's correct `green` claim to `failing` and re-queue the PR for a pointless second fix-checks dispatch):

  ```bash
  # Latest entry per check name BEFORE the walk. headRefOid rides along in the
  # same call so the head-SHA citation check above costs zero extra round-trips.
  latest=$(gh pr view <M> --repo <owner/repo> --json statusCheckRollup,mergeStateStatus,headRefOid --jq '
    {mergeStateStatus: .mergeStateStatus,
     headRefOid: .headRefOid,
     checks: [.statusCheckRollup
              | group_by(.name)
              | map(sort_by(.completedAt // .startedAt // "") | last)
              | .[]]}')
  ```

  Then classify (checking `mergeStateStatus` FIRST, before ever reading `latest.checks`) — this classification is unconditional and identical whether the SHA citation matched, mismatched, or was absent; the citation check above is an integrity/audit signal layered on top, never a gate that changes which branch fires:
  - **`mergeStateStatus == "DIRTY"` → downgrade to `dirty #<M>`**, regardless of what `latest.checks` contains. Do NOT label `blocked:ci`, do NOT push onto `failed_prs`. Append `<M>` to `session_prs` (if not already there). **Add `<M>` to `dirty_fix_checks_prs`** ([#1060](https://github.com/mattsears18/shipyard/issues/1060) — feeds the deadlock-signature detection in the `blocked rebase` reconcile below). Log: `[fix-checks-verify] downgraded #<M> green→dirty: PR conflicts with default branch, no merge ref (#1015); drain's fix-rebase will reconcile.` A DIRTY PR's rollup is empty by construction (no merge ref, so no check ever queued) — checking this first is what stops the empty-rollup rule below from vacuously accepting a `green` claim that was never actually backed by any check running.
  - Every entry `conclusion in {SUCCESS, SKIPPED, NEUTRAL}` (or empty rollup, and NOT DIRTY per the check above) → accept `green`.
  - Any `state in {PENDING, IN_PROGRESS, QUEUED, EXPECTED}` or `conclusion == null` while `status != "completed"` → **downgrade to `pending`**. Do NOT label `blocked:ci`. Do NOT push onto `failed_prs`. Append `<M>` to `session_prs` (if not already there). Log: `[fix-checks-verify] downgraded #<M> green→pending: <n> checks still running (<sample-check-name>); drain will reconcile.`
  - Any `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` → **downgrade to `failing`**. Push `<M>` onto `failed_prs` (deduped) for the next dispatch cycle to pick up. Log: `[fix-checks-verify] downgraded #<M> green→failing: <failing-check-name> conclusion=<conclusion>; re-queued for fix-checks.`

  The spot-check fires on the `green #<M>` and `noop: already green #<M>` paths. It's one cheap `gh pr view` call. Never skip as an optimization. The latest-per-name `--jq` projection adds zero round-trips; skipping it re-introduces the false-positive failure mode from #333.

- **pending #<M>: <n> check(s) still running** ([#985](https://github.com/mattsears18/shipyard/issues/985) / [#987](https://github.com/mattsears18/shipyard/issues/987)) — the worker found nothing failing but the rollup hadn't fully settled, and returned the honest disposition rather than guessing `green`. This is a **first-class, expected** outcome, not a violation — treat it exactly like a `green→pending` downgrade above: do **NOT** label `blocked:ci`, do **NOT** push `<M>` onto `failed_prs` (nothing is broken; enqueuing it would race a redundant fix-checks dispatch against a run that's still settling on its own), do **NOT** count it against the 3-attempt fix cap. Append `<M>` to `session_prs` (if not already there) and **refresh the cost-tracking comment** for `<M>` (same edit-or-create semantics as the `green` path above). The next PR-triage tick re-checks the rollup on its own schedule: green by then → settled, no further action; still red → a fresh fix-checks dispatch. Log: `[fix-checks-pending] PR #<M> reported <n> check(s) still running; no action needed, next PR-triage tick will reconcile.` (Unlike the `green` path, there is normally no spot-check to run here — the worker's own claim is already the conservative one; a live rollup read would only ever confirm or move it *forward*, never catch an overclaim, since `pending` by construction claims less than `green` does. **Exception:** if the fabrication pre-check above tripped on this same return, run the live spot-check anyway and classify off ground truth — see that section.)

- **dirty #<M>: PR conflicts with `<default-branch>`; no merge ref, so no checks will run** ([#1015](https://github.com/mattsears18/shipyard/issues/1015)) — the worker found the PR's `mergeStateStatus` is DIRTY before any checks could queue at all (GitHub can't compute a merge ref for a conflicted PR, so `pull_request`-triggered workflows never run) and returned the honest disposition instead of polling to exhaustion or misdiagnosing it as a CI infrastructure delay. This is **not a CI failure** — do **NOT** label `blocked:ci`, do **NOT** push `<M>` onto `failed_prs`, do **NOT** count it against the 3-attempt fix cap (the worker never got the chance to run a check, let alone fix one). Append `<M>` to `session_prs` (if not already there) — this is what hands the PR to the end-of-session [drain's `D_dirty` scan](./drain.md#end-of-session-drain), which re-derives `mergeStateStatus` live from `session_prs` and dispatches a `fix-rebase` worker against it regardless of check state; no separate action is needed here to "trigger" the rebase. **Add `<M>` to `dirty_fix_checks_prs`** ([#1060](https://github.com/mattsears18/shipyard/issues/1060) — feeds the deadlock-signature detection in the `blocked rebase` reconcile below). **Refresh the cost-tracking comment** for `<M>` (same edit-or-create semantics as the `green` path above). Log: `[fix-checks-dirty] PR #<M> is DIRTY (mergeStateStatus conflicts with default branch); no checks could queue, handing off to the drain's fix-rebase path.` Any commit the worker had already pushed earlier in the same dispatch (before discovering DIRTY) is not discarded — it stays on the branch for `fix-rebase` to carry forward. (Same fabrication-pre-check exception as `pending` above: if the pre-check tripped on this return, verify `mergeStateStatus` live rather than trusting the claimed `dirty` disposition.)

- **flake #<M>: re-ran failed jobs** ([#654](https://github.com/mattsears18/shipyard/issues/654)) — the worker classified the failure as an **infrastructure flake** (cancelled required jobs / dev-server boot timeout / setup-job failure / runner-lost) with local gates passing, and triggered `gh run rerun --failed` instead of a code fix. Do **NOT** label `blocked:ci` — the PR's diff is healthy; CI just needs to re-run on idle infrastructure. Do **NOT** count it against any fix-attempt budget. Do **NOT** push `<M>` onto `failed_prs` — the re-run is in flight, and enqueuing it would race a redundant fix-checks dispatch against a running re-run. Append `<M>` to `session_prs` (if not already there) so the drain phase watches the re-run's outcome, and **refresh the cost-tracking comment** for `<M>` (same edit-or-create semantics as the `green` path above). The next PR-triage tick picks the PR back up when the re-run settles: green → auto-merge fires; still-red → a fresh fix-checks dispatch (which bails `blocked:ci` if the run's attempt count has reached the re-run bound in [fix-checks-only.md's Infra-flake classification](../../agents/issue-worker/fix-checks-only.md#infra-flake-classification-and-re-run-load-bearing)). Log: `[fix-checks-flake] PR #<M> infra-flake re-run triggered (<signature>); watching for re-run outcome.`

- **blocked #<M> at fix-checks** — comment on the PR summarizing the blocker, add the `blocked:ci` label, continue. The label is the drain phase's signal that this PR is "settled — human needs to look." (This is the terminal for a *chronic* infra flake too — the [attempt-count bound](../../agents/issue-worker/fix-checks-only.md#infra-flake-classification-and-re-run-load-bearing) escalates a persistently-starved re-run to this `blocked` return, so a `blocked:ci` label here can mean either a stuck diff or a stuck runner.)

- **Unrecognized return string (narrative status update)** — the agent returned something that doesn't start with `green`, `noop:`, `pending`, `dirty`, `flake`, or `blocked` (e.g., `"E2E shards typically take 8-15 min."`, `"Routine progress."`, `"Shard 3/3 passes."`). This is a [contract violation](../../agents/issue-worker/fix-checks-only.md#return-contract--read-carefully). Do NOT treat the narrative as authoritative. Probe and synthesize via the same **latest-per-name projection** the trust-but-verify spot-check uses (issue [#333](https://github.com/mattsears18/shipyard/issues/333)):

  ```bash
  latest=$(gh pr view <M> --repo <owner/repo> --json statusCheckRollup,mergeStateStatus,state --jq '
    {state: .state, mergeStateStatus: .mergeStateStatus,
     checks: [.statusCheckRollup
              | group_by(.name)
              | map(sort_by(.completedAt // .startedAt // "") | last)
              | .[]]}')
  ```

  Walk `latest.checks` and synthesize:
  - **`mergeStateStatus == "DIRTY"` (checked BEFORE the empty-rollup rule below, regardless of what `latest.checks` contains) → treat as `dirty #<M>`.** Append `<M>` to `session_prs`. Do NOT push onto `failed_prs`, do NOT label `blocked:ci` — same handling as the worker's own `dirty` return in the fix-checks reconcile above ([#1015](https://github.com/mattsears18/shipyard/issues/1015)). **Add `<M>` to `dirty_fix_checks_prs`** (same bookkeeping as the explicit `dirty` return above — [#1060](https://github.com/mattsears18/shipyard/issues/1060)). This check must come first: a DIRTY PR has an empty rollup by construction (no merge ref, so no check ever queued), and an empty rollup vacuously satisfies the "all SUCCESS" `green` rule below — without this ordering, a narrative-returning DIRTY PR would be synthesized as `green` and nearly auto-merge a conflicted PR.
  - All `conclusion in {SUCCESS, SKIPPED, NEUTRAL}` (or empty rollup, and NOT DIRTY per the check above) → treat as `green #<M>`.
  - Any `state in {PENDING, IN_PROGRESS, QUEUED, EXPECTED}` or `conclusion == null` mid-run → treat as `pending`. Append `<M>` to `session_prs`. Do NOT push onto `failed_prs` — that races with the original worker's still-in-progress fix.
  - Any `conclusion in {FAILURE, ERROR, TIMED_OUT, CANCELLED, ACTION_REQUIRED}` → treat as `failing`. Push `<M>` onto `failed_prs` (deduped).

  Log: `[fix-checks-unrecognized] PR #<M> returned narrative status "<first 60 chars>…"; probed rollup, synthesized <outcome>.` Do NOT re-dispatch fix-checks against this PR within the same turn.

- **errored** — record and continue.

For **fix-rebase work** (`rebased` / `noop` / `blocked`) — dispatched primarily by the [end-of-session drain](./drain.md#end-of-session-drain), and also by [D-tail sub-sweep 2](#d-tail-own-the-tail-merge-completion-sweeps-phase-c--663) mid-session when the [three #1034 conditions](../do-work-RATIONALE.md#dont-dispatch-fix-rebase-mid-session-outside-the-three-conditions-issue-1034) hold — the reconcile below is identical regardless of which dispatch site fired it:

- **rebased #<M>** — the agent force-pushed a rebased branch onto current main. PR is no longer DIRTY; CI will re-run on the new head and auto-merge will fire when green. Record. **Increment `rebase_success_counts[<M>]` by 1** (initialize to 0 if absent) — this is the per-PR rate-limit counter that gates merge-train-race recovery per [drain.md's end-of-session drain](./drain.md#end-of-session-drain). Do NOT add `<M>` to `rebase_blocked_prs` — a successful rebase is a winnable race, not a stuck state. The next drain poll snapshot will reflect the transition out of DIRTY naturally — if a sibling merge re-introduces DIRTY before the rebased branch's CI lands, the drain's `D_dirty` check will re-enter the PR for another fix-rebase dispatch (subject to the 3-cap). (PR is already in `session_prs` from whenever it was first opened — no re-add needed.) **CI-minute bookkeeping ([#323](https://github.com/mattsears18/shipyard/issues/323)):** if `ci.max_drain_rebases` is non-null, increment `ci_session_counters.drain_rebases_dispatched` by 1 here — the cap is enforced against total dispatches, not just successful returns, but the increment lives on the dispatch path (drain.md per-poll action 2) AND mirrors here so the counter survives an out-of-order reconcile.
- **noop: not dirty (<reason>)** — by the time the agent started, the PR was no longer in DIRTY state (auto-merge already landed it, mergeStateStatus settled to CLEAN, or new check failures appeared). Record and continue. If the reason hints at new failures (the agent saw `FAILURE` in the rollup and bailed because rebase is the wrong tool), the drain's normal per-poll red-PR scan will catch it on the next tick and route it through fix-checks instead — no extra action needed.
- **blocked rebase #<M>: <reason>** — non-trivial conflict, head branch moved during the rebase, or some deterministic failure. **Add `<M>` to `rebase_blocked_prs`** (per [drain.md's end-of-session drain](./drain.md#end-of-session-drain) — the deterministic-failure gate that prevents re-dispatch within the session). **Deadlock-signature check ([#1060](https://github.com/mattsears18/shipyard/issues/1060)): if `<M>` is already a member of `dirty_fix_checks_prs`, also add it to `deadlocked_prs`.** This PR returned `dirty` from a fix-checks dispatch and `blocked rebase` from a fix-rebase dispatch within the same session — worth naming distinctly in the end-of-session summary even though the settle mechanics are unchanged (`deadlocked_prs` is a subset of `rebase_blocked_prs`, not a separate gate; see [drain.md's settled definition](./drain.md#drain-protocol)). Add a one-line PR comment: `Drain-phase auto-rebase blocked: <reason>. Needs manual rebase.` (when the deadlock signature fired, append `` This PR also returned `dirty` from an earlier fix-checks dispatch this session — see #1060. `` to the same comment so a human reading the PR sees the full history in one place). Do NOT add `blocked:ci` — the PR isn't stuck on checks, it's stuck on stale base; a human can resolve the rebase and the next session will pick it up if it's still DIRTY. Surface in the end-of-session summary as a still-DIRTY PR (or, for `deadlocked_prs` members, the distinct deadlocked entry — see [cleanup-summary.md](./cleanup-summary.md#end-of-session-summary)). **The `conflict extends beyond coordinated manifest+CHANGELOG rows` reason is the expected soft-collision sub-case** ([#507](https://github.com/mattsears18/shipyard/issues/507)). Treat it identically — not a worker failure — and let the still-DIRTY summary entry signal a human hand-resolve (union the additive bullets, keep both items, CHANGELOG newest-first). See [RATIONALE → Soft-collision rebase conflicts](../do-work-RATIONALE.md#soft-collision-rebase-conflicts-507) and the [Soft-collision](dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) rules for the premise boundary.
- **errored** — record and continue.

For **fix-main-ci work** (`shipped` / `noop` / `blocked`):

- **shipped main-ci-fix via PR #<M>** — record. **Append `<M>` to `session_prs`.** The diversion is "resolved" from the orchestrator's perspective the moment the PR is open with auto-merge; the next step-D refresh will detect main going green (and clear the divert flag) once the PR lands. Don't re-enqueue the diversion in the meantime — the in_flight slot is gone but the divert_queue check at step D guards against double-dispatch.

  **Un-sticking other session PRs once this fix's own PR lands is NOT this reconcile's job — it fires at the next `main_ci` transition check** ([#993](https://github.com/mattsears18/shipyard/issues/993)). At the moment this `shipped` return is reconciled, `<M>` has only just opened with auto-merge armed — `main` is still red until `<M>` itself merges and its post-merge run completes, so there's nothing to refresh yet. Any *other* `session_prs` entry carrying a required-check `FAILURE` that predates `<M>`'s eventual merge commit gets automatically re-triggered (`gh pr update-branch`) the next time [04-backlog-divert.md's post-main-CI-fix branch-refresh](./setup/04h-post-main-ci-branch-refresh.md#post-main-ci-fix-branch-refresh--un-stick-session-prs-carrying-a-stale-failing-required-check-993) (step D's periodic refresh) or [drain's per-poll main-CI health read](./drain.md#post-main-ci-fix-branch-refresh-drain-phase-993) observes the resulting red→green transition — see either file for the mechanism. No action is needed at this reconcile step beyond the existing `session_prs` append above.

  **Stamp the attempt counter for the flake circuit breaker** ([#589](https://github.com/mattsears18/shipyard/issues/589)). The just-completed slot's in_flight entry carries the `earliest_red_workflow_name` the divert targeted (call it `sig`). On this `shipped` reconcile, **increment** `main_ci_fix_attempts[sig].attempts` (initializing the entry to `{ attempts: 0, last_pr: null, last_sha: null, escalated: false }` if absent), and set `last_pr = <M>`. This records "we have now made N fix attempts against `sig`." The *re-red verification* — confirming the merge-commit went red again on the same `sig` rather than the fix working — is deferred to the next [step-D divert-checks refresh](#d-periodic-refresh): if that refresh finds `sig` green, the green branch of [step 4.5a's enqueue rule](./setup/04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) deletes the counter (the fix worked, attempts forgotten); if it finds `sig` still/again red, the counter persists and the cap check in the red branch decides whether to re-dispatch or escalate. Incrementing on `shipped` (rather than waiting for the re-red) is what makes the cap converge: a fix that *works* clears the counter at the next green refresh, so only the genuinely-recurring pass-on-PR/fail-on-merge flake accumulates toward the cap.
- **noop: main already green** — main flipped green between divert dispatch and the agent's pre-flight. Record. **Clear any `main_ci_fix_attempts` entry for the slot's `earliest_red_workflow_name`** — main is green on that workflow, so the attempt cycle is done. Step D will repopulate if it goes red again.
- **blocked main-ci-fix: <reason>** — log to the session summary. Do NOT auto-retry — back off and surface in the status line: `main:🔴 (<workflow-summary>, run <id>) · diversion blocked: <reason>` (same `<workflow-summary>` format as the setup.md step 6.5 status-line spec). A human needs to intervene. (Distinct from the [#589](https://github.com/mattsears18/shipyard/issues/589) flake escalation: a `blocked` return is the *worker* declining to fix; the flake escalation is the *orchestrator* capping repeated green-on-PR/red-on-merge fixes that each "succeeded" from the worker's view.)

For **fix-failing-prs-batch work** (`shipped` / `noop` / `blocked`):

- **shipped pr-batch-fix via PR #<M>** — record. **Append `<M>` to `session_prs`.** Same single-shot pattern as fix-main-ci.
- **noop: pileup already cleared** — the count dropped below 10 between dispatch and pre-flight (other PRs got merged or fixed). Record. Step D re-evaluates.
- **blocked pr-batch-fix: <reason>** — log to summary, back off, surface in status line. No auto-retry.

For **investigate work** (`investigated+fixed` / `investigated+needs-human-review` / `investigated+closed-noise` / `investigated+duplicate` / `blocked` / `reaped`):

- **investigated+fixed #<N> via PR #<M>** — the worker diagnosed a real bug and opened a fixing PR. Record. **Append `<M>` to `session_prs`.** Apply the standard `shipped` cost-tracking comment and worktree-reap path (same as issue-work `shipped` — cost comment on PR, immediate worktree reap for `do-work/issue-<N>`). Remove the `needs-triage` label from the issue: `gh issue edit <N> --repo <owner/repo> --remove-label needs-triage 2>/dev/null || true`. The issue auto-closes when PR `<M>` merges (the worker's PR body includes `Closes #<N>`). Same `auto-merge: unavailable — gh token lacks workflow scope` handling as the issue-work `shipped` case above ([#812](https://github.com/mattsears18/shipyard/issues/812)) — append `<M>` to `workflow_scope_blocked_prs` too when the suffix matches.

- **investigated+needs-human-review #<N> (label applied)** — the worker reviewed the issue and determined it requires human judgment (ambiguous reproducer, architectural decision, security-sensitive, etc.). The worker already applied the `needs-human-review` label. Record. Remove `needs-triage`: `gh issue edit <N> --repo <owner/repo> --remove-label needs-triage 2>/dev/null || true`. No auto-retry — `/my-turn` will surface it. Reap the agent's worktree via step B.

- **investigated+needs-human-review #<N> (decision already recorded, gate not re-applied)** — [#1279](https://github.com/mattsears18/shipyard/issues/1279): the worker's own [§4b freshness check](../../agents/issue-worker/investigate.md#4b-genuinely-needs-a-human--apply-needs-human-review-return-blocked-style-the-investigatedneeds-human-review-path) found a decision-resolved sentinel posted after this issue's last escalation and deliberately did **not** (re-)apply `needs-human-review` — the worker already removed `needs-triage` and posted the explanatory comment itself. Record. **Do NOT apply `needs-human-review` here either** — the issue is meant to re-enter the normal dispatch pool with no gate label, since the recorded decision should make it actionable on the next pass. No further label action. Reap the agent's worktree via step B.

- **investigated+closed-noise #<N>** — the worker determined the issue is noise (spam, test artifact, auto-filed bot issue with no actionable signal). The worker already closed the issue. Record. Log: `[investigate-reconcile] #<N> closed as noise.` Reap the agent's worktree via step B.

- **investigated+duplicate #<N> of #<K>** — the worker determined the issue duplicates `#<K>`. The worker already closed `#<N>` as a duplicate. Record. Log: `[investigate-reconcile] #<N> closed as duplicate of #<K>.` Reap the agent's worktree via step B.

- **reaped:** (from investigate mode) — same handling as issue-work `reaped:` above: re-enqueue `<N>` into `investigate_candidates` (deduped), remove `@me` assignee, log the event. The worker's worktree is already gone; no reap needed.

- **blocked #<N>** (from investigate mode) — apply the same `blocked` classification logic as issue-work above (dependency-wait → no label, body-ref filter; refuse → `needs-human-review`; soft → `blocked:agent-soft`). Additionally remove `needs-triage` only on the refuse path (the issue is no longer a triage candidate once a human-review gate has been applied): `gh issue edit <N> --repo <owner/repo> --remove-label needs-triage --add-label needs-human-review 2>/dev/null || true`. Reap the agent's worktree via step B.

For **spike work** (`spiked+shipped` / `spiked+needs-human-review` / `blocked` / `reaped`) — [#774](https://github.com/mattsears18/shipyard/issues/774), dispatched per [`dispatch-rules.md`'s spike-shape detection](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c):

- **spiked+shipped #<N> via PR #<M> (auto-merge: ..., checks: ..., sub-issues: ...)** — the worker concluded the spike (viable / viable-with-caveats / **or** not-viable — all three are `spiked+shipped`, per [spike.md step 11](../../agents/issue-worker/spike.md#11-return)) and opened a PR carrying the committed design doc plus, optionally, a decomposition and/or an implemented slice. Treat this identically to an issue-work `shipped #<N> via PR #<M>` return: **Append `<M>` to `session_prs`.** Run the standard `shipped` cost-tracking comment and immediate worktree reap for `do-work/issue-<N>` (same mechanics as the [issue-work `shipped` handler](#a1-parse-the-return-string) above — auto-merge/checks parsing, cost comment, force-reap-even-on-`peer-alive`). The issue auto-closes when PR `<M>` merges (the worker's PR body includes `Closes #<N>`). Any follow-on sub-issues the worker filed (per spike.md step 6) are fresh `shipyard`-labelled issues with no gate label — they re-enter the normal dispatch loop via the next backlog fetch, exactly like a `/decompose-epic` shard.

- **spiked+needs-human-review #<N> (label applied)** — the investigation surfaced a genuine human-only decision (product/business/legal call, access the worker lacks, or a question no amount of investigation could narrow). The worker already applied `needs-human-review`. Record. No auto-retry — `/my-turn` will surface it. Reap the agent's worktree via step B.

- **spiked+needs-human-review #<N> (decision already recorded, gate not re-applied)** — [#1279](https://github.com/mattsears18/shipyard/issues/1279): same shape as investigate-mode's identically-suffixed outcome above — the worker's own [§4b freshness check](../../agents/issue-worker/spike.md#4b-not-actionable--route-to-a-human) found a decision-resolved sentinel posted after this issue's last escalation and deliberately did **not** (re-)apply `needs-human-review`. Record. **Do NOT apply the label here either** — no further label action. Reap the agent's worktree via step B.

- **reaped:** (from spike mode) — same handling as issue-work `reaped:` above: re-enqueue `<N>` back into the ready pool (deduped), remove `@me` assignee, log the event. The worker's worktree is already gone; no reap needed.

- **blocked #<N>** (from spike mode) — apply the same `blocked` classification logic as issue-work above (dependency-wait → no label, body-ref filter; refuse → `needs-human-review`; soft → `blocked:agent-soft`). Reap the agent's worktree via step B.

`session_prs` is the set of PR numbers this orchestrator session opened (issue-worker shipped, fix-main-ci shipped, fix-failing-prs-batch shipped, spike-worker shipped) plus any pre-existing `@me` PRs that fix-checks touched. It is read by the end-of-session drain to decide what to watch and when to exit. A PR enters `session_prs` exactly once — re-touches don't re-add. Started empty at step 7's initial pool fill.

#### A.5. (removed — [#521](https://github.com/mattsears18/shipyard/issues/521))

The mid-session blocked-issue re-evaluation sweep ([#245](https://github.com/mattsears18/shipyard/issues/245)) was **removed** in [#521](https://github.com/mattsears18/shipyard/issues/521) along with the `blocked:agent-hard` label it reconciled. Its entire job was to auto-clear the redundant `blocked:agent-hard` label mid-session when a shipped PR closed a referenced blocker — but dependency-wait issues no longer carry a label. They are gated purely by the [`Blocked by #N` body-reference filter](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) (bucket 7 / step 4), which already stops dropping the issue the instant the referenced blocker closes. Step C's [lightweight backlog re-check](#c-dispatch-a-replacement-if-work-remains--mandatory-action) runs that filter on every dispatch, so a blocker that closes mid-session re-admits its dependents on the next dispatch turn with no targeted sweep — the body-ref filter is the complete mechanism. See [setup.md step 3d.2](./setup/01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session) for the companion removal of session-start sub-sweep a.

### B. Release the slot

**Never reach this step from a PR-state observation alone — only from this turn's already-parsed A.1 return ([#1235](https://github.com/mattsears18/shipyard/issues/1235); see the invariant at the top of step A).** By the time this step runs, step A has parsed a genuine terminal return string for the slot being released; that parse — never a live `MERGED` read taken on its own — is what licenses the removal below.

Remove the completed entry from `in_flight`. Its `claimed_paths` are now free.

**Then reap the agent's worktree — every completion path, every mode.** Closes [#334](https://github.com/mattsears18/shipyard/issues/334). The A.1 `shipped #<N>` handler already runs an immediate-reap for issue-work `do-work/issue-<N>` worktrees (per [#282](https://github.com/mattsears18/shipyard/issues/282)), but that path does NOT cover the other return shapes:

- **`green #<M>` / `noop: already green #<M>` from fix-checks-only** — head branch is the PR's existing head (typically `do-work/issue-<N>` for shipyard-anchored PRs). When fix-checks completes and the drain phase later dispatches a fix-rebase against the same PR, the fix-rebase worker bails with `blocked rebase #<M>: head branch <head> locked in another worktree` because the fix-checks worktree's lock outlived the worker.
- **`rebased #<M>` from fix-rebase** — head branch is the PR's existing head. Sequential fix-rebase retries (the per-PR 3-attempt cap can hit this) collide on the same branch.
- **`shipped main-ci-fix via PR #<M>` / `shipped pr-batch-fix via PR #<M>` from synthetic-divert workers** — head branches are `do-work/fix-main-ci-<sha>` / `do-work/fix-pr-pileup-<ts>` (not `do-work/issue-<N>`) so the A.1 `shipped #<N>` branch-walk doesn't match and the worktree lingers.
- **`blocked <mode>` from any mode** — the worker bailed without producing a usable artifact; its worktree is no-longer-live and should be reaped same-session so a re-dispatch (after the soft-window, after a human clears `needs-human-review` on a refuse, or after the referenced `Blocked by #N` blocker closes on a dependency-wait) doesn't collide on the head branch.

The single-point reap below covers every one of these. The A.1 `shipped #<N>` path is **not** removed — it remains the load-bearing same-turn reap for the issue-work merge-train coordination case (per #282's rationale), and the duplicate-reap is harmless: the helper's `git worktree remove --force` against a path the A.1 pass already removed is a silent no-op.

**Force-reap even on `peer-alive` here — closes the general-reap gap #576 left open (issue [#771](https://github.com/mattsears18/shipyard/issues/771)).** By the time step B runs, step A has already parsed this turn's **terminal** return string (every mode's completion contract: `shipped` / `green` / `noop` / `rebased` / `blocked`), so the agent is done by definition regardless of which mode produced the release — the same reasoning A.1 and drain's #370 already apply. A `peer-alive` classification at this call site means the lock PID is a transient harness subprocess that outlived the agent's own return by milliseconds, not a genuine still-working peer. Force-reap and audit with classification `peer-alive-force` (same token A.1 uses — the `phase` field, already `steady-state-B-completion`, is what distinguishes the two call sites in `~/.shipyard/reap-audit.jsonl`). See [RATIONALE → Force-reap on peer-alive (#576/#771)](../do-work-RATIONALE.md#force-reap-on-peer-alive-576771) for the PR#2598/#2701 repro that motivated this.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# Capture the agent id BEFORE the in-memory slot removal — the path
# derivation needs it. The agent_id is the same task-id the harness uses
# end-to-end (see step A.−1 for the keying convention) and matches the
# `.claude/worktrees/agent-<id>` directory name the harness creates for
# `isolation: "worktree"` dispatches.
completed_agent_id="${.in_flight[<slot-id>].agent_id}"
# Anchor cwd to a stable directory BEFORE deriving paths or reaping (issue
# #497). The harness can leak the orchestrator's cwd into the very
# `agent-${completed_agent_id}` worktree this block removes; once it's gone,
# the `git worktree prune` below and the `$(git rev-parse --show-toplevel)`
# path derivation both fail with `fatal: Unable to read current working
# directory` (git resolves its own cwd before doing anything). Derive a
# stable anchor cwd-independently via the #477 porcelain idiom (orchestrator
# worktree first, primary as fallback) and cd to it first, then derive the
# primary/worktree paths from porcelain rather than the leaked cwd.
# Process substitution, not a pipe — `awk` still reads the porcelain output
# as a single command's input, but the shape has no bare `|` spanning a
# shell command boundary (issue #1289, mirrors #1277's decomposition rule).
STABLE_DIR=$(awk '/^worktree /{p=substr($0,10)} p ~ /\/\.claude\/worktrees\/orchestrator-/{print p; exit}' \
  <(git worktree list --porcelain 2>/dev/null))
[ -z "$STABLE_DIR" ] && STABLE_DIR=$(awk '/^worktree /{print substr($0,10); exit}' \
  <(git worktree list --porcelain 2>/dev/null))
cd "${STABLE_DIR:-/}" 2>/dev/null || cd /
PRIMARY_CHECKOUT=$(awk '/^worktree /{print substr($0,10); exit}' \
  <(git worktree list --porcelain 2>/dev/null))
wt_dir="${PRIMARY_CHECKOUT}/.git/worktrees/agent-${completed_agent_id}"
worktree_path="${PRIMARY_CHECKOUT}/.claude/worktrees/agent-${completed_agent_id}"

# In-flight guard (issue #832) — NOT applicable as an exclusion here, same
# reasoning as A.0.5 and A.1's shipped-path reap above. This block targets
# exactly one worktree — THIS slot's own `completed_agent_id` — because
# step A has already parsed this dispatch's terminal return by the time
# step B runs. `.in_flight[<slot-id>]` is still present (this IS the
# release), so a naive in_flight-membership skip would wrongly defer the
# reap this step performs. Do not add one.
if [ -d "$wt_dir" ]; then
  # Bootstrap the orchestrator PID so classify-lock can short-circuit on
  # our own session's locks (issue #263 — same pattern as A.1's reap).
  export SHIPYARD_ORCHESTRATOR_PID=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-identity.sh" detect-orchestrator-pid)

  classification=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" \
    classify-lock "$wt_dir/locked")

  # Extract the lock PID for the audit log (best effort; null literal
  # when the lock file is missing or unparseable). Anchor on the literal
  # `pid` keyword, not "first digit-run before a close-paren" — the latter
  # misparses a real `(pid <N> start <ctime>)` lock as the ctime's trailing
  # year (issue #1206). Same fix as `worktree-reap.sh`'s own
  # `extract_lock_pid` helper.
  # `-m1` caps grep at the first match (replaces the `| head -1` stage), and
  # a pure parameter-expansion digit-strip replaces the second `| grep -oE`
  # stage — no pipe spans a shell command boundary. Anchors on the literal
  # `pid` keyword exactly as before (issue #1206).
  lock_pid_match=$(grep -m1 -oE '\(pid[[:space:]]+[0-9]+' "$wt_dir/locked" 2>/dev/null)
  lock_pid="${lock_pid_match//[!0-9]/}"
  [ -z "$lock_pid" ] && lock_pid="null"

  # no-lock / dead / self-ancestor / peer-alive — all safe to reap here.
  # Step A has already parsed THIS dispatch's terminal return string by the
  # time step B runs (shipped / green / noop / rebased / blocked — every
  # mode's completion contract), so the agent is done by definition. Unlike
  # the pre-#771 posture (which deferred on peer-alive as a blanket
  # defensive measure), a peer-alive classification here is treated the
  # same way A.1's shipped-path and drain's #370 pre-dispatch reap already
  # treat it: the lock PID is a transient harness subprocess outliving the
  # agent's own return, not a genuine still-working peer. Force-reap closes
  # the general-reap gap #576 left open — that fix only covered the A.1
  # issue-work `shipped` special case, leaving every other return shape
  # (fix-checks `green`, fix-rebase `rebased`, the synthetic-divert
  # `shipped` variants, any mode's `blocked`) still deferring here and
  # producing the "branch locked in another worktree" re-dispatch bails
  # documented in issue #771. Audit with classification "peer-alive-force"
  # so the override stays traceable in ~/.shipyard/reap-audit.jsonl.
  local_classification="$classification"
  [ "$classification" = "peer-alive" ] && local_classification="peer-alive-force"
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
    --action reaped \
    --worktree-path "$worktree_path" \
    --worktree-name "agent-${completed_agent_id}" \
    --session-id "<session-id>" \
    --classification "$local_classification" \
    --lock-pid "$lock_pid" \
    --phase "steady-state-B-completion" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
fi
```

**Verify the reap above actually happened — as its OWN, separate Bash tool call ([#1274](https://github.com/mattsears18/shipyard/issues/1274)).** Same reasoning as A.0.5's own verify step: a classifier denial of the reap call above kills the whole tool call before any code in that same call can run, so a check bundled into it would never execute either — it has to be a genuinely separate call. This one performs no destructive operation, so it should never itself be denied. Substitute the literal `$worktree_path` / `$local_classification` / `$lock_pid` / `$completed_agent_id` values already known from the block above (shell variables don't survive across Bash tool calls, but the orchestrator composing this call still has them):

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
if [ -e "$worktree_path" ]; then
  "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-reap.sh" reap \
    --action reaped-failed \
    --worktree-path "$worktree_path" \
    --worktree-name "agent-${completed_agent_id}" \
    --session-id "<session-id>" \
    --classification "$local_classification" \
    --reason "reap-attempt-unverified — possible classifier denial (#1274)" \
    --lock-pid "$lock_pid" \
    --phase "steady-state-B-completion" 2>/dev/null || true
  echo "[steady-state-B-completion] worktree still present after reap attempt — reaped-failed recorded (#1274); will surface in end-of-session Cleanup line"
fi
```

**Fire-and-forget discipline.** Every command suffixes `2>/dev/null` and/or `|| true` so a filesystem race (the worktree was already reaped by the A.1 path, the helper script is missing, the lock file is gone, etc.) cannot abort the steady-state loop. If the reap silently fails for any reason, end-of-session cleanup is still the safety net (intentionally NOT removed — it remains the ultimate sweep).

**Audit-log shape.** The JSONL entries this step writes carry `"phase":"steady-state-B-completion"` so an operator inspecting `~/.shipyard/reap-audit.jsonl` can distinguish per-completion reaps from the A.1 same-turn reap (`"phase":"steady-state-A1-shipped"`), the setup-3b stale-worktree pass (no `phase`), and the cleanup-summary end-of-session sweep (no `phase`). The `phase` suffix is appended by the `reap` helper natively (issue #284).

Step B identifies the worktree by `agent_id` (available in working memory at release) rather than walking branches the way A.1's `shipped #<N>` path does — faster and avoids branch-name collisions. See [RATIONALE → Why step B keys on agent_id](../do-work-RATIONALE.md#why-step-b-keys-on-agent_id) for the comparison to A.1's approach.

### C. Dispatch a replacement (if work remains) — MANDATORY ACTION

**This step is non-optional and non-deferrable.** Whenever step B frees a slot, step C MUST resolve in the same turn — either a `Workflow` tool call or an explicit, structured idle-proof (step E). No third option.

**Drain guard:** if `draining = true`, skip dispatch entirely. The slot stays empty until in-flight empties and the loop terminates. Step E still prints with `draining=true` noted.

**Lightweight backlog re-check (every dispatch).** Before consulting `ready_issues` or `raw_backlog`, run the step-4 backlog fetch — a single `gh issue list` with the same **wide-fetch shape** that [setup.md step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) uses (`--state open` server-side only, plus any `--label` qualifiers passed at invocation; the previous `-linked:pr` + `-label:...` server-side qualifiers were removed in [#332](https://github.com/mattsears18/shipyard/issues/332) — they silently excluded resumable-work issues).

**Stamp the invariant-line tokens immediately, from this same wide-fetch payload, BEFORE classification runs** ([#1246](https://github.com/mattsears18/shipyard/issues/1246)) — `scripts/backlog-filter.sh summary` is the single-source-of-truth implementation (the same pure-function split as `classify` itself), so this count can never drift from what [step E's invariant line](#e-invariant-line-end-of-every-steady-state-turn) reports. `unfiltered_open_count` ([added in #332](https://github.com/mattsears18/shipyard/issues/332)) is the wide fetch's raw array length; `me_assigned_open` ([added in #1194](https://github.com/mattsears18/shipyard/issues/1194)) narrows that same wide-fetch payload to the count of issues assigned to the gh-authenticated user — the bucket a wrong assignee filter is most likely to erase:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
ME_LOGIN=$(gh api user --jq '.login')
FETCHED_ISSUES_JSON=$(gh issue list --repo <owner/repo> --state open --limit 200 \
  --json number,title,labels,assignees,body,author,updatedAt,milestone \
  --jq '[.[] | {number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], author: {login: .author.login}, updatedAt, milestone: (.milestone.title // null)}]')

SUMMARY=$("${CLAUDE_PLUGIN_ROOT}/scripts/backlog-filter.sh" summary --me "$ME_LOGIN" <<< "$FETCHED_ISSUES_JSON")
"${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" update --session-id "<session-id>" \
  --set ".unfiltered_open_count = $(printf '%s' "$SUMMARY" | jq -r '.unfiltered_open_count')" \
  --set ".me_assigned_open = $(printf '%s' "$SUMMARY" | jq -r '.me_assigned_open')" \
  --set ".last_fresh_fetch = \"$(date -u +%H:%M:%S)\"" \
  --allow-degraded-init --degraded-init-repo "<owner/repo>"
```

**Classify by invoking `scripts/backlog-filter.sh classify` — never re-derive it here or hand-roll a shorthand substitute** ([#1194](https://github.com/mattsears18/shipyard/issues/1194), [#1247](https://github.com/mattsears18/shipyard/issues/1247)). This is the same executable classifier [setup.md step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) invokes — see that step's "Invocation" block for the exact flags (`--me`, `--trusted-authors`, `--closed-by-healthy-pr`, `--peer-claimed`, `--investigate-dispatch`, `--respect-assignees`, `--milestones-enabled`, `--milestones-prioritize-dispatch`); this re-check passes the same values, re-derived or held from setup, against this same `$FETCHED_ISSUES_JSON`. The two milestone flags (issue [#1241](https://github.com/mattsears18/shipyard/issues/1241)) matter here specifically because this re-check's whole point is to append **net-new** numbers to `raw_backlog` in the script's own rank order — omitting them would silently rank a mid-session-discovered issue by the flat pre-#1241 order even on a repo that has opted into milestone-ordered dispatch, producing exactly the kind of two-call-sites-disagree drift this file's header paragraph already exists to prevent for every other flag. A hand-rolled shorthand ("drop issues with no assignee" instead of "drop issues assigned to someone other than `@me`") is NOT the same predicate and silently reintroduces #332's exact regression one layer down — that was the actual, committed divergence this file carried before #1247 converged all three call-sites onto the single script (`needs-triage` used to be listed inside this file's own dispatch-gate drop enumeration, directly contradicting setup.md's routing of the same label to `investigate_candidates`; the script has exactly one behavior for `needs-triage`, so the contradiction cannot recur). Diff the script's `eligible` numbers against the union of `in_flight` + `ready_issues` + `raw_backlog` + issues previously closed this session; append net-new numbers to `raw_backlog` in the script's own rank order (no separate sort pass needed). **Also diff the script's `route:investigate` numbers against `investigate_candidates` + `in_flight`** and append any net-new ones there too, in the script's investigate rank order — a mid-session Sentry-filed or bot-authored issue must reach `investigate_candidates` exactly as reliably as an ordinary issue reaches `raw_backlog`, not silently vanish the way a `needs-triage`-labeled issue did under this file's pre-#1247 drop enumeration. The trusted-author drop is non-negotiable here — `raw_backlog` and `investigate_candidates` are both dispatch-feeder queues and a stranger's mid-session issue must never reach either. Skip auto-triage label-stamping and full scope pre-flight here — those run on step D's periodic refresh; the cheap pass just appends raw issue numbers (lazy scope at rule 5 of the dispatch rules). On transient `gh` errors, proceed with the queues as-is — never block dispatch on a refill failure.

**Soft-blocked in-window filter (per [#300](https://github.com/mattsears18/shipyard/issues/300)).** Step 4's workable filter does NOT exclude `blocked:agent-soft` — by design, so the label doesn't leak across sessions — but within a session, immediately re-dispatching a worker against an issue another worker just bailed soft on would just re-encounter the same ambiguity. The in-memory `session_blocked_soft` map (populated by step A.1's `blocked` handler — `{issue_number → ISO-8601 timestamp of the bail}`) gates this. Before appending any net-new issue to `raw_backlog`, check:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# Re-derive the SHIPYARD_REPO_ROOT pin (issue #1059/#1064).
SHIPYARD_REPO_ROOT=$(cat "$(git rev-parse --show-toplevel)/.shipyard-primary-root" 2>/dev/null)
[ -z "$SHIPYARD_REPO_ROOT" ] && SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel)"
export SHIPYARD_REPO_ROOT
# blocked_agent.soft_retry_minutes — default 30 — from shipyard-config.sh.
soft_retry_minutes=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" \
  get blocked_agent.soft_retry_minutes 2>/dev/null || echo "30")
now_epoch=$(date -u +%s)
for n in "${net_new_issues[@]}"; do
  bail_iso="${session_blocked_soft[$n]:-}"
  if [ -n "$bail_iso" ]; then
    bail_epoch=$(date -u -d "$bail_iso" +%s 2>/dev/null || \
                 date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$bail_iso" +%s 2>/dev/null || echo 0)
    elapsed_min=$(( (now_epoch - bail_epoch) / 60 ))
    if [ "$elapsed_min" -lt "$soft_retry_minutes" ]; then
      # In-window — skip re-add; will retry on the next dispatch after window expiry.
      continue
    fi
    # Window expired — clear the bookkeeping entry so the issue is treated as fresh.
    unset 'session_blocked_soft[$n]'
  fi
  raw_backlog+=("$n")
done
```

Filter applies to net-new issues from the lightweight re-check ONLY — issues already in `raw_backlog` / `ready_issues` from earlier in the session are NOT re-checked here (they were validated at their own dispatch attempt, and a worker that bailed soft on them already added them to `session_blocked_soft`). When `blocked_agent.soft_retry_minutes` is `0`, the filter is a no-op — every soft-bailed issue is re-considered on every dispatch (useful for debugging; not recommended in normal operation).

**Cache the backlog re-check via `gh-cached.sh`.** This is a hot path — it fires on every dispatch turn — and the backlog doesn't change meaningfully over a 60-second window. Wrap the `gh issue list` call through [`gh-cached.sh`](./setup/00b-parallelization-cache.md#09-gh-cachedsh-wrapper-opt-in-per-call-site) with `--ttl 60`. Invalidate the cache (`gh-cached.sh invalidate --session-id "<session-id>"`) right after any state-changing call shipyard itself makes (issue close, label edit, etc.) so the next dispatch turn picks up the post-write view. Caller picks the trade-off: skip the wrapper to always re-fetch live, or accept up to 60s of staleness in exchange for not re-hitting the API every dispatch.

**Queue-depth backpressure check (self-hosted CI pools only, issue [#1156](https://github.com/mattsears18/shipyard/issues/1156)) — run before filling ANY freed slot, regardless of which queue would supply the candidate.** [Step 1.36](./setup/01-repo-recovery.md#136-detect-ci-executor-pool-capacity-and-clamp-toward-it-1141) clamps `EFFECTIVE_CONCURRENCY` toward a self-hosted runner pool's size **once, at session start** — a one-time signal that says nothing about a queue that grows *during* a long session as the loop keeps filling freed slots regardless of how deep the CI backlog already is. This check is the dispatch-time complement: a **live**, per-turn re-read that can hold a slot open rather than dispatch into an already-saturated pool, mirroring the existing "leave the slot empty for now" path documented for path/lockfile collisions ([dispatch-rules.md](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c), rule 4/6) — the parking mechanism is unchanged, only the trigger (a fresh queue-depth read) is new.

Skip this check entirely unless `.ci_capacity.shape == "self-hosted"` **and** `.ci_capacity.pool_total > 0` (both from session state, written once at [step 1.5](./setup/01-repo-recovery.md#15-initialise-the-session-state-file)) — on `hosted` (GitHub-hosted runners are elastic) or `unknown` (the pool size was never readable), there is nothing to hold back against and the check is a no-op:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
ci_shape=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" read --session-id "<session-id>" --path ".ci_capacity.shape" 2>/dev/null)
pool_total=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" read --session-id "<session-id>" --path ".ci_capacity.pool_total" 2>/dev/null)

if [ "$ci_shape" = "self-hosted" ] && [ "${pool_total:-0}" -gt 0 ] 2>/dev/null; then
  # Live re-read, NOT the stale `.ci_capacity.queued_at_start` snapshot —
  # queue depth is inherently a live number (same posture as the
  # end-of-session summary's own re-query). Cache with a short TTL: this
  # fires on every dispatch turn, and the queue doesn't meaningfully change
  # inside a ~30s window, so a live call on every single turn would be
  # pure API-call waste for no decision-quality gain.
  queued_live=$("${CLAUDE_PLUGIN_ROOT}/scripts/gh-cached.sh" run \
    --session-id "<session-id>" --ttl 30 -- \
    run list --repo "<owner/repo>" --status queued --limit 100 \
    --json databaseId --jq 'length' 2>/dev/null)

  # Re-derive the SHIPYARD_REPO_ROOT pin (issue #1059/#1064) before the
  # shipyard-config.sh reads below — each Bash-tool call is a fresh,
  # hermetic subshell, so nothing set in an earlier call (including step
  # 0.56's original stash-and-export) survives into this one.
  SHIPYARD_REPO_ROOT=$(cat "$(git rev-parse --show-toplevel)/.shipyard-primary-root" 2>/dev/null)
  [ -z "$SHIPYARD_REPO_ROOT" ] && SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel)"
  export SHIPYARD_REPO_ROOT
  multiplier=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get ci.backpressure_multiplier 2>/dev/null)
  min_in_flight=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get ci.backpressure_min_in_flight 2>/dev/null)

  # <in_flight> is the count of entries in `.in_flight` BEFORE this slot is
  # filled — the same count step E's `in_flight < concurrency` check reads.
  verdict=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ci-runner-capacity.sh" \
    --decide-backpressure "$pool_total" "${queued_live:-0}" "<in_flight>" "$multiplier" "$min_in_flight")

  if [ "$verdict" = "hold" ]; then
    threshold=$(awk -v p="$pool_total" -v m="${multiplier:-5}" 'BEGIN{printf "%.0f", p*m}')
    idle_reason="parked (CI queue backpressure: queued=${queued_live:-0} > threshold=${threshold} = pool_total(${pool_total})×${multiplier:-5})"
    # Do NOT dispatch this turn — leave the slot empty and go straight to
    # step E's idle-proof with this idle_reason. The next completion (or
    # the next dispatch turn's fresh live re-read) retries.
  fi
fi
```

**The decision itself lives in exactly one place** — [`scripts/detect-ci-runner-capacity.sh`](../../scripts/detect-ci-runner-capacity.sh)'s `--decide-backpressure` pure mode (same single-executable-source-of-truth pattern as the ungated-admin-direct-merge and gate-narrowing detectors) — do not re-derive the threshold arithmetic inline. `queued > pool_total × ci.backpressure_multiplier` (config default `5` — deliberately looser than the end-of-session summary's fixed `3×` **advisory** threshold, since holding a dispatch slot has a real cost an already-past-tense summary line doesn't) triggers a hold, **unless** the escape valve fires first: `<in_flight> < ci.backpressure_min_in_flight` (config default `1`) always dispatches regardless of queue depth, so a saturated pool can never fully stall the session with backlog work still waiting and every slot parked. A `pool_total` of `0` (shouldn't happen given the `self-hosted` + `pool_total > 0` guard above, but the script is defensive) always dispatches too — never hold on a signal that couldn't actually be read.

**When the check holds** — before parking the slot, try the **CI-cheap candidate bias** below (issue [#1157](https://github.com/mattsears18/shipyard/issues/1157), follow-up to #1141/#1156). **When it doesn't hold** (verdict `dispatch`, or the check was skipped because the shape isn't `self-hosted`) — proceed to the dispatch rules below exactly as before; this check changes nothing about which candidate gets picked, only whether a candidate is picked *at all* this turn.

**CI-cheap candidate bias under a backpressure hold ([#1157](https://github.com/mattsears18/shipyard/issues/1157)) — prefer a candidate whose PR would skip the heavy CI path, rather than only holding the slot.** This runs ONLY when the backpressure check immediately above just produced `verdict = "hold"` — outside a hold, this bias never activates and never changes candidate ranking. It is a **pool FILTER at the moment of a hold, not a rank override**: the existing priority order computed for `ready_issues` ([setup step 4](./setup/04-backlog-divert.md#4-fetch--rank-the-backlog) — `P0` > `P1` > `P2` > unlabeled, then staleness; or, on a repo with `milestones.enabled` AND `milestones.prioritize_dispatch` both `true`, `P0` (global) > `--prioritize-label` > milestone sequence > `P1` > `P2` > unlabeled > type > staleness, per issue [#1241](https://github.com/mattsears18/shipyard/issues/1241) — `backlog-filter.sh classify`'s `_sort_key` is the normative definition either way, this is a non-normative restatement) is never re-sorted by this bias, and a CI-heavy P0 is never skipped in favor of a CI-cheap P2 except in the one narrow sense that, at a moment when the P0 candidate literally cannot be dispatched without violating the hold this turn produced, a CI-cheap candidate further down the list gets a chance instead of the slot sitting idle. **This holds unchanged under milestone-aware ranking too** — `P0` sits at the same global tier-1 position in both orders, so "a CI-heavy P0 is never skipped in favor of a CI-cheap P2" is exactly as true whether or not this repo has opted into `milestones.prioritize_dispatch`.

Skip this bias entirely (fall straight through to the "no compatible job" park below, unchanged) unless BOTH:

- `ci.prefer_cheap_under_backpressure` resolves to `true` (config default `true` — set `false` to restore #1156's unconditional-hold behavior), AND
- `.ci_capacity.cheap_ci_globs` (from session state, written once at [setup step 1.37](./setup/01-repo-recovery.md#137-detect-ci-cheap-path-availability-1157)) is non-empty — a repo with no path-gated CI has no cheap lane to bias toward, so the bias is a documented no-op there regardless of the config knob.

When both hold, scan `ready_issues` **in its existing priority order** — do not re-rank it — for the first candidate that is BOTH otherwise dispatch-eligible (passes the same collision / soft-cap / label checks any other candidate this turn would) AND CI-cheap:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
cheap_globs=$("${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" read --session-id "<session-id>" --path ".ci_capacity.cheap_ci_globs" 2>/dev/null)

# For each candidate <N> in ready_issues, in existing priority order:
candidate_text="<issue title>\n<issue body>"
candidate_paths=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ci-cheap-path.sh" --extract-paths "$candidate_text")
verdict=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-ci-cheap-path.sh" --match "$candidate_paths" "${cheap_globs:-}")
# verdict = "match" -> this candidate's mentioned file paths are ALL covered
# by the repo's paths-ignore glob list; it is CI-cheap. Stop scanning and
# dispatch THIS candidate for the freed slot (normal dispatch mechanics
# unchanged — same Agent-tool / Workflow-substrate call the "Job found"
# branch below would use for any other pick).
```

**Never bias on zero evidence.** `--match` (per [`detect-ci-cheap-path.sh`](../../scripts/detect-ci-cheap-path.sh)) always returns `no-match` when either input is empty — a candidate whose title/body mentions no file path at all is never assumed cheap, and a repo with an empty glob list never matches anything. This mirrors the [inline-trivial](./inline-trivial.md) fast path's own conservative posture: the heuristic only fires on a positive, extractable signal, never a guess.

**No CI-cheap candidate found among `ready_issues`** → fall through to the "no compatible job" park below exactly as [#1156](https://github.com/mattsears18/shipyard/issues/1156) already documented — the `idle_reason` stays `parked (CI queue backpressure: ...)` (optionally append `; no CI-cheap candidate available` for operator visibility, e.g. via `/shipyard:status`). **A CI-cheap candidate IS found** → dispatch it for this slot this turn (the normal dispatch call below — this bias changes *which* candidate gets picked, never the dispatch mechanics themselves) and note the reason in the per-slot dispatch metadata / session log, e.g. `ci-cheap bias: dispatched #<N> under backpressure (queued=<Q> > threshold=<T>) — candidate paths (<paths>) match cheap-path glob(s) (<globs>)`.

**Disk-space backpressure check (issue [#1261](https://github.com/mattsears18/shipyard/issues/1261)) — run before filling ANY freed slot, same posture as the queue-depth check above.** Read [`disk-space-guard.md`](./disk-space-guard.md) now and run it in full — a bounded `reap-stale` sweep whenever free space on `.claude/worktrees` drops below `worktree_reap.disk_free_floor_mb`. Never blocks dispatch; feeds `disk_free_mb=` into step E below.

Apply the **dispatch rules** to pick the next job:

- **Job found** → issue the dispatch call **in this turn**: the default `Agent` call (`subagent_type` + `isolation: "worktree"`, per [dispatch-rules.md's Agent-tool section](./dispatch-rules.md#agent-tool-dispatch--the-default-dispatch-shape-825)), or, under the `Workflow`-substrate alternate, pre-provision the worker's worktree yourself first and then issue the `Workflow` tool call (per [that section](./dispatch-rules.md#workflow-substrate-dispatch--an-alternate-dispatch-shape-825)). Multiple slots freed by step B fill with parallel calls in the same message.
- **No compatible job** → record *why* the slot stays empty. The reason feeds into step E's invariant line. Examples: `parked (all ready_issues collide with in_flight paths)`, `parked (all ready_issues collide with in_flight lockfile sections: overrides×1, dependencies×1)`, `parked (all ready_issues blocked by soft-cap on CLAUDE.md, ×3 active)`, `parked (all queues empty after backlog re-check)`, `parked (CI queue backpressure: queued=25 > threshold=20 = pool_total(4)×5)` (the queue-depth backpressure check above).
- **Dispatch call refused by the harness permission classifier** → the dispatch never happened: no agent ran, **no completion notification coming**. Follow [dispatch-rules.md § "Dispatch denied by the harness permission classifier"](./dispatch-rules.md#dispatch-denied-by-the-harness-permission-classifier-718) ([#718](https://github.com/mattsears18/shipyard/issues/718)) — record it in `dispatch_denials`, **reap the worktree you pre-provisioned for the refused dispatch** (it is orphaned: no worker, no `.in_flight` slot, and no other reap path will find it), take **at most one** *accuracy-correcting* re-dispatch (never a wording retry against the classifier), hand back to the human on a second denial, and fill the slot with the next candidate in the same turn. Do **not** run step A against a denial and do **not** write an `.in_flight` slot for it.

**Per-slot dispatch metadata write-through.** When a new slot lands in `.in_flight`, the orchestrator's write-through call MUST include the slot's `started_at` ISO-8601 UTC timestamp alongside `kind` / `target` / `claimed_paths` / the dispatch id / **`model`** (plus the pre-provisioned `worktree_path` under the `Workflow`-substrate alternate). **The write-through runs only AFTER the dispatch call is accepted** — the dispatch id doesn't exist until it returns, and a speculative pre-write would leave a phantom slot behind on the classifier-denial path ([#718](https://github.com/mattsears18/shipyard/issues/718)). The timestamp powers [`/shipyard:status`](../status.md)'s `ELAPSED` column and the stale-worker detection — without it, every worker would render as "elapsed 0s, stale" the moment a new orchestrator instance reads the file. Per-slot `progress_current` / `progress_total` start as `null` and are managed by the worker via `session-state.sh set-progress --slot <id>` if the worker is doing batch work (the typical issue-work / fix-checks-only worker doesn't bother — the kind alone is enough).

**`model`** ([#978](https://github.com/mattsears18/shipyard/issues/978)) is the exact value [the per-dispatch model-resolution rule](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) computed for this dispatch a moment earlier — `<dispatch_model>` (`opus`/`sonnet`/`haiku`/`fable`) if non-empty, or the literal string `"default"` if the resolver returned empty (meaning the shim's frontmatter pin, or the `Workflow` runtime's own default, applies instead). Write it through **unconditionally** — never omit the field, and never write it *only* when it differs from a mode's usual tier. The whole point is that a slot's recorded `model` is now a durable, inspectable claim about what this dispatch was told to run on, independent of whether the model was actually attached to the dispatch call correctly: a repo with `models.issue_work` configured but a dispatch call that (through orchestrator error) omitted the `model` parameter still ran on *some* model, and recording what was *supposed* to be attached here — rather than skipping the write because "it's just the default" — is what makes that class of silent omission inspectable after the fact via `/shipyard:status` or the end-of-session summary, instead of undetectable (the exact gap #978 reports; this in_flight field cannot itself confirm which model the dispatch call actually invoked — the harness exposes no such signal — but it stops the intended model from disappearing without a trace). Example shape — see [the schema doc](./session-state-file.md#schema) for the canonical fields:

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
# --allow-degraded-init survives the mid-session file-disappear race
# (issue #281). Without it, a concurrent /do-work session's orphan-sweep
# reaping this file mid-session would surface as exit 3 on the next
# update call, leaving working memory out of sync with the file.
"${CLAUDE_PLUGIN_ROOT}/scripts/session-state.sh" update \
  --session-id "<session-id>" \
  --allow-degraded-init --degraded-init-repo "<owner/repo>" \
  --set ".in_flight.<slot-id> = {
    kind: \"issue\", target: <N>,
    claimed_paths: { hard: [...], soft: [...] },
    agent_id: \"<agent-uuid>\",
    model: \"<dispatch_model, or the literal string default>\",
    started_at: \"<iso-8601 UTC now>\",
    progress_current: null,
    progress_total: null,
    progress_updated_at: null
  }"
```

### D. Periodic refresh

**Drain guard:** skip during drain — refresh is pointless when no new work will be dispatched.

Otherwise, the refresh is **event-driven with adaptive backoff** (see [refresh trigger rules](#refresh-trigger-rules) below). When a refresh fires, it runs three sub-steps (plus, on a merge-completion trigger, the [own-the-tail sweeps](#d-tail-own-the-tail-merge-completion-sweeps-phase-c--663) in D-tail):

1. **Divert-checks refresh** — re-run step 4.5 (main CI + all-authors failing PR count). Update `main_ci` and the `failing_pr_count_all` cache. Enqueue or clear `divert_queue` entries per the rules in step 4.5. This is the only place outside setup where diversions are evaluated. **`--fast` skip:** when `--fast` was set at session startup, skip this sub-step every time step D runs — leave `main_ci.status` and `failing_pr_count_all` as `"unknown"` / `0` for the session. The divert-checks cost is the mechanism `--fast` traded away; re-enabling them mid-session would undercut the savings.
2. **Failed-PR scan (@me)** — re-run the step-5 query. Append any newly-red PRs to `failed_prs` (deduped against entries already in `in_flight` or `failed_prs`). **Also run [setup step 5.7's inherited-DIRTY snapshot](./setup/04-backlog-divert.md#57-seed-inherited-dirty-prs-into-session_prs-cross-session-drain-hand-off)** here — it's the same `@me` open-PR list, projected for `mergeStateStatus == "DIRTY"` + healthy checks instead of for failing checks. Append the resulting numbers to `session_prs` (deduped) so the end-of-session drain owns them. At C=1, where the setup-time 5.7 snapshot is deferred (per its lazy-load carve-out), this is where the seeding actually happens; at C≥2 it's a cheap idempotent re-confirm (the dedup makes a re-seed a no-op if setup already ran it). This catches PRs that go DIRTY *mid-session* too — a sibling merge can DIRTY an inherited PR after setup ran, and without re-snapshotting here it would fall back into the blackhole until drain.
3. **Scope refill + auto-triage pass (background)** — gated on `ready_issues` size `< --concurrency`. Fire the next `2 × concurrency` from `raw_backlog` as background scoping agents (`run_in_background: true`) — do NOT wait for them to return before proceeding to step C's dispatch. As each background scope agent completes, apply the same per-entry handling as the [initial scope pre-flight](./setup/06-scope-preflight.md#6-initial-scope-pre-flight) (ready entries → `ready_issues` immediately; deferred entries → run the per-class `evidence_pointer` validator ([#302](https://github.com/mattsears18/shipyard/issues/302)) — valid defers get the comment + `deferred_issues` recording path, malformed defers get the rejection path that pushes the issue back to `raw_backlog`). The periodic auto-triage label-stamping (P0/P1/P2) also runs here (synchronously, before firing the background scope burst). Sub-steps 1 and 2 run regardless of queue depth — they check external state.

Background refill means the ~30s scope-wait at step C never blocks a slot again once the initial batch (step 6) has seeded at least one `ready_issues` entry. See [RATIONALE → Why background refill matters](../do-work-RATIONALE.md#why-background-refill-matters) for the synchronous-model comparison.

The refresh runs in the same turn as the completion handler and does **not** delay step C's dispatch. If `main_ci.status`, `divert_queue` membership, or the 10-threshold for `failing_pr_count_all` changed, also print the status line (see step 6.5).

#### Refresh trigger rules

The orchestrator maintains a small refresh tracker — three fields, all session-scoped — alongside the twelve [orchestrator state](../do-work.md#orchestrator-state) structs:

- **`refresh_last_at`**: timestamp of the most recent refresh that actually ran. Initialized to the moment step 4.5 completes at setup.
- **`refresh_last_snapshot`**: cached `{ main_ci_status, failing_pr_count_all, failed_prs_size }` from the most recent refresh — used to compute deltas.
- **`refresh_zero_delta_streak`**: integer count of consecutive refreshes that produced **no change** vs `refresh_last_snapshot`. Initialized to `0`. Incremented when a refresh produces zero delta; reset to `0` the moment any refresh produces a change.

A refresh fires on a given turn when **any** of the following triggers is true:

1. **Just-reconciled `shipped` return** — step A reconciled a `shipped #<N> via PR #<M>`, `shipped main-ci-fix via PR #<M>`, or `shipped pr-batch-fix via PR #<M>` return this turn. A new PR landed in the world, so `failed_prs` (the new PR's CI may flip red between dispatch and check completion) and `divert_queue` (a newly-opened PR can resolve a main-CI divert) both want a refresh. Fires unless the adaptive-skip carve-out in rule 4 applies.

   **`merged-direct-ungated` sub-case (issue [#457](https://github.com/mattsears18/shipyard/issues/457)) — fires unconditionally.** When the reconciled `shipped` return carries the `auto-merge: merged-direct-ungated` suffix, the PR already landed on the default branch *before* its CI completed (gh admin-direct-merged on a repo with no required status checks — see [worker-preamble § "Auto-merge + snapshot-and-return pattern" step 1.5](../../skills/worker-preamble/auto-merge.md#auto-merge--snapshot-and-return-pattern)). The merge commit's build is still in flight and may flip `main` red with no PR-level gate having caught it. Treat this exactly like trigger 3 (the time-based fallback): the refresh **fires unconditionally**, exempt from the rule-4 adaptive-skip carve-out, so a `refresh_zero_delta_streak >= 3` cannot defer the very refresh that would catch the ungated-merge fallout. The refresh re-runs the [step 4.5a main-CI divert check](./setup/04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) against the default branch; if the post-merge build has gone red, the divert enqueues a `fix-main-ci` worker as usual. No new state field is needed — the existing main-CI divert machinery is the watch; this rule just guarantees the refresh that drives it isn't skipped.
2. **Just-reconciled `green #<M>` / `noop: already green #<M>` / `flake #<M>: re-ran failed jobs` from fix-checks** — step A reconciled a fix-checks-only return that resolved or re-ran a previously-red PR. The all-authors failing-PR count and the `failed_prs` queue just dropped (the PR is green, or its failed jobs are re-running rather than concluded-red); refresh to recompute the divert-checks and pick up any newly-red PRs that need attention. Fires unless the adaptive-skip carve-out in rule 4 applies.
3. **5-minute time-based fallback** — if `now - refresh_last_at >= 5 minutes` AND no other trigger has fired in that window, run a refresh anyway. Covers the case where the orchestrator is idle waiting on long-running CI and external state may have drifted (a human pushed to main; another author opened/closed PRs; new issues got filed). **Fires unconditionally** — the adaptive-skip carve-out in rule 4 does *not* defer this trigger.
4. **Adaptive-skip carve-out (applies to triggers 1 and 2 only).** When trigger 1 or 2 would otherwise fire but `refresh_zero_delta_streak >= 3`, downgrade the event-driven trigger to a deferral — skip this refresh and let trigger 3 (the 5-min fallback) pick it up. The streak indicates external state isn't changing meaningfully relative to completion cadence; saving the `gh` calls until the time-based check is the win. The streak resets the moment any refresh (event-driven or time-based) produces a change. **Trigger 3 is exempt from this carve-out** — the time-based fallback is the unconditional safety net and runs regardless of the streak. **The trigger-1 `merged-direct-ungated` sub-case is also exempt** (issue [#457](https://github.com/mattsears18/shipyard/issues/457)) — a PR that landed on the default branch before its CI completed is precisely the kind of state change a quiet streak would otherwise mask, so its refresh fires regardless of `refresh_zero_delta_streak`.

Triggers that explicitly do NOT fire a refresh: `blocked` / `errored` / non-resolving `noop` returns; `rebased` returns from drain-phase fix-rebase. See [RATIONALE → Refresh non-triggers](../do-work-RATIONALE.md#step-d--refresh-trigger-rules-worked-example) for the per-return discussion.

**Delta computation (drives the backoff streak).** After each refresh that actually ran, compare the new snapshot against `refresh_last_snapshot`:

- `main_ci.status` changed (e.g., `green → red`, `red → pending`, `unknown → green`, etc.) → **change**.
- `failing_pr_count_all` crossed the 10 threshold in either direction (e.g., `8 → 11` or `12 → 9`) → **change**. Movement within a side of the threshold (e.g., `12 → 15`) is not a change for backoff purposes — the divert decision doesn't flip.
- `failed_prs` gained any new entries during this refresh's failed-PR scan → **change**. Decrements aren't a change here — entries leave `failed_prs` via step B's slot release / step C's dispatch, not via the refresh.

If any of the three is a change → set `refresh_zero_delta_streak = 0`, update `refresh_last_snapshot`, update `refresh_last_at`. Otherwise → increment `refresh_zero_delta_streak`, still update `refresh_last_at`, leave `refresh_last_snapshot` unchanged.

See [RATIONALE → Refresh trigger worked example](../do-work-RATIONALE.md#step-d--refresh-trigger-rules-worked-example) for a step-by-step trace of the adaptive backoff on a quiet 30-completion session.

#### D-tail. Own-the-tail merge-completion sweeps (phase c — [#663](https://github.com/mattsears18/shipyard/issues/663))

Phase c of the [#659](https://github.com/mattsears18/shipyard/issues/659) own-the-tail epic adds three behaviors so `/do-work` drives its own PRs to merged **without** a human nudging a stalled tail. All three are **best-effort sweeps** (fire-and-forget; a failed sweep step never aborts the reconcile turn) and run **only on a refresh turn that a `shipped` / `green` / `flake` reconcile triggered** (triggers 1 and 2 in the [refresh trigger rules](#refresh-trigger-rules) above) — i.e. exactly when a PR just landed or a red PR just cleared, which is when a tail can newly stall. They do NOT run on the 5-min time-based fallback (nothing merged, so no dependent went stale) and are **skipped entirely during drain** (drain owns its own merge-train sweeps).

**1. CI auto-heal recap (flake classification + rerun discipline).** The single-PR half of CI auto-heal already lives in the `fix-checks-only` worker's [Infra-flake classification and re-run](../../agents/issue-worker/fix-checks-only.md#infra-flake-classification-and-re-run-load-bearing) ([#654](https://github.com/mattsears18/shipyard/issues/654)) and the orchestrator's [A.1 `flake #<M>` reconcile](#a1-parse-the-return-string). Nothing new is needed here for the *single-PR* flake — the worker classifies (four-signal infra gate + local-gate pass + no deterministic code error), re-runs the failed jobs, and returns `flake #<M>`; the orchestrator watches the re-run's outcome via the next PR-triage tick. This is the **classification-gated, non-speculative** rerun path — it is deliberately NOT gated by `ci.skip_speculative_rerun` (which governs only *blind*, undiagnosed reruns the orchestrator never issues); see [dispatch-rules.md §2c](./dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) for the full reconciliation. Sub-sweep 3 below extends flake/auto-repair thinking from one PR to a **cross-PR recurring signature**.

**2. Cross-PR dependency-update sweep (`gh pr update-branch`).** When a session PR merges, it advances the default branch — and any *other* open session PR whose branch is now merely **behind** that base (a stale base, no conflict) may sit unmergeable until something updates it. On a repo whose base-branch protection is **non-strict** (`strict_required_status_checks_policy == false`), GitHub does **not** auto-update behind PRs, so a shared-file fix that unblocks several dependents leaves them all stranded `BEHIND` with no push to re-trigger their merge. The sweep updates them directly — far cheaper than a full `fix-rebase` worker dispatch (no worktree, no agent, no Haiku spend), and correct precisely because a *behind-but-not-conflicted* PR needs only a base merge, not a conflict resolution.

For each open `@me` PR in `session_prs` (excluding any already in `in_flight` / `failed_prs` / `rebase_blocked_prs`), snapshot `mergeStateStatus` + the latest-per-name rollup, then:

```bash
# One batched projection over the session PRs (reuse the drain-phase gh-batch.sh
# pr-status shape). For each PR classify: BEHIND + healthy → update-branch;
# DIRTY → dispatch fix-rebase now if the three #1034 conditions hold, else
# leave for drain's fix-rebase; anything else → no-op this sweep.
gh pr view <M> --repo <owner/repo> \
  --json mergeStateStatus,statusCheckRollup,headRefName \
  --jq '{merge: .mergeStateStatus,
         fails: ([.statusCheckRollup | group_by(.name)
                  | map(sort_by(.completedAt // .startedAt // "") | last) | .[]
                  | select((.conclusion // .status // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))] | length)}'
```

- `merge == "BEHIND"` AND `fails == 0` → run `gh pr update-branch <M> --repo <owner/repo>` (merges the base into the head; GitHub re-triggers the PR's checks on the fresh head). This is the shared-fix-unblocks-dependents case. Log `[dep-update] PR #<M> was BEHIND after a sibling merge; ran gh pr update-branch (#663)`.
- `merge == "DIRTY"` → do **NOT** `update-branch` (it would fail on the conflict). **Dispatch a mid-session `fix-rebase` worker now instead of waiting for the drain, when all three [#1034](https://github.com/mattsears18/shipyard/issues/1034) conditions hold** — `<M>` is already confirmed in `session_prs` and DIRTY (this branch's own precondition); no `in_flight` entry already holds `<M>`'s head branch; and a `--concurrency` slot is free. Dispatch it exactly like a drain-phase `fix-rebase` (same worker, same `agents/issue-worker/fix-rebase.md` spec, via the normal step-C dispatch mechanism so it counts against the `--concurrency` cap like any other candidate) — [§4.6](../../agents/issue-worker/fix-rebase.md#46-version-coordinated-manifest--changelog-re-number--trivial-resolution-issue-466)'s trivial-conflict-or-bail policy is what makes dispatching speculatively safe: a conflict confined to the coordinated manifest `.version` + CHANGELOG rows resolves deterministically and the branch re-enters the merge train immediately (restoring the merge ref so CI can actually run, rather than sitting CI-dark for the rest of the session); a wider conflict bails `blocked rebase #<M>: ...` exactly as it would at drain time, and [A.1's `blocked rebase` reconcile](#a1-parse-the-return-string) applies unchanged (`rebase_blocked_prs`, PR comment, no re-dispatch this session). **When any of the three conditions doesn't hold** (a worker already holds the branch, or no slot is free) — leave it. The [drain phase's `D_dirty` → fix-rebase path](./drain.md#drain-protocol) owns it as the backstop; a mid-session DIRTY PR is already re-seeded into `session_prs` by [step D sub-step 2's inherited-DIRTY snapshot](#d-periodic-refresh) either way. See [RATIONALE → Don't dispatch fix-rebase mid-session outside the three conditions](../do-work-RATIONALE.md#dont-dispatch-fix-rebase-mid-session-outside-the-three-conditions-issue-1034) for the session repro that motivated this.
- Any other `mergeStateStatus` (`CLEAN` / `BLOCKED` / `UNKNOWN` / `HAS_HOOKS`) → no-op this sweep.

**Bound the CI-minute cost.** Each `update-branch` re-triggers a full CI run on the updated head, so treat it like any other check-triggering action: skip the update when `ci.skip_drain_rebase == true` (the same "don't burn CI to un-stale a base" stance applies to `update-branch`, which is a cheaper rebase) and count each update against a per-poll ceiling so a large fan-out doesn't fire N simultaneous CI runs. `gh pr update-branch` is fire-and-forget — on any error (conflict raced in, permission denied, PR merged between snapshot and update) log `[dep-update] PR #<M> update-branch failed: <reason>; leaving for drain` and continue. This sweep never dispatches a worker and never blocks the turn.

**3. Recurring-failure-signature auto-repair.** A *single* red PR is handled by the [failed-PR scan → fix-checks dispatch](#d-periodic-refresh) path. But when the **same failure signature** reddens **multiple** PRs, that's a shared root cause (a common dependency bump broke every PR's typecheck; a shared helper regressed; a new lint rule fires repo-wide) — fixing it once on a canonical PR unblocks the whole cohort, and treating each red PR as an independent fix-checks target wastes a dispatch per PR re-solving the same defect. This sub-sweep detects the recurrence and dispatches **one** targeted fix-checks against the canonical PR, surfacing the pattern so the operator sees a systemic cause rather than a scatter of unrelated reds.

Maintain a **session-local** working-memory map (not mirrored to the session-state file, same posture as `main_ci_fix_attempts`):

```
recurring_failure_signatures = { <signature> → { prs: [<#M>...], canonical_pr: <#M|null>, dispatched: <bool> } }
```

- **Signature** is the stable cross-PR key: `<workflow-name>|<job-name>|<normalized-first-deterministic-error-line>`, where the error line is the first `error TS####` / lint-rule id / assertion message / compile error from the failing job's log, stripped of PR-specific paths and line numbers so the *same* defect on two PRs produces the *same* key. An **infra-flake signature** (cancelled-required-jobs / webserver-boot-timeout / setup-job-failure / runner-lost — the [#654](https://github.com/mattsears18/shipyard/issues/654) classes) is **excluded** from this map: those are per-PR runner starvation, already handled by the worker's flake rerun + the chronic-flake attempt bound, and are NOT a shared *code* root cause. Only **deterministic code errors** are keyed here.
- **Recording.** On each failed-PR scan (step D sub-step 2), for every red PR compute its signature from the latest-per-name failing job's log and append `<#M>` to `recurring_failure_signatures[<signature>].prs` (deduped).
- **Detection + auto-repair.** When a signature's `prs` set reaches **≥ 2 distinct PRs** AND `dispatched == false`, it's a recurring class. Set `canonical_pr` to the lowest-numbered affected PR, dispatch **one** `fix-checks-only` worker against it (via the normal step-C fix-checks dispatch, respecting the `--concurrency` cap and the `ci.*` pre-dispatch gates), set `dispatched = true`, and log `[recurring-failure] signature <sig> hit <N> PRs (<list>); dispatching canonical fix-checks against #<canonical_pr> (#663)`. Do **not** dispatch fix-checks against the *other* affected PRs this turn — the canonical fix, once merged, advances the base; sub-sweep 2's dependency-update sweep then un-stales the siblings and their re-run picks up the shared fix. If the siblings are still red after the canonical fix merges (the fix didn't cover them), the next failed-PR scan re-keys them under a *new* signature (the error moved) or they fall through to normal per-PR fix-checks.
- **Thrash guard.** `dispatched: true` is one-shot per signature — the map never re-dispatches the same signature, so a canonical fix that doesn't fully resolve the cohort can't loop. Reset a signature's entry (drop it from the map) only when its `prs` all go green (the class cleared). This mirrors `main_ci_fix_attempts`'s converge-on-green discipline: a working fix clears the counter; a genuinely-stuck shared cause surfaces in the [end-of-session summary](./cleanup-summary.md#end-of-session-summary) as a recurring-signature cohort for the next session (or a human) rather than re-dispatching forever.

### E. Invariant line (end of every steady-state turn)

After A → B → C → D, the **last thing emitted in the turn** is a single-line invariant check. Whenever you end a turn without one, you have skipped step C — go back and fix it. The `state=<state>` token also makes the per-turn write-through to the [session state file](../do-work.md#session-state-file) visible in-line. Every other token's full semantics (what it means, when it's set, and the divergence smells it surfaces) is documented in [`invariant-line.md`](./invariant-line.md) — `tokens_attributed`, `last_fresh_fetch`, `unfiltered_open_count`, `me_assigned_open`, `operator_q`/`operator`, `peers`, and `disk_free_mb` all live there; a missing token is a contract violation of the same severity regardless of which file documents it.

**Steady-state format** (after a normal dispatch turn):

```
[invariant] in_flight=<n>/<concurrency> · ready_issues=<r> · scope_bg=<s> · failed_prs=<f> · divert_queue=<dq> · raw_backlog=<b> · unfiltered_open_count=<u> · me_assigned_open=<m> · operator_q=<oq> · operator=<active|skipped|unreachable> · peers=<p> · disk_free_mb=<N|"unknown"> · dispatched_this_turn=<k> · defers_this_turn=<dt> · state=<state> · tokens_attributed=<true|false> · last_fresh_fetch=<HH:MM:SS|"never">
```

**Idle-proof format** (used ONLY when step C produced no dispatch AND `in_flight < concurrency`):

```
[invariant] in_flight=<n>/<concurrency> · ready_issues=<r> · scope_bg=<s> · failed_prs=<f> · divert_queue=<dq> · raw_backlog=<b> · unfiltered_open_count=<u> · me_assigned_open=<m> · operator_q=<oq> · operator=<active|skipped|unreachable> · peers=<p> · disk_free_mb=<N|"unknown"> · dispatched_this_turn=0 · defers_this_turn=<dt> · state=<state> · tokens_attributed=<true|false> · last_fresh_fetch=<HH:MM:SS|"never"> · idle_reason="<reason>"
```

`scope_bg=<s>` is the count of background scoping agents currently in flight (fired by step 6 or step D's scope-refill). When `<s> > 0`, results are arriving asynchronously into `ready_issues` — a `parked (scope refill in flight)` idle_reason is valid and expected. When `<s> == 0` and `ready_issues == 0` and `raw_backlog > 0`, that is a gap: no scoping is in progress and no scoped candidates are ready — fire a background scope-refill burst this turn before ending it.

`<state>` is one of:
- `written` — the turn's `session-state.sh update` call succeeded.
- `noop` — no state mutation happened this turn (rare; mostly drain-poll turns where nothing moved).
- `degraded` — a `session-state.sh` write call (`update`, `bump-tokens`, `record-stall`, `record-denial`, or any other write-class subcommand) either **ran and returned non-zero** (the orchestrator logged the `[session-state] update failed: …` advisory) **or was refused outright by Auto Mode's classifier before it ever ran** ([#1302](https://github.com/mattsears18/shipyard/issues/1302) — the classifier denies the whole `Bash` tool call, so there is no exit code and no stderr from the script itself; the orchestrator's own `[session-state] … denied or failed: …` catch-all around the call, per the `record-stall`/`record-denial` patterns above, is what surfaces it). **Sticky, not per-turn** ([#1302](https://github.com/mattsears18/shipyard/issues/1302)): the first denied/failed write of the session sets the session-local `session_state_degraded_since` timestamp (held in working memory alongside `dispatch_denials` / `stalled_dispatches`, never itself written into the possibly-broken file), and `state=degraded` MUST keep appearing on **every subsequent turn's** invariant line — never silently reverting to `written`/`noop` — until a write-class call actually succeeds again. On the turn a write next succeeds, clear `session_state_degraded_since` and resume normal `written`/`noop` reporting; log `[session-state] mirror recovered — was degraded since <timestamp>` on that turn so the recovery, not just the onset, is visible in the transcript.
- `disabled` — step 1.5's `init` failed and the session is running without the file mirror.

A missing `state=` token is the same contract violation as a missing invariant line — re-run the write-through then re-emit. **An orchestrator that emits `written` or `noop` on a turn while `session_state_degraded_since` is still set (no recovering write happened this turn) is itself a contract violation** — that is exactly the silent-degrade failure mode issue [#1302](https://github.com/mattsears18/shipyard/issues/1302) reports: an eight-hour session that kept reporting a healthy mirror after its very first denied write. See [`cleanup-summary.md`'s "Session-state mirror degraded" block](./cleanup-summary.md#end-of-session-summary) for how the onset (and recovery, if any) is surfaced at end-of-session.

The `idle_reason` MUST be one of: `all queues empty (terminating after in_flight drains)`, `draining=true`, `all ready_issues collide with in_flight paths`, `all ready_issues blocked by soft-cap on <path> (×<N> active)`, `all ready_issues collide with in_flight lockfile sections (<section>×<N>, ...)`, or a concrete diagnostic string. Vague reasons ("waiting for completions", "merge train draining", "nothing to do right now") are NOT acceptable. The first value (`all queues empty (terminating after in_flight drains)`) marks **dispatch-loop** termination + drain handoff, **not** session completion ([#662](https://github.com/mattsears18/shipyard/issues/662)) — the drain then drives the tail and asserts the [full-completion condition](./drain.md#termination-assertion) (every session PR merged or confirmed external-blocked) before the session actually ends.

`defers_this_turn=<d>` is the count of issues added to `deferred_issues` during this turn. It is incremented each time a scope-agent returns a deferred shape (or an orchestrator-side mid-session defer is logged). Initial value per turn: `0`. A turn where `defers_this_turn > 0` is always visible in the invariant line regardless of whether `dispatched_this_turn > 0`.

**Self-check before ending the turn:** Run ALL THREE self-checks:

1. **Under-dispatch check.** If `in_flight < concurrency` AND `ready_issues + failed_prs + divert_queue + raw_backlog > 0` AND `dispatched_this_turn == 0`, that is a programming error in your own turn — re-run step C, find what was skipped, dispatch, and re-emit the invariant line. See [RATIONALE → Invariant line](../do-work-RATIONALE.md#step-e--why-the-invariant-line-is-load-bearing) for common causes.

2. **Over-defer check (the premature-drain-prevention check).** If `defers_this_turn > 0` AND `dispatched_this_turn == 0` AND `in_flight < concurrency`, that is the **over-deferring while idle** pattern — the exact condition that produces premature drain by constructing an empty-queue state via self-defers. **Do not end the turn.** Instead:
   - Re-examine each `deferred_issues` entry added this turn: does the defer reason name a specific blocker issue or PR? If yes, look up its current state (`gh issue view <blocker> --json state` or `gh pr view <blocker> --json state`). If the blocker is already CLOSED or MERGED, the defer reason is stale — remove the entry from `deferred_issues`, move the issue back to `raw_backlog`, and re-run step C.
   - If no stale defers were found, verify the turn had a legitimate reason for zero dispatches. A scope-agent batch in flight (`scope_bg > 0`) is a valid reason. All `ready_issues` colliding with `in_flight` paths is a valid reason. Empty `in_flight` + empty queues + all issues deferred is **not** a valid reason — that means the orchestrator is about to declare termination driven entirely by self-defers, which is the failure mode issue [#246](https://github.com/mattsears18/shipyard/issues/246) documented. In this case, add `idle_reason="defers_this_turn=<d> with no dispatches and open slots — verify defer reasons before proceeding to drain"` to the invariant line and do NOT proceed to drain; instead fire a fresh termination-assertion step 4 fetch to surface any issues the defers may have hidden.
   See [RATIONALE → Over-defer self-check](../do-work-RATIONALE.md#step-e--over-defer-self-check-rationale) for the failure mode this prevents.

3. **Token-presence check ([#1194](https://github.com/mattsears18/shipyard/issues/1194)).** Before the invariant line leaves the turn, literally re-read the string you are about to emit and confirm every mandatory token is present in it: `state=`, `tokens_attributed=`, `last_fresh_fetch=`, `unfiltered_open_count=`, `me_assigned_open=`, `operator_q=`, `operator=`, `peers=`, `disk_free_mb=`. Each token already has its own "missing = contract violation" sentence documented above — this check is the enforcement companion those sentences lacked: a rule that only says "this would be a violation" is not the same as a rule that is actually checked before the turn ends, and a session can silently omit a required token for its entire duration with nothing catching it (the [#1194](https://github.com/mattsears18/shipyard/issues/1194) repro: `unfiltered_open_count=` absent from every turn of a 6.5-hour session). A token's absence means part of this turn's mandatory work — the state write-through, token attribution, the backlog re-fetch, or the operator preflight — did not actually happen; go back, run whichever step owns the missing token, and re-emit before ending the turn. This is a **shape** check only (is the token present in the string), not a semantic re-validation of the two checks above.


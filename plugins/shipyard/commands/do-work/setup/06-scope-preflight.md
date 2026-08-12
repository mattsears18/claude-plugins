# /shipyard:do-work — Setup phase · scope pre-flight + UI + timing flush

**Setup sub-phase (cluster 4 of 5, part 1 of 3 — [#994](https://github.com/mattsears18/shipyard/issues/994)).** Owns the start of step **6**: the initial scope pre-flight's pre-scope synthetic-defer detectors and the scope-result freshness check. The rest of step 6 (design/arch/epic/spike carve-out, operator-slice + QA-verification carve-outs, per-class evidence shapes) continues in **[`06b-scope-carveouts.md`](./06b-scope-carveouts.md)**; per-returned-entry handling plus steps 6.5 → 6.8 (status-line + state-change-banner UI, setup-timing flush) continue in **[`06c-scope-handling-ui.md`](./06c-scope-handling-ui.md)** — this file was split into three once it grew past the per-`Read` token cap on its own ([#994](https://github.com/mattsears18/shipyard/issues/994); the original single-file split from [#611](https://github.com/mattsears18/shipyard/issues/611) was sized against the 256KB byte limit, not the 25k-token `Read` cap that actually binds). Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`04-backlog-divert.md`](./04-backlog-divert.md). Next: [`06b-scope-carveouts.md`](./06b-scope-carveouts.md) (same cluster, part 2).

### 6. Initial scope pre-flight

> **Just-in-time when `concurrency == 1`.** At C=1 pre-flighting `2 × concurrency` (i.e., 2) candidates at setup is wasted token spend: by the time the single slot returns, rankings may have shifted (new comments, refined issues, closed blockers) and the pre-flighted decisions are stale. Instead, pre-flight **only the top candidate** immediately before each dispatch (inline with step 7 and step C). This converts the upfront batch-scope call into a single just-in-time call per dispatch. The rest of step 6's mechanics — ready/deferred shapes, `claimed_paths` partitioning, `deferred_issues` list, the comment-and-drop for deferred entries — are unchanged; only the timing (upfront vs per-dispatch) and the batch size (2 vs 1) change. Set `ready_issues = []` at startup; populate lazily.

**At C=1, the top candidate still gets the comment thread and a merged-PR check before the dispatch prompt is composed — "inline" is a statement about *who* runs this decision, not license to skip the checks it depends on ([#1162](https://github.com/mattsears18/shipyard/issues/1162)).** "Inline with step 7 and step C" above means the orchestrator can make the ready/deferred call itself, in its own turn, without spinning up a separate scoping `Agent` call for a single candidate — that's the cheap path this note exists to enable, and taking it is fine. It is NOT license to shortcut to an ad hoc, body-only read instead of mechanically running the checks "the rest of step 6's mechanics" already require. Concretely, before composing the dispatch prompt for the top candidate:

- **Read its comment thread** — `gh issue view <N> --repo <owner/repo> --json comments` (reuse an already-fetched projection when one exists; otherwise one cheap call). This is the same read [dispatch-rules.md's comment-thread-grounding rule](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) already requires before asserting any confidence/status claim in the prompt — a prior-session disposition comment, a maintainer's revision of the approach, or a recorded decision all live here and are invisible to a body-only read.
- **Run the [staleness probe](#staleness-probe--has-this-already-landed-on-origindefault-branch-992)'s merged-PR check** — `gh pr list --repo <owner/repo> --state merged --search "<N> in:body" --limit 5 --json number,mergedAt,title`. The step-4 backlog filter only joins against **open** PRs, so a merged PR that advanced the issue without a closing keyword leaves no other trace anywhere in the dispatch path — this is the only place that catches it at C=1.

Neither check licenses an automatic defer on a hit. Per [#1148](https://github.com/mattsears18/shipyard/issues/1148)/[#1154](https://github.com/mattsears18/shipyard/issues/1154)'s posture, a comment or a merged PR is **a reason to look, never an automatic defer** — a false defer silently drops real work, which costs more than a wasted dispatch. Read what turns up and either narrow the dispatch prompt to what's still actually true (the staleness probe's outcome-2 partial-landing shape) or proceed unaffected when nothing material surfaces — but never compose a "this is shippable now" framing that the comment thread or a merged PR would have contradicted.

**Rolling pre-flight (C≥2) — dispatch on the first result, don't wait for all.** The rolling model fires the `2 × concurrency` scoping-agent batch in the background and dispatches as soon as ONE entry lands in `ready_issues`, hiding the remainder of the scope latency behind real worker execution. See [RATIONALE → Rolling pre-flight dispatches on the first result (#233)](../../do-work-RATIONALE.md#step-6--rolling-pre-flight-dispatches-on-the-first-result-issue-233) for the latency this replaced.

**Execution model for C≥2:**

```
step 6 opens timing window
  └── fire 2N scoping Agent calls with run_in_background: true
        ↓ first result arrives → push to ready_issues → step 7 dispatches immediately
        ↓ subsequent results arrive → push to ready_issues (queue fills while workers run)
  timing window stays open until all background scope agents complete
  record-scope-preflight fires after the last background agent returns
```

**Timing instrumentation (issue #238).** Open the timing window before firing the batch; close it after the last background scoping agent returns. The `record-scope-preflight` call is also deferred to that point so `ready-count` and `deferred-count` reflect the full batch.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
SCOPE_START_EPOCH=$(date -u +%s)
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" start \
  --session-id "<session-id>" --phase step_6_scope_preflight 2>/dev/null || true

# ... fire all 2N scoping agents with run_in_background: true ...
# ... step 7 dispatches the moment the first result lands in ready_issues ...
# ... remaining scope results arrive asynchronously and push to ready_issues ...
# ... after the LAST background scope agent completes: ...

SCOPE_END_EPOCH=$(date -u +%s)
SCOPE_ELAPSED=$(( SCOPE_END_EPOCH - SCOPE_START_EPOCH ))

"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" end \
  --session-id "<session-id>" --phase step_6_scope_preflight 2>/dev/null || true

# Record the per-candidate metrics for reporting.
"$CLAUDE_PLUGIN_ROOT/scripts/setup-timing.sh" record-scope-preflight \
  --session-id "<session-id>" \
  --candidates-scoped "$candidates_dispatched" \
  --ready-count "${#ready_issues[@]}" \
  --deferred-count "$deferred_count" \
  --elapsed-seconds "$SCOPE_ELAPSED" 2>/dev/null || true
```

#### Pre-scope orchestrator-side detectors (synthetic defers)

**Before dispatching a scope agent against each candidate, run a small set of mechanical detectors on the issue body.** When a detector fires, the orchestrator synthesizes a deferred entry directly and **skips the scope-agent dispatch** for that candidate — the detector's evidence is already conclusive. See [RATIONALE → Pre-scope orchestrator-side detectors (#346)](../../do-work-RATIONALE.md#step-6--pre-scope-orchestrator-side-detectors-issue-346) for why this defense-in-depth layer exists and the failure mode it prevents.

The detector batch runs once per candidate, synchronously, immediately before the per-candidate scope-agent dispatch. Detectors are cheap pure string-matches against the issue body — no network calls, no `gh` round-trips. A candidate that trips any detector never reaches the scope-agent dispatch step.

**Detector 1 — `.github/workflows/` change proposal.** When the issue body literally contains the path fragment `.github/workflows/` (case-sensitive match; covers both prose mentions like *"add `.github/workflows/security.yml`"* and code-fence headers like ```` ```yaml .github/workflows/ci.yml ````), the body is proposing a CI workflow change. Workers' hard rules ([issue-work.md step 2 + Don't list](../../../agents/issue-worker/issue-work.md), [fix-checks-only.md Don't list](../../../agents/issue-worker/fix-checks-only.md), and the harness's auto-mode classifier) all forbid `.github/workflows/` modifications — a worker dispatched against such an issue produces a branch but can't open a PR. Synthesize a deferred entry:

```
{
  issue: N,
  reason: "Issue body proposes a `.github/workflows/` change — CI workflow modifications are gated to human review (worker hard rules + auto-mode classifier block the PR). Needs a maintainer to evaluate the proposed workflow content for prompt-injection risk, secret-leak risk, and CI-correctness before any worker can ship it.",
  defer_reason_class: "human-decision-required",
  evidence_pointer: "Proposes .github/workflows/<filename-or-path-fragment> change — CI workflow modification requires human review (auto-mode classifier blocks worker dispatch)",
  provenance: "orchestrator-judgment",
  deferred_at: "<current ISO-8601 UTC>"
}
```

`<filename-or-path-fragment>` is extracted by reading the first `.github/workflows/<token>` substring in the body, taking the token up to the first whitespace, backtick, or newline. If extraction fails (e.g., the body just mentions `.github/workflows/` without naming a file), use the literal token `<unspecified>`. The point is the evidence_pointer's structured prefix `Proposes .github/workflows/`, not the file's exact name — the validator (next section) keys on the prefix.

`provenance: "orchestrator-judgment"` is correct here: the orchestrator (not a scope agent) made this defer. Per [`do-work.md`'s `deferred_issues` entry](../../do-work.md#orchestrator-state), `orchestrator-judgment` provenance entries get re-validated by [drain.md 5.a](../drain.md#5a--re-validate-orchestrator-judgment-entries) before drain — that re-validation dispatches a fresh scope agent, which (per the cross-reference at the end of this section) ALSO re-runs the pre-scope detector batch first. The synthetic defer stays valid across re-validation as long as the body still names a workflow path.

**Detector 2 — Claude-Code self-modification target proposal.** The matched path set is **config-driven** via `scope.self_modification_paths` (issue [#591](https://github.com/mattsears18/shipyard/issues/591)) — default `[".claude/settings.json", ".claude/settings.local.json", ".mcp.json", ".claude/hooks/"]`. Resolve the effective array from the merged config at session start (it lives alongside `scope.diagnosis_reuse_hours`); a trailing-slash entry (e.g. `.claude/hooks/`) matches **any path under that directory** (so `.claude/hooks/stop-after-edit.sh` and a bare `.claude/hooks/` both fire). When an issue's **deliverable** is editing one of these paths, the body is proposing a Claude-Code self-modification change. Claude Code's auto-mode classifier treats edits to these paths as **Self-Modification** and applies a HARD BLOCK that is **not cleared by user intent** — even explicit "make this edit" instructions are rejected, so the Edit / Write / Bash-heredoc paths are all blocked at the harness level. A worker dispatched against such an issue burns tokens producing the proposed diff before hitting that wall. The structurally correct outcome is the same as Detector 1: skip the dispatch, defer for human review. See issue [#348](https://github.com/mattsears18/shipyard/issues/348) for the original repro, [RATIONALE → Detector 2 (#348)](../../do-work-RATIONALE.md#step-6--detector-2-claude-code-self-modification-target-proposals-issue-348), and [RATIONALE → Detector 2 extension (#591)](../../do-work-RATIONALE.md#step-6--detector-2-extension-config-driven-paths-claudehooks-deliverable-vs-mention-guard-issue-591) for the failure-mode detail.

**Deliverable-vs-mention guard (avoid false-positives on meta-issues — [#591](https://github.com/mattsears18/shipyard/issues/591)).** A naïve "body contains the path fragment anywhere" match false-positives on **meta-issues that merely _discuss_ these paths in prose** rather than proposing to edit them — most notably issue #591 itself, whose body names all four paths while describing the *detector*, not requesting a config edit. The detector fires only when a configured path appears in a **deliverable context** — i.e. the path is what the issue asks the worker to create or modify — not when it is mentioned incidentally. Apply this two-part test against each configured path fragment found in the body:

1. **Deliverable context (fire).** The path appears in an acceptance-criteria / suggested-fix / "create" / "add" / "edit" / "wire" framing — e.g. *"add a Stop hook to `.claude/settings.json`"*, *"wire MCP servers via `.mcp.json`"*, a code-fence header naming the path as the file to write (```` ```json .claude/settings.json ````), or an acceptance-criteria bullet whose object is the path. This is the case the detector exists for.
2. **Incidental mention (do NOT fire).** Every body occurrence of the path is inside meta-discussion *about* shipyard/do-work machinery — the issue is about the detector, the classifier, the dispatch loop, scope pre-flight, or a config knob, and the path is named as an *example of what the machinery handles* rather than as the file the worker must touch. Signals: the path appears next to words like *"detector"*, *"pre-defer"*, *"scope pre-flight"*, *"Auto-Mode-denied set"*, *"classifier"*, *"denied"*, or appears only inside a `## Repro` / `## Summary` paragraph narrating a prior session. When **every** occurrence is incidental, the detector does NOT fire and the candidate proceeds to a normal scope-agent dispatch.

When in doubt between (1) and (2) — i.e. the body has both a deliverable framing AND meta-discussion — **prefer firing** (defer). A false-defer costs a human one glance at an issue that was actually shippable; a false-pass costs a full ~100k-token wasted worker dispatch, which is the exact failure mode this detector exists to prevent. The asymmetry favors deferring. The one place to NOT fire is when *every* occurrence is unambiguously meta (the #591-about-the-detector shape).

When the detector fires, synthesize a deferred entry:

```
{
  issue: N,
  reason: "Issue deliverable is a Claude-Code self-modification target change (.claude/settings.json, .claude/settings.local.json, .mcp.json, or a .claude/hooks/ file) — the auto-mode classifier applies a HARD BLOCK on edits to these paths that is not cleared by user intent, so no worker can ship the change. Needs a maintainer to apply the proposed diff manually (or, if not running under Auto Mode, to clear scope.self_modification_paths so the worker can ship it).",
  defer_reason_class: "human-decision-required",
  evidence_pointer: "Proposes <self-modification-path> change — Claude-Code self-modification HARD BLOCK requires human application (auto-mode classifier blocks worker dispatch)",
  provenance: "orchestrator-judgment",
  deferred_at: "<current ISO-8601 UTC>"
}
```

`<self-modification-path>` is the first matching configured path fragment found in a deliverable context (checked in `scope.self_modification_paths` order; longer-prefix wins so `.claude/settings.local.json` is reported correctly when both prefixes would technically match, and a `.claude/hooks/<file>` match reports the directory prefix `.claude/hooks/`). If multiple paths are mentioned, report only the first match; the maintainer reading the issue will see the full body. The point — same as Detector 1 — is the evidence_pointer's structured prefix `Proposes .claude/` or `Proposes .mcp.json`, not the exact file. The validator (next section) keys on the prefix family, not the specific path.

**Class: `human-decision-required`, not `confirmed-non-shippable-as-single-PR`.** The deliverable here IS shippable as a single PR — it's one config-file edit blocked by a policy decision (the Auto-Mode classifier's hard block), not by anything multi-phase or dependency-gated. `confirmed-non-shippable-as-single-PR` would mislabel it and hand it to `/decompose-epic`, which would try to shard a one-file edit — nonsensical. See [RATIONALE → Detector 2 extension (#591)](../../do-work-RATIONALE.md#step-6--detector-2-extension-config-driven-paths-claudehooks-deliverable-vs-mention-guard-issue-591) for the full reasoning behind declining the issue's suggested class.

`provenance: "orchestrator-judgment"` is correct here, and the handling steps and cross-references in the Detector 1 section apply unchanged — both detectors share the same recording path (skip the per-class validator; post the standard `Scope-preflight diagnosis (not auto-fixable as a single worker): <reason>` comment with the `<!-- do-work-human-decision-required -->` marker; append to `deferred_issues`; apply `needs-human-review`; remove from `raw_backlog`; increment `defers_this_turn`; do NOT dispatch a scope agent).

**`CLAUDE.md` is intentionally excluded from the matched path set.** Only a narrow subset of `CLAUDE.md` edits (behavior-rule changes) hits the HARD BLOCK; most ship cleanly through workers, so a blanket match would defer substantial shippable work. See [RATIONALE → Detector 2 (#348)](../../do-work-RATIONALE.md#step-6--detector-2-claude-code-self-modification-target-proposals-issue-348) for the full reasoning.

**Detector 3 — Orchestrator-only skill/command invocation proposal ([#1294](https://github.com/mattsears18/shipyard/issues/1294)).** The matched skill/command name set is **config-driven** via `scope.orchestrator_only_skills` — default `["shipyard:update-roadmap", "update-roadmap"]` — resolved the same way as `scope.self_modification_paths` above, at session start. When an issue's acceptance criteria, in a **deliverable context**, explicitly instruct a worker to invoke one of these tokens (e.g. *"run the `shipyard:update-roadmap` skill cold"*, *"step 2: invoke `/shipyard:update-roadmap`"*), the body is asking for something a dispatched `mode: issue-work` worker is structurally forbidden from ever doing: both `shipyard:worker-preamble`'s [`milestone-prohibition.md`](../../../skills/worker-preamble/milestone-prohibition.md) fragment and the named skill's own frontmatter/"Who runs this" section state the orchestrator-only boundary unambiguously. A worker dispatched against such an issue reads the target skill before invoking it (per its own [step 4](../../../agents/issue-worker/issue-work.md#4-implement) instruction), discovers the conflict, and can only return `blocked` — a full dispatch spent to arrive at a foregone conclusion. This is the exact repro [#1294](https://github.com/mattsears18/shipyard/issues/1294) documents (found via `#1244`'s own dispatch). Synthesize a deferred entry:

```
{
  issue: N,
  reason: "Issue acceptance criteria call for invoking an orchestrator-only skill/command (`<name>`) that a dispatched issue-work worker is spec-prohibited from ever invoking (see skills/worker-preamble/milestone-prohibition.md and <name>'s own orchestrator-only boundary) — no worker dispatch can complete this AC as written. Needs a human to run the orchestrator-only skill/command directly (from the orchestrator's own turn, or a maintainer's own session), or to re-scope the issue to the portion that doesn't require it.",
  defer_reason_class: "human-decision-required",
  evidence_pointer: "Proposes invoking orchestrator-only skill/command `<name>` — a dispatched worker cannot invoke it (milestone-prohibition.md / the skill's own orchestrator-only boundary blocks worker dispatch)",
  provenance: "orchestrator-judgment",
  deferred_at: "<current ISO-8601 UTC>"
}
```

`<name>` is the first matching configured token found in a deliverable context (checked in `scope.orchestrator_only_skills` order). If multiple tokens are mentioned, report only the first match.

**Deliverable-vs-mention guard — apply the identical two-part test Detector 2 uses above.** Fire only when a configured token appears in a deliverable/acceptance-criteria framing ("run", "invoke", a numbered AC step whose action is the skill itself) — not when every occurrence is incidental meta-discussion (an issue *about* the orchestrator-only boundary, a retrospective narrating a prior session's `blocked` return, this detector's own spec prose). This guard is what keeps the detector from firing on #1294 itself, which discusses `shipyard:update-roadmap` at length without ever instructing a worker to invoke it. When in doubt between deliverable and incidental, prefer firing — same asymmetry as Detector 2: a false defer costs one human glance, a false pass costs a full wasted dispatch that can only rediscover the same prohibition.

**Whole-issue defer, not a slice.** Unlike Detector 1/2 (which guard an absolute harness-level classifier block with zero possible partial credit), the orchestrator-only boundary is a spec-level prohibition — an issue like this can still have an independently-shippable code portion (exactly what happened when the worker dispatched against #1244 shipped the `milestones` config block while declining to run `shipyard:update-roadmap` itself). This detector defers the issue as originally worded rather than attempting to auto-slice it; a maintainer who wants the safe portion shipped immediately can file a narrower follow-up issue scoped to just that slice, or clear the gate and let a fresh scope pass find the phase-1 slice on its own (scope-preflight's normal phase-slicing bias — see [Design/architecture/epic/spike decisions are in-scope by default](06b-scope-carveouts.md#designarchitectureepicspike-decisions-are-in-scope-by-default-not-a-defer-reason-767) — already applies once a human has cleared the orchestrator-only step or the issue is re-scoped to drop it).

`provenance: "orchestrator-judgment"` and the handling steps from Detector 1 apply unchanged (skip the per-class validator; post the standard `Scope-preflight diagnosis (not auto-fixable as a single worker): <reason>` comment with the `<!-- do-work-human-decision-required -->` marker; append to `deferred_issues`; apply `needs-human-review`; remove from `raw_backlog`; increment `defers_this_turn`; do NOT dispatch a scope agent).

**Handling the synthetic deferred entry.** Apply the same recording path as a scope-agent-returned defer (per [Handling each returned entry → Deferred entries → Recording path](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes)):

1. **Skip the per-class validator.** The orchestrator constructed this entry; its `evidence_pointer` already matches the per-class shape table (`human-decision-required` accepts the `Proposes .github/workflows/` structured prefix — see the [Per-class evidence shapes](06b-scope-carveouts.md#per-class-evidence-shapes--what-evidence_pointer-must-look-like) table below). Running the validator against the orchestrator's own synthesis would be redundant.
2. **Post the comment.** Apply the comment dedupe check (recording-path step 1) and post with the class-specific body marker (`<!-- do-work-human-decision-required -->` for `human-decision-required` defers) per the recording-path step 2 marker table. The maintainer reading the issue sees a clear explanation of why the workflow proposal is gated.
3. **Append to `deferred_issues`** with the synthesized entry exactly as shown above.
4. **Remove the issue from `raw_backlog`** as part of the standard "remove every processed issue number" sweep (line below the per-entry handler).
5. **Increment `defers_this_turn`** by 1 (same as scope-agent defers — feeds step E's invariant line and the pre-drain audit).
6. **Do NOT dispatch a scope agent for this candidate.** The detector's evidence is conclusive; spending a scope-agent's ~30 s + tokens on a defer the orchestrator already knows it will produce is waste.

**This detection lives at the orchestrator, not in the scope-agent prompt** — a prompt instruction isn't a contract and wouldn't survive a stale agent version. See [RATIONALE → Pre-scope orchestrator-side detectors (#346)](../../do-work-RATIONALE.md#step-6--pre-scope-orchestrator-side-detectors-issue-346) for the full argument.

**Future detectors.** The detector batch is intentionally extensible — when a new "worker hard rule conflicts with a recurring body shape" failure mode shows up, file an issue documenting the pattern and add a new detector here. Detectors share the same shape: a pure body string-match → a synthesized deferred entry with `provenance: "orchestrator-judgment"` and a structured `evidence_pointer` that matches the validator's per-class shape. See [RATIONALE → Pre-scope orchestrator-side detectors (#346)](../../do-work-RATIONALE.md#step-6--pre-scope-orchestrator-side-detectors-issue-346) for the extensibility rationale.

**Cross-references for re-validation paths.** [Drain.md 5.a's re-validation](../drain.md#5a--re-validate-orchestrator-judgment-entries) dispatches a fresh scope agent for `orchestrator-judgment` defers and [5.b's re-validation](../drain.md#5b--re-validate-scope-agent-and-cached-diagnosis-entries) does the same for `scope-agent` defers. Both paths re-run the **same per-candidate pre-scope detector batch** documented in this section before firing the scope agent — a re-detected trigger synthesizes the defer again without dispatching the agent. See [RATIONALE → Pre-scope orchestrator-side detectors (#346)](../../do-work-RATIONALE.md#step-6--pre-scope-orchestrator-side-detectors-issue-346) for why this matters.

#### Scope-result freshness check (skip dispatch when a fresh diagnosis comment exists)

**After the pre-scope detector batch, before dispatching a scope agent, check whether a reusable fresh diagnosis already exists on the issue.** This avoids re-dispatching scope agents whose conclusions are already documented as marker-tagged comments on the issue. See [RATIONALE → Scope-result freshness check (#563)](../../do-work-RATIONALE.md#step-6--scope-result-freshness-check-issue-563) for the repro that motivated this.

**The freshness window** is `scope.diagnosis_reuse_hours` (config knob, default 72h). Set to `0` to disable the cache entirely and always dispatch a fresh scope agent.

**Check applies to each candidate** after the detector batch (which runs first — a detector match short-circuits into an `orchestrator-judgment` defer regardless of any cached comment):

1. **Fetch the issue's recent comments.** Use the `comments` field from the step 0 issue-view projection (already in context), or re-fetch with `gh issue view <N> --repo <owner/repo> --json comments`. Look for the **newest comment** whose body opens with one of the class-specific body markers listed in the [Deferred entries → Recording path](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes) table (`<!-- do-work-needs-decomposition -->`, `<!-- do-work-external-dependency -->`, `<!-- do-work-human-decision-required -->`, `<!-- do-work-classifier-undispatchable -->`, `<!-- do-work-time-gated -->`). The `<!-- do-work-needs-decomposition -->` marker maps to `confirmed-non-shippable-as-single-PR`; `<!-- do-work-external-dependency -->` maps to `external-dependency`; both `<!-- do-work-human-decision-required -->` and `<!-- do-work-classifier-undispatchable -->` map to `human-decision-required` — the latter is a **distinct marker for a distinct sub-case** ([#953](https://github.com/mattsears18/shipyard/issues/953)): it is never returned by a scope agent, only synthesized by [`dispatch-rules.md`'s two-denial hand-back](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt) when the harness permission classifier denies dispatch itself (no worker ever ran), as opposed to a scope agent's own read of the issue's content. Both markers share the `human-decision-required` class because both situations resolve the same way — a human either does the work by hand or makes a policy call — but the distinct marker keeps the two provenances distinguishable for `/shipyard:my-turn` and for a human skimming the comment thread. `<!-- do-work-time-gated -->` maps to `time-gated` ([#1165](https://github.com/mattsears18/shipyard/issues/1165)) — a **comment** marker, distinct from the separate `<!-- do-work-blocked-until: YYYY-MM-DD -->` **body** marker the recording path also writes for this class; the comment marker is this freshness check's dedupe/reuse sentinel, while the body marker is what the step-4 dispatch filter actually reads.

   Comments without a recognized marker (plain text, `<!-- shipyard-worker-progress -->`, or other markers) are skipped — they are not scope-preflight diagnosis records.

   If **no** marker-tagged diagnosis comment exists → no cache hit; fall through to normal scope-agent dispatch.

2. **Check freshness: is the newest marker-tagged comment within the reuse window?** Compute `now_utc - comment.createdAt` in hours. If the result is ≥ `scope.diagnosis_reuse_hours` (or if `diagnosis_reuse_hours == 0`) → stale; fall through to normal scope-agent dispatch. Log: `[scope-preflight] #<N> freshness check skipped — newest diagnosis comment is <age>h old (window: <window>h)`.

3. **Check that the issue body hasn't changed since the comment.** Fetch `gh issue view <N> --repo <owner/repo> --json updatedAt -q .updatedAt`. If `updatedAt > comment.createdAt` → the body was amended after the comment was posted; the diagnosis may be stale; fall through to normal scope-agent dispatch. Log: `[scope-preflight] #<N> freshness check skipped — issue body updated at <updatedAt> after diagnosis comment at <comment.createdAt>`.

4. **Check whether a human gate-clear has been signalled since the diagnosis comment ([#569](https://github.com/mattsears18/shipyard/issues/569)).** A human clearing the `needs-human-review` label — or posting a `<!-- do-work-decision-resolved -->` or `<!-- shipyard-resolve-decisions -->` sentinel comment — after the diagnosis comment was posted is an explicit signal that the gate reason no longer holds. Two parallel checks, either of which trips the skip:

   **Signal A — label-timeline check.** Fetch the issue's timeline events:

   ```bash
   gh api repos/<owner>/<repo>/issues/<N>/timeline \
     --paginate --jq '[.[] | select(.event == "unlabeled" and .label.name == "needs-human-review")]
     | sort_by(.created_at) | last'
   ```

   If the most recent `unlabeled` event for `needs-human-review` has a `created_at` **after** the diagnosis comment's `createdAt` AND the actor is a non-bot (actor `type` is not `"Bot"`, or actor `login` does not end in `[bot]`) → a human has explicitly cleared the gate after the diagnosis was posted. Fall through to normal scope-agent dispatch. Log: `[scope-preflight] #<N> freshness check skipped — needs-human-review was removed by <actor.login> at <created_at>, after the diagnosis comment at <comment.createdAt> (human gate-clear overrides cached diagnosis)`.

   **Signal B — decision-resolved sentinel check.** Scan the comments already fetched in step 1 for any comment whose body begins with the `<!-- do-work-decision-resolved -->` sentinel **or** the `<!-- shipyard-resolve-decisions -->` sentinel, and whose `createdAt` is **after** the diagnosis comment's `createdAt`. `<!-- do-work-decision-resolved -->` is the recommended first line of a hand-written maintainer comment that records a decision and clears the gate (see CLAUDE.md § "Decision-resolved sentinel"); `<!-- shipyard-resolve-decisions -->` is the marker `/shipyard:resolve-decisions` (and `/my-turn`'s reused decision-gated walkthrough) posts automatically after interactively walking the maintainer through the same blocking decisions (see [`resolve-decisions.md`'s Record + unblock](../../resolve-decisions.md#record--unblock)). Both sentinels record the identical fact — a human answered the blocking questions — through two different call paths, and must be treated identically here ([#962](https://github.com/mattsears18/shipyard/issues/962)). If a comment carrying either sentinel exists → fall through to normal scope-agent dispatch. Log: `[scope-preflight] #<N> freshness check skipped — decision-resolved sentinel found in comment at <sentinelComment.createdAt>, after the diagnosis comment at <comment.createdAt> (maintainer decision comment overrides cached diagnosis)`.

   If neither signal fires (no post-diagnosis label removal by a non-bot human, and no post-diagnosis `<!-- do-work-decision-resolved -->` / `<!-- shipyard-resolve-decisions -->` comment) → the gate-clear did not post-date the diagnosis; continue to step 5.

5. **Re-validate the cached evidence mechanically.** Parse the `defer_reason_class` from the marker (see step 1's marker-to-class mapping). Extract the `evidence_pointer` from the comment body — the line immediately following the marker line starts with `Scope-preflight diagnosis ...` and the evidence pointer was embedded in the original comment per the recording-path template. For `confirmed-blocker-still-open` entries, re-run the blocker-state probe (all `#N` references must still be OPEN). For `time-gated` entries, re-run the date probe: today's UTC calendar date (`date -u +%F`) must still be strictly before the cited `YYYY-MM-DD` — if the date has elapsed, the cached diagnosis is stale (the issue may now be genuinely ready). For other classes, run the per-class shape check only. If re-validation fails → fall through to normal scope-agent dispatch. Log: `[scope-preflight] #<N> freshness check — cached evidence re-validation failed (<reason>); dispatching scope agent`.

6. **Record a `cached-diagnosis` defer.** All five checks passed — the existing comment accurately documents the defer and re-dispatching a scope agent would produce the same result at cost. Synthesize the defer entry directly:

   ```
   {
     issue: N,
     reason: "<first non-marker paragraph of the cached comment, verbatim>",
     defer_reason_class: "<class inferred from the marker>",
     evidence_pointer: "<re-extracted from the cached comment>",
     provenance: "cached-diagnosis",
     deferred_at: "<current ISO-8601 UTC timestamp>",
     would_be_dispatchable_as_phase_1_if?: "<from the cached comment if present>"
   }
   ```

   Apply the same recording steps as a regular deferred entry (comment dedupe check, `needs-human-review` label application for the three labelled classes) — but **skip posting a new comment** (the existing comment is the record; posting again adds noise). Log: `[scope-preflight] #<N> freshness check hit — reusing diagnosis comment from <comment.createdAt> (class=<defer_reason_class>, evidence=<evidence_pointer>); scope-agent dispatch skipped`.

   **Do NOT dispatch a scope agent for this candidate.** Increment `defers_this_turn` by 1 (same as a scope-agent defer — feeds the step E invariant line and the pre-drain audit). Remove the issue from `raw_backlog`.

**When NOT to apply the freshness check.** The check is skipped when:
- `scope.diagnosis_reuse_hours == 0` (disabled by config).
- No marker-tagged comment exists on the issue.
- The comment is older than the window.
- The issue body was amended after the comment.
- A non-bot human removed `needs-human-review` after the diagnosis comment was posted (Signal A — see step 4 above).
- A `<!-- do-work-decision-resolved -->` or `<!-- shipyard-resolve-decisions -->` sentinel comment was posted after the diagnosis comment (Signal B — see step 4 above).
- The cached evidence fails mechanical re-validation.

In all skip cases, fall through to normal scope-agent dispatch. The check is purely additive — it never promotes a cached defer to `ready`; that path is the scope agent's exclusive domain.

#### Staleness probe — has this already landed on `origin/<default-branch>`? ([#992](https://github.com/mattsears18/shipyard/issues/992))

**Before returning any shape, the scope agent checks whether the issue's own claims still hold against `origin/<default-branch>`.** An issue body can go stale relative to `main` with nothing in the comment thread saying so — a PR that fixes part or all of an issue without a closing keyword leaves no trace on the issue itself. The [comment-thread-awareness rule](../dispatch-rules.md) only catches staleness the thread *documents*; this catches staleness the thread is silent about. Dispatching a worker against a fully- or partially-stale premise wastes a full worker dispatch on a prompt that asserts a false premise — the dispatched worker's own pre-implementation verification ([`issue-work.md` step 2](../../../agents/issue-worker/issue-work.md)) recovers from this today, but only *after* burning the dispatch. This probe catches it before the dispatch happens.

**Keep the probe cheap and bounded — it runs per-candidate on the dispatch critical path, and at `--concurrency 1` it sits directly between one worker returning and the next starting.** Prefer targeted, bounded queries over reading source broadly:

- `git log --oneline origin/<default-branch> --grep "#<N>"` and/or `gh pr list --repo <owner/repo> --state merged --search "<N> in:body"` — did a merged PR already reference this issue number, closing keyword or not?
- For each **concrete, individually-checkable claim** the body makes about repo state (a named file, a specific literal/string, a config key, a described-as-missing behavior) — a targeted `git grep` / `gh api` read of just that file or symbol on `origin/<default-branch>`, not a broad directory walk.
- Vague or subjective claims ("the UX is confusing", "this needs better error handling") have no mechanical yes/no answer — skip them; the probe only applies to claims a bounded query can settle.

**Three outcomes, not two:**

1. **Every checkable claim still holds** → proceed to the normal ready/deferred decision unaffected. This is the common case; the probe is a no-op.
2. **Some claims no longer hold, but at least one does (partial landing)** → narrow `phase_1_scope` to name only the surviving claims — the existing field, unchanged shape — rather than passing the whole issue through. State which claims were dropped and why (e.g. "gaps (a) and (b) already shipped in `<PR/commit>`; only gap (c) remains"). **Do not misclassify a partial landing as full** — a false "already landed" silently drops real remaining work from the backlog, which is far more costly than the wasted-dispatch cost this probe exists to avoid, so err toward outcome 2 whenever any claim still holds.
3. **No checkable claim still holds (full landing)** → return the **already-landed shape** below instead of ready or deferred. Require at least one corroborating citation (a merged PR/commit referencing the issue, or the claim's confirmed absence at the specific file/line the body names) before concluding the whole issue is moot — never conclude this from a single ambiguous grep miss.

Take the top `2 × concurrency` from `raw_backlog`. Dispatch read-only scoping agents in parallel with `run_in_background: true` (one message, multiple background `Agent` tool calls). Each returns **one of two shapes**:

**Ready shape** (default — the candidate is shippable as a single-worker dispatch, possibly as a phase-1 slice with explicit out-of-scope items):

```
{ issue: N, files: ["path/a", "path/b", ...], lockfile_sections: ["overrides", "dependencies", ...], phase_1_scope?: "<one-line description of the phase-1 slice + what's out of scope>", operator_residual?: "<one-line description of the operator/security action that stays on THIS issue after the phase-1 slice ships>", operator_residual_security_sensitive?: <bool>, verification_slice?: "<one-line: which auditor to dispatch, against what surface/URL, and which acceptance criteria it covers>", verification_residual?: "<one-line description of what stays un-automated on THIS issue — the native-device/human-only portion>" }
```

`phase_1_scope` is **optional** and present only when the agent chose to slice — it tells the orchestrator what the worker will ship and what the worker MUST file as follow-up issues rather than touch. Absent on plain ready returns (single-phase issues). When present, it's passed through to the dispatched worker as an extra line in the dispatch prompt's "Context" block so the worker stays inside the phase-1 envelope.

`operator_residual` and `operator_residual_security_sensitive` are **optional** and present only when the [operator-slice carve-out](06b-scope-carveouts.md#operator-slice-carve-out--ship-the-code-slice-hand-back-only-the-operator-remainder-851) below fired — i.e. the candidate would otherwise have been a whole-issue `external-dependency`/`agent-console` (or a security-flavored `human-decision-required`) defer, but a phase-1 code slice exists. Unlike a plain `phase_1_scope` out-of-scope item (which becomes a **new** follow-up issue), `operator_residual` describes work that stays on **the same dispatched issue** — the worker must ship the code slice without closing `#<N>`, then hand the residual back on `#<N>` itself. `operator_residual_security_sensitive` (default `false` when omitted) tells the dispatch site which label the residual gets: `true` when the residual is itself a security/access-control mutation (auth setting, IAM, OAuth redirect URI, sharing/member permission — the [Claude-safe-vs-hand-back table](../operate/02-execution-and-playbooks.md#claude-safe-to-auto-drive-vs-hand-back-securityaccess-control)'s hand-back column), which routes the residual to `needs-human-review` per [#848](https://github.com/mattsears18/shipyard/issues/848)'s relabel rule (see this repo's `CLAUDE.md` § `agent-console`); `false` (the common case — a browser/console action with no security dimension) keeps it on `agent-console`.

`verification_slice` and `verification_residual` are **optional** and present only when the [QA-verification carve-out](06b-scope-carveouts.md#qa-verification-carve-out--run-the-automatable-audit-hand-back-only-the-manual-remainder-852) below fired — i.e. the candidate's deliverable is *verification, not a code change* (walk flow X, file bugs for anything broken, check the box), and would otherwise have been a whole-issue `external-dependency` defer, but part of the verification surface is automatable via an existing shipyard auditor. `verification_slice` names the auditor to dispatch (e.g. `shipyard:functional-qa-auditor`), the automatable surface (a live URL + which flow), and the specific acceptance criteria it covers. `verification_residual` describes what stays un-automated on `#<N>` — typically a native-device or human-only check. Like `operator_residual`, this is work that stays on **the same dispatched issue**, not a new follow-up issue: the worker runs the audit (which files its own `bug` issues for real findings), posts a verification-status comment, and dispositions `#<N>` without opening a resolving PR.

**`phase_1_scope` (and any other confidence/status prose in the ready return) must be grounded in the issue's comment thread, not just its body ([#781](https://github.com/mattsears18/shipyard/issues/781)).** The scoping agent's return flows into the dispatch prompt **verbatim** — the orchestrator does not re-derive or fact-check it (see [dispatch-rules.md's "Confidence/status framing" rule](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c)). If the scoping agent asserts something like "these items are untested/not blocked" while scoping, that claim MUST be checked against the candidate's `comments` field (fetch with `gh issue view <N> --repo <owner/repo> --json comments` if not already read) before it's written into `phase_1_scope` — a comment thread can already document a live blocker (a prior QA pass, a maintainer note) that the body never mentions. When a confident claim can't be verified against the comments, phrase it more conservatively (e.g., omit the confidence claim, or note "no blocking label present — verify against the comment thread") rather than asserting it outright.

**Deferred shape** (the scope agent read the issue + code and concluded the fix isn't ship-able as a single `shipyard:issue-worker` dispatch — even as a phase-1 slice — because there's no first phase that can ship independently: external decision pending, every phase depends on infrastructure that isn't provisioned, etc.):

```
{ issue: N, deferred: "<one-paragraph reason the orchestrator should tell the human>", defer_reason_class: "<class>", evidence_pointer: "<mechanical citation>", would_be_dispatchable_as_phase_1_if?: "<one-line description of the unblocked condition>" }
```

`defer_reason_class` is **required** on every deferred return. Valid values (one and only one per entry):

- `external-dependency` — gated on an upstream vendor, SDK, third-party API, or off-repo system that the worker can't move. **Optional — when the blocking condition is a single mechanically-checkable fact, append a trailing `Recheck probe: <verb> <args...>` clause to `evidence_pointer`** ([#1201](https://github.com/mattsears18/shipyard/issues/1201)), using exactly the marker grammar `scripts/eval-recheck-probe.sh` accepts (`npm-view <pkg> <field> == <expected>` or `gh-api repos/<owner>/<repo>/<endpoint> <jq-field> == <expected>`, `<owner>/<repo>` matching this repo — see that script's header for the full grammar). This is a hint, not a requirement — most external-dependency defers have no single-command test and should omit the clause entirely; the [Recording path](06d-recheck-probe-authorship.md) only acts on it when it validates against the same allowlist the read side re-checks on every evaluation, and silently ignores it otherwise.
- `human-decision-required` — needs a product / business / legal call, or is blocked by a policy-gated path (CI/infrastructure config, Claude-Code self-modification) the classifier hard-blocks, before any code path can be picked. **A plain open design or architecture decision does NOT qualify** — see [Design/architecture/epic/spike decisions are in-scope by default](06b-scope-carveouts.md#designarchitectureepicspike-decisions-are-in-scope-by-default-not-a-defer-reason-767) below.
- `untrusted-author` — defense-in-depth defer for issues whose author hasn't been re-cleared against the trust list. (Rare — step 1.7 normally drops these before scope.)
- `confirmed-blocker-still-open` — gated on a referenced issue or PR that is still open, stated in any wording that expresses a genuine ordering/dependency constraint (`Blocked by #N` is the canonical phrasing, but `Wants #N` / `Depends on #N` / `Must not land before #N` and similar count too — see the [blocker-phrasing carve-out](06b-scope-carveouts.md#blocker-phrasing-carve-out--recognize-dependency-constraints-in-any-wording-1148) for the full rule). The agent confirmed the named reference is a genuine, still-open, load-bearing block — not every mention of another issue/PR is one.
- `confirmed-non-shippable-as-single-PR` — the agent attempted to find a phase-1 slice and failed. Use this class only when the agent CAN'T construct a phase-1 description; otherwise prefer the ready-with-`phase_1_scope` form.
- `time-gated` ([#1165](https://github.com/mattsears18/shipyard/issues/1165)) — the work isn't blocked on a person, an external dependency, or an open `#N` — only on a calendar date (a documented migration-window criterion, a scheduled quarantine deadline). Distinct from `human-decision-required` because no human decision is needed once the date elapses, and distinct from `confirmed-blocker-still-open` because there's no other issue/PR gating it, only a date. **Never gated with `needs-human-review` or `agent-console`** — the [Recording path](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes) writes a self-clearing `<!-- do-work-blocked-until: YYYY-MM-DD -->` body marker instead of applying a label, honored by the [step-4 dispatch filter](04-backlog-divert.md#4-fetch--rank-the-backlog) ([#1161](https://github.com/mattsears18/shipyard/issues/1161)).

`evidence_pointer` is **required** on every deferred return ([#302](https://github.com/mattsears18/shipyard/issues/302)) — a single concrete, mechanically-verifiable citation that grounds the chosen `defer_reason_class`. The orchestrator validates the pointer against the per-class shape table below before accepting the defer; a deferred return whose `evidence_pointer` is missing, empty, or doesn't match its class's shape is **rejected as a malformed defer** — see [Handling each returned entry → Deferred entries](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes) for the rejection path. The point is to prevent plausible-sounding-prose defers (the failure mode the rationale's [Phase-slicing bias + classified defers](../../do-work-RATIONALE.md#phase-slicing-bias--classified-defers-issue-298) section already documented for `defer_reason_class` — same fix, one level deeper) from passing the audit; an agent that can't produce mechanical evidence for the class it picked isn't allowed to defer.

**Already-landed shape** ([#992](https://github.com/mattsears18/shipyard/issues/992)) — the [staleness probe](#staleness-probe--has-this-already-landed-on-origindefault-branch-992) above found NO checkable claim in the issue still holds on `origin/<default-branch>`; there is nothing left for a worker to ship:

```
{ issue: N, already_landed: "<one-paragraph explanation of what already exists and where — cite the shipping commit/PR when findable>", evidence_pointer: "<file:line, commit SHA, or merged-PR reference on origin/<default-branch> proving the claim(s) already hold>" }
```

`evidence_pointer` is **required**, same discipline as the deferred shape's above — a bare "looks already fixed" with no mechanical citation is rejected by the orchestrator (see [Handling each returned entry → Already-landed entries](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes)). Use this shape only for the staleness probe's outcome 3 (full landing) — a partial landing is outcome 2 and stays a **ready** return with a narrowed `phase_1_scope`, never this shape.


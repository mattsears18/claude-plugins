# /shipyard:do-work — Setup phase · scope entry handling + UI + timing flush

**Setup sub-phase (cluster 4 of 5, part 3 of 3 — [#994](https://github.com/mattsears18/shipyard/issues/994)).** Finishes step **6** from [`06b-scope-carveouts.md`](./06b-scope-carveouts.md) — handling each returned scope-agent entry (ready / deferred / already-landed / rejected, the re-gate guard, `raw_backlog` removal) — then owns steps **6.5 → 6.8**: the status-line + state-change-banner UI and the setup-timing flush into session state. Router: [`setup.md`](../setup.md). Sidebar: [`dont.md`](../dont.md). Prev: [`06b-scope-carveouts.md`](./06b-scope-carveouts.md) (same cluster, part 2). Next sub-phase: [`07-pool-fill.md`](./07-pool-fill.md).

#### Handling each returned entry (fires as each background agent completes)

- **Ready entries** — partition each `files` array into `{ hard: [...], soft: [...] }` by matching each path against the soft-collision glob set defined in the [Dispatch rules](../dispatch-rules.md#dispatch-rules-used-by-step-7-and-step-c) (default + any `--soft-collision-path` extensions). Paths that match a soft-collision glob go into `soft`; everything else goes into `hard`. The orchestrator does the partitioning — scoping agents return raw paths; they don't need to know about the tier distinction. Cache the partitioned result as the candidate's `claimed_paths`. Cache the optional `phase_1_scope` string (when present) on the candidate so the dispatch site can pass it into the worker prompt's "Context" block — workers told they're working a phase-1 slice MUST stay inside the described envelope and file the explicitly-out-of-scope items as follow-up issues (one per phase) rather than expanding scope. Also cache the optional `operator_residual` string and `operator_residual_security_sensitive` boolean (when present — set by the [operator-slice carve-out](06b-scope-carveouts.md#operator-slice-carve-out--ship-the-code-slice-hand-back-only-the-operator-remainder-851)) alongside `phase_1_scope`; unlike a plain out-of-scope item, `operator_residual` does NOT become a new follow-up issue — it flows into the dispatch prompt as an instruction to keep the SAME issue open and hand the residual back on it (see `dispatch-rules.md`'s "Phase-1 slice augmentation"). Also cache the optional `verification_slice` and `verification_residual` strings (when present — set by the [QA-verification carve-out](06b-scope-carveouts.md#qa-verification-carve-out--run-the-automatable-audit-hand-back-only-the-manual-remainder-852)); like `operator_residual`, neither becomes a new follow-up issue — they flow into the dispatch prompt as an instruction to run the named auditor against the automatable surface and disposition the SAME issue rather than opening a resolving PR (see `dispatch-rules.md`'s "Verification-scope augmentation"). Push onto `ready_issues` (preserving rank). **If this is the first ready entry and step 7 has not yet dispatched, dispatch immediately** — do not wait for the remaining background scope agents to finish.
- **Deferred entries** — first run the **per-class `evidence_pointer` validation** ([#302](https://github.com/mattsears18/shipyard/issues/302)), then either reject the malformed defer or record the valid one.

  **Evidence validation** (runs before any of the recording steps below):

  Check that `evidence_pointer` is present and non-empty AND matches the per-class shape table in the [Deferred shape](06-scope-preflight.md#6-initial-scope-pre-flight) docs. The shape checks are intentionally lightweight — string-matching the orchestrator can run inline without dispatching a fresh agent:

  - `confirmed-blocker-still-open` → `evidence_pointer` must contain at least one `#<digits>` reference (regex: `#\d+`). For each `#N` referenced, the orchestrator does a single `gh issue view <N> --repo <owner/repo> --json state -q .state` and confirms the named blocker is `OPEN`. If any cited blocker is `CLOSED` / `MERGED`, the defer is **rejected** — the supposed block has already resolved. If none of the cited references parse as `#<digits>`, the defer is also rejected as malformed.
  - `external-dependency` → `evidence_pointer` must not match the rejected shapes (no "looks like", "probably", "likely", "seems", "feels" speculative-judgment words). The orchestrator does not validate that the named external system exists (that would be unbounded) — the check is shape-only.
  - `human-decision-required` → same speculative-judgment word check as `external-dependency`. Additionally, generic phrases like "needs design review", "needs product input" without a specific decision named (e.g., what copy is being decided, what design surface) are rejected. **A design or architecture decision is rejected even when named specifically ([#767](https://github.com/mattsears18/shipyard/issues/767))** — "copy decision pending for placeholder field in `src/components/EmailForm.tsx:42`" is accepted only insofar as it's a content/brand-voice call (a product-adjacent decision), never as license to defer a plain UI/architecture design choice; the orchestrator/worker makes those calls itself and proceeds (see [Design/architecture/epic/spike decisions are in-scope by default](06b-scope-carveouts.md#designarchitectureepicspike-decisions-are-in-scope-by-default-not-a-defer-reason-767)). The structured prefixes `Proposes .github/workflows/`, `Proposes .claude/settings.json`, `Proposes .claude/settings.local.json`, `Proposes .mcp.json`, and `Proposes .claude/hooks/` are explicitly accepted (these are the shapes the [pre-scope detectors](06-scope-preflight.md#pre-scope-orchestrator-side-detectors-synthetic-defers) synthesize — Detector 1 produces the workflow shape, Detector 2 produces the Claude-Code self-modification shape; the decision being named is whether to accept the proposal, and both CI/infrastructure-policy and Claude-Code self-modification policy are valid decision categories per the per-class shape table above). The accepted-prefix list tracks `scope.self_modification_paths` ([#591](https://github.com/mattsears18/shipyard/issues/591)) — if that config array is customized to add a new self-modification path, its `Proposes <path>` prefix is accepted here on the same basis. **The structured prefix `Classifier denied dispatch on both permitted attempts` is also explicitly accepted ([#953](https://github.com/mattsears18/shipyard/issues/953))** — this is the shape [`dispatch-rules.md`'s two-denial hand-back](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt) synthesizes directly (never returned by a scope agent, the same way the two detector shapes above are never returned by one); this class only matters here for the [freshness check's](06-scope-preflight.md#scope-result-freshness-check-skip-dispatch-when-a-fresh-diagnosis-comment-exists) mechanical shape-only re-validation of a cached `<!-- do-work-classifier-undispatchable -->` diagnosis, since there is no live way to re-invoke the harness classifier to re-confirm freshness.
  - `untrusted-author` → `evidence_pointer` must contain `author: <login>` where `<login>` matches GitHub's login regex (`[a-zA-Z0-9](?:[a-zA-Z0-9]|-(?=[a-zA-Z0-9])){0,38}`). The orchestrator does not re-validate the login against `trusted_authors` here (step 1.7 already did that); this is a shape-only check that the agent supplied a concrete login.
  - `confirmed-non-shippable-as-single-PR` → `evidence_pointer` must start with one of: `Missing dependency:`, `Multi-service coordination:`, `Multi-PR sequence:`, `Body cites <artifact>:` — these are the structured prefixes the rationale's worked-example catalog covers. Free-form text without one of these prefixes is rejected.
  - `time-gated` ([#1165](https://github.com/mattsears18/shipyard/issues/1165)) → `evidence_pointer` must start with `Time-gate:`, followed by a `YYYY-MM-DD` date, followed by ` — ` and a non-empty citation (file/line or issue comment). The orchestrator additionally parses the date and confirms it is strictly **later than today's UTC calendar date** — a pointer citing a date that has already passed or is today is rejected (`evidence_pointer date <date> is not in the future — the issue is workable now, not time-gated`), since the class exists only to express a still-pending future gate. A malformed date (doesn't parse as `YYYY-MM-DD`) is also rejected.

  **Rejection path** (when validation fails): do NOT record into `deferred_issues`. Instead:

  1. Log `[scope-preflight] #<N> deferred return REJECTED — evidence_pointer "<pointer>" does not match shape for class <defer_reason_class>: <specific reason>`. The `<specific reason>` is the failed check (e.g. `cited blocker #1077 is CLOSED`, `contains speculative phrase "looks like"`, `missing required prefix`).
  2. Post a comment on the issue: `Scope-preflight rejected this defer (class=<defer_reason_class>) — evidence_pointer "<pointer>" did not meet the per-class shape requirement: <specific reason>. Re-queued for a fresh scope pass next session; if you want to override, file a follow-up with explicit acceptance criteria.` This makes the rejection visible to the human reading the issue thread.
  3. **Push the issue number back onto `raw_backlog`** (preserving rank from where it was originally pulled). The next dispatch will re-scope it with a fresh scope agent, which gets another chance to either ready it (with `phase_1_scope`) or supply mechanically-valid evidence. Do not increment `defers_this_turn` — the defer was rejected.
  4. Remove from any in-flight scope-pre-flight tracking state so the same agent's return isn't double-counted.

  **Recording path** (when validation passes):

  1. **Comment dedupe check — before posting, check for an existing identical diagnosis.** Fetch the issue's recent comments and look for any comment whose body contains the class-specific marker for this defer class (see marker table below). If a comment with a matching marker exists and its `deferred reason` conclusion matches the current defer's reason (same first non-marker paragraph), **skip posting a new comment** — log `[scope-preflight] #<N> skipping duplicate diagnosis comment (class=<defer_reason_class>, prior comment: <url>)` and proceed to step 2. This prevents the identical-comment-spam failure mode (see [RATIONALE → needs-human-review extended to external-dependency/human-decision-required (#536)](../../do-work-RATIONALE.md#binary-backlog-phase-3--needs-human-review-extended-to-external-dependency--human-decision-required-defers-issue-536)). The deduplication window is unbounded — do NOT limit it to N days, because the underlying blocker (the external dependency or the decision) may not have changed, and posting again adds no signal.

     The dedupe check is a best-effort read against the `comments` field you should already have from your step 0 issue-view projection (or re-fetch if needed with `gh issue view <N> --repo <owner/repo> --json comments`). A read failure (rate limit, permission) is non-fatal — fall through and post the comment. A false-negative (marker present but body-hash check fails) is acceptable: a spurious extra comment is mild noise; suppressing a legitimate updated diagnosis is worse, so err toward posting on any doubt.

  2. Post a comment on the issue: `Scope-preflight diagnosis (not auto-fixable as a single worker): <deferred reason>` — and when the agent supplied `would_be_dispatchable_as_phase_1_if`, append a second paragraph: `Phase-1 dispatchable if: <would_be_dispatchable_as_phase_1_if>`. **For the `external-dependency` class specifically, render the `would_be_dispatchable_as_phase_1_if` condition as a concrete provisioning checklist ([#628](https://github.com/mattsears18/shipyard/issues/628))** — a short `What to provision:` block listing the operator steps (create the account, copy the credential, where the value goes) so the `/my-turn` handoff is actionable rather than a bare "blocked on upstream" note. The checklist is the operator's runbook: `/do-work` can drive the browser to the provider console and tee it up, and the user supplies the secret value from their password manager (the [`paste-secret` playbook](../operate/02-execution-and-playbooks.md#playbooks-by-kind) — shipyard never types a real secret it derived from issue text). Use `gh issue comment <N> --repo <owner/repo> --body "..."`. If the comment fails (rate limit, permission), log an advisory and continue — don't block the pre-flight pass on a single comment failure. **Each defer class prepends a distinct body marker as the comment's literal first line** — the marker is the idempotency sentinel for the dedupe check above, and it is the discriminator that lets downstream tooling (e.g. `/decompose-epic`) separate the epic-decomposition handoff from the other `needs-human-review` classes. Concretely:

     | `defer_reason_class` | Body marker (first line) | Issue [#519](https://github.com/mattsears18/shipyard/issues/519) / [#536](https://github.com/mattsears18/shipyard/issues/536) |
     |---|---|---|
     | `confirmed-non-shippable-as-single-PR` | `<!-- do-work-needs-decomposition -->` | #519 — consumed by `/decompose-epic` to identify epic-decomposition handoffs |
     | `external-dependency` | `<!-- do-work-external-dependency -->` **(comment marker — as of [#1195](https://github.com/mattsears18/shipyard/issues/1195), step 4b below additionally writes the shared `<!-- do-work-blocked-until: YYYY-MM-DD -->` BODY marker for this class too, alongside the `agent-console` label)** | #536 — dedupe sentinel + discriminator so humans can filter "blocked on upstream" vs other `needs-human-review` |
     | `human-decision-required` | `<!-- do-work-human-decision-required -->` | #536 — dedupe sentinel + discriminator so humans can filter "needs a decision" vs other `needs-human-review` |
     | `human-decision-required` (classifier-denied sub-case) | `<!-- do-work-classifier-undispatchable -->` | #953 — same class, but this hand-back is synthesized by [`dispatch-rules.md`'s two-denial hard stop](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt), never returned by a scope agent; the distinct marker records that **no worker ran at all** (dispatch itself was refused), as opposed to a scope agent's read of the issue's content |
     | `untrusted-author` | *(no marker)* | Not gated by `needs-human-review`; dedupe is not needed (trust-clearance defers are rare) |
     | `confirmed-blocker-still-open` | *(no marker)* | Not gated by `needs-human-review`; the `Blocked by #N` body-reference filter handles exclusion; dedupe is not needed (blocker state changes externally) |
     | `time-gated` | `<!-- do-work-time-gated -->` **(comment marker — distinct from the separate `<!-- do-work-blocked-until: YYYY-MM-DD -->` BODY marker step 4 also writes for this class, below)** | #1165 — the comment marker is this recording path's own dedupe sentinel and the [freshness check's](06-scope-preflight.md#scope-result-freshness-check-skip-dispatch-when-a-fresh-diagnosis-comment-exists) reuse discriminator; the body marker is the one the step-4 dispatch filter ([#1161](https://github.com/mattsears18/shipyard/issues/1161)) actually reads to drop the issue |

     Concretely, the comment bodies for the three scope-agent-facing labelled classes (the `<!-- do-work-classifier-undispatchable -->` sub-case's comment shape is documented at its own origin, [`dispatch-rules.md`'s two-denial hand-back](../dispatch-rules.md#3-on-a-second-denial-stop-hand-back-to-the-human-never-a-third-attempt), not here — it is never produced by this recording path):

     ```
     <!-- do-work-needs-decomposition -->
     Scope-preflight diagnosis (not auto-fixable as a single worker): <deferred reason>
     ```

     ```
     <!-- do-work-external-dependency -->
     Scope-preflight diagnosis (not auto-fixable as a single worker): <deferred reason>

     Phase-1 dispatchable if: <would_be_dispatchable_as_phase_1_if>

     What to provision (operator checklist):
     - Create a <service> account (if you don't have one)
     - Copy the <credential> (e.g. the DSN / API key) from the provider console
     - Set it at <where the value goes, e.g. `terraform.tfvars:sentry_dsn` or the `SENTRY_DSN` CI secret>
     Then clear `agent-console` and `/do-work` will finish wiring it (or `/do-work` can drive the console steps for you).
     ```

     ```
     <!-- do-work-human-decision-required -->
     Scope-preflight diagnosis (not auto-fixable as a single worker): <deferred reason>
     ```

     ```
     <!-- do-work-time-gated -->
     Scope-preflight diagnosis (time-gated, not a human decision): <deferred reason>

     Blocked until: <YYYY-MM-DD>
     ```

     For `time-gated` specifically, **step 4 below additionally writes a separate `<!-- do-work-blocked-until: YYYY-MM-DD -->` marker into the issue BODY** (not this comment) — that body marker, not this comment marker, is what the [step-4 dispatch filter](04-backlog-divert.md#4-fetch--rank-the-backlog) reads. This comment is diagnostic provenance + the freshness-check dedupe sentinel only.

  3. **Normalize `defer_reason_class` before recording** ([#547](https://github.com/mattsears18/shipyard/issues/547)). The valid set is exactly six literal tokens: `external-dependency`, `human-decision-required`, `untrusted-author`, `confirmed-blocker-still-open`, `confirmed-non-shippable-as-single-PR`, `time-gated` ([#1165](https://github.com/mattsears18/shipyard/issues/1165)). A scope agent may return a value that is *missing*, *present-but-invalid* (free-text paraphrase, invented synonym), or *valid*. Handle each case before appending to `deferred_issues`:

     - **Missing** (`defer_reason_class` absent or null): default to `confirmed-non-shippable-as-single-PR` and log `[scope-preflight] #<N> deferred return missing defer_reason_class — defaulted to confirmed-non-shippable-as-single-PR`.
     - **Present but not one of the six valid tokens**: run the evidence-pointer shape table against the `evidence_pointer` field to infer the nearest valid class, then log the normalization. Apply these inference rules in order:
       - If `evidence_pointer` matches the `confirmed-blocker-still-open` shape (contains `#<digits>`) → normalize to `confirmed-blocker-still-open`.
       - Else if `evidence_pointer` matches the `untrusted-author` shape (`author: <login>` pattern) → normalize to `untrusted-author`.
       - Else if `evidence_pointer` matches the `time-gated` shape (starts with `Time-gate:` followed by a parseable, still-future `YYYY-MM-DD` date) → normalize to `time-gated`.
       - Else if `evidence_pointer` matches the `confirmed-non-shippable-as-single-PR` shape (starts with `Missing dependency:` / `Multi-service coordination:` / `Multi-PR sequence:` / `Body cites <artifact>:`) → normalize to `confirmed-non-shippable-as-single-PR`.
       - Else if `evidence_pointer` matches the `human-decision-required` shape (names a concrete decision — no speculative words, not a generic phrase) → normalize to `human-decision-required`.
       - Else → normalize to `external-dependency` (the broadest residual class for a present-but-unclassifiable pointer).

       In all normalization cases log `[scope-preflight] #<N> defer_reason_class "<raw>" normalized to <normalized-class> (evidence_pointer shape match)`. If the `evidence_pointer` is also missing or fails its own shape check *in addition* to the class being invalid, the **rejection path** applies (not normalization) — the normalization branch only fires when the pointer itself is valid for at least one class's shape.
     - **Present and one of the six valid tokens**: use as-is.

     Append the entry `{ issue: N, reason: "<deferred reason>", defer_reason_class: "<normalized-or-original class>", evidence_pointer: "<pointer from the agent's return>", provenance: "scope-agent", deferred_at: "<current ISO-8601 UTC timestamp>", would_be_dispatchable_as_phase_1_if?: "<from the agent's return when provided>" }` to a session-level `deferred_issues` list (a new piece of orchestrator state — initialize as `[]` at startup alongside `ready_issues` / `raw_backlog`). The `provenance: "scope-agent"` value records that a real scope agent read the codebase and made this call — see [`do-work.md`'s `deferred_issues` entry](../../do-work.md#orchestrator-state) for the valid provenance values, the `defer_reason_class` allowed set, the `evidence_pointer` field, and the restriction on mid-session writes. The `evidence_pointer` field has no default — its absence triggers the rejection path above, not normalization. Increment `defers_this_turn` by 1 — this feeds the step E invariant line's `defers_this_turn` token and the pre-drain audit. This feeds the end-of-session summary's `Deferred:` block (see [End-of-session summary](../cleanup-summary.md#end-of-session-summary)).

  3.5. **Re-gate guard — a resolved decision cannot be silently re-applied ([#962](https://github.com/mattsears18/shipyard/issues/962)).** Before step 4 applies `needs-human-review`, check whether this issue already carries a **decision-resolution comment** newer than the most recent removal of `needs-human-review`. This is the mechanical (orchestrator-side, not scope-agent-prompt-side) backstop for the failure mode the [scope-agent prompt instruction](06-scope-preflight.md#6-initial-scope-pre-flight) above already asks the agent to avoid: a fresh scope pass (or a re-confirmed cached diagnosis, or an inline re-validation) re-deriving the SAME pre-decision reasoning a human already answered — the exact loop [#962](https://github.com/mattsears18/shipyard/issues/962) repro'd, where `/shipyard:resolve-decisions` (run directly or via `/my-turn`'s reused walkthrough) cleared the gate and, hours later with no new information, a fresh scope pass re-applied it citing the identical, already-answered policy question. This runs only for the two classes step 4 gates with `needs-human-review` — `human-decision-required` and `confirmed-non-shippable-as-single-PR`; `external-dependency` gates with `agent-console` instead and `time-gated` gates with no label at all (a body marker only), so both are out of scope here.

     Two sentinels count as a decision-resolution comment, treated identically because both record the same fact (a human answered the blocking questions) through different call paths: `/shipyard:resolve-decisions`'s own `<!-- shipyard-resolve-decisions -->` (posted automatically by both `/resolve-decisions` and `/my-turn`'s reused decision-gated walkthrough — see [`resolve-decisions.md`'s Record + unblock](../../resolve-decisions.md#record--unblock)) and a maintainer's hand-written `<!-- do-work-decision-resolved -->` ([#569](https://github.com/mattsears18/shipyard/issues/569), CLAUDE.md § "Decision-resolved sentinel").

     ```bash
     RESOLUTION_AT=$(gh issue view <N> --repo <owner/repo> --json comments \
       --jq '[.comments[] | select(.body | startswith("<!-- shipyard-resolve-decisions -->") or startswith("<!-- do-work-decision-resolved -->"))] | sort_by(.createdAt) | last.createdAt // empty')

     LAST_UNGATE_AT=$(gh api "repos/<owner>/<repo>/issues/<N>/timeline" --paginate \
       --jq '[.[] | select(.event == "unlabeled" and .label.name == "needs-human-review")]
       | sort_by(.created_at) | last.created_at // empty')
     ```

     If `RESOLUTION_AT` is non-empty AND (`LAST_UNGATE_AT` is empty OR `RESOLUTION_AT` is later than `LAST_UNGATE_AT`) — the resolution comment is the latest word on this gate — the fresh defer's `reason` / `evidence_pointer` MUST explicitly name what changed since that resolution (e.g. cite a specific new comment posted after `RESOLUTION_AT`, a new failing check, a scope change in the body after `RESOLUTION_AT`). A bare re-statement of the same policy question the resolution comment already answered is NOT new evidence:

     - **Names what changed** → proceed to step 4 as normal; this is a legitimate re-gate (new information invalidated the prior decision).
     - **Names nothing new** → treat this exactly like a rejected defer (see the [Rejection path](#handling-each-returned-entry-fires-as-each-background-agent-completes) above): do NOT record into `deferred_issues`, do NOT apply `needs-human-review`. Log `[scope-preflight] #<N> defer REJECTED — resolution comment at <RESOLUTION_AT> postdates the last needs-human-review removal (<LAST_UNGATE_AT>) and the fresh defer names no new information (re-gate guard #962)`. Post a comment: `Scope-preflight declined to re-apply needs-human-review — a decision-resolution comment (<url>) is the latest word on this gate and the fresh diagnosis names nothing new. If the resolution is genuinely stale, re-run with an evidence_pointer stating what changed since <RESOLUTION_AT>.` Push the issue back onto `raw_backlog` (preserving rank); do not increment `defers_this_turn`.

     This check runs for **every** defer-recording call site that funnels through this Recording path — the fresh scope-agent path, the cached-diagnosis freshness-check reuse ([step 6 of the freshness check](06-scope-preflight.md#scope-result-freshness-check-skip-dispatch-when-a-fresh-diagnosis-comment-exists) above), and the pre-drain re-validation ([`drain.md` 5.a/5.b](../drain.md#5a--re-validate-orchestrator-judgment-entries)) — because all three record through this same path. It is deliberately orchestrator-side and mechanical rather than scope-agent-prompt-side, matching this file's established defense-in-depth posture: the `evidence_pointer` per-class shape validator earlier in this same Recording path exists for the identical reason ("prompts are not contracts" — see [Why a rejection path and not just stricter prompting](#handling-each-returned-entry-fires-as-each-background-agent-completes) below). A scope agent that genuinely has new grounds to re-gate the issue can still do so — it just has to say what changed, rather than silently re-asserting the pre-resolution reasoning.

  4. **Apply the surfacing gate label — `agent-console` for `external-dependency`, `needs-human-review` for `confirmed-non-shippable-as-single-PR` and `human-decision-required`, and NO label at all for `time-gated`** (issues [#498](https://github.com/mattsears18/shipyard/issues/498), [#519](https://github.com/mattsears18/shipyard/issues/519), [#536](https://github.com/mattsears18/shipyard/issues/536), [#608](https://github.com/mattsears18/shipyard/issues/608), [#1165](https://github.com/mattsears18/shipyard/issues/1165)) — but **ensure-then-label-then-verify**, never a bare `--add-label` that silently depends on [step 3a](01c-label-recovery-refine.md#3-ensure-label-exists--recover-from-prior-session)'s best-effort background create having landed (issue [#508](https://github.com/mattsears18/shipyard/issues/508)). The gate label depends on the class: an **`external-dependency`** defer is a browser/console **operator** action (paste a secret, flip a provider toggle), so it gets **`agent-console`** — which `/do-work` can then *drive* via the [operator phase](../operate.md) rather than only hand back ([#608](https://github.com/mattsears18/shipyard/issues/608)); the other two labelled classes are genuine human-handoffs and get **`needs-human-review`**; **`time-gated` gets no label — it writes a self-clearing body marker instead** (step 4a below), since the whole point of the class is that no human review is needed:

     ```bash
     # Pick the gate label by class: external-dependency → agent-console
     # (a browser/console operator action; /do-work can drive it), time-gated
     # → no label at all (see step 4a below for its own body-marker path),
     # everything else → needs-human-review (genuine human decision / epic
     # handoff).
     case "$DEFER_REASON_CLASS" in
       external-dependency) GATE_LABEL="agent-console" ;;
       time-gated)          GATE_LABEL="" ;;
       *)                   GATE_LABEL="needs-human-review" ;;
     esac
     # time-gated applies no label at all — skip straight to step 4a below.
     if [ -n "$GATE_LABEL" ]; then
       # Ensure the label exists first — step 3a creates it, but 3a's
       # `gh label create … &` group is backgrounded + `2>/dev/null || true`,
       # so on any path where 3a was skipped, raced, or its subshell errored
       # the label may be absent. `gh issue edit … --add-label` is atomic: a
       # missing label makes the WHOLE call exit non-zero, so the apply
       # silently no-ops (and on a repo where this defer path also clears the
       # @me self-assign in the same edit, the unassign is dropped too —
       # #508's combined-call repro). The idempotent create removes the
       # dependency on 3a entirely.
       if [ "$GATE_LABEL" = "agent-console" ]; then
         gh label create agent-console --repo <owner/repo> \
           --description "Blocked on a browser/console action an agent can drive outside the build — not a human decision. See CLAUDE.md's decision rule." \
           --color 1D76DB 2>/dev/null || true
       else
         gh label create needs-human-review --repo <owner/repo> \
           --description "Awaiting a human DECISION before /do-work will touch it" \
           --color D93F0B 2>/dev/null || true
       fi
       gh issue edit <N> --repo <owner/repo> --add-label "$GATE_LABEL" 2>/dev/null || true
       # Read back and warn loudly if the label still isn't present — a silent
       # no-op here corrupts the handoff queue (the issue gets re-scoped
       # every future session, the waste the gate label exists to prevent).
       if ! gh issue view <N> --repo <owner/repo> --json labels \
             --jq --arg L "$GATE_LABEL" '[.labels[].name] | index($L) != null' | grep -qx true; then
         echo "[scope-preflight] WARNING: #<N> $GATE_LABEL apply did not land — handoff surfacing failed; issue will be re-scoped next session"
       fi
     fi
     ```

     This is the keystone that converts the silent diagnosis comment into a tracked handoff: it exits the issue from the re-scope loop — `/do-work` stops re-scoping it every session (both `agent-console` and `needs-human-review` are in the [step 4 dispatch-exclusion set](04-backlog-divert.md#4-fetch--rank-the-backlog) below) — and routes it to the right queue: an `agent-console` issue surfaces to `/my-turn` as a human-actionable operator item **and** becomes drainable by `/do-work` (which drives the browser/console action itself — [#608](https://github.com/mattsears18/shipyard/issues/608)); a `needs-human-review` issue surfaces to `/my-turn` as a human-blocked decision. Without a gate label the diagnosis comment's handoff never reaches either queue (re-scoped every session, never surfaced) — this is the [#536](https://github.com/mattsears18/shipyard/issues/536) failure mode: `external-dependency` and `human-decision-required` defers accumulated 5+ consecutive identical diagnosis comments across sessions because no label was applied to gate re-dispatch. The **distinct body markers** posted in step 2 above are the discriminators that separate `external-dependency` and `human-decision-required` issues from the `confirmed-non-shippable-as-single-PR` epic-decomposition handoff (which `/decompose-epic` consumes via the `<!-- do-work-needs-decomposition -->` marker) and from each other. **Split the mutations** — if this defer path also clears the `@me` self-assign, run `--remove-assignee @me` as its **own** `gh issue edit` call, never combined with `--add-label` in one atomic invocation; otherwise a missing-label failure drops the unassign too (issue [#508](https://github.com/mattsears18/shipyard/issues/508)). If the `gh issue edit` fails (rate limit, permission), the read-back warning fires and the diagnosis comment from step 2 is still posted, so the human still has the comment trail (including the marker). **For the two classes that never applied any label to begin with** (`untrusted-author`, `confirmed-blocker-still-open`) do **not** apply `needs-human-review` here — those defers have different auto-recovery paths: `untrusted-author` is rare (trust-clearance) and `confirmed-blocker-still-open` rides the `Blocked by #N` body-reference filter (which auto-gates and auto-clears without a label). In all cases: do not close the issue, do not assign to a human.

  4a. **`time-gated` only — write the self-clearing `<!-- do-work-blocked-until: YYYY-MM-DD -->` body marker instead of a label** ([#1165](https://github.com/mattsears18/shipyard/issues/1165)). Run this step only when `$DEFER_REASON_CLASS == "time-gated"`; skip it entirely for every other class. Extract `<date>` from the validated `evidence_pointer` (the `YYYY-MM-DD` token immediately after the `Time-gate:` prefix — already confirmed parseable and future-dated by the [evidence validation](#handling-each-returned-entry-fires-as-each-background-agent-completes) above). Prepend the marker to the issue **body** — never a comment, since the [step-4 dispatch filter](04-backlog-divert.md#4-fetch--rank-the-backlog) reads directly from the body, exactly mirroring how a human hand-writes it per [#1161](https://github.com/mattsears18/shipyard/issues/1161):

     ```bash
     CURRENT_BODY=$(gh issue view <N> --repo <owner/repo> --json body --jq '.body')
     if echo "$CURRENT_BODY" | grep -q '<!-- do-work-blocked-until:'; then
       # A marker already exists (e.g. a re-diagnosis extended the gate to a
       # later date, or a human hand-wrote one previously) — replace its date
       # in place rather than stacking a second marker. Idempotent: if the
       # date is unchanged, this is a no-op edit.
       NEW_BODY=$(echo "$CURRENT_BODY" | sed -E "s/<!-- do-work-blocked-until: [0-9]{4}-[0-9]{2}-[0-9]{2} -->/<!-- do-work-blocked-until: <date> -->/")
     else
       NEW_BODY="<!-- do-work-blocked-until: <date> -->

$CURRENT_BODY"
     fi
     gh issue edit <N> --repo <owner/repo> --body "$NEW_BODY"
     # Read back and warn loudly if the marker still isn't present — a silent
     # no-op here means the issue keeps getting re-scoped every session,
     # exactly the waste this class exists to eliminate.
     if ! gh issue view <N> --repo <owner/repo> --json body --jq '.body' | grep -q '<!-- do-work-blocked-until:'; then
       echo "[scope-preflight] WARNING: #<N> do-work-blocked-until body marker did not land — issue will be re-scoped next session instead of self-clearing"
     fi
     ```

     No label applied. The marker alone gates via the [step-4 client-side filter](04-backlog-divert.md#4-fetch--rank-the-backlog) — drops while `today < date`, re-admits at date elapsed.

  4b. **Write a self-clearing `<!-- do-work-blocked-until: YYYY-MM-DD -->` marker** when `$DEFER_REASON_CLASS == "external-dependency"` ([#1195](https://github.com/mattsears18/shipyard/issues/1195)):

     ```bash
     export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
     SHIPYARD_REPO_ROOT=$(cat .shipyard-primary-root 2>/dev/null) || SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel)"
     export SHIPYARD_REPO_ROOT
     DAYS=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get scope.external_dependency_recheck_days 2>/dev/null || echo 14)
     DAYS=${DAYS//[!0-9]/14}
     DATE=$(date -u -d "+${DAYS} days" +%F 2>/dev/null || date -u -v+"${DAYS}"d +%F)

     CURRENT_BODY=$(gh issue view <N> --repo <owner/repo> --json body --jq '.body')
     if echo "$CURRENT_BODY" | grep -q '<!-- do-work-blocked-until:'; then
       EXISTING_DATE=$(echo "$CURRENT_BODY" | grep -oE '<!-- do-work-blocked-until: [0-9]{4}-[0-9]{2}-[0-9]{2} -->' | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
       if [[ "$EXISTING_DATE" > "$DATE" ]]; then
         NEW_BODY="$CURRENT_BODY"
       else
         NEW_BODY=$(echo "$CURRENT_BODY" | sed -E "s/<!-- do-work-blocked-until: [0-9]{4}-[0-9]{2}-[0-9]{2} -->/<!-- do-work-blocked-until: ${DATE} -->/")
       fi
     else
       NEW_BODY="<!-- do-work-blocked-until: ${DATE} -->

$CURRENT_BODY"
     fi
     if [ "$NEW_BODY" != "$CURRENT_BODY" ]; then
       gh issue edit <N> --repo <owner/repo> --body "$NEW_BODY"
     fi
     if ! gh issue view <N> --repo <owner/repo> --json body --jq '.body' | grep -q '<!-- do-work-blocked-until:'; then
       echo "[scope-preflight] WARNING: #<N> do-work-blocked-until marker did not land"
     fi
     ```

  5. **Inline auto-decompose a mechanically-decomposable epic.** This step fires **only** when ALL of the following hold; otherwise skip it (the human handoff recorded by steps 1–4 is the final state, exactly as before #665):

     - `defer_reason_class == "confirmed-non-shippable-as-single-PR"` (the epic-decomposition class — the one that just got `needs-human-review` + the `<!-- do-work-needs-decomposition -->` marker in steps 2/4), **and**
     - the `evidence_pointer` starts with one of the two **mechanically-decomposable** prefixes — `Multi-PR sequence:` or `Missing dependency:` (the non-mechanical prefixes `Multi-service coordination:` and `Body cites <artifact>:` are **excluded** — they always stay on the human handoff), **and**
     - `decompose.auto` is `true` (the merged-config knob, default `true` — read it once at session start alongside `scope.self_modification_paths`; `shipyard-config.sh get decompose.auto`). Setting `decompose.auto: false` is the **opt-out** that restores the pre-#665 park-for-manual-`/decompose-epic` behavior.

     When it fires, **inline-invoke the `/decompose-epic` decomposition-worker logic** against this single issue — do NOT re-implement the sharding here. [`/decompose-epic`'s Worker prompt template](../../decompose-epic.md#worker-prompt-template) is the **single source of truth** for the sharding (evidence-class read → ordered breakdown → confidence gate → sub-issue creation with the `Blocked by #<sibling>` chain → parent mutation, or the escalate fall-through). Dispatch it exactly as the standalone command does — one background `Agent` call, `subagent_type: "shipyard:decompose-worker"`, **no `isolation: "worktree"`** (the worker only reads the codebase read-only and calls the GitHub API), passing the epic number `#<N>`, `<owner/repo>`, and `--max-subissues <decompose.max_subissues>` (merged-config knob, default `8`). The worker reads the diagnosis comment posted in step 2 (which carries the `<!-- do-work-needs-decomposition -->` marker and quotes the `evidence_pointer`) to recover the evidence class, so steps 2/4 must run **before** this dispatch.

     Reusing the worker template (rather than re-implementing the sharding here) means its guardrails apply unchanged: the confidence gate + `--max-subissues` cap live inside the worker (its Step B) and **escalate** — not double-park — on a low-confidence or over-cap breakdown (its Step D: posts the `<!-- do-work-decompose-agent -->` "couldn't auto-decompose: <reason>" comment and leaves the existing `needs-human-review` + trigger-marker handoff unchanged); the worker treats the epic body as an untrusted claim it re-derives against the codebase (the orchestrator passes only the issue number and repo, never the body); and the parent stays `needs-human-review` and OPEN on the success path too (the worker's Step C keeps the label and posts the idempotency comment), so a later standalone `/decompose-epic` run never double-shards it. See [RATIONALE → Inline auto-decompose reuses the decompose-epic worker logic (#665)](../../do-work-RATIONALE.md#step-6--inline-auto-decompose-reuses-the-decompose-epic-worker-logic-issue-665) for the full reuse rationale.

     **Recording the outcome.** The worker returns one of `decomposed: #<N> → <K> sub-issues (#A, #B, …)`, `escalated: #<N> (<reason>)`, or `blocked: <reason>`. On `decomposed:` — log `[scope-preflight] #<N> inline auto-decomposed into <K> sub-issues (#A, #B, …); parent kept as needs-human-review tracking umbrella` and count it in the end-of-session summary's Deferred/decomposed block. The **newly-created shards re-enter the normal dispatch loop the same session**: they're fresh `shipyard`-labelled issues with no gate label, so the next backlog fetch ([step 4 backlog-divert](04-backlog-divert.md#4-fetch--rank-the-backlog)) / scope-refill picks them up, sequenced by their `Blocked by #<sibling>` chain (the first phase dispatches immediately; each later phase unblocks when its predecessor's PR merges). On `escalated:` — log `[scope-preflight] #<N> inline auto-decompose escalated (<reason>) — human handoff preserved` and leave the recorded defer as-is (the epic remains a `needs-human-review` handoff surfaced by `/my-turn`). On `blocked:` — log the reason and leave the human handoff in place (do not retry inline; a maintainer or a later `/decompose-epic` run can revisit).

     This inline dispatch is **best-effort and non-blocking to the scope-preflight pass**: fire it as a background `Agent` call and continue recording the rest of the batch — do not stall first-dispatch latency waiting on the decomposition worker. If the dispatch itself can't be made (agent-spawn error), fall back to the pre-#665 behavior: the human handoff from steps 1–4 is already recorded, so the epic simply waits for a manual `/decompose-epic` — no work is lost. The same reuse applies at the [drain 5.a / 5.b re-validation](../drain.md#5a--re-validate-orchestrator-judgment-entries) call sites: when a re-validated defer is `confirmed-non-shippable-as-single-PR` with a mechanical `evidence_pointer` and `decompose.auto` is true, the re-validation runs this same inline auto-decompose rather than re-parking the epic.

  **Why a rejection path and not just stricter prompting.** The prompt instruction biases the agent toward evidence-backed defers, but prompts are not contracts — a sufficiently confident agent can still produce a defer with a speculative `evidence_pointer` like "probably needs design review". The orchestrator-side validator is the hard gate: speculative-judgment text gets caught by the per-class shape check before it lands in `deferred_issues`. This is the same defense-in-depth posture as the body-vs-codebase rule in `issue-worker.md` step 2 (the worker re-derives the implementation from the codebase even when the body suggests one) — the prompt is the first line, the orchestrator's mechanical check is the load-bearing second line. See [RATIONALE → Evidence-backed defers (issue #302)](../../do-work-RATIONALE.md#evidence-backed-defers-issue-302) for the full motivation.

- **Already-landed entries** ([#992](https://github.com/mattsears18/shipyard/issues/992)) — the [staleness probe](06-scope-preflight.md#staleness-probe--has-this-already-landed-on-origindefault-branch-992) found no checkable claim in the issue still holds on `origin/<default-branch>`; nothing here needs a worker dispatch. **Validate first:** `already_landed` and `evidence_pointer` must both be present and non-empty. A missing/empty field is treated like a malformed deferred return — log `[scope-preflight] #<N> already-landed return REJECTED — missing already_landed/evidence_pointer`, do NOT close the issue, and push it back onto `raw_backlog` (preserving rank) for a fresh scope pass rather than trusting an unsupported claim. When valid:

  1. Post a comment: `Scope-preflight found this issue's request already fully implemented on origin/<default-branch>: <already_landed> (evidence: <evidence_pointer>).`
  2. Close the issue: `gh issue close <N> --repo <owner/repo> --reason completed`.
  3. Log `[scope-preflight] #<N> already-landed — closed without dispatch (evidence: <evidence_pointer>)`.

  Do NOT append to `deferred_issues` (this isn't a defer — there's no remaining work to gate) and do NOT apply `needs-human-review` / `needs-operator` (there's no pending human/operator action). The staleness probe's outcome-3 corroboration requirement (a merged PR/commit citation, not a single ambiguous grep miss) is the primary defense against a false close here; closing is also a one-command-reversible recovery (`gh issue reopen`) if a human later disagrees, unlike the silently-dropped-work cost of misclassifying a partial landing as full (which the probe instead routes to a narrowed `phase_1_scope` on a normal **ready** return, never this shape).

Remove every processed issue number from `raw_backlog` regardless of which shape was returned (ready, deferred, or already-landed) — all three are "done" from the scoping pass's perspective. Issues whose pre-scope detector synthesized a deferred entry (per the [Pre-scope orchestrator-side detectors](06-scope-preflight.md#pre-scope-orchestrator-side-detectors-synthetic-defers) section above) are also removed by this sweep — the detector's own handling step 4 names this explicitly, but the bulk remove here is the unified mechanism. (The Rejection path in the Deferred-entries handler above, and the already-landed validation failure path just above, explicitly re-push the issue back onto `raw_backlog` after the bulk remove, preserving the issue's original rank — those are the exceptions, and they're deliberate: an unsupported return is "not done" and needs another scope pass.)

**First-dispatch latency target.** The rolling model cuts first-dispatch latency from ~30 s (wait all 2N agents) to ~5–10 s (wait only the fastest scoping agent in the batch). Subsequent dispatches read directly from `ready_issues` — no scope-wait at all when at least one scoped entry is queued.

**Edge case — all entries are deferred.** If every scoping agent in the initial batch returns a deferred shape (unlikely but possible), `ready_issues` stays empty. Step 7 cannot dispatch. Proceed to step 6.8 (setup timing flush) and record a `[scope-preflight] all candidates deferred — no initial dispatch` advisory; the steady-state loop will attempt scope-refill on the next turn.

The same handling applies anywhere scoping runs (step 6 initial pre-flight + step D's background scope refill). A scoping agent's return contract is identical across those call sites; the orchestrator branches on `deferred` presence the same way each time.

### 6.5 Status line + state-change banners (UI)

There are two UI surfaces — both unconditionally re-print whenever repo-health state changes, so the user never has to scroll back to figure out what's going on.

#### Status line — one-line repo-health header

Print before the initial pool fill, and again at the top of any turn where state visibly changed (a completion landed, a divert flipped, the failing-PR count crossed the threshold either way, main flipped color, or a soft-collision claim count changed). Format:

```
/do-work · <owner/repo> · main:<emoji> · in-flight: <n>/<concurrency> [<labels>] · failing PRs: <m> (@me: <k>)<soft-suffix><divert-suffix>
```

Fields:

- **main:** — `🟢 green`, `🔴 red (<workflow-summary>, run <id>)`, `⏳ pending`, or `❔ unknown`. When red, `<workflow-summary>` is derived from `main_ci.red_workflow_count` and `main_ci.red_workflow_names`:
  - 1 failing workflow → `<workflow-name>, run <id>` (e.g. `Deploy to Play Store, run 18234567`)
  - 2–3 failing workflows → `<name1>, <name2>[, <name3>], run <id>` (list all names if they fit, truncate with `+N more` if needed to keep the status line under ~120 chars)
  - 4+ failing workflows → `<red_workflow_count> workflows: <name1>, <name2>, +<N> more, run <id>` (limit to 2 names before `+N more`)

  In all cases the run ID (`main_ci.earliest_red_run_id`) remains at the end of the parenthetical so the user can navigate directly to the failing run. No extra `gh` call — all data is in the `main_ci` cache from step 4.5a.

  When `main_ci.non_required_red_workflow_count > 0` (non-required workflows are red but main is gated to required-only), append a parenthetical suffix to the main field after the primary `🟢/🔴/⏳/❔` parenthetical (or directly after the emoji when status is green / pending / unknown): ` (infra: <name1>, <name2>[, +<N> more])`. Limit to 2 names plus `+N more` to stay terse. Example: `main:🟢 (infra: Android Release Notes)` — the green emoji communicates "no divert", the parenthetical surfaces the non-gating failure so the maintainer doesn't lose visibility into it. When `non_required_red_workflow_count == 0` (the common case), omit the suffix entirely.
- **in-flight labels** — comma-separated, derived from each entry's `kind`/`target`: issue → `#N`, fix-checks → `fix-checks #M`, fix-main-ci → `⚠️ fix-main-ci`, fix-failing-prs-batch → `⚠️ fix-prs-batch`. Empty list → `[ ]`.
- **failing PRs:** — the all-authors count from `failing_pr_count_all`. The `(@me: <k>)` parenthetical comes from `failed_prs.length + in_flight fix-checks count`. Append ` ⚠️` to the count when it's ≥ 10 (matches the divert threshold).
- **soft-suffix** — when one or more soft-collision paths are claimed by in-flight workers, append ` · [soft: <path>×<n>, <path>×<n>, ...]` listing each distinct claimed soft path and how many in-flight workers are holding it. Order by claim count desc, then alphabetical. Bracket and brackets are part of the surface (visually similar to the in-flight labels). Append ` ⚠️` to any path whose count equals `--soft-collision-concurrency` (the cap — next claimer on that path will park). Omit the suffix entirely when no soft-collision claims are active.
- **divert-suffix** — when a divert is enqueued but not yet in flight, append ` · diverting: <kind>`. When already in flight, the `[ ]` labels already make that visible, no suffix needed.
- **flake-escalated-suffix** ([#589](https://github.com/mattsears18/shipyard/issues/589)) — when any signature in `main_ci_fix_attempts` has `escalated == true`, append ` · flake-escalated: <sig> (<attempts> fix attempts, each green-on-PR/red-on-merge)`. This is the fix-main-ci attempt-cap circuit breaker firing: main is still red on `<sig>` but the orchestrator has stopped auto-diverting because each of `<attempts>` fix PRs passed on its own PR run and re-reddened the merge commit (a flaky-CI signature). When more than one signature is escalated, list each (comma-separated). The suffix persists until a human gets main green on `<sig>` (which clears the counter). Distinct from `· diverting:` — an escalated signature is explicitly NOT being diverted.

Examples:

```
/do-work · mattsears18/lightwork · main:🟢 · in-flight: 2/2 [#769, #768] · failing PRs: 3 (@me: 1)
/do-work · mattsears18/shipyard · main:🟢 · in-flight: 3/4 [#63, #65, #67] · failing PRs: 0 (@me: 0) · [soft: plugins/shipyard/commands/do-work.md×3 ⚠️, CHANGELOG.md×3 ⚠️]
/do-work · mattsears18/lightwork · main:🔴 (Deploy to Play Store, run 18234567) · in-flight: 2/2 [⚠️ fix-main-ci, #769] · failing PRs: 12 ⚠️ (@me: 2) · diverting: fix-failing-prs-batch
/do-work · mattsears18/lightwork · main:🔴 (3 workflows: Deploy to Play Store, Lighthouse CI, +1 more, run 18234567) · in-flight: 1/2 [⚠️ fix-main-ci] · failing PRs: 0 (@me: 0)
/do-work · mattsears18/lightwork · main:🟢 (infra: Android Release Notes) · in-flight: 2/2 [#769, #768] · failing PRs: 3 (@me: 1)
/do-work · mattsears18/lightwork · main:⏳ · in-flight: 0/2 [ ] · failing PRs: 0 (@me: 0)
/do-work · mattsears18/lightwork · main:🔴 (Web E2E Tests, run 18234567) · in-flight: 1/2 [#769] · failing PRs: 0 (@me: 0) · flake-escalated: Web E2E Tests (3 fix attempts, each green-on-PR/red-on-merge)
```

The soft-suffix is the human's signal that merge conflicts may surface at PR-land time on those paths. When a count hits the cap (` ⚠️`), the orchestrator is also one step away from parking — and the user can decide whether to bump `--soft-collision-concurrency` mid-session (next-session-only, the cap isn't hot-reloadable today) or let dispatch park.

When to print the status line: (a) startup, right before the initial pool fill; (b) any turn where `divert_queue` gained or lost an entry; (c) any turn where `main_ci.status` changed since the previous print; (d) any turn where `failing_pr_count_all` crossed the 10 threshold in either direction; (e) start of the end-of-session summary; (f) right after any state-change banner below; (g) any turn where a soft-collision claim count crossed `--soft-collision-concurrency` (entering or leaving the cap) on any path.

#### State-change banners — make divert events impossible to miss

The status line is for at-a-glance state. **Banners** are for the moments where state CHANGES — they're a 3-line block with blank lines above and below, so they stand out from completion-reconcile logs. Print every time one of the trigger conditions fires; never suppress them.

**Main flipped red → enqueueing a fix-main-ci diversion:**

```

⚠️  MAIN CI RED — diverting next available slot to fix
   Failed workflow: <earliest_red_workflow_name>
   Earliest red run: <earliest_red_run_url>
   Triggered at: <YYYY-MM-DDTHH:MM:SSZ>

```

When `red_workflow_count > 1`, replace the single `Failed workflow:` line with a plural form listing all failing workflows from `red_workflow_names`:

```

⚠️  MAIN CI RED — diverting next available slot to fix
   Failed workflows (3): Deploy to Play Store, Lighthouse CI, Visual Regression
   Earliest red run: <earliest_red_run_url>
   Triggered at: <YYYY-MM-DDTHH:MM:SSZ>

```

The workflow list in the banner is always the **full** `red_workflow_names` list (no truncation — banners are one-shot so verbosity is fine). Use a comma-separated inline list.

When `non_required_red_workflow_count > 0` AND the banner above is firing (a `green → red` transition on the *gating* set), append an info line after the workflows list noting which non-required workflows are also red, so the maintainer's mental model stays accurate:

```
   Non-required workflows also red (not diverting): Android Release Notes
```

When the banner is NOT firing because the gating set is green but `non_required_red_workflow_count` flipped from 0 → ≥1 (e.g. an infra workflow just turned red while CI stayed green), print a softer notification banner instead — this is a `🔔` advisory, not a divert trigger:

```

🔔  NON-REQUIRED CI WORKFLOW(S) RED — main_ci.status stays green, no divert
   Failed (non-required): Android Release Notes
   Note: these workflows aren't in branch protection's required_status_checks list; resolve in their respective consoles.

```

Trigger this notification banner only on the 0 → ≥1 transition (not every refresh) to keep the surface terse — the per-turn status-line `(infra: ...)` suffix carries the steady-state visibility.

**fix-main-ci dispatched (slot now in flight):**

```

🔧  DISPATCHED fix-main-ci on slot <id> — agent investigating <earliest_red_run_id>

```

**fix-main-ci attempt-cap hit → flake escalation, NOT diverting** ([#589](https://github.com/mattsears18/shipyard/issues/589)). Fired once per signature on the transition into `main_ci_fix_attempts[<sig>].escalated == true` (when `attempts >= main_ci.max_fix_attempts` and the red branch of [step 4.5a's enqueue rule](04-backlog-divert.md#45-divert-checks-main-ci--pr-pileup) declines to enqueue):

```

🚩  FIX-MAIN-CI CAP HIT — likely flaky test, NOT diverting again
   Workflow: <earliest_red_workflow_name>
   Fix attempts this session: <attempts> (each green on its own PR run, red on the merge commit)
   Latest fix PR: #<last_pr> · earliest red run: <earliest_red_run_url>
   This pass-on-PR/fail-on-merge pattern is a strong flaky-CI signal (a deterministic
   regression would fail the PR run too). Recommended: quarantine the test (test.fixme /
   skip) + file a tracking issue, OR investigate CI-side. No further auto-dispatch for this
   workflow until a human gets main green on it.

```

The cap is the fix-main-ci analogue of the `blocked:ci` 3-attempt circuit breaker for fix-checks. After the banner fires, the status line carries `· flake-escalated: <sig> (<attempts> fix attempts, each green-on-PR/red-on-merge)` until a human resolves it (main goes green on `<sig>`, which clears the counter at the next green refresh).

**Main flipped back to green (red → green transition):**

```

✅  MAIN CI RESTORED — back to green at run <newest_green_run_id>

```

If a fix-main-ci diversion is in flight when this fires, also add: `   (in-flight fix-main-ci will finish naturally; result may already be redundant)`.

**Failing-PR count crossed UP through 10 — enqueueing a fix-failing-prs-batch diversion:**

```

⚠️  FAILING PR PILEUP — <n> open PRs are red, threshold is 10
   Sample: #<a>, #<b>, #<c>, ... (+ <k> more)
   Diverting next available slot to investigate common root cause.

```

**fix-failing-prs-batch dispatched:**

```

🔧  DISPATCHED fix-failing-prs-batch on slot <id> — investigating <n> failing PRs

```

**Failing-PR count crossed DOWN through 10:**

```

✅  PR PILEUP CLEARED — <n> failing PRs remain (below 10 threshold)

```

**Diversion completed (any kind):**

When a `fix-main-ci` or `fix-failing-prs-batch` worker returns, print a banner BEFORE the normal reconcile line:

- `shipped` → `✅  DIVERSION RESOLVED — fix-main-ci shipped via PR #<M> (auto-merge enabled)`
- `noop` → `➖  DIVERSION NO-OP — fix-main-ci: main already green by the time the agent started`
- `blocked` → `🛑  DIVERSION BLOCKED — fix-main-ci: <reason>. No auto-retry; needs human attention.` (and the status line that follows will keep showing `main:🔴` until a human resolves it)

**End-of-session — diversion summary block.** The end-of-session summary (below) carries a `Diversions:` block when `D > 0` — counts per kind, with shipped/noop/blocked breakdowns and PR numbers. That's how the user sees what diversions fired even if they weren't watching the session live.

The rule of thumb is: banners are LOUD and one-shot (printed when the transition happens), the status line is the persistent at-a-glance view (re-printed whenever the underlying state changes). Both should appear together when a divert fires — banner first, then the updated status line immediately below it.

### 6.8 Flush setup timing into session state

**Before dispatching the first wave of workers**, flush the setup-timing sidecar into the session state file's `setup` block. This ensures the timing data survives even if the session terminates mid-run (e.g. a Claude Code crash between pool fill and the first completion notification). The flush is fire-and-forget — a failure must NOT block pool fill.

```bash
CLAUDE_PLUGIN_ROOT=$(cat .shipyard-plugin-root 2>/dev/null)
export CLAUDE_PLUGIN_ROOT
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-timing.sh" flush \
  --session-id "<session-id>" 2>/dev/null || true
```

After this call the sidecar is gone and the session state file's `.setup` block contains the full per-phase wall-clock breakdown. The cost-history flush at end-of-session will pick it up automatically.

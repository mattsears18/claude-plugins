# /shipyard:do-work — Operator phase (default-on)

The browser-operator layer of `/do-work`, loaded **by default on every run** since [#661](https://github.com/mattsears18/shipyard/issues/661) made autonomous, operator-inclusive operation the default. It is loaded for a plain `/do-work` run. It is **skipped only under the `--no-operate` / `--hands-off` opt-out** — the rare dispatch-only run.

This phase adds one capability to the autonomous loop: the orchestrator drains an [`operator_queue`](../do-work.md#orchestrator-state) of **browser-completable operator actions** by driving whichever [browser backend](#browser-backend--selection-and-detection) the task needs — a headless session for inspection and verification, the user's real, logged-in Chrome for actions that need the live session directly — the work `/do-work` otherwise *defers* or *hands back*. It turns "I can't proceed, handing this back" moments into "I did it in the browser."

It owns the browser-driving machinery (backend selection, self-onboarding preflight, stale-tab recovery, standing authorization, read-page perception) **plus** the queue-drain loop and the proactive browser-completable sweep — see [On-demand bodies](#on-demand-bodies) below for where each of those now lives.

## How it fits the loop

- **Preflight runs once** at session start (right after [setup step 1.7](./setup/01-repo-recovery.md#17-resolve-trusted-author-allowlist), before the first dispatch) on every run except under `--no-operate` / `--hands-off`. It selects + connects a browser backend and front-loads site permissions. See [Preflight](#preflight--detect-gaps-and-guided-setup).
- **The code loop is unchanged.** Issue-workers still dispatch into worktrees and parallelize per `--concurrency`. The operator layer does not change how code work is dispatched, ranked, or reconciled.
- **Serialization is scoped to the authenticated shared browser, not to browser work in general** ([#996](https://github.com/mattsears18/shipyard/issues/996)). The user's real Chrome (driven via `claude-in-chrome`, or `chrome-devtools-mcp` attached to it) is a singleton — only one driver at a time — so any item that needs that live session serializes on the main orchestrator thread, drained one at a time in the **idle gaps**: while waiting for a code worker to return, and at each [step-D refresh tick](./steady-state.md#d-periodic-refresh). The headless backend ([`/browse`](#browser-backend--selection-and-detection)) is not the shared singleton and carries no such constraint on its own — today's drain loop still runs every `operator_queue` item through the same single-threaded orchestrator drain regardless of backend eligibility (never via a subagent — see [`05-dont.md`](./operate/05-dont.md)); actually dispatching headless-eligible reads in parallel with code workers is a further step this note does not itself implement. Code churns in parallel worktrees while the orchestrator operates the browser in between.
- **Termination includes the operator queue.** The loop does not end until the code backlog, the in-flight set, **and** `operator_queue` are all empty (plus the usual main-green drain). See [drain.md termination](./drain.md#termination-assertion).
- **The preflight's outcome is the source of the invariant line's `operator=` token** ([#1193](https://github.com/mattsears18/shipyard/issues/1193)). The moment the preflight resolves — `active` (a backend was selected) or `unreachable` (see [Degradation](#degradation--no-backend-reachable) below) — [steady-state.md's per-turn invariant line](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn) starts reporting it; under `--no-operate` / `--hands-off` the value is `skipped`, known at arg-parse time without this preflight ever running. This makes a session that never loaded this file at all visible on its very first turn as a missing `operator=` token, rather than only discoverable at end-of-session when a human notices untouched `agent-console` issues.

### Degradation — no backend reachable

If the preflight finds **no live-session backend reachable** (neither `claude-in-chrome` nor `chrome-devtools-mcp` — tiers 2–3), the operator layer degrades gracefully rather than aborting: the normal code loop runs to completion, and any `operator_queue` items are **surfaced as hand-backs** in the end-of-session summary (and left on their `agent-console` label) instead of being driven. Print one warning at preflight time and proceed. The operator layer never kills or blocks the autonomous code loop. A missing headless tier (tier 1) alone does **not** trigger this degradation — it only narrows inspection/verification work back onto whichever live-session backend is available, the same as before this ladder existed. **This is the `operator=unreachable` case for the [steady-state invariant line](./steady-state.md#e-invariant-line-end-of-every-steady-state-turn)** — set once, here, and held for the rest of the session.

This is exactly the case [`cleanup-summary.md`'s `Operator queue — needs you (N):` block](./cleanup-summary.md#end-of-session-summary) exists for ([#849](https://github.com/mattsears18/shipyard/issues/849)): since nothing was ever popped off `operator_queue` this session (the drain loop never ran), there is no per-item `operator_handbacks` append to make — cleanup-summary reads the leftover `operator_queue` entries directly and renders each with `reason: "no-browser-backend"`. The same applies to a `--dry-run` session (items are previewed, not driven, and stay queued — cleanup-summary renders them with `reason: "dry-run"`). Either way the end-of-session summary must name the N items and hand the interactive drain command back to the user rather than let them read as a routine dispositioned line.

## Browser backend — selection and detection

**Any backend available to the session may be used to complete browser-completable work — this is a preference-ordered set, not a single named backend** ([#996](https://github.com/mattsears18/shipyard/issues/996)). A hand-back written after trying only one backend has not exhausted the options; see [Falling back vs. retrying a denial](#falling-back-vs-retrying-a-denial-996) below before writing one. The preflight detects and selects, in order:

1. **Headless (gstack's `/browse` skill, plus `/setup-browser-cookies` when the surface needs auth)** — **first choice for inspection and verification work**: navigating, reading a page, confirming a setting's current value, walking the [exhaustion checklist](./operate/03-error-handling-and-safety.md#exhaustion-checklist--before-declaring-a-console-unreachable-998). Fast, doesn't contend for the singleton below, and doesn't disturb the user's live, visible Chrome window. **Not limited to logged-out pages** — `/setup-browser-cookies` imports `Cookies` + `Login Data` from the user's real Chromium profile into the headless session's own persistent profile (`~/.gstack/chromium-profile/`), so it covers authenticated surfaces too, given that one-time import. Reach for it whenever the task is "what does this page currently say" rather than "make this change on my account."
2. **`claude-in-chrome` (the Claude Chrome extension)** — **preferred for the live-session work headless can't cover**: the mutating operator playbooks (`close-pr` / `merge-pr` / `toggle-setting` execute / `console-action` execute / `paste-secret` tee-up), or any inspection where no importable cookie session exists for the target site. Runs *inside* the user's real Chrome, so it natively inherits every logged-in session (GitHub, Vercel, Firebase Console, App Store Connect, etc.) with no remote-debugging setup and no logged-out-isolated-instance hazard. Per-site access is gated by the extension's own permission grants. Richer toolset (`read_page`, `get_page_text`, `find`, `browser_batch`, `gif_creator`).
3. **`chrome-devtools-mcp` (with `--autoConnect`)** — **fallback**, used only when the extension is absent, for the same live-session work item 2 covers. Carries the remote-debugging caveats in [chrome-devtools-mcp fallback notes](./operate/03-error-handling-and-safety.md#chrome-devtools-mcp-fallback-notes).
4. **None reachable** — the operator layer [degrades](#degradation--no-backend-reachable) to code-loop-only with operator items surfaced as hand-backs.

### Falling back vs. retrying a denial ([#996](https://github.com/mattsears18/shipyard/issues/996))

Trying the next tier of this ladder is **not** the same thing as re-attempting a *denied* action, and the two must never be conflated:

| Situation | Correct response |
|---|---|
| A backend is absent, not yet authenticated, or times out — but a live session exists somewhere to import, or a different backend can reach the target | **Try the next tier and continue** — this is not a hand-back |
| No live session exists anywhere for that site (no backend has ever been authenticated to it) | Hand back — but say *"sign in once, then this is automatable"*, not *"impossible"* |
| The action itself was **denied by the harness permission classifier** on the backend attempted | Hand back; **never** route around the denial by trying a different backend — the [existing prohibition](./operate/05-dont.md) is unchanged |

Collapsing row 1 into row 2 is the failure this ladder exists to close — a backend that merely isn't authenticated *yet* looks identical, from a single failed attempt, to a site nobody is signed into anywhere; only the [exhaustion checklist](./operate/03-error-handling-and-safety.md#exhaustion-checklist--before-declaring-a-console-unreachable-998) tells the two apart. Collapsing row 1 or 2 into row 3 — treating "this backend hasn't been tried yet" as license to retry a *denied* action through it — is the opposite failure: `dont.md`'s prohibition on iterating against the classifier applies identically regardless of which backend issued the call.

### Detection

- **Headless skill present?** The `browse` skill (and its `setup-browser-cookies` companion) is available in the session's skill listing. No connection handshake needed — invoke it directly with the read task; import cookies first only when the target surface needs auth.
- **Extension present?** The `mcp__claude-in-chrome__*` tools are in the available tool set. Confirm a live connection with `mcp__claude-in-chrome__tabs_context_mcp` (the canonical session-start call — it also surfaces current tabs for [tab reuse](./operate/02-execution-and-playbooks.md#tab-reuse)). Live context → select the extension backend.
- **Else chrome-devtools-mcp present?** The `mcp__chrome-devtools__*` tools are present. Confirm with `mcp__chrome-devtools__list_pages` (returns pages, not a connection error) → select the chrome-devtools-mcp backend.
- **Else** → no backend; degrade.

### Backend tool mapping

The mutating, live-session playbooks are written **backend-neutral** in terms of these abstract actions, across the two live-session backends (tiers 2–3 above). The headless backend (tier 1) is invoked as a single `browse` skill call describing the inspection task rather than a per-action tool call, so it has no row in this table — it isn't used for the click/fill mutation primitives below.

| Abstract action | claude-in-chrome (preferred) | chrome-devtools-mcp (fallback) |
|---|---|---|
| See current tabs | `tabs_context_mcp` | `list_pages` |
| Open / reuse tab | `tabs_create_mcp` / reuse from context | `new_page` / `select_page` |
| Navigate | `navigate` | `navigate_page` |
| **Read page (default perception)** | `read_page` / `get_page_text` | `take_snapshot` |
| Find an element | `find` | `take_snapshot` (locate via uid) |
| Click | `computer` (click) | `click` |
| Fill a field / form | `form_input` | `fill` / `fill_form` |
| Screenshot (only when visual state matters) | `computer` (screenshot) | `take_screenshot` |
| Batch deterministic steps | `browser_batch` | sequential calls (no batch) |
| Record action | `gif_creator` | — (not supported; `--record` is a no-op) |

## Preflight — detect gaps and guided setup

Runs **once** at session start by default (unless `--no-operate`), before the first dispatch. It verifies every prerequisite and, on any gap, **alerts the user and walks them through the fix interactively** rather than failing opaquely. **Silent on success** — when everything is already configured it prints a single one-line [summary](#preflight-summary) and the loop proceeds with zero friction.

### Self-heal loop (applied to each failing check)

1. **Alerts** — names the specific gap in plain language.
2. **Instructs** — prints the exact steps to fix it (commands to run, UI toggles to flip).
3. **Waits** — asks via `AskUserQuestion`, options scaled to the gap, e.g. `["Done — re-check", "Use fallback backend", "Run code loop only (no browser)"]`.
4. **Re-checks** — on "Done", re-runs that check's detection; on success, advances.
5. **Caps retries** — after **2** failed re-checks for the same gap, stop looping and either fall back (a degraded backend) or [degrade to code-loop-only](#degradation--no-backend-reachable).

Never spin silently. The one **hard blocker** is gh auth (the whole loop needs it); a missing browser backend is *not* a hard blocker for the operator layer — it degrades to code-loop-only.

### Checks (in order)

Checks 2–5 below cover only the **live-session** backends (tiers 2–3 of the [backend ladder](#browser-backend--selection-and-detection)) — the headless backend (tier 1) needs no preflight handshake and its absence never triggers the self-heal loop; [Detection](#detection) simply notes whether the `browse` skill is present and, when it is, the first-choice tier for inspection work is available with zero setup cost.

**1. GitHub CLI auth (hard blocker).** `gh auth status`. If unauthenticated: instruct `gh auth login`, re-check; if unresolved after the cap, abort the whole `/do-work` run (the code loop needs `gh` too).

**2. Browser backend present.** Run [detection](#detection).
- **Extension detected** → check 3.
- **Only chrome-devtools-mcp detected** → note the preferred extension isn't present; offer `["Proceed on chrome-devtools fallback", "Walk me through installing the extension", "Run code loop only (no browser)"]`.
- **Neither detected** → guided install, recommending the extension first (install/enable it, confirm the `mcp__claude-in-chrome__*` tools load, note a Claude Code restart may be needed for a newly-added MCP server). If the user skips → degrade to code-loop-only.

**3. Backend connectivity.** Confirm the selected backend responds:
- Extension: `tabs_context_mcp` returns a live context. If it returns `No MCP tab groups found` / an empty context, the MCP tab group is absent — **not** a connectivity failure; recreate it with `tabs_context_mcp({createIfEmpty:true})` and proceed. (A closed/stale tab group later surfaces mid-run as a misleading `Permission denied by user` — see [Error handling](./operate/03-error-handling-and-safety.md#error-handling) for the recover-then-retry.)
- chrome-devtools-mcp: `list_pages` responds and is not a logged-out isolated instance (see [Error handling](./operate/03-error-handling-and-safety.md#error-handling)).

**4. Site permissions (extension only; non-blocking).** The extension gates access **per site**. Front-load grants for the domains the run will touch — `github.com` always, plus any third-party console the operator queue is likely to route to (Vercel, Firebase, App Store Connect, etc., per the [deep-link table](./operate/03-error-handling-and-safety.md#third-party-console-deep-links)). Only the user can grant in the extension UI; the walkthrough explains the model and asks `["github.com granted", "I'll grant on first navigation", "Skip"]`. Non-blocking — a missing grant just surfaces a one-time prompt on first navigation.

**5. Chrome recency (soft advisory).** The extension needs a current Chrome; the chrome-devtools-mcp fallback historically required Chrome 144+. One-line advisory only if a problem is suspected; never block.

### Preflight summary

```
Preflight (operator): ✓ gh auth (mattsears18) · ✓ headless: browse skill available · ✓ live-session backend: claude-in-chrome · ✓ github.com permitted
```

Degraded paths reflect in the summary (e.g. `⚠ live-session backend: chrome-devtools-mcp (fallback)` or `→ no live-session backend — mutating operator items will be handed back` — the headless tier degrading independently doesn't block the live-session backend from being selected, and vice versa).

## On-demand bodies

This file is a **thin router**: the browser-backend selection and self-onboarding preflight above genuinely run every session, so they stay eager. Everything else — the `operator_queue` mechanics, standing authorization, per-kind playbooks, error handling / safety, and the steady-state hooks — is only exercised when `operator_queue` is actually non-empty, so it moved on-demand into [`operate/`](./operate/), mirroring the [thin-router + on-demand-sub-file pattern](../do-work.md#phase-routing) `do-work.md` and `setup.md` already use.

| Operator sub-phase | Owns | When to load |
|---|---|---|
| [`operate/01-queue-and-authorization.md`](./operate/01-queue-and-authorization.md) | The `operator_queue`'s two feeders (reactive step-A.1, proactive step-D), the security/access-control-heavy-queue expectation note, standing authorization (+ the session-owned-vs-inherited-PR scope correction), and the harness-classifier-denial branch for operator actions | Once the queue holds (or is about to hold) an item, or when a worker/scope-agent return needs classifying as browser-completable |
| [`operate/02-execution-and-playbooks.md`](./operate/02-execution-and-playbooks.md) | Draining-an-item mechanics (plan-then-act, tab reuse, perception, batching, recording), the per-kind playbooks (`close-pr` / `merge-pr` / `toggle-setting` / `console-action` / `paste-secret` / `reply-comment` / `verify`), the CLI-first preference for CLI-coverable actions (`gcloud` / `vercel` / `gh`), and judgment-calls-are-never-enqueued | When actually executing (draining) a popped `operator_queue` item |
| [`operate/03-error-handling-and-safety.md`](./operate/03-error-handling-and-safety.md) | Browser-navigation error handling (incl. the extension's stale-tab-group recovery), the exhaustion checklist before declaring a console unreachable, the trust/safety boundary for browser actions, chrome-devtools-mcp fallback notes, and the third-party console deep-link table | When a navigation/action errors, when a hand-back would assert a console/account is unreachable, or when classifying an action against the trust boundary, or deriving a provider deep link |
| [`operate/04-steady-state-hooks.md`](./operate/04-steady-state-hooks.md) | The two hooks [`steady-state.md`](./steady-state.md) calls into (step-A.1 reactive enqueue, step-D proactive sweep + drain) | Consulted from `steady-state.md`'s own A.1 / D steps, on every run except `--no-operate` / `--hands-off` |
| [`operate/05-dont.md`](./operate/05-dont.md) | The operator-phase-specific prohibition list | Sidebar reference alongside whichever operator sub-phase above is active |

### How to load on demand

Read only the sub-phase relevant to what's currently happening. The eager preflight above never needs any of these five. Once the operator layer has something to *do* — a worker return or scope-agent defer names a browser-completable action, or the step-D proactive sweep finds one — load [`04-steady-state-hooks.md`](./operate/04-steady-state-hooks.md) first (it's the entry point `steady-state.md` calls into), which in turn points at [`01-queue-and-authorization.md`](./operate/01-queue-and-authorization.md) for the enqueue/authorization mechanics and [`02-execution-and-playbooks.md`](./operate/02-execution-and-playbooks.md) for the actual drain + playbook. Reach for [`03-error-handling-and-safety.md`](./operate/03-error-handling-and-safety.md) only when a navigation/action actually errors, when a hand-back is about to assert a console/account is unreachable (walk the exhaustion checklist first), or when an action needs trust/safety classification. Keep [`05-dont.md`](./operate/05-dont.md) as a sidebar alongside whichever of the four you're executing, the same way [`dont.md`](./dont.md) is a sidebar across every top-level phase.

**Don't pre-load adjacent sub-phases.** Each operator sub-file is self-contained for its topic; pulling the others into context defeats the split that exists to keep the eager surface small. The next sub-phase's file loads when the loop actually reaches it — most sessions with an empty `operator_queue` never load any of the five at all.

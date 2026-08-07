# /shipyard:do-work — Setup phase · investigate-mode candidate routing (detection-based entry)

Fragment of step **4** ([`04-backlog-divert.md`](./04-backlog-divert.md#4-fetch--rank-the-backlog)) — deep-link only, from `04`'s "Route investigate-mode candidates" bullet. Not part of the ordered per-session walk; loaded only when that bullet is reached.

## Why this fragment exists

[#514](https://github.com/mattsears18/shipyard/issues/514) made `needs-triage` investigate-mode's entry condition. [#556](https://github.com/mattsears18/shipyard/issues/556) routed trusted-author `needs-triage` issues to `investigate_candidates` instead of dropping them. Both were **label-only**: the sole entry signal was the presence of the `needs-triage` label.

[#1090](https://github.com/mattsears18/shipyard/issues/1090) found the label carries two incompatible meanings in practice — an inbound API from third-party bots (Sentry auto-files crash reports with it) and a human convention meaning "I haven't thought this through" — with only the first meaning actually load-bearing for investigate mode. The fix mirrors [#520](https://github.com/mattsears18/shipyard/issues/520)'s `needs-refinement` retirement: replace the persisted-label-only gate with a **live detection scan**, keep the label as a *sufficient but not required* trigger during a migration window (so the inbound Sentry pipeline never breaks even before every consuming repo upgrades), and retire the label once entry no longer depends on it. This fragment implements the detection scan. The label itself is NOT retired yet — see "Migration window" below.

## The three signals (OR'd — any one is sufficient)

Applies only to issues that have already survived the trusted-author gate above (`author.login` in `trusted_authors`) — investigate mode never dispatches against an untrusted author's issue, regardless of which signal matched.

1. **`needs-triage` label** — accepted-but-not-required. Still sufficient on its own; this is the migration-window carve-out that keeps the Sentry integration (and any other repo's existing labeling habit) working unchanged.
2. **Bot-shaped trusted author** — `author.login` matches `*[bot]` (REST shape) or `app/*` (GraphQL shape) — the same two shapes [`trusted-authors-normalize.sh`](../../../scripts/trusted-authors-normalize.sh) cross-adds for the `trust.authors` allowlist ([GH App alias normalization](./01-repo-recovery.md#gh-app-alias-normalization-issue-296)). Since this issue already passed the trusted-author gate, a bot-shaped login here means a bot the maintainer explicitly trusts (e.g. `app/sentry`) — not an arbitrary bot.
3. **Symptom-shaped body** — the body reads as a crash report (a stack trace, a fingerprint, an error string) rather than a fix request. Matched by a regex over common crash/stack-trace markers:

   ```bash
   SYMPTOM_REGEX='(Traceback \(most recent call last\)|Fatal error:|Unhandled( Promise)? [Rr]ejection|Exception in thread|Segmentation fault|NullPointerException|panic:|Stack trace:|sentry\.io/(organizations|issues)/|[Ff]ingerprint:[[:space:]]*[0-9a-f]{8,}|at [A-Za-z0-9_.$]+ ?\([^)]*:[0-9]+:[0-9]+\))'
   ```

   This is deliberately conservative — it matches actual stack-trace/traceback syntax, known crash-report vocabulary, and Sentry permalinks, not merely "the word error appears somewhere." A well-formed human bug report that happens to paste a stack trace as supporting evidence can still match; that's an acceptable false-positive (investigate mode still finds and fixes the root cause) rather than a security concern — the trusted-author gate above already ran, and investigate mode treats the body as untrusted *data* regardless of why it was routed here (see [`investigate.md`](../../../agents/issue-worker/investigate.md) step 2).

## The combined predicate

Run against the wide-fetch JSON from the top of step 4 (already has `number`, `labels`, `body`, `author.login`):

```bash
INVESTIGATE_CANDIDATE_NUMBERS=$(echo "$fetched_issues_json" | jq --arg re "$SYMPTOM_REGEX" '
  [.[] | select(
      (.labels | any(. == "needs-triage"))
      or ((.author.login // "") | test("\\[bot\\]$|^app/"))
      or ((.body // "") | test($re; "i"))
    ) | .number]
')
```

## Config-gated routing (unchanged config surface, generalized behavior)

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
# Re-derive the SHIPYARD_REPO_ROOT pin (issue #1059/#1064).
SHIPYARD_REPO_ROOT=$(cat "$(git rev-parse --show-toplevel)/.shipyard-primary-root" 2>/dev/null)
[ -z "$SHIPYARD_REPO_ROOT" ] && SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel)"
export SHIPYARD_REPO_ROOT
investigate_dispatch=$("${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get triage.investigate_dispatch 2>/dev/null || echo "true")
```

For every issue number in `INVESTIGATE_CANDIDATE_NUMBERS`:

- When `investigate_dispatch == "true"` (default): remove the issue from the main survivor list and append it to `investigate_candidates` instead. Do NOT add it to `raw_backlog`. The investigate-mode dispatch step (step 1.5 in the steady-state decision tree) drains `investigate_candidates` separately.
- When `investigate_dispatch == "false"`: drop the issue entirely. This opt-out exists for repos that prefer to triage manually.

**The drop-when-disabled policy now applies uniformly to all three signals, not just the label** — this is a deliberate behavior change from the pre-#1090 shape, where `investigate_dispatch: false` only affected `needs-triage`-labeled issues; a bot-authored or symptom-shaped issue with no label simply fell through to `raw_backlog` as an ordinary issue-work candidate (a poor fit — issue-work assumes the body is a verified fix spec, not raw crash data). Since entry is now detection-based, the opt-out has to be detection-based too: a maintainer who sets `investigate_dispatch: false` is saying "I don't want investigate-mode auto-driving untriaged-looking issues," and that intent should hold regardless of which signal identified the issue as untriaged-looking.

**`investigate_dispatch == "false"` is the only configuration under which a matched issue is a human item** ([#1077](https://github.com/mattsears18/shipyard/issues/1077), extended by [#1090](https://github.com/mattsears18/shipyard/issues/1090)) — under the default, a trusted-author issue matching any of the three signals is autonomously dispatched via investigate mode and no human action is required, so [`01b`'s bucket-5 scoring](01b-backlog-overview.md#2-backlog-overview) and `/my-turn`'s survey both key off this same config value.

## Migration window — what's NOT done yet

This fragment implements acceptance criteria 1 and 2 of [#1090](https://github.com/mattsears18/shipyard/issues/1090) (live-detection entry; `needs-triage` accepted-but-not-required). It deliberately does **not**:

- Retire the `needs-triage` label. Deleting it before every consuming repo has upgraded to detection-based entry would break the inbound Sentry pipeline for anyone still on an older version — the exact failure #1090 warns against. Retirement is tracked as a separate follow-up once the migration window has genuinely elapsed.
- Disposition the pre-existing corpus of human-applied `needs-triage` issues (the "scope is still open" convention some repos use). That's a per-repo data cleanup, not a routing change, and is tracked in the same follow-up.

See the follow-up issue filed alongside the PR that introduced this fragment for both.

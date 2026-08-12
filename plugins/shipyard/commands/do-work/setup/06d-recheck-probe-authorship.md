# /shipyard:do-work — Step 6, deferred entries 4c: automated `do-work-recheck` probe authorship

Deep-linked from [`06c-scope-handling-ui.md`](./06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes) step 4c — read this file only when you reach that pointer, not as part of the ordered per-session walk.

## Why this exists

[#1198](https://github.com/mattsears18/shipyard/issues/1198) shipped `scripts/eval-recheck-probe.sh` — an allowlist-only evaluator for a human-authored `<!-- do-work-recheck: <verb> <args...> -->` body marker that lets the proactive operator sweep test a blocking condition mechanically instead of only waiting out the `<!-- do-work-blocked-until: YYYY-MM-DD -->` calendar gate [#1195](https://github.com/mattsears18/shipyard/issues/1195) added for `time-gated` (and, once [#1199](https://github.com/mattsears18/shipyard/issues/1199) landed, `external-dependency`) defers. That slice deliberately left the marker human-authored only. This step ([#1201](https://github.com/mattsears18/shipyard/issues/1201)) is the automated write-time half: it lets the scope agent's own `evidence_pointer` optionally seed the marker when the blocking condition is mechanically checkable.

## Trigger

Runs immediately after [step 4b](06c-scope-handling-ui.md#handling-each-returned-entry-fires-as-each-background-agent-completes)'s calendar marker write, and **only** when both hold:

- `$DEFER_REASON_CLASS == "external-dependency"` (the same gate step 4b uses — `time-gated` is out of scope here; it has no upstream fact to probe, only a date).
- The merged-config knob `scope.recheck_probe_enabled` is `true` (the default — same knob the read side checks; skip this step entirely when it's `false`, since a marker written while the read side is disabled would sit dead).

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
SHIPYARD_REPO_ROOT=$(cat .shipyard-primary-root 2>/dev/null) || SHIPYARD_REPO_ROOT="$(git rev-parse --show-toplevel)"
export SHIPYARD_REPO_ROOT
RECHECK_ENABLED=$("$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get scope.recheck_probe_enabled 2>/dev/null || echo true)
if [ "$DEFER_REASON_CLASS" != "external-dependency" ] || [ "$RECHECK_ENABLED" != "true" ]; then
  : # not applicable — skip this step entirely, calendar-only behavior unchanged
fi
```

## Recognized structured shape — and why it's this narrow

The scope agent optionally appends a trailing clause to `evidence_pointer`, per the hint documented on the [`external-dependency` class](06-scope-preflight.md#6-initial-scope-pre-flight):

```
Recheck probe: <verb> <args...>
```

where `<verb> <args...>` is **exactly** the marker-body grammar `eval-recheck-probe.sh` already accepts (`npm-view <pkg> <field> == <expected>` or `gh-api repos/<owner>/<repo>/<endpoint> <jq-field> == <expected>`). This deliberately asks the scope agent to speak the validator's own grammar directly, rather than inventing a second, looser prefix vocabulary (e.g. free-text "Package X pinned pending Y") that this step would then have to translate into the marker grammar by hand. **That translation step is exactly the second construction path the issue calls out as the risk to avoid** — a hand-rolled translator could produce a plausible-looking but wrong probe (right shape, wrong semantics) that passes its own logic but never matches the real condition. Requiring the scope agent to emit the target grammar directly means this step's only job is extraction + validation, never construction-from-a-different-shape.

## Steps

1. **Extract the clause.** `evidence_pointer` is a single string already held from earlier in the Recording path. Take everything after the LAST occurrence of the literal substring `Recheck probe: ` (case-sensitive) to the end of the string. If the substring isn't present, **stop here — skip silently**, exactly as if this step never ran. Do not log a warning; an absent clause is the common case (most `external-dependency` defers have no single-command test), not an error.

2. **Validate against the shared evaluator — never construct the marker text by hand.**

   ```bash
   export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(R=$(git rev-parse --show-toplevel 2>/dev/null); if [ -d "$R/plugins/shipyard/scripts" ]; then echo "$R/plugins/shipyard"; else I=$(jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null); if [ -n "$I" ] && [ -d "$I/scripts" ]; then echo "$I"; else echo "$R/plugins/shipyard"; fi; fi)}"
   # (re-derived here — variables don't survive across Bash tool calls)
   PROBE_CLAUSE="<extracted text after 'Recheck probe: '>"
   # shellcheck disable=SC2086 — word-splitting on whitespace is exactly what
   # the validator expects (it tokenizes the same way internally); the clause
   # was extracted from evidence_pointer, itself derived from untrusted issue
   # body text, so this MUST go through --validate before anything downstream
   # ever treats it as a real command.
   PARSED=$("$CLAUDE_PLUGIN_ROOT/scripts/eval-recheck-probe.sh" --validate "<owner/repo>" $PROBE_CLAUSE)
   VALIDATE_STATUS=$?
   ```

   `--validate` is hermetic (no network, no `gh`/`npm` call) and is the exact same grammar the read side (`operate/04-steady-state-hooks.md`) re-checks on every evaluation — reusing it here means "can this marker ever be written" and "is this marker safe to evaluate" stay the same predicate, so the two paths can't drift apart.

   - **Non-zero exit (`invalid`)** — the clause didn't match either grammar (wrong verb, wrong token count, a field/expected value outside the allowlisted character classes, or a `gh-api` endpoint naming a different `<owner>/<repo>` than this invocation's — cross-repo probing is rejected by the validator itself, not by anything in this step). **Skip silently** — do not post a comment, do not log a WARNING (this is an optional hint that didn't pan out, not a failure of a required action). A single quiet log line is fine: `[scope-preflight] #<N> evidence_pointer carried an unvalidated Recheck probe clause — skipping do-work-recheck marker write (falling through to calendar-only)`.
   - **Zero exit** — `$PARSED` is `<verb>|<arg1>|<arg2>|<expected>`, where each field individually already passed its own regex inside the validator. Proceed to step 3.

3. **Reconstruct the canonical marker text from the validated fields only — never from the raw clause.** This is the load-bearing safety property: the text written into the issue body is built exclusively from the four pipe-delimited fields the validator itself extracted and regex-checked, not from the untrusted `evidence_pointer` substring verbatim (which could carry incidental extra whitespace or formatting the validator's tokenizer happened to tolerate but a byte-for-byte copy would preserve).

   ```bash
   IFS='|' read -r V A1 A2 EXP <<<"$PARSED"
   MARKER_LINE="<!-- do-work-recheck: $V $A1 $A2 == $EXP -->"
   ```

4. **Write it into the issue body, idempotently — mirroring step 4b's own blocked-until write.** Re-fetch the body fresh (step 4b already mutated it in a separate call; don't trust an in-memory copy across tool calls):

   ```bash
   CURRENT_BODY=$(gh issue view <N> --repo <owner/repo> --json body --jq '.body')
   if echo "$CURRENT_BODY" | grep -q '<!-- do-work-recheck:'; then
     # A marker already exists (e.g. a re-diagnosis produced an updated probe).
     # Replace it in place rather than stacking a second one. Idempotent: if
     # the clause is unchanged, this is a no-op edit.
     NEW_BODY=$(echo "$CURRENT_BODY" | sed -E "s|<!-- do-work-recheck: .+ -->|$MARKER_LINE|")
   else
     NEW_BODY="$MARKER_LINE

$CURRENT_BODY"
   fi
   if [ "$NEW_BODY" != "$CURRENT_BODY" ]; then
     gh issue edit <N> --repo <owner/repo> --body "$NEW_BODY"
   fi
   if ! gh issue view <N> --repo <owner/repo> --json body --jq '.body' | grep -q '<!-- do-work-recheck:'; then
     echo "[scope-preflight] WARNING: #<N> do-work-recheck marker did not land — falling back to calendar-only re-check"
   fi
   ```

   The read-back warning here mirrors step 4b's own — but note the asymmetry: a failed *write* is worth a WARNING (something that should have landed didn't), while an *unvalidated clause* in step 2 is not (it was never going to land — that's the correct, safe outcome for a scope agent's plausible-but-wrong guess).

## Fail-safe posture (same asymmetry as `eval-recheck-probe.sh` itself)

Every failure mode in this step degrades toward **"no marker written, calendar-only behavior unchanged"** — never toward fabricating or force-fitting a marker. A missing clause, an invalid clause, a validator that can't run (missing script, unexpected error) — all of them fall through to skip. This mirrors the read side's own `unknown`-never-`changed` posture: under-triggering here costs nothing beyond the pre-#1198 status quo (the issue stays calendar-gated); over-triggering — writing a marker that looks plausible but tests the wrong thing — would be worse, because a human skimming the issue body could mistake it for a verified, working check. When in doubt, this step does nothing.

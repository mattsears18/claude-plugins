# Bash-tool refusal triggers in an isolated session ([#1308](https://github.com/mattsears18/shipyard/issues/1308))

**The orchestrator-side counterpart to `shipyard:worker-preamble`'s [`compound-command-refusal.md`](../../skills/worker-preamble/compound-command-refusal.md) fragment.** That fragment documents this refusal class for a dispatched **worker**; the orchestrator had no equivalent, which is the direct cause of four consecutive issues ([#1182](https://github.com/mattsears18/shipyard/issues/1182) → [#1277](https://github.com/mattsears18/shipyard/issues/1277) → [#1289](https://github.com/mattsears18/shipyard/issues/1289) → [#1291](https://github.com/mattsears18/shipyard/issues/1291)) each diagnosing the trigger as a *different* wrong axis and decomposing accordingly, while the refusals kept happening.

Load this when a `Bash` call is refused with:

> This agent is isolated in the worktree `<path>`, but this command is too complex to verify that it stays inside the worktree; break it into plain, separate commands.

## The trigger, isolated

Two syntactic shapes are refused. **Neither is "the command is long" or "the command has many statements."**

| Shape | Verdict |
|---|---|
| `${VAR}` — braced parameter expansion, **anywhere** in the command | **REFUSED** |
| `$(cmd)` — command substitution in **argument** position | **REFUSED** |
| `$VAR` — unbraced parameter expansion, anywhere | allowed |
| `VAR=$(cmd)` — command substitution on the **right-hand side of an assignment** | allowed |
| literal paths, several statements, `export`s, `if`/`case`, `[ cond ] && action` | allowed |

The refusal message is generic and mentions redirects it did not observe — **do not read the message as diagnostic**. It says "too complex" for a two-token command whose only sin is a pair of braces.

## The controlled experiment

Run in a worker session isolated in `.claude/worktrees/agent-<id>`, against this repo. Every variation invokes the same script with the same argument and differs only in expansion syntax. No pipes, no loops, no redirects, no command substitution unless named.

| # | Command | Result |
|---|---|---|
| A | `export CLAUDE_PLUGIN_ROOT="<literal>"` then `"${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" get ci.settled_minutes` | REFUSED |
| B | same, but `bash "${CLAUDE_PLUGIN_ROOT}/scripts/shipyard-config.sh" …` (literal command word) | REFUSED |
| C | `<literal>/scripts/shipyard-config.sh get ci.settled_minutes` | allowed → `20` |
| D | `export SHIPYARD_REPO_ROOT="<literal>"` then the same literal-path command | allowed → `20` |
| E | `bash "$PWD/plugins/shipyard/scripts/shipyard-config.sh" get ci.settled_minutes` | allowed → `20` |
| F | `"$PWD/plugins/shipyard/scripts/shipyard-config.sh" get ci.settled_minutes` | allowed → `20` |
| G | `export SY_ROOT="<literal>"` then `"$SY_ROOT/scripts/shipyard-config.sh" get …` | allowed → `20` |
| H | same as G but `"${SY_ROOT}/scripts/shipyard-config.sh" get …` | REFUSED |
| I | `"${PWD}/plugins/shipyard/scripts/shipyard-config.sh" get …` (one statement) | REFUSED |
| J | `export SY_ARG="ci.settled_minutes"` then `<literal>/…/shipyard-config.sh get "${SY_ARG}"` | REFUSED |
| K | `export …` then `SETTLED=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/shipyard-config.sh" get …)` then `echo "settled=$SETTLED"` | allowed → `settled=20` |
| L | `bash "<literal>/scripts/assert-worktree-cwd.sh" "$(pwd)"` | REFUSED |

What each pair isolates:

- **G vs H** — identical commands, identical statement count, identical semantics, differing **only** in `$SY_ROOT` vs `${SY_ROOT}`. This is the decisive pair.
- **F vs I** — single statement, no assignment at all, preset variable. Braces alone flip the verdict.
- **A vs D** — an `export` followed by a command is fine; it is the braced *expansion* that is refused, not the export.
- **B** — putting a literal `bash` in command position does **not** rescue a braced argument. Command position is not the discriminator.
- **J** — braces are refused in a plain, non-path argument. Path-forming is not the discriminator either.
- **K vs L** — command substitution is fine as an assignment RHS (K, three statements, nested inside `$( )`) and refused as an argument (L, one statement). Statement count is not the discriminator.
- **A was re-run verbatim and refused both times** — the guard is deterministic, not a sampling artifact.

## What the four prior issues got wrong

| Issue | Diagnosed trigger | Why the refusals continued |
|---|---|---|
| #1182 | statement count | D and K pass with 2 and 3 statements |
| #1277 | compound shape (loops, pipes, `if`) | I and J are single plain commands with neither |
| #1289 | loop bodies → extract to a script | the extracted call sites were themselves written `"${CLAUDE_PLUGIN_ROOT}/scripts/<new>.sh"`, preserving the real trigger |
| #1291 | block length | C and D are the same length as A |

Each fix was locally reasonable and none touched the braces, so each shipped and the refusals persisted. #1277's decompose-or-extract guidance in [`dont.md`](./dont.md#post-relocation-bash-blocks-must-be-plain-single-purpose-commands-1277) remains correct and stays — genuine loops and pipes really are refused — it is simply **not the trigger that fires on an ordinary helper invocation**.

## The convention

**Spell every variable expansion unbraced in a templated `Bash` block.** `"$PLUGIN_ROOT/scripts/foo.sh"`, never `"${PLUGIN_ROOT}/scripts/foo.sh"`. Bash terminates an unbraced name at the first non-identifier character, so `$VAR/path`, `"$VAR"`, and `$VAR ` are all unambiguous — braces are decorative in every one of these call sites and buy nothing.

Braces are only *required* when the expansion is immediately followed by an identifier character (`${VAR}_suffix`, `${count}M`) or uses a modifier (`${VAR:-default}`, `${#arr[@]}`, `${VAR%.md}`). Those forms have no unbraced spelling, so a block that genuinely needs one **cannot** run post-relocation and must be decomposed or extracted to a script per [`dont.md`](./dont.md#post-relocation-bash-blocks-must-be-plain-single-purpose-commands-1277). This is exactly why the canonical `CLAUDE_PLUGIN_ROOT` preamble (`${CLAUDE_PLUGIN_ROOT:-…}`) is pre-relocation-only and why [step 0.5](./setup/00-config-worktree.md#05-move-into-the-orchestrators-worktree)'s `.shipyard-plugin-root` stash exists — the stash-read form is already unbraced and needs no change.

**Pass command substitution as an assignment, never as an argument.** Instead of `some-script "$(git rev-parse --show-toplevel)"`, write the assignment on its own line and pass the variable unbraced:

```bash
TOPLEVEL=$(git rev-parse --show-toplevel)
bash some-script.sh "$TOPLEVEL"
```

## Why this keeps `$CLAUDE_PLUGIN_ROOT` rather than templating a literal

[#1308](https://github.com/mattsears18/shipyard/issues/1308) proposed replacing the variable with a `<resolved-plugin-root>` placeholder the orchestrator substitutes as a literal at compose time. That is unnecessary once the real trigger is known, and strictly worse: a literal placeholder would have to be re-substituted at ~200 call sites by every reader of the spec, would differ between the dogfooding checkout and a consumer install, and would leave the spec's bash blocks unrunnable as written. De-bracing keeps one resolution point ([step 0.3](./setup/00-config-worktree.md#03-claude_plugin_root-re-export-preamble-every-bash-tool-call)'s two-layer probe), keeps both install layouts working unchanged, keeps the `.shipyard-plugin-root` stash's role intact, and is a pure syntax change.

## Regression coverage

Two gates, one per variable-scope, both required on every PR:

[`scripts/tests/claude-plugin-root-preamble.test.sh`](../../scripts/tests/claude-plugin-root-preamble.test.sh) enforces the convention for `CLAUDE_PLUGIN_ROOT` specifically — the highest-traffic case, on essentially every helper invocation:

- check (3) matches the **unbraced** spelling when verifying preamble coverage;
- check (3b) asserts a floor on the number of blocks observed, so a matcher that stops matching fails loudly instead of passing vacuously over zero blocks;
- check (3c) bans the braced spelling across every `*.md` file in the plugin.

[`scripts/brace-expansion-scan.sh`](../../scripts/brace-expansion-scan.sh) (driven by [`scripts/tests/brace-expansion-scan.test.sh`](../../scripts/tests/brace-expansion-scan.test.sh)) generalizes that to **every** variable name, per [#1311](https://github.com/mattsears18/shipyard/issues/1311). It is fence-aware rather than a plain grep: it walks ` ```bash ` blocks in every git-tracked `*.md` under `plugins/` (mechanical discovery — a new spec file is covered the day it lands) and flags the closing-brace form `${NAME}` only, so every genuinely-required modifier form stays legal without an exemption. Two deliberate behaviors are worth knowing before you hit them:

- **Quoted-heredoc bodies (`<<'EOF'`) are skipped**, because their text is emitted literally rather than expanded — de-bracing there would change what the block *writes*, not what the shell *does*. Unquoted `<<EOF` bodies do expand and are still checked.
- **Identifier-adjacent sites (`${count}MB`, `${VAR}_suffix`) ARE flagged**, even though braces are genuinely load-bearing there. That is the point: the fix is to rewrite the site so no adjacency exists — `"free=$disk_free_mb MB"` with the unit as its own word, which is what [`disk-space-guard.md`](./disk-space-guard.md) now does — not to blind-sweep the braces off (`$disk_free_mbMB` expands a different, unset name) and not to silently exempt it.

An intentional bad example inside a ` ```bash ` fence can be exempted with a `<!-- brace-expansion-scan: allow -->` line immediately before the opening fence. It scopes to exactly that one block. The experiment table above needs no marker — it is prose, not a bash fence.

[`scripts/command-substitution-scan.sh`](../../scripts/command-substitution-scan.sh) (driven by [`scripts/tests/command-substitution-scan.test.sh`](../../scripts/tests/command-substitution-scan.test.sh)) is its **sibling**, enforcing the *other* half of the trigger — `$(cmd)` in argument position — per [#1314](https://github.com/mattsears18/shipyard/issues/1314). Same fence-walking, same quoted-heredoc skip, same mechanical discovery, same anti-vacuity guards; it is a separate script rather than a check bolted into the brace scanner because the two shapes need different exemption policies, and its own `<!-- command-substitution-scan: allow -->` marker keeps exempting a block for one shape from silently exempting it for the other. Three carve-outs are load-bearing:

- **Arithmetic `$((expr))` is not command substitution** and is never flagged. `n=$((n + 1))` and `echo "$((a - b))"` stay exactly as written.
- **Assignment RHS is the sanctioned form** — `VAR=$(cmd)`, `VAR="$(cmd)"`, `export VAR=$(cmd)` and friends are never flagged. Recognition is deliberately **strict**: the `$(` must sit immediately after the `=` (through at most one opening quote), so `OUT=/tmp/run-$(date +%s)` IS flagged even though it is technically on a right-hand side. A false positive costs one hoisted line in a spec; a false negative costs a refused tool call on every dispatch that runs the block.
- **The canonical `${CLAUDE_PLUGIN_ROOT:-…}` preamble line is skipped wholesale.** It is pre-relocation-only by design (see "The convention" above) and already permanently refused via its required-modifier brace, which no amount of de-substituting fixes; it stays counted under the required-modifier residual row below rather than churning 38 identical lines for no runtime gain.

**Both sweeps are complete.** #1308 swept the 246 `CLAUDE_PLUGIN_ROOT` occurrences; #1311 swept the remaining ~86 braces across ~80 other names; #1314 swept the 97 argument-position command substitutions across 41 files. All three counts are now tree-wide zero and CI-enforced (132 files, 570 fenced bash blocks scanned clean by each scanner at #1314's fix time).

**One refused shape remains, and it is not fixable by either sweep** — it is the compound-block problem, not the expansion problem, and stays tracked under [#1277](https://github.com/mattsears18/shipyard/issues/1277)'s decompose-or-extract rule in [`dont.md`](./dont.md#post-relocation-bash-blocks-must-be-plain-single-purpose-commands-1277) plus [`compound-block-scan.sh`](../../scripts/compound-block-scan.sh)'s own (still curated, still incomplete) file list:

| Residual shape | Count in the spec tree | Why neither sweep helps |
|---|---|---|
| Required-modifier expansions (`${VAR:-default}`, `${#arr[@]}`, `${VAR%.md}`) | ~126 across 29 files | No unbraced spelling exists. The block must be decomposed (hoist the default onto its own plain line) or extracted to a script. |

A block carrying that shape stays refused post-relocation even though it now scans clean under **both** scanners — neither says anything about it, so read a clean scan as "no decorative braces and no argument-position substitutions," never as "this block will run."

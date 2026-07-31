On-demand fragment of the `shipyard:worker-preamble` skill (see [`SKILL.md`](./SKILL.md) § "Step-0 cwd fail-fast" and § "Mid-session cwd anchoring"). Load this only when `scripts/assert-worktree-cwd.sh` genuinely can't be located or run — an installed plugin predating [#826](https://github.com/mattsears18/shipyard/issues/826), the `CLAUDE_PLUGIN_ROOT` resolution coming back empty, or the resolution command itself being refused by the harness's Auto Mode classifier ([#965](https://github.com/mattsears18/shipyard/issues/965)). The common path — the script runs fine — never needs this fragment; both `SKILL.md` sections carry the primary, script-based check inline.

Both sections need the identical git-dir-vs-git-common-dir comparison; this fragment carries both call shapes (step-0's bare form and mid-session's `-C`-anchored form) once instead of duplicating the fallback prose twice in the always-loaded core.

## Step-0 form

Issue each as its **own** `Bash` tool call; do not paste them together and chain them with `&&`, a subshell, or an `if` — that compound shape is exactly what the worktree-isolation guard refuses:

```bash
git rev-parse --show-toplevel
```

```bash
git rev-parse --git-dir
```

```bash
git rev-parse --git-common-dir
```

Call the three outputs `TOPLEVEL`, `GIT_DIR`, and `COMMON_DIR` in your own reasoning — there's no shell variable to assign, since each call is independent. Compare `GIT_DIR` and `COMMON_DIR` yourself, by reading the two outputs — don't script the comparison. Same signal (git-dir == git-common-dir ⇒ primary) as the script would report, same `blocked:` wording as the primary-path branch in `SKILL.md`.

**Decomposed `CLAUDE_PLUGIN_ROOT` fallback, if the compound export was refused ([#965](https://github.com/mattsears18/shipyard/issues/965)):** reuse `TOPLEVEL` above. If `"$TOPLEVEL/plugins/shipyard/scripts"` is a directory, that's your plugin root. Otherwise run `jq -r '.plugins["shipyard@shipyard"][0].installPath // empty' "$HOME/.claude/plugins/installed_plugins.json"` as its own plain call — if the result's `scripts/` subdir exists, that's your plugin root; else fall back to `"$TOPLEVEL/plugins/shipyard"` anyway. Use the resulting literal value in place of `${CLAUDE_PLUGIN_ROOT}` everywhere downstream (mid-session anchoring, the CHANGELOG monotonicity scan, the verify_gate model resolution, issue-work §6.a's ungated-admin-direct-merge detector) instead of re-attempting the compound export.

## Mid-session form

Issue each as its own plain `Bash` call, using the literal `WORKTREE_PATH` (the value `git rev-parse --show-toplevel` returned earlier in this same dispatch) in place of `$WORKTREE_PATH` — shell variables don't survive across separate `Bash` calls:

```bash
git -C "$WORKTREE_PATH" rev-parse --git-dir
```

```bash
git -C "$WORKTREE_PATH" rev-parse --git-common-dir
```

Compare the two outputs by inspection, exactly as in the step-0 form above. If they're the same path, the anchor has drifted mid-session — return, verbatim:

> `blocked: cwd anchor drifted mid-session — my cwd is no longer the isolated worktree immediately before a mutating command (see #748). Refusing to run it against a possibly-wrong git context.`

---
name: adding-dependencies
description: Use whenever your implementation introduces a NEW dependency the repo didn't already have — a package.json/requirements.txt/pyproject.toml/go.mod/Cargo.toml/Gemfile line, a GitHub Actions `uses:` pin, a Dockerfile FROM tag, a .nvmrc/.tool-versions entry, a Gradle coordinate, a CocoaPods pod, or an inline `npx <tool>@<version>` invocation. Look up the current stable version from the authoritative registry first — never write down a version remembered from training data. Not for upgrading an existing dependency (that's Dependabot's job) and not a license to override the peer/SDK carve-out (React/React Native, @react-native-firebase/*, expo-* take the framework-required version, never "latest").
---

# Adding a NEW dependency — research the current version first

Closes the gap issue [#694](https://github.com/mattsears18/shipyard/issues/694)'s original rule left open. #694 established "install the latest stable version when introducing a new dependency," but scoped the rule to package-manager manifests only and wired it into a worker-only fragment. Neither restriction held: `mattsears18/lightwork` accumulated 30 major-version Dependabot bumps *after* #694 landed, including two 3-major GitHub Actions drags (`actions/checkout` v4→v7, `actions/upload-artifact` v4→v7) that the original rule's `package.json`-only scope never touched, because a `uses:` pin isn't a package-manager manifest and nothing told the agent to look the version up. See issue [#1045](https://github.com/mattsears18/shipyard/issues/1045) for the full repro and the measured Dependabot data.

This skill is the fix: the introduction-time-version rule, broadened past package managers and made reachable from any session — not just `/shipyard:do-work` worker dispatch. Load it whenever you're about to add a dependency, regardless of what kind of session you're in.

## When this applies

Your diff is about to introduce a dependency the repo did not already have — any of:

- A new manifest entry: `package.json`, `requirements.txt` / `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`.
- A new GitHub Actions `uses: <owner>/<action>@<ref>` pin in `.github/workflows/*.yml`.
- A new or bumped Dockerfile `FROM <image>:<tag>` base image.
- A new `.nvmrc` / `.tool-versions` entry.
- A new Gradle plugin or dependency coordinate (`build.gradle` / `build.gradle.kts`).
- A new CocoaPods pod (`Podfile`).
- An inline `npx <tool>@<version>` (or `pnpm dlx` / `yarn dlx`) invocation pinned to a specific version.

**Scope — introduction only, every ecosystem.** This rule governs *adding* a dependency, in whichever of the manifest classes above your diff touches — not upgrading one the repo already depends on. Do NOT run a repo-wide "update everything," and do NOT bump a package/action/base-image the repo already pins — that's Dependabot's (or a separate audit dimension's) job. The rule fires only when your diff adds a dependency line — in any of these manifests — that wasn't there before.

## Step 1 — look up the current stable version from the authoritative registry, before writing anything down

Do this **first**, before you install, before you write a version string anywhere. Never hand-write a version from memory or training data — training data goes stale the moment a newer release ships, and the whole point of this rule is that a dependency introduced behind starts behind and only drifts further.

"Authoritative registry" means the ecosystem's actual source of truth — the package registry, the releases API, the image registry — not a cached memory of what version was current when you last saw the package. Per ecosystem:

| Ecosystem / manifest | Lookup command | Then |
|---|---|---|
| npm / yarn / pnpm (`package.json`) | `npm view <pkg> version` | `npm install <pkg>@latest` (or `yarn add <pkg>` / `pnpm add <pkg>` — both resolve latest stable) |
| Python (`requirements.txt` / `pyproject.toml`) | `pip index versions <pkg>` (or check `https://pypi.org/pypi/<pkg>/json`) | `pip install <pkg>` (latest stable), then pin what resolved |
| Go (`go.mod`) | `go list -m -versions <pkg>` | `go get <pkg>@latest` |
| Rust (`Cargo.toml`) | `cargo search <pkg>` (or check `https://crates.io/api/v1/crates/<pkg>`) | `cargo add <pkg>` |
| Ruby (`Gemfile`) | `gem list -r -e <pkg>` (or check `https://rubygems.org/api/v1/versions/<pkg>.json`) | `bundle add <pkg>` |
| GitHub Actions `uses:` (`.github/workflows/*.yml`) | `gh api repos/<owner>/<action>/releases/latest --jq .tag_name` | Pin the `uses:` line to that tag (or the action's own major-version alias convention, e.g. `@v7`) |
| Dockerfile `FROM` base image | For a GitHub-hosted image: `gh api repos/<owner>/<image-repo>/tags --jq '.[0].name'`. For a registry-hosted image, check the image's Docker Hub (or equivalent) tags listing | Pin `FROM <image>:<tag>` to the current stable tag |
| `.nvmrc` / `.tool-versions` (a runtime/tool version pin) | `gh api repos/nodejs/node/releases/latest --jq .tag_name` (Node), or the equivalent releases feed for whichever tool is pinned | Write the resolved version into the file |
| Gradle (`build.gradle[.kts]`) | Check the plugin/dependency's Maven Central or Gradle Plugin Portal listing for the current version | Write the resolved coordinate |
| CocoaPods (`Podfile`) | `pod trunk info <pod>` (or check the pod's GitHub releases) | Write the resolved version constraint |
| Inline `npx <tool>@<version>` / `pnpm dlx` / `yarn dlx` | `npm view <tool> version` | Pin the invocation to the resolved version |

Keep `<pkg>@latest` (or the ecosystem's package-manager resolver) as the convenient shortcut where the tool does the lookup for you — npm, Go, Cargo, Bundler, and pip all resolve "latest stable" without a separate lookup step, so for those the lookup command and the install command can be the same call. The explicit lookup-first step is what the GitHub Actions / Dockerfile / `.nvmrc` / Gradle / CocoaPods / inline-`npx` classes need, because none of them has an installer that resolves "latest" on your behalf — skipping the lookup there means writing a version from memory, which is precisely the failure mode this skill exists to close.

## Step 2 — check whether the package is peer/SDK-constrained, before trusting step 1's "latest" result

### The load-bearing carve-out — peer/SDK-constrained packages use the framework-required version, NOT "latest"

"Latest on the registry" is **wrong** for a package whose version is dictated by a framework or SDK peer set. Installing `@latest` for such a package is exactly what produced the #694 native crash. Before choosing a version for a new dependency, **check whether it is peer/SDK-constrained** and, if it is, use the version the framework requires instead:

- **React / React Native:** `react` must equal the version `react-native` (or the installed Expo SDK) bundles — a `react` ≠ `react-native-renderer` skew is a native crash on launch, not a warning. `react-dom` follows `react`.
- **`@react-native-firebase/*`:** every `@react-native-firebase/<module>` must share **one** version, matched to the RN version — bumping one at a time (as Dependabot does) breaks the coordinated peer set into an un-mergeable `ERESOLVE`.
- **`expo-*` / many `react-native-*`:** the installed **Expo SDK** pins these, not "latest on npm".

**Detect the constraint before installing:** inspect the target package's `peerDependencies` (`npm view <pkg> peerDependencies`) against what's already installed, and treat a package that peer-depends on `react` / `react-native` / `expo` — or that shares a scope with a coordinated set already in the tree (`@react-native-firebase/*`) — as framework-constrained.

**For Expo repos, prefer the framework-aligned installer.** `npx expo install <pkg>` resolves the SDK-correct version for the installed Expo SDK instead of the registry's latest, so it is the correct default on any repo with `expo` in its dependency tree. Use it in place of `npm install <pkg>@latest` there; fall back to `npm install <pkg>@latest` only for packages Expo doesn't manage.

When you install a framework-required (non-latest) version because of this carve-out, **say so in the PR body** — name the constraint (e.g. `Installed \`react@19.1.0\` to match the Expo SDK 53 peer set, not latest.`) so the non-latest choice reads as deliberate, not stale.

## Step 3 — record the resolved version in the PR body

**Record the resolved version in the PR body.** State the exact version each newly-added dependency resolved to (e.g. `Added \`zod@3.24.1\` (latest stable).`) so a reviewer can see — without checking out the branch — that the dep started current and confirm the peer/SDK carve-out above was applied when it was. Do the same for a non-`package.json` introduction: `Pinned actions/checkout to v7.0.1 (latest release).`

### Supply-chain-cooldown interaction

A repo that sets a supply-chain cooldown (e.g. an `.npmrc` with `min-release-age=7`, mirroring a `dependabot.yml` `cooldown.default-days: 7`) will have `@latest` — or the equivalent registry lookup — resolve to the latest **eligible** version, not the newest published one. That's correct and intended: the cooldown exists to let a freshly-published release accumulate a few days of real-world signal before anything in the repo depends on it. It's exactly why step 3's "record the resolved version" matters — without it, a reviewer can't tell a cooldown-trimmed pin (expected, current-as-of-eligibility) from a genuinely stale one (introduction-time debt). State the resolved version either way; if it looks older than "latest" because of a cooldown, that's worth a one-line note too.

## Step 4 — run the automated pre-PR-create check

Closes the verification gap issue [#1046](https://github.com/mattsears18/shipyard/issues/1046) left after [#1045](https://github.com/mattsears18/shipyard/issues/1045) shipped this skill: steps 1–3 above are a rule plus a PR-body convention — nothing verified the claim, so a worker that silently wrote a stale/remembered version produced a PR indistinguishable from a compliant one.

**Before `gh pr create`, run `plugins/shipyard/scripts/verify-new-dep-versions.sh`** against your diff. It re-parses the same diff for newly-added dependency lines and cross-checks the version you wrote in step 1 against the authoritative registry — a mechanical backstop for the lookup-first rule above, not a replacement for actually doing the lookup:

```bash
bash plugins/shipyard/scripts/verify-new-dep-versions.sh "origin/$DEFAULT_BRANCH" --pr-body-file "$WORKTREE_PATH/.shipyard-scratch/pr-body.md"
```

Pass the same scratch PR-body file `issue-work.md` step 5 already writes before `gh pr create` — the script reads it for two things: the offline fallback (below) and the cooldown/carve-out-note explanation for an otherwise-unexplained gap.

**Two ecosystems get a hard, online, registry-comparison check** — npm/npx (`package.json` entries, inline `npx <tool>@<version>` / `pnpm dlx` / `yarn dlx` invocations) via `npm view <pkg> version`, and GitHub Actions `uses:` pins via `gh api repos/<owner>/<action>/releases/latest`. A newly-added dependency in either class that's ≥1 major behind the registry's current stable, with no peer/SDK carve-out and no PR-body explanation, is a hard failure (exit 1) — fix the version (or add the explanation) before opening the PR.

**Every other manifest class this skill names — pip, Go, Cargo, Gemfile, Gradle, CocoaPods, Dockerfile `FROM`, `.nvmrc`/`.tool-versions` — falls back to the OFFLINE check**, as does the npm/Actions path itself when the `npm`/`gh` CLI or network isn't available: does the PR body record a resolved version for that dependency, per step 3? That fallback only skip-with-notes; it never hard-fails. Registry comparison for those remaining ecosystems is phase 2, tracked as a follow-up from #1046.

The check honors the peer/SDK carve-out (react, react-native, `@react-native-firebase/*`, `expo-*`) and a cooldown/carve-out note in the PR body as valid explanations for an otherwise-unexplained gap — the same two escape hatches steps 2 and the cooldown section above already document.

## Policy knob + scope

This latest-stable default is configurable per-repo via `dependencies.new_dep_version` in `shipyard.config.json` (default `"latest-stable"`; set `"conservative"` for a repo that wants introductions pinned to a documented older baseline — e.g. a repo deliberately trailing the ecosystem). The peer/SDK carve-out is **unconditional** and is NOT disabled by `"conservative"` — a framework-constrained package always uses the framework-required version regardless of this knob, because installing an SDK-mismatched version is a correctness bug, not a policy preference.

**Scope — introduction only.** This rule governs *adding* a dependency, not upgrading existing ones. Do NOT run a repo-wide "update everything", and do NOT bump a package the repo already depends on — that's Dependabot's / a separate audit dimension's job. The rule fires only when your diff adds a dependency line that wasn't there before.

## Out of scope for this skill (filed as follow-ups)

This skill covers the *rule* (steps 1–3) and the mechanical pre-PR-create verification of it (step 4). It deliberately does not include:

- Registry-comparison (rather than the step-4 offline PR-body-record check) for pip, Go, Cargo, Gemfile, Gradle, CocoaPods, Dockerfile `FROM`, and `.nvmrc`/`.tool-versions` — filed as a follow-up from [#1046](https://github.com/mattsears18/shipyard/issues/1046).

See issue [#1045](https://github.com/mattsears18/shipyard/issues/1045) for the follow-up issues tracking each of these.

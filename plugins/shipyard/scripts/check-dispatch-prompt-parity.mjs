#!/usr/bin/env node
/*
 * check-dispatch-prompt-parity.mjs — assert dispatch-rules.md's reviewable
 * per-mode dispatch-prompt templates and do-work-dispatch.workflow.js's
 * `build<Mode>Prompt` builders haven't silently drifted apart.
 * ==========================================================================
 *
 * WHY THIS EXISTS (issue #880)
 * ----------------------------
 * Every `mode:`-driven `/shipyard:do-work` worker's dispatch prompt exists in
 * TWO hand-maintained copies:
 *
 *   - The reviewable PROSE TEMPLATE in `commands/do-work/dispatch-rules.md`
 *     — passed VERBATIM as the `Agent` tool's `prompt` parameter under the
 *     default Agent-tool dispatch shape (#825).
 *   - The EXECUTING BUILDER in `workflows/do-work-dispatch.workflow.js`
 *     (`buildIssueWorkPrompt` / `buildSpikePrompt` / etc.) — assembles the
 *     equivalent prompt from the same augmentation fields under the
 *     alternate Workflow-substrate dispatch shape.
 *
 * The two are NOT byte-identical by design — the Workflow-substrate builders
 * additionally inject a worktree-anchor block (no isolation primitive exists
 * on that substrate, see the workflow.js header) and a structured
 * `schemas/worker-return.schema.json`-shaped return contract (vs. the
 * Agent-tool shape's free-text terminal string) — so full de-duplication via
 * a mechanical byte-diff is wrong, and (per #856's finding, reused here)
 * `require`/`import`-based de-duplication is impossible: the Workflow
 * runtime executes this script with no filesystem access of its own.
 *
 * What CAN silently drift, with nothing catching it before this checker:
 *   - A mode added to one file's routing but not the other.
 *   - A mode's `agents/issue-worker/<mode>.md` spec-file reference renamed
 *     in one copy but not the other.
 *   - A conditional augmentation paragraph (verify-gate / user-feedback /
 *     phase-1-slice / next-available-version) added, removed, or its
 *     distinctive header text changed in one copy but not the other.
 *   - `buildIssueWorkPrompt` regressing back to inlining its own duplicate
 *     worktree-anchor CALLER-BUG copy instead of delegating to the shared
 *     `worktreeAnchorLines` helper the other six builders use (the "Internal
 *     dup" evidence #880 cited).
 *
 * WHAT IT DOES
 * ------------
 * Mechanical, dependency-free (no eval/new Function, matching the convention
 * `check-workflow-meta-literal.mjs` and `check-worker-return-schema-parity.mjs`
 * already use):
 *
 *   1. Mode-inventory parity — the set of `` `mode: <name>` `` blockquote
 *      templates in dispatch-rules.md must equal the set of `case '<name>':`
 *      branches in workflow.js's `buildWorkerPrompt` switch.
 *   2. Per-mode spec-file parity — for every mode present in both, dispatch-
 *      rules.md's blockquote and the mode's `build<Mode>Prompt` function body
 *      must both reference the same `agents/issue-worker/<mode>.md` path.
 *   3. Augmentation-anchor parity — for each (anchor phrase, applicable mode)
 *      pair in a static table below, the anchor phrase must appear in BOTH
 *      dispatch-rules.md and the applicable mode's builder function body.
 *   4. Worktree-anchor dedup — every mode's builder function body must call
 *      the shared `worktreeAnchorLines(unit, '<mode>')` helper rather than
 *      inlining its own separate "no worktreePath" CALLER-BUG copy.
 *
 * This is a lighter-weight technique than `check-worker-return-schema-parity
 * .mjs`'s full recursive-descent parse — the two sources here are free-form
 * prose (a markdown blockquote, a JS template-literal array), not a single
 * structured JSON-Schema-shaped object literal, so there is no formal grammar
 * to parse both sides into and diff field-for-field. Anchor-substring
 * presence inside a mechanically-extracted function body is the right level
 * of rigor: it catches every drift shape #880 evidenced without being brittle
 * to legitimate prose rewording that doesn't change the underlying meaning.
 *
 * USAGE
 *   node check-dispatch-prompt-parity.mjs <dispatch-rules.md> <workflow.js>
 *
 * EXIT CODES
 *   0  no drift found
 *   1  a drift was found (diagnostics on stdout)
 *   2  usage error / unreadable file / a mode's builder body couldn't be
 *      mechanically located
 *
 * Consumed by scripts/tests/dispatch-prompt-parity-880.test.sh, which also
 * runs it against fixtures reproducing each drift shape above to prove the
 * checker actually fails on them.
 */

import { readFileSync } from 'node:fs'

// --------------------------------------------------------------------------
// Static tables — the known augmentation anchors and which builder(s) they
// apply to. Keep in sync with dispatch-rules.md's "Verify-gate augmentation" /
// "If the issue carries the user-feedback label" / "Phase-1 slice
// augmentation" / next-available-version paragraphs and workflow.js's
// `buildIssueWorkPrompt` / `buildSpikePrompt`.
// --------------------------------------------------------------------------
const AUGMENTATION_ANCHORS = [
  { anchor: 'Verify gate:', modes: ['issue-work'] },
  { anchor: 'This issue originated from end-user feedback', modes: ['issue-work'] },
  { anchor: 'the refinement step may have misread the user', modes: ['issue-work'] },
  { anchor: 'Phase-1 slice (scope-agent-supplied):', modes: ['issue-work'] },
  { anchor: 'Next-available version (orchestrator-supplied):', modes: ['issue-work', 'spike'] },
]

// --------------------------------------------------------------------------
// dispatch-rules.md extraction
// --------------------------------------------------------------------------

/**
 * Every `> **`mode: <name>`** — ...` blockquote line, keyed by mode name.
 * Each template is a single markdown paragraph (one logical blockquote,
 * possibly line-wrapped by the markdown renderer but authored as one
 * `>`-prefixed line in the source), so a per-line regex is sufficient — no
 * multi-line blockquote parsing needed.
 */
function extractMdModeTemplates(mdSrc) {
  const templates = {}
  const re = /^ *> \*\*`mode: ([a-z-]+)`\*\*.*$/gm
  let m
  while ((m = re.exec(mdSrc))) {
    templates[m[1]] = m[0]
  }
  return templates
}

// --------------------------------------------------------------------------
// workflow.js extraction
// --------------------------------------------------------------------------

/** mode -> builder function name, read straight from `buildWorkerPrompt`'s switch. */
function extractModeToBuilderMap(jsSrc) {
  const switchStart = jsSrc.indexOf('function buildWorkerPrompt(')
  if (switchStart === -1) return { ok: false, error: '`function buildWorkerPrompt(` not found' }
  const switchEnd = jsSrc.indexOf('\n}', switchStart)
  const switchBody = jsSrc.slice(switchStart, switchEnd === -1 ? undefined : switchEnd)

  const map = {}
  const re = /case '([a-z-]+)':\s*\n\s*return (build\w+)\(/g
  let m
  while ((m = re.exec(switchBody))) {
    map[m[1]] = m[2]
  }
  return { ok: true, map }
}

/**
 * Extract a named `function <name>(...) { ... }`'s full source text by
 * brace-balance scanning from the opening `{` to its matching close. Safe
 * against `${...}` template-literal interpolations and `{ "mode": ... }`
 * JSON-example strings inside the function body because every brace
 * character in well-formed JS source — including ones inside backtick
 * strings — is still balanced overall; we're not trying to distinguish
 * "real" braces from string-embedded ones, just find where the function
 * that opened at the given index closes.
 */
function extractFunctionBody(jsSrc, fnName) {
  const declRe = new RegExp(`function ${fnName}\\([^)]*\\)\\s*\\{`)
  const declMatch = declRe.exec(jsSrc)
  if (!declMatch) return { ok: false, error: `\`function ${fnName}(...)\` not found` }

  const bodyStart = declMatch.index
  let depth = 0
  let i = bodyStart
  for (; i < jsSrc.length; i++) {
    const ch = jsSrc[i]
    if (ch === '{') depth++
    else if (ch === '}') {
      depth--
      if (depth === 0) { i++; break }
    }
  }
  if (depth !== 0) return { ok: false, error: `unbalanced braces scanning \`${fnName}\` from index ${bodyStart}` }

  return { ok: true, body: jsSrc.slice(bodyStart, i) }
}

/**
 * Render a function body's backtick template-literal STRING CONTENTS as
 * flowing prose — the way a worker actually reads them once `.join('\n')`'d
 * into markdown and soft-wrapped, so an augmentation-anchor phrase the
 * SOURCE cosmetically line-wraps across two consecutive template-literal
 * array elements (a ~80-col wrap for readability, not a semantic paragraph
 * break) is still found as one continuous phrase when diffed against
 * dispatch-rules.md's single-paragraph markdown. Each backtick-quoted
 * segment in source order is joined with a SPACE (not '\n' — a bare '\n'
 * inside one markdown paragraph is a soft line break that renders as a
 * space, and collapsing to a space here is what lets a mid-sentence anchor
 * phrase span a source line-wrap without a spurious newline splitting it).
 * Runs of whitespace are then collapsed to one space. `+`-concatenated
 * segments (used only in the worktree-anchor CALLER-BUG guard text, which no
 * augmentation anchor lives inside) get the same space-joining treatment,
 * which is harmless there too. This function is never used for CHECK 4's
 * JS-syntax (not prose) delegation check.
 */
function renderTemplateLiteralText(body) {
  const segments = []
  const re = /`((?:[^`\\]|\\.)*)`/g
  let m
  while ((m = re.exec(body))) {
    segments.push(m[1].replace(/\\`/g, '`').replace(/\\\\/g, '\\'))
  }
  return segments.join(' ').replace(/\s+/g, ' ')
}

// --------------------------------------------------------------------------
// Comparison
// --------------------------------------------------------------------------

/** Returns { ok, diffs[] } comparing dispatch-rules.md against workflow.js. */
export function diffDispatchPrompts(mdSrc, jsSrc) {
  const diffs = []

  const mdTemplates = extractMdModeTemplates(mdSrc)
  const mdModes = new Set(Object.keys(mdTemplates))

  const builderMapResult = extractModeToBuilderMap(jsSrc)
  if (!builderMapResult.ok) return { ok: false, diffs: [builderMapResult.error] }
  const jsModes = new Set(Object.keys(builderMapResult.map))

  // CHECK 1 — mode-inventory parity.
  for (const mode of mdModes) {
    if (!jsModes.has(mode)) {
      diffs.push(`mode "${mode}": has a dispatch-rules.md template but no case in buildWorkerPrompt's switch`)
    }
  }
  for (const mode of jsModes) {
    if (!mdModes.has(mode)) {
      diffs.push(`mode "${mode}": has a buildWorkerPrompt case but no dispatch-rules.md template`)
    }
  }

  // Only compare modes present on both sides from here on — the inventory
  // mismatches above already flagged anything one-sided.
  const sharedModes = [...mdModes].filter((m) => jsModes.has(m)).sort()

  // Extract each shared mode's builder function body up front so later
  // checks don't re-scan the file per anchor. Keep both the raw source
  // (CHECK 4 needs actual JS call syntax) and the rendered prose (CHECK 2/3
  // need the text as a worker would actually read it, immune to cosmetic
  // source line-wrapping — see renderTemplateLiteralText's doc comment).
  const builderBodies = {}
  const builderRendered = {}
  for (const mode of sharedModes) {
    const fnName = builderMapResult.map[mode]
    const extracted = extractFunctionBody(jsSrc, fnName)
    if (!extracted.ok) {
      diffs.push(`mode "${mode}": could not extract \`${fnName}\`'s body — ${extracted.error}`)
      continue
    }
    builderBodies[mode] = extracted.body
    builderRendered[mode] = renderTemplateLiteralText(extracted.body)
  }

  // CHECK 2 — per-mode spec-file parity.
  for (const mode of sharedModes) {
    if (!(mode in builderRendered)) continue
    const specPath = `agents/issue-worker/${mode}.md`
    const mdHasSpec = mdTemplates[mode].includes(specPath)
    const jsHasSpec = builderRendered[mode].includes(specPath)
    if (!mdHasSpec && !jsHasSpec) {
      diffs.push(`mode "${mode}": neither dispatch-rules.md's template nor \`${builderMapResult.map[mode]}\` references "${specPath}"`)
    } else if (!mdHasSpec) {
      diffs.push(`mode "${mode}": \`${builderMapResult.map[mode]}\` references "${specPath}" but dispatch-rules.md's template does not`)
    } else if (!jsHasSpec) {
      diffs.push(`mode "${mode}": dispatch-rules.md's template references "${specPath}" but \`${builderMapResult.map[mode]}\` does not`)
    }
  }

  // CHECK 3 — augmentation-anchor parity.
  for (const { anchor, modes } of AUGMENTATION_ANCHORS) {
    const mdHasAnchor = mdSrc.includes(anchor)
    for (const mode of modes) {
      if (!sharedModes.includes(mode) || !(mode in builderRendered)) continue
      const jsHasAnchor = builderRendered[mode].includes(anchor)
      if (!mdHasAnchor && !jsHasAnchor) {
        diffs.push(`augmentation "${anchor}" (mode "${mode}"): missing from BOTH dispatch-rules.md and \`${builderMapResult.map[mode]}\``)
      } else if (!mdHasAnchor) {
        diffs.push(`augmentation "${anchor}" (mode "${mode}"): present in \`${builderMapResult.map[mode]}\` but missing from dispatch-rules.md`)
      } else if (!jsHasAnchor) {
        diffs.push(`augmentation "${anchor}" (mode "${mode}"): present in dispatch-rules.md but missing from \`${builderMapResult.map[mode]}\``)
      }
    }
  }

  // CHECK 4 — worktree-anchor dedup: every builder must delegate to the
  // shared `worktreeAnchorLines(unit, '<mode>')` helper rather than inlining
  // its own separate "no worktreePath" CALLER-BUG copy.
  for (const mode of sharedModes) {
    if (!(mode in builderBodies)) continue
    const delegates = builderBodies[mode].includes(`worktreeAnchorLines(unit, '${mode}')`)
    if (!delegates) {
      diffs.push(
        `mode "${mode}": \`${builderMapResult.map[mode]}\` does not call worktreeAnchorLines(unit, '${mode}') — ` +
          `it may be inlining its own duplicate worktree-anchor CALLER-BUG copy (the #880 "Internal dup" regression shape)`,
      )
    }
  }

  return { ok: diffs.length === 0, diffs }
}

// --------------------------------------------------------------------------
// CLI
// --------------------------------------------------------------------------
const isMain = process.argv[1] && import.meta.url === `file://${process.argv[1]}`
if (isMain) {
  const [mdPath, jsPath] = process.argv.slice(2)

  if (!mdPath || !jsPath) {
    console.error('usage: check-dispatch-prompt-parity.mjs <dispatch-rules.md> <workflow.js>')
    process.exit(2)
  }

  let mdSrc, jsSrc
  try {
    mdSrc = readFileSync(mdPath, 'utf8')
  } catch (err) {
    console.error(`error: cannot read ${mdPath}: ${err.message}`)
    process.exit(2)
  }
  try {
    jsSrc = readFileSync(jsPath, 'utf8')
  } catch (err) {
    console.error(`error: cannot read ${jsPath}: ${err.message}`)
    process.exit(2)
  }

  const { ok, diffs } = diffDispatchPrompts(mdSrc, jsSrc)
  if (ok) {
    console.log(`OK    ${jsPath}'s per-mode prompt builders match ${mdPath}'s templates on every checked facet`)
    process.exit(0)
  }

  console.log(`FAIL  ${jsPath} has drifted from ${mdPath}:`)
  for (const d of diffs) console.log(`        ${d}`)
  process.exit(1)
}

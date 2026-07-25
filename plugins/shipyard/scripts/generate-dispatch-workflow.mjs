#!/usr/bin/env node
/*
 * generate-dispatch-workflow.mjs — regenerate
 * workflows/do-work-dispatch.workflow.js from its source-of-truth fragments.
 * ==========================================================================
 *
 * WHY THIS EXISTS (issue #958)
 * -----------------------------
 * `do-work-dispatch.workflow.js` is the single flat literal the Dynamic
 * Workflows runtime executes — it has no filesystem access of its own, so it
 * cannot `import`/`require` anything at runtime (the same constraint that
 * already forces `workerReturnSchema` to be a hand-maintained literal copy
 * of `schemas/worker-return.schema.json` rather than an import). Before
 * #958, that constraint meant the seven `build<Mode>Prompt` worker-dispatch-
 * prompt template functions (~469 lines, none of it orchestration logic) had
 * to live inline in the same file as the actual dispatch-loop logic
 * (`meta`, `args` handling, select/dispatch/collect), making the file harder
 * to read/maintain than its real orchestration-logic size (~500 lines)
 * warranted.
 *
 * This script reconciles "split for editability" with "flat for runtime
 * execution": it reads
 *   - `workflows/do-work-dispatch.core.js` — the orchestration logic, and
 *   - `workflows/prompt-templates/*.mjs` — the per-mode builders and their
 *     shared worktree-anchor helpers, each a small, independently-editable,
 *     `node --check`-able ES module,
 * strips the template modules' `import`/`export` syntax (meaningless once
 * everything lands in one scope), and concatenates the result into
 * `workflows/do-work-dispatch.workflow.js`, which stays checked into git as
 * the generated artifact — exactly the approach issue #958 itself suggested
 * ("a build step that generates this file's template literals from a single
 * source of truth, checked into git as the generated artifact so the
 * sandboxed runtime still only ever sees a flat literal").
 *
 * WHAT IT DOES NOT DO
 * -------------------
 * It does NOT attempt to de-duplicate these templates against
 * `commands/do-work/dispatch-rules.md`'s own reviewable prose templates for
 * the same modes. Those two forms are deliberately NOT byte-identical (see
 * `check-dispatch-prompt-parity.mjs`'s header for the full rationale — the
 * Workflow-substrate builders additionally need a worktree-anchor preamble
 * and a structured-return-contract closing that dispatch-rules.md's
 * Agent-tool prose doesn't), so unifying them into one generated source
 * would either lose that structural difference or require the generator to
 * re-implement per-substrate rendering logic — a materially larger, riskier
 * change than the mechanical file-organization problem this issue actually
 * reported. `check-dispatch-prompt-parity.mjs` remains the mechanism that
 * keeps the two representations in sync; this script is unrelated to it and
 * runs against a completely different pair of inputs.
 *
 * USAGE
 *   node generate-dispatch-workflow.mjs           # regenerate in place
 *   node generate-dispatch-workflow.mjs --check    # verify, don't write (CI)
 *
 * EXIT CODES
 *   0  wrote (or, under --check, confirmed) an up-to-date workflow.js
 *   1  --check found the checked-in file has drifted from the sources
 *   2  usage / unreadable source error
 *
 * Consumed by scripts/tests/dispatch-workflow-generated-958.test.sh, which
 * runs `--check` against the real repo files and also exercises the
 * concatenation logic against small fixture fragments so a regression in the
 * strip/join logic itself is caught, not just a stale checked-in file.
 */

import { readFileSync, writeFileSync, existsSync, realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

// Order matches the pre-#958 file's original layout: the shared
// worktree-anchor helpers first (every builder depends on them), then the
// six non-issue-work builders in their original order, then issue-work last
// — preserved purely to keep the generated file's diff-vs-history minimal,
// not because order is semantically load-bearing.
const TEMPLATE_FILES = [
  'shared.mjs',
  'fix-checks-only.mjs',
  'fix-rebase.mjs',
  'fix-main-ci.mjs',
  'fix-failing-prs-batch.mjs',
  'investigate.mjs',
  'spike.mjs',
  'issue-work.mjs',
]

/**
 * Strip a template module's `import { ... } from './shared.mjs'` line(s) and
 * the leading `export ` off any `export function ...` declaration — both are
 * meaningless (and, for `import`, a hard runtime error) once every fragment
 * lands in the same top-level scope as `do-work-dispatch.core.js`. A plain
 * line-based transform is sufficient here: template modules are authored in
 * the same restricted shape (a header comment, at most one `import` line,
 * then one or more `export function` declarations) rather than arbitrary JS,
 * so there's no risk of an `import`/`export` keyword appearing inside string
 * content that this would mis-strip.
 */
export function stripModuleSyntax(src) {
  return src
    .split('\n')
    .filter((line) => !/^import\s+\{[^}]*\}\s+from\s+['"]\.\/[\w-]+\.mjs['"];?\s*$/.test(line))
    .map((line) => (line.startsWith('export function ') ? line.slice('export '.length) : line))
    .join('\n')
}

/** Trim leading/trailing blank lines a fragment may carry at its seams. */
function trimBlankEdges(text) {
  return text.replace(/^\n+/, '').replace(/\n+$/, '')
}

/**
 * Build the generated file's full text from the core fragment + the
 * template modules, in the fixed order above. Exported (not just used by the
 * CLI section below) so the regression test can exercise it directly
 * against small fixture directories without shelling out.
 */
export function generate({ workflowsDir }) {
  const templatesDir = path.join(workflowsDir, 'prompt-templates')
  const corePath = path.join(workflowsDir, 'do-work-dispatch.core.js')

  const core = trimBlankEdges(readFileSync(corePath, 'utf8'))
  const sections = TEMPLATE_FILES.map((f) =>
    trimBlankEdges(stripModuleSyntax(readFileSync(path.join(templatesDir, f), 'utf8'))),
  )

  return [core, ...sections].join('\n\n') + '\n'
}

// --------------------------------------------------------------------------
// CLI
// --------------------------------------------------------------------------
// Compare REALPATHs, not raw strings — a naive string compare silently
// no-ops when invoked via a symlinked path (issue #933's lesson, applied to
// every isMain check added since).
function resolvesToThisFile() {
  if (!process.argv[1]) return false
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])
  } catch {
    return false
  }
}
const isMain = resolvesToThisFile()
if (isMain) {
  const here = path.dirname(fileURLToPath(import.meta.url))
  const workflowsDir = path.resolve(here, '..', 'workflows')
  const outPath = path.join(workflowsDir, 'do-work-dispatch.workflow.js')
  const checkOnly = process.argv.includes('--check')

  let output
  try {
    output = generate({ workflowsDir })
  } catch (err) {
    console.error(`error: could not generate do-work-dispatch.workflow.js: ${err.message}`)
    process.exit(2)
  }

  if (checkOnly) {
    const current = existsSync(outPath) ? readFileSync(outPath, 'utf8') : null
    if (current !== output) {
      console.log(
        `FAIL  ${outPath} is out of date with do-work-dispatch.core.js + prompt-templates/*.mjs. ` +
          `Run: node plugins/shipyard/scripts/generate-dispatch-workflow.mjs`,
      )
      process.exit(1)
    }
    console.log(`OK    ${outPath} matches its generated source (core.js + prompt-templates/*.mjs)`)
    process.exit(0)
  }

  writeFileSync(outPath, output)
  console.log(`wrote ${outPath}`)
  process.exit(0)
}

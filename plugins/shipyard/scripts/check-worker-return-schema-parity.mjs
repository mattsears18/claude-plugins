#!/usr/bin/env node
/*
 * check-worker-return-schema-parity.mjs — assert the hand-copied
 * `workerReturnSchema` literal inside a Dynamic Workflows script matches the
 * canonical `schemas/worker-return.schema.json` on every validation-relevant
 * facet.
 * ==========================================================================
 *
 * WHY THIS EXISTS (issue #856)
 * ----------------------------
 * `schemas/worker-return.schema.json` is the canonical, schema-validated
 * contract every `mode:`-driven `/shipyard:do-work` worker must return. The
 * `Workflow` runtime that dispatches those workers executes
 * `do-work-dispatch.workflow.js` in an isolated environment with no
 * filesystem access of its own, so it cannot `require`/`import` the JSON
 * file — it carries a literal hand-copied duplicate (`workerReturnSchema`)
 * instead. That copy's own comment used to say "review both files together
 * on any return-contract change," and nothing enforced that: the copy
 * drifted from the canonical schema in two ways before #856 fixed them —
 * the `allOf` conditional-required block (blocked outcomes must carry
 * `blocked_reason`; disposition outcomes must carry `disposition`) was
 * missing entirely, and `issue`/`pr` were missing `minimum: 1`. Both
 * omissions made the workflow's embedded validator silently ACCEPT
 * malformed returns the canonical schema would reject — exactly the
 * "fail loudly at the stage boundary" guarantee the schema-validation layer
 * exists to provide.
 *
 * WHAT IT DOES
 * ------------
 * Loads the canonical JSON schema with `JSON.parse`, locates
 * `const workerReturnSchema = { ... }` in the `.js` file and parses ONLY
 * that object literal with a small hand-rolled recursive-descent parser
 * (grammar below) — deliberately NOT `eval`/`new Function`, so this checker
 * never executes code extracted from the file it's checking, even though
 * that file is repo-owned/trusted content, not untrusted input. It then
 * normalizes both into a comparable shape and diffs:
 *
 *   - top-level `required` (set) and `additionalProperties`
 *   - per-property `type` (set) / `enum` (set) / `minimum`, for every
 *     property named in the CANONICAL schema (and flags any property the
 *     `.js` copy has that the canonical schema doesn't, or vice versa)
 *   - `allOf` conditional-required rules (each `if.properties.outcome.const`
 *     → `then.required`), order-independent
 *
 * `description` text is deliberately EXCLUDED from the comparison — the
 * `.js` copy omits descriptions entirely (they carry no validation weight),
 * so requiring them to match would make this checker fail on a difference
 * that was never a real drift.
 *
 * PARSER GRAMMAR (same literal-only shape as check-workflow-meta-literal.mjs,
 * extended to accept arbitrary nesting since a JSON-Schema object nests
 * deeper than `meta` ever does):
 *
 *   value    := StringLiteral | NumericLiteral | 'true' | 'false' | 'null'
 *             | ObjectLiteral | ArrayLiteral
 *   Object   := '{' ( Property ( ',' Property )* ','? )? '}'
 *   Property := ( Identifier | StringLiteral ) ':' value
 *   Array    := '[' ( value ( ',' value )* ','? )? ']'
 *
 * Deliberately dependency-free: no ajv, no acorn — same "no extra deps for
 * one object" posture as check-workflow-meta-literal.mjs.
 *
 * USAGE
 *   node check-worker-return-schema-parity.mjs <schema.json> <workflow.js> [--var NAME]
 *
 *   --var NAME   name of the const object to extract from the JS file
 *                (default: workerReturnSchema)
 *
 * EXIT CODES
 *   0  the two schemas match on every validation-relevant facet
 *   1  a drift was found (diagnostics on stdout)
 *   2  usage error / unreadable file / unparsable literal
 *
 * Consumed by scripts/tests/worker-return-schema-parity-856.test.sh, which
 * also runs it against a fixture reproducing the exact #856 regression (a
 * `.js` copy missing `allOf` and `minimum: 1`) to prove the checker actually
 * fails on it.
 */

import { readFileSync, realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const PUNCT = new Set(['{', '}', '[', ']', ':', ','])
const KEYWORD_LITERALS = { true: true, false: false, null: null }

function makeLexer(src, startPos) {
  let pos = startPos

  function lineOf(p) {
    let line = 1
    for (let i = 0; i < p && i < src.length; i++) if (src[i] === '\n') line++
    return line
  }

  function skipTrivia() {
    for (;;) {
      while (pos < src.length && /\s/.test(src[pos])) pos++
      if (src.startsWith('//', pos)) {
        const nl = src.indexOf('\n', pos)
        pos = nl === -1 ? src.length : nl + 1
        continue
      }
      if (src.startsWith('/*', pos)) {
        const end = src.indexOf('*/', pos + 2)
        pos = end === -1 ? src.length : end + 2
        continue
      }
      break
    }
  }

  function readString(quote) {
    const at = pos
    pos++ // opening quote
    let out = ''
    while (pos < src.length) {
      const ch = src[pos]
      if (ch === '\\') {
        // Simple escape handling — sufficient for the identifier/enum-value
        // strings this literal actually contains (no \u, no real newlines).
        const next = src[pos + 1]
        const map = { n: '\n', t: '\t', "'": "'", '"': '"', '\\': '\\' }
        out += map[next] ?? next ?? ''
        pos += 2
        continue
      }
      if (ch === quote) {
        pos++
        return { type: 'string', value: out, pos: at, line: lineOf(at) }
      }
      if (ch === '\n') break // unterminated single-line string
      out += ch
      pos++
    }
    return { type: 'bad', value: 'unterminated string', pos: at, line: lineOf(at) }
  }

  function next() {
    skipTrivia()
    if (pos >= src.length) return { type: 'eof', value: '', pos, line: lineOf(pos) }
    const at = pos
    const ch = src[pos]
    const line = lineOf(at)

    if (ch === "'" || ch === '"') return readString(ch)
    if (PUNCT.has(ch)) { pos++; return { type: 'punct', value: ch, pos: at, line } }

    if (/[0-9]/.test(ch) || (ch === '-' && /[0-9]/.test(src[pos + 1] ?? ''))) {
      let out = ch
      pos++
      while (pos < src.length && /[0-9.eE+-]/.test(src[pos])) { out += src[pos]; pos++ }
      return { type: 'number', value: out, pos: at, line }
    }

    if (/[A-Za-z_$]/.test(ch)) {
      let out = ''
      while (pos < src.length && /[A-Za-z0-9_$]/.test(src[pos])) { out += src[pos]; pos++ }
      return { type: 'ident', value: out, pos: at, line }
    }

    pos++
    return { type: 'op', value: ch, pos: at, line }
  }

  return { next, lineOf }
}

class ParseError extends Error {
  constructor(line, detail) {
    super(`line ${line}: ${detail}`)
    this.line = line
  }
}

function parseValue(lex) {
  return parseValueFromToken(lex, lex.next())
}

function parseArray(lex) {
  const items = []
  for (;;) {
    // Consume the next token directly (rather than calling parseValue, which
    // would re-consume) so `]` — an empty array or a trailing comma — can be
    // detected without a lookahead/backtrack API.
    const tok = lex.next()
    if (tok.type === 'punct' && tok.value === ']') return items
    items.push(parseValueFromToken(lex, tok))

    const sep = lex.next()
    if (sep.type === 'punct' && sep.value === ',') continue
    if (sep.type === 'punct' && sep.value === ']') return items
    throw new ParseError(sep.line, `expected \`,\` or \`]\` in array but found \`${sep.value}\``)
  }
}

function parseValueFromToken(lex, tok) {
  if (tok.type === 'string') return tok.value
  if (tok.type === 'number') return Number(tok.value)
  if (tok.type === 'ident' && Object.prototype.hasOwnProperty.call(KEYWORD_LITERALS, tok.value)) {
    return KEYWORD_LITERALS[tok.value]
  }
  if (tok.type === 'punct' && tok.value === '{') return parseObject(lex)
  if (tok.type === 'punct' && tok.value === '[') return parseArray(lex)
  throw new ParseError(tok.line, `unexpected token \`${tok.value}\` where a value was expected`)
}

function parseObject(lex) {
  const obj = {}
  for (;;) {
    const keyTok = lex.next()
    if (keyTok.type === 'punct' && keyTok.value === '}') return obj

    let key
    if (keyTok.type === 'string' || keyTok.type === 'ident') key = keyTok.value
    else throw new ParseError(keyTok.line, `unexpected token \`${keyTok.value}\` where a property key was expected`)

    const colon = lex.next()
    if (!(colon.type === 'punct' && colon.value === ':')) {
      throw new ParseError(colon.line, `expected \`:\` after property key \`${key}\` but found \`${colon.value}\``)
    }

    obj[key] = parseValue(lex)

    const sep = lex.next()
    if (sep.type === 'punct' && sep.value === ',') continue
    if (sep.type === 'punct' && sep.value === '}') return obj
    throw new ParseError(sep.line, `expected \`,\` or \`}\` after property \`${key}\` but found \`${sep.value}\``)
  }
}

/**
 * Locate `const <varName> = { ... }` and parse the object literal that
 * follows into a plain JS value — no eval, no Function constructor.
 */
function extractAndParseObjectLiteral(src, varName) {
  const declRe = new RegExp(`(?:const|let|var)\\s+${varName}\\s*=`)
  const declMatch = declRe.exec(src)
  if (!declMatch) return { ok: false, error: `no \`const ${varName} = { ... }\` declaration found` }

  const lex = makeLexer(src, declMatch.index + declMatch[0].length)
  const open = lex.next()
  if (!(open.type === 'punct' && open.value === '{')) {
    return { ok: false, error: `\`${varName}\` must be an object literal written inline (line ${open.line})` }
  }

  try {
    const value = parseObject(lex)
    return { ok: true, value }
  } catch (err) {
    if (err instanceof ParseError) return { ok: false, error: err.message }
    throw err
  }
}

function asSortedSet(arr) {
  return [...new Set((arr ?? []).map((v) => (v === null ? ' null' : String(v))))].sort()
}

function typeSet(type) {
  return asSortedSet(Array.isArray(type) ? type : [type])
}

/** Normalize a JSON-Schema-shaped object into the comparable facets this checker cares about. */
function normalize(schema) {
  const props = schema.properties ?? {}
  const properties = {}
  for (const key of Object.keys(props).sort()) {
    const p = props[key] ?? {}
    const entry = { type: typeSet(p.type) }
    if ('enum' in p) entry.enum = asSortedSet(p.enum)
    if ('minimum' in p) entry.minimum = p.minimum
    properties[key] = entry
  }

  const allOf = (schema.allOf ?? [])
    .map((rule) => ({
      ifOutcomeConst: rule?.if?.properties?.outcome?.const ?? null,
      thenRequired: asSortedSet(rule?.then?.required),
    }))
    .sort((a, b) => String(a.ifOutcomeConst).localeCompare(String(b.ifOutcomeConst)))

  return {
    type: schema.type ?? null,
    required: asSortedSet(schema.required),
    additionalProperties: schema.additionalProperties ?? null,
    properties,
    allOf,
  }
}

function diffProperties(canonProps, jsProps) {
  const diffs = []
  const allKeys = new Set([...Object.keys(canonProps), ...Object.keys(jsProps)])
  for (const key of [...allKeys].sort()) {
    const c = canonProps[key]
    const j = jsProps[key]
    if (!c) { diffs.push(`property "${key}": present in .js copy but NOT in canonical schema`); continue }
    if (!j) { diffs.push(`property "${key}": present in canonical schema but MISSING from .js copy`); continue }
    if (JSON.stringify(c.type) !== JSON.stringify(j.type)) {
      diffs.push(`property "${key}".type: canonical=${JSON.stringify(c.type)} js=${JSON.stringify(j.type)}`)
    }
    const cEnum = 'enum' in c ? c.enum : undefined
    const jEnum = 'enum' in j ? j.enum : undefined
    if (JSON.stringify(cEnum) !== JSON.stringify(jEnum)) {
      diffs.push(`property "${key}".enum: canonical=${JSON.stringify(cEnum)} js=${JSON.stringify(jEnum)}`)
    }
    const cMin = 'minimum' in c ? c.minimum : undefined
    const jMin = 'minimum' in j ? j.minimum : undefined
    if (cMin !== jMin) {
      diffs.push(`property "${key}".minimum: canonical=${JSON.stringify(cMin)} js=${JSON.stringify(jMin)}`)
    }
  }
  return diffs
}

/** Returns { ok, diffs[] } comparing a canonical JSON-Schema object against the JS-literal copy. */
export function diffSchemas(canonicalSchema, jsSchema) {
  const canon = normalize(canonicalSchema)
  const js = normalize(jsSchema)
  const diffs = []

  if (canon.type !== js.type) {
    diffs.push(`top-level "type": canonical=${JSON.stringify(canon.type)} js=${JSON.stringify(js.type)}`)
  }
  if (JSON.stringify(canon.required) !== JSON.stringify(js.required)) {
    diffs.push(`top-level "required": canonical=${JSON.stringify(canon.required)} js=${JSON.stringify(js.required)}`)
  }
  if (canon.additionalProperties !== js.additionalProperties) {
    diffs.push(
      `top-level "additionalProperties": canonical=${JSON.stringify(canon.additionalProperties)} js=${JSON.stringify(js.additionalProperties)}`,
    )
  }
  diffs.push(...diffProperties(canon.properties, js.properties))
  if (JSON.stringify(canon.allOf) !== JSON.stringify(js.allOf)) {
    diffs.push(`"allOf": canonical=${JSON.stringify(canon.allOf)} js=${JSON.stringify(js.allOf)}`)
  }

  return { ok: diffs.length === 0, diffs }
}

// Exported for the test suite to exercise the parser directly against fixtures.
export function parseJsObjectLiteral(src, varName) {
  return extractAndParseObjectLiteral(src, varName)
}

// --------------------------------------------------------------------------
// CLI
// --------------------------------------------------------------------------
// Compare REALPATHs, not raw strings — see check-workflow-meta-literal.mjs's
// identical comment for why a naive string compare silently no-ops when
// invoked via a symlinked path (issue #933).
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
  const rawArgs = process.argv.slice(2)
  let varName = 'workerReturnSchema'
  const positional = []
  for (let i = 0; i < rawArgs.length; i++) {
    if (rawArgs[i] === '--var') { varName = rawArgs[++i]; continue }
    positional.push(rawArgs[i])
  }
  const [schemaPath, jsPath] = positional

  if (!schemaPath || !jsPath) {
    console.error('usage: check-worker-return-schema-parity.mjs <schema.json> <workflow.js> [--var NAME]')
    process.exit(2)
  }

  let schemaSrc, jsSrc
  try {
    schemaSrc = readFileSync(schemaPath, 'utf8')
  } catch (err) {
    console.error(`error: cannot read ${schemaPath}: ${err.message}`)
    process.exit(2)
  }
  try {
    jsSrc = readFileSync(jsPath, 'utf8')
  } catch (err) {
    console.error(`error: cannot read ${jsPath}: ${err.message}`)
    process.exit(2)
  }

  let canonicalSchema
  try {
    canonicalSchema = JSON.parse(schemaSrc)
  } catch (err) {
    console.error(`error: ${schemaPath} is not valid JSON: ${err.message}`)
    process.exit(2)
  }

  const parsed = extractAndParseObjectLiteral(jsSrc, varName)
  if (!parsed.ok) {
    console.error(`error: could not parse \`${varName}\` in ${jsPath}: ${parsed.error}`)
    process.exit(2)
  }

  const { ok, diffs } = diffSchemas(canonicalSchema, parsed.value)
  if (ok) {
    console.log(`OK    ${jsPath}'s \`${varName}\` matches ${schemaPath} on every validation-relevant facet`)
    process.exit(0)
  }

  console.log(`FAIL  ${jsPath}'s \`${varName}\` has drifted from ${schemaPath}:`)
  for (const d of diffs) console.log(`        ${d}`)
  process.exit(1)
}

#!/usr/bin/env node
// Measures how reusable the app's look is, for the Debug "Design" tab (Settings, tap the name on Home).
//
//   node tools/design-inventory.mjs            # rewrites ios/ikut/Debug/DesignInventory.swift
//   node tools/design-inventory.mjs --check    # exits 1 if that file is out of date (writes nothing)
//   node tools/design-inventory.mjs --lower   # also lowers both ratchet ceilings (Debug/DesignInventoryCeiling.swift, Debug/DesignTokenCeiling.swift) to today's counts, never raises one
//   node tools/design-inventory.mjs --root <dir> --out <file>   # another source folder (the node test uses this)
//
// It records (a) each View / ViewModifier struct outside UI/ with how many other files mention it, and (b) literal
// font sizes, raw colours, opacities, paddings, corner radii and frame sizes, each with file:line. Previews, comment
// lines, #if DEBUG blocks (demo fixtures), files and views named *Demo* or *Preview*, Theme.swift's colours and the
// Debug/ folder (this catalog) are skipped, so none of them count as a one-off or as a use. A view's count is how many
// times its name is written elsewhere (its own declaration not counted). Literals in UI/ are the shared layer: they
// are kept apart (Swift: place starts with UI/) and not counted as one-offs.
// Same sources in, same file out.
import { readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, relative, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const NUM = String.raw`(\d+(?:\.\d+)?)`

function swiftFiles(dir) {
  const out = []
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) out.push(...swiftFiles(p))
    else if (e.name.endsWith('.swift')) out.push(p)
  }
  return out
}

/// The file's lines with comments and #Preview blocks blanked out (line numbers stay).
export function codeLines(text) {
  const lines = text.split('\n')
  let depth = 0, inPreview = false, inBlock = false
  const conds = [] // one per open #if: is it `#if DEBUG`, and are we past its #else
  return lines.map((raw) => {
    let line = raw
    if (inBlock) {
      const end = line.indexOf('*/')
      if (end < 0) return ''
      inBlock = false
      line = line.slice(end + 2)
    }
    line = line.replace(/\/\*.*?\*\//g, '')
    if (line.includes('/*')) { inBlock = true; line = line.slice(0, line.indexOf('/*')) }
    line = stripLineComment(line)
    if (!inPreview) {
      const t = line.trim()
      if (/^#if\b/.test(t)) { conds.push({ debug: /^#if\s+DEBUG$/.test(t), inElse: false }); return '' }
      if (/^#else\b/.test(t) && conds.length) { conds[conds.length - 1].inElse = true; return '' }
      if (/^#endif\b/.test(t)) { conds.pop(); return '' }
      if (conds.some((c) => c.debug && !c.inElse)) return ''
    }
    if (!inPreview && /^\s*#Preview\b/.test(line)) { inPreview = true; depth = 0 }
    if (inPreview) {
      for (const c of stripStrings(line)) { if (c === '{') depth++; else if (c === '}') depth-- }
      if (depth <= 0 && /[}]/.test(line)) inPreview = false
      return ''
    }
    return line
  })
}

function stripStrings(line) { return line.replace(/"(?:\\.|[^"\\])*"/g, '""') }

function stripLineComment(line) {
  let inStr = false
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (c === '\\' && inStr) { i++; continue }
    if (c === '"') inStr = !inStr
    else if (!inStr && c === '/' && line[i + 1] === '/') return line.slice(0, i)
  }
  return line
}

const hex2 = (n) => Math.round(Math.max(0, Math.min(1, n)) * 255).toString(16).padStart(2, '0').toUpperCase()
const trimNum = (s) => String(parseFloat(s))

/// Literals found on one line: [{ category, value, swatch? }].
export function literalsIn(line, file) {
  const found = []
  const add = (category, value, swatch) => found.push({ category, value, swatch })
  for (const m of line.matchAll(new RegExp(String.raw`\.system\(size:\s*${NUM}\s*[,)]`, 'g'))) add('font', trimNum(m[1]))
  for (const m of line.matchAll(new RegExp(String.raw`\.opacity\(${NUM}\)`, 'g'))) add('opacity', trimNum(m[1]))
  for (const m of line.matchAll(new RegExp(String.raw`\.padding\(\s*(?:(\.\w+|\[[^\]]*\])\s*,\s*)?${NUM}\s*\)`, 'g'))) add('padding', trimNum(m[2]))
  for (const m of line.matchAll(new RegExp(String.raw`(?:[cC]ornerRadius:\s*|\.cornerRadius\()${NUM}`, 'g'))) add('radius', trimNum(m[1]))
  for (const m of line.matchAll(/\.frame\(([^()]*)\)/g)) {
    const pairs = [...m[1].matchAll(new RegExp(String.raw`(\w+):\s*${NUM}\s*(?=,|$)`, 'g'))].map((p) => `${p[1]} ${trimNum(p[2])}`)
    if (pairs.length) add('frame', pairs.join(', '))
  }
  if (!file.endsWith('UI/Theme.swift')) {
    for (const m of line.matchAll(/"#([0-9A-Fa-f]{6})"/g)) add('color', `#${m[1].toUpperCase()}`, m[1].toUpperCase())
    for (const m of line.matchAll(/\b0x([0-9A-Fa-f]{6})\b/g)) add('color', `#${m[1].toUpperCase()}`, m[1].toUpperCase())
    for (const m of line.matchAll(new RegExp(String.raw`(?:UI)?Color\(white:\s*${NUM}(?:,\s*alpha:\s*${NUM})?\)`, 'g'))) {
      const g = hex2(parseFloat(m[1]))
      add('color', `white ${trimNum(m[1])}` + (m[2] ? `, alpha ${trimNum(m[2])}` : ''), g + g + g)
    }
    for (const m of line.matchAll(new RegExp(String.raw`(?:UI)?Color\(\s*red:\s*${NUM},\s*green:\s*${NUM},\s*blue:\s*${NUM}(?:,\s*alpha:\s*${NUM})?\)`, 'g'))) {
      add('color', `red ${trimNum(m[1])}, green ${trimNum(m[2])}, blue ${trimNum(m[3])}` + (m[4] ? `, alpha ${trimNum(m[4])}` : ''),
        hex2(parseFloat(m[1])) + hex2(parseFloat(m[2])) + hex2(parseFloat(m[3])))
    }
  }
  return found
}

const STRUCT = /^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|public|internal|final)\s+)*struct\s+(\w+)[^{:]*:([^{]*)/

/// Scans `root` (the app's source folder) and returns { views, literals }.
export function scan(root) {
  const files = swiftFiles(root).map((p) => relative(root, p)).filter((f) => f !== 'Debug/DesignInventory.swift').sort()
  const code = new Map(files.map((f) => [f, codeLines(readFileSync(join(root, f), 'utf8'))]))
  const joined = new Map([...code].map(([f, l]) => [f, l.join('\n')]))
  const skipped = (f) => f.startsWith('Debug/') || /Demo|Preview/.test(f.split('/').pop())
  const views = [], literals = []
  for (const f of files) {
    if (skipped(f)) continue
    code.get(f).forEach((line, i) => {
      for (const l of literalsIn(line, f)) literals.push({ ...l, file: f, line: i + 1 })
      if (f.startsWith('UI/')) return
      const m = STRUCT.exec(line)
      if (!m) return
      const kind = /\bViewModifier\b/.test(m[2]) ? 'ViewModifier' : /\bView\b/.test(m[2]) ? 'View' : null
      if (!kind) return
      if (/Demo|Preview/.test(m[1])) return
      const word = new RegExp(String.raw`\b${m[1]}\b`, 'g')
      let uses = -1 // the declaration itself
      for (const g of files) if (!skipped(g)) uses += (joined.get(g).match(word) || []).length
      views.push({ name: m[1], kind, file: f, uses: Math.max(0, uses) })
    })
  }
  views.sort((a, b) => a.uses - b.uses || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0) || (a.file < b.file ? -1 : 1))
  return { views, literals, tokens: tokens(root) }
}

export const TOKEN_KEYS = ['spacing', 'radius', 'elevation', 'tintFill', 'colour']

/// The body of `enum <name> ... { ... }` in `text` (brace matched), or ''.
function enumBody(text, name) {
  const m = new RegExp(String.raw`\benum\s+${name}\b[^{]*\{`).exec(text)
  if (!m) return ''
  let depth = 1, i = m.index + m[0].length
  const start = i
  for (; i < text.length && depth > 0; i++) { if (text[i] === '{') depth++; else if (text[i] === '}') depth-- }
  return text.slice(start, i - 1)
}

/// The design tokens defined in UI/Theme.swift, UI/Palette.swift and the colour catalog, as { group, name } rows:
/// the `static let`s of Spacing and Radius, the cases of Elevation and TintFill, and the Color Sets of the catalog
/// (Contents.json and other non-.colorset entries are ignored).
export function tokens(root) {
  const read = (f) => (existsSync(join(root, f)) ? codeLines(readFileSync(join(root, f), 'utf8')).join('\n') : '')
  const theme = read('UI/Theme.swift'), palette = read('UI/Palette.swift')
  const lets = (body) => [...body.matchAll(/^\s*(?:private\s+)?static let (\w+)\s*(?::\s*(?!\[)[\w.]+)?\s*=/gm)].map((m) => m[1])
  const cases = (body) => [...body.matchAll(/^\s*case\s+([\w\s,]+?)\s*$/gm)].flatMap((m) => m[1].split(',').map((x) => x.trim()))
  const rows = []
  const add = (group, names) => names.forEach((name) => rows.push({ group, name }))
  add('spacing', lets(enumBody(theme, 'Spacing')))
  add('radius', lets(enumBody(theme, 'Radius')))
  add('elevation', cases(enumBody(palette, 'Elevation')))
  add('tintFill', cases(enumBody(palette, 'TintFill')))
  // D87: the colour tokens are the Color Sets in Assets.xcassets/Colors (one name each).
  const colorsDir = join(root, 'Resources/Assets.xcassets/Colors')
  add('colour', existsSync(colorsDir) ? readdirSync(colorsDir).filter((f) => f.endsWith('.colorset')).map((f) => f.replace(/\.colorset$/, '')).sort() : [])
  return rows
}

export function tokenCounts(rows) {
  return Object.fromEntries(TOKEN_KEYS.map((k) => [k, rows.filter((r) => r.group === k).length]))
}

export function renderTokenCeiling(c) {
  return `// The design-token ratchet (D78). Not generated, but written by \`node tools/design-inventory.mjs --lower\`.
// DesignInventoryTests fails if the number of tokens defined in UI/Theme.swift (Spacing, Radius), UI/Palette.swift
// (Elevation, TintFill) and the Color Sets of Assets.xcassets/Colors is above its number here, so the scales can only
// shrink. Adding a token means merging another one away. A piece that removes tokens MUST lower these: regenerate
// the inventory, then run \`node tools/design-inventory.mjs --lower\` (keeps the smaller of today's count and the
// ceiling, so it never raises one), or edit a single number below by hand.
enum TokenCeiling {
${TOKEN_KEYS.map((k) => `    static let ${k} = ${c[k]}`).join('\n')}
}
`
}

export const CEILING_KEYS = ['font', 'color', 'opacity', 'padding', 'radius', 'frame']

/// Today's counts, in the ratchet's terms: ad hoc literals per category (UI/ excluded) and views used once or not at all.
export function counts({ views, literals }) {
  const c = Object.fromEntries(CEILING_KEYS.map((k) => [k, literals.filter((l) => l.category === k && !l.file.startsWith('UI/')).length]))
  c.viewsUsedOnce = views.filter((v) => v.uses <= 1).length
  return c
}

/// Reads the ceiling out of DesignInventoryCeiling.swift: `static let font = 23` lines.
export function readCeiling(text) {
  const c = {}
  for (const m of text.matchAll(/static let (\w+) = (\d+)/g)) c[m[1]] = Number(m[2])
  return c
}

/// The ceiling file's text for the given numbers.
export function renderCeiling(c) {
  return `// The design ratchet (D77). Not generated, but written by \`node tools/design-inventory.mjs --lower\`.
// DesignInventoryTests fails if any ad hoc count in the generated inventory is above its number here, so the
// inventory can only go down. A piece that removes literals or merges one-off views MUST lower these: regenerate
// the inventory, then run \`node tools/design-inventory.mjs --lower\` (keeps the smaller of today's count and the
// ceiling, so it never raises one), or edit a single number below by hand. Counts exclude UI/, Debug/, previews and demos.
enum DesignCeiling {
${CEILING_KEYS.map((k) => `    static let ${k} = ${c[k]}`).join('\n')}
    /// Views (outside UI/) whose name is written in at most one other place.
    static let viewsUsedOnce = ${c.viewsUsedOnce}
}
`
}

/// The Swift file's text. Rows are one string each, parsed at run time (`InventoryParser`), so thousands of them
/// don't slow the build the way a literal array would.
export function render({ views, literals, tokens: tokenRows = [] }) {
  const esc = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
  return `// GENERATED by tools/design-inventory.mjs. Do not edit by hand.
// Regenerate (and rerun after a merge to refresh) with: node tools/design-inventory.mjs
// Shown by Settings > Design.
enum DesignInventory {
    /// name | kind | file | times its name is written elsewhere
    static let viewRows = """
${views.map((v) => `${v.name}|${v.kind}|${v.file}|${v.uses}`).join('\n')}
"""

    /// category | value | swatch hex (colours) | file:line
    static let literalRows = """
${literals.map((l) => `${l.category}|${esc(l.value)}|${l.swatch ?? ''}|${l.file}:${l.line}`).join('\n')}
"""

    /// group | token name, for the token ratchet
    static let tokenRows = """
${tokenRows.map((t) => `${t.group}|${t.name}`).join('\n')}
"""
}
`
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const opt = (name, fallback) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback)
  const root = resolve(opt('--root', join(here, '../ios/ikut')))
  const out = resolve(opt('--out', join(root, 'Debug/DesignInventory.swift')))
  const text = render(scan(root))
  if (args.includes('--check')) {
    if (!existsSync(out) || readFileSync(out, 'utf8') !== text) {
      console.error('DesignInventory.swift is out of date: run node tools/design-inventory.mjs')
      process.exit(1)
    }
    console.log('DesignInventory.swift is up to date')
  } else {
    writeFileSync(out, text)
    const { views, literals } = scan(root)
    if (args.includes('--lower')) {
      const ceilFile = join(dirname(out), 'DesignInventoryCeiling.swift')
      const now = counts({ views, literals })
      const old = existsSync(ceilFile) ? readCeiling(readFileSync(ceilFile, 'utf8')) : {}
      const next = Object.fromEntries(Object.keys(now).map((k) => [k, Math.min(now[k], old[k] ?? Infinity)]))
      writeFileSync(ceilFile, renderCeiling(next))
      const tokFile = join(dirname(out), 'DesignTokenCeiling.swift')
      const tokNow = tokenCounts(tokens(root))
      const tokOld = existsSync(tokFile) ? readCeiling(readFileSync(tokFile, 'utf8')) : {}
      const tokNext = Object.fromEntries(TOKEN_KEYS.map((k) => [k, Math.min(tokNow[k], tokOld[k] ?? Infinity)]))
      writeFileSync(tokFile, renderTokenCeiling(tokNext))
      console.log('token ceiling: ' + Object.entries(tokNext).map(([k, v]) => `${k} ${v}`).join(', '))
      console.log('ceiling: ' + Object.entries(next).map(([k, v]) => `${k} ${v}`).join(', '))
    }
    const n = (c) => literals.filter((l) => l.category === c && !l.file.startsWith('UI/')).length
    console.log(`${views.length} views (${views.filter((v) => v.uses <= 1).length} used once or not at all), ` +
      `${literals.filter((l) => l.file.startsWith('UI/')).length} literals inside UI/ (not counted below), ` +
      ['font', 'color', 'opacity', 'padding', 'radius', 'frame'].map((c) => `${n(c)} ${c}`).join(', '))
  }
}

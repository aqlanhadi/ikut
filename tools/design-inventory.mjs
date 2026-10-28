#!/usr/bin/env node
// Measures how reusable the app's look is, for the Debug "Design" tab (Settings, tap the name on Home).
//
//   node tools/design-inventory.mjs            # rewrites ios/ikut/Debug/DesignInventory.swift
//   node tools/design-inventory.mjs --check    # exits 1 if that file is out of date (writes nothing)
//   node tools/design-inventory.mjs --root <dir> --out <file>   # another source folder (the node test uses this)
//
// It records (a) each View / ViewModifier struct outside UI/ with how many other files mention it, and (b) literal
// font sizes, raw colours, opacities, paddings, corner radii and frame sizes, each with file:line. Previews, comment
// lines, Theme.swift's colours and the Debug/ folder (this catalog) are skipped; Lobby/LobbyDemo.swift and Debug/ don't count as a use.
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
  const counts = (f) => !(f.startsWith('Debug/') || f === 'Lobby/LobbyDemo.swift')
  const views = [], literals = []
  for (const f of files) {
    if (f.startsWith('Debug/')) continue
    code.get(f).forEach((line, i) => {
      for (const l of literalsIn(line, f)) literals.push({ ...l, file: f, line: i + 1 })
      if (f.startsWith('UI/')) return
      const m = STRUCT.exec(line)
      if (!m) return
      const kind = /\bViewModifier\b/.test(m[2]) ? 'ViewModifier' : /\bView\b/.test(m[2]) ? 'View' : null
      if (!kind) return
      const word = new RegExp(String.raw`\b${m[1]}\b`)
      const usedIn = files.filter((g) => g !== f && counts(g) && word.test(joined.get(g))).length
      views.push({ name: m[1], kind, file: f, usedIn })
    })
  }
  views.sort((a, b) => a.usedIn - b.usedIn || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0) || (a.file < b.file ? -1 : 1))
  return { views, literals }
}

/// The Swift file's text. Rows are one string each, parsed at run time (`InventoryParser`), so thousands of them
/// don't slow the build the way a literal array would.
export function render({ views, literals }) {
  const esc = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
  return `// GENERATED by tools/design-inventory.mjs. Do not edit by hand.
// Regenerate (and rerun after a merge to refresh) with: node tools/design-inventory.mjs
// Shown by Settings > Design (Debug builds only).
#if DEBUG
enum DesignInventory {
    /// name | kind | file | other files that mention it
    static let viewRows = """
${views.map((v) => `${v.name}|${v.kind}|${v.file}|${v.usedIn}`).join('\n')}
"""

    /// category | value | swatch hex (colours) | file:line
    static let literalRows = """
${literals.map((l) => `${l.category}|${esc(l.value)}|${l.swatch ?? ''}|${l.file}:${l.line}`).join('\n')}
"""
}
#endif
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
    const n = (c) => literals.filter((l) => l.category === c).length
    const { views, literals } = scan(root)
    console.log(`${views.length} views (${views.filter((v) => v.usedIn <= 1).length} used in one file or none), ` +
      ['font', 'color', 'opacity', 'padding', 'radius', 'frame'].map((c) => `${n(c)} ${c}`).join(', '))
  }
}

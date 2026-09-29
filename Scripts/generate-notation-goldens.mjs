// Generates Fixtures/ShikiNotationGoldens.json: real Shiki output for source
// with injected `[!code …]` notations, used to verify `applyShikiNotations`.
//
//   npm i shiki@4.4.3 @shikijs/transformers@4.4.3   (Node resolves these next to this
//   script, so run a copy of it from the directory you installed them in)
//   git clone --depth 1 https://github.com/shikijs/textmate-grammars-themes
//   node generate-notation-goldens.mjs <textmate-grammars-themes>/samples Fixtures/ShikiNotationGoldens.json
//
// ShikiSwift follows upstream after "fix(transformers): keep notations on
// content comment lines" (shikijs/shiki#1308), which is not in the published
// 4.4.3 package yet. Point SHIKI_TRANSFORMERS_MODULE at a build that has it
// (or a copy of the published dist with that change applied); without it the
// reference differs on whole-line comments that also contain code text.
//
// Injection is seeded, so output is reproducible for the same samples.
import { createHighlighter, bundledLanguages } from 'shiki'
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const [samplesDir, outFile] = process.argv.slice(2)
const moduleName = process.env.SHIKI_TRANSFORMERS_MODULE
  ? pathToFileURL(path.resolve(process.env.SHIKI_TRANSFORMERS_MODULE)).href
  : '@shikijs/transformers'
const {
  transformerNotationDiff, transformerNotationHighlight, transformerNotationFocus,
  transformerNotationErrorLevel, transformerNotationWordHighlight,
} = await import(moduleName)

const LANGUAGES = (process.env.LANGS ?? [
  'swift', 'typescript', 'javascript', 'python', 'ruby', 'shellscript', 'yaml', 'sql', 'html', 'css', 'rust', 'go',
  'c', 'cpp', 'java', 'kotlin', 'lua', 'haskell', 'php', 'markdown', 'json', 'toml', 'latex', 'clojure',
  'gn', 'actionscript-3', 'crystal', 'dart', 'ini', 'vue',
].join(',')).split(',')
const MAX_LINES = Number(process.env.MAX_LINES ?? 40)

let seed = 12345
const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff
const pick = a => a[Math.floor(rnd() * a.length)]

const styles = {
  slash: t => `// ${t}`, hash: t => `# ${t}`, dash: t => `-- ${t}`, semi: t => `; ${t}`, pct: t => `% ${t}`,
  block: t => `/* ${t} */`, html: t => `<!-- ${t} -->`, tight: t => `//${t}`, hashtight: t => `#${t}`, dsemi: t => `;; ${t}`,
}
const byLang = {
  python: 'hash', ruby: 'hash', shellscript: 'hash', yaml: 'hash', toml: 'hash', ini: 'semi', sql: 'dash', lua: 'dash',
  haskell: 'dash', html: 'html', markdown: 'html', css: 'block', latex: 'pct', clojure: 'semi', gn: 'hash',
}
const notes = ['++', '--', 'highlight', 'hl', 'focus', 'error', 'warning', 'info', '++:2', 'focus:3', 'highlight:2', '--:1', 'HIGHLIGHT', 'Error', 'error:0']
const words = l => l.match(/[A-Za-z_]{3,}/g) || []

function inject(code, style) {
  const c = styles[style]
  const out = []
  for (const line of code.split('\n').slice(0, MAX_LINES)) {
    const r = rnd()
    if (r < 0.10) out.push(`${line} ${c(`[!code ${pick(notes)}]`)}`)
    else if (r < 0.15) out.push(c(`[!code ${pick(notes)}]`), line)
    else if (r < 0.19) {
      const w = words(line)
      out.push(w.length ? `${line} ${c(`[!code word:${pick(w)}${rnd() < 0.3 ? ':' + (1 + Math.floor(rnd() * 3)) : ''}]`)}` : line)
    }
    else if (r < 0.23) out.push(`${line} ${c(`[!code ${pick(notes)}] [!code ${pick(notes)}]`)}`)
    else if (r < 0.26) out.push(`${line} ${c(`note [!code ${pick(notes)}]`)}`)
    else if (r < 0.29) out.push(`${line} // nested ${c(`[!code ${pick(notes)}]`)}`)
    else if (r < 0.31) out.push(c(`[!code word:${pick(words(line).concat(['x']))}]`), line)
    else if (r < 0.33) out.push(`${line} ${c('[!code word:a\\:b]')}`)
    else if (r < 0.35) out.push(`${line}${c(`[!code ${pick(notes)}]`)}`)
    else if (r < 0.38 && line.trim()) out.push(`  ${c(`[!code ${pick(notes)}]`)}`, line)
    else out.push(line)
  }
  return out.join('\n')
}

function summarize(hast) {
  const codeEl = hast.children[0].children[0]
  const text = n => n.type === 'text' ? n.value : (n.children || []).map(text).join('')
  return codeEl.children.filter(c => c.type === 'element').map(line => {
    const ranges = []
    let pos = 0
    for (const span of line.children) {
      const length = text(span).length
      if ([].concat(span.properties?.class ?? []).includes('highlighted-word') && length) {
        const last = ranges.at(-1)
        if (last && last[1] === pos) last[1] = pos + length
        else ranges.push([pos, pos + length])
      }
      pos += length
    }
    const cls = [].concat(line.properties?.class ?? []).filter(c => c !== 'line')
    return { t: text(line), c: [...new Set(cls)].sort(), w: ranges }
  })
}

const h = await createHighlighter({ themes: ['github-dark'], langs: [] })
const cases = []

function run(lang, style, code) {
  const variants = {}
  for (const algo of ['v3', 'v1']) {
    const transformers = [
      transformerNotationDiff, transformerNotationHighlight, transformerNotationFocus,
      transformerNotationErrorLevel, transformerNotationWordHighlight,
    ].map(t => t({ matchAlgorithm: algo }))
    variants[algo] = summarize(h.codeToHast(code, { lang, theme: 'github-dark', transformers, tokenizeTimeLimit: 0 }))
  }
  cases.push({ lang, style, code, variants })
}

for (const lang of LANGUAGES) {
  const file = path.join(samplesDir, `${lang}.sample`)
  if (!bundledLanguages[lang] || !fs.existsSync(file)) { console.error('skip', lang); continue }
  await h.loadLanguage(lang)
  const sample = fs.readFileSync(file, 'utf8')
  for (const style of new Set([byLang[lang] || 'slash', pick(Object.keys(styles))])) run(lang, style, inject(sample, style))
}

const jsx = `const a = (
  <div>
    {/* [!code ++] */}
    <span>hi</span> {/* [!code highlight] */}
    <b>x</b>
    {/* [!code focus:2] */}
    <i>y</i>
  </div>
) // [!code error]
const b = 1 // [!code --]
`
for (const lang of ['jsx', 'tsx']) {
  await h.loadLanguage(lang)
  run(lang, 'jsx', jsx)
}

fs.writeFileSync(outFile, JSON.stringify({ shikiVersion: '4.4.3', cases }))
console.log(`wrote ${cases.length} cases to ${outFile}`)

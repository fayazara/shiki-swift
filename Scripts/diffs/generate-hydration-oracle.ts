// Run with Bun and the supplied upstream checkout; no package installation.
import { resolve } from 'node:path';
import { readFileSync, writeFileSync } from 'node:fs';
const root = process.argv[2];
if (!root) throw new Error('Usage: bun Scripts/generate-hydration-oracle.ts /path/to/diffs');
const { hydratePartialDiff } = await import(resolve(root, 'src/utils/hydratePartialDiff.ts'));
// Reuse the independently generated, pinned-jsdiff inputs and hunk structures.
// Hydration consumes metadata, so intentionally stale indices/counts verify
// that it rebuilds geometry rather than retaining the original full-file result.
const seeds = JSON.parse(readFileSync('Tests/ShikiDiffsTests/Fixtures/diff-oracle.json', 'utf8'));
const cases: any[] = [];
function add(name: string, input: any, oldFile: any, newFile: any) {
  const original = JSON.stringify(input);
  let expected, error;
  try {
    expected = hydratePartialDiff('clone', input, { oldFile, newFile });
  } catch (failure) { error = String(failure); }
  if (JSON.stringify(input) !== original) throw new Error('upstream clone mutated input');
  if (expected != null) {
    const mergeInput = structuredClone(input);
    const merged = hydratePartialDiff('merge', mergeInput, { oldFile, newFile });
    if (merged !== mergeInput || JSON.stringify(merged) !== JSON.stringify(expected))
      throw new Error('upstream clone/merge disagreement');
  }
  cases.push({ name, input, oldFile, newFile, expected, error });
}
for (const [index, seed] of seeds.entries()) {
  const input = structuredClone(seed.expected);
  input.isPartial = true;
  input.deletionLines = []; input.additionLines = [];
  input.splitLineCount = 777; input.unifiedLineCount = 888;
  for (const hunk of input.hunks) {
    for (const key of ['additionLineIndex', 'deletionLineIndex', 'splitLineStart', 'unifiedLineStart',
                       'additionLines', 'deletionLines', 'splitLineCount', 'unifiedLineCount']) hunk[key] = 777;
    for (const content of hunk.hunkContent) { content.additionLineIndex = 777; content.deletionLineIndex = 777; }
  }
  const oldFile = structuredClone(seed.oldFile), newFile = structuredClone(seed.newFile);
  if (index % 4 !== 0) delete input.cacheKey;
  if (index % 4 === 2) delete oldFile.cacheKey;
  if (index % 4 === 3) { delete oldFile.cacheKey; delete newFile.cacheKey; }
  add(`seed-${index}`, input, input.type === 'rename-pure' ? null : oldFile, newFile);
}
const baseline = structuredClone(cases.find(c => c.input.type === 'change'));
add('already hydrated', { ...baseline.input, isPartial: false }, baseline.oldFile, baseline.newFile);
add('missing old file', baseline.input, null, baseline.newFile);
for (const type of ['new', 'deleted']) add(`unsupported ${type}`, { ...baseline.input, type }, baseline.oldFile, baseline.newFile);
for (const contents of ['a\r\nb', '', 'a\n']) {
  for (const cacheKey of [undefined, 'patch']) {
    const input = { ...baseline.input, type: 'rename-pure', hunks: [], cacheKey };
    const file = { name: 'renamed.txt', contents, cacheKey: 'new' };
    add(`pure rename ${JSON.stringify(contents)} ${cacheKey}`, input, null, file);
    add(`invalid pure rename ${JSON.stringify(contents)} ${cacheKey}`, input, baseline.oldFile, file);
  }
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/hydration-oracle.json', JSON.stringify(cases) + '\n');
console.log(`Wrote ${cases.length} upstream hydration cases (${cases.filter(c => c.error).length} rejected)`);

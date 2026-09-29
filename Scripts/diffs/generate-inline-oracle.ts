import { resolve } from 'node:path';
import { writeFileSync } from 'node:fs';
const root = process.argv[2];
const jsdiff = await import(process.argv[3] ?? '/tmp/shiki-diffs-jsdiff/package/libesm/index.js');
const { pushOrJoinSpan } = await import(resolve(root, 'src/utils/parseDiffDecorations.ts'));
const { cleanLastNewline } = await import(resolve(root, 'src/utils/cleanLastNewline.ts'));
function expected(old: string, next: string, type: string, maxLength: number) {
  old = cleanLastNewline(old); next = cleanLastNewline(next);
  const deletions = [], additions = [];
  if (type === 'none' || old.length > maxLength || next.length > maxLength) return { deletions, additions };
  const diff = type === 'char' ? jsdiff.diffChars(old, next) : jsdiff.diffWordsWithSpace(old, next);
  const a = [], b = [];
  for (const item of diff) {
    const config = { item, enableJoin: type === 'word-alt', isLastItem: item === diff.at(-1), isNeutral: !item.added && !item.removed };
    if (!item.added) pushOrJoinSpan({ ...config, arr: a });
    if (!item.removed) pushOrJoinSpan({ ...config, arr: b });
  }
  for (const [spans, output] of [[a, deletions], [b, additions]]) {
    let start = 0;
    for (const [changed, text] of spans) { if (changed) output.push([start, text.length]); start += text.length; }
  }
  return { deletions, additions };
}
const pairs = [
  ['こんにちは世界\n', 'こんにちは地球\n'], ['αβγδ', 'αβχδ'], ['Привет мир', 'Привет Мир'],
  ['café', 'café'], ['👩🏽‍💻x', '👩🏻‍💻y'], ['a\r\nb', 'a\nb'], ['a\uFEFF b', 'a\uFEFFc'],
  ['a\u0085b', 'a b'], ['let a = b + c', 'let d = e + c'], ['aaaa\n', 'bbbb\n'], ['', 'x'],
];
let seed = 19549;
function random() { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed; }
const alphabet = ['a', ' ', '\t', '界', 'α', '😀', '+', '\r', 'é', '\uFEFF', '\n'];
for (let i = 0; i < 200; i++) pairs.push([0, 1].map(() => Array.from({ length: random() % 28 }, () => alphabet[random() % alphabet.length]).join('')));
const cases = pairs.flatMap(([old, next]) => ['word', 'word-alt', 'char', 'none'].flatMap(type => [4, 1000].map(maxLength => ({ old, next, type, maxLength, expected: expected(old, next, type, maxLength) }))));
writeFileSync('Tests/ShikiDiffsTests/Fixtures/inline-oracle.json', JSON.stringify(cases, null, 2) + '\n');
console.log(`Wrote ${cases.length} inline cases from jsdiff 9 and upstream pushOrJoinSpan`);

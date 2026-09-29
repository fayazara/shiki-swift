import { readFileSync, writeFileSync } from 'node:fs';
import { resolveRegion } from '/Users/fayazahmed/Developer/fayazara/diffs/src/utils/resolveRegion';

const seed = JSON.parse(readFileSync(new URL('../../Tests/ShikiDiffsTests/Fixtures/resolution-oracle.json', import.meta.url), 'utf8'))[0].input;
const cases: any[] = [];
const originalError = console.error;
console.error = () => {};
try {
  for (const resolution of ['deletions', 'additions', 'both'] as const) {
    for (const variant of ['valid', 'missing-current', 'missing-incoming', 'both-missing', 'empty-current', 'empty-incoming', 'deleted-block', 'context-unused-current']) {
      const input = structuredClone(seed);
      const block = input.hunks[0].hunkContent[0];
      const indexesToDelete = variant === 'deleted-block' ? [0] : [];
      switch (variant) {
        case 'missing-current': block.deletionLineIndex = -1; break;
        case 'missing-incoming': block.additionLineIndex = 1; break;
        case 'both-missing':
        case 'deleted-block': block.deletionLineIndex = -1; block.additionLineIndex = Number.MAX_SAFE_INTEGER; break;
        case 'empty-current': block.deletions = 0; block.deletionLineIndex = -1; break;
        case 'empty-incoming': block.additions = 0; block.additionLineIndex = -1; break;
        case 'context-unused-current':
          input.hunks[0].hunkContent = [{ type: 'context', lines: 1, deletionLineIndex: -1, additionLineIndex: 0 }];
          break;
      }
      const test: any = { name: `${variant}/${resolution}`, input, resolution, indexesToDelete };
      try {
        test.expected = resolveRegion(input, { hunkIndex: 0, startContentIndex: 0, endContentIndex: 0, resolution, indexesToDelete: new Set(indexesToDelete) });
      } catch (error) { test.error = String(error); }
      cases.push(test);
    }
  }
} finally { console.error = originalError; }
writeFileSync(new URL('../../Tests/ShikiDiffsTests/Fixtures/resolution-validation-oracle.json', import.meta.url), JSON.stringify(cases, null, 2) + '\n');
console.log(`${cases.length} upstream cases; ${cases.filter(item => item.error).length} errors`);

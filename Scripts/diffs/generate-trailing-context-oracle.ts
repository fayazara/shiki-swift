import { resolve } from 'node:path';
const root = process.argv[2];
if (!root) throw new Error('Provide the upstream diffs checkout path');
const { getTrailingContextRangeSize } = await import(resolve(root, 'src/utils/virtualDiffLayout.ts'));
const cases = [];
for (const additions of [0, 1, 5]) for (const deletions of [0, 1, 5])
for (const additionStart of [0, 1, 4, 7]) for (const deletionStart of [0, 1, 4, 7])
for (const additionCount of [0, 1, 3]) for (const deletionCount of [0, 1, 3])
for (const partial of [false, true]) for (const hasHunk of [false, true]) {
    const input = { additions, deletions, additionStart, deletionStart, additionCount, deletionCount, partial, hasHunk };
    const fileDiff = { name: 'f.txt', isPartial: partial, additionLines: Array(additions).fill('x\n'), deletionLines: Array(deletions).fill('x\n'),
        hunks: hasHunk ? [{ additionStart, deletionStart, additionCount, deletionCount }] : [] };
    try { cases.push({ ...input, result: getTrailingContextRangeSize({ fileDiff, errorPrefix: 'oracle' }) }); }
    catch (error) { cases.push({ ...input, error: String((error as Error).message) }); }
}
await Bun.write(new URL('../../Tests/ShikiDiffsTests/Fixtures/trailing-context-oracle.json', import.meta.url), JSON.stringify(cases));
console.log(`Generated ${cases.length} upstream trailing-context cases`);

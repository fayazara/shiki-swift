import { resolve } from 'node:path';
import { readFileSync, writeFileSync } from 'node:fs';
const root = process.argv[2];
const jsdiffPath = process.argv[3] ?? '/tmp/shiki-diffs-jsdiff/package/libesm/index.js';
const jsdiff = await import(jsdiffPath);
const {processFile} = await import(resolve(root, 'src/utils/parsePatchFiles.ts'));
const {composeCacheKey} = await import(resolve(root, 'src/utils/composeCacheKey.ts'));
// Same adapter as upstream parseDiffFromFile, using the pinned jsdiff package.
function parseDiffFromFile(oldFile, newFile, options, throwOnError) {
 const patch = jsdiff.createTwoFilesPatch(oldFile.name,newFile.name,oldFile.contents,newFile.contents,oldFile.header,newFile.header,options);
 const result = processFile(patch,{oldFile,newFile,throwOnError,cacheKey:oldFile.cacheKey != null && newFile.cacheKey != null ? composeCacheKey('diff',oldFile.cacheKey,newFile.cacheKey):undefined});
 if (newFile.lang != null) result.lang = newFile.lang;
 return result;
}
const cases = [];
let seed = 57231;
function random() { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed; }
for (let i = 0; i < 300; i++) {
  const a = Array.from({length: random() % 20}, () => String(random() % 5) + '\n').join('');
  const b = Array.from({length: random() % 20}, () => String(random() % 5) + '\n').join('');
  const oldFile = {name: 'f.txt', contents: a, cacheKey: 'old:' + i};
  const newFile = {name: i % 13 === 0 ? 'renamed.txt' : 'f.txt', contents: b, cacheKey: 'new:' + i};
  const context = i % 5;
  cases.push({oldFile, newFile, context, expected: parseDiffFromFile(oldFile, newFile, {context}, true)});
}
for (const [a,b] of [['a\n','a'],['a\r\n','a\n'],['😀\n','😀x\n'],['','x'],['x',''],['same','same']]) {
  for (const context of [0,4]) {
    const oldFile = {name:'f', contents:a}, newFile={name:'f',contents:b};
    cases.push({oldFile,newFile,context,expected:parseDiffFromFile(oldFile,newFile,{context},true)});
  }
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/diff-oracle.json',JSON.stringify(cases,null,2)+'\n');
console.log(`Wrote ${cases.length} pinned jsdiff 9.0.0 cases`);
const arrays=[];
for(let i=0;i<300;i++){
 const a=Array.from({length:random()%30},()=>random()%4), b=Array.from({length:random()%30},()=>random()%4);
 arrays.push({a,b,expected:jsdiff.diffArrays(a,b).map(e=>({kind:e.added?'insert':e.removed?'delete':'equal',count:e.count}))});
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/sequence-oracle.json',JSON.stringify(arrays,null,2)+'\n');

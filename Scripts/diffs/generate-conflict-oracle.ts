import {readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
const root = process.argv[2];
const {parseMergeConflictDiffFromFile} = await import(resolve(root, 'src/utils/parseMergeConflictDiffFromFile.ts'));
const {resolveConflict} = await import(resolve(root, 'src/utils/resolveConflict.ts'));
const cases=[];
const sources = [
 ['two-sided', 'before\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\nafter\n'],
 ['diff3', 'before\n<<<<<<< HEAD\nours\n||||||| base\nancestor\n=======\ntheirs\n>>>>>>> branch\nafter\n'],
 ['empty current', '<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> branch\n'],
 ['empty incoming', '<<<<<<< HEAD\nours\n=======\n>>>>>>> branch\n'],
 ['both empty', '<<<<<<< HEAD\n=======\n>>>>>>> branch\n'],
 ['missing separator', '<<<<<<< HEAD\nours\n>>>>>>> branch\n'],
 ['unfinished', '<<<<<<< HEAD\nours\n=======\ntheirs\n'],
 ['no conflict', 'a\nb\n'],
 ['empty file', ''],
 ['no newline', '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch'],
 ['long markers', '<<<<<<<<<< HEAD\nours\n==========\ntheirs\n>>>>>>>>>> branch\n'],
 ['invalid marker content', 'before\n<<<<<<<HEAD\nours\n======= stuff\ntheirs\n>>>>>>>branch\n'],
 ['nested', '<<<<<<< HEAD\nouter current\n<<<<<<< inner\ninner current\n=======\ninner incoming\n>>>>>>> inner\n=======\nouter incoming\n>>>>>>> outer\n'],
 ['separate conflicts', '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\n' + Array.from({length:25},(_,i)=>`context ${i}\n`).join('') + '<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> branch\n'],
 ['identical sides', '<<<<<<< HEAD\nsame\n=======\nsame\n>>>>>>> branch\n'],
 ['CRLF', '<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> branch\r\n'],
];
for(const [name,contents] of sources) {
 for(const context of [1,6]) {
  const file={name:'merge.ts',contents,lang:'typescript',cacheKey:'fixture'};
  try { const expected=parseMergeConflictDiffFromFile(file,context); cases.push({name,context,file,expected}); }
  catch { cases.push({name,context,file,throws:true}); }
 }
}
const largeFile={name:'fileConflictLarge.ts',contents:readFileSync(resolve(root,'../pierre/apps/demo/src/mocks/fileConflictLarge.txt'),'utf8')};
cases.push({name:'large conflict source fixture',context:3,file:largeFile,expected:parseMergeConflictDiffFromFile(largeFile,3)});
writeFileSync('Tests/ShikiDiffsTests/Fixtures/conflict-oracle.json',JSON.stringify(cases,null,2)+'\n');
const resolutions=[];
for(const fixture of cases.filter(x=>x.expected?.actions.length && x.name!=='large conflict source fixture')) {
 for(const mode of ['current','incoming','both']) {
  const {fileDiff,actions}=fixture.expected;
  resolutions.push({name:fixture.name+' '+mode,input:fileDiff,action:actions[0],mode,expected:resolveConflict(fileDiff,actions[0],mode)});
 }
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/conflict-resolution-oracle.json',JSON.stringify(resolutions,null,2)+'\n');
console.log(`Wrote ${cases.length} conflict parses and ${resolutions.length} resolutions`);

import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
const root=resolve(process.argv[2]),temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-clipboard-')),entry=resolve(temp,'entry.ts');
writeFileSync(entry,`export {getSelectionText,getSelectionClipboardTexts,resolveSelectionCut} from ${JSON.stringify(resolve(root,'src/editor/selection.ts'))}; export {TextDocument} from ${JSON.stringify(resolve(root,'src/editor/textDocument.ts'))};`);
const build=await Bun.build({entrypoints:[entry],target:'bun',outdir:resolve(temp,'bundle')});if(!build.success)throw new AggregateError(build.logs);
const api=await import(resolve(temp,'bundle/entry.js')),fixtures=[];
for(const text of ['','a','aa\nbb\ncc','aa\r\nbb\r\n','a\rb\rc','\n\n','👩🏽‍💻test\né\n','one\ntwo\nthree\nfour']){
 const doc=new api.TextDocument('f.txt',text),singles=[],sets=[];
 for(let a=0;a<doc.lineCount;a++)for(let b=a;b<doc.lineCount;b++)for(const character of [0,doc.getLineLength(b)])for(const direction of [-1,0,1]){
  const selection={start:{line:a,character:0},end:{line:b,character},direction};singles.push(selection);sets.push([selection]);
 }
 for(let i=0;i<singles.length;i+=3)for(let j=0;j<singles.length;j+=6)sets.push([singles[i],singles[j]]);
 for(const selections of sets)fixtures.push({text,selections,clipboard:api.getSelectionClipboardTexts(doc,selections),expected:api.resolveSelectionCut(doc,selections)});
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/clipboard-oracle.json',JSON.stringify(fixtures)+'\n');console.log(`Wrote ${fixtures.length} clipboard cases`);

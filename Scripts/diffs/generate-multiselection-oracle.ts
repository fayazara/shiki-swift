import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
const root=resolve(process.argv[2]);
const temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-multiselection-'));
const entry=resolve(temp,'entry.ts');
writeFileSync(entry,`export * from ${JSON.stringify(resolve(root,'src/editor/selection.ts'))};\nexport {TextDocument} from ${JSON.stringify(resolve(root,'src/editor/textDocument.ts'))};`);
const build=await Bun.build({entrypoints:[entry],target:'bun',outdir:resolve(temp,'bundle')});
if(!build.success)throw new AggregateError(build.logs);
const api=await import(resolve(temp,'bundle/entry.js'));
let seed=837295;const random=()=>seed=(Math.imul(seed,1664525)+1013904223)>>>0;
const merges=[],replacements=[];
const sel=(a,b,d=1)=>({start:{line:0,character:a},end:{line:0,character:b},direction:a===b?0:d});
for(let i=0;i<512;i++){
 const selections=Array.from({length:1+random()%8},()=>{const a=random()%30,b=a+random()%8;return sel(a,b,[0,1,-1][random()%3])});
 merges.push({selections,expected:api.mergeOverlappingSelections(selections)});
}
function run(text,selections,texts,documentOrder=false){
 const doc=new api.TextDocument('f.txt',text);texts=texts.map(t=>doc.normalizeEol(t));
 const result=api.applyTextReplaceToSelections(doc,selections,texts,undefined,true,documentOrder?'document':'selection');
 replacements.push({text,selections,texts,documentOrder,expectedText:doc.getText(),expectedSelections:result.nextSelections});
}
for(let i=0;i<256;i++){
 const text='0123456789'.repeat(12),selections=[];
 for(let j=0;j<1+random()%6;j++){let a=j*15+random()%5;selections.push(sel(a,a+random()%5,[1,-1][random()%2]));}
 if(random()%2)selections.reverse();
 const choices=['x','','\n','😀','ABC','()'];const texts=selections.map(()=>choices[random()%choices.length]);
 run(text,selections,texts,random()%2===0);
}
run('abcdefghi',[sel(1,5),sel(3,7),sel(8,8)],['','','']);
run("'😀word",[sel(0,1),sel(1,3)], ["'''",'(😀)']);
run('  a\r\n  b',[{start:{line:1,character:3},end:{line:1,character:3},direction:0},sel(3,3)],['\n','\n']);
writeFileSync(process.argv[3] ?? 'Tests/ShikiDiffsTests/Fixtures/multiselection-oracle.json',JSON.stringify({merges,replacements})+'\n');
console.log(`Generated ${merges.length} merge and ${replacements.length} replacement cases from upstream`);

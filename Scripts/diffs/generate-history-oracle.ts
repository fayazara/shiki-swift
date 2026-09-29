import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
const root=resolve(process.argv[2]);
const temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-history-'));
const entry=resolve(temp,'entry.ts');
writeFileSync(entry,`export {EditStack} from ${JSON.stringify(resolve(root,'src/editor/editStack.ts'))};\nexport {TextDocument} from ${JSON.stringify(resolve(root,'src/editor/textDocument.ts'))};`);
const build=await Bun.build({entrypoints:[entry],target:'bun',outdir:resolve(temp,'bundle')});
if(!build.success)throw new AggregateError(build.logs);
const {TextDocument,EditStack}=await import(resolve(temp,'bundle/entry.js'));
let seed=191284;const random=()=>seed=(Math.imul(seed,1664525)+1013904223)>>>0;
const cases=[];
function scenario(text,maxEntries,steps){
 const doc=new TextDocument('f.txt',text,'text',0,new EditStack({maxEntries}));
 const actions=[];
 const apply=(edits,carets,undoBoundary=false,updateHistory=true)=>{
  const selections=carets?.map(c=>({start:doc.positionAt(c),end:doc.positionAt(c),direction:0}));
  doc.applyResolvedEdits(edits,updateHistory,selections,undefined,undoBoundary);
  record({kind:'apply',edits,selections,undoBoundary,updateHistory});
 };
 function record(action){const h=doc.history;actions.push({...action,text:doc.getText(),version:doc.version,undoCount:h.undoStack.length,redoCount:h.redoStack.length,canCoalesce:h.canCoalesce,top:JSON.parse(JSON.stringify(h.undoStack.at(-1)??null))});}
 const undo=()=>{doc.undo();record({kind:'undo'})},redo=()=>{doc.redo();record({kind:'redo'})};
 steps({doc,apply,undo,redo});
 while(doc.canUndo)undo();while(doc.canRedo)redo();
 cases.push({text,maxEntries,actions});
}
scenario('tail',100,({apply})=>{
 apply([{start:0,end:0,text:'a'}],[0],false,true);
 apply([{start:1,end:1,text:'b'}],[1],true,false);
 apply([{start:2,end:2,text:'c'}],[2],true,true);
});
scenario('one\ntwo',100,({doc,apply})=>{for(let i=0;i<80;i++){const a=i,b=doc.getText().indexOf('\n')+1+i;apply([{start:a,end:a,text:'x'},{start:b,end:b,text:'y'}],[a,b]);}});
scenario('abcdefghij\nABCDEFGHIJ',100,({doc,apply})=>{for(let i=0;i<6;i++){const b=doc.getText().indexOf('\n')+1;apply([{start:0,end:1,text:''},{start:b,end:b+1,text:''}],[0,b]);}});
scenario('abcdefghij\nABCDEFGHIJ',100,({doc,apply})=>{for(let i=0;i<6;i++){const a=doc.getText().indexOf('\n'),b=doc.getText().length;apply([{start:a-1,end:a,text:''},{start:b-1,end:b,text:''}],[a,b]);}});
scenario('',100,({doc,apply})=>{for(let i=0;i<110;i++){const n=doc.getText().length;apply([{start:n,end:n,text:'x\n'}],[n]);}});
scenario('a😀b',100,({apply})=>{apply([{start:2,end:2,text:'x'}],[2]);apply([{start:2,end:4,text:'Q'}],[2]);});
for(let i=0;i<32;i++)scenario('0123456789 abcdefghij\nlast',7,({doc,apply,undo,redo})=>{
 for(let n=0;n<60;n++){
  if(random()%7===0){undo();continue;}if(random()%11===0){redo();continue;}
  const length=doc.getText().length,start=random()%(length+1),end=Math.min(length,start+random()%4);
  const text=['x','','a\nb','pq',' '][random()%5];
  apply([{start,end,text}],[random()%2?start:end],random()%9===0);
 }
});
writeFileSync(process.argv[3]??'Tests/ShikiDiffsTests/Fixtures/history-oracle.json',JSON.stringify(cases)+'\n');
console.log(`Generated ${cases.length} histories, ${cases.reduce((n,c)=>n+c.actions.length,0)} operations from upstream`);

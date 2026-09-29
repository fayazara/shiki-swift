import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
const digest=value=>createHash('sha256').update(JSON.stringify(value,(_key,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.entries(v).sort(([a],[b])=>a<b?-1:a>b?1:0)):v)).digest('hex');
const root=resolve(process.argv[2]);
const temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-prediction-'));
writeFileSync(resolve(temp,'entry.ts'),[
 `export * from ${JSON.stringify(resolve(root,'src/editor/editPrediction.ts'))};`,
 `export {TextDocument} from ${JSON.stringify(resolve(root,'src/editor/textDocument.ts'))};`,
 `export {getTextDocumentChangeTransaction} from ${JSON.stringify(resolve(root,'src/editor/textDocumentChangeTransaction.ts'))};`
].join('\n'));
const build=await Bun.build({entrypoints:[resolve(temp,'entry.ts')],target:'bun',outdir:resolve(temp,'bundle')});
if(!build.success)throw new AggregateError(build.logs);
const {TextDocument,buildEditPredictionRequest,recordEditPrediction,matchesEditPredictionPattern,getTextDocumentChangeTransaction}=await import(resolve(temp,'bundle/entry.js'));
let seed=995122;const random=()=>seed=(Math.imul(seed,1664525)+1013904223)>>>0;
const requests=[],histories=[],patterns=[];
function request(text,cursor,blocked=[],history=[]){
 const doc=new TextDocument('a.ts',text,'text',17);
 requests.push({text,cursor,blocked,history,expected:buildEditPredictionRequest('a.ts',doc,cursor,history,line=>!blocked.includes(line))??null});
}
for(const text of ['','a\r\nb\rc\n','a😀z','é\ne\u0301','x'.repeat(1535),'x'.repeat(1539),'x'.repeat(200000)])for(const cursor of [-7,0,1,2,3,text.length,text.length+7])request(text,cursor);
for(let i=0;i<160;i++){
 const lines=Array.from({length:20+random()%250},(_,n)=>['xyz','😀'.repeat(20),'','space '.repeat(25),'x'.repeat(1600)][random()%5]+n);
 const text=lines.join(['\n','\r\n','\r'][random()%3]);
 request(text,random()%(text.length+1),Array.from({length:lines.length},(_,n)=>n).filter(()=>random()%9===0));
}
request('a',1,[],Array.from({length:15},(_,n)=>({path:'a.ts',hunk:`change ${n}`,start:0,end:1,at:n,source:n%2?'user':'prediction'})));
request('a',1,[],[{path:'a.ts',hunk:'x'.repeat(140000),start:0,end:1,at:0,source:'user'}]);
function history(text,steps){
 const doc=new TextDocument('a.ts',text);let history=[],at=0;const actions=[];
 function edit(edits,gap=50,source='user',path='a.ts'){
  const change=doc.applyResolvedEdits(edits);at+=gap;
  history=recordEditPrediction(history,path,doc,getTextDocumentChangeTransaction(change),source,at);
  actions.push({kind:'apply',edits,gap,at,source,path,expected:digest(history)});
 }
 function replay(kind,gap=50){
  const replay=doc[kind]();at+=gap;if(!replay)return;
  history=recordEditPrediction(history,'a.ts',doc,getTextDocumentChangeTransaction(replay[0]),'user',at);
  actions.push({kind,gap,at,source:'user',path:'a.ts',expected:digest(history)});
 }
 steps({doc,edit,replay});histories.push({text,actions});
}
history('one\ntwo\nthree\n',({doc,edit,replay})=>{for(let i=0;i<20;i++)edit([{start:i,end:i,text:'x'}]);replay('undo');replay('redo');edit([{start:0,end:doc.getText().length,text:''}]);});
history('',({edit})=>{edit([{start:0,end:0,text:'x'}]);edit([{start:0,end:1,text:''}]);});
history('a\r\nb\rc\n',({edit})=>{edit([{start:1,end:3,text:'\n'}]);edit([{start:3,end:4,text:'changed\n'}]);});
history(Array.from({length:100},(_,i)=>`${i}: ${'x'.repeat(300)}`).join('\n'),({doc,edit})=>{for(let i=0;i<30;i++){const start=doc.offsetAt({line:i*3,character:1});edit([{start,end:start+1,text:'Q'}]);}});
history('tail',({edit})=>{edit([{start:0,end:0,text:'x'.repeat(7000)}]);edit([{start:0,end:7000,text:''}]);edit([{start:0,end:0,text:'small'}]);});
for(let i=0;i<24;i++)history(Array.from({length:40},(_,n)=>`line ${n}: ${'abc '.repeat(3)}`).join(i%2?'\n':'\r\n'),({doc,edit,replay})=>{
 for(let j=0;j<50;j++){
  if(random()%9===0){replay('undo');continue;}if(random()%13===0){replay('redo');continue;}
  const length=doc.getText().length,start=random()%(length+1),end=Math.min(length,start+random()%9);
  edit([{start,end,text:['X','y\nzz','','😀','e\u0301'][random()%5]}],random()%4?50:1000,random()%6?'user':'prediction',random()%7?'a.ts':'b.ts');
 }
});
for(const path of ['a.ts','src/a.ts','src/deep/a.ts','src/a.TS','a/b','ab','a😀b','line\nnext','']){
 for(const glob of ['**/*.ts','src/*','src/**','?.ts','a?b','a😀b','a*b','**','', 'src\\*.ts','[a].ts'])patterns.push({path,pattern:glob,flags:null,expected:matchesEditPredictionPattern(path,glob)});
 for(const [pattern,flags] of [['\.ts$','i'],['^src',''],['a','g'],['a','y'],['^next','m'],['line.next','s'],['a.b','u'],['a.b',''],['a😀b',''],['a😀b','u'],['😀+',''],['[😀]',''],['[\\p{ASCII}&&\\p{Letter}]+','v']])patterns.push({path,pattern,flags,expected:matchesEditPredictionPattern(path,new RegExp(pattern,flags))});
}
writeFileSync(process.argv[3]??'Tests/ShikiDiffsTests/Fixtures/prediction-oracle.json',JSON.stringify({requests,histories,patterns})+'\n');
console.log(`${requests.length} requests; ${histories.length} histories / ${histories.reduce((n,h)=>n+h.actions.length,0)} transactions; ${patterns.length} patterns`);

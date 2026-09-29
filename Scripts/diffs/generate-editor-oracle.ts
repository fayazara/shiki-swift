// Bundles the actual upstream implementation, only routing its pinned diff dependency.
import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
const root=resolve(process.argv[2]);
const dependency=resolve(process.argv[3] ?? '/tmp/shiki-diffs-jsdiff/package/libesm/index.js');
const temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-editor-oracle-'));
const entry=resolve(temp,'entry.ts');
writeFileSync(entry, `export * from ${JSON.stringify(resolve(root,'src/utils/editSessionHunks.ts'))};\nexport {parseDiffFromFile} from ${JSON.stringify(resolve(root,'src/utils/parseDiffFromFile.ts'))};\nexport {recomputeEmptyDocumentDiff,recomputeTopAlignedAdditionDiff,shouldTopAlignAdditionRecompute} from ${JSON.stringify(resolve(root,'src/utils/updateDiffHunks.ts'))};`);
const build=await Bun.build({entrypoints:[entry],target:'bun',outdir:resolve(temp,'bundle'),plugins:[{name:'pinned-jsdiff',setup(builder){builder.onResolve({filter:/^diff$/},()=>({path:dependency}));}}]});
if(!build.success) throw new AggregateError(build.logs,'Failed to bundle upstream editor oracle');
const upstream=await import(resolve(temp,'bundle/entry.js'));
const fixtures=[];
const snapshot=(value)=>JSON.parse(JSON.stringify(value));
function run(name,oldText,initialText,edits,context=4){
 const diff=upstream.parseDiffFromFile({name:'old.txt',contents:oldText,cacheKey:'old'}, {name:'new.txt',contents:initialText,cacheKey:'new'}, {context},true);
 let expansions=new Map(Array.from({length:diff.hunks.length+1},(_,i)=>[i,{fromStart:i%3+1,fromEnd:i%2+1}]));
 const input=snapshot(diff),steps=[];
 for(const edit of edits){
  const previous=diff.additionLines;
  const lines=typeof edit==='string' ? edit.match(/[^\n]*\n|[^\n]+$/g)??[] : edit.lines;
  const changed=typeof edit==='string' ? null : edit.changed??null;
  diff.additionLines=lines;
  let change,error;
  try {
   change=changed===null ? upstream.rebuildSessionHunks(diff,{context}) : upstream.applySessionChangedLines(diff,changed,{context},new Map(changed.map(i=>[i,previous[i]])));
  } catch(e){error=e.message;}
  if(change) expansions=upstream.remapExpandedHunksForRegionChange(expansions,change);
  steps.push({lines,changed,change:change??null,error:error??null,expected:snapshot(diff),expansions:Object.fromEntries(expansions)});
  if(error) break;
 }
 let anchors=[],anchorError;
 try {anchors=upstream.captureExpansionAnchors(diff,expansions,1)} catch(e){anchorError=e.message}
 const finished=upstream.finishEditSessionForDiff(diff,{context});
 fixtures.push({name,context,input,steps,anchors,anchorError:anchorError??null,finished,expected:snapshot(diff),expansions:Object.fromEntries(upstream.rebuildExpansionFromAnchors(diff,anchors))});
}
const base=Array.from({length:50},(_,i)=>`line ${i}\n`);
for(const context of [0,1,4]){
 let initial=base.slice();initial[8]='changed 8\n';initial[35]='changed 35\n';
 run('revert and gap edit',base.join(''),initial.join(''),[base.join(''),base.map((s,i)=>i===22?'gap edit\n':s).join(''),initial.join('')],context);
 let bridge=base.slice();bridge.splice(7,32,'bridge\n');
 run('merge regions',base.join(''),initial.join(''),[bridge.join(''),base.join('')],context);
 run('insert at boundaries',base.join(''),base.join(''),['insert\n'+base.join(''),base.join('')+'tail\n',base.join('')],context);
 run('delete all and undo',base.join(''),initial.join(''),['',base.join('')],context);
 run('empty exit',base.join(''),initial.join(''),[''],context);
 run('blank exit',base.join(''),initial.join(''),['\n\n'],context);
 run('phantom trailing row','a\nb\nc\n','a\nx\nc\n',[{lines:['a\n','x\n','']},'a\nb\nc\n'],context);
 run('fast balanced','a\nb\nc\n','a\nx\nc\n',[{lines:['a\n','y\n','c\n'],changed:[1,1,-1,100]},{lines:['a\n','b\n','c\n'],changed:[1]}],context);
 run('Unicode exact','é\n😀\n','é\n😀\n',['é\n😀\n','é\n😁\n'],context);
 run('no final newline','a\nb','a\nx',['z\nx','a\nb'],context);
}
let seed=24681357;
function random(){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed;}
for(let i=0;i<120;i++){
 const old=Array.from({length:random()%20},()=>String(random()%6)+'\n');
 let current=old.slice(),edits=[];
 for(let step=0;step<6;step++){
  current=current.slice();const position=random()%(current.length+1),remove=Math.min(random()%4,current.length-position);
  const inserted=Array.from({length:random()%4},()=>String(random()%8)+'\n');
  current.splice(position,remove,...inserted);edits.push(current.join(''));
 }
 run(`random ${i}`,old.join(''),old.join(''),edits,i%5);
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/editor-oracle.json',JSON.stringify(fixtures,null,2)+'\n');
console.log(`Wrote ${fixtures.length} editor sessions with ${fixtures.reduce((n,f)=>n+f.steps.length,0)} editing steps from upstream`);
// Mirrors the small dispatch in DiffHunksRenderer.applyDocumentChange/updateRenderCache:
// empty/blank additions use the upstream sentinel helpers; normal edits retain regions.
// The actual view/editor host is not executed by this data-only oracle.
const retained=[];
for(const fixture of fixtures){
 const diff=snapshot(fixture.input);delete diff.cacheKey;
 let expansions=new Map(Array.from({length:diff.hunks.length+1},(_,i)=>[i,{fromStart:i%3+1,fromEnd:i%2+1}]));
 const steps=[];
 for(const step of fixture.steps){
  const previous=diff.additionLines;diff.additionLines=step.lines;
  let change;
  const empty=diff.additionLines.length<=1 && diff.additionLines.join('')==='';
  if(empty || upstream.shouldTopAlignAdditionRecompute(diff,diff.additionLines)){
   const type=diff.type;
   Object.assign(diff,empty?upstream.recomputeEmptyDocumentDiff(diff,{context:fixture.context}):upstream.recomputeTopAlignedAdditionDiff(diff,diff.additionLines,{context:fixture.context}));
   diff.type=type;diff.editSessionDirty=true;
  } else {
   change=step.changed===null ? upstream.rebuildSessionHunks(diff,{context:fixture.context}) : upstream.applySessionChangedLines(diff,step.changed,{context:fixture.context},new Map(step.changed.map(i=>[i,previous[i]])));
  }
  if(change) expansions=upstream.remapExpandedHunksForRegionChange(expansions,change);
  steps.push({...step,change:change??null,expected:snapshot(diff),expansions:Object.fromEntries(expansions)});
 }
 const anchors=upstream.captureExpansionAnchors(diff,expansions,1);
 const finished=upstream.finishEditSessionForDiff(diff,{context:fixture.context});
 retained.push({...fixture,steps,anchors,anchorError:null,finished,expected:snapshot(diff),expansions:Object.fromEntries(upstream.rebuildExpansionFromAnchors(diff,anchors))});
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/retained-editor-oracle.json',JSON.stringify(retained,null,2)+'\n');
console.log(`Wrote ${retained.length} retained editor sessions using upstream renderer dispatch`);

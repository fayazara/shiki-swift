import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync,readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
const root=resolve(process.argv[2]),temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-selection-'));
const entry=resolve(temp,'entry.ts');
writeFileSync(entry,`export * from ${JSON.stringify(resolve(root,'src/editor/selection.ts'))};`);
const build=await Bun.build({entrypoints:[entry],target:'bun',outdir:resolve(temp,'bundle'),plugins:[{name:'expose-pure-ranges',setup(builder){
 builder.onLoad({filter:/\/editor\/selection\.ts$/},args=>({contents:readFileSync(args.path,'utf8')+'\nexport {resolveDeleteWordBackwardRange, resolveDeleteHardLineForwardRange};',loader:'ts'}));
}}]});
if(!build.success)throw new AggregateError(build.logs);
const api=await import(resolve(temp,'bundle/entry.js'));
const fixtures=[];
const texts=['  alpha\nx\n    omega\n','a👩🏽‍💻b\néx\n🇮🇳!','\tfoo_bar  !!! \nβeta\n','0123456789\na\nabcdefghijk\nlast','word \nword  \nword\u00a0x\n',''];
const segmenter=new Intl.Segmenter(undefined,{granularity:'grapheme'});
for(const text of texts){
 const lines=text.split('\n'),doc={lineCount:lines.length,getLineText:(n)=>lines[n]??'',getLineLength:(n)=>(lines[n]??'').length,offsetAt:({line,character})=>lines.slice(0,line).reduce((n,s)=>n+s.length+1,0)+character,getTextSlice:(a,b)=>text.slice(a,b)};
 const positions=lines.flatMap((line,l)=>[...new Set([0,...Array.from(segmenter.segment(line),s=>s.index+s.segment.length),line.length+5])].map(character=>({line:l,character})));
 for(const mode of ['plain','fold','wrap','wrap-fold']){
  const softLineOffsets=mode.includes('wrap')?Object.fromEntries(lines.map((line,l)=>[l,line.length>5?[0,3,line.length]:[0,line.length]])):undefined;
  const renderableLines=mode.includes('fold')?[0,lines.length-1]:undefined;
  const options={getSoftLineOffsets:softLineOffsets?(l)=>softLineOffsets[l]:undefined,resolveRenderableLine:renderableLines?(line,dir)=>dir==='up'?renderableLines.findLast(l=>l<=line):renderableLines.find(l=>l>=line):undefined};
  for(let i=0;i<positions.length;i++)for(const direction of [0,1,-1]){
   const a=positions[i],b=positions[Math.min(positions.length-1,i+2)];
   const selection={start:a,end:direction===0?a:b,direction};
   for(const movement of ['textStart','start','end','up','down','left','right'])for(const shift of [false,true]){
    fixtures.push({text,softLineOffsets,renderableLines,selection,movement,shift,expected:(shift?api.mapSelectionShift:api.mapCursorMove)(doc,[selection],movement,options)[0]});
   }
  }
 }
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/selection-oracle.json',JSON.stringify(fixtures)+'\n');
const deletions=[];
for(const text of [...texts,'word!','abc !!! ','foo_42\u0085','\u0301◌\t','a\u2028b']){
 const lines=text.split('\n'),doc={lineCount:lines.length,getLineText:(n)=>lines[n]??'',getLineLength:(n)=>(lines[n]??'').length,offsetAt:({line,character})=>lines.slice(0,line).reduce((n,s)=>n+s.length+1,0)+character,getTextSlice:(a,b)=>text.slice(a,b)};
 for(let line=0;line<lines.length;line++)for(const character of [0,...Array.from(segmenter.segment(lines[line]),s=>s.index+s.segment.length)]){
  const selection={start:{line,character},end:{line,character},direction:0};
  for(const kind of ['wordBackward','hardLineForward']){
   const result=(kind==='wordBackward'?api.resolveDeleteWordBackwardRange:api.resolveDeleteHardLineForwardRange)(doc,selection);
   const {start,end}=Array.isArray(result)?{start:result[0],end:result[1]}:result;
   deletions.push({text,selection,kind,expected:{start,end}});
  }
 }
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/deletion-oracle.json',JSON.stringify(deletions)+'\n');
console.log(`Wrote ${fixtures.length} navigation and ${deletions.length} deletion cases`);
const indents=[];
for(const text of [...texts,' \tfoo\n  \n\tbar\n\uFEFF  x',' \u0301foo\n   x']){
 const lines=text.split('\n'),doc={lineCount:lines.length,getLineText:(n)=>lines[n]??''};
 for(let startLine=0;startLine<lines.length;startLine++)for(let endLine=startLine;endLine<lines.length;endLine++)for(const atEnd of [false,true])for(const direction of [1,-1])for(const tabSize of [0,2,4])for(const outdent of [false,true]){
  const selection={start:{line:startLine,character:0},end:{line:endLine,character:atEnd?lines[endLine].length:0},direction};
  const [edits,nextSelection]=api.resolveIndentEdits(doc,selection,tabSize,outdent);
  indents.push({text,selection,tabSize,outdent,edits,nextSelection});
 }
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/indent-oracle.json',JSON.stringify(indents)+'\n');
console.log(`Wrote ${indents.length} indentation cases`);

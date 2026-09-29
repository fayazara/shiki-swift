import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
const root=resolve(process.argv[2]);
const dependency=resolve(process.argv[3]??'/tmp/shiki-diffs-jsdiff/package/libesm/index.js');
const temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-options-'));
const entry=resolve(temp,'entry.ts');
writeFileSync(entry,`export {parseDiffFromFile} from ${JSON.stringify(resolve(root,'src/utils/parseDiffFromFile.ts'))};`);
const build=await Bun.build({entrypoints:[entry],target:'bun',outdir:resolve(temp,'bundle'),plugins:[{name:'pinned-jsdiff',setup(builder){builder.onResolve({filter:/^diff$/},()=>({path:dependency}));}}]});
if(!build.success) throw new AggregateError(build.logs);
const {parseDiffFromFile}=await import(resolve(temp,'bundle/entry.js'));
const fixtures=[];
function run(name,a,b,options,rename=false){
 const oldFile={name:rename?'old.txt':'f.txt',contents:a},newFile={name:rename?'new.txt':'f.txt',contents:b};
 try {fixtures.push({name,oldFile,newFile,options,expected:parseDiffFromFile(oldFile,newFile,options,true)})}
 catch(error){fixtures.push({name,oldFile,newFile,options,error:String(error.message)})}
}
const samples=[['a\r\nb\r\n','a\nb\n'],['a\n',' a '],['a','a\n'],['a\nb\n','x\nb'],['a\nb','x\nb\n'],['\uFEFFa\n','a\n'],['\u0085a\n','a\n'],['\u2007a\n','a\n'],['a\r','a'],[' \n',''],['é\n','é\n'],['a\r\r\n','a\r\n']];
for(let sample=0;sample<samples.length;sample++)for(const context of [0,1,4])for(const ignoreWhitespace of [false,true])for(const stripTrailingCr of [false,true]){
 const [a,b]=samples[sample];run(`edge ${sample}`,a,b,{context,ignoreWhitespace,stripTrailingCr},sample%2===0);
}
let seed=81283;
function random(){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed;}
for(let i=0;i<100;i++){
 const a=Array.from({length:random()%14},()=>['a\n','b\r\n',' c\n','\uFEFFd\r\n','\u0085a\n'][random()%5]).join('');
 const b=Array.from({length:random()%14},()=>['a\n','b\r\n','c\n','d\n','\u0085a\n'][random()%5]).join('');
 for(const ignoreWhitespace of [false,true])for(const stripTrailingCr of [false,true])run(`random ${i}`,a,b,{context:i%5,ignoreWhitespace,stripTrailingCr},i%7===0);
}
for(const includeIndex of [false,true])for(const includeUnderline of [false,true])for(const includeFileHeaders of [false,true]){
 const options={headerOptions:{includeIndex,includeUnderline,includeFileHeaders}};
 for(const [a,b] of [['a\n','b\n'],['a\n','a\n'],['','new\n']])for(const rename of [false,true])run('headers',a,b,options,rename);
 const old=Array.from({length:60},(_,i)=>`line ${i}\n`),next=old.slice();next[4]='changed four\n';next.splice(24,1,'changed twenty four\n','extra line\n');next[49]='changed forty eight\n';
 for(const rename of [false,true])run('multiple hunks with headers',old.join(''),next.join(''),options,rename);
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/options-oracle.json',JSON.stringify(fixtures,null,2)+'\n');
console.log(`Wrote ${fixtures.length} patch-generation option cases`);

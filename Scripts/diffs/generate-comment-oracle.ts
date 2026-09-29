import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
const root=resolve(process.argv[2]),temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-comments-')),entry=resolve(temp,'entry.ts');
writeFileSync(entry,`export * from ${JSON.stringify(resolve(root,'src/editor/languages.ts'))}; export {TextDocument} from ${JSON.stringify(resolve(root,'src/editor/textDocument.ts'))};`);
const build=await Bun.build({entrypoints:[entry],target:'bun',outdir:resolve(temp,'bundle')});if(!build.success)throw new AggregateError(build.logs);
const api=await import(resolve(temp,'bundle/entry.js'));
const fixtures=[];
const texts=['','word','  word\n    next\n\nlast','// one\n//two\n','  // one\n two','/* word */','/*  word  */','a /* word */ b','/**/','/* */','\uFEFFone\r\n \t two\r\n',' \u0301one\n\u0085two','<!-- abc -->','/* '+ 'x'.repeat(120)+' */'];
for(const text of texts){
 const doc=new api.TextDocument('f.txt',text),sets=[];
 for(let a=0;a<doc.lineCount;a++)for(let b=a;b<doc.lineCount;b++)for(const end of [0,doc.getLineLength(b)])for(const direction of [-1,0,1]){
  sets.push([{start:{line:a,character:0},end:{line:b,character:end},direction}]);
 }
 if(doc.lineCount>1)sets.push([0,doc.lineCount-1].map(line=>({start:{line,character:0},end:{line,character:0},direction:0})));
 if(doc.lineCount===1)for(let start=0;start<=Math.min(16,text.length);start++)for(let end=start;end<=Math.min(16,text.length);end+=Math.max(1,text.length%4))sets.push([{start:{line:0,character:start},end:{line:0,character:end},direction:1}]);
 for(const selections of sets){
  for(const token of ['//','#','<!--',''])fixtures.push({text,selections,kind:'line',token,edits:api.resolveLineCommentEdits(doc,selections,token)});
  for(const tokens of [['/*','*/'],['<!--','-->'],['"""','"""']])for(const linewise of [false,true]){
   const result=api.resolveBlockCommentEdits(doc,selections,tokens,linewise);
   fixtures.push({text,selections,kind:'block',tokens,linewise,edits:result?.edits,offsets:result?.nextSelectionOffsets});
  }
 }
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/comment-oracle.json',JSON.stringify(fixtures)+'\n');console.log(`Wrote ${fixtures.length} comment cases`);
const configs=['swift','sql','ruby','rst','coffeescript','cmd','julia','yaml','yml','markdown','zsh','makefile','handlebars','ini','powershell','vb','xml','lua','html','diff','r','fsharp','pug','perl','tex','clojure','css','python','dotenv','dockerfile','razor','prompt'].map(language=>({language,expected:api.resolveCommentConfig(language)}));
writeFileSync('Tests/ShikiDiffsTests/Fixtures/comment-config-oracle.json',JSON.stringify(configs)+'\n');

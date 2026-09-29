import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
const root=resolve(process.argv[2]),temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-annotations-'));
const entry=resolve(temp,'entry.ts');
writeFileSync(entry,`export {TextDocument} from ${JSON.stringify(resolve(root,'src/editor/textDocument.ts'))}; export {applyDocumentChangeToLineAnnotations} from ${JSON.stringify(resolve(root,'src/editor/lineAnnotations.ts'))};`);
const build=await Bun.build({entrypoints:[entry],target:'bun',outdir:resolve(temp,'bundle')});
if(!build.success)throw new AggregateError(build.logs);
const api=await import(resolve(temp,'bundle/entry.js')),fixtures=[];
for(const text of ['','a','aa\nbb\ncc','aa\r\nbb\r\ncc','aa\nbb\n','😀a\nb\nç']) {
 const source=new api.TextDocument('f',text),positions=[];
 for(let line=0;line<source.lineCount;line++)for(let character=0;character<=source.getLineLength(line);character++)positions.push({line,character});
 const annotations=[];
 for(const side of ['additions','deletions'])for(let lineNumber=0;lineNumber<=source.lineCount+1;lineNumber++)annotations.push({id:`${side}:${lineNumber}`,side,lineNumber,text:'Note'});
 for(let a=0;a<positions.length;a++)for(let b=a;b<positions.length;b++)for(const insert of ['','X','\n','x\ny','\n\n']) {
  const edits=[{range:{start:positions[a],end:positions[b]},newText:insert}],doc=new api.TextDocument('f',text);
  const change=doc.applyEdits(edits);
  const expected=change?api.applyDocumentChangeToLineAnnotations(change,annotations):undefined;
  fixtures.push({text,edits,annotations,expected:expected??null,expectedText:doc.getText()});
 }
 for(let a=0;a<positions.length;a++)for(let b=a;b<positions.length;b++)for(let c=b;c<positions.length;c++)for(let d=c;d<positions.length;d++) {
  for(const [left,right] of [['\n',''],['','\n'],['x\ny','z'],['\n','\n']]) {
   const edits=[{range:{start:positions[a],end:positions[b]},newText:left},{range:{start:positions[c],end:positions[d]},newText:right}];
   const doc=new api.TextDocument('f',text);
   let change; try { change=doc.applyEdits(edits); } catch(error) {
    if(error instanceof Error && error.message==='Overlapping text edits are not supported')continue;
    throw error;
   }
   const expected=change?api.applyDocumentChangeToLineAnnotations(change,annotations):undefined;
   fixtures.push({text,edits,annotations,expected:expected??null,expectedText:doc.getText()});
  }
 }
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/annotation-oracle.json',JSON.stringify(fixtures)+'\n');
console.log(`Wrote ${fixtures.length} annotation mapping cases`);

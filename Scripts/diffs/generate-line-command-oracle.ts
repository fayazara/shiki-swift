import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync,readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
const root=resolve(process.argv[2]),temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-line-'));
const source=readFileSync(resolve(root,'src/editor/editor.ts'),'utf8');
const copy=source.slice(source.indexOf('  #copySelectedLines(direction:'),source.indexOf('  /** Inserts an indented blank line'));
const blank=source.slice(source.indexOf('  #insertBlankLine(): void'),source.indexOf('  #moveSelectedLines(direction:'));
const move=source.slice(source.indexOf('  #moveSelectedLines(direction:'),source.indexOf('  #handleLayoutResize ='));
const entry=resolve(temp,'entry.ts');
writeFileSync(entry,`import {DirectionNone,getSelectedLineBlocks,shiftSelectionLines,getCaretPosition} from ${JSON.stringify(resolve(root,'src/editor/selection.ts'))};
export class Harness {
 #editSession; #selections; result;
 constructor(document,selections){this.#editSession={document};this.#selections=selections;document.applyEdits=(edits,_,before,next)=>{this.result={edits,selections:next};return {}}}
 #applyChange(){}
 #applyCommandEdits(edits,resolve){this.result={edits,selections:resolve(this.#editSession.document)}}
 run(command){if(command==='insertBlankLine')this.#insertBlankLine();else if(command.startsWith('copy'))this.#copySelectedLines(command==='copyUp'?-1:1);else this.#moveSelectedLines(command==='moveUp'?-1:1);return this.result??{edits:[],selections:this.#selections}}
 ${copy}\n${blank}\n${move}\n}`);
const build=await Bun.build({entrypoints:[entry],target:'bun',outdir:resolve(temp,'bundle')});if(!build.success)throw new AggregateError(build.logs);
const {Harness}=await import(resolve(temp,'bundle/entry.js'));
const fixtures=[];
for(const text of ['','a','a\n','  first\nx\nlast','a\r\nb\r\nc\r\n','\tfoo\n\n  bar\n\uFEFFbaz','one\ntwo\nthree\nfour\nfive\nsix']){
 const lines=text.split(/\r\n|\r|\n/),eol=text.match(/\r\n|\r|\n/)?.[0]??'\n';
 const offsetAt=({line,character})=>lines.slice(0,line).reduce((n,s)=>n+s.length+eol.length,0)+Math.min(character,lines[line].length);
 const doc={eol,lineCount:lines.length,getLineText:n=>lines[n],getLineLength:n=>lines[n].length,getText:range=>text.slice(offsetAt(range.start),offsetAt(range.end))};
 const selections=[];
 for(let start=0;start<lines.length;start++)for(let end=start;end<lines.length;end++)for(const character of [0,lines[end].length])for(const direction of [-1,0,1]){
  selections.push([{start:{line:start,character:0},end:{line:end,character},direction}]);
 }
 for(let i=0;i<lines.length;i++)for(let j=i+1;j<lines.length;j++)selections.push([i,j].map(line=>({start:{line,character:0},end:{line,character:0},direction:0})));
 for(const selection of selections)for(const command of ['moveUp','moveDown','copyUp','copyDown','insertBlankLine']){
  fixtures.push({text,selections:selection,command,expected:new Harness(doc,selection).run(command)});
 }
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/line-command-oracle.json',JSON.stringify(fixtures)+'\n');console.log(`Wrote ${fixtures.length} line command cases`);

import {resolve} from 'node:path';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
const root=resolve(process.argv[2]),temp=mkdtempSync(resolve(tmpdir(),'shiki-diffs-search-')),entry=resolve(temp,'entry.ts');
writeFileSync(entry,`export {TextDocument} from ${JSON.stringify(resolve(root,'src/editor/textDocument.ts'))}; export {buildSearchReplacementText} from ${JSON.stringify(resolve(root,'src/editor/pieceTable.ts'))};`);
const build=await Bun.build({entrypoints:[entry],target:'bun',outdir:resolve(temp,'bundle')});if(!build.success)throw new AggregateError(build.logs);
const api=await import(resolve(temp,'bundle/entry.js')),fixtures=[];
const texts=['','one ONE one_two one-two','aa\nbb\r\ncc\raa','é é β42 ١٢ _foo','a\u00a0a\u0085a\uFEFFa\u0000a','a\u2028b\u2029c','👩🏽‍💻🇮🇳 a','foo bar foo','abc123 XYZ456','aaa aaaa b','/* x */ [a] (x)','K k K ſ s S ß ss'];
const patterns=['','one','a','foo','é','é','_foo','a\nb','a\rb',String.raw`\n`,String.raw`\r`,'.','^','$','^a','a$','a*','a+','a++','(?=a)|a','(?<=a)a','(?<word>[a-z]+)([0-9]*)',String.raw`\b\w+\b`,String.raw`\d+`,String.raw`\s+`,String.raw`[^\s]+`,'[a-z]','(a)?(b)','(a)(a*)',String.raw`(a)\1`,'[','(?i)a','a{2,3}','(?<!a)b','k','s'];
for(const text of texts)for(const query of patterns)for(const regex of [false,true])for(const caseSensitive of [false,true])for(const wholeWord of [false,true]){
 const params={text:query,replaceText:'<$&>-$1-$2-$0-$01-$99-$$-$`',regex,caseSensitive,wholeWord};
 const doc=new api.TextDocument('f.txt',text),matches=doc.search(params);
 const replacements=matches.map(([start,end])=>api.buildSearchReplacementText(o=>doc.positionAt(o),p=>doc.offsetAt(p),l=>doc.getLineText(l),params,start,end));
 // Swift strings represent Unicode scalar values; malformed surrogate fragments
 // remain covered as ranges, while replacement-string comparisons use valid Unicode.
 const valid=replacements.every(s=>s.isWellFormed());
 fixtures.push({text,params,matches,replacements:valid?replacements:undefined});
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/search-oracle.json',JSON.stringify(fixtures)+'\n');console.log(`Wrote ${fixtures.length} search cases`);

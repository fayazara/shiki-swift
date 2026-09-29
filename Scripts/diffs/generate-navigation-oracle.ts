import { resolve } from 'node:path';
const root = process.argv[2];
if (!root) throw new Error('Provide upstream checkout');
const layout = await import(resolve(root, 'src/utils/virtualDiffLayout.ts'));
const source = await Bun.file(resolve(root, 'src/components/FileDiff.ts')).text();
const method = source.slice(source.indexOf('  public revealLine('), source.indexOf('\n  // Whether render() may run'));
if (!method.startsWith('  public revealLine(') || !method.trimEnd().endsWith('}')) throw new Error('Upstream revealLine boundary changed');
const code = new Bun.Transpiler({loader:'ts'}).transformSync(`class Subject { ${method} }`);
const Subject = new Function('getExpandedRegion','getHunkAdditionLineRange','getTrailingExpandedRegion','DEFAULT_COLLAPSED_CONTEXT_THRESHOLD', `${code}; return Subject`)(layout.getExpandedRegion,layout.getHunkAdditionLineRange,layout.getTrailingExpandedRegion,1);
const cases=[];
for (const starts of [[11,31], [0], [10], []]) for (const count of [0,2])
for (const partial of [false,true]) for (const all of [false,true]) for (const threshold of [1,12])
for (const slices of [[0,0],[3,2],[-2,4],[100,100]]) {
 const hunks=starts.map((s,i)=>({additionStart:s,deletionStart:s,additionCount:count,deletionCount:count,collapsedBefore:Math.max(0,s-(count>0?1:0)-(i ? starts[i-1]-(count>0?1:0)+count:0))}));
 const fileDiff={name:'f.txt',hunks,isPartial:partial,additionLines:Array(45).fill('x\n'),deletionLines:Array(45).fill('x\n')};
 const expandedHunks=new Map(Array.from({length:hunks.length+1},(_,i)=>[i,{fromStart:slices[0],fromEnd:slices[1]}]));
 const options={expandUnchanged:all,collapsedContextThreshold:threshold,expansionLineCount:3};
 const probes=[];
 for (let line=-1;line<=47;line++) {
  const props={fileDiff,lineNumber:line,expandedHunks:all?true:expandedHunks,collapsedContextThreshold:threshold};
  const subject=new Subject(); subject.options=options;subject.getRenderedDiff=()=>fileDiff;subject.hunksRenderer={getExpandedHunksMap:()=>expandedHunks};
  let expansion=null;subject.expandHunk=(index,direction,count)=>{expansion={index,direction,count}};
  const revealed=subject.revealLine(line);
  probes.push({line,visible:layout.isAdditionLineRenderable(props),up:layout.getNearestRenderableAdditionLine({...props,direction:'up'})??null,down:layout.getNearestRenderableAdditionLine({...props,direction:'down'})??null,revealed,expansion});
 }
 cases.push({starts,count,partial,all,threshold,fromStart:slices[0],fromEnd:slices[1],probes});
}
await Bun.write(new URL('../../Tests/ShikiDiffsTests/Fixtures/navigation-oracle.json',import.meta.url),JSON.stringify(cases));
console.log(`Generated ${cases.length} cases, ${cases.length*49} navigation probes`);

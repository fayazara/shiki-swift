// Usage: bun Scripts/test-api-inventory.ts <typescript.js>
import { strict as assert } from 'node:assert';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
const root = mkdtempSync(join(tmpdir(), 'shiki-diffs-export-fixture-'));
mkdirSync(join(root, 'src'));
writeFileSync(join(root, 'package.json'), JSON.stringify({name:'fixture', version:'1', exports:{'.':{import:'./dist/index.js'}}}));
writeFileSync(join(root, 'src/index.ts'), `
export { default as Thing } from './thing';
export * from './types';
export { external as importedFunction } from 'absent-dependency';
export const callable = (value: number): string => String(value);
`);
writeFileSync(join(root, 'src/types.ts'), `
export interface Contract { readonly id: string; perform(value: number): Promise<void> }
export type Alias = string;
export class Base { protected hidden() {} visible() {} }
`);
writeFileSync(join(root, 'src/thing.ts'), `
import { Base } from './types';
export default class Thing extends Base {
  constructor(public readonly label: string, private secret = 1) { super(); }
  private hiddenMethod() {}
  protected protectedMethod() {}
  #secretField = 1;
  execute = (amount: number): boolean => amount > this.secret;
  get name(): string { return this.label; }
}
`);
const output = join(root, 'inventory.json');
const script = new URL('./inventory-upstream-api.ts', import.meta.url).pathname;
const run = () => execFileSync(process.execPath, [script, root, process.argv[2], output], {encoding:'utf8', stdio:'pipe'});
run();
const first = readFileSync(output, 'utf8');
const exports = JSON.parse(first).entryPoints[0].exports;
assert.deepEqual(exports.map((e: any) => e.name), ['Alias', 'Base', 'callable', 'Contract', 'importedFunction', 'Thing']);
const thing = exports.find((e: any) => e.name === 'Thing').origins[0];
assert.equal(thing.file, 'src/thing.ts');
assert.deepEqual(thing.declaredMembers.map((m: any) => m.name), ['constructor', 'execute', 'name', 'label']);
assert.deepEqual(thing.declaredMembers.find((m: any) => m.name === 'execute').callableParameters, ['amount: number']);
assert.equal(exports.find((e: any) => e.name === 'importedFunction').unresolvedExternalAlias, true);
assert.deepEqual(exports.find((e: any) => e.name === 'Contract').origins[0].declaredMembers.map((m: any) => m.name), ['id','perform']);
run(); assert.equal(readFileSync(output, 'utf8'), first);
writeFileSync(join(root, 'src/index.ts'), "export * from './missing';");
assert.throws(run, /Missing re-export/);
console.log('API inventory fixture checks passed: aliases, types, public members, parameter properties, callables, deterministic output, missing-module rejection.');

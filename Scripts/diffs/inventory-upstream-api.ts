// Usage: bun Scripts/inventory-upstream-api.ts <upstream-root> <typescript.js> [output.json]
// Tool dependency: TypeScript 5.9.3; parser only, no upstream code is executed.
import { readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { resolve, relative, dirname } from 'node:path';
import { createHash } from 'node:crypto';
const root = resolve(process.argv[2]);
const ts = (await import(resolve(process.argv[3]))).default;
const pkg = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8'));
const entries = Object.entries(pkg.exports).map(([name, value]: [string, any]) => ({
  name, path: resolve(root, value.import.replace(/^\.\/dist\//, 'src/').replace(/\.js$/, '.ts')),
}));
for (const entry of entries) if (!existsSync(entry.path)) throw new Error(`Missing entry ${entry.path}`);
const program = ts.createProgram(entries.map(e => e.path), {
  noEmit: true, skipLibCheck: true, target: ts.ScriptTarget.ES2022,
  module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler,
  jsx: ts.JsxEmit.ReactJSX,
});
const checker = program.getTypeChecker();
const location = (node: any) => {
  const source = node.getSourceFile();
  return { file: relative(root, source.fileName), line: source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1 };
};
const modifier = (node: any, kind: number) => node.modifiers?.some((m: any) => m.kind === kind) ?? false;
const signature = (node: any) => ({
  kind: ts.SyntaxKind[node.kind], ...location(node),
  ...(node.typeParameters?.length ? { typeParameters: node.typeParameters.map((p: any) => p.getText()) } : {}),
  ...(node.parameters ? { parameters: node.parameters.map((p: any) => p.getText()) } : {}),
  ...(node.type ? { type: node.type.getText() } : {}),
  ...(node.initializer && (ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer))
      ? { callableParameters: node.initializer.parameters.map((p: any) => p.getText()),
          ...(node.initializer.type ? { returnType: node.initializer.type.getText() } : {}) } : {}),
});
const visited = new Map<string, any>();
function inspectGraph(path: string) {
  if (visited.has(path)) return;
  const source = program.getSourceFile(path);
  if (!source) throw new Error(`Unresolved local module ${path}`);
  const reexports: any[] = [];
  const entry = { file: relative(root, path), sha256: createHash('sha256').update(source.text).digest('hex'), reexports };
  visited.set(path, entry);
  const parseErrors = source.parseDiagnostics ?? [];
  if (parseErrors.length) throw new Error(`Parse errors in ${path}`);
  for (const node of source.statements) {
    if (!ts.isExportDeclaration(node) || !node.moduleSpecifier) continue;
    const specifier = node.moduleSpecifier.text;
    const item: any = { specifier, typeOnly: !!node.isTypeOnly, star: !node.exportClause, ...location(node) };
    if (specifier.startsWith('.')) {
      const base = resolve(dirname(path), specifier);
      const target = [base, `${base}.ts`, `${base}.tsx`, `${base}/index.ts`, `${base}/index.tsx`].find(candidate => existsSync(candidate) && statSync(candidate).isFile());
      if (!target) throw new Error(`Missing re-export ${specifier} from ${path}`);
      item.target = relative(root, target); inspectGraph(target);
    } else {
      item.external = true;
      if (!node.exportClause) throw new Error(`Cannot completely enumerate external star export ${specifier}`);
    }
    reexports.push(item);
  }
}
function describe(symbol: any) {
  const original = symbol;
  if (symbol.flags & ts.SymbolFlags.Alias) symbol = checker.getAliasedSymbol(symbol);
  const declarations = symbol.getDeclarations() ?? [];
  const origins = declarations.map((node: any) => {
    const result: any = signature(node);
    if (node.heritageClauses?.length) result.heritage = node.heritageClauses.map((h: any) => h.getText());
    if (node.members) result.declaredMembers = [...node.members,
      ...node.members.filter(ts.isConstructorDeclaration).flatMap((ctor: any) => ctor.parameters.filter((p: any) =>
        modifier(p, ts.SyntaxKind.PublicKeyword) || modifier(p, ts.SyntaxKind.ReadonlyKeyword)))]
      .filter((m: any) => !modifier(m, ts.SyntaxKind.PrivateKeyword) && !modifier(m, ts.SyntaxKind.ProtectedKeyword) && !(m.name && ts.isPrivateIdentifier(m.name)))
      .map((member: any) => ({ name: member.name?.getText() ?? (ts.isConstructorDeclaration(member) ? 'constructor' : '(signature)'),
        ...signature(member), optional: !!member.questionToken, static: modifier(member, ts.SyntaxKind.StaticKeyword), readonly: modifier(member, ts.SyntaxKind.ReadonlyKeyword) }));
    return result;
  });
  return { name: original.getName(), origins,
    unresolvedExternalAlias: declarations.length === 0,
    ...(declarations.length === 0 ? { exportSites: (original.getDeclarations() ?? []).map(location) } : {}),
    nativeDisposition: 'unreviewed' };
}
const results = entries.map(entry => {
  inspectGraph(entry.path);
  const source = program.getSourceFile(entry.path)!;
  const module = checker.getSymbolAtLocation(source);
  const exports = module ? checker.getExportsOfModule(module).map(describe).sort((a: any,b: any) => a.name.localeCompare(b.name, 'en')) : [];
  return { entryPoint: entry.name, source: relative(root, entry.path), exports,
    sideEffectImports: source.statements.filter((s: any) => ts.isImportDeclaration(s) && !s.importClause).map((s: any) => s.moduleSpecifier.text) };
});
const output = {
  package: pkg.name, version: pkg.version, parser: `TypeScript ${ts.version}`,
  limitations: ['Source export enumeration is not native parity.', 'External named aliases can be enumerated but their dependency signatures are unresolved.', 'Only directly declared public members are listed; inherited contracts require separate review.', 'Runtime side effects of worker entry points are not represented by named exports.', 'Type/value availability, inferred types, and overload semantics require contract review.'],
  entryPoints: results,
  reexportModules: [...visited.values()].sort((a,b) => a.file.localeCompare(b.file, 'en')),
};
const target = process.argv[4] ? resolve(process.argv[4]) : new URL('../../Documentation/Diffs/upstream-api-inventory.json', import.meta.url);
writeFileSync(target, JSON.stringify(output, null, 2) + '\n');
for (const entry of results) console.log(`${entry.entryPoint}: ${entry.exports.length} names, ${entry.exports.filter((e: any) => e.unresolvedExternalAlias).length} unresolved external aliases`);
console.log(`${visited.size} re-export graph modules hashed`);

// Runs only the supplied upstream source. Bun strips TypeScript; no package install.
import { resolve } from 'node:path';
import { readFileSync, writeFileSync } from 'node:fs';
const root = process.argv[2];
if (!root) throw new Error('Usage: bun Scripts/generate-patch-oracle.ts /path/to/diffs');
const { parsePatchFiles } = await import(resolve(root, 'src/utils/parsePatchFiles.ts'));
const cases: {name: string; patch: string; expected?: unknown}[] = [];
function add(name: string, body: string, specs = '@@ -1 +1 @@', headers = 'diff --git a/f.txt b/f.txt\nindex abc123..def456 100644\n--- a/f.txt\n+++ b/f.txt') {
  cases.push({name, patch: `${headers}\n${specs}\n${body}`});
}
add('replacement', '-old\n+new\n');
add('context and unequal block', ' top\n-old\n+new\n+extra\n bottom\n', '@@ -1,3 +1,4 @@');
add('no newline either side', '-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n');
add('newline added', '-old\n\\ No newline at end of file\n+old\n');
add('newline removed', '-old\n+old\n\\ No newline at end of file\n');
add('CRLF source', '-old\r\n+new\r\n');
add('insert at start', '+new\n', '@@ -0,0 +1 @@');
add('insert at boundary', '+new\n', '@@ -7,0 +8 @@');
add('delete at boundary', '-old\n', '@@ -8 +7,0 @@');
add('zero-zero', '', '@@ -0,0 +0,0 @@');
add('function context', '-old\n+new\n', '@@ -2 +2 @@ function hello()');
add('unicode and tabs', '-\t👩🏽‍💻 café\n+\t你好 👋🏽\n');
add('similarity shifts addition', '-const value = 1;\n+\n+const value = 2;\n', '@@ -1 +1,2 @@');
add('similarity shifts deletion', '-\n-const value = 1;\n+const value = 2;\n', '@@ -1,2 +1 @@');
add('quoted rename', '-old\n+new\n', '@@ -1 +1 @@', 'diff --git "a/old name.txt" "b/new name.txt"\nsimilarity index 70%\n--- a/old name.txt\n+++ b/new name.txt');
add('plain unified', '-old\n+new\n', '@@ -1 +1 @@', '--- file.txt\t2026-09-01\n+++ file.txt\t2026-09-02');
add('tab unified header', '-old\n+new\n', '@@ -1 +1 @@', '---\tfile.txt\n+++\tfile.txt');
add('escaped quoted git header', '-old\n+new\n', '@@ -1 +1 @@', 'diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"\n--- "a/caf\\303\\251.txt"\n+++ "b/caf\\303\\251.txt"');
cases.push({ name: 'empty patch', patch: '' });
cases.push({ name: 'non-commit From prose', patch: 'From somebody\nMessage\n' + cases[0].patch + 'From somewhere\nMore prose\n' + cases[1].patch });
cases.push({ name: 'rename metadata precedence', patch: 'diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from actual-old.txt\nrename to actual-new.txt\n' });
add('header-like body', '--- text\n+++ text\n', '@@ -1 +1 @@', '--- file.txt\n+++ file.txt');
add('new file', '+one\n+two\n', '@@ -0,0 +1,2 @@', 'diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt');
add('deleted file', '-one\n-two\n', '@@ -1,2 +0,0 @@', 'diff --git a/old.txt b/old.txt\ndeleted file mode 100644\n--- a/old.txt\n+++ /dev/null');
add('multiple hunks', '-old\n+new\n@@ -10 +11 @@\n-old2\n+new2\n');
cases.push({name: 'pure rename', patch: 'diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n'});
cases.push({name: 'mode only', patch: 'diff --git a/script.sh b/script.sh\nold mode 100644\nnew mode 100755\n'});
cases.push({name: 'binary', patch: 'diff --git a/icon.png b/icon.png\nindex 123abc..456def 100644\nBinary files a/icon.png and b/icon.png differ\n'});
cases.push({name: 'multi commit', patch: 'From abc123 Mon Sep 17 00:00:00 2001\nSubject: first\n\n' + cases[0].patch + 'From def456 Mon Sep 17 00:00:00 2001\nSubject: second\n\n' + cases[1].patch});
const mocks = readFileSync(resolve(root, 'test/mocks.ts'), 'utf8');
for (const match of mocks.matchAll(/export const (\w+)(?:: string)? = `([\s\S]*?)`;/g)) {
  if (match[2].includes('diff --git') && !match[2].includes('${') && !match[2].includes('\\')) cases.push({name: match[1], patch: match[2]});
}
cases.push({name: 'large real patch', patch: readFileSync(resolve(root, '../pierre/apps/demo/src/mocks/diff.patch'), 'utf8')});
for (const c of cases) c.expected = parsePatchFiles(c.patch, 'oracle');
writeFileSync('Tests/ShikiDiffsTests/Fixtures/patch-oracle.json', JSON.stringify(cases, null, 2) + '\n');
console.log(`Wrote ${cases.length} source-generated oracle cases`);
const { trimPatchContext } = await import(resolve(root, 'src/utils/trimPatchContext.ts'));
const trimCases = cases.filter(c => c.name !== 'large real patch').flatMap(c => [0,1,2,10].map(contextSize => ({patch:c.patch, contextSize, expected:trimPatchContext(c.patch, contextSize)})));
writeFileSync('Tests/ShikiDiffsTests/Fixtures/trim-oracle.json', JSON.stringify(trimCases,null,2)+'\n');

const { diffAcceptRejectHunk } = await import(resolve(root, 'src/utils/diffAcceptRejectHunk.ts'));
const resolutions = [];
for (const fixture of cases.slice(0, 24)) {
    const input = (fixture.expected as any)[0]?.files[0];
    if (!input?.hunks[0]?.hunkContent.length) continue;
    for (const action of ['accept', 'reject', 'both']) {
        resolutions.push({name: fixture.name + ' ' + action, input, action, expected: diffAcceptRejectHunk(input, 0, action)});
    }
}
writeFileSync('Tests/ShikiDiffsTests/Fixtures/resolution-oracle.json', JSON.stringify(resolutions, null, 2) + '\n');
console.log(`Wrote ${resolutions.length} resolution cases`);

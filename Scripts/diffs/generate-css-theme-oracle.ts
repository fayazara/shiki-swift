// Run with the path to Shiki v3.13.0 packages/core/src/theme-css-variables.ts.
// That standalone module imports only types and can execute directly in Bun.
import { writeFileSync } from 'node:fs';
const { createCssVariablesTheme } = await import(process.argv[2]);
const cases = [];
for (const fontStyle of [true, false]) {
  for (const variablePrefix of ['--shiki-', '--diffs-', '']) {
    const options = {name: 'theme-😀', variablePrefix, fontStyle,
      variableDefaults: {'foreground': '#abc', 'background': '#12345678', 'token-comment': '', 'token-keyword': 'red'}};
    cases.push({options, expected: createCssVariablesTheme(options)});
  }
}
cases.push({options: {}, expected: createCssVariablesTheme()});
writeFileSync(new URL('../../Tests/ShikiDiffsTests/Fixtures/css-theme-oracle.json', import.meta.url), JSON.stringify(cases, null, 2) + '\n');

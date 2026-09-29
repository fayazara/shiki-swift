# Third-party notices

This native port is source-compatible work derived from and tested against the
following pinned projects and data sets. Their original license texts are kept
with the source or generated resources.

| Component | Pinned version or revision | License location |
| --- | --- | --- |
| Shiki | 4.4.3, `48cd2cc695ed2e3357c3f9c370578ea843d6d9a3` | `LICENSES/Shiki.txt` |
| `@shikijs/vscode-textmate` | 10.0.2, `19dc9b889aa47df91027e857cdad518760b5a026` | `LICENSES/vscode-textmate.txt` |
| `vscode-oniguruma` behavioral reference | 1.7.0, `716aeaa229e4ae2e3b0057377b55743e9a3e995b` | `LICENSES/vscode-oniguruma.txt` |
| Oniguruma native source | 6.9.8, `08d36110c5670c815ad6d6f969e578049d209080` | `Sources/COniguruma/LICENSE.txt` |
| `tm-grammars` assets | 1.32.3 | `Sources/Shiki/Resources/licenses/tm-grammars-LICENSE.txt` and `tm-grammars-NOTICE.txt` |
| `tm-themes` assets | 1.12.3 | `Sources/Shiki/Resources/licenses/tm-themes-LICENSE.txt` and `tm-themes-NOTICE.txt` |
| `@pierre/diffs` (ShikiDiffs) | 1.4.2 | `LICENSES/pierre-diffs-Apache-2.0.txt` |
| jsdiff (ShikiDiffs diff frontier) | 9.0.0, npm SHA-1 `297c31cd7c280f13dfe335791ec2063bd4a73a6f` | `LICENSES/jsdiff-BSD-3-Clause.txt` |
| QuickJS libregexp and libunicode (ShikiDiffs search) | 2026-06-04 | `LICENSES/QuickJS-MIT.txt` and `Sources/CSDRegex/Vendor/LICENSE` |
| Pierre Dark and Pierre Light themes (`@pierre/theme`) | 2.0.0 | `Sources/ShikiDiffs/Resources/Themes/NOTICE.md` |

`Sources/Shiki/Resources/provenance.json` records the upstream source,
revision, hash, byte size, and available per-asset license declaration for each
bundled grammar and theme. Some upstream grammar metadata has no per-asset
license declaration; those gaps are explicit in the provenance file and the
aggregated package notices are retained verbatim.

## ShikiDiffs

ShikiDiffs is a native adaptation of **@pierre/diffs 1.4.2**, Copyright The
Pierre Computer Company and contributors, under Apache-2.0
(https://github.com/pierrecomputer/pierre/tree/main/packages/diffs). The source
snapshot it was checked against is recorded file by file in
`Documentation/Diffs/upstream-manifest.json`.

Its diff frontier is adapted from **jsdiff 9.0.0**, Copyright Kevin Decker and
contributors, under BSD-3-Clause. JavaScript is used only to generate reference
fixtures during development; the library runs in Swift, AppKit, CoreText, this
package's native Shiki/Oniguruma, and the C regex library below.

The bundled **Pierre Dark and Pierre Light** themes come from
**@pierre/theme 2.0.0** under Apache-2.0, built on GitHub's VS Code theme (MIT);
both notices are in `Sources/ShikiDiffs/Resources/Themes/NOTICE.md`.

`Sources/ShikiDiffs/CSSVariablesTheme.swift` ports Shiki's
`theme-css-variables.ts` (v3.13.0) under Shiki's MIT license (`LICENSES/Shiki.txt`).

Editor search uses the standalone **QuickJS libregexp and libunicode
2026-06-04** C libraries, Copyright Fabrice Bellard and Charlie Gordon, under
MIT. Only the regex/Unicode support and C utilities are included; the
JavaScript runtime is not. Unmodified sources and their notice are in
`Sources/CSDRegex/Vendor`; wrapper translation units prefix exported symbols.
Release archive and source hashes are in `Documentation/Diffs/regexp-manifest.json`.

Oracle fixtures in `Tests/ShikiDiffsTests/Fixtures` retain metadata and source
samples from the Apache-licensed Pierre test suite and demo.

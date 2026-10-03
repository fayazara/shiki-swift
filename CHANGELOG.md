# Changelog

All notable changes to ShikiSwift are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); see
[RELEASING.md](RELEASING.md) for what that means before 1.0.

## [Unreleased]

## [0.1.1] - 2026-10-03

### Added

- **ShikiDiffs**: `LineTrailingText` draws faint ghost text after the end of a
  source line, such as inline git blame. Pass it to `FileView(lineTrailingText:)`
  or set `NativeFileView.lineTrailingText` / `NativeDiffView.lineTrailingText`.
  It is painted with the line, so it scrolls and re-renders with the code.

## [0.1.0] - 2026-09-29

The first release: a native Swift port of Shiki 4.4.3, with native rendering
and a native port of @pierre/diffs.

### Added

- **Shiki** (`Shiki`, `ShikiCore`): TextMate grammars, VS Code themes, and a
  native Oniguruma 6.9.8 engine, pinned to Shiki 4.4.3, `@shikijs/vscode-textmate`
  10.0.2, `tm-grammars` 1.32.3, and `tm-themes` 1.12.3.
  - 242 bundled languages, 18 injection grammars, and 65 themes.
  - `codeToTokens` with single or multiple themes, UTF-16 offsets,
    explanations, color replacements, `tokenizeMaxLineLength`, and
    `tokenizeTimeLimit`.
  - Resumable grammar state for incremental and streaming highlighting.
  - Runtime registration of grammars and themes, aliases, embedded-language
    detection, ANSI input, plain text, and the `none` theme.
  - Comment notations (`// [!code ++]`, `--`, `highlight`, `focus`, `error`,
    `warning`, `info`, `word:`) as typed line annotations and word ranges,
    matching `@shikijs/transformers`.
- **ShikiUI**: `AttributedString` and SwiftUI rendering (`ShikiCodeView`), and
  `ShikiVirtualizedCodeView` for macOS, virtualized vertically and, for lines
  over 4,096 characters, horizontally.
- **ShikiDiffs** (macOS): a native port of @pierre/diffs 1.4.2. Split and
  unified diffs with word- or character-level changes, striped empty rows,
  change bars, folded context, file headers, hover and line selection, and
  the Pierre Light and Dark themes; highlighted files, virtualized multi-file
  reviews, merge-conflict resolution, native editing, patches, and streaming.
- A macOS demo app covering every feature, including 16 diff examples.

### Verified

- Token output matches Shiki 4.4.3 exactly on every upstream sample
  (238 languages, all 65 themes, single- and dual-theme, scope explanations:
  110,515 tokens, 0 differences) and notation output matches
  `@shikijs/transformers` on 450 generated cases. The sweep is local; the
  checked-in golden fixtures are a subset.
- ShikiDiffs passes 478 tests, including oracle fixtures recorded from the
  upstream TypeScript.

### Known limitations

- Shiki's HTML layer (`codeToHtml`, `codeToHast`, HAST transformer hooks) is
  out of scope for this native SDK. Decorations, a token-level transformer
  protocol, and notation rendering in ShikiUI are not available yet.
- ShikiDiffs' line diff (ported from jsdiff) grows faster than linearly with
  file size: about 3 s for two 100,000-line files in a Release build.
- ShikiDiffs' AppKit tests should run sequentially (`--no-parallel`).

[Unreleased]: https://github.com/fayazara/shiki-swift/compare/0.1.1...HEAD
[0.1.1]: https://github.com/fayazara/shiki-swift/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/fayazara/shiki-swift/releases/tag/0.1.0

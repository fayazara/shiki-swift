# ShikiSwift

A native Swift port of [Shiki](https://shiki.style): TextMate grammars, VS Code
themes, and Oniguruma tokenization without JavaScript, WebAssembly, or a web
view at runtime.

<img width="1728" height="1084" alt="Screendrop_2026-08-14-23-08-39" src="https://github.com/user-attachments/assets/1adc95b4-5480-4fb2-92ea-5e8ea8d1628c" />

ShikiSwift is pinned to **Shiki 4.4.3** and its exact tokenizer and asset
dependencies. For everything it implements, it produces the same tokens as
Shiki, byte for byte (see [Parity with Shiki](#parity-with-shiki)).

- 242 bundled languages (plus 18 injection grammars) and 65 VS Code themes
- Single- and multi-theme tokens with UTF-16 offsets, exactly like Shiki
- Resumable grammar state for incremental and streaming highlighting
- Runtime registration of your own grammars and themes
- `AttributedString` and SwiftUI rendering, plus a virtualized macOS code view
  that stays smooth on 100k-line files and 200k-character minified lines

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Usage](#usage)
- [Long lines and time limits](#long-lines-and-time-limits)
- [Performance](#performance)
- [Parity with Shiki](#parity-with-shiki)
- [Demo app](#demo-app)
- [Package products](#package-products)
- [Verification](#verification)
- [Upstream pins and licensing](#upstream-pins-and-licensing)

## Installation

Add the package with Swift Package Manager (Swift 6.1+):

```swift
dependencies: [
    .package(url: "https://github.com/fayazara/shiki-swift.git", branch: "main"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "Shiki", package: "shiki-swift"),
            .product(name: "ShikiUI", package: "shiki-swift"), // optional
        ]
    ),
]
```

In Xcode, use **File ▸ Add Package Dependencies…** with the same URL.

Supported platforms: macOS 13+, iOS/tvOS 16+, watchOS 9+, and visionOS 1+.
`ShikiVirtualizedCodeView` is macOS only.

## Quick start

```swift
import Shiki
import ShikiUI
import SwiftUI

let highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
let result = try highlighter.codeToTokens(
    "let greeting = \"Hello, Swift!\"",
    language: "swift"
)

for line in result.tokens {
    for token in line {
        print(token.content, token.color ?? "default")
    }
}

// Render it.
let attributed = result.attributedString()   // AttributedString
let view = ShikiCodeView(result: result)     // SwiftUI view
```

Create one `ShikiHighlighter` and reuse it: it caches compiled grammars, regex
scanners, and themes. It is thread-safe, and highlighting is synchronous, so
run large inputs off the main actor and publish the result to your UI.

Language names accept Shiki's ids and aliases (`ts`, `js`, `sh`, …), plus
`text`/`plaintext` and `ansi`. Theme names are Shiki's ids (`github-light`,
`one-dark-pro`, `vitesse-dark`, …). Browse them through
`BundledShikiAssets.shared.languages` and `.themes`.

## Usage

### Single theme and continuation

```swift
import Shiki

let highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
let first = try highlighter.codeToTokens(
    "/* starts here",
    language: "javascript",
    theme: "github-dark"
)

let next = try highlighter.codeToTokens(
    "and ends here */ const ready = true",
    language: "javascript",
    theme: "github-dark",
    grammarState: first.grammarState
)

print(next.tokens[0].map(\.content))
```

`TokensResult.grammarState` can be passed directly into a later call to continue
an open TextMate construct. Its Codable representation preserves Shiki's public
`lang`, `theme`, `themes`, and `scopes` snapshot; a decoded snapshot is metadata,
not a resumable native tokenizer stack.

### Multiple themes

Multi-theme tokenization aligns every theme at the same UTF-16 boundaries. Each
token stores its styles by `colorName`, and `highlightWithThemes` returns one
continuation state containing the stack for every underlying theme.

```swift
let themes: [ShikiThemeVariant] = [
    .init(colorName: "light", themeName: "github-light"),
    .init(colorName: "dark", themeName: "github-dark"),
]

let first = try highlighter.highlightWithThemes(
    "/* starts here",
    language: "javascript",
    themes: themes
)

let token = first.tokens[0][0]
print(token.variants["light"]?.color as Any)
print(token.variants["dark"]?.color as Any)

let next = try highlighter.highlightWithThemes(
    "and ends here */",
    language: "javascript",
    themes: themes,
    grammarState: first.grammarState
)
```

Use `codeToTokensWithThemes` when only the aligned tokens are needed.

### Runtime theme and language registration

Raw VS Code themes and TextMate grammars can be decoded or constructed at
runtime and registered without rebuilding the package:

```swift
let theme = ShikiTheme(
    name: "app-dark",
    type: .dark,
    settings: [
        .init(settings: .init(foreground: "#D8DEE9", background: "#20242C")),
        .init(
            scope: .string("keyword"),
            settings: .init(foreground: "#FF7AB2")
        ),
    ],
    foreground: "#D8DEE9",
    background: "#20242C"
)
try highlighter.registerTheme(theme)

let language = LanguageRegistration(
    name: "spark",
    grammar: RawGrammar(
        scopeName: "source.spark",
        patterns: [.init(name: "keyword.spark", match: #"\bignite\b"#)]
    ),
    aliases: ["sp"]
)
try highlighter.registerLanguage(language)

let custom = try highlighter.codeToTokens(
    "ignite",
    language: "sp",
    theme: "app-dark"
)
```

`loadTheme(s)`, `registerTheme(s)`, `loadLanguage(s)`, and
`registerLanguage(s)` also accept batches and resolved themes. Language batches
can declare custom or bundled embedded dependencies and injection targets.

### Terminal output (ANSI)

`language: "ansi"` parses SGR escape codes (16 colors, 256 colors, true color,
bold, dim, italic, underline, reverse) and maps them to the theme's
`terminal.ansi*` colors, like Shiki:

```swift
let log = try highlighter.codeToTokens("\u{1B}[32m✔ passed\u{1B}[0m", language: "ansi")
```

### Native presentation

On Apple platforms, `ShikiUI` turns a `TokensResult` into an `AttributedString`
or a horizontally scrolling SwiftUI view:

```swift
import ShikiUI

let result = try highlighter.codeToTokens(
    "let greeting = \"Hello, Swift!\"",
    language: "swift"
)
let attributed = result.attributedString()
let view = ShikiCodeView(result: result)
```

### Large documents in macOS apps

Use `ShikiVirtualizedCodeView` for a read-only, selectable code preview with a
fixed viewport height. It is part of the `ShikiUI` library and can be embedded
in any macOS SwiftUI app; it does not depend on the demo app.

```swift
import SwiftUI
import Shiki
import ShikiUI

struct CodePreview: View {
    let result: TokensResult
    let revision: Int

    var body: some View {
        ShikiVirtualizedCodeView(
            result: result,
            renderID: revision,
            font: .monospacedSystemFont(ofSize: 15, weight: .regular),
            contentPadding: 16,
            viewportHeight: 500
        )
    }
}
```

Increment `revision` when replacing the tokens, including after a source,
language, or theme change. Keep it stable during unrelated SwiftUI updates;
creating a new UUID on every render would reset the document unnecessarily.
Updates with the same ID and font preserve selection and scroll position.
Replacing the result or changing the font resets them.

The view provides vertical and horizontal scrolling, unwrapped lines, mouse
selection with drag autoscroll, keyboard selection, Select All, plain-text
copying, and accessibility text/selection ranges. Selection uses full-document
coordinates, so it survives viewport changes and can include offscreen text.

The view is virtualized in both directions:

- **Vertically**, TextKit receives only the visible lines plus a 16-line buffer
  on either side. Distant jumps replace that window directly, without styling or
  laying out the lines in between.
- **Horizontally**, lines longer than 4,096 UTF-16 units are sliced: only the
  visible columns plus about one viewport width on either side enter TextKit,
  placed at their exact x positions. A 200k-character minified line never
  becomes one enormous TextKit line fragment.

Paragraph styling is cached with limits of 256 entries and 262,144 UTF-16 units.
Scrolling work therefore depends on what is on screen, not on the size of the
file or the length of its lines.

Choose the presentation API for your use case:

| API | Use case | Platforms |
| --- | --- | --- |
| `ShikiVirtualizedCodeView` | Large, selectable documents in a fixed-height scrolling viewport | macOS |
| `ShikiCodeView` | Small, intrinsically sized SwiftUI code snippets | Supported Apple platforms |
| `result.attributedString()` | A complete attributed string for your own text view | Supported Apple platforms |
| `ShikiAttributedStringRenderer.render(_:lines:)` | Attributes for a range of token rows in a custom renderer | Supported Apple platforms |

## Long lines and time limits

Shiki stops tokenizing a line after `tokenizeTimeLimit` milliseconds (default
**500**) and emits the rest of that line as one plain token. ShikiSwift does
the same, so very long lines such as minified bundles may be only partially
highlighted. This is Shiki's behavior, not a porting difference: for a
195k-character minified JavaScript line, Shiki 4.4.3 in Node highlights 28
tokens before the limit, and ShikiSwift (Release) highlights 35.

Most of that time goes on the first few dozen tokens, because each regex's first
search scans ahead through the whole line. To highlight such lines completely,
disable or raise the limit, or cap the line length instead:

```swift
let full = try highlighter.codeToTokens(
    minified,
    language: "javascript",
    options: .init(tokenizeTimeLimit: 0)       // no limit: whole line highlighted
)

let capped = try highlighter.codeToTokens(
    minified,
    language: "javascript",
    options: .init(tokenizeMaxLineLength: 20_000) // longer lines stay plain
)
```

With no limit, the full 195k-character line takes about 1.8 s in a Release
build (Shiki in Node: about 3.2 s).

## Performance

Measure performance in **Release** builds. Debug builds compile Oniguruma and
the tokenizer without optimizations and are 10× or more slower, which also
makes lines hit the time limit much sooner.

Local measurements (Apple silicon; not guarantees):

| Scenario | Result |
| --- | --- |
| Warm highlight of a 256 KB JSON file (5,544 lines, 20,592 tokens) | ~131–136 ms Release, ~1.6 s Debug |
| 2,000-line scroll jump in `ShikiVirtualizedCodeView` (same file) | ~2.5 ms, 66 paragraphs styled (was 105 ms / 1,977) |
| Horizontal scroll step across a fully highlighted 200k-character line, drawn on screen | ~2.5 ms median, 4.6 ms p95 (was ~443 ms) |
| Full tokenization of a 195k-character minified JS line, no time limit | ~1.8 s (Shiki in Node: ~3.2 s) |

Virtualization bounds text layout and styling work. The source and tokens are
still retained in full, and `codeToTokens` still tokenizes the entire input. The
view does not provide progressive tokenization or incremental editing. Use
`grammarState` continuation to tokenize incrementally yourself.

To measure scroll/layout work against your own file on macOS:

```sh
Scripts/benchmark-scroll.sh /path/to/file.json json
```

With no arguments, the script uses a generated 10,000-line Swift document. It
builds in Release and reports scroll/layout times, newly styled paragraphs per
jump, and cache size. It uses a hidden AppKit window and excludes painting and
actual display FPS. Use `Scripts/benchmark.sh` (or
`swift run -c release shiki-benchmark [filter]`) to measure tokenization and
attributed-string preparation separately.

The scanner uses the pinned upstream RegSet path for short strings and caches
pattern-search results within longer immutable lines. Capture buffers and
rendering styles are reused. Search-cache invalidation preserves input identity,
search-option changes, backward searches, and position-sensitive `\G` patterns.

Offsets in `ThemedToken` use UTF-16 code units, exactly like JavaScript strings
and `vscode-textmate`. Use `String.utf16` or `NSRange` when mapping them back to
Swift strings.

## Parity with Shiki

### Differential sweep

Every upstream sample from
[`shikijs/textmate-grammars-themes`](https://github.com/shikijs/textmate-grammars-themes/tree/main/samples)
was tokenized with Shiki 4.4.3 in Node and with ShikiSwift, then compared token
by token (time limit disabled on both sides):

| Comparison | Cases | Tokens | Differences |
| --- | --- | --- | --- |
| Single theme: content, UTF-16 offset, color, font style, result `fg`/`bg` (238 languages; every sample with `github-dark` and one of the 65 themes in rotation) | 472 | 70,113 | **0** |
| Dual theme (`light` + `dark`): per-token CSS-variable `htmlStyle` | 238 | 40,402 | **0** |
| Scope explanations (`includeExplanation: .scopeName`) | 238 | 40,402 | **0** |

This sweep was run locally and is not part of `swift test`; the checked-in
differential fixture below is smaller.

### Implemented

- Native Oniguruma 6.9.8 with the UTF-16/UTF-8 bridge used by Shiki.
- The `vscode-textmate` rule compiler, scope selector, theme trie, state stack,
  injections, captures, begin/end, begin/while, backreferences, anchors, and
  zero-width safeguards.
- Shiki theme normalization, font styles, CSS-variable color replacements, and
  VS Code `tokenColors`/TextMate `settings` themes.
- 242 directly highlightable bundled languages, 18 injection grammars,
  aliases, embedded-language dependencies and detection, and 65 VS Code themes.
- Runtime registration of raw or resolved themes and TextMate languages,
  including batches, aliases, dependencies, and injections.
- Persistent single-theme grammar state exposed on `TokensResult`, including
  Shiki-compatible public state metadata and continuation validation.
- UTF-16-aligned multi-theme tokens with per-theme styles and token types,
  `defaultColor` (including `light-dark()`), CSS-variable prefixes, optional
  first-theme explanations, and a continuation stack for every underlying theme.
- Shiki-compatible token options: explanations, per-line time limits, maximum
  line length, context priming (`grammarContextCode`), and color replacements.
- ANSI input (`language: "ansi"`), plain text, and the `none` theme.
- Native `AttributedString` and SwiftUI rendering, including foreground,
  background, bold, italic, underline, and strikethrough styles.

### Not yet ported

Shiki's HTML layer is not ported yet. It is kept separate from the native
tokenization core instead of being approximated:

- `codeToHtml` / `codeToHast` and their rendering options (`mergeWhitespaces`,
  `mergeSameStyleTokens`, `structure`, `tabindex`, `rootStyle` output)
- Transformers, including `@shikijs/transformers` notations such as
  `// [!code ++]`, focus, and highlight
- Decorations

Browser-specific parts of Shiki (the JavaScript regex engine, WASM loading,
bundle factories) have no equivalent here because Oniguruma runs natively.

## Demo app

`shiki-swift.xcodeproj` contains a macOS demo app (requires Xcode 26 and
macOS 26.4). It restyles its whole window from the selected VS Code theme, and
follows the system light/dark appearance by default with a separate light and
dark theme (toolbar and **Theme** menu, ⇧⌘L to toggle).

| Screen | Shows |
| --- | --- |
| Playground | Live, debounced highlighting of any input in any bundled language; copy as HTML, JSON tokens, or plain text |
| Languages / Themes | Galleries of every bundled grammar and theme |
| Light & Dark | Multi-theme tokens rendered as light and dark variants |
| Diffs & Focus | Diff, highlight, and focus line annotations built on tokens |
| Docs & Markdown | Markdown with embedded fenced languages |
| Terminal (ANSI) | ANSI escape codes mapped to theme terminal colors |
| Streaming Chat | Incremental highlighting with `grammarState` continuation |
| Token Inspector | Scopes and matching theme rules for each token |
| Large Files | Timed tokenization of up to 100k lines or a 200k-character minified line in `ShikiVirtualizedCodeView`, with Shiki's 500 ms line limit toggle |

Build it in the **Release** configuration to judge performance.

## Package products

- `ShikiCore`: Oniguruma and the TextMate/theme/token runtime.
- `Shiki`: the high-level highlighter and bundled Shiki assets.
- `ShikiUI`: optional SwiftUI and `AttributedString` adapters, including the
  virtualized macOS code viewport.

## Verification

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The native view tests mount a 10,000-line document and check lazy initial
styling, bounded caches, bounded work on distant scroll jumps, resizing, global
selection, keyboard/mouse interaction, accessibility ranges, and cache
invalidation. Long-line tests check that only a horizontal slice enters TextKit,
that columns land at their exact x positions (including non-ASCII text and
tabs), and that selection and copy still cover the whole line. A rendered-pixel
regression test checks highlighting after rapid scroll reversals. The clipboard
test skips when the environment has no macOS pasteboard service.

An exact checked-in Shiki 4.4.3 differential fixture covers eight representative
language/theme pairs: TypeScript/vitesse-dark, JSON/github-light, Python/nord,
CSS/dark-plus, HTML/github-dark, Bash/min-dark, Rust/rose-pine, and
YAML/github-dark. Its 185 tokens are compared line by line for content, absolute
UTF-16 offset, color, font style, token type, and result `fg`, `bg`, and
`themeName`.

Separate coverage compiles all 65 bundled normalized themes with usable
defaults. A full execution smoke test compiles and tokenizes every one of the
242 directly highlightable grammars, with all 18 injection registrations
loaded, and verifies exact source reconstruction at contiguous UTF-16 offsets.
The suite also includes Shiki's 254 recorded Oniguruma WASM scanner cases,
direct `@shikijs/vscode-textmate` oracle comparisons, grammar-state and
multi-theme continuation, UTF-16 edge cases, bundled asset decoding, and the
native rendering adapters.

The asset importer is deterministic and offline. See
[`Scripts/README.md`](Scripts/README.md) for regeneration and integrity checks.

## Upstream pins and licensing

| Component | Pin |
| --- | --- |
| Shiki | 4.4.3 / `48cd2cc695ed2e3357c3f9c370578ea843d6d9a3` |
| `@shikijs/vscode-textmate` | 10.0.2 / `19dc9b889aa47df91027e857cdad518760b5a026` |
| `vscode-oniguruma` reference | 1.7.0 / `716aeaa229e4ae2e3b0057377b55743e9a3e995b` |
| Oniguruma | 6.9.8 / `08d36110c5670c815ad6d6f969e578049d209080` |
| `tm-grammars` | 1.32.3 |
| `tm-themes` | 1.12.3 |

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), [`LICENSES`](LICENSES),
and the generated resource provenance for the retained upstream notices.

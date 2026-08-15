# ShikiSwift

A native Swift port of [Shiki](https://shiki.style): TextMate grammars, VS Code
themes, and Oniguruma tokenization without JavaScript, WebAssembly, or a web
view at runtime.

<img width="1728" height="1084" alt="Screendrop_2026-08-14-23-08-39" src="https://github.com/user-attachments/assets/1adc95b4-5480-4fb2-92ea-5e8ea8d1628c" />


This repository contains a native, source-faithful tokenization and presentation
slice of Shiki. It is pinned to Shiki 4.4.3 and its exact tokenizer and asset
dependencies.

## Use it

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

Offsets in `ThemedToken` use UTF-16 code units, exactly like JavaScript strings
and `vscode-textmate`. Use `String.utf16` or `NSRange` when mapping them back to
Swift strings.

## What works today

- Native Oniguruma 6.9.8 with the UTF-16/UTF-8 bridge used by Shiki.
- The `vscode-textmate` rule compiler, scope selector, theme trie, state stack,
  injections, captures, begin/end, begin/while, backreferences, anchors, and
  zero-width safeguards.
- Shiki theme normalization, font styles, CSS-variable color replacements, and
  VS Code `tokenColors`/TextMate `settings` themes.
- 242 directly highlightable bundled languages, 18 injection grammars,
  aliases, embedded-language dependencies, and 65 VS Code themes.
- Runtime registration of raw or resolved themes and TextMate languages,
  including batches, aliases, dependencies, and injections.
- Persistent single-theme grammar state exposed on `TokensResult`, including
  Shiki-compatible public state metadata and continuation validation.
- UTF-16-aligned multi-theme tokens with per-theme styles and token types,
  optional first-theme explanations, and a continuation stack for every
  underlying theme.
- Shiki-compatible token options for explanations, per-line time limits,
  maximum line length, context priming, and color replacement.
- Native `AttributedString` and SwiftUI rendering, including foreground,
  background, bold, italic, underline, and strikethrough styles.

This is not yet Shiki's entire public surface. The remaining 1:1 work includes
decorations and transformer hooks, ANSI input, and Shiki's HAST/HTML rendering
layer. Those remain separate from the native tokenization core instead of being
approximated.

## Package products

- `ShikiCore` — Oniguruma and the TextMate/theme/token runtime.
- `Shiki` — the high-level highlighter and bundled Shiki assets.
- `ShikiUI` — optional SwiftUI and `AttributedString` adapters.

The package supports macOS 13+, iOS/tvOS 16+, watchOS 9+, and visionOS 1+.

## Verification

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

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

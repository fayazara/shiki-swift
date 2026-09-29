import Foundation
import Shiki

/// One reusable highlighter shared by every screen. The actor keeps work off
/// the main thread; ShikiHighlighter itself serializes calls on one instance.
actor DemoEngine {
    static let shared = DemoEngine()

    private var cached: ShikiHighlighter?

    private func highlighter() throws -> ShikiHighlighter {
        if let cached { return cached }
        let created = try ShikiHighlighter(defaultTheme: "github-dark")
        cached = created
        return created
    }

    func tokens(
        _ code: String,
        language: String,
        theme: String,
        options: TokenizeWithThemeOptions = .init()
    ) throws -> TokensResult {
        try Task.checkCancellation()
        return try highlighter().codeToTokens(code, language: language, theme: theme, options: options)
    }

    /// Tokens plus the grammar state at the end of `code`, optionally resuming
    /// from an earlier state. This is what makes incremental highlighting work.
    func highlight(
        _ code: String,
        language: String,
        theme: String,
        resumingFrom state: ShikiGrammarState?
    ) throws -> ShikiHighlightResult {
        try highlighter().highlight(code, language: language, theme: theme, grammarState: state)
    }

    /// One tokenization pass that carries colors for every theme variant.
    func variants(
        _ code: String,
        language: String,
        themes: [ShikiThemeVariant]
    ) throws -> [[ThemedTokenWithVariants]] {
        try highlighter().codeToTokensWithThemes(code, language: language, themes: themes)
    }

    /// Shiki's multi-theme `codeToTokens`, flattened to CSS declarations.
    func cssVariableTokens(
        _ code: String,
        language: String,
        themes: [ShikiThemeVariant]
    ) throws -> TokensResult {
        try highlighter().codeToTokens(code, language: language, themes: themes)
    }

    /// Timed highlight used by the performance screen.
    func timedTokens(
        _ code: String,
        language: String,
        theme: String,
        options: TokenizeWithThemeOptions = .init()
    ) throws -> (TokensResult, Duration) {
        let clock = ContinuousClock()
        var result: TokensResult?
        let elapsed = try clock.measure {
            result = try highlighter().codeToTokens(code, language: language, theme: theme, options: options)
        }
        return (result!, elapsed)
    }
}

/// Grammar languages sorted for pickers, with common ones first.
nonisolated enum DemoLanguages {
    static let popular = [
        "swift", "typescript", "tsx", "javascript", "python", "rust", "go", "kotlin",
        "java", "c", "cpp", "csharp", "ruby", "php", "html", "css", "json", "yaml",
        "markdown", "sql", "shellscript",
    ]

    static let all: [ShikiLanguageInfo] = BundledShikiAssets.shared.languages
        .filter { $0.kind == .grammar }
        .sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }

    static func name(_ info: ShikiLanguageInfo) -> String { info.displayName ?? info.id }

    static func name(for id: String) -> String {
        BundledShikiAssets.shared.languages.first { $0.id == id }.map(name) ?? id
    }
}

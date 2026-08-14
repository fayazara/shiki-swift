import Foundation

/// Guesses embedded language identifiers from source text using the same
/// patterns as Shiki's full-bundle singleton shorthands.
///
/// The result preserves first-seen order and removes exact duplicates. It is
/// intentionally not limited to bundled languages; `ShikiHighlighter` applies
/// that validation before loading detected grammars.
public func guessEmbeddedLanguages(_ code: String) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []

    func append(_ value: String) {
        let language = value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty, seen.insert(language).inserted {
            result.append(language)
        }
    }

    for capture in EmbeddedLanguagePatterns.captures(
        in: code,
        matching: EmbeddedLanguagePatterns.languageAttribute
    ) {
        append(capture)
    }
    for capture in EmbeddedLanguagePatterns.captures(
        in: code,
        matching: EmbeddedLanguagePatterns.codeFence
    ) {
        append(capture)
    }
    for capture in EmbeddedLanguagePatterns.captures(
        in: code,
        matching: EmbeddedLanguagePatterns.latexEnvironment
    ) {
        append(capture)
    }
    for capture in EmbeddedLanguagePatterns.captures(
        in: code,
        matching: EmbeddedLanguagePatterns.scriptLanguage
    ) {
        let normalized = capture
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        append(normalized.components(separatedBy: "/").last ?? normalized)
    }

    if EmbeddedLanguagePatterns.frontmatter.firstMatch(
        in: code,
        range: NSRange(code.startIndex..<code.endIndex, in: code)
    ) != nil {
        append("yaml")
    }
    return result
}

private enum EmbeddedLanguagePatterns {
    static let languageAttribute = expression(#":?lang=["']([^"']+)["']"#)
    static let codeFence = expression(#"(?:```|~~~)([A-Za-z0-9_-]+)"#)
    static let latexEnvironment = expression(#"\\begin\{([A-Za-z0-9_-]+)\}"#)
    static let scriptLanguage = expression(
        #"<script\s+(?:type|lang)=["']([^"']+)["']"#,
        options: .caseInsensitive
    )
    static let frontmatter = expression(
        #"^\s*---\r?\n[\s\S]*?\r?\n---(?:\r?\n|\s*$)"#
    )

    static func captures(
        in source: String,
        matching expression: NSRegularExpression
    ) -> [String] {
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: sourceRange).compactMap { match in
            guard
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: source)
            else { return nil }
            return String(source[range])
        }
    }

    private static func expression(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        // These are source-controlled constant expressions. Failure is a
        // programmer error and should surface immediately in development.
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}

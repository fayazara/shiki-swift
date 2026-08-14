import Foundation

/// One Shiki token carrying a named style variant for every requested theme.
public struct ThemedTokenWithVariants: Codable, Equatable, Sendable {
    public var content: String

    /// Absolute zero-based UTF-16 offset into the original source.
    public var offset: Int

    public var type: StandardTokenType?
    public var explanation: [ThemedTokenExplanation]?
    public var variants: [String: TokenStyles]

    public init(
        content: String,
        offset: Int,
        type: StandardTokenType? = nil,
        explanation: [ThemedTokenExplanation]? = nil,
        variants: [String: TokenStyles]
    ) {
        self.content = content
        self.offset = offset
        self.type = type
        self.explanation = explanation
        self.variants = variants
    }

    public init(base: TokenBase, variants: [String: TokenStyles]) {
        self.init(
            content: base.content,
            offset: base.offset,
            type: base.type,
            explanation: base.explanation,
            variants: variants
        )
    }

    public var base: TokenBase {
        TokenBase(
            content: content,
            offset: offset,
            type: type,
            explanation: explanation
        )
    }
}

/// A single-theme token grid associated with its multi-theme variant name.
///
/// `name` is the caller-facing key such as `light` or `dark`, rather than the
/// underlying VS Code theme registration name.
public struct NamedThemeTokenization: Codable, Equatable, Sendable {
    public var name: String
    public var tokens: [[ThemedToken]]

    public init(name: String, tokens: [[ThemedToken]]) {
        self.name = name
        self.tokens = tokens
    }
}

/// Invalid input supplied to Shiki's multi-theme token alignment layer.
public enum MultiThemeTokenizationError:
    Error, Equatable, Sendable, CustomStringConvertible
{
    case noThemes
    case duplicateVariantName(String)
    case lineCountMismatch(theme: Int, expected: Int, actual: Int)
    case lineContentMismatch(theme: Int, line: Int)
    case lineStartOffsetMismatch(
        theme: Int,
        line: Int,
        expected: Int,
        actual: Int
    )
    case discontinuousTokenOffset(
        theme: Int,
        line: Int,
        token: Int,
        expected: Int,
        actual: Int
    )
    case incompatibleEmptyTokens(theme: Int, line: Int)
    case tokenStreamEndedEarly(theme: Int, line: Int)

    public var description: String {
        switch self {
        case .noThemes:
            "At least one theme is required to align theme tokenization."
        case let .duplicateVariantName(name):
            "Theme variant name \(String(reflecting: name)) occurs more than once."
        case let .lineCountMismatch(theme, expected, actual):
            "Theme \(theme) contains \(actual) lines; expected \(expected)."
        case let .lineContentMismatch(theme, line):
            "Theme \(theme), line \(line) does not contain the same source text as theme 0."
        case let .lineStartOffsetMismatch(theme, line, expected, actual):
            "Theme \(theme), line \(line) starts at UTF-16 offset \(actual); expected \(expected)."
        case let .discontinuousTokenOffset(theme, line, token, expected, actual):
            "Theme \(theme), line \(line), token \(token) starts at UTF-16 offset \(actual); expected \(expected)."
        case let .incompatibleEmptyTokens(theme, line):
            "Theme \(theme), line \(line) has an empty-token shape incompatible with theme 0."
        case let .tokenStreamEndedEarly(theme, line):
            "Theme \(theme), line \(line) ended before the other aligned theme streams."
        }
    }
}

/// Breaks multiple themes' tokens at the union of all token boundaries.
///
/// This is the native port of Shiki's `alignThemesTokenization`. Content
/// lengths, slices, and offsets deliberately use UTF-16 code units. Styles,
/// token types, and explanations are retained on every split fragment.
public func alignThemesTokenization(
    _ themes: [[[ThemedToken]]]
) throws -> [[[ThemedToken]]] {
    try validateThemeTokenizations(themes)

    var output = themes.map { _ in [[ThemedToken]]() }
    let themeCount = themes.count
    let lineCount = themes[0].count

    for lineIndex in 0..<lineCount {
        let lines = themes.map { $0[lineIndex] }
        var outputLines = themes.map { _ in [ThemedToken]() }

        // A grammar-backed theme represents an empty source line as `[]`,
        // while `none`/plain themes represent it as one empty token. Upstream
        // stops alignment as soon as any current stream is absent, yielding an
        // empty line for every theme in this mixed case.
        if lines.contains(where: \.isEmpty) {
            for themeIndex in 0..<themeCount {
                output[themeIndex].append(outputLines[themeIndex])
            }
            continue
        }

        var indexes = Array(repeating: 0, count: themeCount)
        var current: [ThemedToken?] = lines.map(\.first)

        while current.allSatisfy({ $0 != nil }) {
            let lengths = current.map { utf16Length($0!.content) }
            guard let minimumLength = lengths.min() else { break }

            for themeIndex in 0..<themeCount {
                guard let token = current[themeIndex] else {
                    throw MultiThemeTokenizationError.tokenStreamEndedEarly(
                        theme: themeIndex,
                        line: lineIndex
                    )
                }

                if lengths[themeIndex] == minimumLength {
                    outputLines[themeIndex].append(token)
                    indexes[themeIndex] += 1
                    let nextIndex = indexes[themeIndex]
                    current[themeIndex] = lines[themeIndex].indices.contains(nextIndex)
                        ? lines[themeIndex][nextIndex]
                        : nil
                } else {
                    let pieces = splitToken(token, atUTF16Offset: minimumLength)
                    outputLines[themeIndex].append(pieces.prefix)
                    current[themeIndex] = pieces.suffix
                }
            }
        }

        if let unfinishedTheme = current.firstIndex(where: { $0 != nil }) {
            throw MultiThemeTokenizationError.tokenStreamEndedEarly(
                theme: unfinishedTheme,
                line: lineIndex
            )
        }

        for themeIndex in 0..<themeCount {
            output[themeIndex].append(outputLines[themeIndex])
        }
    }

    return output
}

/// Aligns named theme token grids and merges their visual fields into variants.
///
/// The first theme supplies content, offset, and optional explanation. In
/// Shiki 4.4.3's runtime shape, token type is carried inside each variant's
/// `TokenStyles` rather than on the merged token base.
public func mergeThemesTokenization(
    _ themes: [NamedThemeTokenization],
    includeExplanation: Bool = false
) throws -> [[ThemedTokenWithVariants]] {
    guard !themes.isEmpty else {
        throw MultiThemeTokenizationError.noThemes
    }

    var seenNames: Set<String> = []
    for theme in themes where !seenNames.insert(theme.name).inserted {
        throw MultiThemeTokenizationError.duplicateVariantName(theme.name)
    }

    let aligned = try alignThemesTokenization(themes.map(\.tokens))
    return aligned[0].enumerated().map { lineIndex, line in
        line.enumerated().map { tokenIndex, firstToken in
            var variants: [String: TokenStyles] = [:]
            variants.reserveCapacity(themes.count)
            for themeIndex in themes.indices {
                variants[themes[themeIndex].name] =
                    aligned[themeIndex][lineIndex][tokenIndex].styles
            }

            return ThemedTokenWithVariants(
                content: firstToken.content,
                offset: firstToken.offset,
                type: nil,
                explanation: includeExplanation
                    ? firstToken.explanation
                    : nil,
                variants: variants
            )
        }
    }
}

private func validateThemeTokenizations(
    _ themes: [[[ThemedToken]]]
) throws {
    guard let referenceTheme = themes.first else {
        throw MultiThemeTokenizationError.noThemes
    }

    for themeIndex in themes.indices where themes[themeIndex].count != referenceTheme.count {
        throw MultiThemeTokenizationError.lineCountMismatch(
            theme: themeIndex,
            expected: referenceTheme.count,
            actual: themes[themeIndex].count
        )
    }

    for lineIndex in referenceTheme.indices {
        let referenceLine = referenceTheme[lineIndex]
        let referenceContent = referenceLine.flatMap { Array($0.content.utf16) }
        let referenceStart = referenceLine.first?.offset

        for themeIndex in themes.indices {
            let line = themes[themeIndex][lineIndex]
            try validateOffsets(
                line,
                themeIndex: themeIndex,
                lineIndex: lineIndex
            )

            let content = line.flatMap { Array($0.content.utf16) }
            guard content == referenceContent else {
                throw MultiThemeTokenizationError.lineContentMismatch(
                    theme: themeIndex,
                    line: lineIndex
                )
            }

            if let referenceStart, let actualStart = line.first?.offset,
               actualStart != referenceStart
            {
                throw MultiThemeTokenizationError.lineStartOffsetMismatch(
                    theme: themeIndex,
                    line: lineIndex,
                    expected: referenceStart,
                    actual: actualStart
                )
            }

            let emptyShape = line.map { utf16Length($0.content) == 0 }
            if referenceContent.isEmpty, line.count > 1 {
                throw MultiThemeTokenizationError.incompatibleEmptyTokens(
                    theme: themeIndex,
                    line: lineIndex
                )
            }
            if !referenceContent.isEmpty, emptyShape.contains(true) {
                throw MultiThemeTokenizationError.incompatibleEmptyTokens(
                    theme: themeIndex,
                    line: lineIndex
                )
            }
        }
    }
}

private func validateOffsets(
    _ line: [ThemedToken],
    themeIndex: Int,
    lineIndex: Int
) throws {
    guard var expectedOffset = line.first?.offset else { return }

    for (tokenIndex, token) in line.enumerated() {
        guard token.offset == expectedOffset else {
            throw MultiThemeTokenizationError.discontinuousTokenOffset(
                theme: themeIndex,
                line: lineIndex,
                token: tokenIndex,
                expected: expectedOffset,
                actual: token.offset
            )
        }
        expectedOffset += utf16Length(token.content)
    }
}

private func splitToken(
    _ token: ThemedToken,
    atUTF16Offset offset: Int
) -> (prefix: ThemedToken, suffix: ThemedToken) {
    let units = Array(token.content.utf16)
    precondition(offset >= 0 && offset < units.count)

    var prefix = token
    prefix.content = String(decoding: units[..<offset], as: UTF16.self)

    var suffix = token
    suffix.content = String(decoding: units[offset...], as: UTF16.self)
    suffix.offset += offset
    return (prefix, suffix)
}

private func utf16Length(_ value: String) -> Int {
    value.utf16.count
}

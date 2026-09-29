import Foundation

/// One Shiki token carrying a named style variant for every requested theme.
public struct ThemedTokenWithVariants: Equatable, Sendable {
    public var content: String

    /// Absolute zero-based UTF-16 offset into the original source.
    public var offset: Int

    public var type: StandardTokenType?
    public var explanation: [ThemedTokenExplanation]?
    public var variants: [String: TokenStyles] {
        didSet { variantNames = Self.reconcile(variantNames, with: variants) }
    }

    /// Variant names in the caller's theme order. JavaScript objects keep
    /// insertion order and renderers treat the first entry as the default
    /// color, so this order is preserved here and when encoding.
    public private(set) var variantNames: [String]

    public init(
        content: String,
        offset: Int,
        type: StandardTokenType? = nil,
        explanation: [ThemedTokenExplanation]? = nil,
        variants: [String: TokenStyles],
        variantNames: [String]? = nil
    ) {
        self.content = content
        self.offset = offset
        self.type = type
        self.explanation = explanation
        self.variants = variants
        self.variantNames = Self.reconcile(variantNames ?? [], with: variants)
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

    /// Variants in theme order.
    public var orderedVariants: [(name: String, styles: TokenStyles)] {
        variantNames.map { ($0, variants[$0]!) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content
            && lhs.offset == rhs.offset
            && lhs.type == rhs.type
            && lhs.explanation == rhs.explanation
            && lhs.variants == rhs.variants
    }

    private static func reconcile(
        _ names: [String],
        with variants: [String: TokenStyles]
    ) -> [String] {
        orderedKeys(of: variants, preferredOrder: names)
    }
}

extension ThemedTokenWithVariants: Codable {
    private enum CodingKeys: String, CodingKey {
        case content, offset, type, explanation, variants
    }

    private struct VariantKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            content: try container.decode(String.self, forKey: .content),
            offset: try container.decode(Int.self, forKey: .offset),
            type: try container.decodeIfPresent(StandardTokenType.self, forKey: .type),
            explanation: try container.decodeIfPresent(
                [ThemedTokenExplanation].self,
                forKey: .explanation
            ),
            variants: try container.decode([String: TokenStyles].self, forKey: .variants)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content, forKey: .content)
        try container.encode(offset, forKey: .offset)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(explanation, forKey: .explanation)
        var nested = container.nestedContainer(keyedBy: VariantKey.self, forKey: .variants)
        for name in variantNames {
            try nested.encode(variants[name]!, forKey: VariantKey(name))
        }
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
///
/// Each line is processed in O(line length + token count): boundaries are
/// merged once and fragments are sliced from a single UTF-16 buffer, instead
/// of repeatedly copying the remainder of a long token for every split.
public func alignThemesTokenization(
    _ themes: [[[ThemedToken]]]
) throws -> [[[ThemedToken]]] {
    try validateThemeTokenizations(themes)

    let themeCount = themes.count
    let lineCount = themes[0].count
    var output = themes.map { _ in [[ThemedToken]]() }
    for index in output.indices { output[index].reserveCapacity(lineCount) }

    var lineUnits: [UInt16] = []
    for lineIndex in 0..<lineCount {
        // A grammar-backed theme represents an empty source line as `[]`,
        // while `none`/plain themes represent it as one empty token. Upstream
        // stops alignment as soon as any current stream is absent, yielding an
        // empty line for every theme in this mixed case.
        if themes.contains(where: { $0[lineIndex].isEmpty }) {
            for themeIndex in 0..<themeCount {
                output[themeIndex].append([])
            }
            continue
        }

        // Union of relative token end positions across every theme.
        var boundaries: [Int] = []
        var lengthsByTheme: [[Int]] = []
        lengthsByTheme.reserveCapacity(themeCount)
        for themeIndex in 0..<themeCount {
            var position = 0
            var lengths: [Int] = []
            lengths.reserveCapacity(themes[themeIndex][lineIndex].count)
            for token in themes[themeIndex][lineIndex] {
                let length = token.content.utf16.count
                lengths.append(length)
                position += length
                boundaries.append(position)
            }
            lengthsByTheme.append(lengths)
        }
        boundaries.sort()
        var uniqueBoundaries: [Int] = []
        uniqueBoundaries.reserveCapacity(boundaries.count)
        for boundary in boundaries where boundary != uniqueBoundaries.last {
            uniqueBoundaries.append(boundary)
        }

        let needsSlicing = lengthsByTheme.contains { $0.count != uniqueBoundaries.count }
        if needsSlicing {
            lineUnits.removeAll(keepingCapacity: true)
            for token in themes[0][lineIndex] {
                lineUnits.append(contentsOf: token.content.utf16)
            }
        }

        for themeIndex in 0..<themeCount {
            let line = themes[themeIndex][lineIndex]
            let lengths = lengthsByTheme[themeIndex]
            if lengths.count == uniqueBoundaries.count {
                output[themeIndex].append(line)
                continue
            }

            var fragments: [ThemedToken] = []
            fragments.reserveCapacity(uniqueBoundaries.count)
            var boundaryIndex = 0
            var tokenStart = 0
            for (tokenIndex, token) in line.enumerated() {
                let tokenEnd = tokenStart + lengths[tokenIndex]
                // Fast path: the token is not split by any other theme.
                if uniqueBoundaries[boundaryIndex] == tokenEnd {
                    fragments.append(token)
                    boundaryIndex += 1
                    tokenStart = tokenEnd
                    continue
                }
                var fragmentStart = tokenStart
                while boundaryIndex < uniqueBoundaries.count,
                      uniqueBoundaries[boundaryIndex] <= tokenEnd
                {
                    let fragmentEnd = uniqueBoundaries[boundaryIndex]
                    var fragment = token
                    fragment.content = String(
                        decoding: lineUnits[fragmentStart..<fragmentEnd],
                        as: UTF16.self
                    )
                    fragment.offset = token.offset + (fragmentStart - tokenStart)
                    fragments.append(fragment)
                    fragmentStart = fragmentEnd
                    boundaryIndex += 1
                }
                tokenStart = tokenEnd
            }
            output[themeIndex].append(fragments)
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

    let names = themes.map(\.name)
    let aligned = try alignThemesTokenization(themes.map(\.tokens))
    return aligned[0].enumerated().map { lineIndex, line in
        line.enumerated().map { tokenIndex, firstToken in
            var variants: [String: TokenStyles] = [:]
            variants.reserveCapacity(themes.count)
            for themeIndex in themes.indices {
                variants[names[themeIndex]] =
                    aligned[themeIndex][lineIndex][tokenIndex].styles
            }

            return ThemedTokenWithVariants(
                content: firstToken.content,
                offset: firstToken.offset,
                type: nil,
                explanation: includeExplanation
                    ? firstToken.explanation
                    : nil,
                variants: variants,
                variantNames: names
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
        let referenceStart = referenceLine.first?.offset
        let referenceLength = try validateOffsets(
            referenceLine,
            themeIndex: 0,
            lineIndex: lineIndex
        )

        for themeIndex in themes.indices {
            let line = themes[themeIndex][lineIndex]
            if themeIndex > 0 {
                let length = try validateOffsets(
                    line,
                    themeIndex: themeIndex,
                    lineIndex: lineIndex
                )
                // Compare content without materializing per-line arrays.
                guard length == referenceLength,
                      line.lazy.flatMap(\.content.utf16)
                        .elementsEqual(referenceLine.lazy.flatMap(\.content.utf16))
                else {
                    throw MultiThemeTokenizationError.lineContentMismatch(
                        theme: themeIndex,
                        line: lineIndex
                    )
                }
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

            if referenceLength == 0, line.count > 1 {
                throw MultiThemeTokenizationError.incompatibleEmptyTokens(
                    theme: themeIndex,
                    line: lineIndex
                )
            }
            if referenceLength != 0, line.contains(where: \.content.isEmpty) {
                throw MultiThemeTokenizationError.incompatibleEmptyTokens(
                    theme: themeIndex,
                    line: lineIndex
                )
            }
        }
    }
}

/// Validates contiguous offsets and returns the line's UTF-16 length.
private func validateOffsets(
    _ line: [ThemedToken],
    themeIndex: Int,
    lineIndex: Int
) throws -> Int {
    guard let firstOffset = line.first?.offset else { return 0 }
    var expectedOffset = firstOffset

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
        expectedOffset += token.content.utf16.count
    }
    return expectedOffset - firstOffset
}

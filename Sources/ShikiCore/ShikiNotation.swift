import Foundation

// A native port of `@shikijs/transformers` comment notations (`// [!code ++]`
// and friends). Upstream applies them to Shiki's HAST tree and reports the
// result as CSS classes; here the same algorithm runs on token lines and
// reports typed line annotations and word ranges instead. The matching,
// comment splitting, line-offset and quirk behavior follows
// `parse-comments.ts`, `notation-transformer.ts`, and `highlight-word.ts`.

/// What a `[!code …]` notation marked on a line.
public enum ShikiLineNotation: String, Codable, CaseIterable, Hashable, Sendable {
    /// `[!code ++]`
    case added
    /// `[!code --]`
    case removed
    /// `[!code highlight]` or `[!code hl]`
    case highlighted
    /// `[!code focus]`
    case focused
    /// `[!code error]`
    case error
    /// `[!code warning]`
    case warning
    /// `[!code info]`
    case info
}

/// A notation family, matching one upstream transformer.
public enum ShikiNotationKind: String, CaseIterable, Sendable {
    /// `transformerNotationDiff`: `++`, `--`.
    case diff
    /// `transformerNotationHighlight`: `highlight`, `hl`.
    case highlight
    /// `transformerNotationFocus`: `focus`.
    case focus
    /// `transformerNotationErrorLevel`: `error`, `warning`, `info`.
    case errorLevel
    /// `transformerNotationWordHighlight`: `word:text`.
    case wordHighlight
}

/// Upstream's `matchAlgorithm` option.
public enum ShikiNotationMatchAlgorithm: Sendable {
    /// Matches comments in any token, with no nested-comment splitting.
    case v1
    /// The default: matches the last token (and JSX comments), splits nested
    /// `//` comments, and applies a standalone comment to the following line.
    case v3
}

/// A highlighted word range within one line of the cleaned output.
public struct ShikiWordHighlight: Equatable, Hashable, Sendable {
    /// Zero-based line index into the cleaned tokens.
    public var line: Int
    /// UTF-16 range within that line's text.
    public var range: Range<Int>

    public init(line: Int, range: Range<Int>) {
        self.line = line
        self.range = range
    }
}

/// Tokens with their notation comments removed, plus what the notations marked.
public struct ShikiNotationResult: Sendable {
    /// Token lines with notation comments (and standalone notation lines)
    /// removed. Token offsets are recomputed to index into `code`.
    public var tokens: [[ThemedToken]]
    /// The notations marking each line, parallel to `tokens`.
    public var lineNotations: [Set<ShikiLineNotation>]
    /// Ranges highlighted by `[!code word:…]`.
    public var wordHighlights: [ShikiWordHighlight]

    /// The cleaned source: the token text joined with LF.
    public var code: String {
        tokens.map { $0.map(\.content).joined() }.joined(separator: "\n")
    }

    public init(
        tokens: [[ThemedToken]],
        lineNotations: [Set<ShikiLineNotation>],
        wordHighlights: [ShikiWordHighlight]
    ) {
        self.tokens = tokens
        self.lineNotations = lineNotations
        self.wordHighlights = wordHighlights
    }

    /// Whether any line carries `notation`.
    public func contains(_ notation: ShikiLineNotation) -> Bool {
        lineNotations.contains { $0.contains(notation) }
    }
}

/// Shiki's `mergeWhitespaceTokens`: whitespace-only tokens join the token
/// that follows them (unless that token is underlined or struck through).
func mergingWhitespaceTokens(_ lines: [[ThemedToken]]) -> [[ThemedToken]] {
    func isWhitespaceOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { Patterns.jsWhitespace.contains($0) }
    }
    func couldMerge(_ token: ThemedToken) -> Bool {
        guard let style = token.fontStyle else { return true }
        return style.rawValue & (FontStyle.underline.rawValue | FontStyle.strikethrough.rawValue) == 0
    }

    return lines.map { line in
        var merged: [ThemedToken] = []
        var carried = ""
        var firstOffset = 0
        for (index, token) in line.enumerated() {
            let mergeable = couldMerge(token)
            if mergeable, isWhitespaceOnly(token.content), index + 1 < line.count {
                if carried.isEmpty { firstOffset = token.offset }
                carried += token.content
            } else if !carried.isEmpty {
                if mergeable {
                    var joined = token
                    joined.offset = firstOffset
                    joined.content = carried + token.content
                    joined.explanation = nil
                    merged.append(joined)
                } else {
                    merged.append(ThemedToken(content: carried, offset: firstOffset))
                    merged.append(token)
                }
                carried = ""
            } else {
                merged.append(token)
            }
        }
        return merged
    }
}

/// Applies Shiki's comment notations to token lines.
///
/// Each requested notation runs in order, like chaining the upstream
/// transformers, and removes the notation comments it recognizes. Tokens are
/// returned untouched when the source contains no `[!code` marker.
///
/// - Parameters:
///   - tokens: Token lines from `codeToTokens`.
///   - language: The language the tokens were produced for; only `"jsx"` and
///     `"tsx"` (exactly, as upstream) enable JSX comment matching.
///   - notations: Which notation families to apply, in order.
///   - matchAlgorithm: Upstream's `matchAlgorithm`.
public func applyShikiNotations(
    to tokens: [[ThemedToken]],
    language: String = "text",
    notations: [ShikiNotationKind] = ShikiNotationKind.allCases,
    matchAlgorithm: ShikiNotationMatchAlgorithm = .v3
) -> ShikiNotationResult {
    guard tokens.contains(where: { $0.contains { $0.content.contains("[!code") } }) else {
        return ShikiNotationResult(
            tokens: tokens,
            lineNotations: Array(repeating: [], count: tokens.count),
            wordHighlights: []
        )
    }
    // Shiki's `codeToHast` merges whitespace into the following token before
    // transformers run (`mergeWhitespaces: true`), so an indented comment is
    // one token. Notation matching depends on that.
    var engine = NotationEngine(
        tokens: mergingWhitespaceTokens(tokens),
        jsx: language == "jsx" || language == "tsx",
        algorithm: matchAlgorithm
    )
    for kind in notations {
        engine.run(kind)
    }
    return engine.result()
}

extension TokensResult {
    /// Applies Shiki's comment notations to these tokens.
    /// See ``applyShikiNotations(to:language:notations:matchAlgorithm:)``.
    public func applyingNotations(
        language: String = "text",
        notations: [ShikiNotationKind] = ShikiNotationKind.allCases,
        matchAlgorithm: ShikiNotationMatchAlgorithm = .v3
    ) -> ShikiNotationResult {
        applyShikiNotations(to: tokens, language: language, notations: notations, matchAlgorithm: matchAlgorithm)
    }
}

// MARK: - Engine

/// Upstream #1308 ("keep notations on content comment lines"): a comment that
/// is the whole line applies to the *next* line only when it contains nothing
/// but notations. Shiki 4.4.3 as published applies every whole-line comment
/// to the next line, so `# note [!code ++]` marks the wrong line.
private let shikiNotationChecksStandalone = true

private final class Segment {
    var token: ThemedToken
    var isWord: Bool

    init(_ token: ThemedToken, isWord: Bool = false) {
        self.token = token
        self.isWord = isWord
    }

    var text: String {
        get { token.content }
        set { token.content = newValue }
    }

    func copy(text: String) -> Segment {
        var token = token
        token.content = text
        token.explanation = nil
        return Segment(token, isWord: isWord)
    }
}

private final class Line {
    var segments: [Segment]
    var notations: Set<ShikiLineNotation> = []

    init(_ segments: [Segment]) {
        self.segments = segments
    }
}

private final class ParsedComment {
    let line: Line
    var token: Segment
    var prefix: String
    var content: String
    var suffix: String?
    let isLineCommentOnly: Bool
    let isJsxStyle: Bool
    let additionalTokens: [Segment]

    init(
        line: Line,
        token: Segment,
        info: CommentInfo,
        isLineCommentOnly: Bool,
        isJsxStyle: Bool,
        additionalTokens: [Segment] = []
    ) {
        self.line = line
        self.token = token
        prefix = info.prefix
        content = info.content
        suffix = info.suffix
        self.isLineCommentOnly = isLineCommentOnly
        self.isJsxStyle = isJsxStyle
        self.additionalTokens = additionalTokens
    }

    var joined: String { prefix + content + (suffix ?? "") }
}

private struct CommentInfo {
    var prefix: String
    var content: String
    var suffix: String?
}

private struct NotationEngine {
    var lines: [Line]
    let jsx: Bool
    let algorithm: ShikiNotationMatchAlgorithm
    private var parsed: [ParsedComment]?

    init(tokens: [[ThemedToken]], jsx: Bool, algorithm: ShikiNotationMatchAlgorithm) {
        lines = tokens.map { row in Line(row.map { Segment($0) }) }
        self.jsx = jsx
        self.algorithm = algorithm
    }

    // MARK: Passes

    mutating func run(_ kind: ShikiNotationKind) {
        switch kind {
        case .diff:
            runMap(["++": .added, "--": .removed])
        case .highlight:
            runMap(["highlight": .highlighted, "hl": .highlighted])
        case .focus:
            runMap(["focus": .focused])
        case .errorLevel:
            runMap(["error": .error, "warning": .warning, "info": .info])
        case .wordHighlight:
            runWord()
        }
    }

    private mutating func runMap(_ map: [String: ShikiLineNotation]) {
        let keys = map.keys.sorted { $0.count > $1.count }
        // Upstream builds the alternation in classMap key order; sorting only
        // matters for keys that are prefixes of each other, which none are.
        let alternation = keys.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let regex = Patterns.make("#?\(Patterns.space)*\\[!code (\(alternation))(:[0-9]+)?\\]", caseInsensitive: true)
        process(regex: regex, global: true) { groups, lines, index in
            let range = groups[2] ?? ":1"
            let count = Self.parseInt(range.dropFirst())
            if let notation = map[groups[1] ?? ""] {
                var i = index
                let end = Self.clampedEnd(index, count, lines.count)
                while i < end {
                    lines[i].notations.insert(notation)
                    i += 1
                }
            }
            return true
        }
    }

    private mutating func runWord() {
        let regex = Patterns.make("\(Patterns.space)*\\[!code word:((?:\\\\.|[^:\\]])+)(:[0-9]+)?\\]", caseInsensitive: false)
        process(regex: regex, global: false) { groups, lines, index, comment in
            let count = groups[2].map { Self.parseInt($0.dropFirst()) } ?? lines.count
            let word = Self.unescape(groups[1] ?? "")
            var i = index
            let end = Self.clampedEnd(index, count, lines.count)
            while i < end {
                Self.highlight(word: word, in: lines[i], ignoring: comment.token)
                i += 1
            }
            return true
        }
    }

    private typealias LineHandler = (_ groups: [String?], _ lines: [Line], _ index: Int) -> Bool
    private typealias CommentHandler = (_ groups: [String?], _ lines: [Line], _ index: Int, _ comment: ParsedComment) -> Bool

    private mutating func process(regex: NSRegularExpression, global: Bool, handler: @escaping LineHandler) {
        process(regex: regex, global: global) { groups, lines, index, _ in handler(groups, lines, index) }
    }

    /// `createCommentNotationTransformer`.
    private mutating func process(regex: NSRegularExpression, global: Bool, handler: CommentHandler) {
        let jsx = jsx
        let algorithm = algorithm
        if parsed == nil { parsed = Self.parseComments(lines, jsx: jsx, algorithm: algorithm) }
        var linesToRemove: [Line] = []

        for comment in parsed! {
            if comment.content.isEmpty { continue }
            var index = lines.firstIndex { $0 === comment.line } ?? -1
            let standalone = Self.jsTrim(
                Patterns.remove(regex, from: Patterns.remove(Patterns.notation, from: comment.content, global: true), global: global)
            ).isEmpty
            if comment.isLineCommentOnly, standalone || !shikiNotationChecksStandalone, algorithm != .v1 { index += 1 }

            var replaced = false
            let currentLines = lines
            comment.content = Patterns.replace(regex, in: comment.content, global: global) { groups in
                if handler(groups, currentLines, index, comment) {
                    replaced = true
                    return ""
                }
                return groups[0] ?? ""
            }
            if !replaced { continue }

            switch algorithm {
            case .v1: comment.content = Patterns.clearEndCommentPrefix(comment.content, trimming: false)
            case .v3: comment.content = Patterns.clearEndCommentPrefix(comment.content, trimming: true)
            }
            let isEmpty = Self.jsTrim(comment.content).isEmpty
            if isEmpty { comment.content = "" }

            if isEmpty, comment.isLineCommentOnly {
                linesToRemove.append(comment.line)
            } else if isEmpty, comment.isJsxStyle {
                // `splice(indexOf(token) - 1, 3)`: the braces around the comment.
                let at = comment.line.segments.firstIndex { $0 === comment.token } ?? -1
                Self.splice(&comment.line.segments, at - 1, 3)
            } else if isEmpty {
                for extra in comment.additionalTokens.reversed() {
                    if let at = comment.line.segments.firstIndex(where: { $0 === extra }) {
                        comment.line.segments.remove(at: at)
                    }
                }
                let at = comment.line.segments.firstIndex { $0 === comment.token } ?? -1
                Self.splice(&comment.line.segments, at, 1)
            } else {
                comment.token.text = comment.joined
                for extra in comment.additionalTokens { extra.text = "" }
            }
        }

        for line in linesToRemove {
            lines.removeAll { $0 === line }
        }
    }

    // MARK: Parsing (`parse-comments.ts`)

    private static func parseComments(_ lines: [Line], jsx: Bool, algorithm: ShikiNotationMatchAlgorithm) -> [ParsedComment] {
        var out: [ParsedComment] = []

        for line in lines {
            if algorithm == .v3 {
                var split: [Segment] = []
                for (index, segment) in line.segments.enumerated() {
                    let isLast = index == line.segments.count - 1
                    guard matchToken(segment.text, isLast: isLast) != nil else {
                        split.append(segment)
                        continue
                    }
                    let pieces = splitNestedComments(segment.text)
                    if pieces.count <= 1 {
                        split.append(segment)
                    } else {
                        split.append(contentsOf: pieces.map { segment.copy(text: $0) })
                    }
                }
                if split.count != line.segments.count { line.segments = split }
            }

            let elements = line.segments
            var start = elements.count - 1
            if algorithm == .v1 { start = 0 } else if jsx { start = elements.count - 2 }

            var i = max(start, 0)
            while i < elements.count {
                defer { i += 1 }
                let token = elements[i]
                let isLast = i == elements.count - 1
                let match = matchToken(token.text, isLast: isLast)

                // Multi-token comments, e.g. a theme splitting `//` from ` [!code --]`.
                if match == nil, i > 0, jsTrim(token.text).hasPrefix("[!code") {
                    let previous = elements[i - 1]
                    if previous.text.contains("//"), let combined = matchToken(previous.text + token.text, isLast: isLast) {
                        out.append(ParsedComment(
                            line: line, token: previous, info: combined,
                            isLineCommentOnly: elements.count == 2,
                            isJsxStyle: false, additionalTokens: [token]
                        ))
                        continue
                    }
                }
                guard let info = match else { continue }

                if jsx, !isLast, i != 0 {
                    let isJsxStyle = isValue(elements[i - 1], "{") && isValue(elements[i + 1], "}")
                    out.append(ParsedComment(
                        line: line, token: token, info: info,
                        isLineCommentOnly: elements.count == 3, isJsxStyle: isJsxStyle
                    ))
                } else {
                    out.append(ParsedComment(
                        line: line, token: token, info: info,
                        isLineCommentOnly: elements.count == 1, isJsxStyle: false
                    ))
                }
            }
        }
        return out
    }

    private static func isValue(_ segment: Segment, _ value: String) -> Bool {
        jsTrim(segment.text) == value
    }

    /// `token.value.split(/(\s+\/\/)/)`, re-attached and filtered as upstream.
    private static func splitNestedComments(_ text: String) -> [String] {
        let ns = text as NSString
        let matches = Patterns.splitComment.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [text] }
        var raw: [String] = []
        var cursor = 0
        for match in matches {
            raw.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            raw.append(ns.substring(with: match.range(at: 1)))
            cursor = NSMaxRange(match.range)
        }
        raw.append(ns.substring(from: cursor))

        var pieces = [raw[0]]
        var i = 1
        while i < raw.count {
            pieces.append(raw[i] + (i + 1 < raw.count ? raw[i + 1] : ""))
            i += 2
        }
        return pieces.filter { !$0.isEmpty }
    }

    /// `matchToken`: comment syntaxes, with spaces around them preserved.
    private static func matchToken(_ text: String, isLast: Bool) -> CommentInfo? {
        let trimmedStart = jsTrimStart(text)
        let spaceFront = text.utf16.count - trimmedStart.utf16.count
        let trimmed = jsTrimEnd(trimmedStart)
        let spaceEnd = text.utf16.count - trimmed.utf16.count - spaceFront

        for (regex, endOfLine) in Patterns.commentMatchers {
            if endOfLine && !isLast { continue }
            let ns = trimmed as NSString
            guard let result = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ n: Int) -> String? {
                guard n < result.numberOfRanges else { return nil }
                let range = result.range(at: n)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            return CommentInfo(
                prefix: String(repeating: " ", count: spaceFront) + (group(1) ?? ""),
                content: group(2) ?? "",
                suffix: group(3).map { $0 + String(repeating: " ", count: spaceEnd) }
            )
        }
        return nil
    }

    // MARK: Word highlight (`highlight-word.ts`)

    private static func highlight(word: String, in line: Line, ignoring ignored: Segment) {
        let content = line.segments.map(\.text).joined() as NSString
        let needle = word as NSString
        guard needle.length > 0 else { return }
        var found = content.range(of: word)
        while found.location != NSNotFound {
            highlightRange(line, ignoring: ignored, index: found.location, length: needle.length)
            let from = found.location + 1
            guard from <= content.length else { break }
            found = content.range(of: word, options: [], range: NSRange(location: from, length: content.length - from))
        }
    }

    private static func highlightRange(_ line: Line, ignoring ignored: Segment, index: Int, length len: Int) {
        var current = 0
        var i = 0
        while i < line.segments.count {
            let element = line.segments[i]
            if element === ignored {
                i += 1
                continue
            }
            let utf16 = Array(element.text.utf16)
            // `hasOverlap([current, current + n - 1], [index, index + len])`
            if current <= index + len, current + utf16.count - 1 >= index {
                let start = max(0, index - current)
                let length = len - max(0, current - index)
                if length == 0 {
                    // Upstream `continue`s here without advancing `current`.
                    i += 1
                    continue
                }
                let end = min(utf16.count, start + length)
                func piece(_ a: Int, _ b: Int) -> String { String(decoding: utf16[a..<b], as: UTF16.self) }
                var output: [Segment] = []
                if start > 0 { output.append(element.copy(text: piece(0, start))) }
                let middle = element.copy(text: piece(min(start, utf16.count), end))
                middle.isWord = true
                output.append(middle)
                if start + length < utf16.count { output.append(element.copy(text: piece(start + length, utf16.count))) }
                line.segments.replaceSubrange(i...i, with: output)
                i += output.count - 1
            }
            current += utf16.count
            i += 1
        }
    }

    // MARK: Output

    func result() -> ShikiNotationResult {
        var tokens: [[ThemedToken]] = []
        var notations: [Set<ShikiLineNotation>] = []
        var words: [ShikiWordHighlight] = []
        var offset = 0
        for (lineIndex, line) in lines.enumerated() {
            var row: [ThemedToken] = []
            var position = 0
            var open: Int?
            for segment in line.segments where !segment.text.isEmpty {
                var token = segment.token
                token.offset = offset + position
                row.append(token)
                let length = token.content.utf16.count
                if segment.isWord {
                    if open == nil { open = position }
                } else if let start = open {
                    words.append(ShikiWordHighlight(line: lineIndex, range: start..<position))
                    open = nil
                }
                position += length
            }
            if let start = open { words.append(ShikiWordHighlight(line: lineIndex, range: start..<position)) }
            tokens.append(row)
            notations.append(line.notations)
            offset += position + 1
        }
        return ShikiNotationResult(tokens: tokens, lineNotations: notations, wordHighlights: words)
    }

    // MARK: JS helpers

    private static func parseInt(_ text: some StringProtocol) -> Int {
        Int(text) ?? Int.max
    }

    private static func clampedEnd(_ index: Int, _ count: Int, _ limit: Int) -> Int {
        let (sum, overflow) = index.addingReportingOverflow(count)
        return min(overflow ? Int.max : sum, limit)
    }

    /// `array.splice(start, count)`, including a negative start counting from the end.
    private static func splice(_ array: inout [Segment], _ start: Int, _ count: Int) {
        let from = start < 0 ? max(0, array.count + start) : min(start, array.count)
        let to = min(array.count, from + count)
        if from < to { array.removeSubrange(from..<to) }
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next(), next != "\n" {
                result.append(next)
            } else {
                result.append(character)
            }
        }
        return result
    }

    fileprivate static func jsTrim(_ text: String) -> String { jsTrimEnd(jsTrimStart(text)) }

    fileprivate static func jsTrimStart(_ text: String) -> String {
        String(text.unicodeScalars.drop { Patterns.jsWhitespace.contains($0) })
    }

    fileprivate static func jsTrimEnd(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let last = scalars.last, Patterns.jsWhitespace.contains(last) { scalars.removeLast() }
        return String(scalars)
    }
}

// MARK: - Patterns

fileprivate enum Patterns {
    /// JavaScript's `\s`, spelled out because ICU's differs slightly.
    static let space = "[\\t\\n\\x{0B}\\x{0C}\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"

    static let jsWhitespace: CharacterSet = {
        var set = CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r \u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        set.insert(charactersIn: "\u{2000}"..."\u{200A}")
        return set
    }()

    static func make(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression {
        // The patterns are fixed or built from escaped literals.
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    static let notation = make("#?\(space)*\\[!code\\b(?:\\\\.|[^\\]])*\\]", caseInsensitive: true)
    static let splitComment = make("(\(space)+//)", caseInsensitive: false)
    static let v1End = make("(?://|[\"'#]|;{1,2}|%{1,2}|--)(\(space)*)$", caseInsensitive: false)
    static let v3End = make("(?://|#|;{1,2}|%{1,2}|--)(\(space)*)$", caseInsensitive: false)

    /// Comment syntaxes and whether each must sit at the end of the line.
    static let commentMatchers: [(NSRegularExpression, Bool)] = [
        (make("^(<!--)(.+)(-->)$", caseInsensitive: false), false),
        (make("^(/\\*)(.+)(\\*/)$", caseInsensitive: false), false),
        (make("^(//|[\"'#]|;{1,2}|%{1,2}|--)(.*)$", caseInsensitive: false), true),
        (make("^(\\*)(.+)$", caseInsensitive: false), true),
    ]

    /// `text.replace(regex, fn)`; `groups[0]` is the whole match.
    static func replace(
        _ regex: NSRegularExpression,
        in text: String,
        global: Bool,
        _ transform: ([String?]) -> String
    ) -> String {
        let ns = text as NSString
        var matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if !global { matches = Array(matches.prefix(1)) }
        guard !matches.isEmpty else { return text }
        var output = ""
        var cursor = 0
        for match in matches {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups: [String?] = (0..<match.numberOfRanges).map { n in
                let range = match.range(at: n)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            output += transform(groups)
            cursor = NSMaxRange(match.range)
        }
        return output + ns.substring(from: cursor)
    }

    static func remove(_ regex: NSRegularExpression, from text: String, global: Bool = true) -> String {
        replace(regex, in: text, global: global) { _ in "" }
    }

    /// `v1ClearEndCommentPrefix` / `v3ClearEndCommentPrefix`.
    static func clearEndCommentPrefix(_ text: String, trimming: Bool) -> String {
        let regex = trimming ? v3End : v1End
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return text }
        let head = ns.substring(to: match.range.location)
        return trimming ? NotationEngine.jsTrimEnd(head) : head
    }
}

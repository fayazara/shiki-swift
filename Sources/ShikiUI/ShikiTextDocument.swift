#if os(macOS)
import AppKit
import ShikiCore

/// Keeps source and UTF-16 row boundaries separate from lazily styled paragraphs.
/// Token offsets describe the original source (possibly CRLF); display offsets
/// describe the LF-joined token rows, just like ShikiAttributedStringRenderer.
@MainActor
final class ShikiTextDocument {
    let source: NSString
    lazy var plainText = NSAttributedString(string: source as String)
    let rowRanges: [NSRange]
    let visualLineOffsets: [Int]
    let result: TokensResult
    let font: NSFont
    let lineHeight: CGFloat
    let estimatedWidth: CGFloat
    /// Advance of one ASCII column in `font`.
    let advance: CGFloat
    let baseAttributes: [NSAttributedString.Key: Any]

    private struct StyleKey: Hashable {
        let color: String?
        let background: String?
        let style: FontStyle
    }
    private var styles: [StyleKey: [NSAttributedString.Key: Any]] = [:]
    private var paragraphs: [NSRange: NSAttributedString] = [:]
    private var recency: [NSRange] = []
    private(set) var cachedUTF16Count = 0
    var cachedParagraphCount: Int { paragraphs.count }
    private(set) var renderedParagraphCount = 0
    private let paragraphLimit = 256
    private let characterLimit = 262_144

    /// Lines longer than this (UTF-16 units) are laid out in horizontal slices,
    /// so a minified line never becomes one enormous TextKit line fragment.
    nonisolated static let sliceThreshold = 4_096
    private static let columnChunk = 1_024

    /// Chunk start offsets (source UTF-16) of one long line and their x
    /// positions, so a slice can start at any chunk at its exact position.
    struct ColumnIndex {
        let offsets: [Int]
        let x: [CGFloat]
    }
    private var columnIndexes: [Int: ColumnIndex] = [:]

    /// Widest extent the viewport lays out. Keeping coordinates below 2^22pt
    /// preserves sub-point precision in Core Animation's 32-bit float
    /// geometry. Longer rows are clipped (never wrapped over the next row);
    /// their full text stays selectable and copyable.
    nonisolated static let maximumWidth: CGFloat = 4_194_304

    /// Font-derived measurements needed to build a layout off the main thread.
    struct Metrics: Sendable {
        var advance: CGFloat
        var wideAdvance: CGFloat
    }

    /// The expensive, font-independent part of a document: the joined text,
    /// row ranges, visual line starts, and a conservative width estimate.
    struct Layout: Sendable {
        var text: String
        var rowRanges: [NSRange]
        var visualLineOffsets: [Int]
        var width: CGFloat
    }

    static func metrics(for font: NSFont) -> Metrics {
        let advance = max(1, (" " as NSString).size(withAttributes: [.font: font]).width)
        return Metrics(advance: advance, wideAdvance: max(advance * 2.3, font.pointSize * 1.5))
    }

    nonisolated static func makeLayout(result: TokensResult, metrics: Metrics) -> Layout {
        let advance = metrics.advance
        var text = ""
        var ranges: [NSRange] = []
        ranges.reserveCapacity(result.tokens.count)
        var offset = 0
        var width: CGFloat = 0
        for (index, row) in result.tokens.enumerated() {
            let start = offset
            var rowWidth: CGFloat = 0
            for token in row {
                text.append(token.content)
                offset += token.content.utf16.count
                // A conservative width estimate avoids laying out hidden rows.
                // Past the maximum the row is clipped, so stop measuring.
                guard rowWidth < maximumWidth else { continue }
                for scalar in token.content.unicodeScalars {
                    if scalar.value == 9 {
                        let tab = advance * 4
                        rowWidth = (floor(rowWidth / tab) + 1) * tab
                    } else {
                        rowWidth += scalar.isASCII ? advance : metrics.wideAdvance
                    }
                }
            }
            width = max(width, rowWidth)
            if index + 1 < result.tokens.count {
                text.append("\n")
                offset += 1
            }
            ranges.append(NSRange(location: start, length: offset - start))
        }
        var lineOffsets = [0]
        var previousCR = false
        var position = 0
        for unit in text.utf16 {
            position += 1
            if unit == 10 && previousCR {
                lineOffsets[lineOffsets.count - 1] = position
            } else if unit == 10 || unit == 13 || unit == 0x85 || unit == 0x2028 || unit == 0x2029 {
                lineOffsets.append(position)
            }
            previousCR = unit == 13
        }
        return Layout(text: text, rowRanges: ranges, visualLineOffsets: lineOffsets, width: width)
    }

    convenience init(result: TokensResult, font: NSFont) {
        self.init(result: result, font: font,
                  layout: Self.makeLayout(result: result, metrics: Self.metrics(for: font)))
    }

    init(result: TokensResult, font: NSFont, layout: Layout) {
        self.result = result
        self.font = font
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let advance = Self.metrics(for: font).advance
        self.advance = advance
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineBreakMode = .byClipping
        paragraphStyle.tabStops = []
        paragraphStyle.defaultTabInterval = advance * 4
        baseAttributes = [
            .font: font,
            .foregroundColor: result.fg.flatMap(ShikiRGBAColor.init(hex:))?.appKitColor ?? NSColor.textColor,
            .paragraphStyle: paragraphStyle,
        ]
        source = layout.text as NSString
        rowRanges = layout.rowRanges
        visualLineOffsets = layout.visualLineOffsets
        estimatedWidth = min(Self.maximumWidth, layout.width + advance * 2)
    }

    /// Also handles TextKit paragraph boundaries inside a token (CR, Unicode
    /// separators), and empty/trailing paragraphs. All slicing uses UTF-16.
    func paragraph(in range: NSRange) -> NSAttributedString? {
        guard range.location >= 0, range.length >= 0,
              range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        if let cached = paragraphs[range] {
            recency.removeAll { $0 == range }
            recency.append(range)
            return cached
        }
        let output = NSMutableAttributedString(
            string: source.substring(with: range), attributes: baseAttributes
        )
        var lower = 0
        var upper = rowRanges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(rowRanges[middle]) <= range.location { lower = middle + 1 }
            else { upper = middle }
        }
        var row = lower
        while row < rowRanges.count, rowRanges[row].location < NSMaxRange(range) {
            var position = rowRanges[row].location
            for token in result.tokens[row] {
                let length = token.content.utf16.count
                let intersection = NSIntersectionRange(NSRange(location: position, length: length), range)
                if intersection.length > 0 {
                    output.setAttributes(attributes(for: token), range: NSRange(
                        location: intersection.location - range.location,
                        length: intersection.length
                    ))
                }
                position += length
                if position >= NSMaxRange(range) { break }
            }
            row += 1
        }
        renderedParagraphCount += 1
        let rendered = NSAttributedString(attributedString: output)
        if range.length <= characterLimit {
            while !recency.isEmpty && (paragraphs.count >= paragraphLimit
                || cachedUTF16Count + range.length > characterLimit) {
                let evicted = recency.removeFirst()
                cachedUTF16Count -= paragraphs.removeValue(forKey: evicted)?.length ?? 0
            }
            paragraphs[range] = rendered
            recency.append(range)
            cachedUTF16Count += range.length
        }
        return rendered
    }

    /// The visual line's range without its trailing line break.
    func contentRange(ofLine line: Int) -> NSRange {
        let start = visualLineOffsets[line]
        var end = line + 1 < visualLineOffsets.count ? visualLineOffsets[line + 1] : source.length
        if end > start {
            let last = source.character(at: end - 1)
            if last == 10 && end - 1 > start && source.character(at: end - 2) == 13 { end -= 2 }
            else if [10, 13, 0x85, 0x2028, 0x2029].contains(last) { end -= 1 }
        }
        return NSRange(location: start, length: end - start)
    }

    /// Measured lazily, once per long line; ASCII chunks cost no text layout.
    func columnIndex(forLine line: Int) -> ColumnIndex {
        if let cached = columnIndexes[line] { return cached }
        let content = contentRange(ofLine: line)
        let end = NSMaxRange(content)
        var offsets = [content.location]
        var xs: [CGFloat] = [0]
        var position = content.location
        var x: CGFloat = 0
        while position < end {
            var next = min(end, position + Self.columnChunk)
            if next < end {
                // Never split a surrogate pair or grapheme cluster.
                let composed = source.rangeOfComposedCharacterSequence(at: next)
                if composed.location > position { next = composed.location }
            }
            x = advance(from: x, over: NSRange(location: position, length: next - position))
            position = next
            offsets.append(position)
            xs.append(x)
        }
        let index = ColumnIndex(offsets: offsets, x: xs)
        if columnIndexes.count >= 64 { columnIndexes.removeAll(keepingCapacity: true) }
        columnIndexes[line] = index
        return index
    }

    /// The x position (relative to the line start) of a source offset in a line.
    func x(at offset: Int, inLine line: Int) -> CGFloat {
        let index = columnIndex(forLine: line)
        var lower = 0
        var upper = index.offsets.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if index.offsets[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        let chunk = max(0, lower - 1)
        let start = index.offsets[chunk]
        return advance(from: index.x[chunk], over: NSRange(location: start, length: max(0, offset - start)))
    }

    /// Mirrors TextKit: fixed columns for printable ASCII, measured glyph
    /// runs otherwise, and tabs snapping to the paragraph's tab interval.
    private func advance(from start: CGFloat, over range: NSRange) -> CGFloat {
        guard range.length > 0 else { return start }
        var units = [unichar](repeating: 0, count: range.length)
        source.getCharacters(&units, range: range)
        if units.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return start + CGFloat(range.length) * advance
        }
        let tab = advance * 4
        var x = start
        var segment = 0
        for index in 0...units.count where index == units.count || units[index] == 9 {
            if index > segment {
                let text = NSAttributedString(string: String(utf16CodeUnits: Array(units[segment..<index]), count: index - segment),
                                              attributes: [.font: font])
                x += CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
            }
            if index < units.count { x = (floor(x / tab) + 1) * tab }
            segment = index + 1
        }
        return x
    }

    private func attributes(for token: ThemedToken) -> [NSAttributedString.Key: Any] {
        let style = token.fontStyle == .notSet ? FontStyle.none : token.fontStyle ?? .none
        let key = StyleKey(color: token.color, background: token.bgColor, style: style)
        if let cached = styles[key] { return cached }
        var attributes = baseAttributes
        var traits = font.fontDescriptor.symbolicTraits
        if style.contains(.bold) { traits.insert(.bold) }
        if style.contains(.italic) { traits.insert(.italic) }
        if traits != font.fontDescriptor.symbolicTraits {
            attributes[.font] = NSFont(
                descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize
            ) ?? font
        }
        if let color = token.color.flatMap(ShikiRGBAColor.init(hex:)) {
            attributes[.foregroundColor] = color.appKitColor
        }
        if let color = token.bgColor.flatMap(ShikiRGBAColor.init(hex:)) {
            attributes[.backgroundColor] = color.appKitColor
        }
        if style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if styles.count >= 256 { styles.removeAll(keepingCapacity: true) }
        styles[key] = attributes
        return attributes
    }
}

extension ShikiRGBAColor {
    var appKitColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
    }
}
#endif

#if canImport(SwiftUI)
import Foundation
import ShikiCore
import SwiftUI

/// Converts Shiki's line-oriented token result into a native AttributedString.
public struct ShikiAttributedStringRenderer: Sendable {
    public var font: Font

    public init(font: Font = .system(.body, design: .monospaced)) {
        self.font = font
    }

    /// Renders all lines, inserting exactly one LF between adjacent token rows.
    ///
    /// A trailing empty token row therefore preserves a trailing source LF.
    public func render(_ result: TokensResult) -> AttributedString {
        render(result, lines: result.tokens.indices)
    }

    /// Renders a clamped range of token rows without materializing other lines.
    /// Separators are inserted only between rows in the requested range.
    public func render(_ result: TokensResult, lines: Range<Int>) -> AttributedString {
        let lower = min(max(0, lines.lowerBound), result.tokens.count)
        let upper = min(max(lower, lines.upperBound), result.tokens.count)
        var output = AttributedString()
        var styles: [StyleKey: AttributeContainer] = [:]
        let foreground = result.fg.flatMap(ShikiRGBAColor.init(hex:))?.swiftUIColor
        var separatorAttributes = AttributeContainer()
        separatorAttributes.font = font
        separatorAttributes.foregroundColor = foreground
        let separator = AttributedString("\n", attributes: separatorAttributes)

        for lineIndex in lower..<upper {
            if lineIndex > lower { output.append(separator) }
            for token in result.tokens[lineIndex] {
                let style = token.fontStyle == .notSet ? FontStyle.none : token.fontStyle ?? .none
                let key = StyleKey(color: token.color, background: token.bgColor, style: style)
                let attributes: AttributeContainer
                if let cached = styles[key] {
                    attributes = cached
                } else {
                    var value = AttributeContainer()
                    var tokenFont = font
                    if style.contains(.bold) { tokenFont = tokenFont.bold() }
                    if style.contains(.italic) { tokenFont = tokenFont.italic() }
                    value.font = tokenFont
                    value.foregroundColor = token.color.flatMap(ShikiRGBAColor.init(hex:))?.swiftUIColor
                        ?? foreground
                    value.backgroundColor = token.bgColor.flatMap(ShikiRGBAColor.init(hex:))?.swiftUIColor
                    if style.contains(.underline) { value.underlineStyle = .single }
                    if style.contains(.strikethrough) { value.strikethroughStyle = .single }
                    attributes = value
                    styles[key] = value
                }
                output.append(AttributedString(token.content, attributes: attributes))
            }
        }
        return output
    }

    private struct StyleKey: Hashable {
        let color: String?
        let background: String?
        let style: FontStyle
    }
}

public extension TokensResult {
    /// Native attributed representation of this highlighted result.
    func attributedString(
        font: Font = .system(.body, design: .monospaced)
    ) -> AttributedString {
        ShikiAttributedStringRenderer(font: font).render(self)
    }
}

public extension ShikiUI {
    /// Namespaced convenience for rendering Shiki tokens as AttributedString.
    static func attributedString(
        from result: TokensResult,
        font: Font = .system(.body, design: .monospaced)
    ) -> AttributedString {
        ShikiAttributedStringRenderer(font: font).render(result)
    }
}
#endif

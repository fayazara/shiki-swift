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
        var output = AttributedString()

        for (lineIndex, line) in result.tokens.enumerated() {
            if lineIndex > 0 {
                output.append(separator(defaultForeground: result.fg))
            }

            for token in line {
                output.append(
                    render(token, defaultForeground: result.fg)
                )
            }
        }

        return output
    }

    private func render(
        _ token: ThemedToken,
        defaultForeground: String?
    ) -> AttributedString {
        var output = AttributedString(token.content)
        let style = normalizedFontStyle(token.fontStyle)
        var tokenFont = font

        if style.contains(.bold) {
            tokenFont = tokenFont.bold()
        }
        if style.contains(.italic) {
            tokenFont = tokenFont.italic()
        }
        output.font = tokenFont

        if let foreground = parsedColor(token.color)
            ?? parsedColor(defaultForeground) {
            output.foregroundColor = foreground.swiftUIColor
        }
        if let background = parsedColor(token.bgColor) {
            output.backgroundColor = background.swiftUIColor
        }
        if style.contains(.underline) {
            output.underlineStyle = .single
        }
        if style.contains(.strikethrough) {
            output.strikethroughStyle = .single
        }

        return output
    }

    private func separator(defaultForeground: String?) -> AttributedString {
        var separator = AttributedString("\n")
        separator.font = font
        if let foreground = parsedColor(defaultForeground) {
            separator.foregroundColor = foreground.swiftUIColor
        }
        return separator
    }

    private func parsedColor(_ source: String?) -> ShikiRGBAColor? {
        source.flatMap(ShikiRGBAColor.init(hex:))
    }

    private func normalizedFontStyle(_ style: FontStyle?) -> FontStyle {
        guard let style, style != .notSet else { return .none }
        return style
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

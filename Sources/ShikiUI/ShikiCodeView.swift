#if canImport(SwiftUI)
import ShikiCore
import SwiftUI

/// A small horizontally scrolling native view for a highlighted token result.
public struct ShikiCodeView: View {
    public let result: TokensResult
    public var font: Font
    public var contentPadding: CGFloat

    public init(
        result: TokensResult,
        font: Font = .system(.body, design: .monospaced),
        contentPadding: CGFloat = 8
    ) {
        self.result = result
        self.font = font
        self.contentPadding = contentPadding
    }

    /// Re-renders only when the tokens or font change, not on every body
    /// evaluation (e.g. unrelated parent state updates). Unchanged results
    /// usually share storage, making the equality check O(1).
    @State private var cache = RenderCache()

    public var body: some View {
        ScrollView(.horizontal) {
            Text(cache.attributedString(for: result, font: font))
                .fixedSize(horizontal: true, vertical: true)
                .padding(contentPadding)
        }
        .background(backgroundColor)
    }

    private final class RenderCache {
        private var result: TokensResult?
        private var font: Font?
        private var value = AttributedString()

        func attributedString(for result: TokensResult, font: Font) -> AttributedString {
            if self.font == font, self.result == result { return value }
            value = ShikiAttributedStringRenderer(font: font).render(result)
            self.result = result
            self.font = font
            return value
        }
    }

    private var backgroundColor: Color {
        result.bg.flatMap(ShikiRGBAColor.init(hex:))?.swiftUIColor ?? .clear
    }
}
#endif

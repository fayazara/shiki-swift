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

    public var body: some View {
        ScrollView(.horizontal) {
            Text(result.attributedString(font: font))
                .fixedSize(horizontal: true, vertical: true)
                .padding(contentPadding)
        }
        .background(backgroundColor)
    }

    private var backgroundColor: Color {
        result.bg.flatMap(ShikiRGBAColor.init(hex:))?.swiftUIColor ?? .clear
    }
}
#endif

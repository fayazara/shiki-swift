import AppKit
import Shiki
import ShikiUI
import SwiftUI

/// A bounded, AppKit-backed viewport for rendering large Shiki token results.
///
/// `renderID` is the cache boundary: callers must change it whenever `result`
/// changes. Ordinary SwiftUI updates with the same ID do not rebuild the large
/// attributed string.
struct StressTestCodeView: NSViewRepresentable {
    let result: TokensResult
    let renderID: Int
    var font: NSFont
    var contentPadding: CGFloat
    var viewportHeight: CGFloat

    init(
        result: TokensResult,
        renderID: Int,
        font: NSFont = .monospacedSystemFont(ofSize: 15, weight: .regular),
        contentPadding: CGFloat = 22,
        viewportHeight: CGFloat = 420
    ) {
        self.result = result
        self.renderID = renderID
        self.font = font
        self.contentPadding = contentPadding
        self.viewportHeight = viewportHeight
    }

    init(
        result: TokensResult,
        renderID: Int,
        fontSize: CGFloat,
        contentPadding: CGFloat = 22,
        viewportHeight: CGFloat = 420
    ) {
        self.init(
            result: result,
            renderID: renderID,
            font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
            contentPadding: contentPadding,
            viewportHeight: viewportHeight
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> StressTestScrollView {
        let scrollView = StressTestScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = Self.maximumDocumentSize
        textView.autoresizingMask = []
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.setAccessibilityLabel("Highlighted code")
        textView.setAccessibilityHelp("Read-only syntax-highlighted source code")

        if let textContainer = textView.textContainer {
            textContainer.containerSize = Self.maximumDocumentSize
            textContainer.widthTracksTextView = false
            textContainer.heightTracksTextView = false
            textContainer.lineFragmentPadding = 0
        }
        textView.layoutManager?.allowsNonContiguousLayout = true

        scrollView.documentView = textView
        update(scrollView, textView: textView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: StressTestScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(scrollView, textView: textView, context: context)
    }

    private func update(
        _ scrollView: StressTestScrollView,
        textView: NSTextView,
        context: Context
    ) {
        let boundedHeight = max(1, viewportHeight)
        if scrollView.viewportHeight != boundedHeight {
            scrollView.viewportHeight = boundedHeight
        }

        let padding = max(0, contentPadding)
        let inset = NSSize(width: padding, height: padding)
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }

        scrollView.backgroundColor = result.bg
            .flatMap(ShikiRGBAColor.init(hex:))?
            .appKitColor ?? .clear

        if let cachedContentSize = context.coordinator.estimatedContentSize {
            scrollView.renderedDocumentSize = Self.documentSize(
                contentSize: cachedContentSize,
                padding: padding
            )
        }

        guard context.coordinator.needsRender(renderID: renderID, font: font) else {
            return
        }

        let renderedDocument = Self.makeAttributedCode(result: result, baseFont: font)
        textView.textStorage?.setAttributedString(renderedDocument.attributedCode)
        context.coordinator.didRender(
            renderID: renderID,
            font: font,
            estimatedContentSize: renderedDocument.estimatedContentSize
        )

        scrollView.renderedDocumentSize = Self.documentSize(
            contentSize: renderedDocument.estimatedContentSize,
            padding: padding
        )
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func makeAttributedCode(
        result: TokensResult,
        baseFont: NSFont
    ) -> RenderedDocument {
        let output = NSMutableAttributedString(string: "")
        output.beginEditing()
        var extent = DocumentExtentEstimator(font: baseFont)
        let defaultForeground = result.fg
            .flatMap(ShikiRGBAColor.init(hex:))?
            .appKitColor ?? .textColor
        let separatorAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: defaultForeground,
        ]

        for (lineIndex, line) in result.tokens.enumerated() {
            if lineIndex > 0 {
                output.append(
                    NSAttributedString(string: "\n", attributes: separatorAttributes)
                )
                extent.appendLineBreak()
            }

            for token in line {
                output.append(
                    NSAttributedString(
                        string: token.content,
                        attributes: attributes(
                            for: token,
                            baseFont: baseFont,
                            defaultForeground: defaultForeground
                        )
                    )
                )
                extent.append(token.content)
            }
        }

        output.endEditing()
        return RenderedDocument(
            attributedCode: output,
            estimatedContentSize: extent.contentSize
        )
    }

    private static func documentSize(contentSize: NSSize, padding: CGFloat) -> NSSize {
        NSSize(
            width: min(maximumDocumentSize.width, contentSize.width + padding * 2),
            height: min(maximumDocumentSize.height, contentSize.height + padding * 2)
        )
    }

    // NSTextView uses finite layout coordinates. These bounds support lines up
    // to roughly one million points wide and hundreds of thousands of rows,
    // without the overflow behavior caused by CGFloat.greatestFiniteMagnitude.
    private static let maximumDocumentSize = NSSize(
        width: 1_000_000,
        height: 5_000_000
    )

    private struct RenderedDocument {
        let attributedCode: NSAttributedString
        let estimatedContentSize: NSSize
    }

    private struct DocumentExtentEstimator {
        private let asciiAdvance: CGFloat
        private let nonASCIIAdvance: CGFloat
        private let lineHeight: CGFloat
        private var currentLineWidth: CGFloat = 0
        private var maximumLineWidth: CGFloat = 0
        private var lineCount = 1

        init(font: NSFont) {
            asciiAdvance = max(1, font.maximumAdvancement.width)
            // Emoji and CJK glyphs commonly come from wider fallback fonts. A
            // conservative two-cell estimate plus a small overhang allowance
            // avoids clipping without invoking glyph layout for every line.
            nonASCIIAdvance = max(asciiAdvance * 2.3, font.pointSize * 1.5)
            lineHeight = ceil(font.ascender - font.descender + font.leading)
        }

        mutating func append(_ content: String) {
            for byte in content.utf8 {
                switch byte {
                case 0x0A:
                    appendLineBreak()
                case 0x09:
                    currentLineWidth += asciiAdvance * 4
                case 0x00...0x7F:
                    currentLineWidth += asciiAdvance
                case 0x80...0xBF:
                    continue
                default:
                    currentLineWidth += nonASCIIAdvance
                }
            }
        }

        mutating func appendLineBreak() {
            maximumLineWidth = max(maximumLineWidth, currentLineWidth)
            currentLineWidth = 0
            lineCount += 1
        }

        var contentSize: NSSize {
            NSSize(
                width: max(maximumLineWidth, currentLineWidth) + asciiAdvance,
                height: CGFloat(lineCount) * lineHeight
            )
        }
    }

    private static func attributes(
        for token: ThemedToken,
        baseFont: NSFont,
        defaultForeground: NSColor
    ) -> [NSAttributedString.Key: Any] {
        let style = token.fontStyle == .notSet ? FontStyle.none : token.fontStyle ?? .none
        var attributes: [NSAttributedString.Key: Any] = [
            .font: styledFont(baseFont, style: style),
            .foregroundColor: token.color
                .flatMap(ShikiRGBAColor.init(hex:))?
                .appKitColor ?? defaultForeground,
        ]

        if let background = token.bgColor
            .flatMap(ShikiRGBAColor.init(hex:))?
            .appKitColor {
            attributes[.backgroundColor] = background
        }
        if style.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        return attributes
    }

    private static func styledFont(_ baseFont: NSFont, style: FontStyle) -> NSFont {
        var traits = baseFont.fontDescriptor.symbolicTraits
        if style.contains(.bold) {
            traits.insert(.bold)
        }
        if style.contains(.italic) {
            traits.insert(.italic)
        }

        guard traits != baseFont.fontDescriptor.symbolicTraits else {
            return baseFont
        }

        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
    }

    final class Coordinator {
        private var renderedID: Int?
        private var renderedFont: NSFont?
        private(set) var estimatedContentSize: NSSize?

        func needsRender(renderID: Int, font: NSFont) -> Bool {
            renderedID != renderID || renderedFont?.isEqual(font) != true
        }

        func didRender(
            renderID: Int,
            font: NSFont,
            estimatedContentSize: NSSize
        ) {
            renderedID = renderID
            renderedFont = font
            self.estimatedContentSize = estimatedContentSize
        }
    }
}

final class StressTestScrollView: NSScrollView {
    var viewportHeight: CGFloat = 420 {
        didSet {
            guard viewportHeight != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: viewportHeight)
    }

    var renderedDocumentSize: NSSize = .zero {
        didSet {
            updateDocumentFrame()
        }
    }

    override func layout() {
        super.layout()
        updateDocumentFrame()
    }

    private func updateDocumentFrame() {
        guard let documentView else { return }
        let size = NSSize(
            width: max(renderedDocumentSize.width, contentSize.width),
            height: max(renderedDocumentSize.height, contentSize.height)
        )
        guard documentView.frame.size != size else { return }
        documentView.setFrameSize(size)
    }
}

private extension ShikiRGBAColor {
    var appKitColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }
}

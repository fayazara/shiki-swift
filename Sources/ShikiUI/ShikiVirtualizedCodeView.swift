#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import ShikiCore
import SwiftUI

/// A selectable macOS code viewport backed by TextKit 2. Source text is retained
/// in full; token attributes and text layout are prepared on demand.
///
/// Change `renderID` whenever the token result changes. Unrelated SwiftUI updates
/// with the same ID and font preserve the document, selection, and scroll position.
public struct ShikiVirtualizedCodeView: View {
    public let result: TokensResult
    public let renderID: AnyHashable
    public var font: NSFont
    public var contentPadding: CGFloat
    public var viewportHeight: CGFloat

    public init(
        result: TokensResult,
        renderID: AnyHashable,
        font: NSFont = .monospacedSystemFont(ofSize: 15, weight: .regular),
        contentPadding: CGFloat = 8,
        viewportHeight: CGFloat = 420
    ) {
        self.result = result
        self.renderID = renderID
        self.font = font
        self.contentPadding = contentPadding
        self.viewportHeight = viewportHeight
    }

    public var body: some View {
        ShikiTextViewport(result: result, renderID: renderID, font: font, padding: contentPadding)
            .frame(height: max(1, viewportHeight))
    }
}

struct ShikiTextViewport: NSViewRepresentable {
    let result: TokensResult
    let renderID: AnyHashable
    let font: NSFont
    let padding: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        // A nonempty initial viewport prevents NSTextView from trying to lay
        // out the entire document before SwiftUI assigns its final bounds.
        let scrollView = ShikiTextScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        let clipView = ShikiTextClipView(frame: scrollView.contentView.frame)
        scrollView.contentView = clipView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let textView = ShikiViewportTextView(usingTextLayoutManager: true)
        textView.frame = scrollView.contentView.bounds
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.isHorizontallyResizable = true
        // Keep a stable estimated document extent; asking TextKit for the full
        // used rect would force layout of every paragraph.
        textView.isVerticallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 1_000_000, height: 5_000_000)
        textView.textContainer?.containerSize = textView.maxSize
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        // Content-storage delegates can be queried for every paragraph while
        // indexing a replacement document. Validate styles at layout time instead.
        textView.textLayoutManager?.renderingAttributesValidator = { [weak coordinator] manager, fragment in
            MainActor.assumeIsolated {
                coordinator?.validateAttributes(manager: manager, fragment: fragment)
            }
        }
        clipView.willScroll = { [weak coordinator, weak textView, weak clipView] point in
            guard let textView, let clipView else { return }
            coordinator?.prepareScroll(to: point.y, textView: textView, viewportHeight: clipView.bounds.height)
        }
        scrollView.willLayoutViewport = { [weak clipView] in
            guard let clipView else { return }
            clipView.willScroll?(clipView.bounds.origin)
        }
        textView.setAccessibilityLabel("Highlighted code")
        textView.setAccessibilityHelp("Read-only syntax-highlighted source code")
        scrollView.documentView = textView
        updateScrollView(scrollView, coordinator: coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        updateScrollView(nsView, coordinator: context.coordinator)
    }

    func updateScrollView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let scrollView = nsView as? ShikiTextScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        let inset = max(0, padding)
        textView.textContainerInset = NSSize(width: inset, height: inset)
        scrollView.backgroundColor = result.bg.flatMap(ShikiRGBAColor.init(hex:))?.appKitColor ?? .clear
        if coordinator.renderID != renderID || coordinator.document?.font.isEqual(font) != true {
            let document = ShikiTextDocument(result: result, font: font)
            coordinator.document = document
            coordinator.renderID = renderID
            coordinator.lastScrollY = 0
            textView.font = font
            textView.defaultParagraphStyle = document.baseAttributes[.paragraphStyle] as? NSParagraphStyle
            textView.textContentStorage?.performEditingTransaction {
                textView.textStorage?.setAttributedString(NSAttributedString(
                    string: document.source as String, attributes: document.baseAttributes
                ))
            }
            coordinator.prepareScroll(to: 0, textView: textView, viewportHeight: scrollView.contentSize.height)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if let document = coordinator.document {
            scrollView.documentExtent = NSSize(
                width: min(1_000_000, document.estimatedWidth + inset * 2),
                height: min(5_000_000, CGFloat(document.visualLineOffsets.count) * document.lineHeight + inset * 2)
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var renderID: AnyHashable?
        var document: ShikiTextDocument?
        var lastScrollY: CGFloat = 0

        func prepareScroll(to y: CGFloat, textView: NSTextView, viewportHeight: CGFloat) {
            let distance = abs(y - lastScrollY)
            lastScrollY = y
            guard let document,
                  let manager = textView.textLayoutManager,
                  let content = manager.textContentManager else { return }
            let offsets = document.visualLineOffsets
            let row = min(offsets.count - 1,
                          max(0, Int((y - textView.textContainerInset.height) / document.lineHeight)))
            guard distance > max(1, viewportHeight) * 2 else { return }
            guard let location = content.location(content.documentRange.location,
                                                  offsetBy: offsets[row]) else { return }
            let viewport = manager.textViewportLayoutController
            let anchor = viewport.relocateViewport(to: location)
            viewport.adjustViewport(byVerticalOffset: CGFloat(row) * document.lineHeight - anchor)
        }

        func validateAttributes(manager: NSTextLayoutManager, fragment: NSTextLayoutFragment) {
            guard let content = manager.textContentManager else { return }
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let length = content.offset(from: fragment.rangeInElement.location, to: fragment.rangeInElement.endLocation)
            // Always fulfill TextKit's validation request. A fragment requested
            // while offscreen may be reused during the next scroll without a
            // second callback. Skipping it permanently caches plain text.
            guard let attributed = document?.paragraph(in: NSRange(location: start, length: length)) else { return }
            attributed.enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, range, _ in
                guard let location = content.location(content.documentRange.location, offsetBy: start + range.location),
                      let end = content.location(location, offsetBy: range.length),
                      let textRange = NSTextRange(location: location, end: end) else { return }
                manager.setRenderingAttributes(attributes, for: textRange)
            }
        }
    }
}

final class ShikiTextClipView: NSClipView {
    var willScroll: ((NSPoint) -> Void)?
    override func scroll(to newOrigin: NSPoint) {
        willScroll?(newOrigin)
        super.scroll(to: newOrigin)
    }
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        willScroll?(newOrigin)
        super.setBoundsOrigin(newOrigin)
    }
}

final class ShikiViewportTextView: NSTextView {
    // The scroll view owns document sizing. AppKit otherwise calls sizeToFit
    // after clip-view resizes, which requests full-document layout.
    override func sizeToFit() {}

    // NSTextView's default origin calculation can ensure layout for the entire
    // document when its frame changes. This unwrapped code view is always
    // top-aligned, so its origin depends only on the explicit insets.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }
}

final class ShikiTextScrollView: NSScrollView {
    var willLayoutViewport: (() -> Void)?
    var documentExtent: NSSize = .zero { didSet { updateDocumentFrame() } }
    override func layout() {
        willLayoutViewport?()
        super.layout()
        updateDocumentFrame()
    }
    private func updateDocumentFrame() {
        guard let documentView else { return }
        let size = NSSize(width: max(documentExtent.width, contentSize.width),
                          height: max(documentExtent.height, contentSize.height))
        if documentView.frame.size != size { documentView.setFrameSize(size) }
    }
}
#endif

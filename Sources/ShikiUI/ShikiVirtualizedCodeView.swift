#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import ShikiCore
import SwiftUI

/// A selectable macOS code viewport with a bounded TextKit 2 window. Source text
/// is retained in full; only visible lines and a small buffer enter text layout.
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
        let scroll = ShikiTextScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let documentView = ShikiCodeDocumentView(frame: scroll.contentView.bounds)
        scroll.documentView = documentView
        scroll.contentView.postsBoundsChangedNotifications = true
        documentView.observeScroll(scroll)
        updateScrollView(scroll, coordinator: coordinator)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        updateScrollView(nsView, coordinator: context.coordinator)
    }

    func updateScrollView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? ShikiCodeDocumentView else { return }
        scroll.backgroundColor = result.bg.flatMap(ShikiRGBAColor.init(hex:))?.appKitColor ?? .clear
        if coordinator.renderID != renderID || coordinator.document?.font.isEqual(font) != true {
            let document = ShikiTextDocument(result: result, font: font)
            coordinator.document = document
            coordinator.renderID = renderID
            view.replaceDocument(document, padding: max(0, padding))
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            view.padding = max(0, padding)
        }
        view.updateExtent()
        view.layoutVisibleText()
    }

    @MainActor
    final class Coordinator: NSObject {
        var renderID: AnyHashable?
        var document: ShikiTextDocument?
    }
}

/// The scrollable extent is independent of TextKit's small, fully styled window.
/// All selection coordinates refer to the full source, never to that window.
final class ShikiCodeDocumentView: NSView, NSTextViewDelegate {
    let textView = ShikiViewportTextView(usingTextLayoutManager: true)
    private(set) var document: ShikiTextDocument?
    private(set) var loadedLines = 0..<0
    private(set) var loadedRange = NSRange(location: 0, length: 0)
    private(set) var selection = NSRange(location: 0, length: 0)
    private var selectionAnchor = 0
    private var selectionHead = 0
    private var updating = false
    private var applyingSelection = false
    private var dragEvent: NSEvent?
    private var dragInitial = NSRange(location: 0, length: 0)
    private var dragClickCount = 1
    private var dragExtendsSelection = false
    var padding: CGFloat = 8 {
        didSet {
            if padding != oldValue { loadedLines = 0..<0; updateExtent(); layoutVisibleText() }
        }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var string: String { document?.source as String? ?? "" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.owner = self
        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 1_000_000, height: 5_000_000)
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityElement(false)
        addSubview(textView)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Highlighted code")
        setAccessibilityHelp("Read-only syntax-highlighted source code")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func observeScroll(_ scroll: NSScrollView) {
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    @objc private func viewportChanged() { layoutVisibleText() }

    func replaceDocument(_ document: ShikiTextDocument, padding: CGFloat) {
        self.document = document
        self.padding = padding
        loadedLines = 0..<0
        loadedRange = NSRange(location: 0, length: 0)
        selection = NSRange(location: 0, length: 0)
        selectionAnchor = 0
        selectionHead = 0
    }

    func updateExtent() {
        guard let document, let scroll = enclosingScrollView else { return }
        let size = NSSize(width: max(scroll.contentSize.width, min(1_000_000, document.estimatedWidth + padding * 2)),
                          height: max(scroll.contentSize.height, CGFloat(document.visualLineOffsets.count) * document.lineHeight + padding * 2))
        if frame.size != size { setFrameSize(size) }
    }

    var visibleLines: Range<Int> {
        guard let document else { return 0..<0 }
        let bounds = enclosingScrollView?.contentView.bounds ?? visibleRect
        let count = document.visualLineOffsets.count
        let first = min(count - 1, max(0, Int(floor((bounds.minY - padding) / document.lineHeight))))
        let end = min(count, max(first + 1, Int(ceil((bounds.maxY - padding) / document.lineHeight))))
        return first..<end
    }

    func layoutVisibleText() {
        guard !updating, let document else { return }
        updating = true
        defer { updating = false }
        let visible = visibleLines
        // Refill in batches rather than replacing text on every trackpad event.
        // Even a jump to EOF only touches this window, never intervening rows.
        if loadedLines.isEmpty || visible.lowerBound < loadedLines.lowerBound
            || visible.upperBound > loadedLines.upperBound {
            let first = max(0, visible.lowerBound - 16)
            let end = min(document.visualLineOffsets.count, visible.upperBound + 16)
            loadedLines = first..<end
            let startOffset = document.visualLineOffsets[first]
            let endOffset = end < document.visualLineOffsets.count ? document.visualLineOffsets[end] : document.source.length
            loadedRange = NSRange(location: startOffset, length: endOffset - startOffset)
            let attributed = NSMutableAttributedString(string: "")
            for row in loadedLines {
                let start = document.visualLineOffsets[row]
                let end = row + 1 < document.visualLineOffsets.count ? document.visualLineOffsets[row + 1] : document.source.length
                if let paragraph = document.paragraph(in: NSRange(location: start, length: end - start)) {
                    attributed.append(paragraph)
                }
            }
            textView.font = document.font
            textView.defaultParagraphStyle = document.baseAttributes[.paragraphStyle] as? NSParagraphStyle
            textView.textStorage?.setAttributedString(attributed)
            applySelection()
        }
        textView.textContainerInset = NSSize(width: padding, height: 0)
        textView.frame = NSRect(x: 0, y: padding + CGFloat(loadedLines.lowerBound) * document.lineHeight,
                                width: frame.width, height: CGFloat(loadedLines.count) * document.lineHeight)
        textView.needsDisplay = true
    }

    func selectedRange() -> NSRange { selection }
    func setSelectedRange(_ range: NSRange) {
        guard let document else { return }
        let start = min(max(0, range.location), document.source.length)
        let length = min(max(0, range.length), document.source.length - start)
        selectionAnchor = start
        selectionHead = start + length
        updateSelection()
    }

    private func updateSelection() {
        selection = NSRange(location: min(selectionAnchor, selectionHead), length: abs(selectionAnchor - selectionHead))
        applySelection()
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Native commands/services that change the local selection must also
        // update the full-document selection used by Copy and accessibility.
        guard !updating, !applyingSelection else { return }
        let range = textView.selectedRange()
        guard range.location != NSNotFound else { return }
        setSelectedRange(NSRange(location: loadedRange.location + range.location, length: range.length))
    }

    private func applySelection() {
        applyingSelection = true
        defer { applyingSelection = false }
        let start = max(selection.location, loadedRange.location)
        let end = min(NSMaxRange(selection), NSMaxRange(loadedRange))
        if end >= start {
            textView.setSelectedRange(NSRange(location: start - loadedRange.location, length: end - start))
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        textView.needsDisplay = true
    }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string), let document else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(document.source.substring(with: selection), forType: .string)
    }
    @objc func copy(_ sender: Any?) { _ = writeSelection(to: .general, types: [.string]) }
    override func selectAll(_ sender: Any?) {
        setSelectedRange(NSRange(location: 0, length: document?.source.length ?? 0))
    }

    private func offset(at event: NSEvent) -> Int {
        guard let document else { return 0 }
        let point = convert(event.locationInWindow, from: nil)
        if point.y < padding { return 0 }
        if point.y >= padding + CGFloat(document.visualLineOffsets.count) * document.lineHeight { return document.source.length }
        let local = textView.convert(event.locationInWindow, from: nil)
        let index = textView.characterIndexForInsertion(at: local)
        return min(document.source.length, loadedRange.location + min(index, loadedRange.length))
    }

    override func mouseDown(with event: NSEvent) { trackSelection(with: event) }
    func trackSelection(with event: NSEvent) {
        guard document != nil, let window else { return }
        window.makeFirstResponder(textView)
        dragClickCount = event.clickCount
        dragExtendsSelection = event.modifierFlags.contains(.shift)
        dragInitial = selectionUnit(at: offset(at: event))
        if !dragExtendsSelection { selectionAnchor = dragInitial.location }
        selectionHead = NSMaxRange(dragInitial)
        updateSelection()
        dragEvent = event
        let timer = Timer(timeInterval: 1.0 / 60, target: self,
                          selector: #selector(extendDragSelection), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate(); dragEvent = nil }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                           inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            dragEvent = next
            extendDragSelection()
        }
    }
    private func selectionUnit(at position: Int) -> NSRange {
        guard let document, document.source.length > 0 else { return NSRange(location: 0, length: 0) }
        let index = min(position, document.source.length - 1)
        if dragClickCount >= 3 { return document.source.lineRange(for: NSRange(location: index, length: 0)) }
        if dragClickCount == 2 { return document.plainText.doubleClick(at: index) }
        return NSRange(location: position, length: 0)
    }
    @objc private func extendDragSelection() {
        guard let event = dragEvent else { return }
        _ = autoscroll(with: event)
        layoutVisibleText()
        let target = selectionUnit(at: offset(at: event))
        if dragClickCount > 1 && !dragExtendsSelection {
            selectionAnchor = target.location < dragInitial.location ? NSMaxRange(dragInitial) : dragInitial.location
        }
        selectionHead = target.location < selectionAnchor ? target.location : NSMaxRange(target)
        updateSelection()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let document else { return false }
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        if command, event.charactersIgnoringModifiers == "a" { selectAll(nil); return true }
        if command, event.charactersIgnoringModifiers == "c" { copy(nil); return true }
        let source = document.source
        var target = selectionHead
        switch event.keyCode {
        case 123, 124: // Left/right, including word and line movement.
            let forward = event.keyCode == 124
            if command {
                let line = source.lineRange(for: NSRange(location: target, length: 0))
                target = forward ? contentEnd(of: line) : line.location
            } else if option {
                target = document.plainText.nextWord(from: target, forward: forward)
            } else if !shift && selection.length > 0 {
                target = forward ? NSMaxRange(selection) : selection.location
            } else if forward && target < source.length {
                target = NSMaxRange(source.rangeOfComposedCharacterSequence(at: target))
            } else if !forward && target > 0 {
                target = source.rangeOfComposedCharacterSequence(at: target - 1).location
            }
        case 125, 126: // Down/up.
            if command { target = event.keyCode == 125 ? source.length : 0 }
            else {
                let row = lineIndex(at: target)
                let next = min(document.visualLineOffsets.count - 1, max(0, row + (event.keyCode == 125 ? 1 : -1)))
                let start = document.visualLineOffsets[next]
                let range = source.lineRange(for: NSRange(location: start, length: 0))
                target = min(contentEnd(of: range), start + target - document.visualLineOffsets[row])
                if target < source.length { target = source.rangeOfComposedCharacterSequence(at: target).location }
            }
        case 115: target = 0 // Home/end.
        case 119: target = source.length
        case 116, 121: // Page up/down only scrolls the viewport.
            if let scroll = enclosingScrollView {
                let bounds = scroll.contentView.bounds
                let y = min(max(0, frame.height - bounds.height), max(0, bounds.minY + (event.keyCode == 121 ? 1 : -1) * bounds.height))
                scroll.contentView.scroll(to: NSPoint(x: bounds.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            return true
        default: return false
        }
        selectionHead = min(source.length, max(0, target))
        if !shift { selectionAnchor = selectionHead }
        updateSelection()
        revealSelection()
        return true
    }
    private func contentEnd(of range: NSRange) -> Int {
        guard let document else { return 0 }
        var end = NSMaxRange(range)
        while end > range.location && CharacterSet.newlines.contains(UnicodeScalar(document.source.character(at: end - 1)) ?? " ") { end -= 1 }
        return end
    }
    private func lineIndex(at offset: Int) -> Int {
        guard let offsets = document?.visualLineOffsets else { return 0 }
        var low = 0
        var high = offsets.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
    private func revealSelection() {
        guard let document else { return }
        let y = padding + CGFloat(lineIndex(at: selectionHead)) * document.lineHeight
        scrollToVisible(NSRect(x: enclosingScrollView?.contentView.bounds.minX ?? 0, y: y, width: 1, height: document.lineHeight))
        layoutVisibleText()
        let index = min(loadedRange.length, max(0, selectionHead - loadedRange.location))
        textView.scrollRangeToVisible(NSRange(location: index, length: 0))
    }

    override func accessibilityValue() -> Any? { string }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === textView }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { window?.makeFirstResponder(textView) }
    }
    override func accessibilitySelectedText() -> String? { document?.source.substring(with: selection) }
    override func accessibilitySelectedTextRange() -> NSRange { selection }
    override func setAccessibilitySelectedTextRange(_ range: NSRange) { setSelectedRange(range); revealSelection() }
    override func accessibilityNumberOfCharacters() -> Int { document?.source.length ?? 0 }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        guard let document else { return NSRange(location: 0, length: 0) }
        let rows = visibleLines
        let start = document.visualLineOffsets[rows.lowerBound]
        let end = rows.upperBound < document.visualLineOffsets.count ? document.visualLineOffsets[rows.upperBound] : document.source.length
        return NSRange(location: start, length: end - start)
    }
    override func accessibilityString(for range: NSRange) -> String? {
        guard let document, range.location >= 0, range.length >= 0,
              range.location <= document.source.length, range.length <= document.source.length - range.location else { return nil }
        return document.source.substring(with: range)
    }
}

final class ShikiViewportTextView: NSTextView {
    weak var owner: ShikiCodeDocumentView?
    override func sizeToFit() {}
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: 0) }
    override func mouseDown(with event: NSEvent) { owner?.trackSelection(with: event) }
    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event) != true { super.keyDown(with: event) }
    }
    override func copy(_ sender: Any?) { owner?.copy(sender) }
    override func selectAll(_ sender: Any?) { owner?.selectAll(sender) }
}

final class ShikiTextScrollView: NSScrollView {
    override func layout() {
        super.layout()
        if let view = documentView as? ShikiCodeDocumentView {
            view.updateExtent()
            view.layoutVisibleText()
        }
    }
}
#endif

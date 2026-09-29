#if os(macOS)
import AppKit
import Shiki
import SwiftUI

/// Native editing with AppKit's IME, accessibility, undo, selection, and find bar.
/// TextKit permits noncontiguous glyph layout. Syntax attributes are installed only
/// in the visible range, using tokens prepared asynchronously by the Shiki actor.
@MainActor public final class NativeEditor: NSView, NSTextViewDelegate {
    public let scrollView = NSScrollView()
    public let textView: NSTextView
    private let manager = NSLayoutManager()
    private let storage = NSTextStorage()
    private let container = NSTextContainer(size: NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude))
    /// Replacing the engine preserves text, selection and undo history.
    public var highlighter: DiffHighlighter {
        didSet {
            guard highlighter !== oldValue else { return }
            prepared = nil
            scheduleHighlight(debounce: false)
        }
    }
    private var highlightTask: Task<Void, Never>?
    private var options = DiffRenderOptions()
    private var fileName = "file.txt"
    private var language: String?
    private var prepared: HighlightedDiff?
    private var lineStarts: [Int] = []
    private var styledRange = NSRange(location: 0, length: 0)
    private var applyingStyles = false
    private var codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var revision = 0
    private var observer: NotificationObservation?
    public var onChange: ((String) -> Void)?
    public var onSelectionChange: (([NSRange]) -> Void)?
    public var onError: ((Error) -> Void)?
    public var wrapsLines = false { didSet { if wrapsLines != oldValue { configureWrapping() } } }
    public private(set) var styledTokenCount = 0
    public override convenience init(frame: NSRect) {
        self.init(frame: frame, highlighter: DiffHighlighter())
    }
    /// Reuse a configured highlighter, including registered themes and languages.
    public init(frame: NSRect, highlighter: DiffHighlighter) {
        self.highlighter = highlighter
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.allowsNonContiguousLayout = true
        textView = NSTextView(frame: NSRect(origin: .zero, size: frame.size), textContainer: container)
        super.init(frame: frame)
        textView.delegate = self
        textView.isRichText = false; textView.allowsUndo = true; textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.minSize = NSSize(width: 0, height: 0); textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.autoresizingMask = [.width]
        scrollView.documentView = textView; scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true; scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView); configureWrapping()
        observer = NotificationObservation(name: NSView.boundsDidChangeNotification, object: scrollView.contentView) { [weak self] _ in
            MainActor.assumeIsolated { self?.styleVisibleTokens() }
        }
    }
    public required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    public override func layout() {
        super.layout(); scrollView.frame = bounds
        if wrapsLines { textView.frame.size.width = scrollView.contentSize.width }
        styleVisibleTokens()
    }
    public func render(_ file: FileContents, options: DiffRenderOptions = .init()) {
        let changed = !textView.string.utf16.elementsEqual(file.contents.utf16)
        let needsHighlight = changed || self.options.theme != options.theme
            || self.options.tokenizeMaxLineLength != options.tokenizeMaxLineLength
            || self.options.tokenizeMaxLength != options.tokenizeMaxLength
            || language != file.lang || fileName != file.name || revision == 0
        self.options = options; fileName = file.name; language = file.lang
        let font = options.fontName.flatMap { NSFont(name: $0, size: options.fontSize) }
            ?? NSFont.monospacedSystemFont(ofSize: options.fontSize, weight: .regular)
        if codeFont != font { codeFont = font; textView.font = font }
        if changed { textView.string = file.contents; textView.undoManager?.removeAllActions(); prepared = nil }
        if needsHighlight { scheduleHighlight(debounce: false) }
        else { styleVisibleTokens() }
    }
    public func textDidChange(_ notification: Notification) {
        prepared = nil; revision += 1
        onChange?(textView.string); scheduleHighlight(debounce: true)
    }
    public func textViewDidChangeSelection(_ notification: Notification) { onSelectionChange?(textView.selectedRanges.map(\.rangeValue)) }
    public func replaceCharacters(in range: NSRange, with string: String) {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= storage.length else { return }
        textView.insertText(string, replacementRange: range)
    }
    public func select(_ ranges: [NSRange]) { textView.selectedRanges = ranges.map { NSValue(range: $0) } }
    public func find() { let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue; textView.performFindPanelAction(item) }
    private func configureWrapping() {
        container.widthTracksTextView = wrapsLines
        textView.isHorizontallyResizable = !wrapsLines
        container.containerSize = NSSize(width: wrapsLines ? max(1, bounds.width - 32) : 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        scrollView.hasHorizontalScroller = !wrapsLines; needsLayout = true
    }
    private func scheduleHighlight(debounce: Bool) {
        highlightTask?.cancel(); revision += 1
        let currentRevision = revision, contents = textView.string, file = FileContents(name: fileName, contents: textView.string, lang: language), options = options
        highlightTask = Task { [weak self, highlighter] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(150)) }
                let result = try await highlighter.prepare(oldFile: file, newFile: file, options: options)
                try Task.checkCancellation()
                guard let self, self.revision == currentRevision else { return }
                self.prepared = result
                self.lineStarts = [0]
                for (offset, unit) in contents.utf16.enumerated() where unit == 10 { self.lineStarts.append(offset + 1) }
                self.textView.backgroundColor = .diffHex(result.background)
                self.textView.textColor = .diffHex(result.foreground)
                self.textView.insertionPointColor = .diffHex(result.foreground)
                self.styleVisibleTokens()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, let self, self.revision == currentRevision else { return }
                self.onError?(error)
            }
        }
    }
    private func styleVisibleTokens() {
        guard !applyingStyles, let prepared, !lineStarts.isEmpty, storage.length > 0 else { return }
        applyingStyles = true; defer { applyingStyles = false }
        var rect = scrollView.contentView.bounds
        rect.origin.x -= textView.textContainerInset.width; rect.origin.y -= textView.textContainerInset.height
        rect = rect.insetBy(dx: 0, dy: -options.lineHeight * 8)
        let glyphs = manager.glyphRange(forBoundingRect: rect, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        func lineAt(_ offset: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high { let mid = (low + high + 1) / 2; if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 } }
            return low
        }
        let first = lineAt(characters.location), last = min(prepared.newTokens.count - 1, lineAt(NSMaxRange(characters)))
        guard last >= first else { return }
        let end = last + 1 < lineStarts.count ? lineStarts[last + 1] : storage.length
        let nextRange = NSRange(location: lineStarts[first], length: end - lineStarts[first])
        var fontRuns: [(NSRange, NSFont)] = []
        if styledRange.length > 0 {
            let range = NSIntersectionRange(styledRange, NSRange(location: 0, length: storage.length))
            for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .font, .underlineStyle, .strikethroughStyle] {
                manager.removeTemporaryAttribute(key, forCharacterRange: range)
            }
            let beforeEnd = min(NSMaxRange(range), nextRange.location)
            if beforeEnd > range.location { fontRuns.append((NSRange(location: range.location, length: beforeEnd - range.location), codeFont)) }
            let afterStart = max(range.location, NSMaxRange(nextRange))
            if NSMaxRange(range) > afterStart { fontRuns.append((NSRange(location: afterStart, length: NSMaxRange(range) - afterStart), codeFont)) }
        }
        styledTokenCount = 0
        let baseFont = codeFont
        var styledFonts: [FontStyle: NSFont] = [:]
        for line in first...last {
            var offset = lineStarts[line]
            for token in prepared.newTokens[line] {
                let length = min(token.content.utf16.count, max(0, storage.length - offset))
                if length > 0 {
                    var attributes: [NSAttributedString.Key: Any] = [:]
                    var tokenFont = baseFont
                    if let color = token.color, !color.isEmpty { attributes[.foregroundColor] = NSColor.diffHex(color) }
                    if let color = token.bgColor, !color.isEmpty { attributes[.backgroundColor] = NSColor.diffHex(color) }
                    if let style = token.fontStyle, style != .notSet {
                        let traits = style.intersection([.bold, .italic])
                        if !traits.isEmpty {
                            let font: NSFont
                            if let cached = styledFonts[traits] { font = cached }
                            else {
                                var value = baseFont
                                if traits.contains(.bold) { value = NSFontManager.shared.convert(value, toHaveTrait: .boldFontMask) }
                                if traits.contains(.italic) { value = NSFontManager.shared.convert(value, toHaveTrait: .italicFontMask) }
                                styledFonts[traits] = value; font = value
                            }
                            tokenFont = font
                        }
                        if style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                        if style.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    }
                    fontRuns.append((NSRange(location: offset, length: length), tokenFont))
                    manager.addTemporaryAttributes(attributes, forCharacterRange: NSRange(location: offset, length: length)); styledTokenCount += 1
                }
                offset += token.content.utf16.count
            }
        }
        // Fonts affect glyph layout, so NSLayoutManager ignores them as temporary
        // attributes. Change only differing text-storage runs, in one transaction.
        var changes: [(NSRange, NSFont)] = []
        for (range, font) in fontRuns {
            storage.enumerateAttribute(.font, in: range) { value, run, _ in
                if (value as? NSFont) != font { changes.append((run, font)) }
            }
        }
        if !changes.isEmpty {
            storage.beginEditing()
            for (range, font) in changes { storage.addAttribute(.font, value: font, range: range) }
            storage.endEditing()
        }
        styledRange = nextRange
    }
}
public struct EditorView: NSViewRepresentable {
    @Binding public var text: String
    public var name: String
    public var options: DiffRenderOptions
    public var wrapsLines: Bool
    public var highlighter: DiffHighlighter?
    @MainActor public final class Coordinator {
        let defaultHighlighter = DiffHighlighter()
    }
    public init(text: Binding<String>, name: String, options: DiffRenderOptions = .init(), wrapsLines: Bool = false, highlighter: DiffHighlighter? = nil) {
        _text = text; self.name = name; self.options = options; self.wrapsLines = wrapsLines; self.highlighter = highlighter
    }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func makeNSView(context: Context) -> NativeEditor {
        NativeEditor(frame: .zero, highlighter: highlighter ?? context.coordinator.defaultHighlighter)
    }
    public func updateNSView(_ view: NativeEditor, context: Context) {
        view.highlighter = highlighter ?? context.coordinator.defaultHighlighter
        view.onChange = { text = $0 }; view.wrapsLines = wrapsLines
        view.render(.init(name: name, contents: text), options: options)
    }
}

#endif

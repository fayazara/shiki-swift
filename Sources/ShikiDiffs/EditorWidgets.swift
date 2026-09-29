#if os(macOS)
import AppKit

/// Retain this renderer across SwiftUI updates to keep mounted content alive.
@MainActor public final class EditorSelectionActionRenderer {
    public let render: (SelectionActionContext) -> NSView?
    public init(render: @escaping (SelectionActionContext) -> NSView?) { self.render = render }
}
/// Only visible collaborator focus positions mount views. Returning nil hides
/// the caret widget while retaining its selection highlight.
@MainActor public final class EditorCaretRenderer {
    public let render: (EditorCaret) -> NSView?
    public init(render: @escaping (EditorCaret) -> NSView?) { self.render = render }
}

/// A live, weak reference to the primary selection, valid only while this widget
/// belongs to the attached editor. Document values are copy-on-write snapshots.
@MainActor public final class SelectionActionContext {
    private weak var editor: DiffEditor?
    let id: UUID
    init(editor: DiffEditor, id: UUID) { self.editor = editor; self.id = id }
    private var activeEditor: DiffEditor? {
        guard let editor, editor.isActive, editor.predictionView != nil, editor.selectionActionID == id else { return nil }
        return editor
    }
    public var isActive: Bool { activeEditor != nil }
    public var selection: EditorSelection? { activeEditor?.getSelections().last }
    public var textDocument: TextDocument? { activeEditor?.document }
    public func getSelectionText() -> String {
        guard let editor = activeEditor, let selection = editor.getSelections().last else { return "" }
        return editor.document.getTextSlice(start: editor.document.offsetAt(selection.start), end: editor.document.offsetAt(selection.end))
    }
    @discardableResult public func applyEdits(_ edits: [TextEdit]) throws -> Bool {
        guard let editor = activeEditor else { return false }
        return try editor.applyEdits(edits)
    }
    @discardableResult public func replaceSelectionText(_ text: String) throws -> Bool {
        guard let editor = activeEditor, let selection = editor.getSelections().last else { return false }
        return try editor.replaceActionSelection(selection, text: text)
    }
    public func close() { activeEditor?.closeSelectionAction(revealCaret: true) }
}

/// The same four-pixel flip hysteresis as the upstream shared popover manager.
struct EditorPopoverPlacement {
    var usedFallback = false
    mutating func choose(preferred: CGRect, fallback: CGRect?, viewport: CGRect) -> CGRect {
        guard let fallback else { usedFallback = false; return preferred }
        func fits(_ rect: CGRect, margin: CGFloat = 0) -> Bool {
            rect.minY >= viewport.minY + margin && rect.maxY <= viewport.maxY - margin
        }
        usedFallback = (usedFallback && fits(fallback) && !fits(preferred, margin: 4)) || (!fits(preferred) && fits(fallback))
        return usedFallback ? fallback : preferred
    }
}

@MainActor final class EditorSelectionActionHost: NSView {
    let content: NSView
    private var observer: NSObjectProtocol?
    var onResize: (() -> Void)?
    override var isFlipped: Bool { true }
    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        identifier = .init("ShikiDiffs.selectionAction")
        wantsLayer = true; layer?.cornerRadius = 9; layer?.borderWidth = 1
        layer?.shadowOpacity = 0.12; layer?.shadowRadius = 5; layer?.shadowOffset = .init(width: 0, height: -2)
        addSubview(content)
        content.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResize?() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func measure(maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let intrinsic = content.fittingSize
        let width = max(1, min(maxWidth, (intrinsic.width > 0 ? intrinsic.width : content.frame.width) + 10))
        content.setFrameSize(.init(width: max(0, width - 10), height: max(1, intrinsic.height > 0 ? intrinsic.height : content.frame.height)))
        content.layoutSubtreeIfNeeded()
        let height = max(1, min(maxHeight, max(content.fittingSize.height, content.frame.height) + 10))
        content.setFrameOrigin(.init(x: 5, y: 5))
        return .init(width: width, height: height)
    }
}

#endif

#if os(macOS)
import AppKit

/// The source line currently targeted by a gutter utility.
public struct DiffHoveredLine: Equatable, Sendable {
    public let lineNumber: Int
    public let side: DiffSide
    public init(lineNumber: Int, side: DiffSide) { self.lineNumber = lineNumber; self.side = side }
}
/// Creates one retained control. Read the supplied getter when the control acts;
/// its current target can change without recreating the view.
public typealias DiffGutterUtilityRenderer = @MainActor (@escaping @MainActor () -> DiffHoveredLine?) -> NSView?

/// Stable renderer identity for SwiftUI updates. Keep this object in host state
/// to retain a control while unrelated view properties change.
@MainActor public final class DiffGutterRenderer {
    public let render: DiffGutterUtilityRenderer
    public init(_ render: @escaping DiffGutterUtilityRenderer) { self.render = render }
}

public struct FileHoveredLine: Equatable, Sendable {
    public let lineNumber: Int
    public init(lineNumber: Int) { self.lineNumber = lineNumber }
}
@MainActor public final class FileGutterRenderer {
    public let render: (@escaping @MainActor () -> FileHoveredLine?) -> NSView?
    public init(_ render: @escaping (@escaping @MainActor () -> FileHoveredLine?) -> NSView?) { self.render = render }
    var adapted: DiffGutterUtilityRenderer {
        { read in self.render { read().map { FileHoveredLine(lineNumber: $0.lineNumber) } } }
    }
}
/// Review targets are resolved at action time, including item rename/reordering.
@MainActor public struct CodeViewGutterTarget {
    public let itemID: String?
    public let document: HighlightedDiff
    public let file: FileContents?
    public let lineNumber: Int
    public let side: DiffSide?
}
@MainActor public final class CodeViewGutterRenderer {
    public let render: (@escaping @MainActor () -> CodeViewGutterTarget?) -> NSView?
    public init(_ render: @escaping (@escaping @MainActor () -> CodeViewGutterTarget?) -> NSView?) { self.render = render }
}

public enum LineHoverHighlight: String, CaseIterable, Sendable {
    case disabled, both, number, line
}

public enum DiffLineType: String, Sendable {
    case changeDeletion = "change-deletion", changeAddition = "change-addition"
    case context, contextExpanded = "context-expanded"
}

/// Native line-event payload. Rectangles are in `view` coordinates and identify
/// the physical wrapped fragment, without allocating a view for every code row.
@MainActor public struct DiffLineClickEvent {
    public let fileDiff: FileDiffMetadata
    public let lineNumber: Int
    public let annotationSide: DiffSide
    public let lineType: DiffLineType
    public let numberColumn: Bool
    public let view: NSView
    public let lineRect: NSRect
    public let numberRect: NSRect
    public let event: NSEvent
}

@MainActor protocol TokenGeometryProviding: AnyObject {
    func visibleTokenRects(lineNumber: Int, side: DiffSide, range: NSRange, revision: UUID?) -> [NSRect]
}

@MainActor public struct DiffTokenClickEvent {
    var revision: UUID? = nil
    /// Currently visible portions of the token, in `view` coordinates. Computed
    /// lazily from shaped text; may contain multiple rectangles for wrapping/bidi.
    public var visibleRects: [NSRect] {
        (view as? any TokenGeometryProviding)?.visibleTokenRects(lineNumber: lineNumber, side: side,
            range: .init(location: lineCharStart, length: lineCharEnd - lineCharStart), revision: revision) ?? []
    }
    public let fileDiff: FileDiffMetadata
    public let lineNumber: Int
    public let side: DiffSide
    public let lineCharStart: Int
    public let lineCharEnd: Int
    public let tokenText: String
    public let view: NSView
    public let event: NSEvent
}

@MainActor public struct DiffInteractionHandlers {
    var hasHoverHandlers: Bool { enableGutterUtility || lineHoverHighlight != .disabled || onLineEnter != nil || onLineLeave != nil || onTokenEnter != nil || onTokenLeave != nil }
    public var onLineSelectionStart: ((LineSelection?) -> Void)?
    public var onLineSelectionChange: ((LineSelection?) -> Void)?
    public var onLineSelectionEnd: ((LineSelection?) -> Void)?
    public var onLineSelected: ((LineSelection?) -> Void)?
    public var controlledSelection = false
    public var enableGutterUtility = false
    public var onGutterUtilityClick: ((LineSelection) -> Void)?
    public var enableLineSelection = false
    public var lineHoverHighlight: LineHoverHighlight = .disabled
    public var enableTokenInteractionsOnWhitespace = false
    public var onTokenEnter: ((DiffTokenClickEvent) -> Void)?
    public var onTokenLeave: ((DiffTokenClickEvent) -> Void)?
    public var onTokenClick: ((DiffTokenClickEvent) -> Void)?
    public var onLineClick: ((DiffLineClickEvent) -> Void)?
    public var onLineEnter: ((DiffLineClickEvent) -> Void)?
    public var onLineLeave: ((DiffLineClickEvent) -> Void)?
    public var onLineNumberClick: ((DiffLineClickEvent) -> Void)?
    public init(onLineClick: ((DiffLineClickEvent) -> Void)? = nil, onLineNumberClick: ((DiffLineClickEvent) -> Void)? = nil, onLineEnter: ((DiffLineClickEvent) -> Void)? = nil, onLineLeave: ((DiffLineClickEvent) -> Void)? = nil, enableTokenInteractionsOnWhitespace: Bool = false, onTokenClick: ((DiffTokenClickEvent) -> Void)? = nil, onTokenEnter: ((DiffTokenClickEvent) -> Void)? = nil, onTokenLeave: ((DiffTokenClickEvent) -> Void)? = nil, lineHoverHighlight: LineHoverHighlight = .disabled, enableLineSelection: Bool = false, onLineSelectionStart: ((LineSelection?) -> Void)? = nil, onLineSelectionChange: ((LineSelection?) -> Void)? = nil, onLineSelectionEnd: ((LineSelection?) -> Void)? = nil, onLineSelected: ((LineSelection?) -> Void)? = nil, controlledSelection: Bool = false, enableGutterUtility: Bool = false, onGutterUtilityClick: ((LineSelection) -> Void)? = nil) {
        self.onLineSelectionStart = onLineSelectionStart; self.onLineSelectionChange = onLineSelectionChange
        self.onLineSelectionEnd = onLineSelectionEnd; self.onLineSelected = onLineSelected
        self.enableGutterUtility = enableGutterUtility; self.onGutterUtilityClick = onGutterUtilityClick
        self.controlledSelection = controlledSelection
        self.enableLineSelection = enableLineSelection
        self.lineHoverHighlight = lineHoverHighlight
        self.onTokenEnter = onTokenEnter; self.onTokenLeave = onTokenLeave
        self.enableTokenInteractionsOnWhitespace = enableTokenInteractionsOnWhitespace; self.onTokenClick = onTokenClick
        self.onLineEnter = onLineEnter; self.onLineLeave = onLineLeave
        self.onLineClick = onLineClick; self.onLineNumberClick = onLineNumberClick
    }
}

@MainActor public struct FileLineClickEvent {
    public let file: FileContents
    public let lineNumber: Int
    public let numberColumn: Bool
    public let view: NSView
    public let lineRect: NSRect
    public let numberRect: NSRect
    public let event: NSEvent
    init(file: FileContents, diffEvent: DiffLineClickEvent) {
        self.file = file; lineNumber = diffEvent.lineNumber; numberColumn = diffEvent.numberColumn
        view = diffEvent.view; lineRect = diffEvent.lineRect; numberRect = diffEvent.numberRect; event = diffEvent.event
    }
}

@MainActor public struct FileTokenClickEvent {
    private let diffToken: DiffTokenClickEvent
    public var visibleRects: [NSRect] { diffToken.visibleRects }
    public let file: FileContents
    public let lineNumber: Int
    public let lineCharStart: Int
    public let lineCharEnd: Int
    public let tokenText: String
    public let view: NSView
    public let event: NSEvent
    init(file: FileContents, diffEvent: DiffTokenClickEvent) {
        diffToken = diffEvent
        self.file = file; lineNumber = diffEvent.lineNumber; lineCharStart = diffEvent.lineCharStart
        lineCharEnd = diffEvent.lineCharEnd; tokenText = diffEvent.tokenText; view = diffEvent.view; event = diffEvent.event
    }
}

@MainActor public struct FileInteractionHandlers {
    public var onLineSelectionStart: ((LineSelection?) -> Void)?
    public var onLineSelectionChange: ((LineSelection?) -> Void)?
    public var onLineSelectionEnd: ((LineSelection?) -> Void)?
    public var onLineSelected: ((LineSelection?) -> Void)?
    public var controlledSelection = false
    public var enableGutterUtility = false
    public var onGutterUtilityClick: ((LineSelection) -> Void)?
    public var enableLineSelection = false
    public var lineHoverHighlight: LineHoverHighlight = .disabled
    public var enableTokenInteractionsOnWhitespace = false
    public var onTokenEnter: ((FileTokenClickEvent) -> Void)?
    public var onTokenLeave: ((FileTokenClickEvent) -> Void)?
    public var onTokenClick: ((FileTokenClickEvent) -> Void)?
    public var onLineClick: ((FileLineClickEvent) -> Void)?
    public var onLineEnter: ((FileLineClickEvent) -> Void)?
    public var onLineLeave: ((FileLineClickEvent) -> Void)?
    public var onLineNumberClick: ((FileLineClickEvent) -> Void)?
    public init(onLineClick: ((FileLineClickEvent) -> Void)? = nil, onLineNumberClick: ((FileLineClickEvent) -> Void)? = nil, onLineEnter: ((FileLineClickEvent) -> Void)? = nil, onLineLeave: ((FileLineClickEvent) -> Void)? = nil, enableTokenInteractionsOnWhitespace: Bool = false, onTokenClick: ((FileTokenClickEvent) -> Void)? = nil, onTokenEnter: ((FileTokenClickEvent) -> Void)? = nil, onTokenLeave: ((FileTokenClickEvent) -> Void)? = nil, lineHoverHighlight: LineHoverHighlight = .disabled, enableLineSelection: Bool = false, onLineSelectionStart: ((LineSelection?) -> Void)? = nil, onLineSelectionChange: ((LineSelection?) -> Void)? = nil, onLineSelectionEnd: ((LineSelection?) -> Void)? = nil, onLineSelected: ((LineSelection?) -> Void)? = nil, controlledSelection: Bool = false, enableGutterUtility: Bool = false, onGutterUtilityClick: ((LineSelection) -> Void)? = nil) {
        self.onLineSelectionStart = onLineSelectionStart; self.onLineSelectionChange = onLineSelectionChange
        self.onLineSelectionEnd = onLineSelectionEnd; self.onLineSelected = onLineSelected
        self.enableGutterUtility = enableGutterUtility; self.onGutterUtilityClick = onGutterUtilityClick
        self.controlledSelection = controlledSelection
        self.enableLineSelection = enableLineSelection
        self.lineHoverHighlight = lineHoverHighlight
        self.onTokenEnter = onTokenEnter; self.onTokenLeave = onTokenLeave
        self.enableTokenInteractionsOnWhitespace = enableTokenInteractionsOnWhitespace; self.onTokenClick = onTokenClick
        self.onLineEnter = onLineEnter; self.onLineLeave = onLineLeave
        self.onLineClick = onLineClick; self.onLineNumberClick = onLineNumberClick
    }
    var hasHoverHandlers: Bool { enableGutterUtility || lineHoverHighlight != .disabled || onLineEnter != nil || onLineLeave != nil || onTokenEnter != nil || onTokenLeave != nil }
    func adapting(_ file: FileContents) -> DiffInteractionHandlers {
        func adapt(_ callback: ((FileLineClickEvent) -> Void)?) -> ((DiffLineClickEvent) -> Void)? {
            callback.map { callback in { callback(.init(file: file, diffEvent: $0)) } }
        }
        return .init(onLineClick: adapt(onLineClick), onLineNumberClick: adapt(onLineNumberClick), onLineEnter: adapt(onLineEnter), onLineLeave: adapt(onLineLeave), enableTokenInteractionsOnWhitespace: enableTokenInteractionsOnWhitespace,
                     onTokenClick: onTokenClick.map { callback in { callback(.init(file: file, diffEvent: $0)) } },
                     onTokenEnter: onTokenEnter.map { callback in { callback(.init(file: file, diffEvent: $0)) } },
                     onTokenLeave: onTokenLeave.map { callback in { callback(.init(file: file, diffEvent: $0)) } }, lineHoverHighlight: lineHoverHighlight, enableLineSelection: enableLineSelection, onLineSelectionStart: onLineSelectionStart, onLineSelectionChange: onLineSelectionChange, onLineSelectionEnd: onLineSelectionEnd, onLineSelected: onLineSelected, controlledSelection: controlledSelection, enableGutterUtility: enableGutterUtility, onGutterUtilityClick: onGutterUtilityClick)
    }
}

/// Stored hover data deliberately excludes the canvas and NSEvent, avoiding a
/// canvas -> event payload -> canvas retain cycle while the pointer is inside.
struct DiffHoverState {
    let fileDiff: FileDiffMetadata
    let lineNumber: Int
    let side: DiffSide
    let lineType: DiffLineType
    let numberColumn: Bool
    let lineRect: NSRect
    let numberRect: NSRect
    let sourceID: UUID?
    @MainActor init(_ hit: DiffLineClickEvent, sourceID: UUID?) {
        fileDiff = hit.fileDiff; lineNumber = hit.lineNumber; side = hit.annotationSide
        lineType = hit.lineType; numberColumn = hit.numberColumn
        lineRect = hit.lineRect; numberRect = hit.numberRect; self.sourceID = sourceID
    }
    @MainActor func payload(view: NSView, event: NSEvent) -> DiffLineClickEvent {
        .init(fileDiff: fileDiff, lineNumber: lineNumber, annotationSide: side, lineType: lineType,
              numberColumn: numberColumn, view: view, lineRect: lineRect, numberRect: numberRect, event: event)
    }
}

struct DiffTokenHoverState {
    let fileDiff: FileDiffMetadata
    let lineNumber: Int
    let side: DiffSide
    let start: Int
    let end: Int
    let text: String
    let revision: UUID?
    @MainActor init(_ hit: DiffTokenClickEvent, revision: UUID?) {
        fileDiff = hit.fileDiff; lineNumber = hit.lineNumber; side = hit.side
        start = hit.lineCharStart; end = hit.lineCharEnd; text = hit.tokenText; self.revision = revision
    }
    @MainActor func matches(_ hit: DiffTokenClickEvent?, revision: UUID?) -> Bool {
        guard let hit else { return false }
        return self.revision == revision && lineNumber == hit.lineNumber && side == hit.side && start == hit.lineCharStart && end == hit.lineCharEnd
    }
    @MainActor func payload(view: NSView, event: NSEvent) -> DiffTokenClickEvent {
        .init(revision: revision, fileDiff: fileDiff, lineNumber: lineNumber, side: side, lineCharStart: start, lineCharEnd: end, tokenText: text, view: view, event: event)
    }
}

#endif

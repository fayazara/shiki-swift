#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import ShikiCore

public enum EditorFocusLine: Sendable { case number(Int), firstVisible }
public struct EditorFocusOptions: Sendable {
    public var preventScroll: Bool
    public var line: EditorFocusLine?
    public var character: Int
    public var offset: CGFloat
    public init(preventScroll: Bool = false, line: EditorFocusLine? = nil, character: Int = 0, offset: CGFloat = 0) {
        self.preventScroll = preventScroll; self.line = line; self.character = character; self.offset = offset
    }
}

public struct EditorViewportState: Equatable, Sendable {
    public var scrollLeft: CGFloat
    public var scrollTop: CGFloat?
    public init(scrollLeft: CGFloat, scrollTop: CGFloat? = nil) { self.scrollLeft = scrollLeft; self.scrollTop = scrollTop }
}
public struct EditorViewState: Equatable, Sendable {
    public var selections: [EditorSelection]?
    public var view: EditorViewportState?
    public init(selections: [EditorSelection]? = nil, view: EditorViewportState? = nil) { self.selections = selections; self.view = view }
}

public enum DiffEditorError: Error { case alreadyAttached, incompatibleSource, missingDocument, conflictDocument, detached, staleSearchDocument, invalidSearchReplacement }
public enum DiffEditCompletionMode: Sendable { case install, discard }
public struct DiffEditCompletion: Sendable {
    public var fileDiff: FileDiffMetadata
    public var originalFileDiff: FileDiffMetadata
    public var oldFile: FileContents?
    public var newFile: FileContents?
    /// Comment positions in the completed edited document.
    public var annotations: [LineAnnotation] = []
    public var originalAnnotations: [LineAnnotation] = []
    /// Whether editing began in a single-file presentation rather than a diff.
    public var isFile: Bool = false
    /// File-shaped annotations preserve identity, text and metadata without a side.
    public var fileAnnotations: [FileLineAnnotation]? {
        isFile ? annotations.map(FileLineAnnotation.init(rendered:)) : nil
    }
    public var originalFileAnnotations: [FileLineAnnotation]? {
        isFile ? originalAnnotations.map(FileLineAnnotation.init(rendered:)) : nil
    }
}

private struct EditorRenderState: Sendable {
    var diff: FileDiffMetadata
    var expansions: [Int: HunkExpansionRegion]
}
private actor DiffEditingEngine {
    var session: DiffEditSession
    init(_ session: DiffEditSession) { self.session = session }
    func update(_ document: TextDocument, expansions: [Int: HunkExpansionRegion]) throws -> EditorRenderState {
        try Task.checkCancellation()
        session.expandedHunks = expansions
        let lines = (0..<document.lineCount).map { document.getLineText($0, includeLineBreak: true) }
        let previous = session.diff.additionLines
        // A parsed diff omits the editor's trailing caret row. That representation
        // difference alone must not turn every ordinary keystroke into a reparse.
        let comparable = lines.count == previous.count ? lines : normalizeEditorLines(lines)
        if comparable.count == previous.count {
            var replacements: [Int: String] = [:]
            for index in comparable.indices where !comparable[index].utf16.elementsEqual(previous[index].utf16) { replacements[index] = comparable[index] }
            try session.updateLines(replacements)
        } else { try session.replaceAdditionLines(lines) }
        return .init(diff: session.diff, expansions: session.expandedHunks)
    }
    func finish(threshold: Int) throws -> EditorRenderState {
        try session.finish(collapsedContextThreshold: threshold)
        return .init(diff: session.diff, expansions: session.expandedHunks)
    }
}

/// Native text input attached directly to the addition column of `NativeDiffView`.
/// AppKit supplies key bindings and input methods; the piece table owns editable text.
/// Session reconstruction and highlighting run asynchronously, outside the main actor.
@MainActor public final class DiffEditor: NSObject, @preconcurrency NSTextInputClient {
    public private(set) var document: TextDocument
    public private(set) var isActive = true
    public private(set) var isPreparing = false
    private var searchReplacementJobs = 0
    public var isReplacingSearch: Bool { searchReplacementJobs > 0 }
    public private(set) var hasEditableSelection = true
    public private(set) var search: DiffEditorSearch?
    public var editPrediction: EditPredictionOptions? {
        didSet {
            if let editPrediction {
                if let predictionController { predictionController.configure(editPrediction) }
                else { predictionController = .init(editor: self, options: editPrediction); predictionController?.inputChanged(force: true) }
            } else { predictionController?.cancel(); predictionController = nil }
        }
    }
    private(set) var predictionController: EditorPredictionController?
    private var predictionPresentationVersion: Int?
    var predictionView: NativeDiffView? { view }
    var predictionPath: String { fileInfo.name }
    var predictionPresentationIsCurrent: Bool { predictionPresentationVersion == document.version }
    public var canAcceptEditPrediction: Bool { predictionController?.canAccept ?? false }
    @discardableResult public func acceptEditPrediction() -> Bool { predictionController?.accept() ?? false }
    public func dismissEditPrediction() { _ = predictionController?.dismiss() }
    func predictionPresentationChanged() { predictionController?.presentationChanged() }
    func predictionModifierChanged(_ event: NSEvent) {
        if [58, 61].contains(event.keyCode), event.modifierFlags.intersection([.option, .command, .control, .shift]) == [.option] { predictionController?.toggleReveal() }
    }
    func applyPrediction(_ response: EditPredictResponse) -> Bool {
        do { return try applyEditorEdits(response.edits, selection: { _ in [.init(start: response.newCursor, end: response.newCursor)] }, normalizeEol: false) }
        catch { onError?(error); return false }
    }
    public var enabledSelectionAction = false {
        didSet { if !enabledSelectionAction { closeSelectionAction() }; view?.updateEditorWidgets() }
    }
    public var selectionActionRenderer: EditorSelectionActionRenderer? {
        didSet { if selectionActionRenderer !== oldValue { closeSelectionAction(); view?.updateEditorWidgets() } }
    }
    public var caretRenderer: EditorCaretRenderer? {
        didSet { if caretRenderer !== oldValue { caretRevision = UUID(); view?.updateEditorWidgets(); view?.editorOverlaysChanged() } }
    }
    private(set) var caretRevision = UUID()
    private(set) var selectionActionID: UUID?
    private(set) var selectionActionMayMount = false
    private(set) var selectionActionDragging = false
    /// Remeasure custom content after changing its intrinsic size without changing its frame.
    public func invalidateWidgetLayout() { view?.updateEditorWidgets() }
    func makeSelectionActionContext() -> SelectionActionContext {
        let id = UUID(); selectionActionID = id
        return .init(editor: self, id: id)
    }
    func closeSelectionAction(revealCaret: Bool = false) {
        selectionActionID = nil; selectionActionMayMount = false
        view?.updateEditorWidgets()
        if revealCaret, let focus = getSelections().last?.focus { view?.revealEditorCaret(focus) }
    }
    func selectionGestureBegan() { selectionActionDragging = true; selectionActionMayMount = true; view?.updateEditorWidgets() }
    func selectionGestureEnded() { selectionActionDragging = false; selectionActionMayMount = true; view?.updateEditorWidgets() }
    func invalidateSelectionActionContext() { selectionActionID = nil }
    func replaceActionSelection(_ selection: EditorSelection, text: String) throws -> Bool {
        let before = getSelections()
        guard let change = try replaceSelections([selection], texts: [text]) else { return false }
        recordUndo(count: 1, before: before, after: getSelections()); onChange?(change); return true
    }
    public var clipboard: EditorClipboardProvider? {
        didSet { if clipboard?.id != oldValue?.id { clipboardController?.cancel() } }
    }
    private var clipboardController: EditorClipboardController?
    public var isReadingClipboard: Bool { clipboardController?.isReading ?? false }
    public var keymap = EditorKeymap()
    public var autoSurround: AutoSurround = .default
    public var matchBrackets = true { didSet { if matchBrackets != oldValue { refreshBracketMatches() } } }
    public private(set) var bracketMatchRanges: [TextRange] = []
    private var bracketTokens: [[ThemedToken]] = []
    private var bracketTokenVersion: Int?
    private func refreshBracketMatches() {
        let previous = bracketMatchRanges
        bracketMatchRanges = []
        if matchBrackets, hasEditableSelection, selected.length == 0, bracketTokenVersion == document.version {
            bracketMatchRanges = findBracketMatchRanges(document, position: document.positionAt(headOffset)) { line in
                guard self.bracketTokens.indices.contains(line) else { return [] }
                let start = self.document.offsetAt(.init(line: line, character: 0))
                return self.bracketTokens[line].compactMap { token in
                    guard token.type == .comment || token.type == .string || token.type == .regex else { return nil }
                    return NSRange(location: token.offset - start, length: token.content.utf16.count)
                }
            } ?? []
        }
        if previous != bracketMatchRanges { view?.editorOverlaysChanged() }
    }
    public var tabSize: Int = 2
    public var languageCommentConfig: [String: EditorLanguageCommentConfig] = [:]
    public var onFocus: (() -> Void)?
    public var onBlur: (() -> Void)?
    public private(set) var isFocused = false
    func focusChanged(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        if focused { onFocus?() } else { onBlur?() }
    }
    public func focus(_ options: EditorFocusOptions = .init()) {
        selectionActionMayMount = false
        guard isActive, let view else { return }
        let position: TextPosition?
        switch options.line {
        case .number(let number): position = document.positionAt(document.offsetAt(.init(line: max(1, number) - 1, character: options.character)))
        case .firstVisible:
            guard let line = view.firstVisibleEditorLine(offset: options.offset) else { return }
            position = .init(line: line - 1, character: 0)
        case nil: position = nil
        }
        let origin = view.editorScrollOrigin
        if let position {
            unmarkText(); hasEditableSelection = true
            assignSelections([.init(start: position, end: position)]); publishSelection()
        }
        view.focusEditor()
        guard isActive, self.view === view else { return }
        if options.preventScroll {
            if isPreparing { restoreScrollOrigin = origin }
            view.restoreEditorScrollOrigin(origin)
        }
        else { view.revealEditorCaret(document.positionAt(headOffset)) }
    }
    public func blur() { view?.blurEditor(); focusChanged(false) }
    public var onChange: ((TextDocumentChange) -> Void)?
    public var onError: ((any Error) -> Void)?
    public private(set) var markers: [Marker] = []
    public private(set) var carets: [EditorCaret] = []
    public var renderMarkerPopover: ((Marker) -> NSView?)?
    private var markerIndex = EditorOverlayIndex()
    private var caretIndex = EditorOverlayIndex()
    private var caretOffsets: [(anchor: Int, focus: Int)] = []
    private var compositionCarets: [EditorCaret]?
    public func setMarkers(_ markers: [Marker]) {
        guard isActive else { return }
        self.markers = markers.map { value in
            var marker = value
            let start = document.offsetAt(value.start), end = document.offsetAt(value.end)
            marker.start = document.positionAt(min(start, end)); marker.end = document.positionAt(max(start, end))
            return marker
        }
        markerIndex = EditorOverlayIndex(self.markers.map { $0.start.line...$0.end.line })
        view?.editorOverlaysChanged()
    }
    public func setCarets(_ carets: [EditorCaret]) {
        guard isActive else { return }
        caretRevision = UUID()
        self.carets = carets.map { value in
            var caret = value; caret.anchor = document.positionAt(document.offsetAt(value.anchor)); caret.focus = document.positionAt(document.offsetAt(value.focus)); return caret
        }
        caretOffsets = self.carets.map { (document.offsetAt($0.anchor), document.offsetAt($0.focus)) }
        rebuildCaretIndex(); view?.editorOverlaysChanged()
    }
    func markers(on line: Int) -> [Marker] { markerIndex.query(line).map { markers[$0] } }
    func caretIndices(on line: Int) -> [Int] { caretIndex.query(line) }
    func carets(on line: Int) -> [EditorCaret] { caretIndex.query(line).map { carets[$0] } }
    func marker(at position: TextPosition) -> Marker? {
        let offset = document.offsetAt(position)
        return markers(on: position.line).first {
            let start = document.offsetAt($0.start), end = document.offsetAt($0.end)
            return offset >= start && (offset < end || start == end && offset == start)
        }
    }
    private func rebuildCaretIndex() { caretIndex = EditorOverlayIndex(carets.map { min($0.anchor.line, $0.focus.line)...max($0.anchor.line, $0.focus.line) }) }
    private func remapExternalCarets() {
        guard !carets.isEmpty else { return }
        for index in carets.indices {
            caretOffsets[index].anchor = remapEditorOffset(caretOffsets[index].anchor, through: document.lastAppliedEdits)
            caretOffsets[index].focus = remapEditorOffset(caretOffsets[index].focus, through: document.lastAppliedEdits)
            carets[index].anchor = document.positionAt(caretOffsets[index].anchor)
            carets[index].focus = document.positionAt(caretOffsets[index].focus)
        }
        rebuildCaretIndex()
    }
    /// Returning true accepts an install completion. With no handler, the external diff is restored.
    public var onEditComplete: ((DiffEditCompletion) -> Bool)?
    var defaultCompletionAcceptance = false
    private(set) var installedCompletionDocument: HighlightedDiff?
    public private(set) var undoManager = UndoManager()
    // Undo registrations follow a session across editor instances without
    // retaining the old editor, callbacks, or its native view.
    final class UndoTarget: NSObject { weak var editor: DiffEditor? }
    private var undoTarget = UndoTarget()
    final class UndoGroup {
        let count: Int
        let before: [EditorSelection]
        var after: [EditorSelection]
        let remapBefore: Bool
        var remapAfter: Bool
        init(count: Int, before: [EditorSelection], after: [EditorSelection], remapBefore: Bool = false, remapAfter: Bool = false) {
            self.count = count; self.before = before; self.after = after; self.remapBefore = remapBefore; self.remapAfter = remapAfter
        }
    }
    private var undoGroups: [UndoGroup] = [], redoGroups: [UndoGroup] = []
    private var canCoalesceUndo = false
    public private(set) var maximumUndoGroups: Int
    public func breakUndoCoalescing() { unmarkText(); canCoalesceUndo = false; document.breakUndoCoalescing() }
    public private(set) var editStateKey: String?
    private let stateManager: EditStateManager
    private var retentionReleased = false
    private var retainedSessionDiff: FileDiffMetadata
    private var suspendedScrollOrigin: CGPoint?
    private var restoreScrollOrigin: CGPoint?
    lazy var textInputContext = NSTextInputContext(client: self)
    private weak var view: NativeDiffView?
    private var suspendedExpansions: [Int: HunkExpansionRegion] = [:]
    private var restoringExpansions: [Int: HunkExpansionRegion]?
    public var isSuspended: Bool { isActive && view == nil }
    private var engine: DiffEditingEngine
    private let diffOptions: DiffOptions
    private let highlighter: DiffHighlighter
    private let sourceID: UUID
    private let highlightSession = UUID()
    private var fileInfo: EditorFileInfo
    private var external: HighlightedDiff
    private var initial: HighlightedDiff
    private var externalAnnotations: [LineAnnotation]
    private var providedAnnotations: [LineAnnotation]
    private var options: DiffRenderOptions
    private var annotations: [LineAnnotation]
    private let isFilePresentation: Bool
    public var currentAnnotations: [LineAnnotation] { annotations }
    public var currentFileAnnotations: [FileLineAnnotation]? {
        isFilePresentation ? annotations.map(FileLineAnnotation.init(rendered:)) : nil
    }
    struct AnnotationHistory: Sendable {
        var before: [LineAnnotation]
        var after: [LineAnnotation]
        var remapBefore = false
        var remapAfter = false
    }
    private var annotationUndo: [AnnotationHistory] = []
    private var annotationRedo: [AnnotationHistory] = []
    private var compositionAnnotationState: (annotations: [LineAnnotation], undo: [AnnotationHistory], redo: [AnnotationHistory])?
    private func trackAnnotations(_ change: TextDocumentChange) {
        predictionController?.recordTransaction()
        let before = annotations
        if let mapped = applyDocumentChangeToLineAnnotations(change, annotations: annotations) { annotations = mapped }
        annotationUndo.append(.init(before: before, after: annotations)); annotationRedo.removeAll()
    }
    private var selected = NSRange(location: 0, length: 0)
    private var anchorOffset = 0
    private var headOffset = 0
    private var secondarySelections: [EditorSelection] = []
    private var secondaryIndex = EditorOverlayIndex()
    private var navigationSelections: [EditorSelection]?
    private var navigationSelection: EditorSelection?
    private var marked = NSRange(location: NSNotFound, length: 0)
    private var compositionEdits = 0
    private var compositionSelection = EditorSelection(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0))
    private var compositionSelections: [EditorSelection] = []
    private var compositionRanges: [EditorSelection] = []
    private var compositionDocument: TextDocument?
    private var syncingSelection = false
    private var generation = 0
    private var renderTask: Task<Void, Never>?

    init(view: NativeDiffView, document: HighlightedDiff, options: DiffRenderOptions, annotations: [LineAnnotation],
         diffOptions: DiffOptions, expandedHunks: [Int: HunkExpansionRegion], highlighter: DiffHighlighter,
         editStateKey: String? = nil, stateManager: EditStateManager = .shared, historyMaxEntries: Int = 100, initialState: EditorInitialState? = nil) throws {
        if let initialState, initialState.type != (view.isFilePresentation ? .file : .fileDiff) { throw EditStateError.incompatibleEditorType }
        let targetLanguage = document.diff.lang ?? getFiletypeFromFileName(document.diff.name)
        let initialState = initialState.flatMap { state -> EditorInitialState? in
            if editStateKey == nil, let supplied = state.document, let info = state.fileInfo,
               !info.name.utf16.elementsEqual(document.diff.name.utf16) || !supplied.languageId.utf16.elementsEqual(targetLanguage.utf16) { return nil }
            return state
        }
        let importedSession = try initialState?.diffSession.map { try DiffEditSession(diff: $0, options: diffOptions, expandedHunks: initialState?.expandedHunks ?? [:]) }
        let session = try DiffEditSession(diff: document.diff, options: diffOptions, expandedHunks: expandedHunks)
        engine = DiffEditingEngine(session); self.highlighter = highlighter; self.diffOptions = diffOptions
        self.document = TextDocument(uri: document.diff.name, text: document.diff.additionLines.joined(), languageId: document.diff.lang ?? getFiletypeFromFileName(document.diff.name), editStack: .init(maxEntries: Int.max))
        fileInfo = .init(name: document.diff.name, lang: document.diff.lang)
        self.view = view; external = document; initial = document; sourceID = document.sourceID; self.options = options
        self.annotations = annotations; externalAnnotations = annotations; providedAnnotations = annotations
        isFilePresentation = view.isFilePresentation
        self.editStateKey = editStateKey; self.stateManager = stateManager; retainedSessionDiff = document.diff
        maximumUndoGroups = max(1, historyMaxEntries)
        super.init()
        undoManager.groupsByEvent = false; undoManager.levelsOfUndo = maximumUndoGroups
        undoTarget.editor = self
        let retained = try editStateKey.flatMap { try stateManager.activate(isFilePresentation ? .file : .fileDiff, key: $0, editor: self) }
        if let initialState {
            importInitialState(initialState, session: importedSession)
        } else if let retained {
            self.document = retained.document; fileInfo = retained.fileInfo; initial = retained.initial; retainedSessionDiff = retained.diff
            engine = DiffEditingEngine(try DiffEditSession(diff: retained.diff, options: diffOptions, expandedHunks: retained.expansions))
            self.annotations = retained.annotations; annotationUndo = retained.annotationUndo; annotationRedo = retained.annotationRedo
            undoManager = retained.undoManager; undoTarget = retained.undoTarget; undoTarget.editor = self
            undoGroups = retained.undoGroups; redoGroups = retained.redoGroups; canCoalesceUndo = retained.canCoalesceUndo
            maximumUndoGroups = retained.maximumUndoGroups
            secondarySelections = retained.secondarySelections
            secondaryIndex = EditorOverlayIndex(secondarySelections.map { $0.start.line...$0.end.line })
            anchorOffset = retained.anchor ?? 0; headOffset = retained.head ?? 0
            hasEditableSelection = retained.anchor != nil && retained.head != nil
            selected = .init(location: min(anchorOffset, headOffset), length: abs(headOffset - anchorOffset))
            suspendedExpansions = retained.expansions; restoringExpansions = retained.expansions; restoreScrollOrigin = retained.scrollOrigin
        }
    }
    private func importInitialState(_ state: EditorInitialState, session: DiffEditSession?) {
        if let supplied = state.document {
            document = supplied
            if let info = state.fileInfo { fileInfo = info }
            if supplied.history.maxEntries != Int.max { maximumUndoGroups = supplied.history.maxEntries }
        }
        let snapshot = state.snapshot.flatMap { $0.historyIdentity == document.historyIdentity ? $0 : nil }
        document.setHistoryCapacity(Int.max)
        if let session { engine = DiffEditingEngine(session); retainedSessionDiff = session.diff }
        if let initialDocument = state.snapshot?.initialDocument { initial = initialDocument }
        annotations = state.annotations ?? annotations
        suspendedExpansions = state.expandedHunks ?? [:]; restoringExpansions = state.expandedHunks
        if let viewport = state.editor?.view {
            let x = viewport.scrollLeft.isFinite ? max(0, viewport.scrollLeft) : 0
            let y = viewport.scrollTop.map { $0.isFinite ? max(0, $0) : 0 } ?? view?.editorScrollOrigin.y ?? 0
            restoreScrollOrigin = .init(x: x, y: y)
        }
        assignSelections(state.editor?.selections ?? getSelections())
        maximumUndoGroups = max(1, snapshot?.maximumUndoGroups ?? maximumUndoGroups)
        undoManager.levelsOfUndo = maximumUndoGroups
        let history = document.history
        func groups(_ saved: [EditState.HistoryGroup]?, entries: [EditHistoryEntry]) -> [UndoGroup] {
            if let saved, saved.allSatisfy({ $0.count > 0 }), saved.reduce(0, { $0 + $1.count }) == entries.count {
                return saved.map { UndoGroup(count: $0.count, before: $0.before, after: $0.after, remapBefore: $0.remapBefore, remapAfter: $0.remapAfter) }
            }
            return entries.map { UndoGroup(count: 1, before: $0.selectionsBefore ?? [], after: $0.selectionsAfter ?? [], remapBefore: $0.selectionsBefore == nil, remapAfter: $0.selectionsAfter == nil) }
        }
        undoGroups = groups(snapshot?.undoGroups, entries: history.undoStack)
        redoGroups = groups(snapshot?.redoGroups, entries: history.redoStack)
        annotationUndo = snapshot?.annotationUndo?.count == history.undoStack.count ? snapshot!.annotationUndo!
            : history.undoStack.map { .init(before: $0.lineAnnotationsBefore ?? annotations, after: $0.lineAnnotationsAfter ?? annotations, remapBefore: $0.lineAnnotationsBefore == nil, remapAfter: $0.lineAnnotationsAfter == nil) }
        annotationRedo = snapshot?.annotationRedo?.count == history.redoStack.count ? snapshot!.annotationRedo!
            : history.redoStack.map { .init(before: $0.lineAnnotationsBefore ?? annotations, after: $0.lineAnnotationsAfter ?? annotations, remapBefore: $0.lineAnnotationsBefore == nil, remapAfter: $0.lineAnnotationsAfter == nil) }
        canCoalesceUndo = snapshot?.canCoalesceUndo ?? history.canCoalesce
        // Build the AppKit redo stack by replaying registrations only. Importing
        // state must never mutate text or emit change callbacks.
        installingHistory = true
        for group in undoGroups + redoGroups.reversed() {
            undoManager.beginUndoGrouping(); registerHistoryAction(group, redo: false); undoManager.setActionName("Edit"); undoManager.endUndoGrouping()
        }
        for _ in redoGroups { undoManager.undo() }
        installingHistory = false
    }
    private var installingHistory = false
    private func registerHistoryAction(_ group: UndoGroup, redo: Bool) {
        undoManager.registerUndo(withTarget: undoTarget) { target in
            MainActor.assumeIsolated {
                guard let editor = target.editor else { return }
                if editor.installingHistory { editor.registerHistoryAction(group, redo: !redo) }
                else { editor.replayHistory(group, redo: redo) }
            }
        }
    }
    public var selectedText: String { (try? document.getText(in: selected)) ?? "" }
    public var type: EditorType { isFilePresentation ? .file : .fileDiff }
    public func getText() -> String { document.getText() }
    public func getFile() -> FileContents { .init(name: fileInfo.name, contents: document.getText(), lang: fileInfo.lang) }
    public func canUndo() -> Bool { isActive && (compositionEdits > 0 || undoManager.canUndo) }
    public func canRedo() -> Bool { isActive && compositionEdits == 0 && undoManager.canRedo }
    /// Apply an atomic batch as one undo step. Invalid overlapping edits throw
    /// before changing the draft; programmatic edits target the addition side.
    @discardableResult public func applyEdits(_ edits: [TextEdit], selection: EditorSelection? = nil) throws -> Bool {
        selectionActionMayMount = false
        guard isActive else { throw DiffEditorError.detached }
        unmarkText()
        return try applyEditorEdits(edits, selection: selection.map { value in { _ in [value] } })
    }
    func activate() { publishSelection(); scheduleRender() }
    /// Release the viewport while keeping text, undo history and selection alive.
    public func suspend() {
        guard isActive, let view else { return }
        breakUndoCoalescing(); predictionController?.cancel(); clipboardController?.cancel(); closeSelectionAction(); selectionActionDragging = false
        suspendedExpansions = restoringExpansions ?? view.editorExpansions; restoringExpansions = suspendedExpansions
        suspendedScrollOrigin = view.editorScrollOrigin
        renderTask?.cancel(); generation += 1; isPreparing = false
        view.hideSearch(); view.detachEditor(self)
        self.view = nil
    }
    func resume(on view: NativeDiffView, external: HighlightedDiff, options: DiffRenderOptions, annotations: [LineAnnotation]) throws {
        guard isActive else { throw DiffEditorError.detached }
        guard self.view == nil else { throw DiffEditorError.alreadyAttached }
        guard external.sourceID == sourceID else { throw DiffEditorError.incompatibleSource }
        receiveExternal(external, options: options, annotations: annotations)
        guard isActive, view.attachedEditor === self else { throw DiffEditorError.detached }
        self.view = view; restoreScrollOrigin = suspendedScrollOrigin
        if let search { view.showSearch(search) }
        scheduleRender()
    }

    public func selectedRange() -> NSRange { hasEditableSelection ? selected : .init(location: NSNotFound, length: 0) }
    public func markedRange() -> NSRange { marked }
    public func hasMarkedText() -> Bool { marked.location != NSNotFound }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .markedClauseSegment] }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0, range.location <= document.utf16Length else { return nil }
        let actual = NSRange(location: range.location, length: min(range.length, document.utf16Length - range.location))
        actualRange?.pointee = actual
        return (try? document.getText(in: actual)).map { NSAttributedString(string: $0) }
    }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let offset = range.location == NSNotFound ? headOffset : min(document.utf16Length, max(0, range.location))
        actualRange?.pointee = .init(location: offset, length: 0)
        return view?.editorRect(document.positionAt(offset)) ?? .zero
    }
    public func characterIndex(for point: NSPoint) -> Int {
        guard let position = view?.editorPosition(at: point) else { return NSNotFound }
        return document.offsetAt(position)
    }
    public func getViewState() -> EditorViewState {
        let origin = isActive ? view?.editorScrollOrigin ?? suspendedScrollOrigin : suspendedScrollOrigin
        return .init(selections: getSelections(), view: origin.map { .init(scrollLeft: $0.x, scrollTop: $0.y) })
    }
    public func setViewState(_ state: EditorViewState) throws {
        selectionActionMayMount = false
        guard isActive, let view else { throw DiffEditorError.detached }
        unmarkText(); assignSelections(state.selections ?? []); publishSelection()
        if let viewport = state.view {
            let left = viewport.scrollLeft.isFinite ? max(0, viewport.scrollLeft) : 0
            let top = viewport.scrollTop.map { $0.isFinite ? max(0, $0) : 0 } ?? view.editorScrollOrigin.y
            let origin = view.restoreEditorScrollOrigin(.init(x: left, y: top))
            if isPreparing { restoreScrollOrigin = origin }
        } else if hasEditableSelection { view.revealEditorCaret(document.positionAt(headOffset)) }
    }
    public func selectNextOccurrence() {
        guard isActive, hasEditableSelection else { return }
        unmarkText(); let selections = getSelections()
        if selections.contains(where: \.isCollapsed) {
            setSelections(selections.map { expandCollapsedSelectionToWord(document, selection: $0) })
        } else if let next = findNextMatch(document, selections: selections) { setSelections(next) }
    }
    /// The last selection is primary. Positions use zero-based UTF-16 columns.
    public func getSelections() -> [EditorSelection] { hasEditableSelection ? secondarySelections + [currentSelection] : [] }
    public func setSelections(_ selections: [EditorSelection]) {
        selectionActionMayMount = false
        guard isActive else { return }
        unmarkText(); assignSelections(selections); publishSelection()
        if hasEditableSelection { view?.revealEditorCaret(document.positionAt(headOffset)) }
    }
    private func assignSelections(_ selections: [EditorSelection]) {
        let selections = mergeOverlappingSelections(selections.map { value in
            var selection = value
            selection.start = document.positionAt(document.offsetAt(value.start)); selection.end = document.positionAt(document.offsetAt(value.end))
            if compareEditorPositions(selection.start, selection.end) > 0 {
                swap(&selection.start, &selection.end)
                if selection.direction != .none { selection.direction = selection.direction == .forward ? .backward : .forward }
            }
            return selection
        })
        secondarySelections = Array(selections.dropLast()); hasEditableSelection = !selections.isEmpty
        if let primary = selections.last { anchorOffset = document.offsetAt(primary.anchor); headOffset = document.offsetAt(primary.focus) }
        secondaryIndex = EditorOverlayIndex(secondarySelections.map { $0.start.line...$0.end.line })
    }
    func secondarySelections(on line: Int) -> [EditorSelection] { secondaryIndex.query(line).map { secondarySelections[$0] } }
    public func select(_ range: NSRange) {
        selectionActionMayMount = false
        guard range.location >= 0, range.location != NSNotFound, range.length >= 0, range.location <= document.utf16Length else { return }
        unmarkText(); secondarySelections = []; secondaryIndex = EditorOverlayIndex()
        hasEditableSelection = true
        anchorOffset = range.location; headOffset = min(document.utf16Length, range.location + min(range.length, document.utf16Length - range.location))
        publishSelection()
    }
    func canvasSelectionChanged(_ text: DiffTextSelection?, lines: LineSelection?, preservingSecondary: Bool = false) {
        guard !syncingSelection, isActive else { return }
        defer { predictionController?.inputChanged(); clipboardController?.inputChanged(); view?.updateEditorWidgets() }
        unmarkText()
        navigationSelection = nil; navigationSelections = nil
        if !preservingSecondary { secondarySelections = []; secondaryIndex = EditorOverlayIndex() }
        guard (text?.side ?? lines?.side) == .additions else { hasEditableSelection = false; refreshBracketMatches(); return }
        guard text != nil || (lines?.endSide ?? .additions) == .additions else { hasEditableSelection = false; refreshBracketMatches(); return }
        hasEditableSelection = true
        if let text {
            anchorOffset = document.offsetAt(text.anchor); headOffset = document.offsetAt(text.head)
        } else if let lines {
            let first = min(lines.startLine, lines.endLine) - 1, last = max(lines.startLine, lines.endLine)
            anchorOffset = document.offsetAt(.init(line: first, character: 0))
            headOffset = last < document.lineCount ? document.offsetAt(.init(line: last, character: 0)) : document.utf16Length
        }
        if preservingSecondary { assignSelections(secondarySelections + [currentSelection]) }
        selected = .init(location: min(anchorOffset, headOffset), length: abs(headOffset - anchorOffset))
        refreshBracketMatches()
    }
    private func publishSelection(preservingNavigation: Bool = false) {
        defer { predictionController?.inputChanged(); clipboardController?.inputChanged(); view?.updateEditorWidgets() }
        if !preservingNavigation { navigationSelection = nil; navigationSelections = nil }
        selected = .init(location: min(anchorOffset, headOffset), length: abs(headOffset - anchorOffset))
        syncingSelection = true
        if hasEditableSelection { view?.editorSelect(.init(side: .additions, anchor: document.positionAt(anchorOffset), head: document.positionAt(headOffset))) }
        else { view?.editorClearSelection() }
        syncingSelection = false
        textInputContext.invalidateCharacterCoordinates()
        refreshBracketMatches()
    }
    private func inputSelections(_ replacementRange: NSRange) throws -> [EditorSelection] {
        if replacementRange.location != NSNotFound {
            guard replacementRange.location >= 0, replacementRange.length >= 0, replacementRange.location <= document.utf16Length,
                  replacementRange.length <= document.utf16Length - replacementRange.location else { throw TextDocumentError.invalidRange }
            return [.init(start: document.positionAt(replacementRange.location), end: document.positionAt(NSMaxRange(replacementRange)))]
        }
        return hasMarkedText() ? compositionRanges : getSelections()
    }
    @discardableResult private func replaceSelections(_ selections: [EditorSelection], texts: [String],
                                                     preserveInner: Bool = true, documentOrder: Bool = false) throws -> TextDocumentChange? {
        let result = try resolveSelectionReplacements(document, selections: selections, texts: texts,
                                                      documentOrder: documentOrder, preserveInnerSelection: preserveInner)
        guard let change = try document.applyResolvedEdits(result.edits, selectionsBefore: getSelections(), coalescing: false) else { return nil }
        remapExternalCarets(); trackAnnotations(change)
        assignSelections(result.selections.map { .init(anchor: document.positionAt($0.anchor), focus: document.positionAt($0.focus)) })
        publishSelection(); scheduleRender()
        return change
    }
    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard isActive, hasEditableSelection else { return }
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        let before = compositionEdits > 0 ? compositionSelections : getSelections()
        do {
        let selections = try inputSelections(replacementRange)
        let texts = replacementRange.location == NSNotFound && !hasMarkedText()
            ? getAutoSurroundReplacementTexts(document, selections: selections, character: text, autoSurround: autoSurround)
                ?? Array(repeating: text, count: selections.count)
            : Array(repeating: text, count: selections.count)
            let change: TextDocumentChange?
            let wasComposing = hasMarkedText()
            if replacementRange.location != NSNotFound {
                change = try replace(replacementRange, text: expandSingleNewlineInsert(document, text: text, offset: replacementRange.location))
            } else { change = try replaceSelections(selections, texts: texts, preserveInner: !wasComposing) }
            let count = compositionEdits + (change == nil ? 0 : 1)
            clearComposition()
            if count > 0 { recordUndo(count: count, before: before, after: getSelections(), undoBoundary: wasComposing) }
            if let change { onChange?(change) }
        } catch { onError?(error) }
    }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isActive, hasEditableSelection else { return }
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        if compositionEdits == 0 {
            predictionController?.beginComposition()
            compositionSelection = currentSelection; compositionSelections = getSelections()
            compositionDocument = document; compositionCarets = carets
            compositionAnnotationState = (annotations, annotationUndo, annotationRedo)
        }
        do {
            let selections = try inputSelections(replacementRange), normalized = document.normalizeEol(text)
            let result = try resolveSelectionReplacements(document, selections: selections,
                texts: Array(repeating: normalized, count: selections.count), preserveInnerSelection: false, expandNewlines: false)
            guard let change = try document.applyResolvedEdits(result.edits, selectionsBefore: getSelections(), coalescing: false) else { return }
            remapExternalCarets(); trackAnnotations(change); compositionEdits += 1
            compositionRanges = result.selections.map { pair in
                .init(start: document.positionAt(pair.focus - normalized.utf16.count), end: document.positionAt(pair.focus))
            }
            let length = normalized.utf16.count
            let local = min(length, max(0, selectedRange.location == NSNotFound ? length : selectedRange.location))
            assignSelections(result.selections.map { pair in
                let start = pair.focus - length + local
                return .init(start: document.positionAt(start), end: document.positionAt(start + min(max(0, selectedRange.length), length - local)))
            })
            if let primary = compositionRanges.last {
                marked = .init(location: document.offsetAt(primary.start), length: length)
            }
            publishSelection(); scheduleRender(); onChange?(change)
        } catch { onError?(error) }
    }
    private func clearComposition() {
        predictionController?.finishComposition()
        compositionEdits = 0; compositionDocument = nil; compositionCarets = nil; compositionAnnotationState = nil
        compositionRanges = []; compositionSelections = []; marked = .init(location: NSNotFound, length: 0)
    }
    public func unmarkText() {
        guard compositionEdits > 0 else { marked = .init(location: NSNotFound, length: 0); return }
        recordUndo(count: compositionEdits, before: compositionSelections, after: getSelections())
        clearComposition()
    }
    private func replace(_ range: NSRange, text: String) throws -> TextDocumentChange? {
        let normalized = document.normalizeEol(text)
        guard let change = try document.applyResolvedEdits([.init(range: range, newText: normalized)], selectionsBefore: getSelections(), coalescing: false) else { return nil }
        remapExternalCarets(); trackAnnotations(change)
        let caret = document.positionAt((document.lastAppliedEdits.first?.range.location ?? range.location) + normalized.utf16.count)
        assignSelections([.init(start: caret, end: caret)])
        publishSelection(); scheduleRender(); return change
    }
    private func recordUndo(count: Int, before: [EditorSelection], after: [EditorSelection], undoBoundary: Bool = true) {
        document.setLastUndoSelectionsAfter(after)
        document.setLastUndoBoundary(undoBoundary || count > 1)
        if let annotations = annotationUndo.last { document.setLastUndoLineAnnotations(before: annotations.before, after: annotations.after) }
        if count == 1, canCoalesceUndo, let previous = undoGroups.last, previous.count == 1,
           document.coalesceLastTwoHistoryEntries() {
            previous.after = after; previous.remapAfter = false
            if annotationUndo.count >= 2 {
                let latest = annotationUndo.removeLast(), prior = annotationUndo.removeLast()
                annotationUndo.append(.init(before: prior.before, after: latest.after, remapBefore: prior.remapBefore, remapAfter: latest.remapAfter))
            }
        } else {
            let group = UndoGroup(count: count, before: before, after: after)
            undoGroups.append(group)
            undoManager.beginUndoGrouping()
            registerHistoryAction(group, redo: false)
            undoManager.setActionName("Edit"); undoManager.endUndoGrouping()
            if undoGroups.count > maximumUndoGroups { undoGroups.removeFirst(undoGroups.count - maximumUndoGroups) }
        }
        redoGroups = []; canCoalesceUndo = true
        let retainedCount = undoGroups.reduce(0) { $0 + $1.count }
        document.retainUndoEntries(retainedCount)
        if annotationUndo.count > retainedCount { annotationUndo.removeFirst(annotationUndo.count - retainedCount) }
    }
    private func replayHistory(_ group: UndoGroup, redo: Bool) {
        guard isActive else { return }
        canCoalesceUndo = false
        if redo { if redoGroups.last === group { redoGroups.removeLast() }; undoGroups.append(group) }
        else { if undoGroups.last === group { undoGroups.removeLast() }; redoGroups.append(group) }
        let previousLineCount = document.lineCount
        let remapSelection = redo ? group.remapAfter : group.remapBefore
        var offsets = getSelections().map { (anchor: document.offsetAt($0.anchor), focus: document.offsetAt($0.focus)) }
        var startLine = document.lineCount, endLine = 0
        for _ in 0..<group.count {
            if let change = redo ? document.redo() : document.undo() {
                remapExternalCarets(); predictionController?.recordTransaction()
                if remapSelection {
                    offsets = offsets.map { (remapEditorOffset($0.anchor, through: document.lastAppliedEdits), remapEditorOffset($0.focus, through: document.lastAppliedEdits)) }
                }
                if redo, let state = annotationRedo.popLast() {
                    annotations = state.remapAfter ? applyDocumentChangeToLineAnnotations(change, annotations: annotations) ?? annotations : state.after
                    annotationUndo.append(state)
                } else if !redo, let state = annotationUndo.popLast() {
                    annotations = state.remapBefore ? applyDocumentChangeToLineAnnotations(change, annotations: annotations) ?? annotations : state.before
                    annotationRedo.append(state)
                }
                startLine = min(startLine, change.startLine); endLine = max(endLine, change.endLine)
            }
        }
        registerHistoryAction(group, redo: !redo)
        assignSelections(remapSelection ? offsets.map { .init(anchor: document.positionAt($0.anchor), focus: document.positionAt($0.focus)) } : redo ? group.after : group.before)
        publishSelection(); scheduleRender()
        onChange?(.init(startLine: min(startLine, document.lineCount - 1), endLine: min(endLine, document.lineCount - 1), previousLineCount: previousLineCount, lineCount: document.lineCount))
    }
    @objc public func undo(_ sender: Any?) { unmarkText(); if undoManager.canUndo { undoManager.undo() } }
    @objc public func redo(_ sender: Any?) { unmarkText(); if undoManager.canRedo { undoManager.redo() } }
    public var clipboardText: String {
        hasEditableSelection ? getSelectionText(document, selections: getSelections()) : view?.selectedText() ?? ""
    }
    private static let selectionPasteboardType = NSPasteboard.PasteboardType(EditorClipboardProvider.selectionType)
    public func copySelection(to pasteboard: NSPasteboard = .general) {
        let text = clipboardText
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let texts = hasEditableSelection ? getSelectionClipboardTexts(document, selections: getSelections()) : []
        if texts.count > 1, let data = try? JSONEncoder().encode(texts) { pasteboard.setData(data, forType: Self.selectionPasteboardType) }
    }
    public func cutSelection(to pasteboard: NSPasteboard = .general) {
        guard isActive else { return }
        guard hasEditableSelection else { copySelection(to: pasteboard); return }
        unmarkText()
        let cut = resolveSelectionCut(document, selections: getSelections())
        copySelection(to: pasteboard)
        let edits = cut.edits.map { TextEdit(range: .init(start: document.positionAt($0.range.location), end: document.positionAt(NSMaxRange($0.range))), newText: "") }
        applyCommandEdits(edits) { document in
            cut.nextSelectionOffsets.map { offset in
                let caret = document.positionAt(offset); return .init(start: caret, end: caret)
            }
        }
    }
    @objc public func copy(_ sender: Any?) { copySelection() }
    @objc public func cut(_ sender: Any?) { cutSelection() }
    public func pasteSelection(from pasteboard: NSPasteboard = .general) {
        guard isActive, hasEditableSelection, let text = pasteboard.string(forType: .string) else { return }
        unmarkText(); clipboardController?.cancel(); let before = getSelections()
        var texts = Array(repeating: text, count: before.count)
        if before.count > 1, let data = pasteboard.data(forType: Self.selectionPasteboardType),
           let paired = try? JSONDecoder().decode([String].self, from: data), paired.count == before.count { texts = paired }
        pasteTexts(texts, into: before)
    }
    func pasteTexts(_ texts: [String], into before: [EditorSelection]) {
        guard isActive, hasEditableSelection else { return }
        do {
            if let change = try replaceSelections(before, texts: texts, documentOrder: true) { recordUndo(count: 1, before: before, after: getSelections()); onChange?(change) }
        } catch { onError?(error) }
    }
    @objc public func paste(_ sender: Any?) {
        guard clipboard != nil else { pasteSelection(); return }
        unmarkText()
        if clipboardController == nil { clipboardController = .init(editor: self) }
        clipboardController?.paste()
    }
    @objc public func selectAll(_ sender: Any?) { select(.init(location: 0, length: document.utf16Length)) }
    @discardableResult public func performCommand(_ command: EditorCommand) -> Bool {
        guard isActive else { return false }
        switch command {
        case .undo: undo(nil)
        case .redo: redo(nil)
        case .selectAll: selectAll(nil)
        case .findNextMatch: selectNextOccurrence()
        case .openSearchPanel: openSearch(replacing: false)
        case .openSearchReplacePanel: openSearch(replacing: true)
        case .indent: indent(outdent: false, lineBased: false)
        case .outdent: indent(outdent: true, lineBased: false)
        case .indentLess: indent(outdent: true, lineBased: true)
        case .indentMore: indent(outdent: false, lineBased: true)
        case .moveLineUp: performLineCommand(.moveUp)
        case .moveLineDown: performLineCommand(.moveDown)
        case .copyLineUp: performLineCommand(.copyUp)
        case .copyLineDown: performLineCommand(.copyDown)
        case .simplifySelection: doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        case .insertBlankLine: performLineCommand(.insertBlankLine)
        case .deleteHardLineForward: deleteRanges(getSelections().map { resolveDeleteHardLineForwardRange(document, selection: $0) })
        case .toggleComment: toggleComment()
        case .toggleBlockComment: toggleComment(block: true)
        case .moveCursorToDocStart: move(.start, extending: false)
        case .moveCursorToDocEnd: move(.end, extending: false)
        case .expandSelectionDocStart: move(.start, extending: true)
        case .expandSelectionDocEnd: move(.end, extending: true)
        }
        return true
    }
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        defer { selectionActionMayMount = true; view?.updateEditorWidgets() }
        // The input method owns candidate navigation and cancellation until its
        // marked text is committed; editor shortcuts must not steal those keys.
        if hasMarkedText() { return textInputContext.handleEvent(event) }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if event.keyCode == 48, acceptEditPrediction() { return true }
            if event.keyCode == 53, predictionController?.dismiss() == true { return true }
        }
        if let command = resolveEditorCommandFromKeyboardEvent(event, keymap: keymap) { return performCommand(command) }
        if let direction = resolveFindAgainShortcut(event), let search { search.next(previous: direction == .previous); return true }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let extending = flags.contains(.shift), navigationFlags = flags.subtracting(.shift)
        if navigationFlags == [.command], event.keyCode == 123 || event.keyCode == 124 {
            move(event.keyCode == 123 ? .textStart : .lineEnd, extending: extending); return true
        }
        if navigationFlags.isEmpty, event.keyCode == 115 || event.keyCode == 119 {
            move(event.keyCode == 115 ? .lineStart : .lineEnd, extending: extending); return true
        }
        if flags == [.command] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil); return true
            case "v": paste(nil); return true
            case "x": cut(nil); return true
            default: break
            }
        }
        guard hasEditableSelection else { return false }
        return textInputContext.handleEvent(event)
    }
    public func doCommand(by selector: Selector) {
        let command = NSStringFromSelector(selector)
        let extending = command.contains("AndModifySelection")
        switch command {
        case "insertNewline:", "insertLineBreak:": insertText(document.eol, replacementRange: .init(location: NSNotFound, length: 0))
        case "insertTab:": indent(outdent: false, lineBased: false)
        case "insertBacktab:": indent(outdent: true, lineBased: false)
        case "deleteToBeginningOfLine:": deleteRanges(getSelections().map { resolveDeleteSoftLineBackwardRange(document, selection: $0, layout: view?.editorCursorLayout ?? .init()) })
        case "deleteWordBackward:": deleteRanges(getSelections().map { resolveDeleteWordBackwardRange(document, selection: $0) })
        case "deleteWordForward:": deleteRanges(getSelections().map {
            .init(start: $0.start, end: $0.isCollapsed ? nativeEditorDestination(document, from: $0.focus, movement: .wordForward) : $0.end)
        })
        case "deleteToEndOfParagraph:": deleteRanges(getSelections().map { resolveDeleteHardLineForwardRange(document, selection: $0) })
        case "deleteBackward:", "deleteForward:": delete(forward: command == "deleteForward:")
        case "moveWordLeft:", "moveWordBackward:", "moveWordLeftAndModifySelection:", "moveWordBackwardAndModifySelection:": moveNative(.wordBackward, extending: extending)
        case "moveWordRight:", "moveWordForward:", "moveWordRightAndModifySelection:", "moveWordForwardAndModifySelection:": moveNative(.wordForward, extending: extending)
        case "moveToBeginningOfParagraph:", "moveToBeginningOfParagraphAndModifySelection:": moveNative(.paragraphStart, extending: extending)
        case "moveToEndOfParagraph:", "moveToEndOfParagraphAndModifySelection:": moveNative(.paragraphEnd, extending: extending)
        case "moveParagraphBackward:", "moveParagraphBackwardAndModifySelection:": moveNative(.paragraphBackward, extending: extending)
        case "moveParagraphForward:", "moveParagraphForwardAndModifySelection:": moveNative(.paragraphForward, extending: extending)
        case "moveLeft:", "moveBackward:", "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:": move(.left, extending: extending)
        case "moveRight:", "moveForward:", "moveRightAndModifySelection:", "moveForwardAndModifySelection:": move(.right, extending: extending)
        case "moveUp:", "moveUpAndModifySelection:": move(.up, extending: extending)
        case "moveDown:", "moveDownAndModifySelection:": move(.down, extending: extending)
        case "moveToBeginningOfLine:", "moveToBeginningOfLineAndModifySelection:": move(.lineStart, extending: extending)
        case "moveToEndOfLine:", "moveToEndOfLineAndModifySelection:": move(.lineEnd, extending: extending)
        case "moveToBeginningOfDocument:", "moveToBeginningOfDocumentAndModifySelection:": move(.start, extending: extending)
        case "moveToEndOfDocument:", "moveToEndOfDocumentAndModifySelection:": move(.end, extending: extending)
        case "cancelOperation:":
            if compositionEdits > 0 {
                // Restore history too: replaying provisional edits backward would
                // replace the pre-composition redo stack with the marked text.
                let previousCount = document.lineCount
                predictionController?.cancelComposition()
                if let compositionDocument { document = compositionDocument }
                if let compositionCarets { setCarets(compositionCarets) }
                if let state = compositionAnnotationState { annotations = state.annotations; annotationUndo = state.undo; annotationRedo = state.redo }
                let selections = compositionSelections
                clearComposition(); assignSelections(selections)
                publishSelection(); scheduleRender()
                onChange?(.init(startLine: compositionSelection.start.line, endLine: document.lineCount - 1,
                                previousLineCount: previousCount, lineCount: document.lineCount))
            } else if hasEditableSelection {
                let primary = currentSelection
                if secondarySelections.isEmpty { assignSelections([.init(start: primary.focus, end: primary.focus)]) }
                else { assignSelections([primary]) }
                publishSelection()
            }
        default: break
        }
    }
    private enum Movement { case left, right, up, down, textStart, lineStart, lineEnd, start, end }
    private func destination(_ movement: Movement, from offset: Int) -> Int {
        var position = document.positionAt(offset)
        let line = document.getLineText(position.line) as NSString
        switch movement {
        case .start: return 0
        case .end: return document.utf16Length
        case .textStart, .lineStart: position.character = 0
        case .lineEnd: position.character = line.length
        case .up: position.line = max(0, position.line - 1)
        case .down: position.line = min(document.lineCount - 1, position.line + 1)
        case .left:
            if position.character > 0 { position.character = line.rangeOfComposedCharacterSequence(at: position.character - 1).location }
            else if position.line > 0 { position.line -= 1; position.character = document.getLineText(position.line).utf16.count }
        case .right:
            if position.character < line.length { position.character = NSMaxRange(line.rangeOfComposedCharacterSequence(at: position.character)) }
            else if position.line + 1 < document.lineCount { position.line += 1; position.character = 0 }
        }
        return document.offsetAt(position)
    }
    private var currentSelection: EditorSelection {
        .init(anchor: document.positionAt(anchorOffset), focus: document.positionAt(headOffset))
    }
    private func move(_ movement: Movement, extending: Bool) {
        guard isActive, hasEditableSelection else { return }
        unmarkText()
        let previous = navigationSelections ?? getSelections()
        let next: [EditorSelection]
        if movement == .start || movement == .end {
            let focus = document.positionAt(movement == .start ? 0 : document.utf16Length)
            next = previous.map { .init(anchor: extending ? $0.anchor : focus, focus: focus) }
        } else {
            let command: EditorCursorMovement
            switch movement {
            case .left: command = .left
            case .right: command = .right
            case .up: command = .up
            case .down: command = .down
            case .textStart: command = .textStart
            case .lineStart: command = .start
            case .lineEnd: command = .end
            case .start, .end: return
            }
            let layout = view?.editorCursorLayout ?? .init()
            next = extending ? mapSelectionShift(document, selections: previous, movement: command, layout: layout)
                : mapCursorMove(document, selections: previous, movement: command, layout: layout)
        }
        assignSelections(next); navigationSelections = next.count == getSelections().count ? next : getSelections(); navigationSelection = navigationSelections?.last
        publishSelection(preservingNavigation: true)
        view?.revealEditorCaret(document.positionAt(headOffset))
    }
    private func moveNative(_ movement: NativeEditorNavigation, extending: Bool) {
        guard isActive, hasEditableSelection else { return }
        unmarkText()
        let layout = view?.editorCursorLayout ?? .init()
        let selections = getSelections().map { selection in
            let origin = extending ? selection.focus : movement.forward ? selection.end : selection.start
            let focus = nativeEditorDestination(document, from: origin, movement: movement, layout: layout)
            return EditorSelection(anchor: extending ? selection.anchor : focus, focus: focus)
        }
        assignSelections(selections); publishSelection()
        view?.revealEditorCaret(document.positionAt(headOffset))
    }
    private func deleteRanges(_ ranges: [TextRange]) {
        guard isActive, hasEditableSelection else { return }
        unmarkText(); let before = getSelections()
        do {
            let selections = ranges.map { EditorSelection(start: $0.start, end: $0.end) }
            if let change = try replaceSelections(selections, texts: Array(repeating: "", count: selections.count)) {
                recordUndo(count: 1, before: before, after: getSelections(), undoBoundary: false); onChange?(change)
            }
        } catch { onError?(error) }
    }
    @discardableResult public func openSearch(replacing: Bool = false) -> DiffEditorSearch? {
        guard isActive else { return nil }
        unmarkText()
        if let search { search.replacing = replacing; view?.focusSearch(); return search }
        var query = ""
        if hasEditableSelection && selected.length == 0 {
            let position = document.positionAt(headOffset), line = document.getLineText(position.line)
            var word: NSRange?
            line.enumerateSubstrings(in: line.startIndex..<line.endIndex, options: .byWords) { _, range, _, stop in
                let utf16 = NSRange(range, in: line)
                if position.character >= utf16.location && position.character <= NSMaxRange(utf16) { word = utf16; stop = true }
            }
            if let word {
                let start = document.offsetAt(.init(line: position.line, character: word.location))
                select(.init(location: start, length: word.length)); query = selectedText
            }
        }
        let session = DiffEditorSearch(editor: self, query: query, replacing: replacing)
        search = session; view?.showSearch(session); session.refresh(); view?.focusSearch()
        return session
    }
    public func closeSearch() {
        guard search != nil else { return }
        search?.stop(); search = nil; view?.hideSearch()
    }
    func searchPresentationChanged() { view?.searchPresentationChanged() }
    func revealSearchMatch(_ range: NSRange) {
        select(range); view?.revealEditorCaret(document.positionAt(NSMaxRange(range)))
    }
    public func replaceSearchMatch(_ match: NSRange, params: EditorSearchParams, expectedVersion: Int) async throws {
        try Task.checkCancellation()
        guard isActive, hasEditableSelection else { throw DiffEditorError.detached }
        guard document.version == expectedVersion else { throw DiffEditorError.staleSearchDocument }
        guard match.location >= 0, match.length > 0, match.location <= document.utf16Length,
              match.length <= document.utf16Length - match.location else { throw DiffEditorError.invalidSearchReplacement }
        unmarkText()
        let snapshot = document, revision = generation
        let task = Task.detached(priority: .userInitiated) { try buildSearchReplacementText(snapshot, params: params, match: match) }
        let replacement = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard isActive, hasEditableSelection else { throw DiffEditorError.detached }
        guard document.version == expectedVersion, generation == revision else { throw DiffEditorError.staleSearchDocument }
        let range = TextRange(start: document.positionAt(match.location), end: document.positionAt(NSMaxRange(match)))
        let end = match.location + document.normalizeEol(replacement).utf16.count
        let applied = applyCommandEdits([.init(range: range, newText: replacement)]) { document in
            let position = document.positionAt(end); return [.init(start: position, end: position)]
        }
        if !applied { throw DiffEditorError.invalidSearchReplacement }
    }
    /// Prepares replacements off the main actor, then commits one undoable batch.
    /// An intervening edit invalidates the result instead of replacing newer text.
    @discardableResult public func replaceAll(_ params: EditorSearchParams) async throws -> Int {
        try Task.checkCancellation()
        guard isActive, hasEditableSelection else { throw DiffEditorError.detached }
        unmarkText()
        searchReplacementJobs += 1
        defer { searchReplacementJobs -= 1 }
        let snapshot = document, version = document.version, revision = generation
        let task = Task.detached(priority: .userInitiated) { try buildSearchReplacementEdits(snapshot, params: params) }
        let edits = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard isActive, hasEditableSelection else { throw DiffEditorError.detached }
        guard document.version == version, generation == revision else { throw DiffEditorError.staleSearchDocument }
        let positioned = edits.map { TextEdit(range: .init(start: document.positionAt($0.range.location), end: document.positionAt(NSMaxRange($0.range))), newText: $0.newText) }
        guard !positioned.isEmpty else { return 0 }
        guard applyCommandEdits(positioned) else { throw DiffEditorError.invalidSearchReplacement }
        return edits.count
    }
    public func performLineCommand(_ command: EditorLineCommand) {
        guard isActive, hasEditableSelection else { return }
        unmarkText()
        let result = resolveLineCommandEdits(document, selections: getSelections(), command: command)
        applyCommandEdits(result.edits) { _ in result.selections }
    }
    public func toggleComment(block: Bool = false) {
        guard isActive, hasEditableSelection else { return }
        unmarkText()
        let config = resolveCommentConfig(document.languageId, overrides: languageCommentConfig)
        if !block, let token = config.lineComment {
            applyCommandEdits(resolveLineCommentEdits(document, selections: getSelections(), token: token))
        } else if let result = resolveBlockCommentEdits(document, selections: getSelections(), tokens: config.blockComment, linewise: !block) {
            if block {
                applyCommandEdits(result.edits) { document in
                    result.nextSelectionOffsets.map { selection in
                        .init(start: document.positionAt(selection.start), end: document.positionAt(selection.end), direction: selection.direction)
                    }
                }
            } else { applyCommandEdits(result.edits) }
        }
    }
    @discardableResult private func applyCommandEdits(_ edits: [TextEdit], selection resolve: ((TextDocument) -> [EditorSelection]?)? = nil) -> Bool {
        do { return try applyEditorEdits(edits, selection: resolve) }
        catch { onError?(error); return false }
    }
    private func applyEditorEdits(_ edits: [TextEdit], selection resolve: ((TextDocument) -> [EditorSelection]?)?, normalizeEol: Bool = true) throws -> Bool {
        let edits = normalizeEol ? edits.map { TextEdit(range: $0.range, newText: document.normalizeEol($0.newText)) } : edits
        let before = getSelections(), offsets = getSelections().map { (document.offsetAt($0.anchor), document.offsetAt($0.focus)) }
        guard let change = try document.applyEdits(edits, selectionsBefore: before, coalescing: false) else { return false }
        remapExternalCarets(); trackAnnotations(change)
        let mapped = offsets.map { pair in
            EditorSelection(anchor: document.positionAt(remapEditorOffset(pair.0, through: document.lastAppliedEdits)),
                            focus: document.positionAt(remapEditorOffset(pair.1, through: document.lastAppliedEdits)))
        }
        // Programmatic edits target additions even when the old side was selected.
        assignSelections(resolve?(document) ?? (mapped.isEmpty ? [currentSelection] : mapped))
        publishSelection(); scheduleRender(); recordUndo(count: 1, before: before, after: getSelections()); onChange?(change)
        return true
    }
    private func indent(outdent: Bool, lineBased: Bool) {
        guard isActive, hasEditableSelection else { return }
        unmarkText(); let selections = getSelections()
        if !outdent && !lineBased && selections.allSatisfy({ $0.start.line == $0.end.line }) {
            let texts = selections.map { document.getLineText($0.start.line).utf16.first == 9 ? "\t" : String(repeating: " ", count: max(0, tabSize)) }
            do {
                if let change = try replaceSelections(selections, texts: texts) { recordUndo(count: 1, before: selections, after: getSelections()); onChange?(change) }
            } catch { onError?(error) }
            return
        }
        var edits: [Int: TextEdit] = [:]
        for selection in selections {
            for edit in resolveIndentEdits(document, selection: selection, tabSize: tabSize, outdent: outdent).edits {
                edits[edit.range.start.line] = edit
            }
        }
        applyCommandEdits(edits.keys.sorted().compactMap { edits[$0] })
    }
    private func delete(forward: Bool) {
        guard hasEditableSelection else { return }
        let ranges: [TextRange] = getSelections().map { selection in
            guard selection.isCollapsed else { return .init(start: selection.start, end: selection.end) }
            let head = document.offsetAt(selection.focus)
            var other = destination(forward ? .right : .left, from: head)
            if !forward && other == head - 1 && tabSize > 0 {
                let position = document.positionAt(head), line = document.getLineText(position.line) as NSString
                let leading = line.substring(to: position.character)
                if leading.allSatisfy({ $0 == " " || $0 == "\t" }), position.character >= tabSize,
                   line.substring(with: .init(location: position.character - tabSize, length: tabSize)).allSatisfy({ $0 == " " }) { other = head - tabSize }
            }
            return .init(start: document.positionAt(min(head, other)), end: document.positionAt(max(head, other)))
        }
        deleteRanges(ranges)
    }
    /// Replaces comments using line positions in the current edited document.
    /// Use this explicit write when an equal-valued array should reset mapped positions.
    public func setAnnotations(_ annotations: [LineAnnotation]) {
        guard isActive else { return }
        providedAnnotations = annotations; self.annotations = annotations
        scheduleRender()
    }
    /// Replaces side-less comments in a single-file editing session.
    public func setFileAnnotations(_ annotations: [FileLineAnnotation]) throws {
        guard isFilePresentation else { throw DiffEditorError.incompatibleSource }
        setAnnotations(annotations.map(\.renderedAnnotation))
    }
    func receiveExternal(_ incoming: HighlightedDiff, options: DiffRenderOptions, annotations: [LineAnnotation]) {
        let newAnnotations = annotations != externalAnnotations && annotations != providedAnnotations && annotations != self.annotations
        let optionsChanged = self.options != options
        let sourceChanged = external.diff != incoming.diff
        if sourceChanged, isActive {
            do {
                // Build the new diff baseline before mutating input or history. An
                // unsupported partial source must leave the current draft usable.
                let session = try DiffEditSession(diff: incoming.diff, options: diffOptions)
                unmarkText(); predictionController?.reset(); clipboardController?.cancel(); closeSelectionAction()
                let language = incoming.diff.lang ?? getFiletypeFromFileName(incoming.diff.name)
                let resetsHistory = !fileInfo.name.utf16.elementsEqual(incoming.diff.name.utf16)
                    || !document.languageId.utf16.elementsEqual(language.utf16)
                let contents = incoming.diff.additionLines.joined()
                let previousLines = document.lineCount
                let textChanged = !document.getText().utf16.elementsEqual(contents.utf16)
                var change: TextDocumentChange?
                if resetsHistory {
                    document = TextDocument(uri: incoming.diff.name, text: contents, languageId: language, editStack: .init(maxEntries: Int.max))
                    suspendedScrollOrigin = nil; restoreScrollOrigin = nil
                    setCarets(carets); setMarkers([])
                    undoManager.removeAllActions(); annotationUndo = []; annotationRedo = []; undoGroups = []; redoGroups = []; canCoalesceUndo = false
                    assignSelections([.init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0))])
                    self.annotations = annotations
                    if textChanged {
                        change = .init(startLine: 0, endLine: max(0, document.lineCount - 1), previousLineCount: previousLines, lineCount: document.lineCount)
                    }
                } else if textChanged {
                    let before = getSelections(), priorAnnotations = self.annotations
                    change = try document.applyResolvedEdits([.init(range: .init(location: 0, length: document.utf16Length), newText: contents)], selectionsBefore: before, coalescing: false)
                    remapExternalCarets()
                    self.annotations = annotations
                    annotationUndo.append(.init(before: priorAnnotations, after: annotations)); annotationRedo = []
                    // A full-document replacement maps both endpoints to its end,
                    // matching upstream remapOffsetThroughEdits.
                    let position = document.positionAt(document.utf16Length)
                    assignSelections([.init(start: position, end: position)])
                    recordUndo(count: 1, before: before, after: getSelections())
                } else { self.annotations = annotations }
                engine = DiffEditingEngine(session); initial = incoming; retainedSessionDiff = incoming.diff; suspendedExpansions = [:]; restoringExpansions = nil
                fileInfo = .init(name: incoming.diff.name, lang: incoming.diff.lang)
                external = incoming; externalAnnotations = annotations; providedAnnotations = annotations; self.options = options
                hasEditableSelection = true; publishSelection(); scheduleRender()
                if let change { onChange?(change) }
                return
            } catch { onError?(error); return }
        }
        if sourceChanged { generation += 1 }
        external = incoming; externalAnnotations = annotations; self.options = options
        if newAnnotations { providedAnnotations = annotations; self.annotations = annotations }
        if newAnnotations || optionsChanged { scheduleRender() }
    }
    // A pending preview may have captured the previous fold map. Restart it
    // against the explicit replacement before it can restore stale folds.
    func expansionStateChanged(_ regions: [Int: HunkExpansionRegion]) {
        guard isPreparing else { return }
        restoringExpansions = regions
        scheduleRender()
    }
    private func scheduleRender() {
        guard isActive else { return }
        predictionPresentationVersion = nil; predictionController?.inputChanged(force: true)
        search?.documentChanged()
        bracketTokenVersion = nil; refreshBracketMatches()
        guard let view else { return }
        renderTask?.cancel(); generation += 1; isPreparing = true
        let generation = generation, document = document, expansions = restoringExpansions ?? (suspendedExpansions.isEmpty ? view.editorExpansions : suspendedExpansions), options = options
        suspendedExpansions = [:]
        renderTask = Task { [weak self, engine, highlighter] in
            do {
                let state = try await engine.update(document, expansions: expansions)
                try Task.checkCancellation()
                guard let self, self.isActive, self.generation == generation else { return }
                let plain = HighlightedDiff(sourceID: self.sourceID, diff: state.diff, oldTokens: self.initial.oldTokens, newTokens: [],
                                            foreground: self.initial.foreground, background: self.initial.background, palette: self.initial.palette)
                self.install(plain, state: state, options: options)
                try await Task.sleep(for: .milliseconds(100))
                let highlighted = try await highlighter.prepareForEditing(state.diff, session: self.highlightSession, options: options).identifyingSource(as: self.sourceID)
                try Task.checkCancellation()
                guard self.isActive, self.generation == generation else { return }
                var highlightedState = state; highlightedState.expansions = self.view?.editorExpansions ?? state.expansions
                self.bracketTokens = highlighted.newTokens; self.bracketTokenVersion = document.version
                self.install(highlighted, state: highlightedState, options: options); self.restoreScrollOrigin = nil; self.isPreparing = false
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == generation else { return }
                self.isPreparing = false; self.onError?(error)
            }
        }
    }
    private func install(_ highlighted: HighlightedDiff, state: EditorRenderState, options: DiffRenderOptions) {
        retainedSessionDiff = state.diff; predictionPresentationVersion = document.version
        syncingSelection = true
        view?.renderEditor(highlighted, options: options, annotations: annotations, expansions: state.expansions)
        syncingSelection = false; restoringExpansions = nil
        predictionController?.presentationChanged()
        if hasEditableSelection { publishSelection(preservingNavigation: true); view?.revealEditorCaret(document.positionAt(headOffset)) }
        if let origin = restoreScrollOrigin, let view {
            view.restoreEditorScrollOrigin(origin)
            // Keep the requested viewport through both plain and highlighted installs.
            if !highlighted.newTokens.isEmpty { restoreScrollOrigin = nil }
        }
    }
    public func waitForRendering() async { await renderTask?.value; await view?.waitForLayout() }
    private var teardownTask: Task<Void, Never>?
    // Internal scheduling seam for deterministic lifecycle race tests.
    var beforeCompletionFinalization: (@MainActor () async -> Void)?
    private var isCompleting = false
    private var completionDelivered = false
    /// Wait for the notification from review removal/reset, if one was scheduled.
    public func waitForTeardown() async { await teardownTask?.value }
    func discardAfterRemoval() {
        guard isActive || (isCompleting && !completionDelivered) else { abandon(); return }
        suspend()
        let snapshot = document, original = external.diff
        let comments = annotations, originalComments = externalAnnotations
        let isFile = isFilePresentation
        let expansions = suspendedExpansions, threshold = options.collapsedContextThreshold
        let completion = onEditComplete, failure = onError
        abandon()
        guard let completion else { return }
        completionDelivered = true
        // The review clears its item maps synchronously before this task resumes.
        // Completion acceptance is intentionally ignored for a removed item.
        teardownTask = Task { [engine] in
            do {
                _ = try await engine.update(snapshot, expansions: expansions)
                let state = try await engine.finish(threshold: threshold)
                let event = DiffEditCompletion(fileDiff: state.diff, originalFileDiff: original,
                    oldFile: state.diff.type == .new ? nil : .init(name: state.diff.prevName ?? state.diff.name, contents: state.diff.deletionLines.joined()),
                    newFile: state.diff.type == .deleted ? nil : .init(name: state.diff.name, contents: state.diff.additionLines.joined(), lang: state.diff.lang),
                    annotations: comments, originalAnnotations: originalComments, isFile: isFile)
                _ = completion(event)
            } catch { failure?(error) }
        }
    }
    func abandon() {
        unmarkText(); suspendedScrollOrigin = view?.editorScrollOrigin ?? suspendedScrollOrigin; releaseRetainedState()
        closeSearch(); predictionController?.cancel(); clipboardController?.cancel(); closeSelectionAction()
        renderTask?.cancel(); generation += 1; isActive = false; isPreparing = false
        view?.detachEditor(self); view?.render(external, options: options, annotations: externalAnnotations)
        undoManager.removeAllActions()
        Task { [highlighter, highlightSession] in await highlighter.releaseEditingSession(highlightSession) }
    }

    /// Finalizes current text, invokes the completion handler, then installs or restores the external diff.
    @discardableResult public func complete(_ mode: DiffEditCompletionMode = .install) async throws -> DiffEditCompletion {
        guard isActive else { throw DiffEditorError.detached }
        isCompleting = true
        defer { isCompleting = false }
        let view = self.view
        suspendedScrollOrigin = view?.editorScrollOrigin ?? suspendedScrollOrigin
        unmarkText(); closeSearch(); predictionController?.cancel(); clipboardController?.cancel(); closeSelectionAction(); renderTask?.cancel(); generation += 1; isActive = false; isPreparing = false
        let completionGeneration = generation
        installedCompletionDocument = nil
        do {
            await beforeCompletionFinalization?()
            _ = try await engine.update(document, expansions: restoringExpansions ?? view?.editorExpansions ?? suspendedExpansions)
            try Task.checkCancellation()
            let state = try await engine.finish(threshold: options.collapsedContextThreshold)
            try Task.checkCancellation()
            guard generation == completionGeneration, view == nil || view?.attachedEditor === self else { throw DiffEditorError.detached }
            let event = DiffEditCompletion(fileDiff: state.diff, originalFileDiff: external.diff,
                oldFile: state.diff.type == .new ? nil : .init(name: state.diff.prevName ?? state.diff.name, contents: state.diff.deletionLines.joined()),
                newFile: state.diff.type == .deleted ? nil : .init(name: state.diff.name, contents: state.diff.additionLines.joined(), lang: state.diff.lang),
                annotations: annotations, originalAnnotations: externalAnnotations, isFile: isFilePresentation)
            completionDelivered = true
            releaseRetainedState()
            let accepted = onEditComplete?(event) ?? defaultCompletionAcceptance
            guard generation == completionGeneration, view == nil || view?.attachedEditor === self else { throw DiffEditorError.detached }
            let prepared: HighlightedDiff?
            if mode == .install && accepted {
                prepared = try await highlighter.prepare(state.diff, options: options).identifyingSource(as: sourceID)
                try Task.checkCancellation()
                guard generation == completionGeneration, view == nil || view?.attachedEditor === self else { throw DiffEditorError.detached }
            } else { prepared = nil }
            view?.detachEditor(self)
            if let prepared {
                installedCompletionDocument = prepared
                view?.renderEditor(prepared, options: options, annotations: annotations, expansions: state.expansions)
            } else { view?.render(external, options: options, annotations: externalAnnotations) }
            undoManager.removeAllActions()
            await highlighter.releaseEditingSession(highlightSession)
            return event
        } catch {
            releaseRetainedState()
            if view?.attachedEditor === self { view?.detachEditor(self); view?.render(external, options: options, annotations: externalAnnotations) }
            await highlighter.releaseEditingSession(highlightSession)
            if !(error is CancellationError) { onError?(error) }; throw error
        }
    }

    @MainActor struct RetainedState {
        var type: EditorType
        var fileInfo: EditorFileInfo
        var document: TextDocument
        var initial: HighlightedDiff
        var diff: FileDiffMetadata
        var annotations: [LineAnnotation]
        var annotationUndo: [AnnotationHistory]
        var annotationRedo: [AnnotationHistory]
        var undoManager: UndoManager
        var undoTarget: UndoTarget
        var undoGroups: [UndoGroup]
        var redoGroups: [UndoGroup]
        var canCoalesceUndo: Bool
        var maximumUndoGroups: Int
        var anchor: Int?
        var head: Int?
        var secondarySelections: [EditorSelection]
        var scrollOrigin: CGPoint?
        var expansions: [Int: HunkExpansionRegion]
        var value: EditState {
            let primary = anchor.flatMap { a in head.map { EditorSelection(anchor: document.positionAt(a), focus: document.positionAt($0)) } }
            var result = EditState(type: type, document: document, fileInfo: fileInfo, selections: secondarySelections + (primary.map { [$0] } ?? []),
                                   scrollOrigin: scrollOrigin, annotations: annotations, expandedHunks: expansions, diffSession: diff)
            result.undoGroups = undoGroups.map { .init(count: $0.count, before: $0.before, after: $0.after, remapBefore: $0.remapBefore, remapAfter: $0.remapAfter) }
            result.redoGroups = redoGroups.map { .init(count: $0.count, before: $0.before, after: $0.after, remapBefore: $0.remapBefore, remapAfter: $0.remapAfter) }
            result.annotationUndo = annotationUndo; result.annotationRedo = annotationRedo
            result.historyIdentity = document.historyIdentity
            result.maximumUndoGroups = maximumUndoGroups; result.canCoalesceUndo = canCoalesceUndo; result.initialDocument = initial
            return result
        }
        mutating func clear(_ parts: ClearEditStateOptions) {
            if parts.history { document.clearHistory(); undoManager.removeAllActions(); annotationUndo = []; annotationRedo = []; undoGroups = []; redoGroups = []; canCoalesceUndo = false }
            if parts.editor || parts.selections { anchor = nil; head = nil; secondarySelections = [] }
            if parts.editor || parts.view { scrollOrigin = nil }
        }
    }
    private func captureRetainedState() -> RetainedState {
        .init(type: type, fileInfo: fileInfo, document: document, initial: initial, diff: retainedSessionDiff, annotations: annotations,
              annotationUndo: annotationUndo, annotationRedo: annotationRedo, undoManager: undoManager, undoTarget: undoTarget,
              undoGroups: undoGroups, redoGroups: redoGroups, canCoalesceUndo: canCoalesceUndo, maximumUndoGroups: maximumUndoGroups,
              anchor: hasEditableSelection ? anchorOffset : nil, head: hasEditableSelection ? headOffset : nil, secondarySelections: secondarySelections, scrollOrigin: view?.editorScrollOrigin ?? suspendedScrollOrigin,
              expansions: restoringExpansions ?? view?.editorExpansions ?? suspendedExpansions)
    }
    public func getEditState() -> EditState {
        var state = captureRetainedState().value
        if compositionEdits > 0 {
            state.undoGroups?.append(.init(count: compositionEdits, before: compositionSelections, after: getSelections()))
            state.redoGroups = []; state.canCoalesceUndo = false
            state.document.setLastUndoBoundary(true)
            state.document.setLastUndoSelectionsAfter(getSelections())
            state.historyIdentity = state.document.historyIdentity
        }
        return state
    }
    private func releaseRetainedState() {
        guard let editStateKey, !retentionReleased else { return }
        retentionReleased = true
        stateManager.release(isFilePresentation ? .file : .fileDiff, key: editStateKey, editor: self, state: captureRetainedState())
        undoTarget.editor = nil
        // The dormant state owns the old registrations. Teardown must not erase them.
        undoManager = UndoManager(); undoManager.groupsByEvent = false; undoManager.levelsOfUndo = maximumUndoGroups
        undoTarget = UndoTarget(); undoTarget.editor = self
    }
}

/// SwiftUI host for the same native diff viewport and its attached input client.
public struct EditableFileDiffView: NSViewRepresentable {
    public var onEditorAttached: ((DiffEditor) -> Void)?
    public var editPrediction: EditPredictionOptions?
    public var clipboard: EditorClipboardProvider?
    public var enabledSelectionAction: Bool
    public var selectionActionRenderer: EditorSelectionActionRenderer?
    public var caretRenderer: EditorCaretRenderer?
    public var initialState: EditorInitialState?
    public var historyMaxEntries: Int
    public var keymap: EditorKeymap
    public var autoSurround: AutoSurround
    public var matchBrackets: Bool
    public var markers: [Marker]
    public var carets: [EditorCaret]
    public var renderMarkerPopover: ((Marker) -> NSView?)?
    public var separatorRenderer: DiffSeparatorRenderer?
    public var gutterRenderer: DiffGutterRenderer?
    public var annotationRenderer: DiffAnnotationRenderer?
    public var interactionHandlers: DiffInteractionHandlers?
    public var headerRenderers: DiffHeaderRenderers?
    public var document: HighlightedDiff
    @Binding public var isEditing: Bool
    public var options: DiffRenderOptions
    public var diffOptions: DiffOptions
    public var annotations: [LineAnnotation]
    public var completionMode: DiffEditCompletionMode
    public var editStateKey: String?
    public var onEditComplete: ((DiffEditCompletion) -> Bool)?
    public var onError: ((any Error) -> Void)?
    public init(document: HighlightedDiff, isEditing: Binding<Bool>, options: DiffRenderOptions = .init(), diffOptions: DiffOptions = .init(), annotations: [LineAnnotation] = [],
                completionMode: DiffEditCompletionMode = .install, editStateKey: String? = nil, historyMaxEntries: Int = 100, initialState: EditorInitialState? = nil, onEditorAttached: ((DiffEditor) -> Void)? = nil, editPrediction: EditPredictionOptions? = nil, clipboard: EditorClipboardProvider? = nil, enabledSelectionAction: Bool = false, selectionActionRenderer: EditorSelectionActionRenderer? = nil, caretRenderer: EditorCaretRenderer? = nil, keymap: EditorKeymap = .init(), autoSurround: AutoSurround = .default, matchBrackets: Bool = true, markers: [Marker] = [], carets: [EditorCaret] = [], renderMarkerPopover: ((Marker) -> NSView?)? = nil, onEditComplete: ((DiffEditCompletion) -> Bool)? = nil, onError: ((any Error) -> Void)? = nil, headerRenderers: DiffHeaderRenderers? = nil, interactionHandlers: DiffInteractionHandlers? = nil, annotationRenderer: DiffAnnotationRenderer? = nil, gutterRenderer: DiffGutterRenderer? = nil, separatorRenderer: DiffSeparatorRenderer? = nil) {
        self.separatorRenderer = separatorRenderer
        self.gutterRenderer = gutterRenderer
        self.annotationRenderer = annotationRenderer
        self.interactionHandlers = interactionHandlers;
        self.headerRenderers = headerRenderers
        self.document = document; _isEditing = isEditing; self.options = options; self.diffOptions = diffOptions; self.annotations = annotations
        self.enabledSelectionAction = enabledSelectionAction; self.selectionActionRenderer = selectionActionRenderer; self.caretRenderer = caretRenderer
        self.clipboard = clipboard; self.editPrediction = editPrediction; self.onEditorAttached = onEditorAttached; self.initialState = initialState; self.historyMaxEntries = historyMaxEntries; self.keymap = keymap; self.autoSurround = autoSurround; self.matchBrackets = matchBrackets
        self.markers = markers; self.carets = carets; self.renderMarkerPopover = renderMarkerPopover
        self.completionMode = completionMode; self.editStateKey = editStateKey; self.onEditComplete = onEditComplete; self.onError = onError
    }
    @MainActor public final class Coordinator {
        var gutterRenderer: DiffGutterRenderer?
        var annotationRenderer: DiffAnnotationRenderer?
        var editor: DiffEditor?
        var completion: Task<Void, Never>?
        let highlighter = DiffHighlighter()
        var installed: HighlightedDiff?
        var installedAnnotations: [LineAnnotation]?
        var providedAnnotations: [LineAnnotation]?
        var sourceID: UUID?
        func resolveAnnotations(documentID: UUID, provided: [LineAnnotation]) -> [LineAnnotation] {
            if sourceID != documentID {
                installed = nil; installedAnnotations = nil; sourceID = documentID
            } else if providedAnnotations != provided { installedAnnotations = nil }
            providedAnnotations = provided
            return installedAnnotations ?? provided
        }
    }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func makeNSView(context: Context) -> NativeDiffView { NativeDiffView(frame: .zero) }
    public func updateNSView(_ view: NativeDiffView, context: Context) {
        view.interactionHandlers = interactionHandlers ?? .init()
        view.headerRenderers = headerRenderers ?? .init()
        let coordinator = context.coordinator
        view.separatorRenderer = separatorRenderer
        if coordinator.gutterRenderer !== gutterRenderer {
            coordinator.gutterRenderer = gutterRenderer
            view.renderGutterUtility = gutterRenderer?.render
        }
        if coordinator.annotationRenderer !== annotationRenderer {
            coordinator.annotationRenderer = annotationRenderer
            view.renderAnnotation = annotationRenderer?.render
        }
        let effectiveAnnotations = coordinator.resolveAnnotations(documentID: document.id, provided: annotations)
        view.render(coordinator.installed ?? document, options: options, annotations: effectiveAnnotations)
        coordinator.editor?.onEditComplete = onEditComplete; coordinator.editor?.onError = onError
        coordinator.editor?.enabledSelectionAction = enabledSelectionAction; coordinator.editor?.selectionActionRenderer = selectionActionRenderer; coordinator.editor?.caretRenderer = caretRenderer
        coordinator.editor?.clipboard = clipboard; coordinator.editor?.editPrediction = editPrediction; coordinator.editor?.keymap = keymap; coordinator.editor?.autoSurround = autoSurround; coordinator.editor?.matchBrackets = matchBrackets
        coordinator.editor?.renderMarkerPopover = renderMarkerPopover
        coordinator.editor?.setMarkers(markers); coordinator.editor?.setCarets(carets)
        guard coordinator.completion == nil else { return }
        if isEditing && coordinator.editor == nil {
            do {
                let editor = try view.beginEditing(highlighter: coordinator.highlighter, diffOptions: diffOptions, editStateKey: editStateKey, historyMaxEntries: historyMaxEntries, initialState: initialState)
                editor.onEditComplete = onEditComplete; editor.onError = onError; coordinator.editor = editor
                editor.enabledSelectionAction = enabledSelectionAction; editor.selectionActionRenderer = selectionActionRenderer; editor.caretRenderer = caretRenderer
                editor.clipboard = clipboard; editor.editPrediction = editPrediction; editor.keymap = keymap; editor.autoSurround = autoSurround; editor.matchBrackets = matchBrackets
                editor.renderMarkerPopover = renderMarkerPopover; editor.setMarkers(markers); editor.setCarets(carets)
                onEditorAttached?(editor)
            } catch { onError?(error) }
        } else if !isEditing, let editor = coordinator.editor {
            coordinator.completion = Task { @MainActor in
                do {
                    try await editor.complete(completionMode)
                    coordinator.installed = view.displayedDocument
                    coordinator.installedAnnotations = view.displayedAnnotations
                }
                catch { if !(error is CancellationError) { onError?(error) } }
                coordinator.editor = nil; coordinator.completion = nil
                if !Task.isCancelled, isEditing {
                    do {
                        let resumed = try view.beginEditing(highlighter: coordinator.highlighter, diffOptions: diffOptions, editStateKey: editStateKey, historyMaxEntries: historyMaxEntries, initialState: initialState)
                        resumed.onEditComplete = onEditComplete; resumed.onError = onError; coordinator.editor = resumed
                        resumed.enabledSelectionAction = enabledSelectionAction; resumed.selectionActionRenderer = selectionActionRenderer; resumed.caretRenderer = caretRenderer
                        resumed.clipboard = clipboard; resumed.editPrediction = editPrediction; resumed.keymap = keymap; resumed.autoSurround = autoSurround; resumed.matchBrackets = matchBrackets
                        resumed.renderMarkerPopover = renderMarkerPopover; resumed.setMarkers(markers); resumed.setCarets(carets)
                        onEditorAttached?(resumed)
                    } catch { onError?(error) }
                }
            }
        }
    }
    public static func dismantleNSView(_ view: NativeDiffView, coordinator: Coordinator) {
        coordinator.completion?.cancel(); coordinator.editor?.abandon(); coordinator.editor = nil
    }
}

#endif

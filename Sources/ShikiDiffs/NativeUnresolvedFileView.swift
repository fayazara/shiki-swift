#if os(macOS)
import AppKit

public struct MergeConflictActionPayload: Equatable, Sendable {
    public var resolution: DiffResolution
    public var conflict: MergeConflictRegion
    public init(resolution: DiffResolution, conflict: MergeConflictRegion) {
        self.resolution = resolution; self.conflict = conflict
    }
}

/// Mutually exclusive, matching upstream's automatic and controlled action modes.
@MainActor public enum UnresolvedFileBehavior {
    case automatic(onResolve: ((FileContents, MergeConflictActionPayload) -> Void)? = nil)
    case controlled(onAction: (MergeConflictActionPayload, NativeUnresolvedFileView) -> Void)
}

/// Owns conflict source state and renders native controls with asynchronous highlighting.
/// Custom headers, annotations, gutters and controls remain available through `diffView`.
@MainActor public final class NativeUnresolvedFileView: NSView {
    public let diffView = NativeDiffView(frame: .zero)
    public let highlighter: DiffHighlighter
    public var behavior: UnresolvedFileBehavior = .automatic()
    public var onPostRender: ((NativeUnresolvedFileView, PostRenderPhase) -> Void)?
    public var onError: ((any Error) -> Void)?
    public private(set) var state: UnresolvedFileState?
    public private(set) var isPreparing = false
    public private(set) var preparationError: (any Error)?
    private var options = DiffRenderOptions()
    private var annotations: [LineAnnotation] = []
    private var sourceID = UUID()
    private var request = UUID()
    private var preparationTask: Task<Void, Never>?
    private struct PreparationKey: Equatable {
        var revision: UUID
        var source: UUID
        var theme: [UInt16]
        var lineLimit: Int
        var fileLimit: Int
    }
    private var preparationKey: PreparationKey?

    public init(frame: NSRect = .zero, highlighter: DiffHighlighter = DiffHighlighter()) {
        self.highlighter = highlighter
        super.init(frame: frame)
        addSubview(diffView); diffView.isHidden = true
        diffView.onPostRender = { [weak self] _, phase in
            guard let self else { return }; self.onPostRender?(self, phase)
        }
    }
    public required init?(coder: NSCoder) { fatalError("Use init(frame:highlighter:)") }
    deinit { preparationTask?.cancel() }
    public override func layout() { super.layout(); diffView.frame = bounds; diffView.layoutSubtreeIfNeeded() }

    /// Replaces source state. Parsing errors leave the existing presentation intact.
    public func render(file: FileContents, options: DiffRenderOptions = .init(),
                       annotations: [LineAnnotation] = [], maxContextLines: Int = 6) throws {
        let next = try UnresolvedFileState(file: file, maxContextLines: maxContextLines)
        render(state: next, options: options, annotations: annotations, preservingSource: false)
    }

    /// Installs externally owned state, including stable conflict identities.
    public func render(state: UnresolvedFileState, options: DiffRenderOptions = .init(),
                       annotations: [LineAnnotation] = [], preservingSource: Bool = true) {
        if self.state == nil || !preservingSource { sourceID = UUID() }
        self.state = state; self.options = options; self.annotations = annotations
        // UnresolvedFile always uses unified layout, even after its final conflict resolves.
        self.options.diffStyle = .unified; self.options.lineDiffType = .none
        presentAndPrepare()
    }

    /// Queries one-based new-file lines using the currently presented conflict diff.
    public func isLineRenderable(_ number: Int) throws -> Bool {
        try diffView.isLineRenderable(number)
    }
    public func getNearestRenderableLine(_ number: Int, direction: LineNavigationDirection) throws -> Int? {
        try diffView.getNearestRenderableLine(number, direction: direction)
    }
    /// Expands folded conflict context without scrolling. Expansion survives highlighting.
    @discardableResult public func revealLine(_ number: Int) throws -> Bool {
        try diffView.revealLine(number)
    }

    public func setEditorActiveLine(_ number: Int?, options: EditorActiveLineOptions = .init()) {
        diffView.setEditorActiveLine(number, options: options)
    }
    public func setOptions(_ options: DiffRenderOptions?) {
        guard let options else { return }
        self.options = options; self.options.diffStyle = .unified; self.options.lineDiffType = .none
        presentAndPrepare()
    }
    public func setLineAnnotations(_ annotations: [LineAnnotation]) {
        self.annotations = annotations; presentAndPrepare()
    }
    public func rerender() { guard state != nil else { return }; diffView.rerender() }

    /// Pure resolution, useful to controlled hosts; does not change this view.
    public func resolveConflict(_ conflictIndex: Int, resolution: DiffResolution) throws -> UnresolvedFileState? {
        guard var next = state, next.result.actions.contains(where: { $0.conflictIndex == conflictIndex }) else { return nil }
        try next.resolve(conflictIndex: conflictIndex, resolution: resolution)
        return next
    }

    /// Handles an action in the current mode. Automatic mode commits source before callbacks.
    @discardableResult
    public func performResolution(_ conflictIndex: Int, resolution: DiffResolution) throws -> Bool {
        guard let action = state?.result.actions.first(where: { $0.conflictIndex == conflictIndex }) else { return false }
        let payload = MergeConflictActionPayload(resolution: resolution, conflict: action.conflict)
        switch behavior {
        case let .controlled(onAction): onAction(payload, self)
        case let .automatic(onResolve):
            guard let next = try resolveConflict(conflictIndex, resolution: resolution) else { return false }
            state = next
            presentAndPrepare()
            onResolve?(next.file, payload)
        }
        return true
    }

    /// Cancels pending work and invalidates previously captured action handlers.
    public func cleanUp() {
        preparationTask?.cancel(); preparationTask = nil
        let ticket = UUID(); request = ticket
        preparationKey = nil
        diffView.cleanUp()
        guard request == ticket else { return }
        state = nil; isPreparing = false; preparationError = nil
        preparationKey = nil
        diffView.onResolveConflict = nil; diffView.mergeConflictActions = []
        guard request == ticket else { return }
        diffView.isHidden = true
    }

    private func presentAndPrepare() {
        guard let state else { return }
        let key = PreparationKey(revision: state.revision, source: sourceID,
            theme: Array(options.theme.utf16), lineLimit: options.tokenizeMaxLineLength,
            fileLimit: options.tokenizeMaxLength)
        if preparationKey == key, preparationError == nil, let displayed = diffView.displayedDocument {
            // Layout and annotation changes do not invalidate syntax tokens or
            // an in-flight preparation for the same source/theme/limits.
            diffView.render(displayed, options: options, annotations: annotations, markerRows: state.result.markerRows)
            return
        }
        preparationTask?.cancel()
        let ticket = UUID(); request = ticket
        preparationKey = key
        preparationError = nil; isPreparing = true
        let source = sourceID, options = options, annotations = annotations, highlighter = highlighter
        let old = diffView.displayedDocument
        let plain = HighlightedDiff(sourceID: source, diff: state.result.fileDiff, oldTokens: [], newTokens: [],
            foreground: old?.foreground ?? "#eeeeee", background: old?.background ?? "#101010",
            palette: old?.palette ?? .init())
        diffView.mergeConflictActions = state.result.actions
        guard request == ticket else { return }
        diffView.onResolveConflict = { [weak self] index, resolution in
            guard let self, self.request == ticket else { return }
            do { try self.performResolution(index, resolution: resolution) }
            catch { self.preparationError = error; self.onError?(error) }
        }
        diffView.isHidden = false
        diffView.render(plain, options: options, annotations: annotations, markerRows: state.result.markerRows)
        // Custom view factories can synchronously reenter render or cleanUp.
        guard request == ticket else { return }
        needsLayout = true; layoutSubtreeIfNeeded()
        guard request == ticket else { return }
        preparationTask = Task { [weak self] in
            do {
                let prepared = try await highlighter.prepare(state.result.fileDiff, options: options).identifyingSource(as: source)
                try Task.checkCancellation()
                guard let self, self.request == ticket else { return }
                self.isPreparing = false; self.preparationTask = nil
                // Display settings may have changed while the highlighter awaited
                // a theme or grammar. Use the latest layout and annotations.
                self.diffView.render(prepared, options: self.options, annotations: self.annotations, markerRows: state.result.markerRows)
            } catch {
                guard !Task.isCancelled, let self, self.request == ticket else { return }
                self.isPreparing = false; self.preparationTask = nil; self.preparationError = error
                self.onError?(error)
            }
        }
    }
}

#endif

#if os(macOS)
import AppKit
import CoreText
import Shiki
import SwiftUI

private final class DiffColorCache: @unchecked Sendable {
    static let shared = DiffColorCache()
    let values = NSCache<NSString, NSColor>()
    private init() { values.countLimit = 512 }
}
extension NSColor {
    static func diffHex(_ hex: String, fallback: NSColor = .textColor) -> NSColor {
        if let cached = DiffColorCache.shared.values.object(forKey: hex as NSString) { return cached }
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard [3, 4, 6, 8].contains(text.utf8.count),
              text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return fallback }
        let expanded = text.count <= 4 ? String(text.flatMap { [$0, $0] }) : text
        guard let value = UInt64(expanded, radix: 16) else { return fallback }
        let alpha = expanded.count == 8 ? CGFloat(value & 255) / 255 : 1
        let rgb = expanded.count == 8 ? value >> 8 : value
        let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: alpha)
        DiffColorCache.shared.values.setObject(color, forKey: hex as NSString)
        return color
    }
}
public struct DiffViewportMetrics: Sendable {
    public var tokenIndexesBuilt = 0
    public var pointerSourcesBuilt = 0
    public var oversizedTokenIndexUTF16Units = 0
    public var drawnRows = 0
    public var styledLines = 0
    public var cachedLines = 0
    public var cachedUTF16Units = 0
    public var lastDrawMilliseconds = 0.0
    public init() {}
}
/// AppKit entry point. The scroll view owns both columns, so vertical and horizontal
/// scroll synchronization cannot drift during momentum scrolling.
public struct EditorActiveLineOptions: Equatable, Sendable {
    public var side: DiffSide
    public var lineNumberOnly: Bool
    public init(side: DiffSide = .additions, lineNumberOnly: Bool = false) {
        self.side = side; self.lineNumberOnly = lineNumberOnly
    }
}

@MainActor public final class NativeDiffView: NSView {
    public let scrollView: NSScrollView = DiffScrollView()
    /// Label offset for a streamed excerpt. Source/event positions remain unchanged.
    public var startingLineIndex: Int = 1 {
        didSet { canvas.lineNumberOffset = max(1, startingLineIndex) - 1; canvas.needsDisplay = true }
    }
    /// Called after presentation changes, with this native view replacing the DOM node.
    public var onPostRender: ((NativeDiffView, PostRenderPhase) -> Void)?
    var presentationObserver: ((PostRenderPhase) -> Void)?
    private var presentationMounted = false
    private var presentationRevision = UUID()
    private func emitPostRender(unmount: Bool = false) {
        if unmount {
            guard presentationMounted else { return }
            presentationMounted = false
            let callback = onPostRender
            presentationObserver?(.unmount)
            callback?(self, .unmount)
        } else {
            let phase: PostRenderPhase = presentationMounted ? .update : .mount
            presentationMounted = true
            let callback = onPostRender
            presentationObserver?(phase)
            callback?(self, phase)
        }
    }
    /// Ends presentation and cancels pending work. Recycle preserves an attached editor's state.
    public func cleanUp(recycle: Bool = false) {
        let ticket = UUID(); presentationRevision = ticket
        emitPostRender(unmount: true)
        guard presentationRevision == ticket else { return }
        if let editor = attachedEditor {
            editor.suspend()
            guard presentationRevision == ticket else { return }
            if !recycle { editor.abandon() }
        }
        loadTask?.cancel(); loadTask = nil; loadRequest = nil; fileLoadError = nil
        let empty = HighlightedDiff(diff: .init(name: ""), oldTokens: [], newTokens: [], foreground: "#eeeeee", background: "#101010")
        canvas.mergeConflictActions = []
        canvas.setDocument(empty, options: options, annotations: [], markers: [], reset: true)
        guard presentationRevision == ticket else { return }
        canvas.document = nil; canvas.activeLine = nil
        sourceDocument = nil; hydratedDocument = nil; currentID = nil; currentSourceID = nil
        annotations = []; markerRows = []; headerFile = nil
        mergeConflictActions = []
        header.update(empty, renderers: .init(), options: options)
        guard presentationRevision == ticket else { return }
        header.isHidden = true; scrollView.isHidden = true
    }
    private let header = DiffHeaderView(frame: .zero)
    private var reviewHeaderScrollOffset: CGFloat?
    private var layoutHeaderHeight: CGFloat = 0
    private var layoutSearchHeight: CGFloat = 0
    func setReviewHeaderScrollOffset(_ offset: CGFloat) {
        guard reviewHeaderScrollOffset != offset else { return }
        reviewHeaderScrollOffset = offset; needsLayout = true
    }
    private var headerFile: FileContents?
    var isFilePresentation: Bool { headerFile != nil }
    private var stagingHeader = false
    private var headerNeedsUpdate = false
    public var headerRenderers = DiffHeaderRenderers() { didSet { if !stagingHeader { reloadHeader() } } }
    /// Install file metadata and callbacks atomically with the next document render.
    func stageFileHeader(_ file: FileContents, renderers: DiffHeaderRenderers) {
        stagingHeader = true
        headerFile = file; headerRenderers = renderers
        stagingHeader = false; headerNeedsUpdate = true
    }
    /// Re-evaluate presence-based callbacks after their captured state changes.
    public func reloadHeader() {
        headerNeedsUpdate = false
        if let document = canvas.document { header.update(document, renderers: headerRenderers, file: headerFile, options: options) }
        invalidateHeaderLayout()
    }
    /// Re-measure retained header content after an intrinsic-size-only change.
    /// Explicit frame-size changes are observed automatically.
    public func invalidateHeaderLayout() {
        header.needsLayout = true; needsLayout = true
        onHeaderLayoutChange?(); onLayoutChange?()
    }
    var onHeaderLayoutChange: (() -> Void)?
    private let canvas = DiffCanvas()
    private var hoverScrollObservation: NotificationObservation?
    private var searchBar: DiffSearchBar?
    private var currentID: UUID?
    private var currentSourceID: UUID?
    private var options = DiffRenderOptions()
    private var annotations: [LineAnnotation] = []
    private var markerRows: [MergeConflictMarkerRow] = []
    private var sourceDocument: HighlightedDiff?
    weak var attachedEditor: DiffEditor?
    private var renderingEditor = false
    private var hydratedDocument: HighlightedDiff?
    private var loadTask: Task<Void, Never>?
    private var loadRequest: UUID?
    public var loadHighlighter = DiffHighlighter()
    public var loadDiffFiles: DiffContentsLoader? {
        didSet {
            canvas.canLoadPartial = loadDiffFiles != nil
            if loadDiffFiles == nil { loadTask?.cancel(); loadTask = nil; loadRequest = nil }
            else { loadFilesIfNecessary() }
        }
    }
    public var onFilesLoaded: ((HighlightedDiff) -> Void)?
    public var onFileLoadError: ((any Error) -> Void)?
    public private(set) var fileLoadError: (any Error)?
    public var isLoadingFiles: Bool { loadRequest != nil }
    public var displayedAnnotations: [LineAnnotation] { annotations }
    public var displayedDocument: HighlightedDiff? { hydratedDocument ?? sourceDocument }
    public var interactionHandlers = DiffInteractionHandlers() { didSet { canvas.interactionHandlers = interactionHandlers } }
    public var renderGutterUtility: DiffGutterUtilityRenderer? {
        didSet { canvas.renderGutterUtility = renderGutterUtility }
    }
    public var separatorRenderer: DiffSeparatorRenderer? {
        didSet {
            guard separatorRenderer !== oldValue else { return }
            canvas.separatorRenderer = separatorRenderer
            canvas.clearSeparatorViews()
            canvas.resetAnnotationHeights()
        }
    }
    /// Re-measure custom separator content after its preferred height changes.
    public func invalidateSeparatorLayout() { canvas.updateSeparatorViews(); needsLayout = true }
    public var conflictActionRenderer: DiffConflictActionRenderer? {
        didSet {
            guard conflictActionRenderer !== oldValue else { return }
            canvas.conflictActionRenderer = conflictActionRenderer
            canvas.clearConflictActionViews(); canvas.resetAnnotationHeights()
        }
    }
    /// Supply `MergeConflictResult.actions` for custom conflict controls.
    public var mergeConflictActions: [MergeConflictDiffAction] = [] {
        didSet {
            guard mergeConflictActions != oldValue else { return }
            canvas.mergeConflictActions = mergeConflictActions
            canvas.clearConflictActionViews(); canvas.resetAnnotationHeights()
        }
    }
    public func invalidateConflictActionLayout() { canvas.updateConflictActionViews(); needsLayout = true }
    public func getHoveredLine() -> DiffHoveredLine? { canvas.gutterTarget ?? canvas.hoveredSourceLine }
    public var onSelectionChange: ((LineSelection?) -> Void)? { didSet { canvas.onSelectionChange = onSelectionChange } }
    /// Custom content for visible annotation rows. Intrinsic or fitting height
    /// determines the row extent; paired annotations use the taller view.
    public var renderAnnotation: ((LineAnnotation) -> NSView?)? {
        didSet { canvas.renderAnnotation = renderAnnotation; canvas.clearAnnotationViews(); canvas.resetAnnotationHeights(); canvas.updateAnnotationViews() }
    }
    /// Call after custom annotation content changes its preferred height.
    /// Existing mounted views are retained and the viewport anchor is preserved.
    public func invalidateAnnotationLayout() {
        canvas.invalidateAnnotationMeasurements()
        canvas.updateAnnotationViews()
        needsLayout = true
    }
    func containsCodePointer(_ event: NSEvent) -> Bool { canvas.visibleRect.contains(canvas.convert(event.locationInWindow, from: nil)) }
    func refreshHover(with event: NSEvent) { canvas.receiveHover(event) }
    func endHover(with event: NSEvent) { canvas.mouseExited(with: event) }
    var forwardScroll: ((NSEvent) -> Void)? {
        didSet { (scrollView as? DiffScrollView)?.forwardScroll = forwardScroll }
    }
    var onExpansion: ((Int, Int, ExpansionDirection) -> Void)?
    var onExpansionStateChange: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var preferredHeaderHeight: CGFloat { headerHeight(for: bounds.width) }
    func headerHeight(for width: CGFloat) -> CGFloat { options.disableFileHeader ? 0 : header.preferredHeight(for: width) }
    public var onResolveConflict: ((Int, DiffResolution) -> Void)? {
        get { canvas.onResolveConflict } set { canvas.onResolveConflict = newValue }
    }
    public var metrics: DiffViewportMetrics { canvas.metrics }
    public var rowCount: Int { canvas.plan?.rows.count ?? 0 }
    var contentHeight: CGFloat { canvas.rowHeights.totalHeight }
    var measuredRowHeights: RowHeightIndex { canvas.rowHeights }
    func resetMeasuredAnnotationHeights() {
        canvas.rowHeights = .init(rows: canvas.plan?.rows ?? [], options: options)
        canvas.invalidateAnnotationMeasurements()
        needsLayout = true
    }
    func restoreMeasuredRowHeights(_ heights: RowHeightIndex) {
        guard heights.rowCount == rowCount, heights.lineHeight == canvas.rowHeights.lineHeight else { return }
        canvas.rowHeights = heights
        canvas.updateSize(viewport: scrollView.contentSize)
        needsLayout = true
    }
    public var selectedLines: LineSelection? { canvas.selection }
    public var selectionHighlightSide: DiffSide? { canvas.selectionHighlightSide }
    public var selectionLineNumberOnly: Bool { canvas.selectionLineNumberOnly }
    public func getLineIndex(_ lineNumber: Int, side: DiffSide = .additions) -> DiffLineIndexes? {
        canvas.document?.diff.getLineIndex(lineNumber, side: side)
    }
    public var selectedTextRange: DiffTextSelection? { canvas.textSelection }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true; scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = canvas
        scrollView.contentView.postsBoundsChangedNotifications = true
        hoverScrollObservation = NotificationObservation(name: NSView.boundsDidChangeNotification, object: scrollView.contentView) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHeaderPosition(); self?.canvas.refreshHoverAfterViewportChange(); self?.canvas.updateAnnotationViews(); self?.canvas.updateEditorWidgets(); self?.attachedEditor?.predictionPresentationChanged() }
        }
        addSubview(scrollView); addSubview(header)
        header.onSizeChange = { [weak self] in self?.invalidateHeaderLayout() }
        canvas.onExpand = { [weak self] index, count, direction in self?.expandHunk(index, lines: count, direction: direction) }
        canvas.onLayoutChange = { [weak self] in self?.needsLayout = true; self?.onLayoutChange?() }
        canvas.setAccessibilityRole(.textArea)
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityLabel("Code diff")
    }
    public required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    private var hasScrollingHeader: Bool { reviewHeaderScrollOffset == nil && !options.stickyHeader }
    private var hiddenHeaderHeight: CGFloat {
        let offset = reviewHeaderScrollOffset ?? (hasScrollingHeader ? scrollView.contentView.bounds.minY + layoutHeaderHeight : 0)
        return min(layoutHeaderHeight, max(0, offset))
    }
    private func updateHeaderPosition() {
        let visible = layoutHeaderHeight - hiddenHeaderHeight
        header.isHidden = canvas.document == nil || options.disableFileHeader || visible == 0
        header.frame = .init(x: 0, y: bounds.height - visible, width: bounds.width, height: layoutHeaderHeight)
        searchBar?.frame = .init(x: 0, y: bounds.height - visible - layoutSearchHeight, width: bounds.width, height: layoutSearchHeight)
    }
    public override func scrollWheel(with event: NSEvent) { scrollView.scrollWheel(with: event) }
    public override func layout() {
        super.layout()
        layoutHeaderHeight = preferredHeaderHeight
        layoutSearchHeight = searchBar?.preferredHeight ?? 0
        let inset = hasScrollingHeader ? layoutHeaderHeight : 0
        let oldInset = scrollView.contentInsets.top
        let oldOrigin = scrollView.contentView.bounds.origin
        if oldInset != inset {
            scrollView.contentInsets = .init(top: inset, left: 0, bottom: 0, right: 0)
        }
        let reservedHeader = hasScrollingHeader ? 0 : layoutHeaderHeight - hiddenHeaderHeight
        scrollView.frame = .init(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - reservedHeader - layoutSearchHeight))
        canvas.updateSize(viewport: scrollView.contentSize)
        if oldInset != inset {
            // Keep the top/partially visible header anchored when its height or
            // sticky mode changes; scrolled source positions retain their row.
            let y = oldOrigin.y <= -oldInset ? -inset : oldOrigin.y < 0 ? oldOrigin.y + oldInset - inset : oldOrigin.y
            let clip = scrollView.contentView
            clip.scroll(to: clip.constrainBoundsRect(.init(origin: .init(x: oldOrigin.x, y: y), size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
        }
        updateHeaderPosition()
        canvas.refreshHoverAfterViewportChange()
        canvas.updateAnnotationViews(); canvas.updateEditorWidgets(); attachedEditor?.predictionPresentationChanged()
    }
    /// Editor state uses a nonnegative scroll offset including a scrolling header.
    var editorScrollOrigin: CGPoint {
        var point = scrollView.contentView.bounds.origin
        point.y += scrollView.contentInsets.top
        return point
    }
    @discardableResult func restoreEditorScrollOrigin(_ origin: CGPoint) -> CGPoint {
        let clip = scrollView.contentView
        let point = CGPoint(x: max(0, origin.x), y: max(0, origin.y) - scrollView.contentInsets.top)
        clip.scroll(to: clip.constrainBoundsRect(.init(origin: point, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        return editorScrollOrigin
    }
    /// Stable prepared IDs preserve scroll and selection across unrelated SwiftUI updates.
    public func render(_ document: HighlightedDiff, options: DiffRenderOptions = .init(), annotations: [LineAnnotation] = [], markerRows: [MergeConflictMarkerRow] = []) {
        var options = options
        if !markerRows.isEmpty {
            // Upstream UnresolvedFileHunksRenderer always presents conflicts
            // together and disables word-level difference highlighting.
            options.diffStyle = .unified
            options.lineDiffType = .none
        }
        if !renderingEditor, let attachedEditor {
            attachedEditor.receiveExternal(document, options: options, annotations: annotations)
            return
        }
        if sourceDocument?.id != document.id || sourceDocument?.sourceID != document.sourceID {
            loadTask?.cancel(); loadTask = nil; loadRequest = nil
            sourceDocument = document; hydratedDocument = nil; fileLoadError = nil
        }
        let document = hydratedDocument ?? document
        guard !presentationMounted || currentID != document.id || currentSourceID != document.sourceID || self.options != options || self.annotations != annotations || self.markerRows != markerRows else {
            if headerNeedsUpdate { reloadHeader() }
            return
        }
        let ticket = UUID(); presentationRevision = ticket
        scrollView.isHidden = false
        let changed = currentSourceID != document.sourceID
        currentSourceID = document.sourceID
        currentID = document.id; self.options = options; self.annotations = annotations; self.markerRows = markerRows
        let color = NSColor.diffHex(document.background)
        layer?.backgroundColor = color.cgColor; scrollView.backgroundColor = color
        headerNeedsUpdate = false
        header.update(document, renderers: headerRenderers, file: headerFile, options: options)
        guard presentationRevision == ticket else { return }
        canvas.setDocument(document, options: options, annotations: annotations, markers: markerRows, reset: changed)
        guard presentationRevision == ticket else { return }
        needsLayout = true; layoutSubtreeIfNeeded()
        guard presentationRevision == ticket else { return }
        if changed { restoreEditorScrollOrigin(.zero) }
        loadFilesIfNecessary()
        guard presentationRevision == ticket else { return }
        emitPostRender()
    }
    /// Updates presentation options without replacing the logical source.
    public func setOptions(_ options: DiffRenderOptions?) {
        guard let options else { return }
        guard let document = displayedDocument else { self.options = options; return }
        render(document, options: options, annotations: annotations, markerRows: markerRows)
    }
    /// Ghost text drawn after the end of lines, such as inline blame. It survives re-renders.
    public var lineTrailingText: [LineTrailingText] = [] {
        didSet { canvas.trailingText = Dictionary(lineTrailingText.map { ($0.lineNumber, $0) }, uniquingKeysWith: { _, last in last }) }
    }
    public func setLineAnnotations(_ annotations: [LineAnnotation]) {
        guard let document = displayedDocument else { self.annotations = annotations; return }
        render(document, options: options, annotations: annotations, markerRows: markerRows)
    }
    /// Refreshes custom content while retaining source, expansion and selection.
    public func rerender() {
        guard let document = displayedDocument else { return }
        if attachedEditor != nil {
            let ticket = presentationRevision
            reloadHeader()
            guard presentationRevision == ticket else { return }
            canvas.needsDisplay = true; needsLayout = true
            layoutSubtreeIfNeeded()
            guard presentationRevision == ticket else { return }
            emitPostRender()
        } else {
            currentID = nil
            render(document, options: options, annotations: annotations, markerRows: markerRows)
        }
    }
    /// Returns a value snapshot; changing it does not mutate the displayed context.
    public func getExpandedHunksMap() -> [Int: HunkExpansionRegion] { canvas.expandedRegions }
    public func getExpandedHunk(_ index: Int) -> HunkExpansionRegion { canvas.expandedRegions[index] ?? .init() }
    /// Replaces explicit expansions, including clearing them with an empty map.
    /// The map belongs to the currently presented source; replacing the source resets it.
    public func setExpandedHunksMap(_ regions: [Int: HunkExpansionRegion]) {
        guard canvas.document != nil, canvas.expandedRegions != regions else { return }
        let ticket = presentationRevision
        canvas.expanded = []; canvas.expandedRegions = regions
        canvas.refreshExpansionLayout()
        guard presentationRevision == ticket else { return }
        attachedEditor?.expansionStateChanged(regions)
        needsLayout = true
        onExpansionStateChange?()
        guard presentationRevision == ticket else { return }
        layoutSubtreeIfNeeded()
        guard presentationRevision == ticket else { return }
        emitPostRender()
    }
    public func expandHunk(_ index: Int, lines: Int? = nil, direction: ExpansionDirection = .up) {
        let ticket = presentationRevision
        let count = max(1, lines ?? options.expansionLineCount)
        canvas.expandHunk(index, lines: count, direction: direction); needsLayout = true
        guard presentationRevision == ticket else { return }
        attachedEditor?.expansionStateChanged(canvas.expandedRegions)
        onExpansion?(index, count, direction)
        guard presentationRevision == ticket else { return }
        loadFilesIfNecessary()
        if canvas.document != nil {
            layoutSubtreeIfNeeded()
            guard presentationRevision == ticket else { return }
            emitPostRender()
        }
    }
    public func retryLoadingFiles() { fileLoadError = nil; loadFilesIfNecessary() }
    private func loadFilesIfNecessary() {
        guard loadRequest == nil, fileLoadError == nil, hydratedDocument == nil, let source = sourceDocument,
              source.diff.isPartial, [.change, .renameChanged, .renamePure].contains(source.diff.type),
              let loader = loadDiffFiles else { return }
        let request = UUID(); loadRequest = request; fileLoadError = nil
        let highlighter = loadHighlighter
        loadTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let files = try await loader(source.diff)
                try Task.checkCancellation()
                guard let self, self.loadRequest == request, self.sourceDocument?.id == source.id else { return }
                var options = self.options
                var prepared = try await highlighter.hydrate(source.diff, files: files, options: options)
                while self.options != options {
                    try Task.checkCancellation(); options = self.options
                    prepared = try await highlighter.prepare(prepared.diff, options: options)
                }
                try Task.checkCancellation()
                guard self.loadRequest == request, self.sourceDocument?.id == source.id else { return }
                let result = prepared.identifyingSource(as: source.sourceID)
                self.loadRequest = nil; self.loadTask = nil; self.hydratedDocument = result
                self.render(source, options: self.options, annotations: self.annotations, markerRows: self.markerRows)
                self.onFilesLoaded?(result)
            } catch {
                guard let self, self.loadRequest == request else { return }
                self.loadRequest = nil; self.loadTask = nil
                if !(error is CancellationError) { self.fileLoadError = error; self.onFileLoadError?(error) }
            }
        }
    }
    private var foldedLineNavigation: FoldedLineNavigation? {
        canvas.document.map { FoldedLineNavigation(diff: $0.diff, options: options, expanded: canvas.expanded, regions: canvas.expandedRegions) }
    }
    /// Whether a one-based new-file line is outside folded context (independent of the viewport).
    public func isLineRenderable(_ number: Int) throws -> Bool {
        try foldedLineNavigation?.isRenderable(number) ?? true
    }
    /// Finds the nearest new-file line at or beyond the target in the given direction.
    public func getNearestRenderableLine(_ number: Int, direction: LineNavigationDirection) throws -> Int? {
        guard let navigation = foldedLineNavigation else { return number }
        return try navigation.nearest(number, direction: direction)
    }
    /// Expands the nearest edge of folded context to expose a new-file line. Does not scroll.
    @discardableResult public func revealLine(_ number: Int) throws -> Bool {
        guard let expansion = try foldedLineNavigation?.expansionToReveal(number) else { return false }
        expandHunk(expansion.index, lines: expansion.count, direction: expansion.direction)
        return true
    }
    public func scrollToLine(_ number: Int, side: DiffSide = .additions) {
        guard let rows = canvas.plan?.rows, let index = rows.firstIndex(where: { (side == .additions ? $0.newNumber : $0.oldNumber) == number }) else { return }
        scrollToRow(index)
    }
    public func scrollToRow(_ index: Int) {
        let y = min(max(0, canvas.rowOrigin(index)), max(0, canvas.frame.height - scrollView.contentSize.height))
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView); canvas.needsDisplay = true
    }
    func installRenderPlan(_ plan: DiffRenderPlan) { canvas.installRenderPlan(plan); needsLayout = true }
    public func selectLines(_ selection: LineSelection?, notify: Bool = true, activeLineSide: DiffSide? = nil, lineNumberOnly: Bool = false) {
        canvas.selectionHighlightSide = activeLineSide; canvas.selectionLineNumberOnly = lineNumberOnly
        let changed = canvas.selection != selection, revision = canvas.document?.id
        canvas.clearProposedLineSelection(); canvas.textSelection = nil; canvas.selection = selection
        if notify && changed && canvas.document?.id == revision { interactionHandlers.onLineSelected?(selection) }
    }
    /// Independent of the selected line range; numbers refer to one-based source lines.
    public func setEditorActiveLine(_ number: Int?, options: EditorActiveLineOptions = .init()) {
        canvas.activeLine = number.flatMap { $0 > 0 ? $0 : nil }; canvas.activeLineOptions = options; canvas.needsDisplay = true
    }
    public var editorActiveLine: Int? { canvas.activeLine }
    public var editorActiveLineOptions: EditorActiveLineOptions { canvas.activeLineOptions }
    public func selectText(_ selection: DiffTextSelection?) { canvas.setTextSelection(selection) }
    public func selectedText() -> String { canvas.selectedText() }
    /// Wait for the current asynchronous wrapping job, including replacement
    /// jobs scheduled while layout settles. This does not wait for tokenization.
    public func waitForLayout() async { layoutSubtreeIfNeeded(); await canvas.waitForLayout() }
    public func resetMetrics() { canvas.metrics = .init() }
    /// Attaches input to the addition side of this viewport. Retain the returned editor.
    public func beginEditing(highlighter: DiffHighlighter = DiffHighlighter(), diffOptions: DiffOptions = .init(), editStateKey: String? = nil, stateManager: EditStateManager = .shared, historyMaxEntries: Int = 100, initialState: EditorInitialState? = nil, editPrediction: EditPredictionOptions? = nil) throws -> DiffEditor {
        guard attachedEditor == nil else { throw DiffEditorError.alreadyAttached }
        guard let document = displayedDocument else { throw DiffEditorError.missingDocument }
        guard markerRows.isEmpty else { throw DiffEditorError.conflictDocument }
        let editor = try DiffEditor(view: self, document: document, options: options, annotations: annotations,
                                    diffOptions: diffOptions, expandedHunks: canvas.expandedRegions, highlighter: highlighter,
                                    editStateKey: editStateKey, stateManager: stateManager, historyMaxEntries: historyMaxEntries, initialState: initialState)
        attachedEditor = editor; canvas.editor = editor
        editor.editPrediction = editPrediction
        window?.makeFirstResponder(canvas)
        editor.activate()
        return editor
    }
    /// Reattach a suspended session to a viewport rendering the same logical source.
    public func resumeEditing(_ editor: DiffEditor) throws {
        guard attachedEditor == nil else { throw DiffEditorError.alreadyAttached }
        guard let document = displayedDocument else { throw DiffEditorError.missingDocument }
        guard markerRows.isEmpty else { throw DiffEditorError.conflictDocument }
        attachedEditor = editor; canvas.editor = editor
        do { try editor.resume(on: self, external: document, options: options, annotations: annotations) }
        catch { attachedEditor = nil; canvas.editor = nil; throw error }
    }
    func renderEditor(_ document: HighlightedDiff, options: DiffRenderOptions, annotations: [LineAnnotation], expansions: [Int: HunkExpansionRegion]) {
        renderingEditor = true
        canvas.expandedRegions = expansions
        render(document, options: options, annotations: annotations)
        renderingEditor = false
    }
    func detachEditor(_ editor: DiffEditor) {
        guard attachedEditor === editor else { return }
        attachedEditor = nil; canvas.editor = nil
    }
    func showSearch(_ session: DiffEditorSearch) {
        searchBar?.removeFromSuperview(); let bar = DiffSearchBar(session: session); searchBar = bar; addSubview(bar)
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    func hideSearch() {
        searchBar?.removeFromSuperview(); searchBar = nil; needsLayout = true; canvas.needsDisplay = true
        window?.makeFirstResponder(canvas)
    }
    func focusEditor() { window?.makeFirstResponder(canvas) }
    func blurEditor() { if window?.firstResponder === canvas { window?.makeFirstResponder(nil) } }
    func firstVisibleEditorLine(offset: CGFloat) -> Int? { canvas.firstVisibleEditorLine(offset: offset) }
    func focusSearch() { searchBar?.focusQuery() }
    func searchPresentationChanged() { canvas.needsDisplay = true }
    func updateEditorWidgets() { canvas.updateEditorWidgets() }
    func editorOverlaysChanged() { canvas.hideMarkerPopover(); canvas.updateTrackingAreas(); canvas.updateEditorWidgets(); canvas.needsDisplay = true }
    var editorCursorLayout: EditorCursorLayout { canvas.editorCursorLayout }
    var editorExpansions: [Int: HunkExpansionRegion] { canvas.expandedRegions }
    var predictionVisibleLines: Set<Int> { canvas.predictionVisibleLines }
    func setPredictionPreview(_ preview: EditorPredictionPreview?) { canvas.setPredictionPreview(preview) }
    func isPredictionVisible(_ preview: EditorPredictionPreview) -> Bool { canvas.isPredictionVisible(preview) }
    func editorClearSelection() { canvas.setTextSelection(nil) }
    func editorSelect(_ selection: DiffTextSelection) { canvas.setTextSelection(selection) }
    func editorRect(_ position: TextPosition) -> NSRect { canvas.screenRect(for: position) }
    func editorPosition(at screenPoint: NSPoint) -> TextPosition? { canvas.editorPosition(at: screenPoint) }
    func revealEditorCaret(_ position: TextPosition) { canvas.revealEditorCaret(position) }
}

@MainActor private final class DiffCanvas: NSView, TokenGeometryProviding {
    var lineNumberOffset = 0
    private func displayedLineNumber(_ number: Int) -> String {
        let sum = number.addingReportingOverflow(lineNumberOffset)
        return String(sum.overflow ? Int.max : sum.partialValue)
    }
    weak var editor: DiffEditor? { didSet {
        if oldValue !== editor { oldValue?.invalidateSelectionActionContext(); clearEditorWidgets() }
        hideMarkerPopover(); updateTrackingAreas(); needsDisplay = true
        if editor == nil { activeLine = nil }
        if oldValue !== editor { oldValue?.focusChanged(false); editor?.focusChanged(window?.firstResponder === self) }
    } }
    var activeLine: Int?
    private struct CaretWidget { var view: NSView? }
    private var caretWidgets: [Int: CaretWidget] = [:]
    private var caretWidgetRevision: UUID?
    private var selectionActionHost: EditorSelectionActionHost?
    private var selectionActionContext: SelectionActionContext?
    private var selectionPlacement = EditorPopoverPlacement()
    private var updatingEditorWidgets = false
    private func clearSelectionAction() {
        let host = selectionActionHost
        selectionActionHost = nil; selectionActionContext = nil; selectionPlacement = .init()
        editor?.invalidateSelectionActionContext()
        host?.onResize = nil; host?.removeFromSuperview()
    }
    private func clearEditorWidgets() {
        let old = caretWidgets; caretWidgets = [:]; caretWidgetRevision = nil
        clearSelectionAction()
        for entry in old.values { entry.view?.removeFromSuperview() }
    }
    func updateEditorWidgets() {
        guard !updatingEditorWidgets else { return }
        updatingEditorWidgets = true
        defer { updatingEditorWidgets = false }
        guard let editor, editor.isActive, !options.collapsed, plan != nil else { clearEditorWidgets(); return }
        let revision = separatorRevision, caretRevision = editor.caretRevision, inputIdentity = editor.document.historyIdentity
        let renderer = editor.caretRenderer
        func current() -> Bool { self.editor === editor && editor.isActive && editor.document.historyIdentity == inputIdentity && separatorRevision == revision && editor.caretRevision == caretRevision && editor.caretRenderer === renderer }
        if caretWidgetRevision != caretRevision {
            let old = caretWidgets; caretWidgets = [:]; caretWidgetRevision = caretRevision
            for entry in old.values { entry.view?.removeFromSuperview() }
            guard current() else { return }
        }
        if !editor.enabledSelectionAction || editor.selectionActionRenderer == nil || editor.selectionActionDragging || editor.hasMarkedText()
            || editor.getSelections().last?.isCollapsed != false { clearSelectionAction() }
        // Geometry from a previous document version must not anchor host views.
        guard editor.predictionPresentationIsCurrent else {
            for entry in caretWidgets.values { entry.view?.isHidden = true }
            selectionActionHost?.isHidden = true
            return
        }
        let visible = visibleRect
        var visibleCarets = Set<Int>()
        if let renderer {
            for line in predictionVisibleLines {
                for index in editor.caretIndices(on: line) where editor.carets[index].focus.line == line {
                    let caret = editor.carets[index]
                    guard let rect = editorLocalRect(caret.focus), rect.maxY > visible.minY, rect.minY < visible.maxY,
                          rect.minX >= visible.minX + (options.diffStyle == .split ? columnWidth : 0) + gutter, rect.minX < visible.maxX else { continue }
                    visibleCarets.insert(index)
                    if caretWidgets[index] == nil {
                        let view = renderer.render(caret)
                        guard current() else { return }
                        caretWidgets[index] = .init(view: view)
                        if let view { addSubview(view) }
                        guard current() else { return }
                    }
                    if let view = caretWidgets[index]?.view {
                        let size = view.fittingSize
                        view.setFrameOrigin(rect.origin)
                        if size.width > 0 && size.height > 0 { view.setFrameSize(size) }
                        view.isHidden = false
                    }
                    guard current() else { return }
                }
            }
        }
        for index in Array(caretWidgets.keys) where !visibleCarets.contains(index) {
            let entry = caretWidgets.removeValue(forKey: index); entry?.view?.removeFromSuperview()
            guard current() else { return }
        }
        guard editor.enabledSelectionAction, let actionRenderer = editor.selectionActionRenderer,
              !editor.selectionActionDragging, !editor.hasMarkedText(), let selection = editor.getSelections().last, !selection.isCollapsed,
              let head = editorLocalRect(selection.focus), head.maxY > visible.minY, head.minY < visible.maxY else {
            clearSelectionAction(); return
        }
        if selectionActionContext?.id != editor.selectionActionID { clearSelectionAction() }
        if selectionActionHost == nil {
            guard editor.selectionActionMayMount else { return }
            let context = editor.makeSelectionActionContext()
            let content = actionRenderer.render(context)
            guard current(), context.isActive, editor.selectionActionRenderer === actionRenderer, editor.getSelections().last == selection else {
                if editor.selectionActionID == context.id { editor.invalidateSelectionActionContext() }
                return
            }
            guard let content else { editor.closeSelectionAction(); return }
            let host = EditorSelectionActionHost(content: content)
            guard current(), context.isActive else { return }
            selectionActionHost = host; selectionActionContext = context
            host.onResize = { [weak self] in self?.updateEditorWidgets() }
            addSubview(host)
        }
        guard current(), let host = selectionActionHost, selectionActionContext?.isActive == true else { return }
        let minX = visible.minX + (options.diffStyle == .split ? columnWidth : 0) + gutter + 8
        let maxWidth = min(640, visible.maxX - minX - 8)
        guard maxWidth > 0, visible.height > 8 else { host.isHidden = true; return }
        let size = host.measure(maxWidth: maxWidth, maxHeight: visible.height - 8)
        guard current(), selectionActionHost === host, selectionActionContext?.isActive == true else { return }
        let backward = selection.direction == .backward
        func candidate(_ rect: CGRect, above: Bool) -> CGRect {
            .init(x: rect.minX, y: above ? rect.minY - size.height : rect.maxY, width: size.width, height: size.height)
        }
        let tail = editorLocalRect(selection.anchor).flatMap { $0.maxY > visible.minY && $0.minY < visible.maxY ? $0 : nil }
        var frame = selectionPlacement.choose(preferred: candidate(head, above: backward), fallback: tail.map { candidate($0, above: !backward) }, viewport: visible)
        frame.origin.x = max(minX, min(frame.minX, visible.maxX - 8 - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - 8 - frame.height))
        host.frame = frame
        host.layer?.backgroundColor = NSColor.diffLabMix(background, foreground, fraction: 0.04).cgColor
        host.layer?.borderColor = foreground.withAlphaComponent(0.2).cgColor
        host.isHidden = false
    }
    var activeLineOptions = EditorActiveLineOptions()
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { editor?.focusChanged(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { editor?.unmarkText(); editor?.focusChanged(false) }
        return accepted
    }
    func firstVisibleEditorLine(offset: CGFloat) -> Int? {
        guard let rows = plan?.rows else { return nil }
        let offset = offset.isFinite ? max(0, offset) : 0
        let top = visibleRect.minY + offset
        for index in visibleRows(y: top, height: max(0, visibleRect.maxY - top)) {
            let row = rows[index]
            if rowOrigin(index) >= top, let number = row.newNumber { return number }
        }
        return nil
    }
    override var undoManager: UndoManager? { editor?.undoManager ?? super.undoManager }
    override var inputContext: NSTextInputContext? { editor?.textInputContext ?? super.inputContext }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var document: HighlightedDiff? { didSet { cachedAccessibleSource = nil; clearSeparatorViews(); clearConflictActionViews() } }
    private var cachedAccessibleSource: (side: DiffSide, text: NSString)?
    var options = DiffRenderOptions()
    var plan: DiffRenderPlan? { didSet {
        separatorRevision = UUID()
        conflictActionRevision = UUID()
        cachedEditorCursorLayout = nil
        predictionRows = nil; predictionLayoutKey = nil; predictionSpacers = [:]; predictionPreview?.rendered = false
        rowHeights = .init(rows: plan?.rows ?? [], options: options)
        hasDecorationControls = plan?.rows.contains { row in
            switch row.kind {
            case .separator: return options.hunkSeparators == .lineInfo || options.hunkSeparators == .lineInfoBasic
            case .conflictMarker(_, .start): return options.mergeConflictActionsType == .default
            default: return false
            }
        } ?? false
        hoveredDecoration = nil
        updateTrackingAreas()
    } }
    var rowHeights = RowHeightIndex(rowCount: 0, lineHeight: 20) {
        didSet { if !predictionSpacers.isEmpty { rowHeights.setSupplementalHeights(predictionSpacers) } }
    }
    func resetAnnotationHeights() {
        rowHeights = .init(rows: plan?.rows ?? [], options: options)
        updateSize(viewport: enclosingScrollView?.contentSize ?? .zero)
        needsDisplay = true; onLayoutChange?()
    }
    func rowOrigin(_ row: Int) -> CGFloat { rowHeights.origin(of: row) }
    func visibleRows(y: CGFloat, height: CGFloat) -> Range<Int> {
        guard rowHeights.rowCount > 0, y.isFinite, height.isFinite, height > 0,
              y < rowHeights.totalHeight, y + height > 0 else { return 0..<0 }
        let start = rowHeights.row(at: max(0, y))
        let end = rowHeights.row(at: min(rowHeights.totalHeight, y + height).nextDown) + 1
        return start..<max(start, end)
    }
    private var predictionPreview: EditorPredictionPreview?
    private var predictionContentWidth: CGFloat = 0
    private var predictionLayoutKey: String?
    private var predictionLayouts: [PredictionLayout] = []
    private var predictionSpacers: [Int: CGFloat] = [:]
    private var predictionRows: [Int: [Int]]?
    private var predictionLineCache: [String: CTLine] = [:]
    private struct PredictionFragment { var range: NSRange; var x: CGFloat }
    private struct PredictionLayout {
        var group: EditPredictionGroup
        var anchorRow: Int
        var spacerRow: Int
        var fragments: [PredictionFragment]
        var text: NSAttributedString
        var typesetter: CTTypesetter
        var ascii: Bool
    }
    var predictionVisibleLines: Set<Int> {
        guard let rows = plan?.rows else { return [] }
        return Set(visibleRows(y: visibleRect.minY, height: visibleRect.height).compactMap { index in
            let row = rows[index]
            guard row.newIndex != nil || row.kind == .editorCaret,
                  rowOrigin(index) + options.lineHeight > visibleRect.minY else { return nil }
            return row.newNumber.map { $0 - 1 }
        })
    }
    func setPredictionPreview(_ preview: EditorPredictionPreview?) {
        guard predictionPreview !== preview else { return }
        predictionPreview?.rendered = false; predictionPreview = preview
        predictionLayoutKey = nil; predictionLayouts = []; predictionLineCache = [:]
        if preview == nil {
            let widthChanged = predictionContentWidth != 0; predictionContentWidth = 0
            installPredictionSpacers([:])
            if widthChanged { updateSize(viewport: enclosingScrollView?.contentSize ?? .zero); onLayoutChange?() }
        }
        else { refreshPredictionLayout() }
        needsDisplay = true
    }
    func isPredictionVisible(_ preview: EditorPredictionPreview) -> Bool {
        guard predictionPreview === preview, predictionLayouts.count == preview.groups.count, let rows = predictionRows else { return false }
        for layout in predictionLayouts {
            let range = layout.group.edit.range
            for line in range.start.line...range.end.line {
                guard let indexes = rows[line], indexes.contains(where: {
                    let y = rowOrigin($0)
                    return y < visibleRect.maxY && y + options.lineHeight > visibleRect.minY
                }) else { return false }
            }
            let y = rowOrigin(layout.anchorRow)
            guard y < visibleRect.maxY && y + options.lineHeight > visibleRect.minY else { return false }
        }
        return true
    }
    private func installPredictionSpacers(_ spacers: [Int: CGFloat]) {
        guard predictionSpacers != spacers else { return }
        predictionSpacers = spacers; rowHeights.setSupplementalHeights(spacers)
        updateSize(viewport: enclosingScrollView?.contentSize ?? .zero)
        needsDisplay = true; onLayoutChange?()
    }
    private func refreshPredictionLayout() {
        guard let preview = predictionPreview, let plan, let document, let editor, options.lineHeight.isFinite, options.lineHeight > 0 else { return }
        let width = max(1, columnWidth - gutter - 12)
        let key = "\(preview.id):\(separatorRevision):\(width):\(font.fontName):\(font.pointSize):\(options.lineHeight):\(options.overflow)"
        guard predictionLayoutKey != key else { return }
        predictionLayoutKey = key; predictionLayouts = []; predictionLineCache = [:]; preview.rendered = false
        ensureEditorRowIndex()
        var layouts: [PredictionLayout] = [], spacers: [Int: CGFloat] = [:]
        for group in preview.groups {
            let edit = group.edit, start = edit.range.start
            guard (start.line...edit.range.end.line).allSatisfy({ predictionRows?[$0] != nil }),
                  let sourceRows = predictionRows?[start.line], let lastRow = sourceRows.last,
                  let anchorRow = sourceRows.first(where: { index in
                      guard let range = plan.rows[index].newRange else { return true }
                      return start.character >= range.location && (start.character < NSMaxRange(range) || index == lastRow && start.character == NSMaxRange(range))
                  }) else { installPredictionSpacers([:]); return }
            let anchor = plan.rows[anchorRow], base = anchor.newRange?.location ?? 0
            let prefix = editor.document.getTextSlice(start: editor.document.offsetAt(.init(line: start.line, character: base)), end: editor.document.offsetAt(start))
            let prefixLine = CTLineCreateWithAttributedString(NSAttributedString(string: prefix, attributes: [.font: font]))
            let anchorX = CGFloat(CTLineGetTypographicBounds(prefixLine, nil, nil, nil))
            let text = NSMutableAttributedString(string: edit.newText, attributes: [.font: font, .foregroundColor: foreground.withAlphaComponent(0.45)])
            if let suffix = group.insertionSuffix, let position = group.suffixStart {
                let suffixBase = text.length
                text.append(NSAttributedString(string: suffix, attributes: [.font: font, .foregroundColor: foreground]))
                // Preserve the source tokens when a mid-line insertion moves its suffix.
                if let sourceIndex = anchor.newIndex, document.newTokens.indices.contains(sourceIndex) {
                    var tokenOffset = 0
                    for token in document.newTokens[sourceIndex] {
                        let range = NSRange(location: tokenOffset, length: token.content.utf16.count); tokenOffset += range.length
                        let overlap = NSIntersectionRange(range, NSRange(location: position.character, length: (suffix as NSString).length))
                        if overlap.length > 0 {
                            let target = NSRange(location: suffixBase + overlap.location - position.character, length: overlap.length)
                            if let color = token.color, !color.isEmpty { text.addAttribute(.foregroundColor, value: NSColor.diffHex(color), range: target) }
                            if let color = token.bgColor, !color.isEmpty { text.addAttribute(.backgroundColor, value: NSColor.diffHex(color), range: target) }
                            if let style = token.fontStyle, style != .notSet {
                                var styled = font
                                if style.contains(.bold) { styled = NSFontManager.shared.convert(styled, toHaveTrait: .boldFontMask) }
                                if style.contains(.italic) { styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask) }
                                text.addAttribute(.font, value: styled, range: target)
                                if style.contains(.underline) { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: target) }
                                if style.contains(.strikethrough) { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: target) }
                            }
                        }
                    }
                }
            }
            let typesetter = CTTypesetterCreateWithAttributedString(text), units = Array(text.string.utf16)
            var fragments: [PredictionFragment] = [], offset = 0, first = true
            if !edit.newText.isEmpty {
                while offset <= units.count {
                    var end = offset
                    while end < units.count && units[end] != 10 && units[end] != 13 { end += 1 }
                    var cursor = offset
                    repeat {
                        let x = first ? anchorX : 0
                        let remaining = end - cursor
                        var count = remaining
                        if options.overflow == .wrap && remaining > 0 {
                            let available = Double(max(1, width - x))
                            count = CTTypesetterSuggestLineBreak(typesetter, cursor, available)
                            if count <= 0 { count = CTTypesetterSuggestClusterBreak(typesetter, cursor, available) }
                            count = min(remaining, max(1, count))
                        }
                        fragments.append(.init(range: .init(location: cursor, length: count), x: x))
                        cursor += count; first = false
                    } while cursor < end
                    if end == units.count { break }
                    offset = end + (units[end] == 13 && end + 1 < units.count && units[end + 1] == 10 ? 2 : 1)
                }
                let availableRows = sourceRows.filter { $0 >= anchorRow }.count
                let extra = max(0, fragments.count - availableRows)
                if extra > 0 { spacers[lastRow] = max(spacers[lastRow] ?? 0, CGFloat(extra) * options.lineHeight) }
            }
            layouts.append(.init(group: group, anchorRow: anchorRow, spacerRow: lastRow, fragments: fragments,
                                 text: text, typesetter: typesetter, ascii: units.allSatisfy { $0 >= 32 && $0 < 127 || $0 == 10 || $0 == 13 }))
        }
        var contentWidth: CGFloat = 0
        if options.overflow != .wrap {
            for layout in layouts {
                for fragment in layout.fragments {
                    let width = layout.ascii && font.isFixedPitch ? CGFloat(fragment.range.length) * monospaceAdvance
                        : CGFloat(CTLineGetTypographicBounds(CTTypesetterCreateLine(layout.typesetter, CFRange(location: fragment.range.location, length: fragment.range.length)), nil, nil, nil))
                    contentWidth = max(contentWidth, fragment.x + width)
                }
            }
        }
        let widthChanged = contentWidth != predictionContentWidth; predictionContentWidth = contentWidth
        predictionLayouts = layouts; installPredictionSpacers(spacers)
        if widthChanged { updateSize(viewport: enclosingScrollView?.contentSize ?? .zero); onLayoutChange?() }
    }
    private func drawPredictionPreviews() {
        guard let preview = predictionPreview, let editor, let plan, let context = NSGraphicsContext.current?.cgContext else { return }
        preview.rendered = false
        guard isPredictionVisible(preview) else { return }
        let columnX = visibleRect.minX + (options.diffStyle == .split ? columnWidth : 0)
        let textX = columnX + gutter - visibleRect.minX / (options.diffStyle == .split ? 2 : 1)
        let clip = NSRect(x: columnX + gutter, y: visibleRect.minY, width: max(0, columnWidth - gutter), height: visibleRect.height)
        NSGraphicsContext.saveGraphicsState(); clip.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (groupIndex, layout) in predictionLayouts.enumerated() {
            let edit = layout.group.edit, deletion = edit.newText.isEmpty
            let maskEnd = layout.group.insertionSuffix != nil
                ? TextPosition(line: edit.range.start.line, character: (try? editor.document.getLineLength(edit.range.start.line)) ?? 0) : edit.range.end
            for lineNumber in edit.range.start.line...maskEnd.line {
                for index in predictionRows?[lineNumber] ?? [] {
                    let row = plan.rows[index], y = rowOrigin(index)
                    guard y < visibleRect.maxY && y + options.lineHeight > visibleRect.minY else { continue }
                    let length = (try? editor.document.getLineLength(lineNumber)) ?? 0
                    let fragment = row.newRange ?? .init(location: 0, length: length)
                    let from = max(fragment.location, lineNumber == edit.range.start.line ? edit.range.start.character : 0)
                    let to = min(NSMaxRange(fragment), lineNumber == maskEnd.line ? maskEnd.character : length)
                    guard to >= from else { continue }
                    let source = editor.document.getLineText(lineNumber) as NSString
                    let ct = CTLineCreateWithAttributedString(NSAttributedString(string: source.substring(with: fragment), attributes: [.font: font]))
                    let a = CTLineGetOffsetForStringIndex(ct, from - fragment.location, nil), b = CTLineGetOffsetForStringIndex(ct, to - fragment.location, nil)
                    if deletion {
                        deleted.withAlphaComponent(0.7).setFill()
                        NSRect(x: textX + min(a, b), y: y + options.lineHeight / 2 - 0.5, width: abs(b - a), height: 1).fill()
                    } else {
                        background.setFill()
                        NSRect(x: textX + min(a, b), y: y, width: max(0, abs(b - a)), height: options.lineHeight).fill()
                    }
                }
            }
            let top = rowOrigin(layout.anchorRow)
            let first = min(layout.fragments.count, max(0, Int(floor((visibleRect.minY - top) / options.lineHeight))))
            let last = min(layout.fragments.count, max(first, Int(ceil((visibleRect.maxY - top) / options.lineHeight))))
            for index in first..<last {
                let fragment = layout.fragments[index], y = top + CGFloat(index) * options.lineHeight
                var range = fragment.range, x = textX + fragment.x
                if options.overflow != .wrap && layout.ascii && font.isFixedPitch && range.length > 2048 {
                    let skip = min(range.length, max(0, Int(floor((clip.minX - x) / monospaceAdvance)) - 2))
                    range.location += skip; range.length = min(range.length - skip, max(1, Int(ceil(clip.width / monospaceAdvance)) + 4)); x += CGFloat(skip) * monospaceAdvance
                }
                let key = "\(groupIndex):\(range.location):\(range.length)"
                let line: CTLine
                if let cached = predictionLineCache[key] { line = cached }
                else {
                    line = range.length > 0 ? CTTypesetterCreateLine(layout.typesetter, CFRange(location: range.location, length: range.length))
                        : CTLineCreateWithAttributedString(NSAttributedString(string: "↵", attributes: [.font: font, .foregroundColor: foreground.withAlphaComponent(0.45)]))
                    if predictionLineCache.count >= 512 { predictionLineCache.removeAll(keepingCapacity: true) }
                    predictionLineCache[key] = line
                }
                background.setFill()
                NSRect(x: x, y: y, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), height: options.lineHeight).fill()
                // CTLineDraw paints glyphs and underlines, but not AppKit's
                // token backgrounds or strikes. Preserve those on moved source
                // suffixes, including wrapped and horizontally cropped runs.
                var strikes: [(NSRect, NSColor)] = []
                if range.length > 0 {
                    layout.text.enumerateAttributes(in: range) { attributes, tokenRange, _ in
                        let hasStrike = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
                        guard attributes[.backgroundColor] != nil || hasStrike else { return }
                        let a = CTLineGetOffsetForStringIndex(line, tokenRange.location, nil)
                        let b = CTLineGetOffsetForStringIndex(line, NSMaxRange(tokenRange), nil)
                        let rect = NSRect(x: x + min(a, b), y: y, width: abs(b - a), height: options.lineHeight)
                        if let color = attributes[.backgroundColor] as? NSColor { color.setFill(); rect.fill() }
                        if hasStrike {
                            strikes.append((.init(x: rect.minX, y: y + options.lineHeight / 2, width: rect.width, height: 1),
                                            attributes[.foregroundColor] as? NSColor ?? foreground))
                        }
                    }
                }
                context.saveGState(); context.translateBy(x: x, y: y + (options.lineHeight - font.ascender + font.descender) / 2 + font.ascender)
                context.scaleBy(x: 1, y: -1); context.textMatrix = .identity; context.textPosition = .zero; CTLineDraw(line, context); context.restoreGState()
                for (rect, color) in strikes { color.setFill(); rect.fill() }
            }
        }
        if let selection = editor.getSelections().last, selection.isCollapsed, let indexes = predictionRows?[selection.focus.line] {
            let position = selection.focus
            if let index = indexes.first(where: { i in
                guard let range = plan.rows[i].newRange else { return true }
                return position.character >= range.location && (position.character < NSMaxRange(range) || i == indexes.last && position.character == NSMaxRange(range))
            }) {
                let base = plan.rows[index].newRange?.location ?? 0
                let prefix = editor.document.getTextSlice(start: editor.document.offsetAt(.init(line: position.line, character: base)), end: editor.document.offsetAt(position))
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: prefix, attributes: [.font: font]))
                foreground.setFill(); NSRect(x: textX + CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), y: rowOrigin(index) + 2, width: 1, height: options.lineHeight - 4).fill()
            }
        }
        preview.rendered = true
    }

    private var cachedEditorCursorLayout: EditorCursorLayout?
    var editorCursorLayout: EditorCursorLayout {
        if let cachedEditorCursorLayout { return cachedEditorCursorLayout }
        var lines: Set<Int> = [], offsets: [Int: Set<Int>] = [:]
        for row in plan?.rows ?? [] {
            guard let number = row.newNumber, row.newIndex != nil || row.kind == .editorCaret else { continue }
            let line = number - 1
            lines.insert(line)
            if let range = row.newRange {
                offsets[line, default: []].insert(range.location)
                offsets[line, default: []].insert(NSMaxRange(range))
            }
        }
        let result = EditorCursorLayout(softLineOffsets: options.overflow == .wrap ? offsets.mapValues { $0.sorted() } : nil,
                                        renderableLines: Array(lines))
        cachedEditorCursorLayout = result
        return result
    }
    var annotations: [LineAnnotation] = []
    /// Ghost text after the end of a line, keyed by 1-based line number.
    var trailingText: [Int: LineTrailingText] = [:] {
        didSet {
            guard oldValue != trailingText else { return }
            // Ghost text past the end of the longest line has to be scrollable to.
            updateSize(viewport: enclosingScrollView?.contentSize ?? .zero)
            needsDisplay = true
            onLayoutChange?()
        }
    }
    /// Characters needed to show the widest line together with its ghost text, which follows the line after a gap.
    private var trailingTextCharacters: Int {
        guard let lines = document?.diff.additionLines else { return 0 }
        return trailingText.values.compactMap { ghost -> Int? in
            guard lines.indices.contains(ghost.lineNumber - 1) else { return nil }
            return cleanLastNewline(lines[ghost.lineNumber - 1]).utf16.count + 4 + ghost.text.count
        }.max() ?? 0
    }
    var markerRows: [MergeConflictMarkerRow] = []
    var canLoadPartial = false { didSet { if canLoadPartial != oldValue { refreshExpansionLayout() } } }
    var expanded: Set<Int> = []
    var expandedRegions: [Int: HunkExpansionRegion] = [:]
    var onExpand: ((Int, Int, ExpansionDirection) -> Void)?
    var onLayoutChange: (() -> Void)?
    private var wrapTask: Task<Void, Never>?
    private var wrapKey: String?
    private var externalLayout = false
    var onSelectionChange: ((LineSelection?) -> Void)?
    var selection: LineSelection? { didSet { updateGutterUtility(); needsDisplay = true; onSelectionChange?(selection); editor?.canvasSelectionChanged(textSelection, lines: selection, preservingSecondary: preservingMultipleDrag) } }
    private var preservingMultipleDrag = false
    var textSelection: DiffTextSelection?
    var interactionHandlers = DiffInteractionHandlers() { didSet {
        if !interactionHandlers.enableLineSelection && !interactionHandlers.enableGutterUtility && editor == nil { dragAnchor = nil; lineSelectionSession = false; pendingLineUnselect = false; clearProposedLineSelection() }
        if oldValue.enableGutterUtility != interactionHandlers.enableGutterUtility {
            if renderGutterUtility == nil { reloadGutterUtility() } else { updateGutterUtility() }
        }
        updateTrackingAreas(); needsDisplay = true
    } }
    var renderGutterUtility: DiffGutterUtilityRenderer? { didSet { reloadGutterUtility() } }
    private var gutterUtility: NSView?
    private var gutterRevision = UUID()
    private(set) var gutterTarget: DiffHoveredLine?
    var hoveredSourceLine: DiffHoveredLine? {
        hoveredLine.map { .init(lineNumber: $0.lineNumber, side: $0.side) }
    }
    private func reloadGutterUtility() {
        let revision = UUID(); gutterRevision = revision
        gutterUtility?.removeFromSuperview(); gutterUtility = nil; gutterTarget = nil
        let view: NSView?
        if let renderGutterUtility {
            view = renderGutterUtility({ [weak self] in
                guard let self, self.gutterRevision == revision else { return nil }
                return self.gutterTarget ?? self.hoveredSourceLine
            })
        } else if interactionHandlers.enableGutterUtility {
            view = DiffGutterButton(owner: self)
        } else { view = nil }
        guard gutterRevision == revision else { return }
        gutterUtility = view
        if let view { view.isHidden = true; addSubview(view) }
        updateTrackingAreas(); updateGutterUtility()
    }
    private func updateGutterUtility() {
        gutterTarget = nil
        guard let utility = gutterUtility else { return }
        utility.isHidden = true
        guard interactionHandlers.enableGutterUtility, !options.disableLineNumbers, let document, let plan else { return }
        if let button = utility as? DiffGutterButton {
            button.size = options.lineHeight
            button.fillColor = .diffHex(document.palette.modified)
            button.symbolColor = .diffHex(document.background)
            button.needsDisplay = true
        }
        var target = hoveredSourceLine
        if let selection = gestureSelection,
           let start = document.diff.selectionLineIndex(selection.startLine, side: selection.side),
           let end = document.diff.selectionLineIndex(selection.endLine, side: selection.endSide ?? selection.side) {
            let startIndex = options.diffStyle == .split ? start.split : start.unified
            let endIndex = options.diffStyle == .split ? end.split : end.unified
            target = startIndex > endIndex
                ? .init(lineNumber: selection.startLine, side: selection.side)
                : .init(lineNumber: selection.endLine, side: selection.endSide ?? selection.side)
        }
        guard let target else { return }
        // Only search mounted physical rows, never the whole source document.
        let visible = visibleRect
        for index in visibleRows(y: visible.minY, height: visible.height) {
            guard plan.rows.indices.contains(index) else { continue }
            let row = plan.rows[index]
            guard !row.isContinuation, row.kind == .context || row.kind == .change,
                  (target.side == .deletions ? row.oldNumber : row.newNumber) == target.lineNumber else { continue }
            let intrinsic = utility.intrinsicContentSize
            let width = min(gutter, max(1, intrinsic.width > 0 ? intrinsic.width : utility.frame.width > 0 ? utility.frame.width : options.lineHeight))
            let height = min(options.lineHeight, max(1, intrinsic.height > 0 ? intrinsic.height : utility.frame.height > 0 ? utility.frame.height : options.lineHeight))
            let x = visible.minX + (options.diffStyle == .split && target.side == .additions ? columnWidth : 0)
            utility.frame = .init(x: x + gutter - (utility is DiffGutterButton ? monospaceAdvance : width), y: rowOrigin(index) + (options.lineHeight - height) / 2, width: width, height: height)
            gutterTarget = target; utility.isHidden = false
            return
        }
    }
    private var gutterGestureRevision: UUID?
    fileprivate func beginGutterSelection() {
        guard interactionHandlers.enableGutterUtility, renderGutterUtility == nil,
              interactionHandlers.onGutterUtilityClick != nil, let target = gutterTarget,
              let diff = document?.diff else { return }
        pendingClick = nil; pendingLineUnselect = false; textDrag = false
        clearProposedLineSelection(); textSelection = nil
        var top = target, bottom = target
        if let selection, let a = diff.selectionLineIndex(selection.startLine, side: selection.side),
           let b = diff.selectionLineIndex(selection.endLine, side: selection.endSide ?? selection.side) {
            let start = DiffHoveredLine(lineNumber: selection.startLine, side: selection.side)
            let end = DiffHoveredLine(lineNumber: selection.endLine, side: selection.endSide ?? selection.side)
            let forward = options.diffStyle == .split ? a.split <= b.split : a.unified <= b.unified
            top = forward ? start : end; bottom = forward ? end : start
        }
        gutterGestureRevision = document?.id
        lineSelectionSession = true; dragAnchor = top.lineNumber; dragSide = top.side
        setGestureSelection(.init(side: top.side, startLine: top.lineNumber, endLine: bottom.lineNumber, endSide: top.side == bottom.side ? nil : bottom.side))
        guard gutterGestureRevision == document?.id else { return }
        interactionHandlers.onLineSelectionStart?(gestureSelection)
    }
    fileprivate func dragGutterSelection(with event: NSEvent) {
        guard interactionHandlers.enableGutterUtility, let revision = gutterGestureRevision, revision == document?.id else { return }
        mouseDragged(with: event)
    }
    fileprivate func finishGutterSelection(with event: NSEvent? = nil) {
        guard interactionHandlers.enableGutterUtility, let revision = gutterGestureRevision, revision == document?.id else { gutterGestureRevision = nil; return }
        if let event { mouseDragged(with: event) }
        guard revision == document?.id, let completed = gestureSelection else { return }
        gutterGestureRevision = nil; lineSelectionSession = false; dragAnchor = nil
        defer { clearProposedLineSelection(); updateGutterUtility() }
        interactionHandlers.onGutterUtilityClick?(completed)
        guard revision == document?.id else { return }
        interactionHandlers.onLineSelectionEnd?(completed)
        guard revision == document?.id else { return }
        interactionHandlers.onLineSelected?(completed)
    }
    private enum DecorationHover: Equatable {
        case expansion(Int, HunkExpansionAction)
        case conflict(Int, DiffResolution)
    }
    private var hasDecorationControls = false
    private var hoveredDecoration: DecorationHover?
    private var lineTrackingArea: NSTrackingArea?
    private var hoveredToken: DiffTokenHoverState?
    private var hoveredLine: DiffHoverState?
    private var lastPointerEvent: NSEvent?
    private var refreshingHover = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !interactionHandlers.hasHoverHandlers { hoveredLine = nil; hoveredToken = nil }
        guard interactionHandlers.hasHoverHandlers || hasDecorationControls || editor?.markers.isEmpty == false else {
            hoveredDecoration = nil
            if let lineTrackingArea { removeTrackingArea(lineTrackingArea); self.lineTrackingArea = nil }
            hoveredLine = nil; hoveredToken = nil; lastPointerEvent = nil; return
        }
        guard lineTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        lineTrackingArea = area; addTrackingArea(area)
    }
    func receiveHover(_ event: NSEvent) { lastPointerEvent = event; updateHover(event) }
    override func mouseMoved(with event: NSEvent) { receiveHover(event) }
    override func mouseEntered(with event: NSEvent) { lastPointerEvent = event; updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        if markerPopover == nil { hideMarkerPopover() }
        lastPointerEvent = nil; hoveredDecoration = nil
        defer { updateGutterUtility() }
        let previousToken = hoveredToken; hoveredToken = nil
        let previous = hoveredLine; hoveredLine = nil
        needsDisplay = true
        if let previousToken { interactionHandlers.onTokenLeave?(previousToken.payload(view: self, event: event)) }
        if let previous { interactionHandlers.onLineLeave?(previous.payload(view: self, event: event)) }
    }
    func refreshHoverAfterViewportChange() {
        if markerPopover != nil { hideMarkerPopover() }
        defer { updateGutterUtility() }
        guard !refreshingHover, let lastPointerEvent else { return }
        refreshingHover = true; defer { refreshingHover = false }
        updateHover(lastPointerEvent)
    }
    private func updateDecorationHover(_ event: NSEvent) {
        var next: DecorationHover?
        let point = convert(event.locationInWindow, from: nil)
        if hasDecorationControls, visibleRect.contains(point), let plan, point.y >= 0, point.y < rowHeights.totalHeight {
            let index = rowHeights.row(at: point.y)
            if plan.rows.indices.contains(index) {
                let row = plan.rows[index], y = rowOrigin(index)
                if case .conflictMarker(_, .start) = row.kind {
                    if let control = conflictControls(y: y).first(where: { $0.2.contains(point) }) { next = .conflict(index, control.1) }
                } else if case .separator = row.kind {
                    if let control = separatorControls(row, y: y).first(where: { $0.1.contains(point) }) { next = .expansion(index, control.0) }
                }
            }
        }
        if hoveredDecoration != next { hoveredDecoration = next; needsDisplay = true }
    }
    private func updateHover(_ event: NSEvent) {
        updateDecorationHover(event)
        updateMarkerHover(event)
        defer { updateGutterUtility() }
        guard interactionHandlers.hasHoverHandlers else { return }
        let revision = document?.id
        let hit = clickEvent(event)
        let token = (interactionHandlers.onTokenEnter != nil || interactionHandlers.onTokenLeave != nil) ? hit.flatMap { $0.numberColumn ? nil : tokenEvent(event, line: $0) } : nil
        if hoveredToken?.matches(token, revision: revision) != true {
            let previousToken = hoveredToken
            hoveredToken = token.map { DiffTokenHoverState($0, revision: revision) }
            if let previousToken { interactionHandlers.onTokenLeave?(previousToken.payload(view: self, event: event)) }
            if let token, document?.id == revision, hoveredToken?.matches(token, revision: revision) == true {
                interactionHandlers.onTokenEnter?(token)
            }
        }
        guard document?.id == revision else { return }
        if let hit, let previous = hoveredLine, previous.lineNumber == hit.lineNumber,
           previous.side == hit.annotationSide, previous.sourceID == document?.sourceID { return }
        let previous = hoveredLine
        hoveredLine = hit.map { DiffHoverState($0, sourceID: document?.sourceID) }
        needsDisplay = true
        if let previous { interactionHandlers.onLineLeave?(previous.payload(view: self, event: event)) }
        if let hit, document?.id == revision, hoveredLine?.lineNumber == hit.lineNumber,
           hoveredLine?.side == hit.annotationSide { interactionHandlers.onLineEnter?(hit) }
    }
    private var oversizedTokenIndex: (key: String, index: TokenInteractionIndex)?
    private var pointerSource: (key: String, text: NSString)?
    private var tokenIndices: [String: TokenInteractionIndex] = [:]
    private var tokenIndexOrder: [String] = []
    private var tokenIndexUnits = 0
    private var pendingClick: (line: Int, side: DiffSide, numberColumn: Bool, sourceID: UUID?)?
    private var proposedLineSelection: LineSelection?
    private var hasProposedLineSelection = false
    private var gestureSelection: LineSelection? { hasProposedLineSelection ? proposedLineSelection : selection }
    private func setGestureSelection(_ value: LineSelection?) {
        if gestureSelection != value { selectionHighlightSide = nil; selectionLineNumberOnly = false }
        if lineSelectionSession && interactionHandlers.controlledSelection {
            hasProposedLineSelection = true; proposedLineSelection = value
        } else { selection = value }
    }
    func clearProposedLineSelection() { hasProposedLineSelection = false; proposedLineSelection = nil }
    private var lineSelectionSession = false
    private var pendingLineUnselect = false
    private var textDrag = false
    var metrics = DiffViewportMetrics()
    private var dragAnchor: Int?
    private var dragSide: DiffSide = .additions
    private var tokenGeometryCache: [String: TokenLineGeometry] = [:]
    private var cache: [String: (CTLine, Int)] = [:]
    private var cacheOrder: [String] = []
    private var cacheUnits = 0
    private var maxCharacters = 0
    private var oldLongASCII: [Int: Int] = [:]
    private var newLongASCII: [Int: Int] = [:]
    private var additionBackground = NSColor.clear
    private var deletionBackground = NSColor.clear
    private var additionGutter = NSColor.clear
    private var deletionGutter = NSColor.clear
    private var separatorBackground = NSColor.clear
    private var emptyPattern = NSColor.clear
    private var viewportWidth: CGFloat = 800
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var foreground: NSColor { NSColor.diffHex(document?.foreground ?? "#c9d1d9") }
    private var background: NSColor { NSColor.diffHex(document?.background ?? "#0d1117") }
    private var numberGutter: CGFloat { options.disableLineNumbers ? 16 : 60 }
    private var gutter: CGFloat { numberGutter + (options.diffIndicators == .classic ? 2 * monospaceAdvance : 0) }
    private var columnWidth: CGFloat { options.diffStyle == .split ? viewportWidth / 2 : viewportWidth }
    private var added: NSColor { .diffHex(document?.palette.addition ?? "#5ecc71") }
    private var deleted: NSColor { .diffHex(document?.palette.deletion ?? "#ff6762") }
    func setDocument(_ value: HighlightedDiff, options: DiffRenderOptions, annotations: [LineAnnotation], markers: [MergeConflictMarkerRow], reset: Bool) {
        // Hosted annotation controls should inherit the code theme, rather than
        // the application's potentially opposite system appearance.
        appearance = NSAppearance(named: value.palette.isLight ? .aqua : .darkAqua)
        var previousOptions = self.options; previousOptions.theme = options.theme
        let retainedHeights = !reset && options.overflow == .scroll && previousOptions == options
            && self.annotations == annotations && markerRows == markers && document?.diff == value.diff ? rowHeights : nil
        let preserveAnnotationViews = !reset && self.options == options && options.overflow == .scroll
        if preserveAnnotationViews {
            // Retain controls by annotation identity when source edits move rows.
            annotationRevision = UUID()
        } else { clearAnnotationViews() }
        externalLayout = false
        tokenIndices = [:]; tokenIndexOrder = []; tokenIndexUnits = 0
        oversizedTokenIndex = nil; pointerSource = nil; metrics.oversizedTokenIndexUTF16Units = 0
        document = value; self.options = options; self.annotations = annotations; markerRows = markers
        let light = value.palette.isLight
        additionBackground = .diffLabMix(background, added, fraction: light ? 0.12 : 0.20)
        deletionBackground = .diffLabMix(background, deleted, fraction: light ? 0.12 : 0.20)
        additionGutter = .diffLabMix(background, added, fraction: light ? 0.09 : 0.15)
        deletionGutter = .diffLabMix(background, deleted, fraction: light ? 0.09 : 0.15)
        separatorBackground = .diffLabMix(background, light ? .black : .white, fraction: light ? 0.04 : 0.15)
        let stripeColor = NSColor.diffLabMix(background, light ? .black : .white, fraction: 0.08)
        let tile = NSImage(size: .init(width: 8, height: 8), flipped: true) { _ in
            stripeColor.setFill()
            for diagonal: CGFloat in [-3, 5, 13, 21] {
                let path = NSBezierPath()
                path.move(to: .init(x: diagonal, y: 0)); path.line(to: .init(x: diagonal + 2, y: 0))
                path.line(to: .init(x: diagonal - 6, y: 8)); path.line(to: .init(x: diagonal - 8, y: 8)); path.close(); path.fill()
            }
            return true
        }
        emptyPattern = NSColor(patternImage: tile)
        font = options.fontName.flatMap { NSFont(name: $0, size: options.fontSize) } ?? .monospacedSystemFont(ofSize: options.fontSize, weight: .regular)
        if reset {
            activeLine = nil
            hoveredLine = nil; hoveredToken = nil
            expanded = []; expandedRegions = [:]; selection = nil; textSelection = nil
            lineSelectionSession = false; pendingLineUnselect = false; dragAnchor = nil; clearProposedLineSelection()
        }
        maxCharacters = max(value.diff.deletionLines.lazy.map(\.utf16.count).max() ?? 0, value.diff.additionLines.lazy.map(\.utf16.count).max() ?? 0)
        func eligible(_ lines: [String]) -> [Int: Int] {
            var result: [Int: Int] = [:]
            for index in lines.indices {
                let text = cleanLastNewline(lines[index])
                if text.utf8.count > 4096 && text.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) { result[index] = text.utf8.count }
            }
            return result
        }
        oldLongASCII = eligible(value.diff.deletionLines); newLongASCII = eligible(value.diff.additionLines)
        tokenGeometryCache.removeAll(keepingCapacity: true)
        cache.removeAll(keepingCapacity: true); cacheOrder.removeAll(keepingCapacity: true); cacheUnits = 0
        rebuildPlan()
        if let retainedHeights, retainedHeights.rowCount == plan?.rows.count { rowHeights = retainedHeights }
        if preserveAnnotationViews { remapAnnotationViews() }
    }
    func expandHunk(_ index: Int, lines: Int, direction: ExpansionDirection) { expandedRegions[index, default: .init()].expand(direction, by: lines); rebuildPlan(); updateSize(viewport: enclosingScrollView?.contentSize ?? .zero) }
    func refreshExpansionLayout() { rebuildPlan(); updateSize(viewport: enclosingScrollView?.contentSize ?? .zero) }
    private func rebuildPlan() {
        guard let document else { return }
        wrapTask?.cancel(); wrapKey = nil
        plan = withEditorCaret(.init(diff: document.diff, options: options, expandedHunks: expanded, expandedRegions: expandedRegions, annotations: annotations, markerRows: markerRows, canHydrateContext: canLoadPartial))
        needsDisplay = true
    }
    private func withEditorCaret(_ plan: DiffRenderPlan) -> DiffRenderPlan {
        guard !options.collapsed, let editor, let document,
              editor.document.lineCount > document.diff.additionLines.count,
              editor.document.getLineText(editor.document.lineCount - 1).isEmpty else { return plan }
        return DiffRenderPlan(rows: plan.rows + [.init(kind: .editorCaret, newNumber: editor.document.lineCount)])
    }
    func updateSize(viewport: NSSize) {
        viewportWidth = viewport.width
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let width = max(CGFloat(max(maxCharacters, trailingTextCharacters)) * advance, predictionContentWidth) + gutter + 30
        let totalWidth = options.diffStyle == .split ? width * 2 : width
        setFrameSize(NSSize(width: options.overflow == .wrap ? viewport.width : max(viewport.width, totalWidth), height: max(max(0, viewport.height - (enclosingScrollView?.contentInsets.top ?? 0)), rowHeights.totalHeight)))
        scheduleWrapping()
        updateAnnotationViews()
    }
    func installRenderPlan(_ value: DiffRenderPlan) {
        wrapTask?.cancel(); externalLayout = true; plan = value
        let revision = annotationRevision
        remapAnnotationViews()
        guard annotationRevision == revision else { return }
        updateSize(viewport: enclosingScrollView?.contentSize ?? .zero); needsDisplay = true
    }
    func waitForLayout() async {
        while let task = wrapTask {
            let key = wrapKey
            await task.value
            if key == wrapKey { return }
        }
    }
    private func scheduleWrapping() {
        guard !externalLayout, options.overflow == .wrap, let document, let plan, viewportWidth > 0 else { return }
        let width = max(1, columnWidth - gutter - 12)
        let key = "\(document.id):\(width):\(font.fontName):\(options.fontSize)"
        guard wrapKey != key else { return }
        wrapKey = key; wrapTask?.cancel()
        let name = font.fontName, size = options.fontSize
        let base = withEditorCaret(DiffRenderPlan(diff: document.diff, options: options, expandedHunks: expanded, expandedRegions: expandedRegions, annotations: annotations, markerRows: markerRows, canHydrateContext: canLoadPartial))
        wrapTask = Task { [weak self] in
            do {
                let wrapped = try await DiffWrapLayout.shared.layout(plan: base, diff: document.diff, width: width, fontName: name, fontSize: size)
                try Task.checkCancellation()
                guard let self, self.wrapKey == key else { return }
                let rowOffset = self.visibleRect.minY
                // A detached or closing view can have a null visible rectangle.
                // Validate against the actual row bounds before converting to Int.
                let oldRow = rowOffset.isFinite && rowOffset >= 0 && rowOffset < self.rowHeights.totalHeight ? self.rowHeights.row(at: rowOffset) : -1
                let anchor = plan.rows.indices.contains(oldRow) ? plan.rows[oldRow] : nil
                let anchorOffset = oldRow >= 0 ? rowOffset - self.rowOrigin(oldRow) : 0
                self.plan = wrapped
                let annotationRevision = self.annotationRevision
                self.remapAnnotationViews()
                guard self.wrapKey == key, self.annotationRevision == annotationRevision else { return }
                self.updateSize(viewport: self.enclosingScrollView?.contentSize ?? .zero)
                if let anchor, let target = wrapped.rows.firstIndex(where: { $0.matchesScrollAnchor(anchor) }) {
                    let offset = min(max(0, anchorOffset), max(0, self.rowHeights.height(of: target) - 1))
                    self.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: self.rowOrigin(target) + offset))
                }
                self.needsDisplay = true; self.onLayoutChange?()
            } catch { /* Replaced width/document jobs are deliberately discarded. */ }
        }
    }
    var selectionHighlightSide: DiffSide? { didSet { needsDisplay = true } }
    var selectionLineNumberOnly = false { didSet { needsDisplay = true } }
    var conflictActionRenderer: DiffConflictActionRenderer?
    var mergeConflictActions: [MergeConflictDiffAction] = [] {
        didSet {
            conflictActionsByIndex.removeAll(keepingCapacity: true)
            for action in mergeConflictActions where conflictActionsByIndex[action.conflictIndex] == nil {
                conflictActionsByIndex[action.conflictIndex] = action
            }
        }
    }
    private var conflictActionsByIndex: [Int: MergeConflictDiffAction] = [:]
    private struct MountedConflictAction {
        let id: UUID
        let action: MergeConflictDiffAction
        let view: NSView?
    }
    private var conflictActionViews: [Int: MountedConflictAction] = [:]
    private var conflictActionRevision = UUID()
    private var updatingConflictActions = false
    func clearConflictActionViews() {
        conflictActionRevision = UUID()
        let previous = conflictActionViews; conflictActionViews.removeAll()
        for entry in previous.values { entry.view?.removeFromSuperview() }
        needsDisplay = true
    }
    func updateConflictActionViews() {
        guard !updatingConflictActions else { return }
        guard options.mergeConflictActionsType == .custom, let plan, document != nil else {
            if !conflictActionViews.isEmpty { clearConflictActionViews() }
            return
        }
        updatingConflictActions = true
        defer { updatingConflictActions = false }
        let renderer = conflictActionRenderer, revision = conflictActionRevision
        let visible = visibleRect
        let anchorRow = rowHeights.row(at: visible.minY), anchorOffset = visible.minY - rowOrigin(rowHeights.row(at: visible.minY))
        var retained = Set<Int>(), changed = false
        for index in visibleRows(y: visible.minY, height: visible.height) {
            let row = plan.rows[index]
            guard case .conflictMarker(_, .start) = row.kind, let conflict = row.conflictIndex else { continue }
            var height: CGFloat = 0
            if let action = conflictActionsByIndex[conflict] {
                height = 28 // Upstream action content has a 1.75rem minimum.
                retained.insert(conflict)
                if conflictActionViews[conflict]?.action != action {
                    conflictActionViews.removeValue(forKey: conflict)?.view?.removeFromSuperview()
                    guard conflictActionRevision == revision else { return }
                    let id = UUID()
                    let view = renderer?.render(action) { [weak self] resolution in
                        guard let self, self.options.mergeConflictActionsType == .custom,
                              self.conflictActionRenderer === renderer,
                              self.conflictActionViews[conflict]?.id == id,
                              let currentPlan = self.plan,
                              self.visibleRows(y: self.visibleRect.minY, height: self.visibleRect.height).contains(where: {
                                  guard currentPlan.rows.indices.contains($0) else { return false }
                                  if case .conflictMarker(_, .start) = currentPlan.rows[$0].kind {
                                      return currentPlan.rows[$0].conflictIndex == conflict
                                  }
                                  return false
                              }), let resolve = self.onResolveConflict else { return false }
                        resolve(conflict, resolution); return true
                    }
                    guard conflictActionRevision == revision else { return }
                    conflictActionViews[conflict] = .init(id: id, action: action, view: view)
                    if let view { addSubview(view) }
                    guard conflictActionRevision == revision else { return }
                }
                if let view = conflictActionViews[conflict]?.view {
                    view.frame = .init(x: visible.minX + gutter + 8, y: rowOrigin(index), width: max(0, viewportWidth - gutter - 16), height: view.frame.height)
                    view.layoutSubtreeIfNeeded()
                    let intrinsic = view.intrinsicContentSize.height
                    let fitting = intrinsic >= 0 ? intrinsic : view.fittingSize.height
                    let preferred = fitting > 0 ? fitting : view.frame.height
                    guard conflictActionRevision == revision else { return }
                    if preferred.isFinite { height = max(28, ceil(preferred)) }
                    view.setFrameSize(.init(width: view.frame.width, height: height))
                    guard conflictActionRevision == revision else { return }
                }
            }
            let total = height + options.lineHeight
            if rowHeights.height(of: index) != total { rowHeights.setHeight(total, for: index); changed = true }
        }
        for key in Array(conflictActionViews.keys) where !retained.contains(key) {
            conflictActionViews.removeValue(forKey: key)?.view?.removeFromSuperview()
            guard conflictActionRevision == revision else { return }
        }
        if changed {
            setFrameSize(.init(width: frame.width, height: max(enclosingScrollView?.contentSize.height ?? 0, rowHeights.totalHeight)))
            if let scroll = enclosingScrollView {
                let y = min(max(0, rowOrigin(anchorRow) + anchorOffset), max(0, frame.height - scroll.contentSize.height))
                scroll.contentView.scroll(to: .init(x: visible.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            needsDisplay = true; onLayoutChange?()
        }
    }
    var separatorRenderer: DiffSeparatorRenderer?
    private struct MountedSeparator {
        let id: UUID
        let data: HunkData
        let view: NSView?
    }
    private var separatorViews: [String: MountedSeparator] = [:]
    private var separatorRevision = UUID()
    private var updatingSeparatorViews = false
    func clearSeparatorViews() {
        separatorRevision = UUID()
        let previous = separatorViews
        separatorViews.removeAll()
        for entry in previous.values { entry.view?.removeFromSuperview() }
        needsDisplay = true
    }
    func updateSeparatorViews() {
        guard !updatingSeparatorViews else { return }
        guard options.hunkSeparators == .custom, let plan, let document else {
            if !separatorViews.isEmpty { clearSeparatorViews() }
            return
        }
        updatingSeparatorViews = true
        defer { updatingSeparatorViews = false }
        let renderer = separatorRenderer
        let revision = separatorRevision
        let visible = visibleRect
        let anchorRow = rowHeights.row(at: visible.minY)
        let anchorOffset = visible.minY - rowOrigin(anchorRow)
        let types: [CodeColumnType] = options.diffStyle == .split ? [.deletions, .additions] : [.unified]
        var retained = Set<String>()
        var changed = false
        for index in visibleRows(y: visible.minY, height: visible.height) {
            let row = plan.rows[index]
            guard case .separator = row.kind else { continue }
            var height: CGFloat = 0
            var views: [NSView] = []
            for type in types {
                guard let data = row.hunkData(in: document.diff, type: type,
                    expansionLineCount: options.expansionLineCount, canHydrateContext: canLoadPartial) else { continue }
                let key = data.slotName
                retained.insert(key)
                if separatorViews[key]?.data != data {
                    separatorViews.removeValue(forKey: key)?.view?.removeFromSuperview()
                    guard separatorRevision == revision else { return }
                    let id = UUID()
                    let view = renderer?.render(data) { [weak self] action in
                        guard let self, self.options.hunkSeparators == .custom,
                              self.separatorRenderer === renderer,
                              let entry = self.separatorViews[key], entry.id == id,
                              entry.data.expansionActions.contains(action),
                              let current = self.document,
                              self.plan?.rows.contains(where: {
                                  $0.hunkData(in: current.diff, type: data.type,
                                    expansionLineCount: self.options.expansionLineCount,
                                    canHydrateContext: self.canLoadPartial) == data
                              }) == true,
                              let expand = self.onExpand else { return false }
                        let direction: ExpansionDirection = action == .up ? .up : action == .down ? .down : .both
                        expand(data.hunkIndex, action == .all ? data.lines : self.options.expansionLineCount, direction)
                        return true
                    }
                    guard separatorRevision == revision else { return }
                    separatorViews[key] = .init(id: id, data: data, view: view)
                    if let view { addSubview(view) }
                    guard separatorRevision == revision else { return }
                }
                if let view = separatorViews[key]?.view {
                    let x = visible.minX + (type == .additions ? columnWidth : 0)
                    let width = type == .unified ? viewportWidth : columnWidth
                    view.frame = .init(x: x, y: rowOrigin(index), width: width, height: view.frame.height)
                    view.layoutSubtreeIfNeeded()
                    let intrinsic = view.intrinsicContentSize.height
                    let fitting = intrinsic >= 0 ? intrinsic : view.fittingSize.height
                    let preferred = fitting > 0 ? fitting : view.frame.height
                    guard separatorRevision == revision else { return }
                    if preferred.isFinite { height = max(height, ceil(preferred)) }
                    views.append(view)
                }
            }
            if rowHeights.height(of: index) != height {
                rowHeights.setHeight(height, for: index); changed = true
            }
            for view in views {
                view.setFrameSize(.init(width: view.frame.width, height: height))
                guard separatorRevision == revision else { return }
            }
        }
        for key in Array(separatorViews.keys) where !retained.contains(key) {
            separatorViews.removeValue(forKey: key)?.view?.removeFromSuperview()
            guard separatorRevision == revision else { return }
        }
        if changed {
            setFrameSize(.init(width: frame.width, height: max(enclosingScrollView?.contentSize.height ?? 0, rowHeights.totalHeight)))
            if let scroll = enclosingScrollView {
                let y = min(max(0, rowOrigin(anchorRow) + anchorOffset), max(0, frame.height - scroll.contentSize.height))
                scroll.contentView.scroll(to: .init(x: visible.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            needsDisplay = true; onLayoutChange?()
        }
    }
    var renderAnnotation: ((LineAnnotation) -> NSView?)?
    private struct MountedAnnotation {
        var annotation: LineAnnotation
        let view: NSView?
        var frameObservation: ViewFrameSizeObservation?
        var measuredWidth: CGFloat?
        var measuredHeight: CGFloat?
    }
    private var annotationViews: [String: MountedAnnotation] = [:]
    private var annotationRevision = UUID()
    private var updatingAnnotationViews = false
    private func remapAnnotationViews() {
        guard !annotationViews.isEmpty, let plan else { return }
        let revision = annotationRevision
        let previous = annotationViews
        var candidates = Dictionary(grouping: previous.values, by: { $0.annotation.id })
        var next: [String: MountedAnnotation] = [:]
        var retained = Set<ObjectIdentifier>()
        for (row, item) in plan.rows.enumerated() {
            for (slot, annotation) in item.annotations.enumerated() {
                guard let entries = candidates.removeValue(forKey: annotation.id), entries.count == 1,
                      var entry = entries.first, entry.annotation.side == annotation.side,
                      entry.annotation.text == annotation.text, entry.annotation.metadata == annotation.metadata else { continue }
                entry.annotation = annotation
                next["\(row):\(slot)"] = entry
                if let view = entry.view { retained.insert(ObjectIdentifier(view)) }
            }
        }
        annotationViews = next
        for entry in previous.values {
            if let view = entry.view, !retained.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
            guard annotationRevision == revision else { return }
        }
    }
    func invalidateAnnotationMeasurements() {
        for key in Array(annotationViews.keys) {
            annotationViews[key]?.measuredWidth = nil
            annotationViews[key]?.measuredHeight = nil
        }
    }
    func clearAnnotationViews() {
        annotationRevision = UUID()
        let previous = annotationViews
        annotationViews.removeAll(); needsDisplay = true
        for entry in previous.values { entry.view?.removeFromSuperview() }
    }
    func updateAnnotationViews() {
        updateSeparatorViews()
        updateConflictActionViews()
        annotationRevision = UUID()
        guard !updatingAnnotationViews else {
            enclosingScrollView?.superview?.needsLayout = true
            return
        }
        updatingAnnotationViews = true
        defer { updatingAnnotationViews = false }
        let revision = annotationRevision
        guard let renderAnnotation, let plan else { clearAnnotationViews(); return }
        let visible = visibleRect
        let range = visibleRows(y: visible.minY, height: visible.height)
        let anchorRow = rowHeights.row(at: visible.minY)
        let anchorOffset = visible.minY - rowOrigin(anchorRow)
        var heightChanged = false
        var retained = Set<String>()
        for index in range {
            var measuredHeight: CGFloat = 0
            for (slot, annotation) in plan.rows[index].annotations.enumerated() {
                let key = "\(index):\(slot)"
                retained.insert(key)
                if annotationViews[key]?.annotation != annotation {
                    annotationViews.removeValue(forKey: key)?.view?.removeFromSuperview()
                    guard annotationRevision == revision else { return }
                    let view = renderAnnotation(annotation)
                    guard annotationRevision == revision else { return }
                    annotationViews[key] = .init(annotation: annotation, view: view)
                    if let view {
                        annotationViews[key]?.frameObservation = ViewFrameSizeObservation(view: view) { [weak self, weak view] in
                            guard let self, let view, !self.updatingAnnotationViews else { return }
                            for key in Array(self.annotationViews.keys) where self.annotationViews[key]?.view === view {
                                self.annotationViews[key]?.measuredWidth = nil
                                self.annotationViews[key]?.measuredHeight = nil
                            }
                            self.enclosingScrollView?.superview?.needsLayout = true
                        }
                    }
                    if let view { addSubview(view) }
                    guard annotationRevision == revision else { return }
                }
                let split = options.diffStyle == .split
                let x = visible.minX + (split && annotation.side == .additions ? columnWidth : 0)
                if let view = annotationViews[key]?.view {
                    view.frame = .init(x: x, y: rowOrigin(index), width: split ? columnWidth : viewportWidth, height: max(options.lineHeight, view.frame.height))
                    let height: CGFloat
                    if annotationViews[key]?.measuredWidth == view.frame.width,
                       let cached = annotationViews[key]?.measuredHeight {
                        height = cached
                    } else {
                        view.layoutSubtreeIfNeeded()
                        let intrinsic = view.intrinsicContentSize.height
                        let fitting = intrinsic > 0 ? intrinsic : view.fittingSize.height
                        height = fitting > 0 ? fitting : view.frame.height
                        guard annotationRevision == revision else { return }
                        annotationViews[key]?.measuredWidth = view.frame.width
                        annotationViews[key]?.measuredHeight = height
                    }
                    if height.isFinite { measuredHeight = max(measuredHeight, options.lineHeight, ceil(height)) }
                }
                guard annotationRevision == revision else { return }
            }
            if !plan.rows[index].annotations.isEmpty {
                if rowHeights.height(of: index) != measuredHeight {
                    rowHeights.setHeight(measuredHeight, for: index); heightChanged = true
                }
                for slot in plan.rows[index].annotations.indices {
                    if let view = annotationViews["\(index):\(slot)"]?.view {
                        view.setFrameSize(.init(width: view.frame.width, height: measuredHeight))
                        guard annotationRevision == revision else { return }
                    }
                }
            }
        }
        for key in Array(annotationViews.keys) where !retained.contains(key) {
            annotationViews.removeValue(forKey: key)?.view?.removeFromSuperview()
            guard annotationRevision == revision else { return }
        }
        if heightChanged {
            setFrameSize(.init(width: frame.width, height: max(enclosingScrollView?.contentSize.height ?? 0, rowHeights.totalHeight)))
            if let scroll = enclosingScrollView {
                let y = min(max(0, rowOrigin(anchorRow) + anchorOffset), max(0, frame.height - scroll.contentSize.height))
                scroll.contentView.scroll(to: .init(x: visible.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            needsDisplay = true; onLayoutChange?()
        }
    }
    private var selectionPaintRange: ClosedRange<Int>?
    private var selectedOldPaintLines: [Int: Bool] = [:]
    private var selectedNewPaintLines: [Int: Bool] = [:]
    override func draw(_ dirtyRect: NSRect) {
        let start = CACurrentMediaTime()
        refreshPredictionLayout(); updateEditorWidgets()
        background.setFill(); dirtyRect.fill()
        updateGutterUtility()
        guard let plan, let document else { return }
        selectionPaintRange = nil
        selectedOldPaintLines.removeAll(keepingCapacity: true)
        selectedNewPaintLines.removeAll(keepingCapacity: true)
        if textSelection == nil, let selection {
            selectionPaintRange = selection.rowRange(in: document.diff, style: options.diffStyle)
        }
        let visible = dirtyRect.intersection(visibleRect)
        guard !visible.isNull else { return }
        let range = visibleRows(y: visible.minY, height: visible.height)
        metrics.drawnRows = range.count
        for index in range {
            let row = plan.rows[index], y = rowOrigin(index)
            switch row.kind {
            case .separator(let hidden, let hi):
                if options.hunkSeparators == .custom { continue }
                let card = separatorRect(row, y: y)
                let rounded = options.hunkSeparators == .lineInfo
                separatorBackground.setFill()
                NSBezierPath(roundedRect: card, xRadius: rounded ? 6 : 0, yRadius: rounded ? 6 : 0).fill()
                if options.hunkSeparators == .simple { continue }
                let controls = separatorControls(row, y: y)
                for (action, rect) in controls where action != .all {
                    background.setFill(); NSRect(x: rect.maxX - 2, y: card.minY, width: 2, height: card.height).fill()
                    if rect.height < card.height {
                        background.setFill(); NSRect(x: rect.minX, y: card.midY - 1, width: rect.width, height: 2).fill()
                    }
                    drawExpandIcon(action, in: rect, hovered: hoveredDecoration == .expansion(index, action))
                }
                let title: String
                if options.hunkSeparators == .metadata, document.diff.hunks.indices.contains(hi) { title = document.diff.hunks[hi].hunkSpecs ?? "" }
                else { title = row.hunkData(in: document.diff, type: .unified, canHydrateContext: canLoadPartial)?.lineCountKnown == false ? "More unchanged context may be available" : "\(hidden) unmodified lines" }
                let textX = controls.last(where: { $0.0 != .all })?.1.maxX ?? card.minX
                NSGraphicsContext.saveGraphicsState(); card.clip()
                uiLabel(title, in: .init(x: textX + 8, y: card.minY, width: max(0, card.maxX - textX - 16), height: card.height), underline: hoveredDecoration == .expansion(index, .all))
                NSGraphicsContext.restoreGraphicsState()
            case .annotation(let text):
                if renderAnnotation != nil { continue }
                if row.annotations.isEmpty {
                    NSColor.systemBlue.withAlphaComponent(0.12).setFill(); NSRect(x: 0, y: y, width: bounds.width, height: options.lineHeight).fill()
                    label("●  " + text, x: visibleRect.minX + gutter, y: y, color: .systemBlue)
                } else {
                    for annotation in row.annotations {
                        let split = options.diffStyle == .split
                        let x = visibleRect.minX + (split && annotation.side == .additions ? columnWidth : 0)
                        let rect = NSRect(x: x, y: y, width: split ? columnWidth : viewportWidth, height: options.lineHeight)
                        NSGraphicsContext.saveGraphicsState(); rect.clip()
                        NSColor.systemBlue.withAlphaComponent(0.12).setFill(); rect.fill()
                        label("●  " + annotation.text, x: x + gutter, y: y, color: .systemBlue)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
            case .conflictMarker(let text, let kind):
                var markerY = y
                let neutral = NSColor.diffLabMix(background, document.palette.isLight ? .black : .white, fraction: document.palette.isLight ? 0.015 : 0.075)
                if kind == .start && options.mergeConflictActionsType != .none {
                    let actionHeight = max(0, rowHeights.height(of: index) - options.lineHeight)
                    neutral.setFill(); NSRect(x: visibleRect.minX, y: y, width: viewportWidth, height: actionHeight).fill()
                    for (title, resolution, rect) in conflictControls(y: y) {
                        let hoverColor = resolution == .deletions ? added : resolution == .additions ? NSColor.diffHex(document.palette.modified) : foreground
                        uiLabel(title, in: rect, fontSize: 12, color: hoveredDecoration == .conflict(index, resolution) ? hoverColor : nil)
                        if resolution != .both {
                            uiLabel(" | ", in: .init(x: rect.maxX, y: rect.minY, width: conflictSeparatorWidth, height: rect.height), fontSize: 12, color: foreground.withAlphaComponent(0.36))
                        }
                    }
                    markerY += actionHeight
                }
                let tint = kind == .start ? added : NSColor.diffHex(document.palette.modified)
                let color = kind == .start || kind == .end ? NSColor.diffLabMix(background, tint, fraction: document.palette.isLight ? 0.22 : 0.32) : neutral
                color.setFill(); NSRect(x: visibleRect.minX, y: markerY, width: viewportWidth, height: options.lineHeight).fill()
                background.setFill(); NSRect(x: visibleRect.minX + gutter - 2, y: y, width: 2, height: markerY - y + options.lineHeight).fill()
                let origin = NSPoint(x: visibleRect.minX + gutter + 8, y: markerY + (options.lineHeight - font.ascender + font.descender) / 2)
                (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: foreground])
                let suffix = kind == .start ? " (Current Change)" : kind == .end ? " (Incoming Change)" : ""
                let width = (text as NSString).size(withAttributes: [.font: font]).width
                uiLabel(suffix, in: .init(x: origin.x + width, y: markerY, width: max(0, viewportWidth - gutter - width), height: options.lineHeight), fontSize: 12)
            case .noNewline:
                if options.diffStyle == .split {
                    drawNoNewline(row, side: .deletions, x: visibleRect.minX, y: y)
                    drawNoNewline(row, side: .additions, x: visibleRect.minX + columnWidth, y: y)
                } else {
                    drawNoNewline(row, side: row.oldNumber != nil ? .deletions : .additions, x: visibleRect.minX, y: y)
                }
            case .editorCaret:
                let x = visibleRect.minX + (options.diffStyle == .split ? columnWidth : 0)
                drawLineState(row, side: .additions, number: row.newNumber, x: x, y: y)
                if !options.disableLineNumbers, let number = row.newNumber { label(displayedLineNumber(number), x: x + numberGutter - monospaceAdvance - (displayedLineNumber(number) as NSString).size(withAttributes: [.font: font]).width, y: y, color: lineNumberColor(number, side: .additions, changed: false)) }
                if let selected = textSelection, selected.side == .additions, selected.head.line + 1 == row.newNumber {
                    foreground.setFill(); NSRect(x: x + gutter, y: y + 2, width: 1, height: options.lineHeight - 4).fill()
                }
                if let number = row.newNumber {
                    let empty = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: [.font: font]))
                    drawEditorOverlays(line: empty, sourceLine: number - 1, fragment: nil, sourceLength: 0, textX: x + gutter, y: y)
                }
            default:
                if options.diffStyle == .split {
                    drawCell(row, side: .deletions, x: visibleRect.minX, y: y)
                    drawCell(row, side: .additions, x: visibleRect.minX + columnWidth, y: y)
                } else { drawCell(row, side: row.newIndex != nil ? .additions : .deletions, x: visibleRect.minX, y: y) }
            }
        }
        if options.diffStyle == .split {
            background.setFill()
            for index in range {
                if case .separator = plan.rows[index].kind { continue }
                NSRect(x: visibleRect.minX + columnWidth - 1, y: rowOrigin(index), width: 2, height: rowHeights.height(of: index)).fill()
            }
        }
        if options.diffStyle == .split {
            for (index, height) in predictionSpacers where plan.rows.indices.contains(index) {
                let rect = NSRect(x: visibleRect.minX, y: rowOrigin(index) + options.lineHeight, width: columnWidth, height: height).intersection(visibleRect)
                guard !rect.isNull else { continue }
                let row = plan.rows[index]
                if row.oldIndex == nil { drawEmptyCell(rect) }
                else if row.kind == .change && !options.disableBackground {
                    deletionBackground.setFill(); rect.fill(); deletionGutter.setFill()
                    NSRect(x: rect.minX, y: rect.minY, width: gutter, height: rect.height).fill()
                    if options.diffIndicators == .bars {
                        deleted.setFill()
                        let period = options.lineHeight / max(1, (options.lineHeight / 2).rounded())
                        let start = floor(rect.minY / period) * period
                        NSGraphicsContext.saveGraphicsState(); rect.clip()
                        for y in stride(from: start, to: rect.maxY, by: period) { NSRect(x: rect.minX, y: y, width: 4, height: period / 2).fill() }
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
            }
        }
        drawPredictionPreviews()
        metrics.cachedLines = cache.count; metrics.cachedUTF16Units = cacheUnits
        metrics.lastDrawMilliseconds = (CACurrentMediaTime() - start) * 1000
    }
    private func lineNumberColor(_ number: Int, side: DiffSide, changed: Bool) -> NSColor {
        let selected = isLineSelected(number, side: side)
        let active = activeLine == number && activeLineOptions.side == side
        if (selected || active), let document {
            return .diffLabMix(.diffHex(document.palette.modified), document.palette.isLight ? .black : .white,
                               fraction: document.palette.isLight ? 0.35 : 0.25)
        }
        return changed ? (side == .deletions ? deleted : added) : .diffLabMix(background, foreground, fraction: 0.65)
    }
    private func isLineSelected(_ number: Int?, side: DiffSide) -> Bool {
        guard textSelection == nil, selection != nil, let number, selectionHighlightSide == nil || selectionHighlightSide == side else { return false }
        if let diff = document?.diff {
            if let cached = side == .deletions ? selectedOldPaintLines[number] : selectedNewPaintLines[number] { return cached }
            guard let range = selectionPaintRange,
                  let index = diff.selectionLineIndex(number, side: side) else { return false }
            let selected = range.contains(options.diffStyle == .split ? index.split : index.unified)
            if side == .deletions { selectedOldPaintLines[number] = selected }
            else { selectedNewPaintLines[number] = selected }
            return selected
        }
        return false
    }
    private func drawLineState(_ row: DiffRow, side: DiffSide, number: Int?, x: CGFloat, y: CGFloat) {
        guard let document else { return }
        let tint = row.conflictSide.map { $0 == .deletions ? added : NSColor.diffHex(document.palette.modified) } ?? (side == .deletions ? deleted : added)
        let isSelected = isLineSelected(number, side: side)
        let activeCaret = number != nil && activeLine == number && activeLineOptions.side == side
        let activeCode = activeCaret && !activeLineOptions.lineNumberOnly
        let activeBackground = document.palette.editorLineHighlightBackground.map { NSColor.diffHex($0, fallback: .clear) }
        let hasActiveBackground = (activeBackground?.alphaComponent ?? 0) > 0
        let hoverMode = hoveredLine?.side == side && hoveredLine?.lineNumber == number ? interactionHandlers.lineHoverHighlight : .disabled
        if (isSelected || activeCaret || hoverMode != .disabled) {
            let changed = row.kind == .change && !options.disableBackground
            let light = document.palette.isLight
            let selectedColor = NSColor.diffHex(document.palette.modified)
            let target: NSColor = (isSelected || activeCaret) ? selectedColor : changed ? tint : (light ? .black : .white)
            for isGutter in [true, false] {
                var color = changed ? (isGutter ? (side == .additions ? additionGutter : deletionGutter) : (side == .additions ? additionBackground : deletionBackground)) : background
                let paintSelection = isSelected && (isGutter || !selectionLineNumberOnly)
                if paintSelection {
                    color = .diffLabMix(color, selectedColor, fraction: isGutter ? (light ? 0.25 : 0.40) : (light ? 0.18 : 0.25))
                }
                if (isGutter ? activeCaret : activeCode) && hasActiveBackground {
                    var emphasis = selectedColor
                    if !isGutter && isSelected && changed && light { emphasis = .diffLabMix(tint, selectedColor, fraction: 0.18) }
                    color = .diffLabMix(color, emphasis, fraction: 0.15)
                }
                let hovered = hoverMode == .both || (isGutter ? hoverMode == .number : hoverMode == .line)
                if hovered { color = .diffLabMix(color, target, fraction: light ? 0.03 : 0.09) }
                if paintSelection || hovered || (isGutter ? activeCaret : activeCode) {
                    color.setFill()
                    NSRect(x: x + (isGutter ? 0 : gutter), y: y, width: isGutter ? gutter : max(0, columnWidth - gutter), height: options.lineHeight).fill()
                }
            }
        }
        if activeCode {
            let border = document.palette.editorLineHighlightBorder.map { NSColor.diffHex($0, fallback: .clear) }
                ?? (hasActiveBackground ? .clear : .diffLabMix(background, foreground, fraction: 0.30))
            border.setStroke()
            let physicalIndex = rowHeights.row(at: y)
            func sameLine(at index: Int) -> Bool {
                guard let rows = plan?.rows, rows.indices.contains(index) else { return false }
                return (side == .deletions ? rows[index].oldNumber : rows[index].newNumber) == number
                    && (side == .deletions ? rows[index].oldIndex != nil : rows[index].newIndex != nil)
            }
            let left = x + gutter + 0.5, right = x + max(gutter + 0.5, columnWidth - 0.5)
            let top = y + 0.5, bottom = y + options.lineHeight - 0.5
            let path = NSBezierPath()
            path.move(to: .init(x: left, y: y)); path.line(to: .init(x: left, y: y + options.lineHeight))
            path.move(to: .init(x: right, y: y)); path.line(to: .init(x: right, y: y + options.lineHeight))
            if !sameLine(at: physicalIndex - 1) { path.move(to: .init(x: left, y: top)); path.line(to: .init(x: right, y: top)) }
            if !sameLine(at: physicalIndex + 1) { path.move(to: .init(x: left, y: bottom)); path.line(to: .init(x: right, y: bottom)) }
            path.stroke()
        }
    }
    private func drawChangeBar(side: DiffSide, x: CGFloat, y: CGFloat) {
        let tint = side == .additions ? added : deleted
        tint.setFill()
        if side == .additions { NSRect(x: x, y: y, width: 4, height: options.lineHeight).fill() }
        else {
            deletionBackground.setFill(); NSRect(x: x, y: y, width: 4, height: options.lineHeight).fill()
            tint.setFill()
            let period = options.lineHeight / max(1, (options.lineHeight / 2).rounded())
            for offset in stride(from: CGFloat(0), to: options.lineHeight, by: period) {
                NSRect(x: x, y: y + offset, width: 4, height: period / 2).fill()
            }
        }
    }
    private func drawNoNewline(_ row: DiffRow, side: DiffSide, x: CGFloat, y: CGFloat) {
        let rect = NSRect(x: x, y: y, width: columnWidth, height: options.lineHeight)
        guard rect.intersects(visibleRect) else { return }
        guard (side == .deletions ? row.oldNumber : row.newNumber) != nil else {
            drawEmptyCell(rect); return
        }
        NSGraphicsContext.saveGraphicsState(); rect.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if row.noNewlineChanged {
            if !options.disableBackground {
                (side == .additions ? additionBackground : deletionBackground).setFill(); rect.fill()
                (side == .additions ? additionGutter : deletionGutter).setFill()
                NSRect(x: x, y: y, width: gutter, height: options.lineHeight).fill()
            }
            if options.diffIndicators == .bars { drawChangeBar(side: side, x: x, y: y) }
            else if options.diffIndicators == .classic {
                label(side == .additions ? "+" : "-", x: x + numberGutter, y: y, color: side == .additions ? added : deleted)
            }
        }
        label("No newline at end of file", x: x + gutter, y: y, color: foreground.withAlphaComponent(0.6))
    }
    private func drawCell(_ row: DiffRow, side: DiffSide, x: CGFloat, y: CGFloat) {
        guard let document else { return }
        let rect = NSRect(x: x, y: y, width: columnWidth, height: options.lineHeight)
        guard rect.intersects(visibleRect) else { return }
        let index = side == .deletions ? row.oldIndex : row.newIndex
        let number = side == .deletions ? row.oldNumber : row.newNumber
        let tint = row.conflictSide.map { $0 == .deletions ? added : NSColor.diffHex(document.palette.modified) } ?? (side == .deletions ? deleted : added)
        if row.kind == .change {
            if index != nil && !options.disableBackground {
                (side == .additions ? additionBackground : deletionBackground).setFill(); rect.fill()
                (side == .additions ? additionGutter : deletionGutter).setFill()
                NSRect(x: x, y: y, width: gutter, height: options.lineHeight).fill()
            }
            else if index == nil { drawEmptyCell(rect) }
        }
        if let conflictSide = row.conflictSide, index != nil {
            let color = conflictSide == .deletions ? added : NSColor.diffHex(document.palette.modified)
            NSColor.diffLabMix(background, color, fraction: document.palette.isLight ? 0.12 : 0.20).setFill(); rect.fill()
            NSColor.diffLabMix(background, color, fraction: document.palette.isLight ? 0.09 : 0.15).setFill()
            NSRect(x: x, y: y, width: gutter, height: options.lineHeight).fill()
            background.setFill(); NSRect(x: x + gutter - 2, y: y, width: 2, height: options.lineHeight).fill()
        }
        if index != nil { drawLineState(row, side: side, number: number, x: x, y: y) }
        if row.kind == .change && index != nil && row.conflictSide == nil && options.diffIndicators == .bars {
            drawChangeBar(side: side, x: x, y: y)
        }
        guard let index else { return }
        NSGraphicsContext.saveGraphicsState(); rect.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if !options.disableLineNumbers, !row.isContinuation, let number { label(displayedLineNumber(number), x: x + numberGutter - monospaceAdvance - (displayedLineNumber(number) as NSString).size(withAttributes: [.font: font]).width, y: y, color: row.conflictSide.map { $0 == .deletions ? added : .diffHex(document.palette.modified) } ?? lineNumberColor(number, side: side, changed: row.kind == .change)) }
        if row.kind == .change && row.conflictSide == nil && options.diffIndicators == .classic { label(side == .additions ? "+" : "-", x: x + numberGutter, y: y, color: tint) }
        let lines = side == .deletions ? document.diff.deletionLines : document.diff.additionLines
        guard lines.indices.contains(index) else { return }
        let fragment = visibleFragment(row, side: side, index: index)
        let line = styledLine(index: index, side: side, fragment: fragment, document: document)
        let horizontalFragment = (side == .deletions ? row.oldRange : row.newRange) == nil ? fragment?.location ?? 0 : 0
        let textX = x + gutter - visibleRect.minX / (options.diffStyle == .split ? 2 : 1) + CGFloat(horizontalFragment) * monospaceAdvance
        NSRect(x: x + gutter, y: y, width: max(0, columnWidth - gutter), height: options.lineHeight).clip()
        let styledTokens = side == .deletions ? document.oldTokens : document.newTokens
        var strikes: [(NSRect, NSColor)] = []
        if styledTokens.indices.contains(index) {
            var offset = 0
            for token in styledTokens[index] {
                let length = token.content.utf16.count
                defer { offset += length }
                let strike = token.fontStyle != .notSet && token.fontStyle?.contains(.strikethrough) == true
                guard token.bgColor != nil || strike else { continue }
                let range = NSRange(location: offset, length: length)
                let overlap = fragment.map { NSIntersectionRange(range, $0) } ?? range
                guard overlap.length > 0 else { continue }
                let base = fragment?.location ?? 0
                let a = CTLineGetOffsetForStringIndex(line, overlap.location - base, nil)
                let b = CTLineGetOffsetForStringIndex(line, NSMaxRange(overlap) - base, nil)
                if let color = token.bgColor, !color.isEmpty {
                    NSColor.diffHex(color).setFill(); NSRect(x: textX + min(a, b), y: y, width: abs(b - a), height: options.lineHeight).fill()
                }
                if strike {
                    strikes.append((NSRect(x: textX + min(a, b), y: y + options.lineHeight / 2, width: abs(b - a), height: 1), NSColor.diffHex(token.color.flatMap { $0.isEmpty ? nil : $0 } ?? document.foreground)))
                }
            }
        }
        let spans = (side == .deletions ? document.oldSpans : document.newSpans)[index] ?? []
        for span in options.lineDiffType == .none ? [] : spans {
            let overlap = fragment.map { NSIntersectionRange(span.range, $0) } ?? span.range
            guard overlap.length > 0 else { continue }
            let base = fragment?.location ?? 0
            let start = CTLineGetOffsetForStringIndex(line, overlap.location - base, nil)
            let end = CTLineGetOffsetForStringIndex(line, NSMaxRange(overlap) - base, nil)
            tint.withAlphaComponent(document.palette.isLight ? 0.15 : 0.20).setFill(); NSRect(x: textX + start, y: y + 2, width: max(1, end - start), height: options.lineHeight - 4).fill()
        }
        if side == .additions, let matches = editor?.search?.lineMatches[index] {
            let visible = fragment ?? NSRange(location: 0, length: cleanLastNewline(lines[index]).utf16.count)
            var low = 0, high = matches.count
            while low < high { let middle = (low + high) / 2; if NSMaxRange(matches[middle]) <= visible.location { low = middle + 1 } else { high = middle } }
            NSColor.systemYellow.withAlphaComponent(document.palette.isLight ? 0.35 : 0.25).setFill()
            while low < matches.count && matches[low].location < NSMaxRange(visible) {
                let overlap = NSIntersectionRange(matches[low], visible)
                let a = CTLineGetOffsetForStringIndex(line, overlap.location - visible.location, nil)
                let b = CTLineGetOffsetForStringIndex(line, NSMaxRange(overlap) - visible.location, nil)
                NSRect(x: textX + min(a, b), y: y + 1, width: max(1, abs(b - a)), height: options.lineHeight - 2).fill()
                low += 1
            }
        }
        if side == .additions, let editor, editor.hasMarkedText(), let number {
            let start = editor.document.offsetAt(.init(line: number - 1, character: 0))
            let base = fragment?.location ?? 0, length = fragment?.length ?? cleanLastNewline(lines[index]).utf16.count
            let overlap = NSIntersectionRange(editor.markedRange(), NSRange(location: start + base, length: length))
            if overlap.length > 0 {
                let a = CTLineGetOffsetForStringIndex(line, overlap.location - start - base, nil)
                let b = CTLineGetOffsetForStringIndex(line, NSMaxRange(overlap) - start - base, nil)
                foreground.setFill(); NSRect(x: textX + min(a, b), y: y + options.lineHeight - 2, width: max(1, abs(b - a)), height: 1).fill()
            }
        }
        if side == .additions, let number {
            drawEditorOverlays(line: line, sourceLine: number - 1, fragment: fragment,
                               sourceLength: cleanLastNewline(lines[index]).utf16.count, textX: textX, y: y)
        }
        if let selected = textSelection, selected.side == side, let number {
            let (low, high) = selected.ordered
            if low.line <= number - 1 && number - 1 <= high.line {
                let base = fragment?.location ?? 0
                let length = fragment?.length ?? cleanLastNewline(lines[index]).utf16.count
                let from = number - 1 == low.line ? low.character : 0
                let to = number - 1 == high.line ? high.character : lines[index].utf16.count
                let start = min(length, max(0, from - base)), end = min(length, max(0, to - base))
                let a = CTLineGetOffsetForStringIndex(line, start, nil), b = CTLineGetOffsetForStringIndex(line, end, nil)
                if end > start {
                    NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55).setFill()
                    NSRect(x: textX + min(a, b), y: y, width: abs(b - a), height: options.lineHeight).fill()
                } else if low == high && from >= base && from <= base + length {
                    foreground.setFill(); NSRect(x: textX + a, y: y + 2, width: 1, height: options.lineHeight - 4).fill()
                }
            }
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.translateBy(x: textX, y: y + (options.lineHeight - font.ascender + font.descender) / 2 + font.ascender)
        context.scaleBy(x: 1, y: -1); context.textMatrix = .identity; context.textPosition = .zero; CTLineDraw(line, context); context.restoreGState()
        for (rect, color) in strikes { color.setFill(); rect.fill() }
        // Ghost text follows the end of a whole line. A line cut into slices has no single end to follow.
        if side == .additions, fragment == nil, let number, let ghost = trailingText[number], !ghost.text.isEmpty {
            let end = textX + CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let color = ghost.color.map { NSColor.diffHex($0) } ?? foreground.withAlphaComponent(0.45)
            label(ghost.text, x: end + monospaceAdvance * 4, y: y, color: color)
        }
    }
    private func drawEditorOverlays(line: CTLine, sourceLine: Int, fragment: NSRange?, sourceLength: Int, textX: CGFloat, y: CGFloat) {
        guard let editor, let document else { return }
        let visible = fragment ?? NSRange(location: 0, length: sourceLength)
        func span(_ start: TextPosition, _ end: TextPosition) -> NSRect? {
            let from = sourceLine == start.line ? start.character : 0
            let to = sourceLine == end.line ? end.character : sourceLength
            let lower = max(visible.location, from), upper = min(NSMaxRange(visible), to)
            guard upper > lower || (start == end && lower == upper && lower >= visible.location && lower <= NSMaxRange(visible)) else { return nil }
            let a = CTLineGetOffsetForStringIndex(line, lower - visible.location, nil)
            let b = CTLineGetOffsetForStringIndex(line, upper - visible.location, nil)
            return .init(x: textX + min(a, b), y: y, width: max(1, abs(b - a)), height: options.lineHeight)
        }
        for range in editor.bracketMatchRanges where range.start.line == sourceLine {
            guard let rect = span(range.start, range.end) else { continue }
            foreground.withAlphaComponent(0.05).setFill(); rect.fill()
            foreground.withAlphaComponent(0.6).setFill()
            NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        }
        for selection in editor.secondarySelections(on: sourceLine) {
            if !selection.isCollapsed, let rect = span(selection.start, selection.end) {
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).setFill(); rect.fill()
            }
            let focus = selection.focus
            if focus.line == sourceLine, focus.character >= visible.location,
               focus.character < NSMaxRange(visible) || focus.character == sourceLength && NSMaxRange(visible) == sourceLength {
                let offset = CTLineGetOffsetForStringIndex(line, focus.character - visible.location, nil)
                foreground.setFill(); NSRect(x: textX + offset, y: y + 2, width: 1.5, height: options.lineHeight - 4).fill()
            }
        }
        for caret in editor.carets(on: sourceLine) {
            let selection = EditorSelection(anchor: caret.anchor, focus: caret.focus)
            let color = NSColor.diffHex(caret.metadata.color)
            if !selection.isCollapsed, let rect = span(selection.start, selection.end) {
                color.withAlphaComponent(color.alphaComponent * 0.32).setFill(); rect.fill()
            }
            if editor.caretRenderer == nil, caret.focus.line == sourceLine, caret.focus.character >= visible.location,
               caret.focus.character < NSMaxRange(visible) || caret.focus.character == sourceLength && NSMaxRange(visible) == sourceLength {
                let offset = CTLineGetOffsetForStringIndex(line, caret.focus.character - visible.location, nil)
                color.setFill(); NSRect(x: textX + offset, y: y + 2, width: 2, height: options.lineHeight - 4).fill()
            }
        }
        for marker in editor.markers(on: sourceLine) {
            guard var rect = span(marker.start, marker.end) else { continue }
            if marker.start == marker.end { rect.size.width = monospaceAdvance }
            rect = rect.intersection(visibleRect)
            guard !rect.isEmpty else { continue }
            let color: NSColor
            switch marker.severity {
            case .error: color = .diffHex(document.palette.editorErrorForeground ?? document.palette.deletion)
            case .warning: color = .diffHex(document.palette.editorWarningForeground ?? (document.palette.isLight ? "#d5a910" : "#ffd452"))
            case .info: color = .diffHex(document.palette.editorInfoForeground ?? document.palette.modified)
            case .hint: color = document.palette.editorHintForeground.map { NSColor.diffHex($0) } ?? foreground.withAlphaComponent(0.55)
            }
            NSGraphicsContext.saveGraphicsState(); rect.clip()
            color.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1
            var x = rect.minX
            // Same six-by-three zigzag path as upstream editor.css.
            path.move(to: .init(x: x, y: rect.maxY - 0.5))
            while x < rect.maxX {
                path.line(to: .init(x: x + 2, y: rect.maxY - 2))
                path.line(to: .init(x: x + 3, y: rect.maxY - 2))
                path.line(to: .init(x: x + 5, y: rect.maxY - 0.5))
                path.line(to: .init(x: x + 6, y: rect.maxY - 0.5)); x += 6
            }
            path.stroke(); NSGraphicsContext.restoreGraphicsState()
        }
    }
    private var markerHoverTask: Task<Void, Never>?
    private var hoveredMarkerID: UUID?
    private var markerPopover: NSPopover?
    func hideMarkerPopover() {
        markerHoverTask?.cancel(); markerHoverTask = nil
        hoveredMarkerID = nil; markerPopover?.close(); markerPopover = nil
    }
    private func updateMarkerHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let columnX = visibleRect.minX + (options.diffStyle == .split ? columnWidth : 0)
        guard event.type != .leftMouseDragged, let editor, point.x >= columnX + gutter,
              let row = row(at: point), row.newNumber != nil,
              let position = textPosition(at: point, row: row, side: .additions),
              let marker = editor.marker(at: position) else { hideMarkerPopover(); return }
        guard marker.id != hoveredMarkerID else { return }
        hideMarkerPopover(); hoveredMarkerID = marker.id
        markerHoverTask = Task { [weak self, weak editor] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, let editor, self.editor === editor, self.window != nil,
                  self.hoveredMarkerID == marker.id, !Task.isCancelled else { return }
            let content: NSView
            if let custom = editor.renderMarkerPopover?(marker) { content = custom }
            else {
                let title = marker.source.map { "\($0) · \(marker.severity.rawValue.capitalized)" } ?? marker.severity.rawValue.capitalized
                let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 12, weight: .semibold)
                let message = NSTextField(wrappingLabelWithString: marker.message); message.font = .systemFont(ofSize: 12)
                message.preferredMaxLayoutWidth = 296
                let stack = NSStackView(views: [heading, message]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
                stack.edgeInsets = .init(top: 10, left: 12, bottom: 10, right: 12)
                stack.setFrameSize(.init(width: 320, height: 70)); content = stack
            }
            // A custom renderer may replace the session or its diagnostics.
            guard self.editor === editor, self.hoveredMarkerID == marker.id else { return }
            let controller = NSViewController(); controller.view = content
            let popover = NSPopover(); popover.animates = false; popover.behavior = .semitransient; popover.contentViewController = controller
            let size = content.fittingSize
            popover.contentSize = .init(width: min(480, max(180, size.width)), height: max(44, size.height))
            self.markerPopover = popover
            popover.show(relativeTo: .init(x: point.x, y: point.y, width: 1, height: self.options.lineHeight), of: self, preferredEdge: .maxY)
        }
    }
    private func styledLine(index: Int, side: DiffSide, fragment: NSRange?, document: HighlightedDiff) -> CTLine {
        let lines = side == .deletions ? document.diff.deletionLines : document.diff.additionLines
        let key = side.rawValue + ":" + String(index) + (fragment.map { ":\($0.location):\($0.length)" } ?? "")
        let line: CTLine
        if let cached = cache[key] { line = cached.0 }
        else {
            let source: String
            if let pointerSource, pointerSource.key == side.rawValue + ":" + String(index) {
                source = fragment.map { pointerSource.text.substring(with: $0) } ?? (pointerSource.text as String)
            } else {
                let wholeSource = cleanLastNewline(lines[index])
                source = fragment.map { (wholeSource as NSString).substring(with: $0) } ?? wholeSource
            }
            let fragmentStart = fragment?.location ?? 0
            let attr = NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: foreground])
            let tokens = side == .deletions ? document.oldTokens : document.newTokens
            var offset = 0
            if tokens.indices.contains(index) {
                for token in tokens[index] {
                    let tokenRange = NSRange(location: offset, length: token.content.utf16.count)
                    let overlap = NSIntersectionRange(tokenRange, NSRange(location: fragmentStart, length: attr.length))
                    if overlap.length > 0 {
                        let range = NSRange(location: overlap.location - fragmentStart, length: overlap.length)
                        if let color = token.color, !color.isEmpty { attr.addAttribute(.foregroundColor, value: NSColor.diffHex(color), range: range) }
                        if let color = token.bgColor, !color.isEmpty { attr.addAttribute(.backgroundColor, value: NSColor.diffHex(color), range: range) }
                        if let style = token.fontStyle, style != .notSet {
                            var styled = font
                            if style.contains(.bold) { styled = NSFontManager.shared.convert(styled, toHaveTrait: .boldFontMask) }
                            if style.contains(.italic) { styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask) }
                            attr.addAttribute(.font, value: styled, range: range)
                            if style.contains(.underline) { attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
                        }
                    }
                    offset += token.content.utf16.count
                }
            }
            // CoreText does not paint NSAttributedString backgrounds; draw diff spans explicitly below.
            line = CTLineCreateWithAttributedString(attr)
            if attr.length <= 262_144 {
                while !cacheOrder.isEmpty && (cache.count >= 512 || cacheUnits + attr.length > 262_144) {
                    let oldest = cacheOrder.removeFirst(); cacheUnits -= cache.removeValue(forKey: oldest)?.1 ?? 0
                    tokenGeometryCache.removeValue(forKey: oldest)
                }
                cache[key] = (line, attr.length); cacheOrder.append(key); cacheUnits += attr.length
            }
            metrics.styledLines += 1
        }
        return line
    }
    private func label(_ text: String, x: CGFloat, y: CGFloat, color: NSColor) {
        (text as NSString).draw(at: NSPoint(x: x, y: y + (options.lineHeight - font.ascender + font.descender) / 2), withAttributes: [.font: font, .foregroundColor: color])
    }
    private var monospaceAdvance: CGFloat { ("M" as NSString).size(withAttributes: [.font: font]).width }
    private func visibleFragment(_ row: DiffRow, side: DiffSide, index: Int) -> NSRange? {
        if let wrapped = side == .deletions ? row.oldRange : row.newRange { return wrapped }
        guard options.overflow == .scroll, font.isFixedPitch,
              let length = (side == .deletions ? oldLongASCII : newLongASCII)[index] else { return nil }
        let offset = visibleRect.minX / (options.diffStyle == .split ? 2 : 1)
        let advance = max(1, monospaceAdvance)
        let start = min(length, max(0, Int(offset / advance) - 32) / 128 * 128)
        let end = min(length, Int((offset + columnWidth) / advance) + 160)
        return NSRange(location: start, length: max(0, end - start))
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let plan else { return }
        for index in visibleRows(y: visibleRect.minY, height: visibleRect.height) where plan.rows.indices.contains(index) {
            if case .conflictMarker(_, .start) = plan.rows[index].kind {
                for (_, _, rect) in conflictControls(y: rowOrigin(index)) {
                    let clipped = rect.intersection(visibleRect)
                    if !clipped.isNull && !clipped.isEmpty { addCursorRect(clipped, cursor: .pointingHand) }
                }
            }
            for (_, rect) in separatorControls(plan.rows[index], y: rowOrigin(index)) {
                let clipped = rect.intersection(visibleRect)
                if !clipped.isNull && !clipped.isEmpty { addCursorRect(clipped, cursor: .pointingHand) }
            }
        }
    }
    private func separatorControls(_ row: DiffRow, y: CGFloat) -> [(HunkExpansionAction, NSRect)] {
        guard options.hunkSeparators == .lineInfo || options.hunkSeparators == .lineInfoBasic,
              let document else { return [] }
        var actions = row.hunkData(in: document.diff, type: .unified,
            expansionLineCount: options.expansionLineCount, canHydrateContext: canLoadPartial)?.expansionActions ?? []
        if !actions.isEmpty && !actions.contains(.all) { actions.append(.all) }
        let card = separatorRect(row, y: y)
        let stacked = actions.contains(.up) && actions.contains(.down)
        let buttonWidth = min(34, card.width)
        return actions.map { action in
            if action == .all {
                return (action, NSRect(x: card.minX + buttonWidth, y: card.minY, width: max(0, card.width - buttonWidth), height: card.height))
            }
            let height = stacked ? card.height / 2 : card.height
            return (action, NSRect(x: card.minX, y: card.minY + (stacked && action == .down ? height : 0), width: buttonWidth, height: height))
        }
    }
    private func separatorRect(_ row: DiffRow, y: CGFloat) -> NSRect {
        let inset: CGFloat = options.hunkSeparators == .lineInfo ? 8 : 0
        return .init(x: visibleRect.minX + inset, y: y + (row.separatorIsFirst ? 0 : inset), width: max(0, viewportWidth - 2 * inset), height: options.hunkSeparators == .simple ? 4 : 32)
    }
    private func uiLabel(_ text: String, in rect: NSRect, fontSize: CGFloat? = nil, color: NSColor? = nil, underline: Bool = false) {
        let uiFont = NSFont.systemFont(ofSize: fontSize ?? options.fontSize)
        let height = uiFont.ascender - uiFont.descender
        (text as NSString).draw(in: .init(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height + 3), withAttributes: [.font: uiFont, .foregroundColor: color ?? foreground.withAlphaComponent(0.6), .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0])
    }
    private func drawExpandIcon(_ action: HunkExpansionAction, in rect: NSRect, hovered: Bool) {
        let icon = NSRect(x: rect.midX - 9, y: rect.midY - 8, width: 16, height: 16)
        (action == .both ? DiffSymbol.expandAll : .expand).draw(in: icon,
            color: hovered ? foreground : foreground.withAlphaComponent(0.6), flipY: action == .down)
    }
    private func drawEmptyCell(_ rect: NSRect) {
        let mixer: NSColor = document?.palette.isLight == true ? .black : .white
        NSColor.diffLabMix(background, mixer, fraction: document?.palette.isLight == true ? 0.02 : 0.04).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: gutter, height: rect.height).fill()
        let content = NSRect(x: rect.minX + gutter + 2, y: rect.minY, width: max(0, rect.width - gutter - 2), height: rect.height)
        emptyPattern.setFill(); content.fill()

    }
    var onResolveConflict: ((Int, DiffResolution) -> Void)?
    private var conflictSeparatorWidth: CGFloat { (" | " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width }
    private func conflictControls(y: CGFloat) -> [(String, DiffResolution, NSRect)] {
        guard options.mergeConflictActionsType == .default else { return [] }
        var x = visibleRect.minX + gutter + 8
        return [("Accept current change", DiffResolution.deletions), ("Accept incoming change", .additions), ("Accept both", .both)].enumerated().map { index, value in
            let title = value.0
            let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            defer { x += width + (index < 2 ? conflictSeparatorWidth : 0) }
            return (title, value.1, .init(x: x, y: y, width: width, height: 28))
        }
    }

    override func mouseDown(with event: NSEvent) {
        editor?.selectionGestureBegan()
        preservingMultipleDrag = false
        hideMarkerPopover()
        lineSelectionSession = false; pendingLineUnselect = false; dragAnchor = nil; textDrag = false
        clearProposedLineSelection()
        pendingClick = nil
        if let hit = clickEvent(event) { pendingClick = (hit.lineNumber, hit.annotationSide, hit.numberColumn, document?.sourceID) }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let row = row(at: point) else { return }
        if case .conflictMarker(_, .start) = row.kind, let conflict = row.conflictIndex,
           let hit = conflictControls(y: rowOrigin(rowHeights.row(at: point.y))).first(where: { $0.2.contains(point) }) {
            onResolveConflict?(conflict, hit.1); return
        }
        if case .separator(_, let hi) = row.kind {
            if let (action, _) = separatorControls(row, y: rowOrigin(rowHeights.row(at: point.y))).first(where: { $0.1.contains(point) }) {
                let direction: ExpansionDirection = action == .up ? .up : action == .down ? .down : .both
                let count: Int
                if case let .separator(hidden, _) = row.kind, action == .all { count = hidden }
                else { count = options.expansionLineCount }
                onExpand?(hi, count, direction)
            }
            return
        }
        dragSide = options.diffStyle == .split ? (point.x - visibleRect.minX < columnWidth ? .deletions : .additions) : (row.newNumber != nil ? .additions : .deletions)
        guard let line = dragSide == .deletions ? row.oldNumber : row.newNumber else { return }
        let columnX = visibleRect.minX + (options.diffStyle == .split && dragSide == .additions ? columnWidth : 0)
        textDrag = point.x >= columnX + gutter && event.clickCount < 3
        if textDrag, let position = textPosition(at: point, row: row, side: dragSide) {
            if let editor, dragSide == .additions, event.modifierFlags.contains(.option), event.clickCount == 1 {
                editor.setSelections(editor.getSelections() + [.init(start: position, end: position)])
                preservingMultipleDrag = true; return
            }
            let anchor = event.modifierFlags.contains(.shift) && textSelection?.side == dragSide ? textSelection!.anchor : position
            if event.clickCount == 2, let index = dragSide == .additions ? row.newIndex : row.oldIndex {
                let source = cleanLastNewline((dragSide == .additions ? document!.diff.additionLines : document!.diff.deletionLines)[index]) as NSString
                let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_]+|\s+|[^\p{L}\p{N}_\s]"#)
                let hit = min(position.character, max(0, source.length - 1))
                let range = regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)).first { NSLocationInRange(hit, $0.range) }?.range ?? NSRange(location: hit, length: 0)
                setTextSelection(.init(side: dragSide, anchor: .init(line: position.line, character: range.location), head: .init(line: position.line, character: NSMaxRange(range))))
            } else { setTextSelection(.init(side: dragSide, anchor: anchor, head: position)) }
            return
        }
        if point.x < columnX + gutter && editor == nil && !interactionHandlers.enableLineSelection { return }
        lineSelectionSession = editor == nil && point.x < columnX + gutter && interactionHandlers.enableLineSelection
        pendingLineUnselect = lineSelectionSession && !event.modifierFlags.contains(.shift) && selection == LineSelection(side: dragSide, startLine: line, endLine: line)
        textSelection = nil
        if pendingLineUnselect { dragAnchor = line; return }
        let clickedSide = dragSide
        if lineSelectionSession, event.modifierFlags.contains(.shift), let selection, let diff = document?.diff {
            guard let start = diff.selectionLineIndex(selection.startLine, side: selection.side),
                  let end = diff.selectionLineIndex(selection.endLine, side: selection.endSide ?? selection.side),
                  let clicked = diff.selectionLineIndex(line, side: clickedSide) else { lineSelectionSession = false; return }
            let a = options.diffStyle == .split ? start.split : start.unified
            let b = options.diffStyle == .split ? end.split : end.unified
            let c = options.diffStyle == .split ? clicked.split : clicked.unified
            let useStart = a <= b ? c >= a : c <= b
            dragAnchor = useStart ? selection.startLine : selection.endLine
            dragSide = useStart ? selection.side : selection.endSide ?? selection.side
        } else if event.modifierFlags.contains(.shift), let selection, selection.side == dragSide {
            let useStart = selection.startLine <= selection.endLine
                ? line >= selection.startLine : line <= selection.endLine
            dragAnchor = useStart ? selection.startLine : selection.endLine
        } else { dragAnchor = line }
        let revision = document?.id
        setGestureSelection(.init(side: dragSide, startLine: dragAnchor ?? line, endLine: line, endSide: clickedSide == dragSide ? nil : clickedSide))
        guard document?.id == revision else { lineSelectionSession = false; dragAnchor = nil; return }
        if lineSelectionSession { interactionHandlers.onLineSelectionStart?(gestureSelection) }
    }
    override func mouseDragged(with event: NSEvent) {
        lastPointerEvent = event; updateHover(event)
        pendingClick = nil
        _ = autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if textDrag, let row = row(at: point), let position = textPosition(at: point, row: row, side: dragSide), let anchor = textSelection?.anchor {
            setTextSelection(.init(side: dragSide, anchor: anchor, head: position)); return
        }
        guard let anchor = dragAnchor, let row = row(at: point) else { return }
        let endSide: DiffSide = lineSelectionSession
            ? (options.diffStyle == .split ? (point.x - visibleRect.minX < columnWidth ? .deletions : .additions) : (row.newNumber != nil ? .additions : .deletions)) : dragSide
        guard let line = endSide == .deletions ? row.oldNumber : row.newNumber else { return }
        let next = LineSelection(side: dragSide, startLine: anchor, endLine: line, endSide: endSide == dragSide ? nil : endSide)
        guard gestureSelection != next else { return }
        let wasPending = pendingLineUnselect; pendingLineUnselect = false
        let revision = document?.id
        setGestureSelection(next)
        guard document?.id == revision else { lineSelectionSession = false; dragAnchor = nil; return }
        if lineSelectionSession {
            if wasPending { interactionHandlers.onLineSelectionStart?(gestureSelection) }
            if document?.id == revision && lineSelectionSession { interactionHandlers.onLineSelectionChange?(gestureSelection) }
        }
    }
    override func mouseUp(with event: NSEvent) {
        defer { preservingMultipleDrag = false; editor?.selectionGestureEnded() }
        let gestureRevision = document?.id
        let pending = pendingClick
        let finishedSelection = lineSelectionSession
        if pendingLineUnselect { pendingLineUnselect = false; setGestureSelection(nil) }
        let completedSelection = gestureSelection
        lineSelectionSession = false
        defer { clearProposedLineSelection() }
        pendingClick = nil; dragAnchor = nil; textDrag = false
        guard document?.id == gestureRevision else { return }
        if finishedSelection {
            let revision = document?.id, completed = completedSelection
            interactionHandlers.onLineSelectionEnd?(completed)
            if document?.id == revision { interactionHandlers.onLineSelected?(gestureSelection) }
        }
        guard document?.id == gestureRevision else { return }
        guard let pending, pending.sourceID == document?.sourceID, let hit = clickEvent(event), pending.line == hit.lineNumber,
              pending.side == hit.annotationSide, pending.numberColumn == hit.numberColumn else { return }
        let revision = document?.id
        if !hit.numberColumn, let callback = interactionHandlers.onTokenClick, let token = tokenEvent(event, line: hit) { callback(token) }
        guard document?.id == revision else { return }
        if hit.numberColumn, let callback = interactionHandlers.onLineNumberClick { callback(hit) }
        else { interactionHandlers.onLineClick?(hit) }
    }
    private func clickEvent(_ event: NSEvent) -> DiffLineClickEvent? {
        guard interactionHandlers.onLineClick != nil || interactionHandlers.onLineNumberClick != nil || interactionHandlers.hasHoverHandlers || interactionHandlers.onTokenClick != nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let document, visibleRect.contains(point), let row = row(at: point), row.kind == .context || row.kind == .change else { return nil }
        let side: DiffSide = options.diffStyle == .split ? (point.x - visibleRect.minX < columnWidth ? .deletions : .additions) : (row.newNumber != nil ? .additions : .deletions)
        guard let line = side == .deletions ? row.oldNumber : row.newNumber else { return nil }
        let x = visibleRect.minX + (options.diffStyle == .split && side == .additions ? columnWidth : 0)
        let y = rowOrigin(rowHeights.row(at: point.y))
        let numberRect = NSRect(x: x, y: y, width: options.disableLineNumbers ? 0 : gutter, height: options.lineHeight)
        let type: DiffLineType = row.kind == .change ? (side == .deletions ? .changeDeletion : .changeAddition) : (row.hunkIndex == nil ? .contextExpanded : .context)
        return .init(fileDiff: document.diff, lineNumber: line, annotationSide: side, lineType: type, numberColumn: numberRect.contains(point), view: self,
                     lineRect: .init(x: x + gutter, y: y, width: max(0, columnWidth - gutter), height: options.lineHeight), numberRect: numberRect, event: event)
    }
    private func tokenEvent(_ event: NSEvent, line: DiffLineClickEvent) -> DiffTokenClickEvent? {
        let point = convert(event.locationInWindow, from: nil)
        guard line.lineRect.contains(point), let document, let row = row(at: point),
              let index = line.annotationSide == .deletions ? row.oldIndex : row.newIndex,
              let position = textPosition(at: point, row: row, side: line.annotationSide) else { return nil }
        let key = line.annotationSide.rawValue + ":" + String(index)
        let tokenIndex: TokenInteractionIndex
        if let cached = tokenIndices[key] { tokenIndex = cached }
        else if let oversizedTokenIndex, oversizedTokenIndex.key == key { tokenIndex = oversizedTokenIndex.index }
        else {
            metrics.tokenIndexesBuilt += 1
            let lines = line.annotationSide == .deletions ? document.diff.deletionLines : document.diff.additionLines
            let tokens = line.annotationSide == .deletions ? document.oldTokens : document.newTokens
            let text = cleanLastNewline(lines[index])
            tokenIndex = .init(contents: tokens.indices.contains(index) ? tokens[index].map(\.content) : [], fallback: text)
            let units = tokenIndex.spans.last?.lineCharEnd ?? 0
            if units <= 262_144 {
                while !tokenIndexOrder.isEmpty && (tokenIndices.count >= 512 || tokenIndexUnits + units > 262_144) {
                    let oldest = tokenIndexOrder.removeFirst()
                    tokenIndexUnits -= tokenIndices.removeValue(forKey: oldest)?.spans.last?.lineCharEnd ?? 0
                }
                tokenIndices[key] = tokenIndex; tokenIndexOrder.append(key); tokenIndexUnits += units
            } else {
                oversizedTokenIndex = (key, tokenIndex)
                metrics.oversizedTokenIndexUTF16Units = units
            }
        }
        guard let token = tokenIndex.token(at: position.character, includeWhitespace: interactionHandlers.enableTokenInteractionsOnWhitespace) else { return nil }
        return .init(revision: document.id, fileDiff: document.diff, lineNumber: line.lineNumber, side: line.annotationSide,
                     lineCharStart: token.lineCharStart, lineCharEnd: token.lineCharEnd, tokenText: token.tokenText, view: self, event: event)
    }
    func visibleTokenRects(lineNumber: Int, side: DiffSide, range: NSRange, revision: UUID?) -> [NSRect] {
        guard let document, document.id == revision, let plan else { return [] }
        var result: [NSRect] = []
        for physicalIndex in visibleRows(y: visibleRect.minY, height: visibleRect.height) {
            let row = plan.rows[physicalIndex]
            guard (side == .deletions ? row.oldNumber : row.newNumber) == lineNumber,
                  let index = side == .deletions ? row.oldIndex : row.newIndex else { continue }
            let fragment = visibleFragment(row, side: side, index: index)
            let overlap = fragment.map { NSIntersectionRange(range, $0) } ?? range
            guard overlap.length > 0 else { continue }
            let shaped = styledLine(index: index, side: side, fragment: fragment, document: document)
            let key = side.rawValue + ":" + String(index) + (fragment.map { ":\($0.location):\($0.length)" } ?? "")
            let geometry: TokenLineGeometry
            if let cached = tokenGeometryCache[key] { geometry = cached }
            else {
                geometry = TokenLineGeometry(shaped)
                if cache[key] != nil { tokenGeometryCache[key] = geometry }
            }
            let columnX = visibleRect.minX + (options.diffStyle == .split && side == .additions ? columnWidth : 0)
            let horizontalFragment = (side == .deletions ? row.oldRange : row.newRange) == nil ? fragment?.location ?? 0 : 0
            let x = columnX + gutter - visibleRect.minX / (options.diffStyle == .split ? 2 : 1) + CGFloat(horizontalFragment) * monospaceAdvance
            let y = rowOrigin(physicalIndex)
            let clip = NSRect(x: columnX + gutter, y: y, width: max(0, columnWidth - gutter), height: options.lineHeight).intersection(visibleRect)
            for rect in geometry.rects(for: .init(location: overlap.location - (fragment?.location ?? 0), length: overlap.length), origin: .init(x: x, y: y), height: options.lineHeight) {
                let visible = rect.intersection(clip)
                if !visible.isNull && !visible.isEmpty { result.append(visible) }
            }
        }
        return result
    }
    private func textPosition(at point: NSPoint, row: DiffRow, side: DiffSide) -> TextPosition? {
        if row.kind == .editorCaret, side == .additions, let number = row.newNumber { return .init(line: number - 1, character: 0) }
        guard let document, let index = side == .additions ? row.newIndex : row.oldIndex,
              let number = side == .additions ? row.newNumber : row.oldNumber else { return nil }
        let sourceKey = side.rawValue + ":" + String(index)
        let source: NSString
        if let pointerSource, pointerSource.key == sourceKey { source = pointerSource.text }
        else {
            source = cleanLastNewline((side == .additions ? document.diff.additionLines : document.diff.deletionLines)[index]) as NSString
            pointerSource = (sourceKey, source); metrics.pointerSourcesBuilt += 1
        }
        let fragment = visibleFragment(row, side: side, index: index)
        let range = fragment ?? NSRange(location: 0, length: source.length)
        let line = styledLine(index: index, side: side, fragment: fragment, document: document)
        let columnX = visibleRect.minX + (options.diffStyle == .split && side == .additions ? columnWidth : 0)
        let horizontalFragment = (side == .deletions ? row.oldRange : row.newRange) == nil ? fragment?.location ?? 0 : 0
        let x = point.x - columnX - gutter + visibleRect.minX / (options.diffStyle == .split ? 2 : 1) - CGFloat(horizontalFragment) * monospaceAdvance
        let hit = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        var column = range.location + (hit == kCFNotFound ? (x <= 0 ? 0 : range.length) : min(range.length, max(0, hit)))
        if column < source.length { column = source.rangeOfComposedCharacterSequence(at: column).location }
        return .init(line: number - 1, character: column)
    }
    func setTextSelection(_ value: DiffTextSelection?) {
        textSelection = value
        if editor != nil {
            activeLine = value?.side == .additions ? value.map { $0.head.line + 1 } : nil
            activeLineOptions = .init(side: .additions, lineNumberOnly: value?.anchor != value?.head)
        }
        selection = value.map { .init(side: $0.side, startLine: $0.anchor.line + 1, endLine: $0.head.line + 1) }
    }
    private func row(at point: NSPoint) -> DiffRow? {
        guard point.y.isFinite, point.y >= 0, point.y < rowHeights.totalHeight else { return nil }
        let index = rowHeights.row(at: point.y)
        if predictionSpacers[index] != nil, point.y >= rowOrigin(index) + options.lineHeight { return nil }
        guard let rows = plan?.rows, rows.indices.contains(index) else { return nil }; return rows[index]
    }
    override func flagsChanged(with event: NSEvent) { editor?.predictionModifierChanged(event); super.flagsChanged(with: event) }
    override func keyDown(with event: NSEvent) {
        if let editor, editor.handleKeyEvent(event) { return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copy(nil); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" { selectAll(nil); return }
        if event.keyCode == 53 { cancelOperation(nil); return }
        if let textSelection, [123, 124, 125, 126].contains(event.keyCode) { moveTextSelection(textSelection, event: event); return }
        if event.keyCode == 125 || event.keyCode == 126 {
            guard let document else { return }
            let side = selection?.endSide ?? selection?.side ?? .additions
            let count = side == .additions ? document.diff.additionLines.count : document.diff.deletionLines.count
            let next = min(count, max(1, (selection?.endLine ?? 1) + (event.keyCode == 125 ? 1 : -1)))
            let extending = event.modifierFlags.contains(.shift)
            selection = .init(side: extending ? selection?.side ?? side : side,
                              startLine: extending ? selection?.startLine ?? next : next,
                              endLine: next, endSide: extending && (selection?.side ?? side) != side ? side : nil)
            if let index = plan?.rows.firstIndex(where: { (side == .additions ? $0.newNumber : $0.oldNumber) == next }) { scrollToVisible(NSRect(x: 0, y: rowOrigin(index), width: 1, height: options.lineHeight)) }
            return
        }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        pendingClick = nil; dragAnchor = nil; textDrag = false
        lineSelectionSession = false; pendingLineUnselect = false
        clearProposedLineSelection()
        setTextSelection(nil)
    }
    @objc func copy(_ sender: Any?) {
        if let editor, editor.hasEditableSelection { editor.copy(sender); return }
        let value = selectedText(); if !value.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    }
    @objc func paste(_ sender: Any?) { editor?.paste(sender) }
    @objc func cut(_ sender: Any?) { editor?.cut(sender) }
    @objc func undo(_ sender: Any?) { editor?.undo(sender) }
    @objc func redo(_ sender: Any?) { editor?.redo(sender) }
    @objc override func selectAll(_ sender: Any?) {
        if let editor, editor.hasEditableSelection { editor.selectAll(sender); return }
        textSelection = nil
        let side = selection?.side ?? .additions
        let numbers = plan?.rows.compactMap { side == .additions ? $0.newNumber : $0.oldNumber } ?? []
        if let start = numbers.min(), let end = numbers.max() { selection = .init(side: side, startLine: start, endLine: end) }
    }
    func selectedText() -> String {
        if let editor, editor.hasEditableSelection { return editor.selectedText }
        guard let document else { return "" }
        return textSelection?.text(in: document.diff) ?? selection?.text(in: document.diff) ?? ""
    }
    func editorPosition(at point: NSPoint) -> TextPosition? {
        guard let window else { return nil }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard let row = row(at: local) else { return nil }
        if options.diffStyle == .split && local.x < visibleRect.minX + columnWidth { return nil }
        return textPosition(at: local, row: row, side: .additions)
    }
    private func ensureEditorRowIndex() {
        guard predictionRows == nil, let plan else { return }
        var rows: [Int: [Int]] = [:]
        for index in plan.rows.indices {
            let row = plan.rows[index]
            if let number = row.newNumber, row.newIndex != nil || row.kind == .editorCaret { rows[number - 1, default: []].append(index) }
        }
        predictionRows = rows
    }
    private func editorLocalRect(_ position: TextPosition) -> NSRect? {
        ensureEditorRowIndex()
        guard let indexes = predictionRows?[position.line] else { return nil }
        if let ri = indexes.first(where: { plan?.rows[$0].kind == .editorCaret }) {
            return .init(x: visibleRect.minX + (options.diffStyle == .split ? columnWidth : 0) + gutter,
                         y: rowOrigin(ri), width: 1, height: options.lineHeight)
        }
        guard let document, let rows = plan?.rows,
              let ri = indexes.first(where: { ri in
                  let row = rows[ri]
                  guard row.newNumber == position.line + 1, row.newIndex != nil else { return false }
                  guard let range = row.newRange else { return true }
                  let length = cleanLastNewline(document.diff.additionLines[row.newIndex!]).utf16.count
                  return position.character >= range.location && (position.character < NSMaxRange(range) || position.character == length && NSMaxRange(range) == length)
              }), let index = rows[ri].newIndex else { return nil }
        let row = rows[ri], source = cleanLastNewline(document.diff.additionLines[index]) as NSString
        let fragment = visibleFragment(row, side: .additions, index: index)
        let range = fragment ?? NSRange(location: 0, length: source.length)
        let key = "additions:" + String(index) + (fragment.map { ":\($0.location):\($0.length)" } ?? "")
        let line = cache[key]?.0 ?? CTLineCreateWithAttributedString(NSAttributedString(string: source.substring(with: range), attributes: [.font: font]))
        let offset = position.character < range.location || position.character > NSMaxRange(range)
            ? CGFloat(position.character - range.location) * monospaceAdvance
            : CTLineGetOffsetForStringIndex(line, position.character - range.location, nil)
        let horizontal = row.newRange == nil ? CGFloat(fragment?.location ?? 0) * monospaceAdvance : 0
        let x = visibleRect.minX + (options.diffStyle == .split ? columnWidth : 0) + gutter
            - visibleRect.minX / (options.diffStyle == .split ? 2 : 1) + horizontal + offset
        return NSRect(x: x, y: rowOrigin(ri), width: 1, height: options.lineHeight)
    }
    func screenRect(for position: TextPosition) -> NSRect {
        guard let rect = editorLocalRect(position), let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }
    func revealEditorCaret(_ position: TextPosition) {
        if editorLocalRect(position) == nil, let document, !options.collapsed {
            var previousEnd = 0
            for (index, hunk) in document.diff.hunks.enumerated() {
                if position.line >= previousEnd && position.line < hunk.newBoundary {
                    expandedRegions[index, default: .init()].fromEnd = max(expandedRegions[index]?.fromEnd ?? 0, hunk.newBoundary - position.line)
                    refreshExpansionLayout(); break
                }
                previousEnd = hunk.newBoundary + hunk.additionCount
            }
            if position.line >= previousEnd && position.line < document.diff.additionLines.count {
                let key = document.diff.hunks.count
                expandedRegions[key, default: .init()].fromStart = max(expandedRegions[key]?.fromStart ?? 0, position.line - previousEnd + 1)
                refreshExpansionLayout()
            }
        }
        guard let rect = editorLocalRect(position) else { return }
        scrollToVisible(NSRect(x: visibleRect.minX, y: rect.minY, width: 1, height: rect.height))
        inputContext?.invalidateCharacterCoordinates()
    }
    private var accessibleSource: NSString {
        if let editor, editor.hasEditableSelection { return editor.document.getText() as NSString }
        let side: DiffSide = selection?.side == .deletions ? .deletions : .additions
        if let cachedAccessibleSource, cachedAccessibleSource.side == side { return cachedAccessibleSource.text }
        let lines = side == .deletions ? document?.diff.deletionLines : document?.diff.additionLines
        let text = (lines?.joined() ?? "") as NSString
        // Retain only the queried side; replacement documents invalidate this snapshot.
        cachedAccessibleSource = (side, text)
        return text
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let document, let plan else { return nil }
        let documentID = document.id
        var result: [NSAccessibilityCustomAction] = []
        for index in visibleRows(y: visibleRect.minY, height: visibleRect.height) where plan.rows.indices.contains(index) {
            let row = plan.rows[index]
            if case .conflictMarker(_, .start) = row.kind, let conflict = row.conflictIndex {
                for (title, resolution, _) in conflictControls(y: rowOrigin(index)) {
                    result.append(NSAccessibilityCustomAction(name: "\(title.replacingOccurrences(of: " | ", with: "")) at conflict \(conflict + 1)", handler: { [weak self] in
                        guard let self, self.document?.id == documentID,
                              self.options.mergeConflictActionsType == .default,
                              let currentPlan = self.plan, currentPlan.rows.indices.contains(index),
                              currentPlan.rows[index].conflictIndex == conflict,
                              case .conflictMarker(_, .start) = currentPlan.rows[index].kind,
                              self.visibleRows(y: self.visibleRect.minY, height: self.visibleRect.height).contains(index),
                              let resolve = self.onResolveConflict else { return false }
                        resolve(conflict, resolution); return true
                    }))
                }
            }
            guard let data = row.hunkData(in: document.diff, type: .unified,
                expansionLineCount: options.expansionLineCount, canHydrateContext: canLoadPartial) else { continue }
            for (action, _) in separatorControls(row, y: rowOrigin(index)) {
                let name = "Expand \(action.rawValue) context at hunk \(data.hunkIndex + 1)"
                result.append(NSAccessibilityCustomAction(name: name, handler: { [weak self] in
                    guard let self, let current = self.document, current.id == documentID,
                          let currentPlan = self.plan, currentPlan.rows.indices.contains(index),
                          self.visibleRows(y: self.visibleRect.minY, height: self.visibleRect.height).contains(index),
                          currentPlan.rows[index].hunkData(in: current.diff, type: .unified,
                            expansionLineCount: self.options.expansionLineCount, canHydrateContext: self.canLoadPartial) == data,
                          self.separatorControls(currentPlan.rows[index], y: self.rowOrigin(index)).contains(where: { $0.0 == action }) else { return false }
                    let direction: ExpansionDirection = action == .up ? .up : action == .down ? .down : .both
                    self.onExpand?(data.hunkIndex, action == .all ? data.lines : self.options.expansionLineCount, direction)
                    return true
                }))
            }
        }
        return result.isEmpty ? nil : result
    }
    override func accessibilityValue() -> Any? { accessibleSource }
    override func accessibilitySelectedText() -> String? { selectedText() }
    override func accessibilityNumberOfCharacters() -> Int { accessibleSource.length }
    override func accessibilityString(for range: NSRange) -> String? {
        let source = accessibleSource as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length, range.length <= source.length - range.location else { return nil }
        return source.substring(with: range)
    }
    private func moveTextSelection(_ value: DiffTextSelection, event: NSEvent) {
        guard let document, let plan else { return }
        let lines = value.side == .additions ? document.diff.additionLines : document.diff.deletionLines
        let numbered = Dictionary(plan.rows.compactMap { row -> (Int, Int)? in
            guard let number = value.side == .additions ? row.newNumber : row.oldNumber,
                  let index = value.side == .additions ? row.newIndex : row.oldIndex else { return nil }
            return (number - 1, index)
        }, uniquingKeysWith: { first, _ in first })
        let available = document.diff.isPartial ? numbered.keys.sorted() : Array(lines.indices)
        guard !available.isEmpty else { return }
        func text(_ line: Int) -> NSString {
            let index = document.diff.isPartial ? numbered[line] : line
            guard let index, lines.indices.contains(index) else { return "" }
            return cleanLastNewline(lines[index]) as NSString
        }
        var head = value.head
        if event.keyCode == 125 || event.keyCode == 126 {
            let current = available.firstIndex(of: head.line) ?? 0
            head.line = available[min(available.count - 1, max(0, current + (event.keyCode == 125 ? 1 : -1)))]
            head.character = min(head.character, text(head.line).length)
        } else {
            let source = text(head.line), right = event.keyCode == 124
            head.character = min(source.length, max(0, head.character))
            if event.modifierFlags.contains(.command) { head.character = right ? source.length : 0 }
            else if right && head.character < source.length { head.character = NSMaxRange(source.rangeOfComposedCharacterSequence(at: head.character)) }
            else if !right && head.character > 0 { head.character = source.rangeOfComposedCharacterSequence(at: head.character - 1).location }
            else if let current = available.firstIndex(of: head.line) {
                let next = current + (right ? 1 : -1)
                if available.indices.contains(next) { head.line = available[next]; head.character = right ? 0 : text(head.line).length }
            }
        }
        setTextSelection(.init(side: value.side, anchor: event.modifierFlags.contains(.shift) ? value.anchor : head, head: head))
        if let index = plan.rows.firstIndex(where: { (value.side == .additions ? $0.newNumber : $0.oldNumber) == head.line + 1 && !(($0.newRange ?? $0.oldRange).map { head.character >= NSMaxRange($0) } ?? false) }) {
            scrollToVisible(NSRect(x: visibleRect.minX, y: rowOrigin(index), width: 1, height: options.lineHeight))
        }
    }
}

/// SwiftUI adapter for the same AppKit viewport; it creates no view per code row.
public struct FileDiffView: NSViewRepresentable {
    public final class Coordinator {
        var gutterRenderer: DiffGutterRenderer?
        var annotationRenderer: DiffAnnotationRenderer?
    }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    public var conflictActionRenderer: DiffConflictActionRenderer?
    public var mergeConflictActions: [MergeConflictDiffAction]
    public var separatorRenderer: DiffSeparatorRenderer?
    public var gutterRenderer: DiffGutterRenderer?
    public var annotationRenderer: DiffAnnotationRenderer?
    /// Optional host-owned line selection. Pair with controlledSelection to
    /// accept proposals in onLineSelected without committing every drag update.
    public var selectedLines: Binding<LineSelection?>?
    /// Styling for the host-owned selectedLines binding.
    public var activeLineSide: DiffSide?
    public var lineNumberOnly: Bool
    public var interactionHandlers: DiffInteractionHandlers?
    public var onResolveConflict: ((Int, DiffResolution) -> Void)?
    public var headerRenderers: DiffHeaderRenderers?
    public var document: HighlightedDiff
    public var options: DiffRenderOptions
    public var annotations: [LineAnnotation]
    public var onSelectionChange: ((LineSelection?) -> Void)?
    public var markerRows: [MergeConflictMarkerRow]
    public var loadDiffFiles: DiffContentsLoader?
    public var onFilesLoaded: ((HighlightedDiff) -> Void)?
    public var onFileLoadError: ((any Error) -> Void)?
    public var onPostRender: ((NativeDiffView, PostRenderPhase) -> Void)?
    public init(document: HighlightedDiff, options: DiffRenderOptions = .init(), annotations: [LineAnnotation] = [], markerRows: [MergeConflictMarkerRow] = [], loadDiffFiles: DiffContentsLoader? = nil, onFilesLoaded: ((HighlightedDiff) -> Void)? = nil, onFileLoadError: ((any Error) -> Void)? = nil, onSelectionChange: ((LineSelection?) -> Void)? = nil, headerRenderers: DiffHeaderRenderers? = nil, interactionHandlers: DiffInteractionHandlers? = nil, selectedLines: Binding<LineSelection?>? = nil, activeLineSide: DiffSide? = nil, lineNumberOnly: Bool = false, annotationRenderer: DiffAnnotationRenderer? = nil, onResolveConflict: ((Int, DiffResolution) -> Void)? = nil, gutterRenderer: DiffGutterRenderer? = nil, separatorRenderer: DiffSeparatorRenderer? = nil, conflictActionRenderer: DiffConflictActionRenderer? = nil, mergeConflictActions: [MergeConflictDiffAction] = [], onPostRender: ((NativeDiffView, PostRenderPhase) -> Void)? = nil) {
        self.onPostRender = onPostRender
        self.conflictActionRenderer = conflictActionRenderer
        self.mergeConflictActions = mergeConflictActions
        self.separatorRenderer = separatorRenderer
        self.gutterRenderer = gutterRenderer
        self.onResolveConflict = onResolveConflict
        self.annotationRenderer = annotationRenderer
        self.selectedLines = selectedLines
        self.activeLineSide = activeLineSide; self.lineNumberOnly = lineNumberOnly
        self.interactionHandlers = interactionHandlers
        self.headerRenderers = headerRenderers
        self.document = document; self.options = options; self.annotations = annotations; self.markerRows = markerRows; self.onSelectionChange = onSelectionChange
        self.loadDiffFiles = loadDiffFiles; self.onFilesLoaded = onFilesLoaded; self.onFileLoadError = onFileLoadError
    }
    public func makeNSView(context: Context) -> NativeDiffView { NativeDiffView(frame: .zero) }
    public static func dismantleNSView(_ view: NativeDiffView, coordinator: Coordinator) { view.cleanUp() }
    public func updateNSView(_ view: NativeDiffView, context: Context) {
        view.onPostRender = onPostRender
        view.conflictActionRenderer = conflictActionRenderer
        view.mergeConflictActions = mergeConflictActions
        view.separatorRenderer = separatorRenderer
        if context.coordinator.gutterRenderer !== gutterRenderer {
            context.coordinator.gutterRenderer = gutterRenderer
            view.renderGutterUtility = gutterRenderer?.render
        }
        if context.coordinator.annotationRenderer !== annotationRenderer {
            context.coordinator.annotationRenderer = annotationRenderer
            view.renderAnnotation = annotationRenderer?.render
        }
        view.onResolveConflict = onResolveConflict
        view.interactionHandlers = interactionHandlers ?? .init()
        view.headerRenderers = headerRenderers ?? .init()
        view.onSelectionChange = onSelectionChange; view.onFilesLoaded = onFilesLoaded; view.onFileLoadError = onFileLoadError
        view.render(document, options: options, annotations: annotations, markerRows: markerRows)
        if let selectedLines, view.selectedLines != selectedLines.wrappedValue || view.selectionHighlightSide != activeLineSide || view.selectionLineNumberOnly != lineNumberOnly {
            view.selectLines(selectedLines.wrappedValue, notify: false, activeLineSide: activeLineSide, lineNumberOnly: lineNumberOnly)
        }
        view.loadDiffFiles = loadDiffFiles
    }
}

@MainActor private final class DiffScrollView: NSScrollView {
    var forwardScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if let forwardScroll, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) { forwardScroll(event) }
        else { super.scrollWheel(with: event) }
    }
}

@MainActor private final class DiffGutterButton: NSView {
    weak var owner: DiffCanvas?
    var fillColor = NSColor.controlAccentColor
    var symbolColor = NSColor.textBackgroundColor
    override var isFlipped: Bool { true }
    var size: CGFloat = 20
    override var intrinsicContentSize: NSSize { .init(width: size, height: size) }
    init(owner: DiffCanvas) {
        self.owner = owner; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("Add comment on selected lines")
    }
    required init?(coder: NSCoder) { fatalError("Use init(owner:)") }
    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        DiffSymbol.plus.draw(in: .init(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16), color: symbolColor)
    }
    override func mouseDown(with event: NSEvent) { owner?.beginGutterSelection() }
    override func mouseDragged(with event: NSEvent) { owner?.dragGutterSelection(with: event) }
    override func mouseUp(with event: NSEvent) { owner?.finishGutterSelection(with: event) }
    override func accessibilityPerformPress() -> Bool {
        guard let owner else { return false }
        owner.beginGutterSelection(); owner.finishGutterSelection(); return true
    }
}

#endif

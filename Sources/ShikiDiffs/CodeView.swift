#if os(macOS)
import AppKit
import SwiftUI
import QuartzCore

public enum CodeViewScrollBehavior: Sendable { case instant, smooth, smoothAuto }

@MainActor private final class ReviewScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

@MainActor private final class ReviewScrollFrameTarget: NSObject {
    weak var owner: NativeCodeView?
    init(_ owner: NativeCodeView) { self.owner = owner }
    @available(macOS 14.0, *)
    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.advanceSmoothScroll(timestamp: link.timestamp * 1000)
    }
    /// macOS 13 has no view display links; a common-mode timer stands in.
    @objc func timerTick(_ timer: Timer) {
        guard let owner else { timer.invalidate(); return }
        owner.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000)
    }
}

/// Drives smooth scrolling frames: a display link where available.
@MainActor private final class ReviewScrollFrameDriver {
    private let stop: () -> Void
    init(view: NSView, target: ReviewScrollFrameTarget) {
        if #available(macOS 14.0, *) {
            let link = view.displayLink(target: target, selector: #selector(ReviewScrollFrameTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            stop = { link.invalidate() }
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, target: target,
                              selector: #selector(ReviewScrollFrameTarget.timerTick(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            stop = { timer.invalidate() }
        }
    }
    func invalidate() { stop() }
}

/// A prepared diff with a caller-owned review identity.
public struct CodeViewItem: Sendable {
    public var id: String
    public var document: HighlightedDiff
    public var annotations: [LineAnnotation]
    public var file: FileContents?
    /// Per-item collapse; nil retains the review-wide setting.
    public var collapsed: Bool?
    /// Requests a review-owned editor when createEditor is configured.
    public var edit: Bool
    public var fileAnnotations: [FileLineAnnotation]? {
        file == nil ? nil : annotations.map(FileLineAnnotation.init(rendered:))
    }
    public init(id: String, document: HighlightedDiff, annotations: [LineAnnotation] = [], file: FileContents? = nil, collapsed: Bool? = nil, edit: Bool = false) {
        self.id = id; self.document = document; self.annotations = annotations; self.file = file; self.collapsed = collapsed; self.edit = edit
    }
    /// A prepared single-file item with side-less comments.
    public init(id: String, document: HighlightedDiff, file: FileContents, fileAnnotations: [FileLineAnnotation], collapsed: Bool? = nil, edit: Bool = false) {
        self.init(id: id, document: document, annotations: fileAnnotations.map(\.renderedAnnotation), file: file, collapsed: collapsed, edit: edit)
    }
}
public enum CodeViewItemError: Error { case duplicateID(String), invalidEditorFactory, unknownInstance }
public enum CodeViewEditDecision: Sendable { case accept, reject }

@MainActor private final class ReviewEditorOwnership {
    var item: CodeViewItem
    init(_ item: CodeViewItem) { self.item = item }
}

/// A snapshot of a mounted review item. Retaining this value retains its native
/// view; query again after scrolling or item updates for the current mounted set.
@MainActor public struct CodeViewRenderedItem {
    public let item: CodeViewItem
    public let instance: NativeDiffView
    public var id: String { item.id }
    public var version: UUID { item.document.id }
    public var isFile: Bool { item.file != nil }
}

/// A review selection addressed by the caller's exact item identity.
public struct CodeViewLineSelection: Sendable, Equatable {
    public var id: String
    public var range: LineSelection
    public init(id: String, range: LineSelection) { self.id = id; self.range = range }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf16.elementsEqual(rhs.id.utf16) && lhs.range == rhs.range
    }
}

public enum CodeViewScrollAlignment: String, CaseIterable, Sendable { case start, center, end, nearest }

/// Spacing around and between files in a review, in logical points.
public struct CodeViewLayout: Equatable, Sendable {
    public var paddingTop: CGFloat
    public var paddingBottom: CGFloat
    public var gap: CGFloat
    public init(paddingTop: CGFloat = 8, paddingBottom: CGFloat = 8, gap: CGFloat = 8) {
        self.paddingTop = paddingTop; self.paddingBottom = paddingBottom; self.gap = gap
    }
}

/// Virtualizes an entire review containing many files. Prefix offsets support
/// logarithmic file lookup; only files intersecting the destination viewport are mounted.
@MainActor public final class NativeCodeView: NSView {
    public let scrollView: NSScrollView = ReviewScrollView()
    var reducedMotionPreference: () -> Bool = { prefersReducedMotion() }
    public var stickyHeaders = false {
        didSet { if stickyHeaders != oldValue { updateVisibleFiles() } }
    }
    public var smoothScrollSettings = SmoothScrollSettings() {
        didSet { if !smoothScrollSettings.isValid { cancelScrollAnimation() } }
    }
    private var scrollSpring: ScrollSpring?
    private var smoothDestination: CGFloat = 0
    private var smoothFileSource: UUID?
    private var smoothFileIndex: Int?
    private var smoothRangeTarget: (first: Int, last: Int, range: LineSelection, alignment: CodeViewScrollAlignment, offset: CGFloat, revision: UUID, generation: Int)?
    private var scrollDisplayLink: ReviewScrollFrameDriver?
    private var applyingAnimationFrame = false
    private var applyingScrollLayout = false
    private var scrollAnimationRevision = 0
    public var isAnimatingScroll: Bool { scrollSpring != nil }
    public func cancelScrollAnimation() {
        scrollAnimationRevision &+= 1
        scrollDisplayLink?.invalidate(); scrollDisplayLink = nil; scrollSpring = nil
        smoothFileSource = nil; smoothFileIndex = nil; smoothRangeTarget = nil
    }
    /// Navigate to an absolute review offset. Smooth retargeting retains velocity.
    /// In-range targets account for sticky headers; out-of-range targets clamp
    /// directly to the document boundary, matching upstream position targets.
    public func scrollTo(top: CGFloat, behavior: CodeViewScrollBehavior = .instant) {
        guard top.isFinite else { return }
        let clamped = min(max(0, top), max(0, host.bounds.height - scrollView.contentSize.height))
        let inset = stickyHeaders && !documents.isEmpty && clamped == top
            ? headerHeight(lowerFile(at: top)) : 0
        scrollToResolvedTop(clamped - inset, behavior: behavior)
    }
    private func scrollToResolvedTop(_ top: CGFloat, behavior: CodeViewScrollBehavior) {
        guard top.isFinite else { return }
        smoothFileSource = nil; smoothFileIndex = nil; smoothRangeTarget = nil
        scrollAnimationRevision &+= 1
        pendingLineNavigation = nil; resizeAnchor = nil; navigationRevision &+= 1
        let destination = min(max(0, top), max(0, host.bounds.height - scrollView.contentSize.height))
        let settings = smoothScrollSettings
        let animate = !reducedMotionPreference() && (behavior == .smooth ||
            behavior == .smoothAuto && abs(destination - scrollTop) <= scrollView.contentSize.height * 10)
        guard animate, window != nil, settings.isValid else {
            cancelScrollAnimation()
            scrollView.contentView.scroll(to: .init(x: 0, y: destination))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            updateVisibleFiles()
            return
        }
        smoothDestination = destination
        if scrollSpring == nil {
            scrollSpring = .init(position: scrollTop, lastTimestamp: CACurrentMediaTime() * 1000)
            scrollDisplayLink = ReviewScrollFrameDriver(view: self, target: ReviewScrollFrameTarget(self))
        }
    }
    func advanceSmoothScroll(timestamp: Double) {
        guard var spring = scrollSpring else { return }
        if isPreparingWrappedLayout {
            // Keep velocity, but do not integrate time against obsolete rows.
            spring.lastTimestamp = timestamp; scrollSpring = spring
            return
        }
        let revision = scrollAnimationRevision
        if let source = smoothFileSource {
            let cached = smoothFileIndex.flatMap { documents.indices.contains($0) && documents[$0].sourceID == source ? $0 : nil }
            guard let index = cached ?? documents.firstIndex(where: { $0.sourceID == source }) else { cancelScrollAnimation(); return }
            smoothFileIndex = index
            smoothDestination = fileOffset(index)
            if let target = smoothRangeTarget {
                guard documents[index].id == target.revision, generation == target.generation else { cancelScrollAnimation(); return }
                let heights = mounted[index]?.measuredRowHeights ?? retainedHeights[index]?.heights
                let top = heights?.origin(of: target.first) ?? CGFloat(target.first) * options.lineHeight
                let bottom = heights?.origin(of: target.last + 1) ?? CGFloat(target.last + 1) * options.lineHeight
                let height = bottom - top, viewport = scrollView.contentView.bounds.height
                smoothDestination += headerHeight(index) + top
                if target.alignment == .center && height + target.offset < viewport {
                    smoothDestination += -(viewport - height) / 2 + target.offset
                } else if target.alignment == .end {
                    smoothDestination += -(viewport - height) + target.offset
                } else { smoothDestination -= target.offset + (stickyHeaders ? headerHeight(index) : 0) }
            }
        }
        let destination = min(max(0, smoothDestination), max(0, host.bounds.height - scrollView.contentSize.height))
        let settled = spring.advance(to: destination, timestamp: timestamp, settings: smoothScrollSettings)
        guard spring.position.isFinite, spring.velocity.isFinite else { cancelScrollAnimation(); return }
        scrollSpring = spring
        applyingAnimationFrame = true
        scrollView.contentView.scroll(to: .init(x: 0, y: spring.position))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateVisibleFiles()
        applyingAnimationFrame = false
        if settled && scrollAnimationRevision == revision { cancelScrollAnimation() }
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelScrollAnimation() }
    }
    /// Extra logical points of file mounting on either side of the viewport.
    /// Zero preserves viewport-only mounting; hidden neighboring files are prepared
    /// within this bounded window when a host opts into overscroll.
    public var overscrollSize: CGFloat = 0 {
        didSet { if overscrollSize != oldValue { updateVisibleFiles() } }
    }
    public var reviewHeader: NSView? {
        didSet { if reviewHeader !== oldValue { oldValue?.removeFromSuperview(); if let reviewHeader { host.addSubview(reviewHeader) }; invalidateReviewChromeLayout() } }
    }
    public var reviewFooter: NSView? {
        didSet { if reviewFooter !== oldValue { oldValue?.removeFromSuperview(); if let reviewFooter { host.addSubview(reviewFooter) }; invalidateReviewChromeLayout() } }
    }
    /// Call when review-level content changes its preferred height.
    public func invalidateReviewChromeLayout() { chromeDirty = true; needsLayout = true }
    private var chromeDirty = true
    private var chromeWidth: CGFloat?
    private var reviewHeaderHeight: CGFloat = 0
    private var reviewFooterHeight: CGFloat = 0
    private let host = CodeHost()
    private var documents: [HighlightedDiff] = []
    private var items: [CodeViewItem] = []
    private var itemIndices: [[UInt16]: Int] = [:]
    private var itemSources: [[UInt16]: UUID] = [:]
    private var itemPresentationChanged = false
    private func resolvedOptions(at index: Int, base: DiffRenderOptions) -> DiffRenderOptions {
        var resolved = base
        if items.indices.contains(index), let collapsed = items[index].collapsed { resolved.collapsed = collapsed }
        if items.indices.contains(index), items[index].file != nil {
            resolved.diffStyle = .unified; resolved.expandUnchanged = true
        }
        return resolved
    }
    /// Shared lifecycle callback for caller-identified review items.
    public var onPostRender: ((CodeViewRenderedItem, PostRenderPhase) -> Void)?
    public var onItemsChange: (([CodeViewItem]) -> Void)?
    private var itemEditors: [UUID: DiffEditor] = [:]
    /// Called lazily for a mounted, expanded item whose edit flag is true.
    /// Return an editor attached to the provided view via beginEditing().
    public var getEditStateKey: ((CodeViewItem) -> String?)?
    public var createEditor: ((NativeDiffView, CodeViewItem, String?) throws -> DiffEditor)? {
        didSet { updateVisibleFiles() }
    }
    public var onItemEditChange: ((TextDocumentChange, CodeViewItem, DiffEditor) -> Void)?
    /// Defaults to reject. Accepted prepared items arrive through onItemsChange.
    public var onItemEditComplete: ((DiffEditCompletion, CodeViewItem, DiffEditor) -> CodeViewEditDecision)?
    public var onItemEditError: ((any Error, CodeViewItem) -> Void)?
    private var managedEditors: [UUID: ReviewEditorOwnership] = [:]
    private var editCompletionTasks: [UUID: Task<Void, Never>] = [:]
    private var editTeardownTasks: [UUID: Task<Void, Never>] = [:]
    private func currentItem(for source: UUID) -> CodeViewItem? {
        guard let key = itemSources.first(where: { $0.value == source })?.key,
              let index = itemIndices[key] else { return nil }
        return items[index]
    }
    private func attachManagedEditor(to view: NativeDiffView, at index: Int) {
        guard items.indices.contains(index), items[index].edit,
              !resolvedOptions(at: index, base: options).collapsed,
              let createEditor else { return }
        let source = documents[index].sourceID
        guard itemEditors[source] == nil, editCompletionTasks[source] == nil else { return }
        let item = items[index], revision = generation
        do {
            let editor = try createEditor(view, item, getEditStateKey?(item))
            guard view.attachedEditor === editor, editor.isActive else { throw CodeViewItemError.invalidEditorFactory }
            guard generation == revision, mounted[index] === view else { editor.suspend(); editor.abandon(); return }
            let ownership = ReviewEditorOwnership(item)
            managedEditors[source] = ownership; itemEditors[source] = editor
            editor.defaultCompletionAcceptance = false
            let previousChange = editor.onChange, previousError = editor.onError
            editor.onChange = { [weak self, weak editor] change in
                previousChange?(change)
                guard let self, let editor else { return }
                if let current = self.currentItem(for: source) { ownership.item = current }
                self.onItemEditChange?(change, ownership.item, editor)
            }
            editor.onError = { [weak self] error in
                previousError?(error)
                self?.onItemEditError?(error, ownership.item)
            }
            let completionHandler = onItemEditComplete
            editor.onEditComplete = { [weak self, weak editor] completion in
                guard let editor else { return false }
                if let current = self?.currentItem(for: source) { ownership.item = current }
                return (self?.onItemEditComplete ?? completionHandler)?(completion, ownership.item, editor) == .accept
            }
        } catch { onItemEditError?(error, item) }
    }
    private func syncManagedEditors() {
        for (source, ownership) in Array(managedEditors) {
            guard let item = currentItem(for: source), let editor = itemEditors[source] else { continue }
            ownership.item = item
            if item.edit { continue }
            guard editor.isActive, editCompletionTasks[source] == nil else { continue }
            editor.suspend()
            editCompletionTasks[source] = Task { [weak self, weak editor] in
                guard let self else { return }
                defer {
                    if let editor, !editor.isActive, self.itemEditors[source] === editor {
                        self.itemEditors.removeValue(forKey: source)
                        self.managedEditors.removeValue(forKey: source)
                    }
                    self.editCompletionTasks.removeValue(forKey: source)
                    self.updateVisibleFiles()
                }
                guard let item = self.currentItem(for: source) else { return }
                do { _ = try await self.completeEditingItem(item.id) }
                catch DiffEditorError.detached { /* A newer source/removal owns the result. */ }
                catch is CancellationError { }
                catch { /* DiffEditor already reports through its error callback. */ }
            }
        }
    }
    /// Waits for completions requested by edit=false, without polling view state.
    public func waitForPendingEdits() async {
        while !editCompletionTasks.isEmpty || !editTeardownTasks.isEmpty {
            let pending = Array(editCompletionTasks.values) + Array(editTeardownTasks.values)
            for task in pending { await task.value }
        }
    }

    fileprivate weak var attachedController: CodeViewController?
    func dismantle() {
        attachedController?.detach(self)
        onItemsChange = nil; onSelectedLinesChange = nil; scrollListeners = [:]
        reset()
    }

    /// Clear review content and pending layout while retaining presentation configuration
    /// and subscriptions so the same native host can display a new review.
    public func reset() {
        cancelScrollAnimation()
        pendingLineNavigation = nil; resizeAnchor = nil
        navigationRevision += 1
        wrapTask?.cancel(); wrapTask = nil; wrapKey = nil; appliedWrapKey = nil; generation += 1
        appendWrapPrefix = nil
        retireEditors(except: [])
        render([], options: options, layout: reviewLayout)
        // An unmount callback may have installed a newer review.
        guard documents.isEmpty else { return }
        items = []; itemIndices = [:]; itemSources = [:]
        selections = [:]; pendingItemSelection = nil; expansions = [:]; retainedHeights = [:]; headerHeights = [:]
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Tear down presentation and subscriptions. The native NSView remains
    /// owned by its parent and can be configured and used again.
    public func cleanUp() {
        reset()
        // An unmount/completion callback may have installed a newer review.
        guard documents.isEmpty else { return }
        scrollListeners.removeAll(); reviewHeader = nil; reviewFooter = nil
    }
    public func setOptions(_ options: DiffRenderOptions?) throws {
        guard let options else { return }
        if !items.isEmpty { try setItems(items, options: options) }
        else { render(documents, options: options, annotations: annotations, layout: reviewLayout) }
    }

    public func getEditor(_ id: String) -> DiffEditor? {
        guard let source = itemSources[Array(id.utf16)], let editor = itemEditors[source], editor.isActive else { return nil }
        return editor
    }
    /// Start editing a review item, mounting only its destination viewport.
    public func beginEditingItem(_ id: String, highlighter: DiffHighlighter = DiffHighlighter(), diffOptions: DiffOptions = .init(), editStateKey: String? = nil, stateManager: EditStateManager = .shared) throws -> DiffEditor {
        guard let index = itemIndices[Array(id.utf16)], let source = itemSources[Array(id.utf16)] else { throw DiffEditorError.missingDocument }
        if let editor = getEditor(id) { return editor }
        scrollToFile(at: index)
        guard let view = mounted[index] else { throw DiffEditorError.missingDocument }
        let editor = try view.beginEditing(highlighter: highlighter, diffOptions: diffOptions, editStateKey: editStateKey, stateManager: stateManager)
        editor.defaultCompletionAcceptance = true
        itemEditors[source] = editor
        if resolvedOptions(at: index, base: options).collapsed { editor.suspend() }
        return editor
    }
    /// Complete an editor without mounting its file. Accepted edits become the review item's revision.
    @discardableResult public func completeEditingItem(_ id: String, mode: DiffEditCompletionMode = .install) async throws -> DiffEditCompletion {
        guard let source = itemSources[Array(id.utf16)], let editor = getEditor(id),
              let originalItem = getItem(id) else { throw DiffEditorError.detached }
        let completion = try await editor.complete(mode)
        guard itemEditors[source] === editor, let key = itemSources.first(where: { $0.value == source })?.key,
              let index = itemIndices[key] else { throw DiffEditorError.detached }
        itemEditors.removeValue(forKey: source)
        let managed = managedEditors.removeValue(forKey: source) != nil
        // Host updates made during completion own the new revision, even when the
        // editor is offscreen and therefore has no attachment to invalidate.
        guard items[index].document.id == originalItem.document.id,
              items[index].annotations == originalItem.annotations,
              items[index].file == originalItem.file else { throw DiffEditorError.detached }
        if let prepared = editor.installedCompletionDocument {
            var next = items
            next[index].document = prepared; next[index].annotations = completion.annotations
            if managed { next[index].edit = false }
            if next[index].file != nil, let newFile = completion.newFile { next[index].file?.contents = newFile.contents }
            try setItems(next)
            onItemsChange?(items)
        } else if managed, items[index].edit {
            var next = items; next[index].edit = false
            try setItems(next); onItemsChange?(items)
        }
        return completion
    }
    private func retireEditors(except sources: Set<UUID>) {
        for source in Array(itemEditors.keys) where !sources.contains(source) {
            let editor = itemEditors.removeValue(forKey: source)
            if let item = currentItem(for: source) { managedEditors[source]?.item = item }
            managedEditors.removeValue(forKey: source)
            editor?.discardAfterRemoval()
            if let editor {
                editTeardownTasks[source] = Task { [weak self, editor] in
                    await editor.waitForTeardown()
                    self?.editTeardownTasks.removeValue(forKey: source)
                }
            }
        }
    }
    private var applyingItems = false
    private var navigationRevision = 0
    public func getItem(_ id: String) -> CodeViewItem? { itemIndices[Array(id.utf16)].map { items[$0] } }
    /// Mounted items in review order; this query never mounts additional views.
    public func getRenderedItems() -> [CodeViewRenderedItem] {
        mounted.keys.sorted().compactMap { index in
            guard items.indices.contains(index), let instance = mounted[index] else { return nil }
            return .init(item: items[index], instance: instance)
        }
    }
    /// Current logical top, including review padding and header, without mounting
    /// or scrolling the item. Estimates may settle as wrapped content is measured.
    public func getTopForItem(_ id: String) -> CGFloat? {
        itemIndices[Array(id.utf16)].map { fileOffset($0) }
    }
    /// Reconcile a review using exact UTF-16 IDs, matching JavaScript string identity.
    /// Duplicate IDs reject the entire update before changing the review.
    public func setItems(_ next: [CodeViewItem], options: DiffRenderOptions? = nil, layout: CodeViewLayout? = nil) throws {
        let previousSelection = getSelectedLines()
        var indices: [[UInt16]: Int] = [:], sources: [[UInt16]: UUID] = [:]
        var prepared: [HighlightedDiff] = [], notes: [Int: [LineAnnotation]] = [:]
        for (index, item) in next.enumerated() {
            let key = Array(item.id.utf16)
            guard indices[key] == nil else { throw CodeViewItemError.duplicateID(item.id) }
            indices[key] = index
            let source = itemSources[key] ?? UUID()
            sources[key] = source
            prepared.append(item.document.identifyingSource(as: source))
            if !item.annotations.isEmpty { notes[index] = item.annotations }
        }
        itemPresentationChanged = next.contains { item in
            guard let old = itemIndices[Array(item.id.utf16)] else { return false }
            return items[old].file != item.file || items[old].collapsed != item.collapsed
        }
        let queued = pendingLineNavigation
        let queuedKey = queued.flatMap { items.indices.contains($0.file) ? Array(items[$0.file].id.utf16) : nil }
        let revision = navigationRevision
        retireEditors(except: Set(sources.values))
        items = next; itemIndices = indices; itemSources = sources
        syncManagedEditors()
        applyingItems = true
        defer { applyingItems = false }
        render(prepared, options: options ?? self.options, annotations: notes, layout: layout ?? reviewLayout)
        updateVisibleFiles()
        if let pending = pendingItemSelection {
            pendingItemSelection = nil
            if let index = itemIndices[Array(pending.id.utf16)] {
                selectLines(pending.range, inFileAt: index, notify: false)
            }
        }
        if navigationRevision == revision, let queued, let key = queuedKey, let index = itemIndices[key] {
            scrollToRange(queued.range, inFileAt: index, align: queued.align, offset: queued.offset, behavior: queued.behavior)
        }
        // Publish only after reconciliation; hosts may replace the review here.
        applyingItems = false
        // Offscreen editors have no NativeDiffView to forward source updates.
        // Notify after reconciliation so a host callback can safely replace items.
        let reconciledGeneration = generation
        for (index, document) in documents.enumerated() {
            guard generation == reconciledGeneration else { return }
            if let editor = itemEditors[document.sourceID], editor.isSuspended {
                editor.receiveExternal(document, options: resolvedOptions(at: index, base: self.options), annotations: notes[index] ?? [])
            }
        }
        if previousSelection != nil && getSelectedLines() == nil { onSelectedLinesChange?(nil) }
    }
    public func addItems(_ additions: [CodeViewItem]) throws { try setItems(items + additions) }
    public func addItem(_ item: CodeViewItem) throws { try addItems([item]) }
    @discardableResult public func updateItem(_ item: CodeViewItem) throws -> Bool {
        guard let index = itemIndices[Array(item.id.utf16)] else { return false }
        var next = items; next[index] = item; try setItems(next); return true
    }
    @discardableResult public func removeItem(_ id: String) throws -> Bool {
        guard let index = itemIndices[Array(id.utf16)] else { return false }
        var next = items; next.remove(at: index); try setItems(next); return true
    }
    @discardableResult public func updateItemID(_ oldID: String, to newID: String) -> Bool {
        let old = Array(oldID.utf16), new = Array(newID.utf16)
        if old == new { return true }
        guard let index = itemIndices[old], itemIndices[new] == nil else { return false }
        let selected = getSelectedLines()
        items[index].id = newID
        itemIndices.removeValue(forKey: old); itemIndices[new] = index
        itemSources[new] = itemSources.removeValue(forKey: old)
        if let source = itemSources[new] { managedEditors[source]?.item = items[index] }
        if let view = mounted[index] { bindCallbacks(view, at: index) }
        if let selected, selected.id.utf16.elementsEqual(old) {
            if pendingItemSelection != nil { pendingItemSelection = .init(id: newID, range: selected.range) }
            onSelectedLinesChange?(.init(id: newID, range: selected.range))
        }
        return true
    }
    @discardableResult public func scrollToRange(_ range: LineSelection, inItem id: String, align: CodeViewScrollAlignment = .start, offset: CGFloat = 0, behavior: CodeViewScrollBehavior = .instant) -> Bool {
        guard let index = itemIndices[Array(id.utf16)] else { return false }
        return scrollToRange(range, inFileAt: index, align: align, offset: offset, behavior: behavior)
    }
    /// Select source lines in an existing item without mounting or scrolling to it.
    /// Returns false for an unknown ID and leaves the current selection unchanged.
    @discardableResult public func selectLines(_ selection: LineSelection?, inItem id: String, notify: Bool = true, activeLineSide: DiffSide? = nil, lineNumberOnly: Bool = false) -> Bool {
        guard let index = itemIndices[Array(id.utf16)] else { return false }
        selectLines(selection, inFileAt: index, notify: notify, activeLineSide: activeLineSide, lineNumberOnly: lineNumberOnly)
        return true
    }
    @discardableResult public func selectText(_ selection: DiffTextSelection?, inItem id: String) -> Bool {
        guard let index = itemIndices[Array(id.utf16)] else { return false }
        selectText(selection, inFileAt: index)
        return true
    }
    public func selectedText(inItem id: String) -> String {
        guard let index = itemIndices[Array(id.utf16)] else { return "" }
        return selectedText(inFileAt: index)
    }
    public var selectedItemLines: (id: String, range: LineSelection)? {
        guard let selection = selectedLines, items.indices.contains(selection.fileIndex) else { return nil }
        return (items[selection.fileIndex].id, selection.range)
    }

    private var identities: [UUID] = []
    private var annotations: [Int: [LineAnnotation]] = [:]
    private var options = DiffRenderOptions()
    private var reviewLayout = CodeViewLayout()
    private func fileOffset(_ index: Int) -> CGFloat { reviewLayout.paddingTop + reviewHeaderHeight + offsets[index] }
    private var totalHeight: CGFloat {
        reviewHeaderHeight + reviewFooterHeight + reviewLayout.paddingTop + (offsets.last ?? 0) - (documents.isEmpty ? 0 : reviewLayout.gap) + reviewLayout.paddingBottom
    }
    private var offsets = FileHeightIndex()
    private var headerHeights: [Int: CGFloat] = [:]
    private var headersChanged = false
    private var stagingHeaders = false
    public var headerRenderers = DiffHeaderRenderers() {
        didSet {
            headersChanged = true
            if !stagingHeaders { render(documents, options: options, annotations: annotations, layout: reviewLayout) }
        }
    }
    func stageHeaderRenderers(_ renderers: DiffHeaderRenderers) {
        guard !renderers.isEmpty || !headerRenderers.isEmpty else { return }
        stagingHeaders = true; headerRenderers = renderers; stagingHeaders = false
    }
    private func headerHeight(_ index: Int) -> CGFloat { options.disableFileHeader ? 0 : headerHeights[index] ?? DiffHeaderView.defaultHeight(options: resolvedOptions(at: index, base: options)) }
    public var fileHeaderRenderers = FileHeaderRenderers() {
        didSet {
            headersChanged = true
            if !stagingHeaders { render(documents, options: options, annotations: annotations, layout: reviewLayout) }
        }
    }
    func stageFileHeaderRenderers(_ renderers: FileHeaderRenderers) {
        guard !renderers.isEmpty || !fileHeaderRenderers.isEmpty else { return }
        stagingHeaders = true; fileHeaderRenderers = renderers; stagingHeaders = false
    }
    private func resolvedHeaders(at index: Int) -> DiffHeaderRenderers {
        if items.indices.contains(index), let file = items[index].file { return fileHeaderRenderers.adapting(file) }
        return headerRenderers
    }
    public var interactionHandlers = DiffInteractionHandlers() { didSet { refreshInteractionHandlers() } }
    /// Review-level selection events, including selected-item rename/removal.
    public var onSelectedLinesChange: ((CodeViewLineSelection?) -> Void)?
    public var fileInteractionHandlers = FileInteractionHandlers() { didSet { refreshInteractionHandlers() } }
    private func resolvedInteractions(at index: Int) -> DiffInteractionHandlers {
        var handlers = items.indices.contains(index) && items[index].file != nil
            ? fileInteractionHandlers.adapting(items[index].file!) : interactionHandlers
        guard items.indices.contains(index), let source = itemSources[Array(items[index].id.utf16)] else { return handlers }
        let callback = handlers.onLineSelected
        handlers.onLineSelected = { [weak self] range in
            guard let self, let key = self.itemSources.first(where: { $0.value == source })?.key,
                  let index = self.itemIndices[key] else { return }
            self.onSelectedLinesChange?(range.map { .init(id: self.items[index].id, range: $0) })
            callback?(range)
        }
        return handlers
    }
    private func refreshInteractionHandlers() {
        host.hoverEnabled = interactionHandlers.hasHoverHandlers || fileInteractionHandlers.hasHoverHandlers || gutterRenderer != nil
        if !host.hoverEnabled { lastPointerEvent = nil }
        for (index, view) in Array(mounted) { view.interactionHandlers = resolvedInteractions(at: index) }
    }
    public var gutterRenderer: CodeViewGutterRenderer? {
        didSet {
            guard oldValue !== gutterRenderer else { return }
            for view in Array(mounted.values) { installGutterRenderer(on: view) }
            refreshInteractionHandlers()
        }
    }
    private func installGutterRenderer(on view: NativeDiffView) {
        guard let renderer = gutterRenderer else { view.renderGutterUtility = nil; return }
        view.renderGutterUtility = { [weak self, weak view] read in
            renderer.render { [weak self, weak view] in
                guard let self, let view, let line = read(),
                      let index = self.mounted.first(where: { $0.value === view })?.key,
                      self.documents.indices.contains(index) else { return nil }
                let item = self.items.indices.contains(index) ? self.items[index] : nil
                return .init(itemID: item?.id, document: self.documents[index], file: item?.file,
                             lineNumber: line.lineNumber, side: item?.file == nil ? line.side : nil)
            }
        }
    }
    /// Custom annotation content is created only by mounted file views.
    public var separatorRenderer: DiffSeparatorRenderer? {
        didSet {
            guard separatorRenderer !== oldValue else { return }
            retainedHeights.removeAll()
            for view in Array(mounted.values) { view.separatorRenderer = separatorRenderer }
            updateVisibleFiles()
        }
    }
    public func invalidateSeparatorLayout() {
        measurementWidth = nil
        invalidateHeightsAfterWidthChange()
        for view in Array(mounted.values) { view.invalidateSeparatorLayout() }
        updateVisibleFiles()
    }
    public var annotationRenderer: DiffAnnotationRenderer? {
        didSet {
            guard annotationRenderer !== oldValue else { return }
            retainedHeights.removeAll()
            for view in Array(mounted.values) { view.renderAnnotation = annotationRenderer?.render }
            updateVisibleFiles()
        }
    }
    private var mounted: [Int: NativeDiffView] = [:]
    private var pendingLineNavigation: (range: LineSelection, file: Int, id: UUID, align: CodeViewScrollAlignment, offset: CGFloat, behavior: CodeViewScrollBehavior)?
    private var resizeAnchor: (file: Int, row: Int, offset: CGFloat)?
    private var measurementWidth: CGFloat?
    private var retainedHeights: [Int: (width: CGFloat, heights: RowHeightIndex)] = [:]
    private var expansions: [Int: [Int: HunkExpansionRegion]] = [:]
    private struct RetainedSelection { var lines: LineSelection?; var text: DiffTextSelection?; var highlightSide: DiffSide? = nil; var lineNumberOnly = false }
    private var selections: [Int: RetainedSelection] = [:]
    private var clearingPreviousSelection = false
    /// The review has one active selection, even when its file is unmounted.
    public var selectedLines: (fileIndex: Int, range: LineSelection)? {
        for (index, selection) in selections {
            if let lines = selection.lines { return (index, lines) }
            if let text = selection.text {
                return (index, .init(side: text.side, startLine: text.anchor.line + 1, endLine: text.head.line + 1))
            }
        }
        return nil
    }
    public func clearSelectedLines(notify: Bool = true) {
        pendingItemSelection = nil
        guard let selected = selectedLines else { return }
        selectLines(nil, inFileAt: selected.fileIndex, notify: notify)
    }
    private func clearOtherSelections(except index: Int) {
        pendingItemSelection = nil
        let previous = selections.keys.filter { $0 != index }
        clearingPreviousSelection = true
        defer { clearingPreviousSelection = false }
        for key in previous {
            selections.removeValue(forKey: key)
            mounted[key]?.selectLines(nil, notify: false)
        }
    }
    private var pendingItemSelection: CodeViewLineSelection?
    public func getSelectedLines() -> CodeViewLineSelection? {
        if let pendingItemSelection { return pendingItemSelection }
        guard let selected = selectedLines, items.indices.contains(selected.fileIndex) else { return nil }
        return .init(id: items[selected.fileIndex].id, range: selected.range)
    }
    /// Retains an absent target until the next item reconciliation, matching
    /// upstream setSelectedLines. The existing selectLines(inItem:) remains strict.
    public func setSelectedLines(_ selection: CodeViewLineSelection?, notify: Bool = true) {
        guard selection != getSelectedLines() else { return }
        clearSelectedLines(notify: selection == nil ? notify : false)
        guard let selection else { return }
        if let index = itemIndices[Array(selection.id.utf16)] {
            selectLines(selection.range, inFileAt: index, notify: notify)
        } else {
            pendingItemSelection = selection
        }
    }
    private var lastPointerEvent: NSEvent?
    private var observer: NotificationObservation?
    private var scrollListeners: [UUID: @MainActor (CGFloat, NativeCodeView) -> Void] = [:]
    /// Current vertical position in review coordinates.
    public var scrollTop: CGFloat { scrollView.contentView.bounds.minY }
    public func getScrollTop() -> CGFloat { scrollTop }
    public func getHeight() -> CGFloat { scrollView.contentSize.height }
    /// Logical content height, including review chrome, padding and file gaps.
    public func getScrollHeight() -> CGFloat { totalHeight }
    public func getLocalTopForInstance(_ instance: NativeDiffView) throws -> CGFloat {
        guard let index = mounted.first(where: { $0.value === instance })?.key else { throw CodeViewItemError.unknownInstance }
        return offsets[index]
    }
    private var windowSpecs = VirtualWindowSpecs(top: 0, bottom: 0)
    /// Last window used to reconcile mounted files, including overscroll.
    public func getWindowSpecs() -> VirtualWindowSpecs { windowSpecs }
    /// Observe native scroll changes. The returned closure cancels this registration.
    /// Registration does not invoke the listener or retain the view through cancellation.
    public func subscribeToScroll(_ listener: @escaping @MainActor (CGFloat, NativeCodeView) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        scrollListeners[id] = listener
        return { [weak self] in self?.scrollListeners.removeValue(forKey: id) }
    }
    private func notifyScroll() {
        guard !scrollListeners.isEmpty else { return }
        let top = scrollTop
        for id in Array(scrollListeners.keys) { scrollListeners[id]?(top, self) }
    }
    private var updating = false
    private var wrapTask: Task<Void, Never>?
    private var wrapKey: String?
    private var appliedWrapKey: String?
    private var generation = 0
    private var filePlans: [DiffRenderPlan] = []
    private var appendWrapPrefix: (count: Int, width: CGFloat)?
    public var isPreparingWrappedLayout: Bool { options.overflow == .wrap && !documents.isEmpty && (filePlans.count != documents.count || appliedWrapKey != wrapKey) }
    public var mountedFileCount: Int { mounted.count }
    public var fileCount: Int { documents.count }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        (scrollView as? ReviewScrollView)?.onUserScroll = { [weak self] in self?.cancelScrollAnimation() }
        scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true
        scrollView.documentView = host; scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        host.onPointer = { [weak self] event, inside in
            guard let self else { return }
            self.lastPointerEvent = inside ? event : nil
            if inside { self.refreshReviewHover() }
            else { for view in Array(self.mounted.values) { view.endHover(with: event) } }
        }
        observer = NotificationObservation(name: NSView.boundsDidChangeNotification, object: scrollView.contentView) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.applyingAnimationFrame && !self.applyingScrollLayout { self.cancelScrollAnimation() }
                self.updateVisibleFiles(); self.notifyScroll()
            }
        }
    }
    public required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    public override func layout() {
        // Preserve velocity through layout corrections. Wrapped targets pause
        // until source lines can be mapped into the replacement row plan.
        let revision = scrollAnimationRevision
        let oldTop = scrollTop
        let preserving = isAnimatingScroll
        let wasApplying = applyingScrollLayout
        if preserving { applyingScrollLayout = true }
        defer {
            applyingScrollLayout = wasApplying
            if preserving, revision == scrollAnimationRevision, !wasApplying {
                scrollSpring?.position += Double(scrollTop - oldTop)
            }
        }
        super.layout(); scrollView.frame = bounds
        measureReviewChrome()
        invalidateHeightsAfterWidthChange()
        host.setFrameSize(NSSize(width: scrollView.contentSize.width, height: max(scrollView.contentSize.height, totalHeight)))
        reviewHeader?.frame = .init(x: 0, y: 0, width: scrollView.contentSize.width, height: reviewHeaderHeight)
        reviewFooter?.frame = .init(x: 0, y: totalHeight - reviewFooterHeight, width: scrollView.contentSize.width, height: reviewFooterHeight)
        updateVisibleFiles(); scheduleWrappedLayout()
    }
    private func measureReviewChrome() {
        let width = scrollView.contentSize.width
        guard chromeDirty || chromeWidth != width else { return }
        chromeDirty = false; chromeWidth = width
        let top = scrollView.contentView.bounds.minY
        let followsFile = !documents.isEmpty && top >= fileOffset(0)
        let oldHeader = reviewHeaderHeight
        func measure(_ view: NSView?) -> CGFloat {
            guard let view else { return 0 }
            view.setFrameSize(.init(width: width, height: view.frame.height))
            view.layoutSubtreeIfNeeded()
            let intrinsic = view.intrinsicContentSize.height
            let fitting = intrinsic > 0 ? intrinsic : view.fittingSize.height
            let height = fitting > 0 ? fitting : view.frame.height
            return height.isFinite ? max(0, ceil(height)) : 0
        }
        reviewHeaderHeight = measure(reviewHeader); reviewFooterHeight = measure(reviewFooter)
        host.setFrameSize(.init(width: width, height: max(scrollView.contentSize.height, totalHeight)))
        if followsFile {
            scrollView.contentView.scroll(to: .init(x: 0, y: min(max(0, top + reviewHeaderHeight - oldHeader), max(0, host.frame.height - scrollView.contentSize.height))))
        }
    }
    private func invalidateHeightsAfterWidthChange() {
        let width = scrollView.contentSize.width
        guard width > 0, width != measurementWidth else { return }
        measurementWidth = width
        guard annotationRenderer != nil || separatorRenderer != nil, !documents.isEmpty else { return }
        let top = scrollView.contentView.bounds.minY
        let file = lowerFile(at: top), local = top - fileOffset(lowerFile(at: top))
        let header = headerHeight(file)
        let oldHeights = mounted[file]?.measuredRowHeights ?? retainedHeights[file]?.heights
        var newLocal = local
        var pendingAnchor: (file: Int, row: Int, offset: CGFloat)?
        if local >= header, let oldHeights, oldHeights.rowCount > 0 {
            let row = oldHeights.row(at: local - header)
            let withinRow = local - header - oldHeights.origin(of: row)
            pendingAnchor = (file, row, withinRow)
            newLocal = header + CGFloat(row) * options.lineHeight + min(withinRow, max(0, options.lineHeight - 1))
        }
        let affected = Set(retainedHeights.keys).union(mounted.keys)
        for index in affected where separatorRenderer != nil || !(annotations[index]?.isEmpty ?? true) {
            mounted[index]?.resetMeasuredAnnotationHeights()
            let height = mounted[index]?.contentHeight ?? DiffRenderPlan.estimatedHeight(documents[index].diff, options: resolvedOptions(at: index, base: options), expandedRegions: expansions[index] ?? [:], annotations: annotations[index] ?? [])
            offsets.update(index, height: height + headerHeight(index) + reviewLayout.gap)
        }
        retainedHeights.removeAll()
        host.setFrameSize(.init(width: width, height: max(scrollView.contentSize.height, totalHeight)))
        scrollView.contentView.scroll(to: .init(x: 0, y: min(max(0, fileOffset(file) + newLocal), max(0, host.frame.height - scrollView.contentSize.height))))
        resizeAnchor = pendingAnchor
    }
    public func render(_ documents: [HighlightedDiff], options: DiffRenderOptions = .init(), annotations: [Int: [LineAnnotation]] = [:], layout: CodeViewLayout = .init()) {
        let ids = documents.map(\.id)
        let sourceIDs = documents.map(\.sourceID)
        let oldSourceIDs = self.documents.map(\.sourceID)
        if !applyingItems && (ids != identities || sourceIDs != oldSourceIDs) {
            retireEditors(except: [])
            items = []; itemIndices = [:]; itemSources = [:]
            pendingItemSelection = nil
        }
        // An append must not discard local state in the unchanged visible prefix.
        if !self.documents.isEmpty, documents.count > self.documents.count,
           Array(ids.prefix(identities.count)) == identities, Array(sourceIDs.prefix(oldSourceIDs.count)) == oldSourceIDs, self.options == options,
           (options.overflow != .wrap || !isPreparingWrappedLayout), reviewLayout == layout, !headersChanged, !itemPresentationChanged,
           (0..<self.documents.count).allSatisfy({ self.annotations[$0] == annotations[$0] }) {
            let firstNew = self.documents.count
            if options.overflow == .wrap {
                appendWrapPrefix = (firstNew, scrollView.contentSize.width)
                generation += 1; wrapKey = nil
            }
            self.documents = documents; identities = ids; self.annotations = annotations
            for index in firstNew..<documents.count {
                let notes = annotations[index] ?? []
                let height = DiffRenderPlan.estimatedHeight(documents[index].diff, options: resolvedOptions(at: index, base: options), expandedRegions: [:], annotations: notes)
                offsets.append(max(0, height + headerHeight(index)) + reviewLayout.gap)
            }
            host.setFrameSize(.init(width: scrollView.contentSize.width, height: max(scrollView.contentSize.height, totalHeight)))
            needsLayout = true; layoutSubtreeIfNeeded()
            return
        }
        guard ids != identities || sourceIDs != oldSourceIDs || self.options != options || self.annotations != annotations || reviewLayout != layout || headersChanged || itemPresentationChanged else { return }
        let canReusePresentation = !headersChanged && !itemPresentationChanged && self.options == options
        var canReuseViews = canReusePresentation && options.overflow == .scroll
        let presentationChanged = itemPresentationChanged
        itemPresentationChanged = false
        headersChanged = false
        pendingLineNavigation = nil
        resizeAnchor = nil
        if !presentationChanged && ids == identities && sourceIDs == oldSourceIDs && self.options == options && self.annotations == annotations && reviewLayout == layout {
            for (index, view) in Array(mounted) { view.headerRenderers = resolvedHeaders(at: index) }
            updateVisibleFiles(); needsLayout = true
            return
        }
        let sameFiles = documents.map { $0.diff.cacheKey ?? $0.diff.name } == self.documents.map { $0.diff.cacheKey ?? $0.diff.name }
        // Source identity survives highlighting updates and file-list reordering.
        // Duplicate source IDs are ambiguous (the array API allows repeated documents).
        let oldGroups = Dictionary(grouping: self.documents.indices, by: { self.documents[$0].sourceID })
        let newGroups = Dictionary(grouping: documents.indices, by: { documents[$0].sourceID })
        var movedIndices: [Int: Int] = [:]
        for (id, oldIndices) in oldGroups {
            if oldIndices.count == 1, let newIndices = newGroups[id], newIndices.count == 1 {
                movedIndices[oldIndices[0]] = newIndices[0]
            }
        }
        if sameFiles && !applyingItems {
            let matchedSources = !movedIndices.isEmpty
            var usedDestinations = Set(movedIndices.values)
            for index in self.documents.indices where movedIndices[index] == nil && !usedDestinations.contains(index) {
                if !matchedSources || oldSourceIDs[index] == sourceIDs[index] {
                    movedIndices[index] = index
                    usedDestinations.insert(index)
                }
            }
        }
        let oldAnchor = !self.documents.isEmpty ? lowerFile(at: scrollView.contentView.bounds.minY) : nil
        let anchorFile = oldAnchor.flatMap { movedIndices[$0] }
        let anchorLocal = oldAnchor.map { scrollView.contentView.bounds.minY - fileOffset($0) } ?? 0
        var reorderedPlans: [DiffRenderPlan]?
        if canReusePresentation, options.overflow == .wrap, !isPreparingWrappedLayout,
           documents.count == self.documents.count, movedIndices.count == documents.count,
           !itemEditors.values.contains(where: { $0.isActive }),
           movedIndices.allSatisfy({ old, new in oldSourceIDs[old] == sourceIDs[new] && self.documents[old].id == documents[new].id && self.annotations[old] == annotations[new] }) {
            let reverse = Dictionary(uniqueKeysWithValues: movedIndices.map { ($0.value, $0.key) })
            reorderedPlans = documents.indices.map { filePlans[reverse[$0]!] }
            canReuseViews = true
        }
        var reusedViews: [Int: NativeDiffView] = [:]
        var reusedHeights: [Int: (width: CGFloat, heights: RowHeightIndex)] = [:]
        var reusedHeaderHeights: [Int: CGFloat] = [:]
        if canReuseViews {
            for (old, new) in movedIndices where oldSourceIDs[old] == sourceIDs[new] && self.documents[old].id == documents[new].id && self.annotations[old] == annotations[new] {
                if let view = mounted.removeValue(forKey: old) { reusedViews[new] = view }
                if let height = headerHeights[old] { reusedHeaderHeights[new] = height }
                if let cached = retainedHeights[old], cached.width == scrollView.contentSize.width { reusedHeights[new] = cached }
            }
        }
        selections = Dictionary(uniqueKeysWithValues: selections.compactMap { old, value in movedIndices[old].map { ($0, value) } })
        expansions = Dictionary(uniqueKeysWithValues: expansions.compactMap { old, value in movedIndices[old].map { ($0, value) } })
        self.documents = documents; identities = ids; self.options = options; self.annotations = annotations; self.reviewLayout = layout
        headerHeights = reusedHeaderHeights
        for (index, view) in reusedViews { headerHeights[index] = view.headerHeight(for: scrollView.contentSize.width) }
        appendWrapPrefix = nil
        generation += 1; wrapKey = nil; wrapTask?.cancel(); filePlans = []
        if let reorderedPlans {
            filePlans = reorderedPlans
            wrapKey = "\(generation):\(scrollView.contentSize.width)"
            appliedWrapKey = wrapKey
        }
        offsets = .init()
        for (index, document) in documents.enumerated() {
            let notes = annotations[index] ?? []
            let estimated = reorderedPlans.map { RowHeightIndex(rows: $0[index].rows, options: resolvedOptions(at: index, base: options)).totalHeight }
                ?? DiffRenderPlan.estimatedHeight(document.diff, options: resolvedOptions(at: index, base: options), expandedRegions: expansions[index] ?? [:], annotations: notes)
            offsets.append(max(0, (reusedViews[index]?.contentHeight ?? reusedHeights[index]?.heights.totalHeight ?? estimated) + headerHeight(index)) + reviewLayout.gap)
        }
        // Publish the reconciled map before unmount callbacks. A callback can
        // replace this review; it must find reusable views and attached editors
        // in the new map instead of trying to attach those editors a second time.
        let retiredViews = Array(mounted.values)
        retainedHeights = reusedHeights
        mounted = reusedViews
        for (index, view) in reusedViews { bindCallbacks(view, at: index) }
        let cleanupGeneration = generation
        for view in retiredViews { retireView(view) }
        guard generation == cleanupGeneration else { return }
        host.setFrameSize(.init(width: scrollView.contentSize.width, height: max(scrollView.contentSize.height, totalHeight)))
        if let anchorFile {
            let local = min(max(0, anchorLocal), max(0, offsets[anchorFile + 1] - offsets[anchorFile] - reviewLayout.gap - 1))
            let target = min(fileOffset(anchorFile) + local, max(0, host.bounds.height - scrollView.contentSize.height))
            scrollView.contentView.scroll(to: .init(x: 0, y: target))
        } else { scrollView.contentView.scroll(to: .zero) }
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    @discardableResult public func scrollToItem(_ id: String, behavior: CodeViewScrollBehavior = .instant) -> Bool {
        guard let index = itemIndices[Array(id.utf16)] else { return false }
        scrollToFile(at: index, behavior: behavior)
        return true
    }
    public func scrollToFile(at index: Int, behavior: CodeViewScrollBehavior = .instant) {
        guard documents.indices.contains(index) else { return }
        if behavior != .instant {
            let source = documents[index].sourceID
            scrollToResolvedTop(fileOffset(index), behavior: behavior)
            if isAnimatingScroll { smoothFileSource = source; smoothFileIndex = index }
            return
        }
        cancelScrollAnimation()
        navigationRevision &+= 1
        pendingLineNavigation = nil
        resizeAnchor = nil
        let y = min(fileOffset(index), max(0, host.bounds.height - scrollView.contentSize.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y)); scrollView.reflectScrolledClipView(scrollView.contentView)
        updateVisibleFiles()
    }
    /// Navigate to a represented source line without mounting intervening files.
    /// Hidden context targets its separator. Returns false for missing lines.
    /// Wrapping defers a valid target.
    @discardableResult public func scrollToLine(_ number: Int, side: DiffSide = .additions, inFileAt index: Int, align: CodeViewScrollAlignment = .start, offset: CGFloat = 0, behavior: CodeViewScrollBehavior = .instant) -> Bool {
        scrollToRange(.init(side: side, startLine: number, endLine: number), inFileAt: index, align: align, offset: offset, behavior: behavior)
    }
    /// Navigate to the union of both endpoint line spans, including reversed and cross-side ranges.
    @discardableResult public func scrollToRange(_ range: LineSelection, inFileAt index: Int, align: CodeViewScrollAlignment = .start, offset: CGFloat = 0, behavior: CodeViewScrollBehavior = .instant) -> Bool {
        guard documents.indices.contains(index), range.startLine > 0, range.endLine > 0, offset.isFinite else { return false }
        func endpointRows(_ plan: DiffRenderPlan) -> (Int, Int)? {
            let isFile = items.indices.contains(index) && items[index].file != nil
            if resolvedOptions(at: index, base: options).collapsed {
                // Upstream resolves a collapsed file to the zero-height point
                // below its header. Diff targets require a hunk to resolve a
                // source index; single-file targets accept any positive line.
                guard isFile || !documents[index].diff.hunks.isEmpty else { return nil }
                // The inclusive last row is one before the first: both span
                // boundaries are zero, including in the smooth-scroll driver.
                return (0, -1)
            }
            var target = range
            if isFile {
                let lineCount = documents[index].diff.additionLines.count
                if lineCount == 0 { return (0, -1) }
                // File targets have no diff side and clamp beyond EOF to the
                // final logical line, including all of its wrapped rows.
                target = .init(side: .additions, startLine: min(range.startLine, lineCount),
                               endLine: min(range.endLine, lineCount))
            }
            var first: Int?, last: Int?
            var foundStart = false, foundEnd = false
            for (index, row) in plan.rows.enumerated() {
                func represents(_ line: Int, side: DiffSide) -> Bool {
                    let number = side == .additions ? row.newNumber : row.oldNumber
                    let hidden = side == .additions ? row.hiddenNewLines : row.hiddenOldLines
                    return number == line || hidden?.contains(line) == true
                }
                let isStart = represents(target.startLine, side: target.side)
                let isEnd = represents(target.endLine, side: target.endSide ?? target.side)
                if isStart || isEnd {
                    if first == nil { first = index }
                    last = index
                    foundStart = foundStart || isStart
                    foundEnd = foundEnd || isEnd
                }
            }
            guard foundStart, foundEnd, let first, let last else { return nil }
            return (first, last)
        }
        if isPreparingWrappedLayout {
            let base = DiffRenderPlan(diff: documents[index].diff, options: resolvedOptions(at: index, base: options), expandedRegions: expansions[index] ?? [:], annotations: annotations[index] ?? [])
            guard endpointRows(base) != nil else { return false }
            cancelScrollAnimation()
            navigationRevision &+= 1
            pendingLineNavigation = (range, index, documents[index].id, align, offset, behavior)
            resizeAnchor = nil
            return true
        }
        let plan = filePlans.indices.contains(index) ? filePlans[index]
            : DiffRenderPlan(diff: documents[index].diff, options: resolvedOptions(at: index, base: options), expandedRegions: expansions[index] ?? [:], annotations: annotations[index] ?? [])
        guard let (row, lastRow) = endpointRows(plan) else { return false }
        if behavior == .instant { cancelScrollAnimation() }
        navigationRevision &+= 1
        pendingLineNavigation = nil
        resizeAnchor = nil
        let baselineHeights = RowHeightIndex(rows: plan.rows, options: resolvedOptions(at: index, base: options))
        if retainedHeights[index] == nil { retainedHeights[index] = (scrollView.contentSize.width, baselineHeights) }
        func geometry(_ measured: RowHeightIndex?) -> (top: CGFloat, height: CGFloat) {
            let heights = measured ?? baselineHeights
            let top = heights.origin(of: row)
            let bottom = heights.origin(of: lastRow + 1)
            return (fileOffset(index) + headerHeight(index) + top, bottom - top)
        }
        let initial = geometry(mounted[index]?.measuredRowHeights ?? retainedHeights[index]?.heights)
        let viewport = scrollView.contentView.bounds
        let stickyOffset = stickyHeaders ? headerHeight(index) : 0
        let visibleTop = viewport.minY + stickyOffset
        var alignment = align
        if alignment == .nearest {
            if initial.top - offset <= visibleTop && initial.top + initial.height + offset >= viewport.maxY { cancelScrollAnimation(); return true }
            if initial.top - offset < visibleTop { alignment = .start }
            else if initial.top + initial.height + offset > viewport.maxY { alignment = .end }
            else { cancelScrollAnimation(); return true }
        }
        func destination(_ geometry: (top: CGFloat, height: CGFloat)) -> CGFloat {
            let y: CGFloat
            if alignment == .center && geometry.height + offset < viewport.height {
                y = geometry.top - (viewport.height - geometry.height) / 2 + offset
            } else if alignment == .end { y = geometry.top - (viewport.height - geometry.height) + offset }
            else { y = geometry.top - offset - (stickyHeaders ? headerHeight(index) : 0) }
            return min(max(0, y), max(0, host.frame.height - scrollView.contentSize.height))
        }
        if behavior != .instant {
            scrollToResolvedTop(destination(initial), behavior: behavior)
            if isAnimatingScroll {
                smoothFileSource = documents[index].sourceID; smoothFileIndex = index
                smoothRangeTarget = (row, lastRow, range, alignment, offset, documents[index].id, generation)
            }
            return true
        }
        scrollView.contentView.scroll(to: .init(x: 0, y: destination(initial)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateVisibleFiles()
        if let view = mounted[index] {
            let corrected = destination(geometry(view.measuredRowHeights))
            if corrected != scrollView.contentView.bounds.minY {
                scrollView.contentView.scroll(to: .init(x: 0, y: corrected))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                updateVisibleFiles()
            }
        }
        return true
    }
    public func selectText(_ selection: DiffTextSelection?, inFileAt index: Int) {
        guard documents.indices.contains(index) else { return }
        if selection != nil { clearOtherSelections(except: index) }
        selections[index] = .init(text: selection); mounted[index]?.selectText(selection)
    }
    public func selectLines(_ selection: LineSelection?, inFileAt index: Int, notify: Bool = true, activeLineSide: DiffSide? = nil, lineNumberOnly: Bool = false) {
        guard documents.indices.contains(index) else { return }
        if selection != nil { clearOtherSelections(except: index) }
        let previous = selectedLines
        let changed = (previous?.fileIndex == index ? previous?.range : nil) != selection
        selections[index] = .init(lines: selection, highlightSide: activeLineSide, lineNumberOnly: lineNumberOnly)
        if let view = mounted[index] { view.selectLines(selection, notify: notify, activeLineSide: activeLineSide, lineNumberOnly: lineNumberOnly) }
        else if notify && changed { resolvedInteractions(at: index).onLineSelected?(selection) }
    }
    public func selectedText(inFileAt index: Int) -> String {
        guard documents.indices.contains(index), let selection = selections[index] else { return "" }
        return selection.text?.text(in: documents[index].diff) ?? selection.lines?.text(in: documents[index].diff) ?? ""
    }
    private func scheduleWrappedLayout() {
        guard options.overflow == .wrap, !documents.isEmpty, scrollView.contentSize.width > 0 else { return }
        let width = scrollView.contentSize.width
        let key = "\(generation):\(width)"
        guard key != wrapKey else { return }
        wrapKey = key; wrapTask?.cancel()
        let documents = documents, options = options, expansions = expansions, annotations = annotations
        let prefixCount = appendWrapPrefix?.width == width ? min(appendWrapPrefix?.count ?? 0, filePlans.count) : 0
        let prefixPlans = Array(filePlans.prefix(prefixCount))
        appendWrapPrefix = nil
        let font = options.fontName.flatMap { NSFont(name: $0, size: options.fontSize) } ?? NSFont.monospacedSystemFont(ofSize: options.fontSize, weight: .regular)
        let name = font.fontName
        let classicInset = 2 * ("M" as NSString).size(withAttributes: [.font: font]).width
        let itemOptions = documents.indices.map { resolvedOptions(at: $0, base: options) }
        wrapTask = Task { [weak self] in
            do {
                var plans = prefixPlans
                for index in prefixCount..<documents.count {
                    let document = documents[index]
                    let resolved = itemOptions[index]
                    let textWidth = max(1, width / (resolved.diffStyle == .split ? 2 : 1) - (resolved.disableLineNumbers ? 16 : 60) - (resolved.diffIndicators == .classic ? classicInset : 0) - 12)
                    try Task.checkCancellation()
                    plans.append(try await DiffWrapLayout.shared.layout(plan: DiffRenderPlan(diff: document.diff, options: resolved, expandedRegions: expansions[index] ?? [:], annotations: annotations[index] ?? []), diff: document.diff, width: textWidth, fontName: name, fontSize: options.fontSize))
                }
                guard let self, self.wrapKey == key else { return }
                let animationRevision = self.scrollAnimationRevision
                let wasApplying = self.applyingScrollLayout
                if self.isAnimatingScroll { self.applyingScrollLayout = true }
                defer { self.applyingScrollLayout = wasApplying }
                let top = self.scrollView.contentView.bounds.minY
                let file = self.lowerFile(at: top)
                let local = top - self.fileOffset(file)
                let header = self.headerHeight(file)
                let oldRows = self.filePlans.indices.contains(file) ? self.filePlans[file].rows : DiffRenderPlan(diff: documents[file].diff, options: itemOptions[file], expandedRegions: expansions[file] ?? [:], annotations: annotations[file] ?? []).rows
                let oldHeights = self.mounted[file]?.measuredRowHeights ?? self.retainedHeights[file]?.heights
                let row = oldHeights?.row(at: max(0, local - header)) ?? max(0, Int((local - header) / options.lineHeight))
                let anchor = oldRows.indices.contains(row) ? oldRows[row] : nil
                let rowOffset = max(0, local - header - (oldHeights?.origin(of: row) ?? CGFloat(row) * options.lineHeight))
                self.filePlans = plans; self.appliedWrapKey = key; self.offsets = .init()
                for (index, plan) in plans.enumerated() {
                    let retained = index < prefixCount ? self.mounted[index]?.contentHeight ?? self.retainedHeights[index]?.heights.totalHeight : nil
                    let height = retained ?? RowHeightIndex(rows: plan.rows, options: options).totalHeight
                    self.offsets.append(max(0, height + self.headerHeight(index)) + self.reviewLayout.gap)
                }
                let cleanupGeneration = self.generation
                for index in Array(self.mounted.keys) where index >= prefixCount {
                    self.removeMounted(index, retainHeights: false)
                    guard self.generation == cleanupGeneration else { return }
                }
                self.retainedHeights = self.retainedHeights.filter { $0.key < prefixCount }
                self.host.setFrameSize(NSSize(width: width, height: max(self.scrollView.contentSize.height, self.totalHeight)))
                var newTop = self.fileOffset(file) + min(local, header)
                var pendingAnchor: (file: Int, row: Int, offset: CGFloat)?
                if local >= header, let anchor, let target = plans[file].rows.firstIndex(where: { $0.matchesScrollAnchor(anchor) }) {
                    newTop = self.fileOffset(file) + header + CGFloat(target) * options.lineHeight + min(rowOffset, max(0, options.lineHeight - 1))
                    pendingAnchor = (file, target, rowOffset)
                }
                self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(newTop, max(0, self.host.bounds.height - self.scrollView.contentSize.height))))
                self.resizeAnchor = pendingAnchor
                self.updateVisibleFiles()
                if self.isAnimatingScroll, animationRevision == self.scrollAnimationRevision {
                    self.scrollSpring?.position += Double(self.scrollTop - top)
                    self.scrollSpring?.lastTimestamp = CACurrentMediaTime() * 1000
                    if let target = self.smoothRangeTarget, let source = self.smoothFileSource {
                        let cached = self.smoothFileIndex.flatMap { self.documents.indices.contains($0) && self.documents[$0].sourceID == source ? $0 : nil }
                        if let index = cached ?? self.documents.firstIndex(where: { $0.sourceID == source }),
                           self.documents[index].id == target.revision, self.generation == target.generation {
                            if !self.scrollToRange(target.range, inFileAt: index, align: target.alignment, offset: target.offset, behavior: .smooth) {
                                self.cancelScrollAnimation()
                            }
                        } else { self.cancelScrollAnimation() }
                    }
                }
                if let target = self.pendingLineNavigation {
                    self.pendingLineNavigation = nil
                    if self.documents.indices.contains(target.file), self.documents[target.file].id == target.id {
                        self.scrollToRange(target.range, inFileAt: target.file, align: target.align, offset: target.offset, behavior: target.behavior)
                    }
                }
            } catch { /* Superseded document/width jobs are cancelled. */ }
        }
    }
    private func lowerFile(at offset: CGFloat) -> Int {
        offsets.file(at: offset - reviewLayout.paddingTop - reviewHeaderHeight)
    }
    private func refreshReviewHover() {
        guard !updating, let lastPointerEvent else { return }
        let views = Array(mounted.values)
        let target = views.first { !$0.isHidden && $0.containsCodePointer(lastPointerEvent) }
        for view in views where view !== target { view.endHover(with: lastPointerEvent) }
        target?.refreshHover(with: lastPointerEvent)
    }
    private func bindCallbacks(_ view: NativeDiffView, at index: Int) {
        let snapshot = items.indices.contains(index) ? items[index] : nil
        view.presentationObserver = { [weak self, weak view] phase in
            guard let self, let view, let snapshot else { return }
            if phase == .unmount {
                self.onPostRender?(.init(item: snapshot, instance: view), phase)
            } else if self.mounted[index] === view, self.items.indices.contains(index) {
                self.onPostRender?(.init(item: self.items[index], instance: view), phase)
            }
        }

        view.onSelectionChange = { [weak self, weak view] lines in
            guard let self, !self.clearingPreviousSelection, let view, self.mounted[index] === view else { return }
            if lines != nil || view.selectedTextRange != nil { self.clearOtherSelections(except: index) }
            self.selections[index] = .init(lines: lines, text: view.selectedTextRange, highlightSide: view.selectionHighlightSide, lineNumberOnly: view.selectionLineNumberOnly)
        }
        let updateExpansions: () -> Void = { [weak self, weak view] in
            guard let self, let view, self.mounted[index] === view else { return }
            self.expansions[index] = view.getExpandedHunksMap()
            let newHeight = max(0, self.mounted[index]?.contentHeight ?? 0) + self.headerHeight(index) + self.reviewLayout.gap
            self.offsets.update(index, height: newHeight)
            if self.options.overflow == .wrap { self.generation += 1; self.wrapKey = nil; self.filePlans = [] }
            self.needsLayout = true; self.layoutSubtreeIfNeeded()
        }
        view.onExpansion = { _, _, _ in updateExpansions() }
        view.onExpansionStateChange = updateExpansions
        view.onHeaderLayoutChange = { [weak self, weak view] in
            guard let self, let view, self.mounted[index] === view, !self.updating, self.resizeAnchor == nil else { return }
            let top = self.scrollView.contentView.bounds.minY
            let file = self.lowerFile(at: top)
            guard let anchorView = self.mounted[file] else { return }
            let local = top - self.fileOffset(file) - self.headerHeight(file)
            let heights = anchorView.measuredRowHeights
            guard local >= 0, local < heights.totalHeight, heights.rowCount > 0 else { return }
            let row = heights.row(at: local)
            self.resizeAnchor = (file, row, local - heights.origin(of: row))
        }
        view.onLayoutChange = { [weak self] in
            self?.needsLayout = true
        }
    }
    private func removeMounted(_ index: Int, retainHeights: Bool = true) {
        guard let view = mounted.removeValue(forKey: index) else { return }
        if retainHeights, (annotationRenderer != nil && !(annotations[index]?.isEmpty ?? true)) || separatorRenderer != nil {
            retainedHeights[index] = (view.bounds.width, view.measuredRowHeights)
        }
        retireView(view)
    }
    private func retireView(_ view: NativeDiffView) {
        if let lastPointerEvent { view.endHover(with: lastPointerEvent) }
        view.cleanUp(recycle: true)
        view.presentationObserver = nil
        view.removeFromSuperview()
    }
    private func restoreResizeAnchor() {
        guard let anchor = resizeAnchor else { return }
        resizeAnchor = nil
        guard documents.indices.contains(anchor.file), let view = mounted[anchor.file] else { return }
        let heights = view.measuredRowHeights
        guard anchor.row < heights.rowCount else { return }
        let local = heights.origin(of: anchor.row) + min(max(0, anchor.offset), max(0, heights.height(of: anchor.row) - 1))
        let y = min(fileOffset(anchor.file) + headerHeight(anchor.file) + local,
                    max(0, host.frame.height - scrollView.contentSize.height))
        scrollView.contentView.scroll(to: .init(x: scrollView.contentView.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    private func updateVisibleFiles() {
        guard !updating else { return }
        guard !documents.isEmpty else { windowSpecs = .init(top: 0, bottom: 0); return }
        var geometryChanged = false
        var newMounts: [NativeDiffView] = []
        updating = true
        defer {
            updating = false
            if geometryChanged { updateVisibleFiles() } else { restoreResizeAnchor(); refreshReviewHover() }
            // Dispatch only after mounting/layout commits, so callbacks may
            // replace the review without invalidating the iteration above.
            for view in newMounts {
                guard let index = mounted.first(where: { $0.value === view })?.key,
                      items.indices.contains(index) else { continue }
                let callbackGeneration = generation
                onPostRender?(.init(item: items[index], instance: view), .mount)
                if generation != callbackGeneration { updateVisibleFiles() }
            }

        }
        let visible = scrollView.contentView.bounds
        let top = max(0, visible.minY)
        var bottom = min(totalHeight, top + visible.height)
        let window = createWindowFromScrollPosition(scrollTop: Double(top), height: Double(visible.height),
            scrollHeight: Double(totalHeight), overscrollSize: Double(overscrollSize.isFinite ? max(0, overscrollSize) : 0))
        windowSpecs = window
        let first = lowerFile(at: CGFloat(window.top)), last = lowerFile(at: CGFloat(window.bottom))
        let needed = Set(first...last)
        let cleanupGeneration = generation
        for index in Array(mounted.keys) where !needed.contains(index) {
            removeMounted(index)
            guard generation == cleanupGeneration else { geometryChanged = true; return }
        }
        for index in needed.sorted() {
            let view: NativeDiffView
            if let existing = mounted[index] { view = existing }
            else {
                view = NativeDiffView(frame: .zero)
                view.setReviewHeaderScrollOffset(0)
                view.separatorRenderer = separatorRenderer
                view.renderAnnotation = annotationRenderer?.render
                view.interactionHandlers = resolvedInteractions(at: index)
                view.headerRenderers = resolvedHeaders(at: index)
                view.forwardScroll = { [weak self] event in self?.scrollView.scrollWheel(with: event) }
                view.scrollView.hasVerticalScroller = false
                view.scrollView.hasHorizontalScroller = true
                if let file = items.indices.contains(index) ? items[index].file : nil {
                    view.stageFileHeader(file, renderers: resolvedHeaders(at: index))
                }
                var initialOptions = resolvedOptions(at: index, base: options)
                if options.overflow == .wrap && filePlans.count != documents.count { initialOptions.overflow = .scroll }
                view.render(documents[index], options: initialOptions, annotations: annotations[index] ?? [])
                view.setExpandedHunksMap(expansions[index] ?? [:])
                if filePlans.indices.contains(index) { view.installRenderPlan(filePlans[index]) }
                if let retained = retainedHeights[index], retained.width == visible.width {
                    view.restoreMeasuredRowHeights(retained.heights)
                }
                if let selected = selections[index] {
                    if let text = selected.text { view.selectText(text) } else { view.selectLines(selected.lines, notify: false, activeLineSide: selected.highlightSide, lineNumberOnly: selected.lineNumberOnly) }
                }
                bindCallbacks(view, at: index)
                host.addSubview(view); mounted[index] = view
                newMounts.append(view)
                let beforeRenderer = generation
                installGutterRenderer(on: view)
                guard generation == beforeRenderer, mounted[index] === view else {
                    geometryChanged = true; return
                }
                if !resolvedOptions(at: index, base: options).collapsed, let editor = itemEditors[documents[index].sourceID], editor.isActive {
                    do { try view.resumeEditing(editor) }
                    catch { editor.onError?(error) }
                }
            }
            let beforeEditor = generation
            attachManagedEditor(to: view, at: index)
            guard generation == beforeEditor, mounted[index] === view else { geometryChanged = true; return }
            let measured = view.headerHeight(for: visible.width)
            let measuredFileHeight = max(0, view.contentHeight + measured) + reviewLayout.gap
            if headerHeights[index] != measured || offsets[index + 1] - offsets[index] != measuredFileHeight {
                geometryChanged = true
                headerHeights[index] = measured
                offsets.update(index, height: measuredFileHeight)
                host.setFrameSize(.init(width: visible.width, height: max(visible.height, totalHeight)))
                bottom = min(totalHeight, top + visible.height)
                needsLayout = true
            }
            let fileTop = fileOffset(index), fileBottom = fileOffset(index + 1) - reviewLayout.gap
            let segmentTop = max(fileTop, top), segmentBottom = min(fileBottom, bottom)
            guard segmentBottom > segmentTop else { view.isHidden = true; continue }
            view.isHidden = false
            view.frame = NSRect(x: 0, y: segmentTop, width: visible.width, height: segmentBottom - segmentTop)
            let localY = max(0, segmentTop - fileTop)
            view.setReviewHeaderScrollOffset(stickyHeaders ? 0 : localY)
            view.layoutSubtreeIfNeeded()
            let codeY = stickyHeaders ? localY : max(0, localY - measured)
            view.scrollView.contentView.scroll(to: NSPoint(x: view.scrollView.contentView.bounds.minX, y: codeY))
            view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        }
    }
}
/// Retain this object to access the native review from SwiftUI actions.
@MainActor public final class CodeViewController {
    public private(set) weak var view: NativeCodeView?
    public init() {}
    func attach(_ view: NativeCodeView) { self.view = view; view.attachedController = self }
    func detach(_ view: NativeCodeView) { if self.view === view { self.view = nil } }
}

public struct CodeView: NSViewRepresentable {
    public var stickyHeaders = false
    public var reviewHeader: NSView?
    public var reviewFooter: NSView?
    public var reviewLayout: CodeViewLayout
    public var separatorRenderer: DiffSeparatorRenderer?
    public var gutterRenderer: CodeViewGutterRenderer?
    public var annotationRenderer: DiffAnnotationRenderer?
    public var overscrollSize: CGFloat
    public var annotations: [Int: [LineAnnotation]]
    public var interactionHandlers: DiffInteractionHandlers?
    public var headerRenderers: DiffHeaderRenderers?
    public var controller: CodeViewController?
    public var onItemsChange: (([CodeViewItem]) -> Void)?
    public var onSelectedLinesChange: ((CodeViewLineSelection?) -> Void)?
    public var items: [CodeViewItem]?
    public var fileHeaderRenderers: FileHeaderRenderers?
    public var fileInteractionHandlers: FileInteractionHandlers?
    /// Invalid item updates retain the previous review and report the error here.
    public var onItemError: ((any Error) -> Void)?
    public var getEditStateKey: ((CodeViewItem) -> String?)?
    public var createEditor: ((NativeDiffView, CodeViewItem, String?) throws -> DiffEditor)?
    public var onItemEditChange: ((TextDocumentChange, CodeViewItem, DiffEditor) -> Void)?
    public var onItemEditComplete: ((DiffEditCompletion, CodeViewItem, DiffEditor) -> CodeViewEditDecision)?
    public var onItemEditError: ((any Error, CodeViewItem) -> Void)?

    public var onPostRender: ((CodeViewRenderedItem, PostRenderPhase) -> Void)?
    public var documents: [HighlightedDiff]
    public var options: DiffRenderOptions
    public init(documents: [HighlightedDiff], options: DiffRenderOptions = .init(), headerRenderers: DiffHeaderRenderers? = nil, interactionHandlers: DiffInteractionHandlers? = nil, annotations: [Int: [LineAnnotation]] = [:], overscrollSize: CGFloat = 0, annotationRenderer: DiffAnnotationRenderer? = nil, layout: CodeViewLayout = .init(), reviewHeader: NSView? = nil, reviewFooter: NSView? = nil, stickyHeaders: Bool = false, gutterRenderer: CodeViewGutterRenderer? = nil, separatorRenderer: DiffSeparatorRenderer? = nil, onPostRender: ((CodeViewRenderedItem, PostRenderPhase) -> Void)? = nil, createEditor: ((NativeDiffView, CodeViewItem, String?) throws -> DiffEditor)? = nil, getEditStateKey: ((CodeViewItem) -> String?)? = nil, onItemEditChange: ((TextDocumentChange, CodeViewItem, DiffEditor) -> Void)? = nil, onItemEditComplete: ((DiffEditCompletion, CodeViewItem, DiffEditor) -> CodeViewEditDecision)? = nil, onItemEditError: ((any Error, CodeViewItem) -> Void)? = nil) {
        self.createEditor = createEditor; self.getEditStateKey = getEditStateKey; self.onItemEditChange = onItemEditChange
        self.onItemEditComplete = onItemEditComplete; self.onItemEditError = onItemEditError
        self.onPostRender = onPostRender
        self.separatorRenderer = separatorRenderer
        self.gutterRenderer = gutterRenderer
        self.reviewHeader = reviewHeader; self.reviewFooter = reviewFooter
        self.stickyHeaders = stickyHeaders
        self.reviewLayout = layout
        self.annotationRenderer = annotationRenderer
        self.overscrollSize = overscrollSize
        self.annotations = annotations
        self.interactionHandlers = interactionHandlers; self.documents = documents; self.options = options; self.headerRenderers = headerRenderers }
    public init(items: [CodeViewItem], options: DiffRenderOptions = .init(), headerRenderers: DiffHeaderRenderers? = nil, fileHeaderRenderers: FileHeaderRenderers? = nil, interactionHandlers: DiffInteractionHandlers? = nil, fileInteractionHandlers: FileInteractionHandlers? = nil, overscrollSize: CGFloat = 0, annotationRenderer: DiffAnnotationRenderer? = nil, layout: CodeViewLayout = .init(), reviewHeader: NSView? = nil, reviewFooter: NSView? = nil, onItemError: ((any Error) -> Void)? = nil, controller: CodeViewController? = nil, onItemsChange: (([CodeViewItem]) -> Void)? = nil, onSelectedLinesChange: ((CodeViewLineSelection?) -> Void)? = nil, stickyHeaders: Bool = false, gutterRenderer: CodeViewGutterRenderer? = nil, separatorRenderer: DiffSeparatorRenderer? = nil, onPostRender: ((CodeViewRenderedItem, PostRenderPhase) -> Void)? = nil, createEditor: ((NativeDiffView, CodeViewItem, String?) throws -> DiffEditor)? = nil, getEditStateKey: ((CodeViewItem) -> String?)? = nil, onItemEditChange: ((TextDocumentChange, CodeViewItem, DiffEditor) -> Void)? = nil, onItemEditComplete: ((DiffEditCompletion, CodeViewItem, DiffEditor) -> CodeViewEditDecision)? = nil, onItemEditError: ((any Error, CodeViewItem) -> Void)? = nil) {
        self.init(documents: [], options: options, headerRenderers: headerRenderers, interactionHandlers: interactionHandlers, overscrollSize: overscrollSize, annotationRenderer: annotationRenderer, layout: layout, reviewHeader: reviewHeader, reviewFooter: reviewFooter, stickyHeaders: stickyHeaders, gutterRenderer: gutterRenderer, separatorRenderer: separatorRenderer, onPostRender: onPostRender, createEditor: createEditor, getEditStateKey: getEditStateKey, onItemEditChange: onItemEditChange, onItemEditComplete: onItemEditComplete, onItemEditError: onItemEditError)
        self.controller = controller; self.onItemsChange = onItemsChange
        self.onSelectedLinesChange = onSelectedLinesChange
        self.items = items; self.fileHeaderRenderers = fileHeaderRenderers
        self.fileInteractionHandlers = fileInteractionHandlers; self.onItemError = onItemError
    }
    public func makeNSView(context: Context) -> NativeCodeView { NativeCodeView(frame: .zero) }
    public static func dismantleNSView(_ view: NativeCodeView, coordinator: ()) { view.dismantle() }
    public func updateNSView(_ view: NativeCodeView, context: Context) {
        view.onPostRender = onPostRender
        view.onItemEditChange = onItemEditChange; view.onItemEditComplete = onItemEditComplete
        view.onItemEditError = onItemEditError
        view.getEditStateKey = getEditStateKey; view.createEditor = createEditor
        view.stickyHeaders = stickyHeaders
        controller?.attach(view)
        view.onItemsChange = onItemsChange
        view.onSelectedLinesChange = onSelectedLinesChange
        view.reviewHeader = reviewHeader; view.reviewFooter = reviewFooter
        view.gutterRenderer = gutterRenderer
        view.separatorRenderer = separatorRenderer
        view.annotationRenderer = annotationRenderer
        view.interactionHandlers = interactionHandlers ?? .init()
        view.stageHeaderRenderers(headerRenderers ?? .init())
        view.stageFileHeaderRenderers(fileHeaderRenderers ?? .init())
        view.fileInteractionHandlers = fileInteractionHandlers ?? .init()
        if let items {
            do { try view.setItems(items, options: options, layout: reviewLayout) }
            catch { onItemError?(error) }
        } else {
            view.render(documents, options: options, annotations: annotations, layout: reviewLayout)
        }
        view.overscrollSize = overscrollSize
    }
}

@MainActor private final class CodeHost: NSView {
    override var isFlipped: Bool { true }
    var onPointer: ((NSEvent, Bool) -> Void)?
    var hoverEnabled = false { didSet { updateTrackingAreas() } }
    private var pointerArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverEnabled else {
            if let pointerArea { removeTrackingArea(pointerArea); self.pointerArea = nil }
            return
        }
        guard pointerArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        pointerArea = area; addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) { if hoverEnabled { onPointer?(event, true) } }
    override func mouseEntered(with event: NSEvent) { if hoverEnabled { onPointer?(event, true) } }
    override func mouseExited(with event: NSEvent) { if hoverEnabled { onPointer?(event, false) } }
    override func mouseDragged(with event: NSEvent) { if hoverEnabled { onPointer?(event, true) } }
}

#endif

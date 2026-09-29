#if os(macOS)
import AppKit
import SwiftUI

/// SwiftUI owner for a merge-conflict file. Unchanged input preserves internal resolutions.
/// To reset the same source explicitly, change the SwiftUI view's identity with `.id(...)`.
public struct UnresolvedFileView: NSViewRepresentable {
    public var file: FileContents
    public var options: DiffRenderOptions
    public var annotations: [LineAnnotation]
    public var maxContextLines: Int
    public var highlighter: DiffHighlighter?
    public var behavior: UnresolvedFileBehavior
    public var onPostRender: ((NativeUnresolvedFileView, PostRenderPhase) -> Void)?
    public var onError: ((any Error) -> Void)?
    public var headerRenderers: DiffHeaderRenderers?
    public var interactionHandlers: DiffInteractionHandlers?
    public var annotationRenderer: DiffAnnotationRenderer?
    public var gutterRenderer: DiffGutterRenderer?
    public var separatorRenderer: DiffSeparatorRenderer?
    public var conflictActionRenderer: DiffConflictActionRenderer?
    public var onSelectionChange: ((LineSelection?) -> Void)?
    public var selectedLines: Binding<LineSelection?>?
    public var activeLineSide: DiffSide?
    public var lineNumberOnly: Bool

    public init(file: FileContents, options: DiffRenderOptions = .init(), annotations: [LineAnnotation] = [],
                maxContextLines: Int = 6, highlighter: DiffHighlighter? = nil,
                behavior: UnresolvedFileBehavior = .automatic(), onError: ((any Error) -> Void)? = nil,
                headerRenderers: DiffHeaderRenderers? = nil, interactionHandlers: DiffInteractionHandlers? = nil,
                annotationRenderer: DiffAnnotationRenderer? = nil, gutterRenderer: DiffGutterRenderer? = nil,
                separatorRenderer: DiffSeparatorRenderer? = nil, conflictActionRenderer: DiffConflictActionRenderer? = nil,
                onSelectionChange: ((LineSelection?) -> Void)? = nil,
                selectedLines: Binding<LineSelection?>? = nil, activeLineSide: DiffSide? = nil,
                lineNumberOnly: Bool = false, onPostRender: ((NativeUnresolvedFileView, PostRenderPhase) -> Void)? = nil) {
        self.onPostRender = onPostRender
        self.file = file; self.options = options; self.annotations = annotations
        self.maxContextLines = maxContextLines; self.highlighter = highlighter
        self.behavior = behavior; self.onError = onError; self.headerRenderers = headerRenderers
        self.interactionHandlers = interactionHandlers; self.annotationRenderer = annotationRenderer
        self.gutterRenderer = gutterRenderer; self.separatorRenderer = separatorRenderer
        self.conflictActionRenderer = conflictActionRenderer; self.onSelectionChange = onSelectionChange
        self.selectedLines = selectedLines; self.activeLineSide = activeLineSide; self.lineNumberOnly = lineNumberOnly
    }
    public func makeCoordinator() -> Coordinator { Coordinator(highlighter: highlighter ?? DiffHighlighter()) }
    public func makeNSView(context: Context) -> NativeUnresolvedFileView {
        NativeUnresolvedFileView(highlighter: context.coordinator.highlighter)
    }
    public func updateNSView(_ view: NativeUnresolvedFileView, context: Context) { context.coordinator.update(self, view: view) }
    public static func dismantleNSView(_ view: NativeUnresolvedFileView, coordinator: Coordinator) { view.cleanUp() }

    @MainActor public final class Coordinator {
        let highlighter: DiffHighlighter
        private var file: FileContents?
        private var options: DiffRenderOptions?
        private var annotations: [LineAnnotation] = []
        private var maxContextLines: Int?
        private var annotationRenderer: DiffAnnotationRenderer?
        private var gutterRenderer: DiffGutterRenderer?
        init(highlighter: DiffHighlighter) { self.highlighter = highlighter }
        func update(_ input: UnresolvedFileView, view: NativeUnresolvedFileView) {
            view.onPostRender = input.onPostRender
            view.behavior = input.behavior; view.onError = input.onError
            let diff = view.diffView
            defer {
                if let selection = input.selectedLines,
                   diff.selectedLines != selection.wrappedValue || diff.selectionHighlightSide != input.activeLineSide || diff.selectionLineNumberOnly != input.lineNumberOnly {
                    // Native notify:false suppresses interaction events, while
                    // onSelectionChange still observes programmatic changes.
                    // Do not echo a SwiftUI binding application back to its host.
                    let callback = diff.onSelectionChange
                    diff.onSelectionChange = nil
                    diff.selectLines(selection.wrappedValue, notify: false, activeLineSide: input.activeLineSide, lineNumberOnly: input.lineNumberOnly)
                    diff.onSelectionChange = callback
                }
            }
            diff.headerRenderers = input.headerRenderers ?? .init()
            diff.interactionHandlers = input.interactionHandlers ?? .init()
            diff.onSelectionChange = input.onSelectionChange
            diff.separatorRenderer = input.separatorRenderer
            diff.conflictActionRenderer = input.conflictActionRenderer
            if annotationRenderer !== input.annotationRenderer {
                annotationRenderer = input.annotationRenderer; diff.renderAnnotation = input.annotationRenderer?.render
            }
            if gutterRenderer !== input.gutterRenderer {
                gutterRenderer = input.gutterRenderer; diff.renderGutterUtility = input.gutterRenderer?.render
            }
            let fileChanged = !areFilesEqual(file, input.file)
            let contextChanged = maxContextLines != input.maxContextLines
            let layoutChanged = options != input.options || annotations != input.annotations
            guard fileChanged || contextChanged || layoutChanged || view.state == nil else { return }
            do {
                if let state = view.state, (!fileChanged || areFilesEqual(state.file, input.file)), !contextChanged {
                    // Includes host echoes of the just-resolved source: retain conflict IDs.
                    view.render(state: state, options: input.options, annotations: input.annotations)
                } else {
                    // Context-only changes rebuild the current source, not the original input.
                    let source = !fileChanged ? view.state?.file ?? input.file : input.file
                    try view.render(file: source, options: input.options, annotations: input.annotations, maxContextLines: input.maxContextLines)
                }
                file = input.file; options = input.options; annotations = input.annotations
                maxContextLines = input.maxContextLines
            } catch { input.onError?(error) }
        }
    }
}

#endif

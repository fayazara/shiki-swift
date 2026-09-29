#if os(macOS)
import AppKit
import SwiftUI

/// File header callbacks receive original file metadata, including optional
/// language, header and cache key, rather than a synthesized diff target.
@MainActor public struct FileHeaderRenderers {
    public typealias Renderer = (FileContents) -> NSView?
    public var renderHeaderPrefix: Renderer?
    public var renderHeaderFilenameSuffix: Renderer?
    public var renderHeaderMetadata: Renderer?
    public var renderCustomHeader: Renderer?
    public init(renderHeaderPrefix: Renderer? = nil, renderHeaderFilenameSuffix: Renderer? = nil,
                renderHeaderMetadata: Renderer? = nil, renderCustomHeader: Renderer? = nil) {
        self.renderHeaderPrefix = renderHeaderPrefix; self.renderHeaderFilenameSuffix = renderHeaderFilenameSuffix
        self.renderHeaderMetadata = renderHeaderMetadata; self.renderCustomHeader = renderCustomHeader
    }
    var isEmpty: Bool { renderHeaderPrefix == nil && renderHeaderFilenameSuffix == nil && renderHeaderMetadata == nil && renderCustomHeader == nil }
    func adapting(_ file: FileContents) -> DiffHeaderRenderers {
        func adapt(_ renderer: Renderer?) -> DiffHeaderRenderers.Renderer? {
            renderer.map { callback in { _ in callback(file) } }
        }
        return .init(renderHeaderPrefix: adapt(renderHeaderPrefix), renderHeaderFilenameSuffix: adapt(renderHeaderFilenameSuffix),
                     renderHeaderMetadata: adapt(renderHeaderMetadata), renderCustomHeader: adapt(renderCustomHeader))
    }
}

/// The single-file/streaming presentation shares the virtualized code canvas.
@MainActor public final class NativeFileView: NSView {
    public let diffView = NativeDiffView(frame: .zero)
    public var onPostRender: ((NativeFileView, PostRenderPhase) -> Void)?
    private var renderOptions = DiffRenderOptions()
    private var renderAnnotations: [LineAnnotation] = []
    private var presentationRevision = UUID()
    public func setEditorActiveLine(_ number: Int?, options: EditorActiveLineOptions = .init()) {
        diffView.setEditorActiveLine(number, options: options)
    }
    public func setOptions(_ options: DiffRenderOptions?) {
        guard let options else { return }
        renderOptions = options
        if let document = diffView.displayedDocument { render(document, file: file, options: options, annotations: renderAnnotations) }
    }
    public func setLineAnnotations(_ annotations: [LineAnnotation]) {
        renderAnnotations = annotations
        diffView.setLineAnnotations(annotations)
    }
    public func setFileAnnotations(_ annotations: [FileLineAnnotation]) { setLineAnnotations(annotations.map(\.renderedAnnotation)) }
    public func rerender() { diffView.rerender() }
    public func cleanUp() {
        let ticket = UUID(); presentationRevision = ticket
        diffView.cleanUp()
        guard presentationRevision == ticket else { return }
        file = nil; reconstructedID = nil; reconstructedFile = nil; renderAnnotations = []
    }

    public var gutterRenderer: FileGutterRenderer? {
        didSet { if oldValue !== gutterRenderer { diffView.renderGutterUtility = gutterRenderer?.adapted } }
    }
    public var annotationRenderer: DiffAnnotationRenderer? {
        didSet {
            if oldValue !== annotationRenderer { diffView.renderAnnotation = annotationRenderer?.render }
        }
    }
    public func invalidateAnnotationLayout() { diffView.invalidateAnnotationLayout() }
    private var stagingHeader = false
    public var headerRenderers = FileHeaderRenderers() { didSet { if !stagingHeader { reloadHeader() } } }
    func stageHeaderRenderers(_ renderers: FileHeaderRenderers) {
        stagingHeader = true; headerRenderers = renderers; stagingHeader = false
    }
    public var interactionHandlers = FileInteractionHandlers() { didSet { installInteractions() } }
    private func installInteractions() {
        if let file { diffView.interactionHandlers = interactionHandlers.adapting(file) }
    }
    public private(set) var file: FileContents?
    private var reconstructedID: UUID?
    private var reconstructedFile: FileContents?
    public override init(frame: NSRect) {
        super.init(frame: frame); addSubview(diffView)
        diffView.presentationObserver = { [weak self] phase in
            guard let self else { return }; self.onPostRender?(self, phase)
        }
    }
    public required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    public override func layout() { super.layout(); diffView.frame = bounds; diffView.layoutSubtreeIfNeeded() }
    public func reloadHeader() {
        if let file { diffView.headerRenderers = headerRenderers.adapting(file) }
    }
    /// Supply the original file to preserve metadata unavailable in a prepared
    /// diff. Otherwise use its additions as a file snapshot, cached per revision.
    public func render(_ document: HighlightedDiff, file: FileContents? = nil, options: DiffRenderOptions = .init(), annotations: [LineAnnotation] = []) {
        presentationRevision = UUID()
        renderOptions = options; renderAnnotations = annotations
        let source: FileContents
        if let file { source = file }
        else {
            if reconstructedID != document.id {
                reconstructedID = document.id
                reconstructedFile = .init(name: document.diff.name, contents: document.diff.additionLines.joined(),
                                           lang: document.diff.lang, cacheKey: document.diff.cacheKey)
            }
            source = reconstructedFile!
        }
        self.file = source
        installInteractions()
        diffView.stageFileHeader(source, renderers: headerRenderers.adapting(source))
        var resolved = options; resolved.diffStyle = .unified; resolved.expandUnchanged = true
        diffView.render(document, options: resolved, annotations: annotations)
        needsLayout = true; layoutSubtreeIfNeeded()
    }
}

public struct FileView: NSViewRepresentable {
    public var annotations: [LineAnnotation]
    public var onPostRender: ((NativeFileView, PostRenderPhase) -> Void)?
    public var gutterRenderer: FileGutterRenderer?
    public var annotationRenderer: DiffAnnotationRenderer?
    public var interactionHandlers: FileInteractionHandlers?
    public var document: HighlightedDiff
    public var file: FileContents?
    public var options: DiffRenderOptions
    public var headerRenderers: FileHeaderRenderers?
    public init(document: HighlightedDiff, options: DiffRenderOptions = .init(), file: FileContents? = nil, headerRenderers: FileHeaderRenderers? = nil, interactionHandlers: FileInteractionHandlers? = nil, annotations: [LineAnnotation] = [], annotationRenderer: DiffAnnotationRenderer? = nil, gutterRenderer: FileGutterRenderer? = nil, onPostRender: ((NativeFileView, PostRenderPhase) -> Void)? = nil) {
        self.onPostRender = onPostRender
        self.gutterRenderer = gutterRenderer
        self.annotations = annotations; self.annotationRenderer = annotationRenderer
        self.interactionHandlers = interactionHandlers
        self.document = document; self.options = options; self.file = file; self.headerRenderers = headerRenderers
    }
    public func makeNSView(context: Context) -> NativeFileView { NativeFileView(frame: .zero) }
    public static func dismantleNSView(_ view: NativeFileView, coordinator: ()) { view.cleanUp() }
    public func updateNSView(_ view: NativeFileView, context: Context) {
        view.onPostRender = onPostRender
        view.gutterRenderer = gutterRenderer
        view.annotationRenderer = annotationRenderer
        view.interactionHandlers = interactionHandlers ?? .init()
        view.stageHeaderRenderers(headerRenderers ?? .init())
        view.render(document, file: file, options: options, annotations: annotations)
    }
}

extension NativeFileView {
    /// Side-less file comments are adapted to the shared single-file canvas.
    public func render(_ document: HighlightedDiff, file: FileContents? = nil, options: DiffRenderOptions = .init(), fileAnnotations: [FileLineAnnotation]) {
        render(document, file: file, options: options, annotations: fileAnnotations.map(\.renderedAnnotation))
    }
}

extension FileView {
    public init(document: HighlightedDiff, options: DiffRenderOptions = .init(), file: FileContents? = nil,
                headerRenderers: FileHeaderRenderers? = nil, interactionHandlers: FileInteractionHandlers? = nil,
                fileAnnotations: [FileLineAnnotation], annotationRenderer: DiffAnnotationRenderer? = nil, gutterRenderer: FileGutterRenderer? = nil, onPostRender: ((NativeFileView, PostRenderPhase) -> Void)? = nil) {
        self.init(document: document, options: options, file: file, headerRenderers: headerRenderers,
                  interactionHandlers: interactionHandlers, annotations: fileAnnotations.map(\.renderedAnnotation),
                  annotationRenderer: annotationRenderer, gutterRenderer: gutterRenderer, onPostRender: onPostRender)
    }
}

#endif

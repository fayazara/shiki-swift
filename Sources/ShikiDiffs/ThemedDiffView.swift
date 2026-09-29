#if os(macOS)
import AppKit
import SwiftUI

public enum DiffThemeAppearance: String, CaseIterable, Sendable { case system, light, dark }
public struct DiffThemeNames: Equatable, Sendable {
    public var light: String
    public var dark: String
    public init(light: String = "pierre-light", dark: String = "pierre-dark") { self.light = light; self.dark = dark }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.light.utf16.elementsEqual(rhs.light.utf16) && lhs.dark.utf16.elementsEqual(rhs.dark.utf16)
    }
}
public struct ThemedDiff: Sendable {
    public let light: HighlightedDiff
    public let dark: HighlightedDiff
    public let themes: DiffThemeNames
    public func identifyingSource(as sourceID: UUID) -> ThemedDiff {
        .init(light: light.identifyingSource(as: sourceID), dark: dark.identifyingSource(as: sourceID), themes: themes)
    }
}
public extension DiffHighlighter {
    func resolveThemes(_ diff: FileDiffMetadata, hunkIndex: Int, resolution: DiffResolution, themes: DiffThemeNames = .init(), options: DiffRenderOptions = .init()) async throws -> ThemedDiff {
        try await prepareThemes(diffAcceptRejectHunk(diff, hunkIndex: hunkIndex, resolution: resolution), themes: themes, options: options)
    }
    func prepareThemes(_ diff: FileDiffMetadata, themes: DiffThemeNames = .init(), options: DiffRenderOptions = .init()) async throws -> ThemedDiff {
        var options = options; options.theme = themes.dark
        let dark = try await prepare(diff, options: options)
        try Task.checkCancellation()
        options.theme = themes.light
        let light = try await prepare(diff, options: options).identifyingSource(as: dark.sourceID)
        return .init(light: light, dark: dark, themes: themes)
    }
    func prepareThemes(oldFile: FileContents?, newFile: FileContents?, themes: DiffThemeNames = .init(), diffOptions: DiffOptions = .init(), options: DiffRenderOptions = .init()) async throws -> ThemedDiff {
        try await prepareThemes(parseDiffFromFile(oldFile, newFile, options: diffOptions), themes: themes, options: options)
    }
}

/// Both theme variants are prepared before presentation. Appearance changes only
/// replace the bounded visible styling cache and preserve the logical selection.
@MainActor public final class NativeThemedDiffView: NSView {
    public let diffView = NativeDiffView(frame: .zero)
    public var conflictActionRenderer: DiffConflictActionRenderer? {
        get { diffView.conflictActionRenderer }
        set { diffView.conflictActionRenderer = newValue }
    }
    public var mergeConflictActions: [MergeConflictDiffAction] {
        get { diffView.mergeConflictActions }
        set { diffView.mergeConflictActions = newValue }
    }
    public func invalidateConflictActionLayout() { diffView.invalidateConflictActionLayout() }
    public var separatorRenderer: DiffSeparatorRenderer? {
        get { diffView.separatorRenderer }
        set { diffView.separatorRenderer = newValue }
    }
    public func invalidateSeparatorLayout() { diffView.invalidateSeparatorLayout() }
    public var gutterRenderer: DiffGutterRenderer? {
        didSet { if oldValue !== gutterRenderer { diffView.renderGutterUtility = gutterRenderer?.render } }
    }
    public var annotationRenderer: DiffAnnotationRenderer? {
        didSet {
            if oldValue !== annotationRenderer { diffView.renderAnnotation = annotationRenderer?.render }
        }
    }
    public func invalidateAnnotationLayout() { diffView.invalidateAnnotationLayout() }
    public var interactionHandlers: DiffInteractionHandlers {
        get { diffView.interactionHandlers }
        set { diffView.interactionHandlers = newValue }
    }
    public var headerRenderers: DiffHeaderRenderers {
        get { diffView.headerRenderers }
        set { diffView.headerRenderers = newValue }
    }
    public var themeAppearance: DiffThemeAppearance = .system { didSet { present() } }
    private var document: ThemedDiff?
    private var options = DiffRenderOptions()
    private var annotations: [LineAnnotation] = []
    private var markerRows: [MergeConflictMarkerRow] = []
    public override init(frame: NSRect) { super.init(frame: frame); addSubview(diffView) }
    public required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    public override func layout() { super.layout(); diffView.frame = bounds; diffView.layoutSubtreeIfNeeded() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); present() }
    public func render(_ document: ThemedDiff, options: DiffRenderOptions = .init(), annotations: [LineAnnotation] = [], markerRows: [MergeConflictMarkerRow] = []) {
        self.document = document; self.options = options; self.annotations = annotations; self.markerRows = markerRows
        present(); needsLayout = true; layoutSubtreeIfNeeded()
    }
    private func present() {
        guard let document else { return }
        let light = themeAppearance == .light || (themeAppearance == .system && effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua)
        var options = options; options.theme = light ? document.themes.light : document.themes.dark
        diffView.render(light ? document.light : document.dark, options: options, annotations: annotations, markerRows: markerRows)
    }
}
public struct ThemedFileDiffView: NSViewRepresentable {
    public var conflictActionRenderer: DiffConflictActionRenderer?
    public var mergeConflictActions: [MergeConflictDiffAction]
    public var separatorRenderer: DiffSeparatorRenderer?
    public var gutterRenderer: DiffGutterRenderer?
    public var annotationRenderer: DiffAnnotationRenderer?
    public var interactionHandlers: DiffInteractionHandlers?
    public var headerRenderers: DiffHeaderRenderers?
    public var document: ThemedDiff
    public var options: DiffRenderOptions
    public var appearance: DiffThemeAppearance
    public var annotations: [LineAnnotation]
    public var markerRows: [MergeConflictMarkerRow]
    public var onSelectionChange: ((LineSelection?) -> Void)?
    public init(document: ThemedDiff, options: DiffRenderOptions = .init(), appearance: DiffThemeAppearance = .system, annotations: [LineAnnotation] = [], markerRows: [MergeConflictMarkerRow] = [], onSelectionChange: ((LineSelection?) -> Void)? = nil, headerRenderers: DiffHeaderRenderers? = nil, interactionHandlers: DiffInteractionHandlers? = nil, annotationRenderer: DiffAnnotationRenderer? = nil, gutterRenderer: DiffGutterRenderer? = nil, separatorRenderer: DiffSeparatorRenderer? = nil, conflictActionRenderer: DiffConflictActionRenderer? = nil, mergeConflictActions: [MergeConflictDiffAction] = []) {
        self.conflictActionRenderer = conflictActionRenderer
        self.mergeConflictActions = mergeConflictActions
        self.separatorRenderer = separatorRenderer
        self.gutterRenderer = gutterRenderer
        self.annotationRenderer = annotationRenderer
        self.interactionHandlers = interactionHandlers;
        self.headerRenderers = headerRenderers
        self.document = document; self.options = options; self.appearance = appearance; self.annotations = annotations; self.markerRows = markerRows; self.onSelectionChange = onSelectionChange
    }
    public func makeNSView(context: Context) -> NativeThemedDiffView { NativeThemedDiffView(frame: .zero) }
    public func updateNSView(_ view: NativeThemedDiffView, context: Context) {
        view.conflictActionRenderer = conflictActionRenderer
        view.mergeConflictActions = mergeConflictActions
        view.separatorRenderer = separatorRenderer
        view.gutterRenderer = gutterRenderer
        view.annotationRenderer = annotationRenderer
        view.interactionHandlers = interactionHandlers ?? .init()
        view.headerRenderers = headerRenderers ?? .init()
        view.diffView.onSelectionChange = onSelectionChange; view.themeAppearance = appearance
        view.render(document, options: options, annotations: annotations, markerRows: markerRows)
    }
}

#endif

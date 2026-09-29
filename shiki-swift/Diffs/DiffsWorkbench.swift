import SwiftUI
import Shiki
import ShikiDiffs
import AppKit

@MainActor private final class DemoContextController {
    weak var view: NativeDiffView?
}

/// The ShikiDiffs workbench: one example (chosen in the app sidebar) with
/// every display and comparison control in an inspector.
struct DiffsWorkbench: View {
    let sample: DemoSample
    @Environment(AppTheme.self) private var appTheme
    @State private var showInspector = true
    /// nil follows the app's theme (and its light/dark appearance).
    @State private var themeOverride: String?
    @State private var streamMode: DemoStreamMode = .snapshots
    @State private var streamConfiguration: StreamTokenizerConfiguration?
    @State private var options: DiffRenderOptions = {
        var options = DiffRenderOptions()
        options.theme = "pierre-light"
        return options
    }()
    @State private var document: HighlightedDiff?
    @State private var editedAnnotations: [LineAnnotation]?
    @State private var isLoading = false
    @State private var isColorizing = false
    @State private var error: String?
    @State private var lastTokenEvent: NSEvent?
    @State private var interactWithWhitespace = false
    @State private var enableLineSelection = true
    @State private var selectionPolicy = 0
    @State private var selectionHighlightSide: DiffSide?
    @State private var selectionNumberOnly = false
    @State private var acceptedSelection: LineSelection?
    @State private var selectionStatus: String?
    @State private var showTokenPopovers = false
    @State private var hoverHighlight: LineHoverHighlight = .disabled
    @State private var tokenPopover: NSPopover?
    @State private var lastInteraction: String?
    @State private var selection: LineSelection?
    @State private var showAnnotations = false
    @State private var showGutterUtility = false
    @State private var customGutterUtility = false
    @State private var gutterRenderer = DiffGutterRenderer { read in
        NSHostingView(rootView: DemoGutterUtility(getHoveredLine: read))
    }
    @State private var fileGutterRenderer = FileGutterRenderer { read in
        NSHostingView(rootView: DemoGutterUtility(getHoveredLine: { read().map { .init(lineNumber: $0.lineNumber, side: .additions) } }))
    }
    @State private var reviewGutterRenderer = CodeViewGutterRenderer { read in
        NSHostingView(rootView: DemoGutterUtility(getHoveredLine: { read().map { .init(lineNumber: $0.lineNumber, side: $0.side ?? .additions) } }))
    }
    @State private var separatorRenderer = DiffSeparatorRenderer { data, expand in
        NSHostingView(rootView: DemoHunkSeparator(data: data, expand: expand))
    }
    @State private var conflictActionRenderer = DiffConflictActionRenderer { action, resolve in
        NSHostingView(rootView: DemoConflictActions(index: action.conflictIndex, resolve: resolve))
    }
    @State private var customAnnotations = false
    @State private var annotationRenderer = DiffAnnotationRenderer { annotation in
        NSHostingView(rootView: VStack(alignment: .leading, spacing: 6) {
            Label("Review note", systemImage: "text.bubble").font(.caption.bold())
            Text(annotation.text).font(.callout)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1)))
    }
    @State private var headerMode = 0
    @State private var contextController = DemoContextController()
    @State private var savedContext: [Int: HunkExpansionRegion]?
    @State private var context = 4
    @State private var ignoreWhitespace = false
    @State private var stripTrailingCr = false
    @State private var prepareNeighboringFiles = false
    @State private var multiDocuments: [HighlightedDiff] = []
    @State private var reviewFiles: [String: FileContents] = [:]
    @State private var collapsedReviewFiles: Set<String> = []
    @State private var autoEditFirstReviewFile = false
    @State private var acceptAutomaticEdits = true
    @State private var retainReviewDrafts = false
    @State private var showEditorDiagnostics = false
    @State private var editorMatchBrackets = true
    @State private var editorAutoSurround: AutoSurround = .default
    @State private var showExternalCaret = false
    @State private var appendTask: Task<Void, Never>?
    @State private var appendRequest: UUID?
    @State private var showReviewChrome = false
    @State private var stickyReviewHeaders = false
    @State private var reviewController = CodeViewController()
    @State private var editingReviewItem: String?
    @State private var savingReview = false
    @State private var reviewCompletionTask: Task<Void, Never>?
    @State private var reviewCompletionRequest: UUID?
    @State private var reviewHeader = DemoReviewHeader(text: "Module review\nInspect changes across the service modules.")
    @State private var reviewFooter = DemoReviewHeader(text: "End of review · Add more files from the sidebar.")
    @State private var editorText = ""
    @State private var editorInitialized = false
    @State private var editingDiff = true
    @State private var showEditorShortcuts = false
    @State private var customEditorKeymap = false
    @State private var demoAttachedEditor: DiffEditor?
    @State private var savedEditState: EditState?
    @State private var editorInitialState: EditorInitialState?
    @State private var editorMountID = UUID()
    @State private var predictionExample = DemoPredictionExample.off
    @State private var subtlePredictions = false
    @State private var showSelectionActions = false
    @State private var customCollaboratorCaret = false
    @State private var delayedClipboard = false
    @State private var selectionActionRenderer = EditorSelectionActionRenderer { context in
        NSHostingView(rootView: DemoSelectionActions(context: context))
    }
    @State private var caretRenderer = EditorCaretRenderer { _ in
        NSHostingView(rootView: HStack(spacing: 4) {
            Rectangle().fill(.purple).frame(width: 2, height: 20)
            Text("Alex").font(.system(size: 11, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 2)
                .foregroundStyle(.white).background(.purple, in: RoundedRectangle(cornerRadius: 3))
        }.fixedSize())
    }
    @State private var clipboardProvider = EditorClipboardProvider { type in
        try await Task.sleep(for: .milliseconds(250))
        return await MainActor.run {
            NSPasteboard.general.string(forType: type.map { NSPasteboard.PasteboardType(rawValue: $0) } ?? .string) ?? ""
        }
    }
    @State private var editCompletionMode = DiffEditCompletionMode.install
    @State private var wrapEditor = false
    @State private var conflictFile: FileContents?
    @State private var themedDocument: ThemedDiff?
    @State private var followAppearance = false
    @State private var hydratePatch = false
    private func presentToken(_ text: String, in view: NSView, rects: [NSRect], event: NSEvent) {
        let point = view.convert(event.locationInWindow, from: nil)
        guard let rect = rects.first(where: { $0.contains(point) }) ?? rects.first else { return }
        tokenPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            Text(String(text.prefix(400))).font(.system(.body, design: .monospaced))
                .textSelection(.enabled).padding(12).frame(maxWidth: 360))
        tokenPopover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
    private let highlighter = DiffHighlighter()
    var body: some View {
        detail
        .inspector(isPresented: $showInspector) {
            Form {
                Section("Display") {
                    Picker("Layout", selection: $options.diffStyle) {
                        Text("Split").tag(DiffStyle.split)
                        Text("Unified").tag(DiffStyle.unified)
                    }
                    .pickerStyle(.segmented)
                    .disabled(sample == .conflict)
                    Toggle("Expand unchanged", isOn: $options.expandUnchanged)
                    if sample == .stream {
                        Picker("Streaming mode", selection: $streamMode) {
                            ForEach(DemoStreamMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                        }
                    }
                    if sample == .multiple {
                        Toggle("Review header and footer", isOn: $showReviewChrome)
                        Toggle("Sticky file headers", isOn: $stickyReviewHeaders)
                        Toggle("Automatically edit first file", isOn: $autoEditFirstReviewFile)
                            .disabled(editingReviewItem != nil || isLoading)
                        if autoEditFirstReviewFile {
                            Toggle("Accept edits when editing ends", isOn: $acceptAutomaticEdits)
                            Toggle("Remember drafts and undo", isOn: $retainReviewDrafts)
                            Text("Turn automatic editing off to finish. Collapse keeps the draft and undo history.")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        HStack {
                            Button("Collapse all") { collapsedReviewFiles = Set(multiDocuments.map { $0.diff.name }) }
                            Button("Expand all") { collapsedReviewFiles = [] }
                        }.disabled(isLoading || multiDocuments.isEmpty)
                        Button("Toggle first file") {
                            guard let id = multiDocuments.first?.diff.name else { return }
                            if !collapsedReviewFiles.insert(id).inserted { collapsedReviewFiles.remove(id) }
                        }.disabled(isLoading || multiDocuments.isEmpty)

                        Button(appendRequest == nil ? "Add 20 files" : "Adding files…") {
                            let request = UUID(); appendRequest = request
                            appendTask = Task { await appendReviewFiles(request: request) }
                        }
                        .disabled(isLoading || multiDocuments.isEmpty || appendRequest != nil)
                        Text("\(multiDocuments.count) items · every fifth item is a single file").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Select last file") {
                                guard let id = multiDocuments.last?.diff.name, let view = reviewController.view else { return }
                                let range = LineSelection(side: .additions, startLine: 1, endLine: 1)
                                view.selectLines(range, inItem: id)
                                view.scrollToRange(range, inItem: id, align: .center)
                            }
                            Button("Clear") { reviewController.view?.clearSelectedLines() }
                        }.disabled(isLoading || multiDocuments.isEmpty || editingReviewItem != nil)
                        HStack {
                            Button("Glide to first") {
                                guard let id = multiDocuments.first?.diff.name else { return }
                                reviewController.view?.scrollToItem(id, behavior: .smooth)
                            }
                            Button("Glide to last") {
                                guard let id = multiDocuments.last?.diff.name else { return }
                                reviewController.view?.scrollToItem(id, behavior: .smooth)
                            }
                        }.disabled(isLoading || multiDocuments.isEmpty || editingReviewItem != nil)
                        if let editingReviewItem {
                            HStack {
                                Button("Save edit") { completeReviewEdit(editingReviewItem, mode: .install) }
                                Button("Discard") { completeReviewEdit(editingReviewItem, mode: .discard) }
                            }.disabled(savingReview)
                        } else {
                            Button("Edit first file") {
                                guard !autoEditFirstReviewFile, let id = multiDocuments.first?.diff.name, let view = reviewController.view else { return }
                                do { _ = try view.beginEditingItem(id); editingReviewItem = id }
                                catch { self.error = error.localizedDescription }
                            }.disabled(isLoading || multiDocuments.isEmpty)
                        }
                        Toggle("Prepare neighboring files", isOn: $prepareNeighboringFiles)
                            .help("Prepare files within 600 points above and below the visible review.")
                    }
                    Picker("Overflow", selection: $options.overflow) {
                        Text("Scroll").tag(DiffOverflow.scroll)
                        Text("Wrap").tag(DiffOverflow.wrap)
                    }
                    Toggle("Annotations", isOn: $showAnnotations)
                    if showAnnotations && (supportsControlledSelection || sample == .diffEditor || sample == .file || sample == .stream || sample == .multiple || (followAppearance && supportsAdaptiveTheme)) {
                        Toggle("Custom annotation cards", isOn: $customAnnotations)
                    }
                    if sample != .editor {
                        Toggle("Gutter utility", isOn: $showGutterUtility)
                        if showGutterUtility { Toggle("Custom gutter popover", isOn: $customGutterUtility) }
                    }
                    Toggle("Gutter line selection", isOn: $enableLineSelection)
                    if supportsControlledSelection {
                        Picker("Selection ownership", selection: $selectionPolicy) {
                            Text("View manages selection").tag(0)
                            Text("Accept on release").tag(1)
                            Text("Reject proposals").tag(2)
                        }
                        if selectionPolicy != 0 {
                            Picker("Highlight columns", selection: $selectionHighlightSide) {
                                Text("Both").tag(DiffSide?.none)
                                Text("Old").tag(DiffSide?.some(.deletions))
                                Text("New").tag(DiffSide?.some(.additions))
                            }
                            Toggle("Highlight gutter only", isOn: $selectionNumberOnly)
                        }
                        if let selectionStatus { Text(selectionStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                    Toggle("Interact with whitespace", isOn: $interactWithWhitespace)
                    Toggle("Token popovers", isOn: $showTokenPopovers)
                    Picker("Hover highlight", selection: $hoverHighlight) {
                        ForEach(LineHoverHighlight.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Header", selection: $headerMode) {
                        Text("Default").tag(0)
                        Text("Custom slots").tag(1)
                        Text("Custom view").tag(2)
                    }
                    .disabled(sample == .editor)
                    if sample == .editor { Toggle("Wrap editor lines", isOn: $wrapEditor) }
                    Toggle("Hide backgrounds", isOn: $options.disableBackground)
                    Toggle("Hide line numbers", isOn: $options.disableLineNumbers)
                    Toggle("Collapse file", isOn: $options.collapsed)
                    Toggle("Sticky header", isOn: $options.stickyHeader).disabled(sample == .multiple)
                    if sample == .patch {
                        Button("Save expanded context") {
                            savedContext = contextController.view?.getExpandedHunksMap()
                        }.disabled(options.expandUnchanged || !hydratePatch)
                        Button("Restore expanded context") {
                            if let savedContext { contextController.view?.setExpandedHunksMap(savedContext) }
                        }.disabled(savedContext == nil || options.expandUnchanged || !hydratePatch)
                        Button("Collapse expanded context") {
                            contextController.view?.setExpandedHunksMap([:])
                        }.disabled(options.expandUnchanged || !hydratePatch)
                    }
                    Picker("Indicators", selection: $options.diffIndicators) {
                        ForEach(DiffIndicators.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Separators", selection: $options.hunkSeparators) {
                        ForEach(HunkSeparators.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if sample == .conflict {
                        Picker("Conflict actions", selection: $options.mergeConflictActionsType) {
                            Text("Default").tag(MergeConflictActionsType.default)
                            Text("Hidden").tag(MergeConflictActionsType.none)
                            Text("Custom").tag(MergeConflictActionsType.custom)
                        }
                    }
                    Picker("Inline diff", selection: $options.lineDiffType) {
                        ForEach(LineDiffType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Theme", selection: $themeOverride) {
                        Text("App theme").tag(String?.none)
                        Divider()
                        Text("Pierre Light").tag(Optional("pierre-light"))
                        Text("Pierre Dark").tag(Optional("pierre-dark"))
                        Text("GitHub Dark").tag(Optional("github-dark"))
                        Text("GitHub Light").tag(Optional("github-light"))
                        Text("Vitesse Dark").tag(Optional("vitesse-dark"))
                        Text("Nord").tag(Optional("nord"))
                        Text("Custom · Sea Glass").tag(Optional("demo-sea-glass"))
                        Text("Custom · Variable Colors").tag(Optional("demo-variable-colors"))
                        Text("Rose Pine").tag(Optional("rose-pine"))
                    }
                    Toggle("Follow macOS appearance", isOn: $followAppearance).disabled(!supportsAdaptiveTheme)
                    if sample == .patch { Toggle("Load full patch contents", isOn: $hydratePatch) }
                    Stepper("Size  \(Int(options.fontSize)) pt", value: $options.fontSize, in: 10...22)
                }
                Section("Comparison") {
                    Stepper("Context  \(context) lines", value: $context, in: 0...20)
                    Toggle("Ignore whitespace", isOn: $ignoreWhitespace)
                    Toggle("Ignore CRLF differences", isOn: $stripTrailingCr)
                }.disabled(!supportsComparisonOptions)
            }
            .formStyle(.grouped)
            .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: { Label("Diff Options", systemImage: "sidebar.trailing") }
                    .help("Show or hide diff options")
            }
        }
        .task(id: preparationKey) { await load() }
        .onAppear { syncAppearance() }
        .onChange(of: appTheme.themeID) { _, _ in syncAppearance() }
        .onChange(of: appTheme.codeFontFamily) { _, _ in syncAppearance() }
        .onChange(of: themeOverride) { _, _ in syncAppearance() }
        .onChange(of: preparationKey) { _, _ in
            savedContext = nil
            appendTask?.cancel(); appendRequest = nil
            if savingReview { cancelReviewCompletion() }
        }
        .onChange(of: sample) { _, _ in
            cancelReviewCompletion(); savedEditState = nil; editorInitialState = nil; demoAttachedEditor = nil; editorMountID = UUID()
        }
        .onDisappear { appendTask?.cancel(); appendRequest = nil; cancelReviewCompletion() }
        .onChange(of: options.fontSize) { _, value in options.lineHeight = ceil(value * 1.65); syncAppearance() }
        .onChange(of: selectionPolicy) { previous, _ in
            if previous == 0 { acceptedSelection = selection }
            selectionStatus = nil
        }
    }
    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sample.title).font(.system(size: 21, weight: .semibold))
                        Text(sample == .multiple ? "\(multiDocuments.count) files in one review. Only files in the viewport have mounted native views." : sample.subtitle).font(.callout).foregroundStyle(.secondary)
                    }.layoutPriority(1)
                    Spacer(minLength: 16)
                    if let document, document.diff.hunks.contains(where: { $0.additionLines + $0.deletionLines > 0 }), ![DemoSample.editor, .diffEditor, .file, .multiple, .stream, .conflict].contains(sample) {
                        Button("Reject hunk") { Task { await resolveFirstHunk(.deletions) } }
                        Button("Accept hunk") { Task { await resolveFirstHunk(.additions) } }
                            .buttonStyle(.borderedProminent)
                    }
                    if isLoading { ProgressView().controlSize(.small) }
                    if let document {
                        Text("+\(document.diff.additions)").foregroundStyle(.green)
                        Text("−\(document.diff.deletions)").foregroundStyle(.red)
                    }
                }
                if sample == .diffEditor {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { editorMenus; editorActions }.fixedSize()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { editorMenus }.fixedSize()
                            HStack(spacing: 8) { editorActions }.fixedSize()
                        }
                    }.controlSize(.small)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            Divider()
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding(8) }
            if sample == .multiple && !multiDocuments.isEmpty {
                CodeView(items: multiDocuments.map { document in
                    if let file = reviewFiles[document.diff.name] {
                        return CodeViewItem(id: document.diff.name, document: document, file: file, fileAnnotations: demoFileAnnotations, collapsed: collapsedReviewFiles.contains(document.diff.name), edit: autoEditFirstReviewFile && document.diff.name == multiDocuments.first?.diff.name)
                    }
                    return CodeViewItem(id: document.diff.name, document: document, annotations: demoAnnotations, collapsed: collapsedReviewFiles.contains(document.diff.name), edit: autoEditFirstReviewFile && document.diff.name == multiDocuments.first?.diff.name)
                }, options: options, headerRenderers: demoHeaderRenderers, fileHeaderRenderers: demoFileHeaderRenderers, interactionHandlers: demoInteractionHandlers, fileInteractionHandlers: .init(enableGutterUtility: showGutterUtility, onGutterUtilityClick: customGutterUtility ? nil : { range in lastInteraction = "Gutter action: lines \(range.startLine)–\(range.endLine)" }), overscrollSize: prepareNeighboringFiles ? 600 : 0, annotationRenderer: customAnnotations ? annotationRenderer : nil, reviewHeader: showReviewChrome ? reviewHeader : nil, reviewFooter: showReviewChrome ? reviewFooter : nil, controller: reviewController, onItemsChange: { [expectedKey = preparationKey] updated in
                    guard sample == .multiple, preparationKey == expectedKey else { return }
                    multiDocuments = updated.map(\.document)
                    collapsedReviewFiles = Set(updated.filter { $0.collapsed == true }.map(\.id))
                    autoEditFirstReviewFile = updated.first?.edit ?? false
                    reviewFiles = Dictionary(uniqueKeysWithValues: updated.compactMap { item in item.file.map { (item.id, $0) } })
                }, onSelectedLinesChange: { [expectedKey = preparationKey] selected in
                    Task { @MainActor in
                        guard sample == .multiple, preparationKey == expectedKey else { return }
                        lastInteraction = selected.map {
                            "\(URL(fileURLWithPath: $0.id).lastPathComponent) · \($0.range.side.rawValue) · lines \($0.range.startLine)–\($0.range.endLine)"
                        } ?? "Selection cleared"
                    }
                }, stickyHeaders: stickyReviewHeaders, gutterRenderer: showGutterUtility && customGutterUtility ? reviewGutterRenderer : nil, separatorRenderer: separatorRenderer, onPostRender: { [expectedKey = preparationKey] item, phase in
                    let name = URL(fileURLWithPath: item.id).lastPathComponent
                    Task { @MainActor in
                        guard sample == .multiple, preparationKey == expectedKey else { return }
                        lastInteraction = "\(phase.rawValue.capitalized) · \(name)"
                    }
                }, createEditor: { host, _, key in
                    try host.beginEditing(highlighter: highlighter, diffOptions: parseOptions, editStateKey: key)
                }, getEditStateKey: { item in
                    retainReviewDrafts ? "demo-review-" + item.id : nil
                }, onItemEditChange: { _, item, _ in
                    Task { @MainActor in lastInteraction = "Editing · \(URL(fileURLWithPath: item.id).lastPathComponent)" }
                }, onItemEditComplete: { [expectedKey = preparationKey] _, item, _ in
                    guard sample == .multiple, preparationKey == expectedKey else { return .reject }
                    let accepted = acceptAutomaticEdits
                    Task { @MainActor in
                        lastInteraction = "\(accepted ? "Accepted" : "Rejected") · \(URL(fileURLWithPath: item.id).lastPathComponent)"
                    }
                    return accepted ? .accept : .reject
                }, onItemEditError: { failure, _ in
                    Task { @MainActor in error = failure.localizedDescription }
                })
            } else if sample == .editor {
                EditorView(text: $editorText, name: "Sources/DiffEngine.swift", options: options, wrapsLines: wrapEditor, highlighter: highlighter)
            } else if let document, sample == .diffEditor {
                EditableFileDiffView(document: document, isEditing: $editingDiff, options: options, diffOptions: parseOptions, annotations: demoAnnotations,
                    completionMode: editCompletionMode, initialState: editorInitialState,
                    onEditorAttached: { [editorMountID] editor in
                        Task { @MainActor in
                            guard self.editorMountID == editorMountID, sample == .diffEditor else { return }
                            demoAttachedEditor = editor; editorInitialState = nil
                        }
                    },
                    editPrediction: predictionExample.provider.map { .init(provider: $0, mode: subtlePredictions ? .subtle : .eager) },
                    clipboard: delayedClipboard ? clipboardProvider : nil,
                    enabledSelectionAction: showSelectionActions, selectionActionRenderer: selectionActionRenderer,
                    caretRenderer: customCollaboratorCaret ? caretRenderer : nil,
                    keymap: customEditorKeymap ? .init([.init(platform: .mac, bindings: ["cmd+d": .copyLineDown])]) : .init(),
                    autoSurround: editorAutoSurround, matchBrackets: editorMatchBrackets,
                    markers: showEditorDiagnostics ? [Marker(start: .init(line: 2, character: 0), end: .init(line: 2, character: 30), severity: .warning, message: "Example diagnostic: check the return value before continuing.", source: "Demo")]: [],
                    carets: showExternalCaret ? [EditorCaret(anchor: .init(line: 4, character: 2), focus: .init(line: 5, character: 12), metadata: .init(color: "#9d71ee"))] : [],
                    onEditComplete: { event in
                        if editCompletionMode == .install {
                            let previousID = document.id
                            Task {
                                do {
                                    let prepared = try await highlighter.prepare(event.fileDiff, options: options).identifyingSource(as: document.sourceID)
                                    if sample == .diffEditor, self.document?.id == previousID {
                                        editedAnnotations = event.annotations
                                        self.document = prepared
                                    }
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                        return true
                    }, onError: { error = $0.localizedDescription }, headerRenderers: demoHeaderRenderers, interactionHandlers: demoInteractionHandlers, annotationRenderer: customAnnotations ? annotationRenderer : nil, gutterRenderer: showGutterUtility && customGutterUtility ? gutterRenderer : nil, separatorRenderer: separatorRenderer)
                .id(editorMountID)
            } else if sample == .stream && streamMode != .snapshots {
                if let streamConfiguration {
                    DemoStreamingView(mode: streamMode, options: options, configuration: streamConfiguration, highlighter: highlighter)
                } else if let error {
                    ContentUnavailableView("Couldn’t prepare stream", systemImage: "exclamationmark.triangle", description: Text(error))
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else if let document, sample == .stream || sample == .file {
                FileView(document: document, options: options, headerRenderers: demoFileHeaderRenderers, interactionHandlers: .init(onLineClick: { event in
                    if lastTokenEvent !== event.event { lastInteraction = "Clicked line \(event.lineNumber)" }
                }, onLineNumberClick: { event in
                    lastInteraction = "Gutter line \(event.lineNumber)"
                }, enableTokenInteractionsOnWhitespace: interactWithWhitespace, onTokenClick: { event in
                    lastTokenEvent = event.event
                    lastInteraction = "Token \(event.lineCharStart)–\(event.lineCharEnd): \(event.tokenText.prefix(24))"
                    if showTokenPopovers { presentToken(event.tokenText, in: event.view, rects: event.visibleRects, event: event.event) }
                }, lineHoverHighlight: hoverHighlight, enableLineSelection: enableLineSelection, enableGutterUtility: showGutterUtility, onGutterUtilityClick: customGutterUtility ? nil : { range in lastInteraction = "Gutter action: lines \(range.startLine)–\(range.endLine)" }), fileAnnotations: demoFileAnnotations, annotationRenderer: customAnnotations ? annotationRenderer : nil, gutterRenderer: showGutterUtility && customGutterUtility ? fileGutterRenderer : nil)
            } else if let themedDocument, followAppearance && supportsAdaptiveTheme {
                ThemedFileDiffView(document: themedDocument, options: options, annotations: demoAnnotations, onSelectionChange: { selection = $0 }, headerRenderers: demoHeaderRenderers, interactionHandlers: demoInteractionHandlers, annotationRenderer: customAnnotations ? annotationRenderer : nil, gutterRenderer: showGutterUtility && customGutterUtility ? gutterRenderer : nil, separatorRenderer: separatorRenderer)
            } else if sample == .conflict, let conflictFile {
                UnresolvedFileView(file: conflictFile, options: options, annotations: demoAnnotations,
                    highlighter: highlighter, behavior: .automatic { _, payload in
                        lastInteraction = "Resolved conflict \(payload.conflict.conflictIndex + 1)"
                    }, onError: { error = $0.localizedDescription },
                    headerRenderers: demoHeaderRenderers, interactionHandlers: demoInteractionHandlers,
                    annotationRenderer: customAnnotations ? annotationRenderer : nil,
                    gutterRenderer: showGutterUtility && customGutterUtility ? gutterRenderer : nil,
                    separatorRenderer: separatorRenderer, conflictActionRenderer: conflictActionRenderer,
                    onSelectionChange: { selection = $0; lastInteraction = nil },
                    selectedLines: selectionPolicy == 0 ? nil : $acceptedSelection,
                    activeLineSide: selectionHighlightSide, lineNumberOnly: selectionNumberOnly)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document {
                FileDiffView(document: document, options: options, annotations: demoAnnotations, loadDiffFiles: patchLoader, onFilesLoaded: { self.document = $0 }, onFileLoadError: { error = $0.localizedDescription }, onSelectionChange: { selection = $0; lastInteraction = nil }, headerRenderers: demoHeaderRenderers,
                    interactionHandlers: demoInteractionHandlers, selectedLines: selectionPolicy == 0 ? nil : $acceptedSelection, activeLineSide: selectionHighlightSide, lineNumberOnly: selectionNumberOnly, annotationRenderer: customAnnotations ? annotationRenderer : nil, gutterRenderer: showGutterUtility && customGutterUtility ? gutterRenderer : nil, separatorRenderer: separatorRenderer, conflictActionRenderer: conflictActionRenderer,
                    onPostRender: { view, phase in
                        if phase == .unmount {
                            if contextController.view === view { contextController.view = nil }
                        } else { contextController.view = view }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Couldn’t prepare diff", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView("Preparing native diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 16) {
                Circle().fill(error == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text("AppKit / CoreText")
                if let document, sample != .editor {
                    Text("\(document.diff.deletionLines.count.formatted()) → \(document.diff.additionLines.count.formatted()) lines")
                    if let error { Text("Preparation failed").foregroundStyle(.orange).help(error) }
                    else if isColorizing { Text("Applying syntax colors…") }
                    else { Text(String(format: "Prepare %.1f ms", document.preparationMilliseconds)) }
                }
                Spacer()
                if let lastInteraction { Text(lastInteraction) }
                else if let selection { Text("\(selection.side.rawValue) · lines \(selection.startLine)–\(selection.endLine)") }
                else { Text("Drag to select · ⌘C to copy") }
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
    }

    /// The theme and code font follow the app unless the inspector overrides them.
    private func syncAppearance() {
        let theme = themeOverride ?? appTheme.themeID
        if options.theme != theme { options.theme = theme }
        let font = appTheme.codeFontFamily.map { _ in appTheme.codeNSFont(size: options.fontSize).fontName }
        if options.fontName != font { options.fontName = font }
    }
    private func cancelReviewCompletion() {
        reviewCompletionTask?.cancel(); reviewCompletionTask = nil
        reviewCompletionRequest = nil; savingReview = false; editingReviewItem = nil
    }
    private func completeReviewEdit(_ id: String, mode: DiffEditCompletionMode) {
        guard let view = reviewController.view else { return }
        let request = UUID(); reviewCompletionRequest = request
        savingReview = true
        reviewCompletionTask = Task { @MainActor in
            defer {
                if reviewCompletionRequest == request {
                    savingReview = false; editingReviewItem = nil
                    reviewCompletionTask = nil; reviewCompletionRequest = nil
                }
            }
            do { _ = try await view.completeEditingItem(id, mode: mode) }
            catch is CancellationError { }
            catch { if reviewCompletionRequest == request { self.error = error.localizedDescription } }
        }
    }

    private func appendReviewFiles(request: UUID) async {
        let key = preparationKey, prefix = multiDocuments.map(\.id)
        let renderOptions = options, parsingOptions = parseOptions
        defer { if appendRequest == request { appendRequest = nil } }
        do {
            var added: [HighlightedDiff] = []
            var addedFiles: [String: FileContents] = [:]
            for index in prefix.count..<(prefix.count + 20) {
                try Task.checkCancellation()
                let old = FileContents(name: "Sources/Module\(index)/Service.swift", contents: DemoSample.oldSwift)
                let new = FileContents(name: old.name, contents: DemoSample.newSwift)
                let isFile = index % 5 == 4
                added.append(try await highlighter.prepare(oldFile: isFile ? new : old, newFile: new, diffOptions: parsingOptions, options: renderOptions))
                if isFile { addedFiles[new.name] = new }
            }
            try Task.checkCancellation()
            guard appendRequest == request, sample == .multiple, preparationKey == key,
                  multiDocuments.map(\.id) == prefix else { return }
            multiDocuments.append(contentsOf: added)
            reviewFiles.merge(addedFiles) { _, new in new }
        } catch is CancellationError { }
        catch { if appendRequest == request { self.error = error.localizedDescription } }
    }

    private func resolveFirstHunk(_ resolution: DiffResolution) async {
        guard let current = document, let index = current.diff.hunks.firstIndex(where: { $0.additionLines + $0.deletionLines > 0 }) else { return }
        do {
            if followAppearance && supportsAdaptiveTheme {
                let resolved = try await highlighter.resolveThemes(current.diff, hunkIndex: index, resolution: resolution, options: options).identifyingSource(as: current.sourceID)
                if document?.id == current.id { document = resolved.dark; themedDocument = resolved }
                return
            }
            let resolved = try await highlighter.resolve(current.diff, hunkIndex: index, resolution: resolution, options: options)
            if document?.id == current.id { document = resolved.identifyingSource(as: current.sourceID) }
        } catch { self.error = error.localizedDescription }
    }
    @ViewBuilder private var editorMenus: some View {
        Menu("Typing") {
            Toggle("Match brackets", isOn: $editorMatchBrackets)
            Toggle("Custom shortcut: ⌘D duplicates line", isOn: $customEditorKeymap)
            Picker("Surround selection", selection: $editorAutoSurround) {
                ForEach(AutoSurround.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
            }
        }
        Menu("Predictions") {
            Picker("Local example", selection: $predictionExample) {
                ForEach(DemoPredictionExample.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Subtle (press Option to reveal)", isOn: $subtlePredictions)
            Text("Tab accepts · Escape dismisses")
        }
        Menu("Session") {
            Button("Save draft snapshot") { savedEditState = demoAttachedEditor?.getEditState() }
                .disabled(!editingDiff || demoAttachedEditor?.isActive != true)
            Button("Restore saved snapshot") {
                guard let savedEditState else { return }
                editorInitialState = .init(savedEditState); editorMountID = UUID(); editingDiff = true
            }.disabled(savedEditState == nil)
        }
        Menu("Widgets") {
            Toggle("Selection actions", isOn: $showSelectionActions)
            Toggle("Diagnostic markers", isOn: $showEditorDiagnostics)
            Toggle("Collaborator selection", isOn: $showExternalCaret)
            Toggle("Collaborator name label", isOn: $customCollaboratorCaret)
            Toggle("Delayed clipboard (250 ms)", isOn: $delayedClipboard)
        }
    }
    @ViewBuilder private var editorActions: some View {
        Button { showEditorShortcuts.toggle() } label: { Image(systemName: "keyboard") }
            .help("Editing shortcuts")
            .accessibilityLabel("Editing shortcuts")
            .popover(isPresented: $showEditorShortcuts) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Editing shortcuts").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 10) {
                        ForEach(editorShortcuts, id: \.0) { action, keys in
                            GridRow {
                                Text(action)
                                Text(keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(24)
            }
        if editingDiff {
            Button("Discard edits") { editCompletionMode = .discard; editingDiff = false }
            Button("Apply edits") { editCompletionMode = .install; editingDiff = false }.buttonStyle(.borderedProminent)
        } else { Button("Edit additions") { editingDiff = true }.buttonStyle(.borderedProminent) }

    }
    private var editorShortcuts: [(String, String)] {
        [("Add caret", "⌥Click"), ("Select next occurrence", "⌘D"), ("Keep primary selection", "Esc"),
         ("Move / select word", "⌥← / ⇧⌥←"), ("Indent / line start", "⌘←"),
         ("Find / replace", "⌘F / ⌥⌘F"), ("Next / previous match", "⌘G / ⇧⌘G"),
         ("Indent / outdent", "Tab / ⇧Tab"), ("Indent selected lines", "⌘] / ⌘["),
         ("Move lines", "⌥↑ / ⌥↓"), ("Copy lines", "⇧⌥↑ / ⇧⌥↓"),
         ("Insert blank line", "⌘Return"), ("Toggle line comment", "⌘/"),
         ("Toggle block comment", "⇧⌥A"), ("Undo / redo", "⌘Z / ⇧⌘Z")]
    }
    private var supportsAdaptiveTheme: Bool { ![DemoSample.file, .editor, .diffEditor, .multiple, .stream, .conflict, .patch].contains(sample) }
    private var supportsControlledSelection: Bool {
        ![DemoSample.file, .editor, .diffEditor, .multiple, .stream].contains(sample) && !(followAppearance && supportsAdaptiveTheme)
    }
    private var supportsComparisonOptions: Bool {
        ![DemoSample.file, .editor, .stream, .conflict, .patch].contains(sample) && (sample != .diffEditor || !editingDiff)
    }
    private var parseOptions: DiffOptions { .init(context: context, ignoreWhitespace: ignoreWhitespace, stripTrailingCr: stripTrailingCr) }
    private var demoInteractionHandlers: DiffInteractionHandlers {
        .init(onLineClick: { event in
            if lastTokenEvent !== event.event { lastInteraction = "Clicked \(event.annotationSide.rawValue):\(event.lineNumber)" }
        }, onLineNumberClick: { event in
            lastInteraction = "Gutter \(event.annotationSide.rawValue):\(event.lineNumber)"
        }, onLineEnter: { event in
            if lastTokenEvent !== event.event { lastInteraction = "Hover \(event.annotationSide.rawValue):\(event.lineNumber)" }
        }, onLineLeave: { _ in
            if lastInteraction?.hasPrefix("Hover ") == true && lastInteraction?.hasPrefix("Hover token") != true { lastInteraction = nil }
        }, enableTokenInteractionsOnWhitespace: interactWithWhitespace, onTokenClick: { event in
            lastTokenEvent = event.event
            lastInteraction = "Token \(event.lineCharStart)–\(event.lineCharEnd): \(event.tokenText.prefix(24))"
                        if showTokenPopovers { presentToken(event.tokenText, in: event.view, rects: event.visibleRects, event: event.event) }
        }, onTokenEnter: { event in
            lastTokenEvent = event.event
            lastInteraction = "Hover token: \(event.tokenText.prefix(24))"
        }, onTokenLeave: { _ in
            if lastInteraction?.hasPrefix("Hover token") == true { lastInteraction = nil }
        }, lineHoverHighlight: hoverHighlight, enableLineSelection: enableLineSelection,
           onLineSelectionChange: { value in
               selectionStatus = value.map { "Proposed lines \($0.startLine)–\($0.endLine)" } ?? "Proposed clear"
           }, onLineSelected: { value in
               if supportsControlledSelection && selectionPolicy == 1 { acceptedSelection = value }
               selectionStatus = supportsControlledSelection && selectionPolicy == 2 ? "Proposal rejected; selection retained" : "Selection accepted"
           }, controlledSelection: supportsControlledSelection && selectionPolicy != 0, enableGutterUtility: showGutterUtility, onGutterUtilityClick: customGutterUtility ? nil : { range in lastInteraction = "Gutter action: lines \(range.startLine)–\(range.endLine)" })
    }
    private var demoAnnotations: [LineAnnotation] {
        guard showAnnotations else { return [] }
        if sample == .diffEditor, let editedAnnotations { return editedAnnotations }
        return [
            LineAnnotation(id: "demo-file", lineNumber: 0, text: "File review: annotations can appear above the first hunk."),
            LineAnnotation(id: "demo-before", side: .deletions, lineNumber: 5, text: "Before: check the original behavior."),
            LineAnnotation(id: "demo-after", lineNumber: 5, text: "After: review the updated behavior."),
            LineAnnotation(id: "demo-note", lineNumber: 5, text: "A second note shares this source line.")
        ]
    }
    private var demoFileAnnotations: [FileLineAnnotation] {
        guard showAnnotations else { return [] }
        return [
            .init(id: "demo-file", lineNumber: 0, text: "File review: comments can appear above the first source line."),
            .init(id: "demo-after", lineNumber: 5, text: "Review this source line."),
            .init(id: "demo-note", lineNumber: 5, text: "A second note shares this source line.")
        ]
    }
    private var demoFileHeaderRenderers: FileHeaderRenderers? {
        if headerMode == 1 {
            return .init(renderHeaderPrefix: { _ in NSTextField(labelWithString: "FILE") },
                         renderHeaderMetadata: { _ in NSTextField(labelWithString: "Native highlighting") })
        }
        if headerMode == 2 {
            return .init(renderCustomHeader: { file in
                let label = NSTextField(labelWithString: "Viewing \(file.name)")
                label.font = .systemFont(ofSize: 15, weight: .medium)
                let container = NSView(frame: .init(x: 0, y: 0, width: 400, height: 56))
                label.frame = .init(x: 16, y: 18, width: 368, height: 20)
                label.autoresizingMask = [.width]; container.addSubview(label)
                return container
            })
        }
        return nil
    }
    private var demoHeaderRenderers: DiffHeaderRenderers? {
        if headerMode == 1 {
            return .init(renderHeaderPrefix: { _ in NSTextField(labelWithString: "REVIEW") },
                         renderHeaderFilenameSuffix: { _ in NSTextField(labelWithString: "• modified") },
                         renderHeaderMetadata: { _ in NSTextField(labelWithString: "Needs review") })
        }
        if headerMode == 2 {
            return .init(renderCustomHeader: { diff in
                DemoReviewHeader(text: "Reviewing \(diff.name)\n\(diff.additions) additions · \(diff.deletions) deletions")
            })
        }
        return nil
    }
    private var patchLoader: DiffContentsLoader? {
        guard sample == .patch && hydratePatch else { return nil }
        var old = (0..<120).map { "// Context line \($0 + 1)\n" }
        old[17] = "  private values = new Map();\n"; old[18] = "  limit = Infinity;\n"
        old[19] = "  get(key) { return this.values.get(key); }\n"; old[20] = "}\n"
        old[79] = "  cache.clear();\n"; old[80] = "}\n"
        var new = old; new[18] = "  limit = 512;\n  maxBytes = 262144;\n"; new[79] = "  cache.dispose();\n"
        let files = LoadedDiffFiles(oldFile: .init(name: "src/cache.ts", contents: old.joined()), newFile: .init(name: "src/cache.ts", contents: new.joined()))
        return { _ in try await Task.sleep(for: .milliseconds(250)); return files }
    }
    private var preparationKey: String { sample.rawValue + options.theme + options.lineDiffType.rawValue + String(context) + String(ignoreWhitespace) + String(stripTrailingCr) + String(followAppearance) + String(hydratePatch) + streamMode.rawValue }
    private func load() async {
        editedAnnotations = nil; streamConfiguration = nil
        isLoading = true; isColorizing = false; error = nil; selection = nil; acceptedSelection = nil; selectionStatus = nil; themedDocument = nil
        do {
            try await highlighter.registerCustomLanguage("review-rules", extensionsOrFilenames: ["reviewdemo"]) {
                [LanguageRegistration(name: "review-rules", grammar: RawGrammar(
                    scopeName: "source.review-rules",
                    patterns: [
                        RawRule(name: "comment.line.number-sign", match: "#.*$"),
                        RawRule(name: "string.quoted.double", begin: "\"", end: "\""),
                        RawRule(name: "keyword.control", match: #"\b(allow|deny|when|and|or)\b"#),
                        RawRule(name: "constant.numeric", match: #"\b[0-9]+\b"#)
                    ]
                ))]
            }
            await highlighter.registerCustomTheme("demo-sea-glass") {
                .init(name: "demo-sea-glass", type: .dark, colors: [
                    "editor.background": "#102326", "editor.foreground": "#c7e6df",
                    "editor.lineHighlightBackground": "#183438",
                    "gitDecoration.addedResourceForeground": "#77d6ab",
                    "gitDecoration.deletedResourceForeground": "#ef9b93",
                    "gitDecoration.modifiedResourceForeground": "#79bded"
                ])
            }
            await highlighter.registerCustomCSSVariableTheme("demo-variable-colors", variableDefaults: [
                "foreground": "#d8dee9", "background": "#202630",
                "token-comment": "#8290a6", "token-keyword": "#c792ea",
                "token-string": "#a3be8c", "token-string-expression": "#a3be8c",
                "token-constant": "#f5b971", "token-parameter": "#d8dee9",
                "token-function": "#82aaff", "token-punctuation": "#aab4c4",
                "token-link": "#88c0d0", "token-inserted": "#a3be8c",
                "token-deleted": "#bf616a", "token-changed": "#ebcb8b",
                "ansi-black": "#202630", "ansi-red": "#bf616a", "ansi-green": "#a3be8c",
                "ansi-yellow": "#ebcb8b", "ansi-blue": "#81a1c1", "ansi-magenta": "#b48ead",
                "ansi-cyan": "#88c0d0", "ansi-white": "#e5e9f0",
                "ansi-bright-black": "#4c566a", "ansi-bright-red": "#bf616a",
                "ansi-bright-green": "#a3be8c", "ansi-bright-yellow": "#ebcb8b",
                "ansi-bright-blue": "#81a1c1", "ansi-bright-magenta": "#b48ead",
                "ansi-bright-cyan": "#8fbcbb", "ansi-bright-white": "#eceff4"
            ])
            let input = await sample.files()
            try Task.checkCancellation()
            if sample == .conflict, let file = input.new {
                options.diffStyle = .unified
                conflictFile = file; document = nil; isLoading = false; return
            }
            if sample == .editor {
                if !editorInitialized { editorText = input.new?.contents ?? ""; editorInitialized = true }
                document = nil; isLoading = false; return
            }
            if sample == .stream {
                let configuration = try await highlighter.streamConfiguration(language: "swift", theme: options.theme,
                    options: .init(tokenizeMaxLineLength: options.tokenizeMaxLineLength, tokenizeTimeLimit: 0))
                try Task.checkCancellation()
                streamConfiguration = configuration
                if streamMode != .snapshots { document = nil; isLoading = false; return }
                let stream = ShikiDiffs.FileStream(name: "Stream.swift", configuration: configuration)
                let source = Array((input.new?.contents ?? "").unicodeScalars)
                for start in stride(from: 0, to: source.count, by: 28) {
                    try Task.checkCancellation()
                    let chunk = String(String.UnicodeScalarView(source[start..<min(source.count, start + 28)]))
                    let prepared = try await stream.append(chunk)
                    try Task.checkCancellation()
                    document = prepared
                    try await Task.sleep(for: .milliseconds(65))
                }
                let prepared = await stream.close()
                try Task.checkCancellation()
                document = prepared; isLoading = false; return
            }
            if sample == .multiple {
                var results: [HighlightedDiff] = []
                var files: [String: FileContents] = [:]
                for index in 0..<60 {
                    try Task.checkCancellation()
                    let old = FileContents(name: "Sources/Module\(index)/Service.swift", contents: DemoSample.oldSwift)
                    let new = FileContents(name: old.name, contents: DemoSample.newSwift)
                    let isFile = index % 5 == 4
                    results.append(try await highlighter.prepare(oldFile: isFile ? new : old, newFile: new, diffOptions: parseOptions, options: options))
                    if isFile { files[new.name] = new }
                }
                try Task.checkCancellation()
                multiDocuments = results; reviewFiles = files; document = results.first; isLoading = false; return
            }
            let result: HighlightedDiff
            if followAppearance && supportsAdaptiveTheme {
                let prepared = try await highlighter.prepareThemes(oldFile: input.old, newFile: input.new, diffOptions: parseOptions, options: options)
                try Task.checkCancellation()
                themedDocument = prepared; document = prepared.dark; isLoading = false; return
            }
            let parsingOptions = parseOptions
            let diff = try await Task.detached(priority: .userInitiated) {
                if let patch = input.patch {
                    let parsed = try parsePatchFiles(patch, throwOnError: true)
                    guard let first = parsed.first?.files.first else { throw DiffError.missingFiles }
                    return first
                }
                return try parseDiffFromFile(input.old, input.new, options: parsingOptions)
            }.value
            try Task.checkCancellation()
            if sample == .diffEditor {
                result = try await highlighter.prepare(diff, options: options)
            } else {
                let preview = try await highlighter.preparePreview(diff, options: options)
                try Task.checkCancellation()
                document = preview; isColorizing = true
                let prefix = try await highlighter.preparePreview(diff, options: options, highlightedLineCount: 64)
                    .identifyingSource(as: preview.sourceID)
                try Task.checkCancellation()
                document = prefix
                result = try await highlighter.prepare(diff, options: options, sourceID: preview.sourceID)
            }
            try Task.checkCancellation()
            document = result; isLoading = false; isColorizing = false
        } catch is CancellationError { }
        catch {
            // A superseded load must not overwrite the next example's status.
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription; isLoading = false; isColorizing = false
        }
    }
}

enum DemoSample: String, CaseIterable, Identifiable {
    case swift, typescript, json, patch, rename, newFile, deleted, unicode, longLine, file, multiple, stream, editor, diffEditor, conflict, customLanguage
    var id: Self { self }
    var title: String {
        switch self {
        case .customLanguage: "Custom language"
        case .swift: "Swift refactor"
        case .typescript: "TypeScript component"
        case .json: "Large JSON · 1 MB"
        case .patch: "Patch with collapsed context"
        case .rename: "Renamed file"
        case .newFile: "New file"
        case .deleted: "Deleted file"
        case .unicode: "Unicode & line endings"
        case .longLine: "Long lines"
        case .file: "Highlighted file"
        case .multiple: "Multi-file review"
        case .stream: "Streaming code"
        case .editor: "Native editor"
        case .diffEditor: "Editable diff"
        case .conflict: "Merge conflicts"
        }
    }
    var icon: String {
        switch self {
        case .customLanguage: "textformat.abc"
        case .swift: "swift"
        case .typescript: "curlybraces"
        case .json: "speedometer"
        case .patch: "doc.text.magnifyingglass"
        case .rename: "arrow.triangle.branch"
        case .newFile: "doc.badge.plus"
        case .deleted: "document.on.trash"
        case .unicode: "character.cursor.ibeam"
        case .longLine: "arrow.left.and.right"
        case .file: "doc.text"
        case .multiple: "square.stack.3d.up"
        case .stream: "text.append"
        case .editor: "pencil.line"
        case .diffEditor: "square.and.pencil"
        case .conflict: "arrow.triangle.merge"
        }
    }
    var subtitle: String {
        switch self {
        case .customLanguage: "Review rules highlighted by a lazily registered TextMate grammar."
        case .conflict: "Current, base, and incoming sections with source-faithful conflict resolution."
        case .editor: "Native selection, undo/redo, input methods, and ⌘F find. Highlighting runs off the main thread."
        case .diffEditor: "Edit the additions column. Regions stay visible through undo; apply or discard when finished."
        case .multiple: "60 files in one review. Only files in the viewport have mounted native views."
        case .stream: "New chunks recall only the incomplete line; stable lines retain their grammar state."
        case .json: "Expand unchanged lines, then jump through the document to inspect scrolling."
        case .patch: "A partial Git patch. Hidden source remains unavailable until hydration."
        case .unicode: "Emoji, combining marks, tabs, CRLF, and an end-of-file newline change."
        case .longLine: "Horizontal scrolling across lines exceeding the tokenization limit."
        default: "Syntax highlighting, inline changes, and synchronized native scrolling."
        }
    }
    nonisolated func files() async -> DemoInput {
        switch self {
        case .conflict: return .pair("src/settings.ts", "", "const config = {\n<<<<<<< HEAD\n  theme: 'dark',\n||||||| base\n  theme: 'system',\n=======\n  theme: 'light',\n>>>>>>> feature/themes\n  fontSize: 14,\n<<<<<<< HEAD\n  context: 4,\n=======\n  context: 6,\n>>>>>>> feature/context\n};\n")
        case .customLanguage:
            return .pair("policy.reviewdemo", """
            # Repository review policy
            allow "merge" when approvals >= 1
            deny "release" when failures > 0
            allow "preview" when branch == "main"

            """, """
            # Repository review policy
            allow "merge" when approvals >= 2 and failures == 0
            deny "release" when failures > 0
            allow "preview" when branch == "main" or branch == "staging"

            """)
        case .file: return .pair("Sources/DiffEngine.swift", Self.newSwift, Self.newSwift)
        case .multiple, .stream, .editor, .diffEditor: return .pair("Sources/DiffEngine.swift", Self.oldSwift, Self.newSwift)
        case .swift:
            return .pair("Sources/Library/DiffEngine.swift", Self.oldSwift, Self.newSwift)
        case .typescript:
            return .pair("src/components/CodeReview.tsx", """
            import { useState } from 'react';
            import { FileDiff } from '@pierre/diffs/react';

            interface ReviewProps {
              original: string;
              updated: string;
            }

            export function CodeReview({ original, updated }: ReviewProps) {
              const [mode, setMode] = useState('unified');
              return (
                <section className="review">
                  <h2>Changes</h2>
                  <FileDiff
                    oldFile={{ name: 'file.ts', contents: original }}
                    newFile={{ name: 'file.ts', contents: updated }}
                    options={{ diffStyle: mode }}
                  />
                </section>
              );
            }
            """, """
            import { useState, useCallback } from 'react';
            import { FileDiff } from '@pierre/diffs/react';

            interface ReviewProps {
              original: string;
              updated: string;
              filename: string;
              onApprove?: () => void;
            }

            export function CodeReview({ original, updated, filename, onApprove }: ReviewProps) {
              const [mode, setMode] = useState('split');
              const approve = useCallback(() => onApprove?.(), [onApprove]);
              return (
                <section className="review-container">
                  <header>
                    <h2>{filename}</h2>
                    <button onClick={approve}>Approve changes</button>
                  </header>
                  <FileDiff
                    oldFile={{ name: filename, contents: original }}
                    newFile={{ name: filename, contents: updated }}
                    options={{ diffStyle: mode, theme: 'github-dark' }}
                  />
                </section>
              );
            }
            """)
        case .json:
            var rows = ["{\n  \"items\": [\n"]
            for index in 0..<12_000 {
                rows.append("    { \"id\": \(index), \"name\": \"Item \(index)\", \"enabled\": true, \"region\": \"ap-south-1\", \"score\": 42 }" + (index == 11_999 ? "\n" : ",\n"))
            }
            rows.append("  ]\n}\n")
            let old = rows.joined()
            for i in stride(from: 42, to: 12_000, by: 701) { rows[i] = rows[i].replacingOccurrences(of: "true", with: "false").replacingOccurrences(of: "42", with: "99") }
            return .pair("fixtures/catalog.json", old, rows.joined())
        case .patch:
            return DemoInput(old: nil, new: nil, patch: "diff --git a/src/cache.ts b/src/cache.ts\nindex abc123..def456 100644\n--- a/src/cache.ts\n+++ b/src/cache.ts\n@@ -18,4 +18,5 @@ export class Cache {\n   private values = new Map();\n-  limit = Infinity;\n+  limit = 512;\n+  maxBytes = 262144;\n   get(key) { return this.values.get(key); }\n }\n@@ -80,2 +81,2 @@ function reset() {\n-  cache.clear();\n+  cache.dispose();\n }\n")
        case .rename: return DemoInput(old: .init(name: "src/old-name.swift", contents: Self.oldSwift), new: .init(name: "Sources/DiffEngine.swift", contents: Self.newSwift))
        case .newFile: return DemoInput(old: nil, new: .init(name: "Sources/DiffEngine.swift", contents: Self.newSwift))
        case .deleted: return DemoInput(old: .init(name: "Sources/Legacy.swift", contents: Self.oldSwift), new: nil)
        case .unicode: return .pair("Greeting.swift", "// Hello 👩🏽‍💻\r\nlet greeting = \"café\"\r\n\tprint(\"你好 🌍\")\r\n", "// Hello 👨🏻‍💻\r\nlet greeting = \"café\"\r\n\tprint(\"こんにちは 🌏\")")
        case .longLine:
            let line = "let values = [" + (0..<800).map { "\"value\($0)\"" }.joined(separator: ", ") + "]\n"
            return .pair("LongLine.swift", line, line.replacingOccurrences(of: "value400", with: "changed400"))
        }
    }
    nonisolated static let oldSwift = """
    import AppKit
    import Foundation

    /// Prepares a code document for presentation.
    final class DiffEngine {
        private var cache: [String: NSAttributedString] = [:]
        private let fontSize: CGFloat = 13

        func render(_ source: String) -> NSAttributedString {
            if let cached = cache[source] {
                return cached
            }

            let text = NSAttributedString(
                string: source,
                attributes: [.font: NSFont.monospacedSystemFont(
                    ofSize: fontSize,
                    weight: .regular
                )]
            )
            cache[source] = text
            return text
        }

        func clear() {
            cache.removeAll()
        }
    }

    """
    nonisolated static let newSwift = """
    import AppKit
    import Foundation
    import Shiki

    /// Prepares only the requested viewport for presentation.
    actor DiffEngine {
        private let cache = LineCache(capacity: 512)
        private let highlighter: ShikiHighlighter
        private let fontSize: CGFloat = 14

        init() throws {
            highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
        }

        func render(_ source: String, lines: Range<Int>) throws -> TokensResult {
            try Task.checkCancellation()
            let result = try highlighter.codeToTokens(
                source,
                language: "swift",
                theme: "github-dark"
            )
            cache.insert(result, for: lines)
            return result
        }

        func clear() {
            cache.removeAll(keepingCapacity: true)
        }
    }

    """
}
struct DemoInput: Sendable {
    var old: FileContents?
    var new: FileContents?
    var patch: String? = nil
    nonisolated static func pair(_ name: String, _ old: String, _ new: String) -> Self { .init(old: .init(name: name, contents: old), new: .init(name: name, contents: new)) }
}

/// Real wrapping text exercises the library's width-dependent header measurement.
@MainActor private final class DemoReviewHeader: NSView {
    private let label: NSTextField
    init(text: String) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("Use init(text:)") }
    override var intrinsicContentSize: NSSize {
        let measured = label.cell?.cellSize(forBounds: .init(x: 0, y: 0, width: max(1, bounds.width - 32), height: .greatestFiniteMagnitude)).height ?? 44
        return .init(width: NSView.noIntrinsicMetric, height: max(76, measured + 32))
    }
    override func layout() { super.layout(); label.frame = bounds.insetBy(dx: 16, dy: 16) }
}


private struct DemoGutterUtility: View {
    let getHoveredLine: @MainActor () -> DiffHoveredLine?
    @State private var target: DiffHoveredLine?
    @State private var showingTarget = false
    var body: some View {
        Button {
            target = getHoveredLine()
            showingTarget = target != nil
        } label: {
            Image(systemName: "plus").frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
        .help("Show gutter target")
        .popover(isPresented: $showingTarget) {
            if let target {
                Text("Line \(target.lineNumber) · \(target.side.rawValue)")
                    .padding(16)
            }
        }
    }
}

private struct DemoHunkSeparator: View {
    let data: HunkData
    let expand: DiffSeparatorRenderer.Expand
    var body: some View {
        HStack(spacing: 10) {
            Text(data.lineCountKnown ? "\(data.lines) unchanged lines" : "More context")
                .font(.caption)
            Spacer(minLength: 0)
            ForEach(data.expansionActions, id: \.rawValue) { action in
                Button(action == .all ? "Show all" : "Expand \(action.rawValue)") { _ = expand(action) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
    }
}

private struct DemoConflictActions: View {
    let index: Int
    let resolve: DiffConflictActionRenderer.Resolve
    var body: some View {
        HStack(spacing: 12) {
            Text("Conflict \(index + 1)").font(.caption)
            Button("Keep current") { _ = resolve(.deletions) }
            Button("Use incoming") { _ = resolve(.additions) }
            Button("Keep both") { _ = resolve(.both) }
        }
        .buttonStyle(.bordered)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


private enum DemoPredictionExample: String, CaseIterable, Sendable {
    case off = "Off", inline = "Inline insertion", multiline = "Multiple lines", replacement = "Replace word", deletion = "Delete word"
    private static let inlineProvider = make(.inline)
    private static let multilineProvider = make(.multiline)
    private static let replacementProvider = make(.replacement)
    private static let deletionProvider = make(.deletion)
    var provider: EditPredictProvider? {
        switch self {
        case .off: nil
        case .inline: Self.inlineProvider
        case .multiline: Self.multilineProvider
        case .replacement: Self.replacementProvider
        case .deletion: Self.deletionProvider
        }
    }
    private enum NoSuggestion: Error { case emptyWord }
    private static func make(_ example: Self) -> EditPredictProvider {
        .init { request in
            try Task.checkCancellation()
            let excerpt = TextDocument(uri: request.path, text: request.excerptText)
            let cursor = excerpt.positionAt(request.cursorOffsetInExcerpt)
            func absolute(_ position: TextPosition) -> TextPosition { .init(line: position.line + request.excerptStartLine, character: position.character) }
            let start: TextPosition, end: TextPosition, text: String, next: TextPosition
            switch example {
            case .multiline:
                start = .init(line: cursor.line, character: 0); end = start
                text = "// Suggested comment" + request.eol; next = .init(line: cursor.line + 1, character: cursor.character)
            case .replacement, .deletion:
                let word = expandCollapsedSelectionToWord(excerpt, selection: .init(start: cursor, end: cursor))
                guard !word.isCollapsed else { throw NoSuggestion.emptyWord }
                start = word.start; end = word.end
                text = example == .deletion ? "" : "updatedValue"
                next = .init(line: start.line, character: start.character + text.utf16.count)
            default:
                start = cursor; end = cursor; text = " /* suggested */"
                next = .init(line: cursor.line, character: cursor.character + text.utf16.count)
            }
            return .init(edits: [.init(range: .init(start: absolute(start), end: absolute(end)), newText: text)], newCursor: absolute(next))
        }
    }
}

private struct DemoSelectionActions: View {
    let context: SelectionActionContext
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button("Uppercase") { replace(context.getSelectionText().uppercased()) }
                Button("Lowercase") { replace(context.getSelectionText().lowercased()) }
                Button { context.close() } label: { Image(systemName: "xmark") }
                    .help("Close selection actions")
            }.buttonStyle(.borderless).controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(4).fixedSize()
    }
    private func replace(_ text: String) {
        do { _ = try context.replaceSelectionText(text); context.close() }
        catch { self.error = error.localizedDescription }
    }
}

#if os(macOS)
import AppKit

public struct EditPredictProvider: Sendable {
    private(set) var id = UUID()
    public var predict: @Sendable (EditPredictRequest) async throws -> EditPredictResponse { didSet { id = UUID() } }
    public init(predict: @escaping @Sendable (EditPredictRequest) async throws -> EditPredictResponse) { self.predict = predict }
}
public enum EditPredictionMode: Sendable { case eager, subtle }
public struct EditPredictionOptions: Sendable {
    public var provider: EditPredictProvider
    public var mode: EditPredictionMode
    public var include: [EditPredictionPattern]?
    public var exclude: [EditPredictionPattern]?
    public init(provider: EditPredictProvider, mode: EditPredictionMode = .eager,
                include: [EditPredictionPattern]? = nil, exclude: [EditPredictionPattern]? = nil) {
        self.provider = provider; self.mode = mode; self.include = include; self.exclude = exclude
    }
    func matches(_ path: String) -> Bool {
        let path = path.replacingOccurrences(of: "\\", with: "/")
        return (include?.contains { matchesEditPredictionPattern(path: path, pattern: $0) } ?? true)
            && !(exclude?.contains { matchesEditPredictionPattern(path: path, pattern: $0) } ?? false)
    }
    func sameConfiguration(as other: Self) -> Bool {
        provider.id == other.provider.id && mode == other.mode && include == other.include && exclude == other.exclude
    }
}
struct EditPredictionGroup {
    var edit: TextEdit
    var insertionSuffix: String?
    var suffixStart: TextPosition?
}
/// Shares one composition between spacer measurement and drawing, matching the
/// upstream rule that edits touching the same source line form one preview.
func composeEditPredictionGroups(_ response: EditPredictResponse, document: TextDocument) -> [EditPredictionGroup] {
    var groups: [EditPredictionGroup] = [], index = 0
    while index < response.edits.count {
        let first = response.edits[index]; var endIndex = index, endLine = first.range.end.line
        while endIndex + 1 < response.edits.count && response.edits[endIndex + 1].range.start.line <= endLine {
            endIndex += 1; endLine = max(endLine, response.edits[endIndex].range.end.line)
        }
        if endIndex == index && (first.newText.isEmpty || first.range.start == first.range.end) {
            let suffix = first.range.start == first.range.end && first.range.start.character < ((try? document.getLineLength(first.range.start.line)) ?? 0)
                ? document.getTextSlice(start: document.offsetAt(first.range.start), end: document.offsetAt(.init(line: first.range.start.line, character: Int.max))) : nil
            groups.append(.init(edit: first, insertionSuffix: suffix, suffixStart: suffix == nil ? nil : first.range.start))
        } else {
            let end = TextPosition(line: endLine, character: (try? document.getLineLength(endLine)) ?? 0)
            var parts: [String] = [], consumed = document.offsetAt(first.range.start)
            for edit in response.edits[index...endIndex] {
                parts.append(document.getTextSlice(start: consumed, end: document.offsetAt(edit.range.start))); parts.append(edit.newText)
                consumed = document.offsetAt(edit.range.end)
            }
            parts.append(document.getTextSlice(start: consumed, end: document.offsetAt(end)))
            groups.append(.init(edit: .init(range: .init(start: first.range.start, end: end), newText: parts.joined())))
        }
        index = endIndex + 1
    }
    return groups
}
@MainActor final class EditorPredictionPreview {
    let id = UUID()
    let response: EditPredictResponse
    let groups: [EditPredictionGroup]
    var rendered = false
    init(_ response: EditPredictResponse, document: TextDocument) {
        self.response = response; groups = composeEditPredictionGroups(response, document: document)
    }
}
@MainActor final class EditorPredictionController {
    weak var editor: DiffEditor?
    private var options: EditPredictionOptions
    private var task: Task<Void, Never>?
    private var generation = 0
    private var identity: Input?
    private var retryOnRender = false
    private var revealed = false
    private(set) var preview: EditorPredictionPreview?
    private(set) var history: [EditPredictionHistoryRecord] = []
    var applying = false
    private var compositionHistory: [EditPredictionHistoryRecord]?
    func beginComposition() { if compositionHistory == nil { compositionHistory = history } }
    func finishComposition() { compositionHistory = nil }
    func cancelComposition() { if let compositionHistory { history = compositionHistory }; compositionHistory = nil; cancel() }
    private struct Input: Equatable {
        var origin: UUID; var version: Int; var path: [UInt16]; var selections: [EditorSelection]; var marked: Bool
    }
    init(editor: DiffEditor, options: EditPredictionOptions) { self.editor = editor; self.options = options; if editor.hasMarkedText() { compositionHistory = [] } }
    func configure(_ value: EditPredictionOptions) {
        guard !options.sameConfiguration(as: value) else { return }
        options = value; inputChanged(force: true)
    }
    private func input(_ editor: DiffEditor) -> Input {
        .init(origin: editor.document.historyIdentity.origin, version: editor.document.version, path: Array(editor.predictionPath.utf16),
              selections: editor.getSelections(), marked: editor.hasMarkedText())
    }
    func cancel() {
        task?.cancel(); task = nil; generation += 1; retryOnRender = false; revealed = false
        preview?.rendered = false; preview = nil
        editor?.predictionView?.setPredictionPreview(nil)
    }
    func reset() { cancel(); identity = nil; history = []; compositionHistory = nil }
    func inputChanged(force: Bool = false) {
        guard let editor else { cancel(); return }
        let current = input(editor)
        guard force || current != identity else { return }
        cancel(); identity = current
        guard editor.isActive, !editor.isSuspended, !current.marked, current.selections.count == 1,
              current.selections[0].isCollapsed, options.matches(editor.predictionPath) else { return }
        let generation = generation
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let work = self?.makeRequest(generation: generation) else { return }
                let provider = work.provider, request = work.request
                let job = Task.detached(priority: .utility) { try await provider.predict(request) }
                let response = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                try Task.checkCancellation()
                self?.receive(response, request: request, generation: generation)
            } catch { /* Providers may fail or ignore cancellation; stale results never install. */ }
        }
    }
    private func makeRequest(generation: Int) -> (provider: EditPredictProvider, request: EditPredictRequest)? {
        guard generation == self.generation, let editor, editor.isActive, !editor.isSuspended, identity == input(editor),
              let selection = editor.getSelections().first, let view = editor.predictionView else { return nil }
        let lines = view.predictionVisibleLines
        guard editor.predictionPresentationIsCurrent, lines.contains(selection.focus.line) else { retryOnRender = true; return nil }
        guard let request = buildEditPredictionRequest(path: editor.predictionPath, document: editor.document,
                cursorOffset: editor.document.offsetAt(selection.focus), history: history, isLineEditable: { lines.contains($0) }) else { return nil }
        return (options.provider, request)
    }
    private func receive(_ response: EditPredictResponse, request: EditPredictRequest, generation: Int) {
        guard generation == self.generation, let editor, editor.isActive, !editor.isSuspended, identity == input(editor),
              let response = validateEditPredictionResponse(response, request: request, document: editor.document) else { return }
        preview = EditorPredictionPreview(response, document: editor.document)
        editor.predictionView?.setPredictionPreview(options.mode == .eager || revealed ? preview : nil)
    }
    func presentationChanged() {
        guard let editor, editor.isActive, !editor.isSuspended else { return }
        if retryOnRender, editor.predictionPresentationIsCurrent, let selection = editor.getSelections().first,
           editor.predictionView?.predictionVisibleLines.contains(selection.focus.line) == true { inputChanged(force: true) }
    }
    func recordTransaction() {
        guard let editor, options.matches(editor.predictionPath), let transaction = editor.document.lastChangeTransaction else { return }
        history = recordEditPrediction(history: history, path: editor.predictionPath, document: editor.document,
                                       transaction: transaction, source: applying ? .prediction : .user)
    }
    var canAccept: Bool {
        guard let editor, editor.isActive, !editor.isSuspended, identity == input(editor), let preview else { return false }
        return preview.rendered && editor.predictionView?.isPredictionVisible(preview) == true
    }
    @discardableResult func accept() -> Bool {
        guard canAccept, let editor, let response = preview?.response else { return false }
        cancel(); applying = true
        defer { applying = false }
        return editor.applyPrediction(response)
    }
    @discardableResult func dismiss() -> Bool {
        guard preview != nil else { return false }; cancel(); return true
    }
    func toggleReveal() {
        guard options.mode == .subtle, let preview else { return }
        revealed.toggle(); preview.rendered = false
        editor?.predictionView?.setPredictionPreview(revealed ? preview : nil)
    }
    deinit { task?.cancel() }
}

#endif

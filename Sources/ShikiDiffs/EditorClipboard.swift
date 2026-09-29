#if os(macOS)
// Native adaptation of @pierre/diffs editor selection clipboard helpers.
import Foundation

private func clipboardRegions(_ document: TextDocument, selections: [EditorSelection]) -> [NSRange] {
    var ranges: [NSRange] = selections.map { selection in
        let start: Int, end: Int
        if selection.isCollapsed {
            let line = selection.start.line
            start = document.offsetAt(.init(line: line, character: 0))
            end = line < document.lineCount - 1 ? document.offsetAt(.init(line: line + 1, character: 0)) : document.utf16Length
        } else {
            let a = document.offsetAt(selection.start), b = document.offsetAt(selection.end)
            start = min(a, b); end = max(a, b)
        }
        return .init(location: start, length: end - start)
    }
    ranges.sort { a, b in a.location == b.location ? a.length < b.length : a.location < b.location }
    return ranges
}
public func getSelectionClipboardTexts(_ document: TextDocument, selections: [EditorSelection]) -> [String] {
    clipboardRegions(document, selections: selections).map { try! document.getText(in: $0) }
}
public func getSelectionText(_ document: TextDocument, selections: [EditorSelection]) -> String {
    var result = "", previousEnd = -1
    for range in clipboardRegions(document, selections: selections) {
        let start = range.location, end = NSMaxRange(range)
        if end <= start { continue }
        if start <= previousEnd {
            if end > previousEnd {
                result += try! document.getText(in: .init(location: previousEnd, length: end - previousEnd))
                previousEnd = end
            }
            continue
        }
        if !result.isEmpty, result.utf16.last != 10, result.utf16.last != 13 { result += document.eol }
        result += try! document.getText(in: range)
        previousEnd = end
    }
    return result
}
public struct EditorSelectionCut: Sendable {
    public var text: String
    public var edits: [ResolvedTextEdit]
    public var nextSelectionOffsets: [Int]
}
public func resolveSelectionCut(_ document: TextDocument, selections: [EditorSelection]) -> EditorSelectionCut {
    var cuts: [(index: Int, start: Int, end: Int)] = selections.enumerated().map { index, selection in
        var start = document.offsetAt(selection.start), end = document.offsetAt(selection.end)
        if selection.isCollapsed {
            let line = selection.start.line
            if line < document.lineCount - 1 {
                start = document.offsetAt(.init(line: line, character: 0)); end = document.offsetAt(.init(line: line + 1, character: 0))
            } else {
                start = line > 0 ? document.offsetAt(.init(line: line - 1, character: document.getLineText(line - 1).utf16.count)) : 0
                end = document.utf16Length
            }
        }
        return (index, min(start, end), max(start, end))
    }
    cuts.sort { a, b in
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        return a.index < b.index
    }
    var edits: [ResolvedTextEdit] = []
    for cut in cuts where cut.start < cut.end {
        if let last = edits.last, cut.start <= NSMaxRange(last.range) {
            edits[edits.count - 1].range.length = max(NSMaxRange(last.range), cut.end) - last.range.location
        } else { edits.append(.init(range: .init(location: cut.start, length: cut.end - cut.start), newText: "")) }
    }
    var next = Array(repeating: 0, count: cuts.count), editIndex = 0, delta = 0
    for cut in cuts {
        while editIndex < edits.count && cut.start > NSMaxRange(edits[editIndex].range) {
            delta -= edits[editIndex].range.length; editIndex += 1
        }
        if editIndex < edits.count, cut.start >= edits[editIndex].range.location, cut.start <= NSMaxRange(edits[editIndex].range) {
            next[cut.index] = edits[editIndex].range.location + delta
        } else { next[cut.index] = cut.start + delta }
    }
    return .init(text: getSelectionText(document, selections: selections), edits: edits, nextSelectionOffsets: next)
}


/// Override paste reads without replacing AppKit's copy/cut pasteboard behavior.
/// A nil type requests plain text; multiple selections also request `selectionType`.
public struct EditorClipboardProvider: Sendable {
    public static let selectionType = "application/vnd.pierre.diffs-selections+json"
    private(set) var id = UUID()
    public var readText: @Sendable (String?) async throws -> String { didSet { id = UUID() } }
    public init(readText: @escaping @Sendable (String?) async throws -> String) { self.readText = readText }
}

@MainActor final class EditorClipboardController {
    private weak var editor: DiffEditor?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var input: Input?
    var isReading: Bool { task != nil }
    private struct Input: Equatable {
        var origin: UUID
        var revision: UInt64
        var selections: [EditorSelection]
        var provider: UUID
    }
    init(editor: DiffEditor) { self.editor = editor }
    deinit { task?.cancel() }
    private func currentInput() -> Input? {
        guard let editor, editor.isActive, editor.predictionView != nil,
              !editor.hasMarkedText(), editor.hasEditableSelection, let provider = editor.clipboard else { return nil }
        return .init(origin: editor.document.historyIdentity.origin, revision: editor.document.historyIdentity.revision,
                     selections: editor.getSelections(), provider: provider.id)
    }
    func cancel() { task?.cancel(); task = nil; input = nil; generation &+= 1 }
    func inputChanged() { if task != nil, input != currentInput() { cancel() } }
    func paste() {
        cancel()
        guard let input = currentInput(), let provider = editor?.clipboard else { return }
        self.input = input
        let generation = generation
        task = Task { [weak self] in
            // Host I/O must not occupy the main actor. Cancellation is forwarded,
            // but the identity check also handles providers that ignore it.
            let read = Task.detached(priority: .userInitiated) {
                let text = try await provider.readText(nil)
                try Task.checkCancellation()
                var texts = Array(repeating: text, count: input.selections.count)
                if input.selections.count > 1 {
                    let metadata = try await provider.readText(EditorClipboardProvider.selectionType)
                    try Task.checkCancellation()
                    if let paired = try? JSONDecoder().decode([String].self, from: Data(metadata.utf8)), paired.count == texts.count { texts = paired }
                }
                return texts
            }
            do {
                let texts = try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.task = nil; self.input = nil
                guard self.currentInput() == input else { return }
                self.editor?.pasteTexts(texts, into: input.selections)
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.task = nil; self.input = nil
                guard self.currentInput() == input else { return }
                if !(error is CancellationError) { self.editor?.onError?(error) }
            }
        }
    }
}

#endif

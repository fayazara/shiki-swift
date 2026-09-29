#if os(macOS)
import Foundation

public enum EditHistoryCoalescingMode: String, Codable, Sendable { case insert, backspace, delete }
public struct EditHistoryEntry: Sendable {
    public var forwardEdits: [ResolvedTextEdit]
    public var inverseEdits: [ResolvedTextEdit]
    public var versionBefore: Int
    public var versionAfter: Int
    public var selectionsBefore: [EditorSelection]?
    public var selectionsAfter: [EditorSelection]?
    public var lineAnnotationsBefore: [LineAnnotation]?
    public var lineAnnotationsAfter: [LineAnnotation]?
    public var coalescingMode: EditHistoryCoalescingMode?
    public var undoBoundary: Bool
    public init(forwardEdits: [ResolvedTextEdit], inverseEdits: [ResolvedTextEdit], versionBefore: Int, versionAfter: Int,
                selectionsBefore: [EditorSelection]? = nil, selectionsAfter: [EditorSelection]? = nil,
                lineAnnotationsBefore: [LineAnnotation]? = nil, lineAnnotationsAfter: [LineAnnotation]? = nil,
                coalescingMode: EditHistoryCoalescingMode? = nil, undoBoundary: Bool = false) {
        self.forwardEdits = forwardEdits; self.inverseEdits = inverseEdits; self.versionBefore = versionBefore; self.versionAfter = versionAfter
        self.selectionsBefore = selectionsBefore; self.selectionsAfter = selectionsAfter
        self.lineAnnotationsBefore = lineAnnotationsBefore; self.lineAnnotationsAfter = lineAnnotationsAfter
        self.coalescingMode = coalescingMode; self.undoBoundary = undoBoundary
    }
}
/// Independent copy-on-write history snapshot. The caller owns modifications;
/// pass it to EditStack(state:) to transfer it into another document.
public struct EditHistoryState: Sendable {
    public var undoStack: [EditHistoryEntry]
    public var redoStack: [EditHistoryEntry]
    public var maxEntries: Int
    public var canCoalesce: Bool
    public init(undoStack: [EditHistoryEntry] = [], redoStack: [EditHistoryEntry] = [], maxEntries: Int = 100, canCoalesce: Bool = false) {
        self.undoStack = undoStack; self.redoStack = redoStack; self.maxEntries = max(1, maxEntries); self.canCoalesce = canCoalesce
    }
}
public struct EditStack: Sendable {
    private var state: EditHistoryState
    public init(maxEntries: Int = 100) { state = .init(maxEntries: maxEntries) }
    public init(state: EditHistoryState) { self.state = state; self.state.maxEntries = max(1, state.maxEntries) }
    public var canUndo: Bool { !state.undoStack.isEmpty }
    public var canRedo: Bool { !state.redoStack.isEmpty }
    public func getState() -> EditHistoryState { state }
    public func peekUndo() -> EditHistoryEntry? { state.undoStack.last }
    public func peekUndoForCoalescing() -> EditHistoryEntry? { state.canCoalesce ? peekUndo() : nil }
    public mutating func clear() { state.undoStack = []; state.redoStack = []; state.canCoalesce = false }
    public mutating func clearRedo() { state.redoStack = [] }
    public mutating func breakCoalescing() { state.canCoalesce = false }
    public mutating func push(_ entry: EditHistoryEntry) {
        state.undoStack.append(entry); clearRedo(); state.canCoalesce = true
        if state.undoStack.count > state.maxEntries { state.undoStack.removeFirst(state.undoStack.count - state.maxEntries) }
    }
    public mutating func replaceLastUndo(_ entry: EditHistoryEntry) {
        guard !state.undoStack.isEmpty else { push(entry); return }
        state.undoStack[state.undoStack.count - 1] = entry; clearRedo(); state.canCoalesce = true
    }
    public mutating func setLastUndoSelectionsAfter(_ selections: [EditorSelection]) {
        guard !state.undoStack.isEmpty else { return }; state.undoStack[state.undoStack.count - 1].selectionsAfter = selections
    }
    public mutating func setLastUndoLineAnnotations(before: [LineAnnotation], after: [LineAnnotation]) {
        guard !state.undoStack.isEmpty else { return }
        state.undoStack[state.undoStack.count - 1].lineAnnotationsBefore = before
        state.undoStack[state.undoStack.count - 1].lineAnnotationsAfter = after
    }
    public mutating func popUndoToRedo() -> EditHistoryEntry? {
        guard let entry = state.undoStack.popLast() else { return nil }
        state.redoStack.append(entry); state.canCoalesce = false; return entry
    }
    public mutating func popRedoToUndo() -> EditHistoryEntry? {
        guard let entry = state.redoStack.popLast() else { return nil }
        state.undoStack.append(entry); state.canCoalesce = false; return entry
    }
    mutating func setCapacity(_ value: Int) { state.maxEntries = max(1, value) }
    mutating func retainUndoEntries(_ count: Int) {
        if state.undoStack.count > count { state.undoStack.removeFirst(state.undoStack.count - max(0, count)) }
    }
    mutating func coalesceLastTwo() -> Bool {
        guard state.undoStack.count >= 2 else { return false }
        let next = state.undoStack[state.undoStack.count - 1], previous = state.undoStack[state.undoStack.count - 2]
        guard shouldCoalesceEditStackEntry(previous, next) else { return false }
        state.undoStack.removeLast(2); push(coalesceEditStackEntries(previous, next)); return true
    }
}

public func createEditStackEntry(_ document: TextDocument, resolvedEdits: [ResolvedTextEdit], versionBefore: Int, versionAfter: Int,
                                selectionsBefore: [EditorSelection]? = nil, selectionsAfter: [EditorSelection]? = nil,
                                lineAnnotationsBefore: [LineAnnotation]? = nil, lineAnnotationsAfter: [LineAnnotation]? = nil) throws -> EditHistoryEntry {
    let edits = resolvedEdits.enumerated().sorted { $0.element.range.location == $1.element.range.location ? $0.offset < $1.offset : $0.element.range.location < $1.element.range.location }.map(\.element)
    var inverse: [ResolvedTextEdit] = [], delta = 0, mode: EditHistoryCoalescingMode?
    if let selectionsBefore, selectionsBefore.count == edits.count, selectionsBefore.allSatisfy(\.isCollapsed) {
        let offsets = selectionsBefore.map { document.offsetAt($0.start) }.sorted()
        let deletes = edits.allSatisfy { $0.newText.isEmpty && $0.range.length > 0 }
        if deletes && zip(edits, offsets).allSatisfy({ NSMaxRange($0.0.range) == $0.1 }) { mode = .backspace }
        else if deletes && zip(edits, offsets).allSatisfy({ $0.0.range.location == $0.1 }) { mode = .delete }
    }
    for edit in edits {
        let removed = try document.getText(in: edit.range), length = edit.newText.utf16.count
        inverse.append(.init(range: .init(location: edit.range.location + delta, length: length), newText: removed))
        delta += length - edit.range.length
    }
    return .init(forwardEdits: edits, inverseEdits: inverse, versionBefore: versionBefore, versionAfter: versionAfter,
                 selectionsBefore: selectionsBefore, selectionsAfter: selectionsAfter, lineAnnotationsBefore: lineAnnotationsBefore,
                 lineAnnotationsAfter: lineAnnotationsAfter, coalescingMode: mode)
}

public func shouldCoalesceEditStackEntry(_ previous: EditHistoryEntry?, _ next: EditHistoryEntry) -> Bool {
    guard let previous, !previous.undoBoundary, !next.undoBoundary, !previous.forwardEdits.isEmpty,
          previous.forwardEdits.count == previous.inverseEdits.count, previous.forwardEdits.count == next.forwardEdits.count,
          next.forwardEdits.count == next.inverseEdits.count else { return false }
    var mode: EditHistoryCoalescingMode?
    for index in previous.forwardEdits.indices {
        let pf = previous.forwardEdits[index], pi = previous.inverseEdits[index], nf = next.forwardEdits[index], ni = next.inverseEdits[index]
        let mapped = mapHistoryOffsetToBefore(nf.range.location, edits: previous.forwardEdits)
        let nextMode: EditHistoryCoalescingMode
        if !pf.newText.isEmpty && !pf.newText.contains("\n") && !pi.newText.contains("\n"),
           nf.range.length == 0 && !nf.newText.isEmpty && !nf.newText.contains("\n") && ni.newText.isEmpty {
            guard nf.range.location == NSMaxRange(pi.range) else { return false }; nextMode = .insert
        } else if pf.newText.isEmpty && pf.range.length > 0 && !pi.newText.isEmpty,
                  nf.newText.isEmpty && nf.range.length > 0 && !ni.newText.isEmpty {
            if mapped == NSMaxRange(pf.range) { nextMode = .delete }
            else if mapped + nf.range.length == pf.range.location { nextMode = .backspace }
            else { return false }
        } else { return false }
        guard mode == nil || mode == nextMode,
              previous.coalescingMode == nil || previous.coalescingMode == nextMode,
              next.coalescingMode == nil || next.coalescingMode == nextMode else { return false }
        mode = nextMode
    }
    return mode != nil
}

/// Call only for entries accepted by shouldCoalesceEditStackEntry.
public func coalesceEditStackEntries(_ previous: EditHistoryEntry, _ next: EditHistoryEntry) -> EditHistoryEntry {
    guard shouldCoalesceEditStackEntry(previous, next) else { return next }
    var forward: [ResolvedTextEdit] = [], inverse: [ResolvedTextEdit] = [], delta = 0
    var mode: EditHistoryCoalescingMode?
    for index in previous.forwardEdits.indices {
        let pf = previous.forwardEdits[index], pi = previous.inverseEdits[index], nf = next.forwardEdits[index], ni = next.inverseEdits[index]
        let mapped = mapHistoryOffsetToBefore(nf.range.location, edits: previous.forwardEdits)
        let edit: ResolvedTextEdit, removed: String
        if !pf.newText.isEmpty { mode = .insert; edit = .init(range: pf.range, newText: pf.newText + nf.newText); removed = pi.newText }
        else if mapped == NSMaxRange(pf.range) {
            mode = .delete; edit = .init(range: .init(location: pf.range.location, length: mapped + nf.range.length - pf.range.location), newText: "")
            removed = pi.newText + ni.newText
        } else {
            mode = .backspace; let start = min(pf.range.location, mapped)
            edit = .init(range: .init(location: start, length: NSMaxRange(pf.range) - start), newText: ""); removed = ni.newText + pi.newText
        }
        forward.append(edit)
        inverse.append(.init(range: .init(location: edit.range.location + delta, length: edit.newText.utf16.count), newText: removed))
        delta += edit.newText.utf16.count - edit.range.length
    }
    return .init(forwardEdits: forward, inverseEdits: inverse, versionBefore: previous.versionBefore, versionAfter: next.versionAfter,
                 selectionsBefore: previous.selectionsBefore, selectionsAfter: next.selectionsAfter,
                 lineAnnotationsBefore: previous.lineAnnotationsBefore, lineAnnotationsAfter: next.lineAnnotationsAfter, coalescingMode: mode)
}
private func mapHistoryOffsetToBefore(_ original: Int, edits: [ResolvedTextEdit]) -> Int {
    var offset = original
    for edit in edits {
        guard offset >= edit.range.location else { continue }
        let length = edit.newText.utf16.count
        if offset >= edit.range.location + length { offset -= length - edit.range.length }
        else { offset = edit.range.location + min(offset - edit.range.location, edit.range.length) }
    }
    return offset
}

#endif

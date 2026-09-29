#if os(macOS)
import Foundation

public struct TextPosition: Codable, Equatable, Sendable {
    public var line: Int
    public var character: Int
    public init(line: Int, character: Int) { self.line = line; self.character = character }
}
public struct TextRange: Codable, Equatable, Sendable {
    public var start: TextPosition
    public var end: TextPosition
    public init(start: TextPosition, end: TextPosition) { self.start = start; self.end = end }
}
public struct TextEdit: Sendable {
    public var range: TextRange
    public var newText: String
    public init(range: TextRange, newText: String) { self.range = range; self.newText = newText }
}
public struct ResolvedTextEdit: Sendable {
    public var range: NSRange
    public var newText: String
    public init(range: NSRange, newText: String) { self.range = range; self.newText = newText }
}
/// One edit in application order; line coordinates include preceding edits in the batch.
public struct TextDocumentLineChange: Equatable, Sendable {
    public var startLine: Int
    public var endLine: Int
    public var lineDelta: Int
    public var startCharacter: Int
    public var endCharacter: Int
    public var endedAtDocumentEnd: Bool
}
public struct TextDocumentChange: Equatable, Sendable {
    public var startLine: Int
    public var endLine: Int
    public var previousLineCount: Int
    public var lineCount: Int
    public var lineDelta: Int { lineCount - previousLineCount }
    public var changedLineChanges: [TextDocumentLineChange] = []
}
/// Replay metadata for editor hosts. Without a saved selection, selectionEdits
/// lets the host map its current carets through the replayed transaction.
public struct TextDocumentHistoryResult: Sendable {
    public var change: TextDocumentChange
    public var selections: [EditorSelection]?
    public var annotations: [LineAnnotation]?
    public var selectionEdits: [ResolvedTextEdit]?
}
public enum TextDocumentError: Error { case overlappingEdits, invalidRange, invalidLine(Int) }

/// UTF-16 document model with an append-only piece table, incremental line index,
/// atomic edit batches, and inverse-edit undo. A keystroke does not copy the original file.
public struct TextDocument: Sendable {
    public let uri: String
    public var languageId: String
    public private(set) var version: Int
    public let eol: String
    private var storage: UTF16PieceTable
    private var starts: [Int]
    struct HistoryIdentity: Equatable, Sendable { let origin: UUID; var revision: UInt64 = 0 }
    private(set) var historyIdentity = HistoryIdentity(origin: UUID())
    private var lastChangeLineDelta = 0
    private var editStack: EditStack
    public var history: EditHistoryState { editStack.getState() }
    // The applied transaction is shared with input overlays, including undo/redo.
    private(set) var lastAppliedEdits: [ResolvedTextEdit] = []
    public private(set) var lastChangeTransaction: TextDocumentChangeTransaction?
    public var lineCount: Int { starts.count }
    public var utf16Length: Int { storage.count }
    public var canUndo: Bool { editStack.canUndo }
    public var canRedo: Bool { editStack.canRedo }
    public init(uri: String, text: String, languageId: String = "text", version: Int = 0, eol: String? = nil, editStack: EditStack = .init()) {
        self.uri = URL(string: uri, relativeTo: URL(string: "file://")!)?.absoluteString ?? uri
        self.languageId = languageId; self.version = version; self.editStack = editStack
        let units = Array(text.utf16)
        storage = UTF16PieceTable(units); starts = Self.lineStarts(units)
        if let eol { self.eol = eol }
        else if let index = units.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            self.eol = units[index] == 13 ? (index + 1 < units.count && units[index + 1] == 10 ? "\r\n" : "\r") : "\n"
        } else { self.eol = "\n" }
    }
    public func getText(_ range: TextRange? = nil) -> String {
        guard let range else { return storage.text(0..<storage.count) }
        let start = offsetAt(range.start), end = offsetAt(range.end)
        return getTextSlice(start: start, end: end)
    }
    /// Reads an exact UTF-16 slice without materializing the complete document.
    public func getText(in range: NSRange) throws -> String {
        guard range.location >= 0, range.length >= 0, range.location <= storage.count,
              range.length <= storage.count - range.location else { throw TextDocumentError.invalidRange }
        return storage.text(range.location..<NSMaxRange(range))
    }
    public func getLineText(_ line: Int, includeLineBreak: Bool = false) -> String {
        let line = min(max(0, line), starts.count - 1), end = line + 1 < starts.count ? starts[line + 1] : storage.count
        let text = storage.text(starts[line]..<end)
        if includeLineBreak { return text }
        if text.utf8.last == 13 { return String(text.dropLast()) }
        return cleanLastNewline(text)
    }
    public func positionAt(_ offset: Int) -> TextPosition {
        let offset = min(max(0, offset), storage.count), line = lineAt(offset)
        return .init(line: line, character: min(offset - starts[line], visibleLength(line)))
    }
    public func offsetAt(_ position: TextPosition) -> Int {
        let line = min(max(0, position.line), starts.count - 1)
        return starts[line] + min(max(0, position.character), visibleLength(line))
    }
    public func positionsAt(_ offsets: [Int]) -> [TextPosition] { offsets.map(positionAt) }
    public func normalizePosition(_ position: TextPosition) -> TextPosition { positionAt(offsetAt(position)) }
    /// Checked source-compatible line access. The existing getLineText method
    /// remains a clamping convenience for native viewport callers.
    public func getLineTextChecked(_ line: Int, includeLineBreak: Bool = false) throws -> String {
        guard starts.indices.contains(line) else { throw TextDocumentError.invalidLine(line) }
        return getLineText(line, includeLineBreak: includeLineBreak)
    }
    public func getLineLength(_ line: Int, includeLineBreak: Bool = false) throws -> Int {
        guard starts.indices.contains(line) else { throw TextDocumentError.invalidLine(line) }
        return includeLineBreak ? (line + 1 < starts.count ? starts[line + 1] : storage.count) - starts[line] : visibleLength(line)
    }
    public func getTextSlice(start: Int, end: Int) -> String {
        guard start < end else { return "" }
        let start = min(max(0, start), storage.count), end = min(max(0, end), storage.count)
        return storage.text(start..<max(start, end))
    }
    /// Preserves individual UTF-16 code units, including surrogate halves.
    public func utf16CodeUnit(at offset: Int) -> UInt16? {
        guard offset >= 0, offset < storage.count else { return nil }; return storage.unit(at: offset)
    }
    /// Swift String represents an isolated surrogate half as U+FFFD. Call
    /// utf16CodeUnit(at:) when exact JavaScript charCodeAt semantics are needed.
    public func charAt(_ offset: Int) -> String { utf16CodeUnit(at: offset).map { String(decoding: [$0], as: UTF16.self) } ?? "" }
    public func charAt(_ position: TextPosition) -> String { charAt(offsetAt(position)) }
    /// Exact UTF-16 search over piece buffers, wrapping after the last occupied
    /// range. No full-document String or match list is allocated.
    public func findNextNonOverlappingSubstring(_ needle: String, occupied: [NSRange]) -> Int? {
        storage.findNextNonOverlappingSubstring(Array(needle.utf16), occupied: occupied)
    }
    public func normalizeEol(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: eol)
    }
    public mutating func clearHistory() { editStack.clear(); historyIdentity.revision &+= 1 }
    public mutating func breakUndoCoalescing() { editStack.breakCoalescing(); historyIdentity.revision &+= 1 }
    public mutating func setLastUndoSelectionsAfter(_ selections: [EditorSelection]) { editStack.setLastUndoSelectionsAfter(selections); historyIdentity.revision &+= 1 }
    public mutating func setLastUndoLineAnnotations(before: [LineAnnotation], after: [LineAnnotation]) { editStack.setLastUndoLineAnnotations(before: before, after: after); historyIdentity.revision &+= 1 }
    mutating func setHistoryCapacity(_ value: Int) { editStack.setCapacity(value) }
    mutating func retainUndoEntries(_ count: Int) { editStack.retainUndoEntries(count); historyIdentity.revision &+= 1 }
    mutating func coalesceLastTwoHistoryEntries() -> Bool {
        guard lastChangeLineDelta == 0 && editStack.coalesceLastTwo() else { return false }
        historyIdentity.revision &+= 1; return true
    }
    mutating func setLastUndoBoundary(_ boundary: Bool) {
        guard var entry = editStack.peekUndo() else { return }; entry.undoBoundary = boundary; editStack.replaceLastUndo(entry); historyIdentity.revision &+= 1
    }
    /// The same surrogate-safe geometry used by application and selection remapping.
    public func resolveEdits(_ edits: [TextEdit]) throws -> [ResolvedTextEdit] {
        try normalizedEdits(edits.map { edit in
            let start = offsetAt(edit.range.start), end = offsetAt(edit.range.end)
            return .init(range: NSRange(location: min(start, end), length: abs(end - start)), newText: edit.newText)
        })
    }
    @discardableResult public mutating func applyEdits(_ edits: [TextEdit], updateHistory: Bool = true, selectionsBefore: [EditorSelection]? = nil,
                                                      selectionsAfter: [EditorSelection]? = nil, undoBoundary: Bool = false,
                                                      coalescing: Bool = true) throws -> TextDocumentChange? {
        try applyResolvedEdits(resolveEdits(edits), updateHistory: updateHistory, selectionsBefore: selectionsBefore, selectionsAfter: selectionsAfter,
                               undoBoundary: undoBoundary, coalescing: coalescing)
    }
    @discardableResult public mutating func applyResolvedEdits(_ edits: [ResolvedTextEdit], updateHistory: Bool = true, selectionsBefore: [EditorSelection]? = nil,
                                                              selectionsAfter: [EditorSelection]? = nil, undoBoundary: Bool = false,
                                                              coalescing: Bool = true) throws -> TextDocumentChange? {
        guard !edits.isEmpty else { return nil }
        let edits = try normalizedEdits(edits)
        var entry = try createEditStackEntry(self, resolvedEdits: edits, versionBefore: version, versionAfter: version + 1,
                                            selectionsBefore: updateHistory ? selectionsBefore : nil, selectionsAfter: updateHistory ? selectionsAfter : nil)
        entry.undoBoundary = updateHistory && undoBoundary
        let previous = editStack.peekUndoForCoalescing()
        let change = apply(edits); lastChangeTransaction = .init(appliedEdits: edits, inverseEdits: entry.inverseEdits); version += 1; lastChangeLineDelta = change.lineDelta
        if coalescing, change.lineDelta == 0, shouldCoalesceEditStackEntry(previous, entry), let previous {
            editStack.replaceLastUndo(coalesceEditStackEntries(previous, entry))
        } else { editStack.push(entry) }
        historyIdentity.revision &+= 1
        return change
    }
    func normalizedEdits(_ edits: [ResolvedTextEdit]) throws -> [ResolvedTextEdit] {
        var indexed: [(Int, ResolvedTextEdit)] = []
        for (index, edit) in edits.enumerated() {
            guard edit.range.location >= 0, edit.range.length >= 0, edit.range.location <= storage.count, edit.range.length <= storage.count - edit.range.location else { throw TextDocumentError.invalidRange }
            var start = edit.range.location, end = NSMaxRange(edit.range)
            if splitsSurrogate(start) { start -= 1 }
            if edit.range.length == 0 { end = start }
            else if splitsSurrogate(end) { end += 1 }
            let range = NSRange(location: start, length: end - start)
            let resolved = ResolvedTextEdit(range: range, newText: edit.newText)
            indexed.append((index, resolved))
        }
        indexed.sort { left, right in
            if left.1.range.location == right.1.range.location {
                if left.1.range.length != right.1.range.length { return left.1.range.length < right.1.range.length }
                return left.0 < right.0
            }
            return left.1.range.location < right.1.range.location
        }
        let edits = indexed.map { $0.1 }
        for i in edits.indices.dropFirst() where edits[i].range.location < NSMaxRange(edits[i - 1].range) { throw TextDocumentError.overlappingEdits }
        return edits
    }
    @discardableResult public mutating func undo() -> TextDocumentChange? { undoResult()?.change }
    @discardableResult public mutating func redo() -> TextDocumentChange? { redoResult()?.change }
    @discardableResult public mutating func undoResult() -> TextDocumentHistoryResult? {
        guard let entry = editStack.popUndoToRedo() else { return nil }
        let change = apply(entry.inverseEdits); lastChangeTransaction = .init(appliedEdits: entry.inverseEdits, inverseEdits: entry.forwardEdits); version = entry.versionBefore; historyIdentity.revision &+= 1
        return .init(change: change, selections: entry.selectionsBefore, annotations: entry.lineAnnotationsBefore,
                     selectionEdits: entry.selectionsBefore == nil ? entry.inverseEdits : nil)
    }
    @discardableResult public mutating func redoResult() -> TextDocumentHistoryResult? {
        guard let entry = editStack.popRedoToUndo() else { return nil }
        let change = apply(entry.forwardEdits); lastChangeTransaction = .init(appliedEdits: entry.forwardEdits, inverseEdits: entry.inverseEdits); version = entry.versionAfter; historyIdentity.revision &+= 1
        return .init(change: change, selections: entry.selectionsAfter, annotations: entry.lineAnnotationsAfter,
                     selectionEdits: entry.selectionsAfter == nil ? entry.forwardEdits : nil)
    }
    public func search(_ query: String, caseSensitive: Bool = true, regularExpression: Bool = false, wholeWord: Bool = false) throws -> [NSRange] {
        try search(.init(text: query, caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regularExpression))
    }

    private func splitsSurrogate(_ offset: Int) -> Bool {
        guard offset > 0 && offset < storage.count else { return false }
        return (0xD800...0xDBFF).contains(storage.unit(at: offset - 1)) && (0xDC00...0xDFFF).contains(storage.unit(at: offset))
    }
    private func visibleLength(_ line: Int) -> Int {
        var end = line + 1 < starts.count ? starts[line + 1] : storage.count
        if end > starts[line] && storage.unit(at: end - 1) == 10 { end -= 1 }
        if end > starts[line] && storage.unit(at: end - 1) == 13 { end -= 1 }
        return end - starts[line]
    }
    private func lineAt(_ offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high { let mid = (low + high + 1) / 2; if starts[mid] <= offset { low = mid } else { high = mid - 1 } }
        return low
    }
    private mutating func apply(_ edits: [ResolvedTextEdit]) -> TextDocumentChange {
        lastAppliedEdits = edits
        let previousCount = lineCount, first = edits.first?.range.location ?? 0, startLine = lineAt(first)
        var lineDeltaBeforeEdit = 0
        let changes: [TextDocumentLineChange] = edits.map { edit in
            let start = positionAt(edit.range.location), end = positionAt(NSMaxRange(edit.range))
            let inserted = Self.lineStarts(Array(edit.newText.utf16)).count - 1
            let delta = inserted - (end.line - start.line)
            let changedStart = start.line + lineDeltaBeforeEdit
            lineDeltaBeforeEdit += delta
            return .init(startLine: changedStart, endLine: changedStart + inserted, lineDelta: delta,
                         startCharacter: start.character, endCharacter: end.character,
                         endedAtDocumentEnd: NSMaxRange(edit.range) == storage.count)
        }
        if edits.count > 1 {
            let replacements = edits.map { (range: $0.range.location..<NSMaxRange($0.range), units: Array($0.newText.utf16)) }
            let delta = replacements.reduce(0) { $0 + $1.units.count - $1.range.count }
            let lastEnd = NSMaxRange(edits.last!.range) + delta
            storage.replaceBatch(replacements)
            starts = Self.lineStarts(storage.units(0..<storage.count))
            return .init(startLine: startLine, endLine: lineAt(min(storage.count, max(first, lastEnd))), previousLineCount: previousCount, lineCount: lineCount, changedLineChanges: changes)
        }
        var lastEnd = first
        for edit in edits.reversed() {
            let start = edit.range.location, end = NSMaxRange(edit.range)
            // Rescan only affected lines plus a neighboring line to preserve CRLF
            // pairs formed or split across edit boundaries.
            let lowerLine = max(0, lineAt(start) - 1), upperLine = min(starts.count - 1, lineAt(end) + 1)
            let lower = starts[lowerLine], upper = upperLine + 1 < starts.count ? starts[upperLine + 1] : storage.count
            let units = Array(edit.newText.utf16), delta = units.count - edit.range.length
            storage.replace(start..<end, with: units)
            let middle = Self.lineStarts(storage.units(lower..<(upper + delta))).map { $0 + lower }
            let tail = starts.filter { $0 > upper }.map { $0 + delta }
            starts = Array(starts.prefix(lowerLine)) + middle + tail
            lastEnd = max(start + units.count, lastEnd + delta)
        }
        return .init(startLine: startLine, endLine: lineAt(min(storage.count, max(first, lastEnd))), previousLineCount: previousCount, lineCount: lineCount, changedLineChanges: changes)
    }
    private static func lineStarts(_ units: [UInt16]) -> [Int] {
        var result = [0], i = 0
        while i < units.count {
            if units[i] == 13 { if i + 1 < units.count && units[i + 1] == 10 { i += 1 }; result.append(i + 1) }
            else if units[i] == 10 { result.append(i + 1) }
            i += 1
        }
        return result
    }
}

private struct UTF16PieceTable: Sendable {
    private struct Piece: Sendable { var added: Bool; var start: Int; var count: Int }
    private let original: [UInt16]
    private var added: [UInt16] = []
    private var pieces: [Piece]
    private var pieceEnds: [Int]
    private(set) var count: Int
    init(_ units: [UInt16]) { original = units; count = units.count; pieces = units.isEmpty ? [] : [.init(added: false, start: 0, count: units.count)]; pieceEnds = units.isEmpty ? [] : [units.count] }
    func text(_ range: Range<Int>) -> String { String(decoding: units(range), as: UTF16.self) }
    private func pieceIndex(at offset: Int) -> Int {
        var low = 0, high = pieceEnds.count
        while low < high { let middle = (low + high) / 2; if pieceEnds[middle] <= offset { low = middle + 1 } else { high = middle } }
        return low
    }
    func units(_ range: Range<Int>) -> [UInt16] {
        guard !range.isEmpty else { return [] }
        var result: [UInt16] = []; result.reserveCapacity(range.count)
        var index = pieceIndex(at: range.lowerBound)
        var offset = index == 0 ? 0 : pieceEnds[index - 1]
        while index < pieces.count && offset < range.upperBound {
            let piece = pieces[index], lo = max(range.lowerBound, offset), hi = min(range.upperBound, pieceEnds[index])
            if lo < hi { let buffer = piece.added ? added : original; result += buffer[(piece.start + lo - offset)..<(piece.start + hi - offset)] }
            offset = pieceEnds[index]; index += 1
        }
        return result
    }
    func unit(at target: Int) -> UInt16 {
        let index = pieceIndex(at: target)
        guard index < pieces.count else { return 0 }
        let offset = index == 0 ? 0 : pieceEnds[index - 1], piece = pieces[index]
        return (piece.added ? added : original)[piece.start + target - offset]
    }
    func findNextNonOverlappingSubstring(_ needle: [UInt16], occupied: [NSRange]) -> Int? {
        guard !needle.isEmpty, needle.count <= count else { return nil }
        var ranges: [Range<Int>] = []
        for value in occupied {
            let start = min(count, max(0, value.location))
            let sum = value.location.addingReportingOverflow(max(0, value.length))
            let end = min(count, max(start, sum.overflow ? Int.max : sum.partialValue))
            if start < end { ranges.append(start..<end) }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        let pivot = merged.last?.upperBound ?? 0
        func overlaps(_ start: Int, _ end: Int) -> Bool {
            var low = 0, high = merged.count
            while low < high { let mid = (low + high) / 2; if merged[mid].upperBound <= start { low = mid + 1 } else { high = mid } }
            return low < merged.count && merged[low].lowerBound < end
        }
        var prefix = Array(repeating: 0, count: needle.count), length = 0
        for index in 1..<needle.count {
            while length > 0 && needle[index] != needle[length] { length = prefix[length - 1] }
            if needle[index] == needle[length] { length += 1 }
            prefix[index] = length
        }
        var matched = 0, offset = 0, wrapped: Int?
        for piece in pieces {
            let buffer = piece.added ? added : original
            for index in piece.start..<(piece.start + piece.count) {
                let unit = buffer[index]
                while matched > 0 && unit != needle[matched] { matched = prefix[matched - 1] }
                if unit == needle[matched] { matched += 1 }
                if matched == needle.count {
                    let start = offset - needle.count + 1
                    if !overlaps(start, start + needle.count) {
                        if start >= pivot { return start }
                        if wrapped == nil { wrapped = start }
                    }
                    matched = prefix[matched - 1]
                }
                offset += 1
            }
        }
        return wrapped
    }
    mutating func replace(_ range: Range<Int>, with units: [UInt16]) {
        replaceBatch([(range: range, units: units)])
    }
    /// Sorted nonoverlapping edits share a single traversal of the old pieces.
    mutating func replaceBatch(_ edits: [(range: Range<Int>, units: [UInt16])]) {
        let previous = pieces, previousCount = count
        var output: [Piece] = [], index = 0, localOffset = 0, position = 0
        output.reserveCapacity(previous.count + edits.count * 2)
        func append(_ piece: Piece) {
            guard piece.count > 0 else { return }
            if let last = output.last, last.added == piece.added, last.start + last.count == piece.start {
                output[output.count - 1].count += piece.count
            } else { output.append(piece) }
        }
        func consume(to end: Int, keeping: Bool) {
            while position < end && index < previous.count {
                let piece = previous[index], amount = min(piece.count - localOffset, end - position)
                if keeping { append(.init(added: piece.added, start: piece.start + localOffset, count: amount)) }
                position += amount; localOffset += amount
                if localOffset == piece.count { index += 1; localOffset = 0 }
            }
        }
        for edit in edits {
            consume(to: edit.range.lowerBound, keeping: true)
            consume(to: edit.range.upperBound, keeping: false)
            append(.init(added: true, start: added.count, count: edit.units.count))
            added += edit.units
            count += edit.units.count - edit.range.count
        }
        consume(to: previousCount, keeping: true)
        pieces = output; pieceEnds = []; pieceEnds.reserveCapacity(output.count)
        var end = 0
        for piece in output { end += piece.count; pieceEnds.append(end) }
    }
}

#endif

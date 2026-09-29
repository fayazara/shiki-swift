#if os(macOS)
import Foundation

public struct MergeConflictRegion: Codable, Equatable, Sendable {
    public var conflictIndex: Int
    public var startLineIndex: Int
    public var startLineNumber: Int
    public var separatorLineIndex: Int
    public var separatorLineNumber: Int
    public var endLineIndex: Int
    public var endLineNumber: Int
    public var baseMarkerLineIndex: Int?
    public var baseMarkerLineNumber: Int?
}
public struct MergeConflictDiffAction: Codable, Equatable, Sendable {
    public struct MarkerLines: Codable, Equatable, Sendable {
        public var start: String; public var base: String?; public var separator: String; public var end: String
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.start.utf16.elementsEqual(rhs.start.utf16)
                && lhs.base.map { Array($0.utf16) } == rhs.base.map { Array($0.utf16) }
                && lhs.separator.utf16.elementsEqual(rhs.separator.utf16)
                && lhs.end.utf16.elementsEqual(rhs.end.utf16)
        }
    }
    public var conflict: MergeConflictRegion
    public var conflictIndex: Int
    public var hunkIndex = -1
    public var startContentIndex = -1
    public var endContentIndex = -1
    public var endMarkerContentIndex = -1
    public var currentContentIndex: Int?
    public var baseContentIndex: Int?
    public var incomingContentIndex: Int?
    public var markerLines: MarkerLines
}
public struct MergeConflictMarkerRow: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case start = "marker-start", base = "marker-base", separator = "marker-separator", end = "marker-end" }
    public var type: Kind
    public var hunkIndex: Int
    public var contentIndex: Int
    public var conflictIndex: Int
    public var lineText: String
    public var lineIndex: Int
}
public struct MergeConflictResult: Codable, Equatable, Sendable {
    public var fileDiff: FileDiffMetadata
    public var currentFile: FileContents
    public var incomingFile: FileContents
    public var actions: [MergeConflictDiffAction]
    public var markerRows: [MergeConflictMarkerRow]
}
public func parseMergeConflictDiffFromFile(_ file: FileContents, maxContextLines: Int = 6) throws -> MergeConflictResult {
    try ConflictParser(file: file, context: max(1, maxContextLines)).parse()
}
private final class ConflictParser {
    enum Stage { case current, base, incoming }
    struct Frame { var index: Int; var stage: Stage = .current; var sourceStart: Int; var baseIndex: Int?; var separatorIndex: Int?; var start: String; var base: String?; var separator: String? }
    final class Builder {
        var h = Hunk()
        var bufferCount = 0, bufferAdd = 0, bufferDel = 0
        var baseConflicts: [Int: Int] = [:]
        init(addition: Int, deletion: Int) {
            h.additionStart = addition; h.deletionStart = deletion
            h.additionLineIndex = max(0, addition - 1); h.deletionLineIndex = max(0, deletion - 1)
            bufferAdd = h.additionLineIndex; bufferDel = h.deletionLineIndex
        }
    }
    let file: FileContents
    let context: Int
    var diff: FileDiffMetadata
    var stack: [Frame] = []
    var actions: [MergeConflictDiffAction] = []
    var completed: Set<Int> = []
    var active: Builder?
    init(file: FileContents, context: Int) { self.file = file; self.context = context; diff = .init(name: file.name); diff.isPartial = false }
    func parse() throws -> MergeConflictResult {
        for (index, line) in splitFileContents(file.contents).enumerated() { try process(line, index) }
        guard stack.isEmpty else { throw DiffError.invalidPatch("Unfinished merge conflict") }
        if let active, !active.h.hunkContent.isEmpty { try flush(active, .trailing); finalize() }
        guard completed.count == actions.count else { throw DiffError.invalidPatch("Unanchored merge conflict") }
        recomputeGeometry(&diff)
        var current = file, incoming = file
        current.contents = diff.deletionLines.joined(); incoming.contents = diff.additionLines.joined()
        current.cacheKey = file.cacheKey.map { $0 + ":merge-conflict-current" }; incoming.cacheKey = file.cacheKey.map { $0 + ":merge-conflict-incoming" }
        diff.type = incoming.contents.isEmpty ? .deleted : current.contents.isEmpty ? .new : .change
        diff.cacheKey = file.cacheKey.map { $0 + ":merge-conflict-diff" }
        return .init(fileDiff: diff, currentFile: current, incomingFile: incoming, actions: actions, markerRows: buildMergeConflictMarkerRows(diff, actions: actions))
    }
    func ensure() -> Builder {
        if let active { return active }
        let builder = Builder(addition: diff.additionLines.count + 1, deletion: diff.deletionLines.count + 1); active = builder; return builder
    }
    func process(_ line: String, _ index: Int) throws {
        let marker = markerType(line)
        if stack.isEmpty {
            if marker == .start { start(line, index) } else { emitContext(line) }
            return
        }
        if marker == .start { start(line, index); return }
        let top = stack.count - 1
        if marker == .base { stack[top].stage = .base; stack[top].baseIndex = index; stack[top].base = line; return }
        if marker == .separator { stack[top].stage = .incoming; stack[top].separatorIndex = index; stack[top].separator = line; return }
        if marker == .end { try finish(stack.removeLast(), index, line); return }
        let frame = stack[top]
        if frame.stage == .base { emitContext(line, conflict: frame.index) }
        else { try emitChange(line, addition: frame.stage == .incoming, conflict: frame.index, stage: frame.stage) }
    }
    func start(_ line: String, _ index: Int) {
        let ci = actions.count
        stack.append(Frame(index: ci, sourceStart: index, start: line))
        let region = MergeConflictRegion(conflictIndex: ci, startLineIndex: index, startLineNumber: index + 1, separatorLineIndex: index, separatorLineNumber: index + 1, endLineIndex: index, endLineNumber: index + 1)
        actions.append(.init(conflict: region, conflictIndex: ci, markerLines: .init(start: line, separator: "", end: "")))
    }
    func assign(_ ci: Int, _ role: Stage, _ content: Int) throws {
        if actions[ci].hunkIndex < 0 { actions[ci].hunkIndex = diff.hunks.count }
        else if actions[ci].hunkIndex != diff.hunks.count { throw DiffError.invalidPatch("Conflict spans multiple hunks") }
        if actions[ci].startContentIndex < 0 { actions[ci].startContentIndex = content }
        actions[ci].endContentIndex = content; actions[ci].endMarkerContentIndex = content
        switch role {
        case .current: if actions[ci].currentContentIndex == nil { actions[ci].currentContentIndex = content }
        case .base: if actions[ci].baseContentIndex == nil { actions[ci].baseContentIndex = content }
        case .incoming: actions[ci].incomingContentIndex = content
        }
    }
    enum Flush { case leading, trailing, beforeChange }
    func flush(_ builder: Builder, _ mode: Flush) throws {
        var count = builder.bufferCount, add = builder.bufferAdd, del = builder.bufferDel
        if mode == .leading && count > context {
            let delta = count - context; add += delta; del += delta; count = context
            builder.h.additionStart += delta; builder.h.deletionStart += delta
            builder.h.additionLineIndex += delta; builder.h.deletionLineIndex += delta
        }
        if mode == .trailing && count > context { count = context }
        if count > 0 {
            if builder.h.hunkContent.last?.type == .context { builder.h.hunkContent[builder.h.hunkContent.count - 1].lines += count }
            else { builder.h.hunkContent.append(.init(type: .context, lines: count, deletionLineIndex: del, additionLineIndex: add)) }
            builder.h.additionCount += count; builder.h.deletionCount += count
            let from = add - builder.bufferAdd
            for (offset, ci) in builder.baseConflicts where offset >= from && offset < from + count { try assign(ci, .base, builder.h.hunkContent.count - 1) }
        }
        builder.bufferCount = 0; builder.baseConflicts = [:]
    }
    func finalize() {
        guard let builder = active else { return }; active = nil
        guard !builder.h.hunkContent.isEmpty else { return }
        var h = builder.h
        if h.additionCount == 0 { h.additionStart -= 1 }
        if h.deletionCount == 0 { h.deletionStart -= 1 }
        func range(_ start: Int, _ count: Int) -> String { count == 1 ? String(start) : "\(start),\(count)" }
        h.hunkSpecs = "@@ -\(range(h.deletionStart, h.deletionCount)) +\(range(h.additionStart, h.additionCount)) @@\n"
        diff.hunks.append(h)
    }
    func split() throws {
        guard let builder = active else { return }
        let count = builder.bufferCount, omitted = count - context * 2
        let nextAdd = builder.bufferAdd + count - context, nextDel = builder.bufferDel + count - context
        var nextBase: [Int: Int] = [:]
        for (offset, ci) in builder.baseConflicts where offset >= count - context { nextBase[offset - count + context] = ci }
        try flush(builder, .trailing); finalize()
        let next = Builder(addition: builder.h.additionStart + builder.h.additionCount + omitted, deletion: builder.h.deletionStart + builder.h.deletionCount + omitted)
        next.bufferAdd = nextAdd; next.bufferDel = nextDel; next.bufferCount = context; next.baseConflicts = nextBase
        active = next
    }
    func emitContext(_ line: String, conflict: Int? = nil) {
        let builder = ensure()
        if builder.bufferCount == 0 { builder.bufferAdd = diff.additionLines.count; builder.bufferDel = diff.deletionLines.count }
        diff.additionLines.append(line); diff.deletionLines.append(line)
        if let conflict { builder.baseConflicts[builder.bufferCount] = conflict }
        builder.bufferCount += 1
    }
    func emitChange(_ line: String, addition: Bool, conflict: Int, stage: Stage) throws {
        var builder = ensure()
        if !builder.h.hunkContent.isEmpty && builder.bufferCount > context && builder.bufferCount - context > context { try split(); builder = active! }
        try flush(builder, builder.h.hunkContent.isEmpty ? .leading : .beforeChange)
        let ai = diff.additionLines.count, di = diff.deletionLines.count
        if addition { diff.additionLines.append(line) } else { diff.deletionLines.append(line) }
        if builder.h.hunkContent.last?.type != .change { builder.h.hunkContent.append(.init(type: .change, deletionLineIndex: di, additionLineIndex: ai)) }
        let ci = builder.h.hunkContent.count - 1
        if addition { builder.h.hunkContent[ci].additions += 1; builder.h.additionCount += 1 }
        else { builder.h.hunkContent[ci].deletions += 1; builder.h.deletionCount += 1 }
        try assign(conflict, stage, ci)
    }
    func finish(_ frame: Frame, _ index: Int, _ line: String) throws {
        guard let separatorIndex = frame.separatorIndex, let separator = frame.separator else { throw DiffError.invalidPatch("Conflict is missing separator") }
        let ci = frame.index
        actions[ci].markerLines.separator = separator; actions[ci].markerLines.end = line; actions[ci].markerLines.base = frame.base
        actions[ci].conflict = .init(conflictIndex: ci, startLineIndex: frame.sourceStart, startLineNumber: frame.sourceStart + 1, separatorLineIndex: separatorIndex, separatorLineNumber: separatorIndex + 1, endLineIndex: index, endLineNumber: index + 1, baseMarkerLineIndex: frame.baseIndex, baseMarkerLineNumber: frame.baseIndex.map { $0 + 1 })
        let fallback = actions[ci].currentContentIndex ?? actions[ci].incomingContentIndex
        if let fallback {
            if actions[ci].currentContentIndex == nil { actions[ci].currentContentIndex = fallback }
            if actions[ci].incomingContentIndex == nil { actions[ci].incomingContentIndex = fallback }
            if actions[ci].startContentIndex < 0 { actions[ci].startContentIndex = fallback }
            if actions[ci].endContentIndex < 0 { actions[ci].endContentIndex = fallback }
            if actions[ci].endMarkerContentIndex < 0 { actions[ci].endMarkerContentIndex = fallback }
        }
        guard actions[ci].hunkIndex >= 0 && actions[ci].startContentIndex >= 0 && actions[ci].endContentIndex >= 0 && actions[ci].endMarkerContentIndex >= 0 else { throw DiffError.invalidPatch("Unable to anchor merge conflict") }
        completed.insert(ci)
    }
    func markerType(_ line: String) -> MergeConflictMarkerRow.Kind? {
        let units = Array(line.utf16)
        guard units.count >= 7, let first = units.first, [60, 62, 61, 124].contains(first) else { return nil }
        var end = units.count
        if end > 0 && units[end - 1] == 10 { end -= 1 }; if end > 0 && units[end - 1] == 13 { end -= 1 }
        var count = 1
        while count < end && units[count] == first { count += 1 }
        guard count >= 7 else { return nil }
        if first == 61 { return count == end ? .separator : nil }
        guard count == end || [9, 10, 11, 12, 13, 32].contains(units[count]) else { return nil }
        return first == 60 ? .start : first == 62 ? .end : .base
    }
}
public func buildMergeConflictMarkerRows(_ diff: FileDiffMetadata, actions: [MergeConflictDiffAction]) -> [MergeConflictMarkerRow] {
    let starts: [[Int]] = diff.hunks.map { h in
        var values = [h.unifiedLineStart]
        for c in h.hunkContent { values.append(values.last! + (c.type == .context ? c.lines : c.additions + c.deletions)) }
        return values
    }
    var rows: [MergeConflictMarkerRow] = []
    for action in actions {
        guard diff.hunks.indices.contains(action.hunkIndex) else { continue }
        let h = diff.hunks[action.hunkIndex], offsets = starts[action.hunkIndex]
        func start(_ i: Int) -> Int { offsets.indices.contains(max(i, 0)) ? offsets[max(i, 0)] : h.unifiedLineStart }
        func end(_ i: Int) -> Int { max(start(i), start(i + 1) - 1) }
        func append(_ type: MergeConflictMarkerRow.Kind, _ ci: Int, _ text: String, _ line: Int) {
            rows.append(.init(type: type, hunkIndex: action.hunkIndex, contentIndex: ci, conflictIndex: action.conflictIndex, lineText: text, lineIndex: line))
        }
        append(.start, action.startContentIndex, action.markerLines.start, start(action.startContentIndex))
        if let base = action.baseContentIndex {
            guard let current = action.currentContentIndex, let incoming = action.incomingContentIndex, let baseText = action.markerLines.base,
                  h.hunkContent.indices.contains(current), h.hunkContent.indices.contains(incoming), h.hunkContent.indices.contains(base),
                  h.hunkContent[current].type == .change, h.hunkContent[base].type == .context, h.hunkContent[incoming].type == .change else { continue }
            append(.base, base, baseText, start(current) + h.hunkContent[current].deletions)
            append(.separator, base, action.markerLines.separator, start(incoming))
        } else {
            guard let current = action.currentContentIndex, h.hunkContent.indices.contains(current), h.hunkContent[current].type == .change else { continue }
            let deletionCount = h.hunkContent[current].deletions
            append(.separator, current, action.markerLines.separator, deletionCount > 0 ? start(current) + deletionCount : start(action.startContentIndex))
        }
        append(.end, action.endMarkerContentIndex, action.markerLines.end, end(action.endMarkerContentIndex))
    }
    return rows
}
public func resolveConflict(_ diff: FileDiffMetadata, conflict: MergeConflictDiffAction, resolution: DiffResolution) throws -> FileDiffMetadata {
    var indexes: Set<Int> = []
    if let base = conflict.baseContentIndex { indexes.insert(base) }
    if conflict.endMarkerContentIndex != conflict.endContentIndex { indexes.insert(conflict.endMarkerContentIndex) }
    return try resolveRegion(diff, hunkIndex: conflict.hunkIndex, startContentIndex: conflict.startContentIndex, endContentIndex: conflict.endContentIndex, resolution: resolution, indexesToDelete: indexes)
}

#endif

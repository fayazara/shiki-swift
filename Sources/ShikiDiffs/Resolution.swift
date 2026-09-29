#if os(macOS)
import Foundation

public enum DiffResolution: String, CaseIterable, Sendable { case deletions, additions, both }
/// Resolves a hunk (or one change block) without recomputing or moving the other hunks.
/// This also works for partial patches: omitted lines stay omitted.
public func diffAcceptRejectHunk(_ diff: FileDiffMetadata, hunkIndex: Int, resolution: DiffResolution, changeIndex: Int? = nil) throws -> FileDiffMetadata {
    guard diff.hunks.indices.contains(hunkIndex) else { throw DiffError.invalidHunk }
    let hunk = diff.hunks[hunkIndex]
    let start = changeIndex ?? 0, end = changeIndex ?? max(0, hunk.hunkContent.count - 1)
    return try resolveRegion(diff, hunkIndex: hunkIndex, startContentIndex: start, endContentIndex: end, resolution: resolution)
}
public func resolveRegion(_ diff: FileDiffMetadata, hunkIndex: Int, startContentIndex: Int, endContentIndex: Int, resolution: DiffResolution, indexesToDelete: Set<Int> = []) throws -> FileDiffMetadata {
    guard diff.hunks.indices.contains(hunkIndex), startContentIndex >= 0, startContentIndex <= endContentIndex, endContentIndex < diff.hunks[hunkIndex].hunkContent.count else { throw DiffError.invalidHunk }
    var result = diff
    result.hunks = []; result.additionLines = []; result.deletionLines = []
    result.cacheKey = diff.cacheKey.map { "\($0):\(resolution.rawValue.prefix(1))-\(hunkIndex):\(startContentIndex)-\(endContentIndex)" }
    var oldNumber = 1, newNumber = 1
    var splitRows = 0, unifiedRows = 0
    func adding(_ value: Int, _ increment: Int) throws -> Int {
        let result = value.addingReportingOverflow(increment)
        guard value >= 0, increment >= 0, !result.overflow else { throw DiffError.invalidHunk }
        return result.partialValue
    }
    func sourceLines(_ lines: [String], start: Int, count: Int) throws -> [String] {
        // A zero-length side has no source lookup, including sentinel indices.
        if count == 0 { return [] }
        guard count > 0, start >= 0, start <= lines.count,
              count <= lines.count - start else { throw DiffError.invalidHunk }
        return Array(lines[start..<(start + count)])
    }
    func appendContext(_ oldIndex: Int, _ newIndex: Int, _ count: Int) throws {
        result.deletionLines += try sourceLines(diff.deletionLines, start: oldIndex, count: count)
        result.additionLines += try sourceLines(diff.additionLines, start: newIndex, count: count)
    }
    for (hi, source) in diff.hunks.enumerated() {
        guard source.deletionCount >= 0, source.additionCount >= 0, source.collapsedBefore >= 0,
              source.deletionStart >= (source.deletionCount > 0 ? 1 : 0),
              source.additionStart >= (source.additionCount > 0 ? 1 : 0) else { throw DiffError.invalidHunk }
        if source.collapsedBefore > 0 {
            if !diff.isPartial { try appendContext(source.oldBoundary - source.collapsedBefore, source.newBoundary - source.collapsedBefore, source.collapsedBefore) }
            oldNumber = try adding(oldNumber, source.collapsedBefore); newNumber = try adding(newNumber, source.collapsedBefore)
            splitRows = try adding(splitRows, source.collapsedBefore); unifiedRows = try adding(unifiedRows, source.collapsedBefore)
        }
        var h = source; h.hunkContent = []; h.deletionStart = oldNumber; h.additionStart = newNumber
        h.deletionLineIndex = result.deletionLines.count; h.additionLineIndex = result.additionLines.count
        h.deletionCount = 0; h.additionCount = 0
        var additionLines = 0, deletionLines = 0
        for (ci, c) in source.hunkContent.enumerated() {
            var block = c; block.deletionLineIndex = result.deletionLines.count; block.additionLineIndex = result.additionLines.count
            if hi == hunkIndex && startContentIndex...endContentIndex ~= ci && indexesToDelete.contains(ci) {
                block = .init(type: .context, lines: 0, deletionLineIndex: block.deletionLineIndex, additionLineIndex: block.additionLineIndex)
            } else if hi == hunkIndex && startContentIndex...endContentIndex ~= ci && c.type == .change {
                // Upstream only reads the chosen side(s). Deleted blocks and
                // the unused side must not trigger a source lookup.
                let old = resolution == .additions ? [] : try sourceLines(diff.deletionLines, start: c.deletionLineIndex, count: c.oldCount)
                let new = resolution == .deletions ? [] : try sourceLines(diff.additionLines, start: c.additionLineIndex, count: c.newCount)
                let selected = old + new
                result.deletionLines += selected; result.additionLines += selected
                block = .init(type: .context, lines: selected.count, deletionLineIndex: block.deletionLineIndex, additionLineIndex: block.additionLineIndex)
            } else if c.type == .context {
                let new = try sourceLines(diff.additionLines, start: c.additionLineIndex, count: c.lines)
                result.deletionLines += new; result.additionLines += new
            } else {
                result.deletionLines += try sourceLines(diff.deletionLines, start: c.deletionLineIndex, count: c.oldCount)
                result.additionLines += try sourceLines(diff.additionLines, start: c.additionLineIndex, count: c.newCount)
            }
            h.hunkContent.append(block)
            h.deletionCount = try adding(h.deletionCount, block.oldCount); h.additionCount = try adding(h.additionCount, block.newCount)
            oldNumber = try adding(oldNumber, block.oldCount); newNumber = try adding(newNumber, block.newCount)
            additionLines = try adding(additionLines, block.additions); deletionLines = try adding(deletionLines, block.deletions)
            splitRows = try adding(splitRows, block.type == .context ? block.lines : max(block.additions, block.deletions))
            unifiedRows = try adding(unifiedRows, block.type == .context ? block.lines : adding(block.additions, block.deletions))
        }
        if hi == hunkIndex && hunkIndex == diff.hunks.count - 1 && endContentIndex == source.hunkContent.count - 1 {
            let eof = resolution == .deletions ? source.noEOFCRDeletions : source.noEOFCRAdditions
            h.noEOFCRDeletions = eof; h.noEOFCRAdditions = eof
        }
        if h.deletionCount == 0 { h.deletionStart -= 1; if !diff.isPartial { h.deletionLineIndex -= 1 } }
        if h.additionCount == 0 { h.additionStart -= 1; if !diff.isPartial { h.additionLineIndex -= 1 } }
        result.hunks.append(h)
    }
    if !diff.isPartial, let last = diff.hunks.last {
        let oldEnd = try adding(last.oldBoundary, last.deletionCount), newEnd = try adding(last.newBoundary, last.additionCount)
        let trailing = min(diff.deletionLines.count - oldEnd, diff.additionLines.count - newEnd)
        try appendContext(oldEnd, newEnd, trailing)
        splitRows = try adding(splitRows, trailing); unifiedRows = try adding(unifiedRows, trailing)
    }
    recomputeGeometry(&result); return result
}

#endif

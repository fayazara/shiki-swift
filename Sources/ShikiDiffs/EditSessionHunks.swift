#if os(macOS)
// Native adaptation of @pierre/diffs editSessionHunks.ts and editor recomputation.
import Foundation

public struct DivergenceCore: Codable, Equatable, Sendable {
    public var start: Int
    public var deletionEnd: Int
    public var additionEnd: Int
}
public struct PreviousRegionSpan: Codable, Equatable, Sendable {
    public var firstIndex: Int
    public var lastIndex: Int
}
public struct SessionRegionChange: Codable, Equatable, Sendable {
    public var regions: [PreviousRegionSpan?]
}

public func normalizeEditorLines(_ lines: [String]) -> [String] {
    lines.count > 1 && lines.last == "" ? Array(lines.dropLast()) : lines
}
public func findDivergenceCore(_ deletionLines: [String], _ additionLines: [String]) -> DivergenceCore? {
    var start = 0, oldEnd = deletionLines.count, newEnd = additionLines.count
    while start < min(oldEnd, newEnd) && deletionLines[start].utf16.elementsEqual(additionLines[start].utf16) { start += 1 }
    while oldEnd > start && newEnd > start && deletionLines[oldEnd - 1].utf16.elementsEqual(additionLines[newEnd - 1].utf16) { oldEnd -= 1; newEnd -= 1 }
    return start == oldEnd && start == newEnd ? nil : .init(start: start, deletionEnd: oldEnd, additionEnd: newEnd)
}

private struct SessionRegionPlan {
    var start: Int
    var end: Int
    var blocks: [HunkContent] = []
    var previous: PreviousRegionSpan?
    mutating func merge(_ other: Self) {
        start = min(start, other.start); end = max(end, other.end); blocks += other.blocks
        if let span = other.previous {
            previous = .init(firstIndex: min(previous?.firstIndex ?? span.firstIndex, span.firstIndex),
                             lastIndex: max(previous?.lastIndex ?? span.lastIndex, span.lastIndex))
        }
    }
}

/// Retains old-side regions across undo and grows or merges them as edits cross boundaries.
/// Full file lines are required. The update is atomic if region validation fails.
@discardableResult
public func rebuildSessionHunks(_ diff: inout FileDiffMetadata, options: DiffOptions = .init()) throws -> SessionRegionChange? {
    guard !diff.isPartial else { throw DiffError.partialDiff }
    var next = diff
    next.additionLines = normalizeEditorLines(diff.additionLines)
    var blocks: [HunkContent] = [], old = 0, new = 0
    if findDivergenceCore(next.deletionLines, next.additionLines) != nil {
        let parsed = try canonicalRecompute(next, options: options)
        for hunk in parsed.hunks {
            let gap = hunk.additionCount > 0 ? hunk.additionLineIndex - new : hunk.deletionLineIndex - old
            old += gap; new += gap
            for var content in hunk.hunkContent {
                if content.type == .context { old += content.lines; new += content.lines; continue }
                if content.additions == 0 { content.additionLineIndex = new }
                if content.deletions == 0 { content.deletionLineIndex = old }
                blocks.append(content); old += content.deletions; new += content.additions
            }
        }
    }
    let previous = diff.hunks.enumerated().map { index, hunk in
        SessionRegionPlan(start: hunk.oldBoundary, end: hunk.oldBoundary + hunk.deletionCount,
                          previous: .init(firstIndex: index, lastIndex: index))
    }
    var plans: [SessionRegionPlan] = [], previousIndex = 0
    for block in blocks {
        let start = block.deletionLineIndex, end = start + block.deletions
        while previousIndex < previous.count && previous[previousIndex].end < start {
            plans.append(previous[previousIndex]); previousIndex += 1
        }
        var plan: SessionRegionPlan?
        if let last = plans.last, start <= last.end && end >= last.start { plan = plans.removeLast() }
        while previousIndex < previous.count && previous[previousIndex].start <= end {
            if plan == nil { plan = previous[previousIndex] } else { plan!.merge(previous[previousIndex]) }
            previousIndex += 1
        }
        if plan == nil {
            var lower = start, upper = end
            if (block.deletions == 0 || block.additions == 0) && diff.deletionLines.count > block.deletions {
                let previousEnd = plans.last?.end ?? 0
                let nextStart = previousIndex < previous.count ? previous[previousIndex].start : diff.deletionLines.count
                if start > previousEnd { lower -= 1 } else if end < nextStart { upper += 1 }
            }
            plan = .init(start: lower, end: upper)
        }
        plan!.start = min(plan!.start, start); plan!.end = max(plan!.end, end)
        plan!.blocks.append(block); plans.append(plan!)
    }
    plans += previous.dropFirst(previousIndex)
    old = 0; new = 0; next.hunks = []
    for plan in plans {
        let gap = plan.start - old
        guard gap >= 0 else { throw DiffError.invalidPatch("Overlapping editor regions") }
        old += gap; new += gap
        let newStart = new
        var hunk = Hunk()
        func appendContext(_ count: Int) {
            if count > 0 { hunk.hunkContent.append(.init(type: .context, lines: count, deletionLineIndex: old, additionLineIndex: new)) }
            old += count; new += count
        }
        for block in plan.blocks {
            let context = block.deletionLineIndex - old
            guard context >= 0 && context == block.additionLineIndex - new else { throw DiffError.invalidPatch("Editor block context mismatch") }
            appendContext(context); hunk.hunkContent.append(block)
            old += block.deletions; new += block.additions
        }
        guard plan.end >= old else { throw DiffError.invalidPatch("Editor block exceeds region") }
        appendContext(plan.end - old)
        hunk.deletionCount = plan.end - plan.start; hunk.additionCount = new - newStart
        hunk.deletionStart = plan.start + (hunk.deletionCount == 0 ? 0 : 1)
        hunk.additionStart = newStart + (hunk.additionCount == 0 ? 0 : 1)
        hunk.deletionLineIndex = plan.start - (hunk.deletionCount == 0 ? 1 : 0)
        hunk.additionLineIndex = newStart - (hunk.additionCount == 0 ? 1 : 0)
        hunk.hunkSpecs = "@@ -\(hunk.deletionStart),\(hunk.deletionCount) +\(hunk.additionStart),\(hunk.additionCount) @@"
        next.hunks.append(hunk)
    }
    guard next.deletionLines.count - old == next.additionLines.count - new else { throw DiffError.invalidPatch("Editor trailing context mismatch") }
    next.editSessionDirty = true
    recomputeGeometry(&next)
    for index in next.hunks.indices {
        let last = index == next.hunks.count - 1
        next.hunks[index].noEOFCRAdditions = last && next.additionLines.last.map { !$0.isEmpty && $0.utf8.last != 10 } == true
        next.hunks[index].noEOFCRDeletions = last && next.deletionLines.last.map { !$0.isEmpty && $0.utf8.last != 10 } == true
    }
    preserveTrailingEditorBlankLine(&next, additionLines: diff.additionLines)
    let changed = !sameSessionLayout(diff.hunks, next.hunks)
    diff = next
    return changed ? .init(regions: plans.map(\.previous)) : nil
}

// Compare row coordinates without allocating an array proportional to the file.
private struct SplitMapping: IteratorProtocol {
    struct Row: Equatable { var old: Int?; var new: Int? }
    var contents: [HunkContent]
    var index = 0, offset = 0
    mutating func next() -> Row? {
        while index < contents.count {
            let c = contents[index], count = max(c.oldCount, c.newCount)
            if offset >= count { index += 1; offset = 0; continue }
            defer { offset += 1 }
            return .init(old: offset < c.oldCount ? c.deletionLineIndex + offset : nil,
                         new: offset < c.newCount ? c.additionLineIndex + offset : nil)
        }
        return nil
    }
}
private func sameSessionLayout(_ old: [Hunk], _ new: [Hunk]) -> Bool {
    guard old.count == new.count else { return false }
    for (a, b) in zip(old, new) {
        guard a.oldBoundary == b.oldBoundary, a.newBoundary == b.newBoundary,
              a.deletionCount == b.deletionCount, a.additionCount == b.additionCount,
              a.splitLineCount == b.splitLineCount else { return false }
        var left = SplitMapping(contents: a.hunkContent), right = SplitMapping(contents: b.hunkContent)
        while true {
            let x = left.next(), y = right.next()
            if x != y { return false }; if x == nil { break }
        }
    }
    return true
}

/// Updates same-line-count edits. Balanced unmatched replacements retain their existing blocks.
@discardableResult
public func applySessionChangedLines(_ diff: inout FileDiffMetadata, changedAdditionLineIndexes: [Int],
                                     options: DiffOptions = .init(), previousAdditionLines: [Int: String]? = nil) throws -> SessionRegionChange? {
    try applySessionLines(&diff, changedAdditionLineIndexes: changedAdditionLineIndexes, options: options,
                          previousAdditionLines: previousAdditionLines, cachedOldLines: nil)
}
private func applySessionLines(_ diff: inout FileDiffMetadata, changedAdditionLineIndexes: [Int], options: DiffOptions,
                               previousAdditionLines: [Int: String]?, cachedOldLines: Set<Data>?) throws -> SessionRegionChange? {
    guard !diff.isPartial else { throw DiffError.partialDiff }
    let lines = Set(changedAdditionLineIndexes).filter { diff.additionLines.indices.contains($0) }.sorted()
    guard !lines.isEmpty else { return nil }
    var region: Int?, index = 0
    for line in lines {
        while index < diff.hunks.count && line >= diff.hunks[index].newBoundary + diff.hunks[index].additionCount { index += 1 }
        guard index < diff.hunks.count, line >= diff.hunks[index].newBoundary, region == nil || region == index else {
            return try rebuildSessionHunks(&diff, options: options)
        }
        region = index
    }
    let hunk = diff.hunks[region!]
    // UTF-8 keys preserve JavaScript exact equality, including canonically equivalent text.
    if let previousAdditionLines, !options.ignoreWhitespace, !options.stripTrailingCr,
       !hunk.hunkContent.contains(where: { $0.type == .change && ($0.additions == 0 || $0.deletions == 0) }) {
        let oldLines = cachedOldLines ?? Set(diff.deletionLines.map { Data($0.utf8) })
        let retain = lines.allSatisfy { line in
            guard let previous = previousAdditionLines[line], !oldLines.contains(Data(previous.utf8)),
                  !oldLines.contains(Data(diff.additionLines[line].utf8)) else { return false }
            return hunk.hunkContent.contains { c in
                c.type == .change && c.additions == c.deletions && line >= c.additionLineIndex && line < c.additionLineIndex + c.additions
            }
        }
        if retain { diff.editSessionDirty = true; return nil }
    }
    return try rebuildSessionHunks(&diff, options: options)
}

public func remapExpandedHunksForRegionChange(_ expandedHunks: [Int: HunkExpansionRegion], change: SessionRegionChange) -> [Int: HunkExpansionRegion] {
    var result: [Int: HunkExpansionRegion] = [:]
    for key in 0...change.regions.count {
        let previous = key > 0 ? change.regions[key - 1] : nil
        let next = key < change.regions.count ? change.regions[key] : nil
        let start = key == 0 ? expandedHunks[0]?.fromStart ?? 0 : previous.flatMap { expandedHunks[$0.lastIndex + 1]?.fromStart } ?? 0
        let end = next.flatMap { expandedHunks[$0.firstIndex]?.fromEnd } ?? 0
        if start > 0 || end > 0 { result[key] = .init(fromStart: start, fromEnd: end) }
    }
    return result
}

/// Expanded slices use immutable old-side coordinates so they survive the final recompute.
public func captureExpansionAnchors(_ diff: FileDiffMetadata, expandedHunks: [Int: HunkExpansionRegion], collapsedContextThreshold: Int) throws -> [Range<Int>] {
    guard !diff.isPartial else { return [] }
    var anchors: [Range<Int>] = []
    for (index, hunk) in diff.hunks.enumerated() {
        let size = max(0, hunk.collapsedBefore)
        guard size > collapsedContextThreshold else { continue }
        var start = min(size, max(0, expandedHunks[index]?.fromStart ?? 0))
        var end = min(size, max(0, expandedHunks[index]?.fromEnd ?? 0))
        if start + end >= size { start = size; end = 0 }
        let gapEnd = hunk.oldBoundary, gapStart = gapEnd - size
        if start > 0 { anchors.append(gapStart..<(gapStart + start)) }
        if end > 0 { anchors.append((gapEnd - end)..<gapEnd) }
    }
    if let last = diff.hunks.last, !diff.additionLines.isEmpty, !diff.deletionLines.isEmpty {
        let start = last.oldBoundary + last.deletionCount
        let oldRemaining = diff.deletionLines.count - start
        let newRemaining = diff.additionLines.count - last.newBoundary - last.additionCount
        if oldRemaining > 0 || newRemaining > 0 {
            guard oldRemaining == newRemaining else { throw DiffError.invalidPatch("Editor trailing context mismatch") }
            let count = min(oldRemaining, max(0, expandedHunks[diff.hunks.count]?.fromStart ?? 0))
            if oldRemaining > collapsedContextThreshold && count > 0 { anchors.append(start..<(start + count)) }
        }
    }
    return anchors
}

public func rebuildExpansionFromAnchors(_ diff: FileDiffMetadata, anchors: [Range<Int>]) -> [Int: HunkExpansionRegion] {
    var result: [Int: HunkExpansionRegion] = [:]
    func apply(_ key: Int, _ start: Int, _ end: Int) {
        guard end > start else { return }
        var fromStart = 0, fromEnd = 0
        for range in anchors where range.upperBound > start && range.lowerBound < end {
            if range.lowerBound <= start { fromStart = max(fromStart, min(range.upperBound, end) - start) }
            if range.upperBound >= end { fromEnd = max(fromEnd, end - max(range.lowerBound, start)) }
        }
        if fromStart > 0 || fromEnd > 0 { result[key] = .init(fromStart: fromStart, fromEnd: fromEnd) }
    }
    for (index, hunk) in diff.hunks.enumerated() { apply(index, hunk.oldBoundary - max(hunk.collapsedBefore, 0), hunk.oldBoundary) }
    if let last = diff.hunks.last, !diff.isPartial, !diff.deletionLines.isEmpty {
        apply(diff.hunks.count, last.oldBoundary + last.deletionCount, diff.deletionLines.count)
    }
    return result
}

private func canonicalRecompute(_ diff: FileDiffMetadata, options: DiffOptions) throws -> FileDiffMetadata {
    try parseDiffFromFile(.init(name: diff.prevName ?? diff.name, contents: diff.deletionLines.joined()),
                          .init(name: diff.name, contents: diff.additionLines.joined(), lang: diff.lang), options: options)
}
public func preserveTrailingEditorBlankLine(_ diff: inout FileDiffMetadata, additionLines: [String]) {
    let extra = additionLines.count - diff.additionLines.count
    guard additionLines.count > 1, additionLines.last == "", extra > 0, let last = diff.hunks.last,
          last.newBoundary + last.additionCount == diff.additionLines.count else { return }
    for index in last.hunkContent.indices {
        let c = last.hunkContent[index]
        if c.type == .change && c.additions < c.deletions && c.additionLineIndex + c.additions == diff.additionLines.count {
            diff.additionLines = additionLines
            let hi = diff.hunks.count - 1
            diff.hunks[hi].hunkContent[index].additions += extra
            diff.hunks[hi].additionCount += extra
            recomputeGeometry(&diff); return
        }
    }
}

/// Rebuilds the diff on session exit, preserving non-hunk metadata and clearing the dirty flag.
@discardableResult
public func finishEditSessionForDiff(_ diff: inout FileDiffMetadata, options: DiffOptions = .init()) throws -> Bool {
    guard diff.editSessionDirty == true else { return false }
    guard !diff.isPartial else { throw DiffError.partialDiff }
    var result: FileDiffMetadata
    let additions = diff.additionLines
    let empty = additions.count <= 1 && additions.joined().isEmpty
    if !empty && shouldTopAlignAdditionRecompute(diff, additionLines: additions) {
        result = try topAlignedRecompute(diff, additionLines: additions, options: options)
    } else {
        result = try canonicalRecompute(diff, options: options)
        if !empty { preserveTrailingEditorBlankLine(&result, additionLines: additions) }
    }
    installHunkUpdate(&diff, from: result)
    diff.editSessionDirty = nil
    return true
}
public func shouldTopAlignAdditionRecompute(_ diff: FileDiffMetadata, additionLines: [String]) -> Bool {
    !additionLines.isEmpty && additionLines.count < diff.deletionLines.count &&
        additionLines.allSatisfy { $0.unicodeScalars.allSatisfy { isECMAScriptWhitespace($0.value) } }
}
private func topAlignedRecompute(_ diff: FileDiffMetadata, additionLines: [String], options: DiffOptions) throws -> FileDiffMetadata {
    var sentinel = (0..<max(additionLines.count, 1)).map { String(repeating: " ", count: $0 + 1) + "\n" }.joined()
    if sentinel.utf16.elementsEqual(diff.deletionLines.joined().utf16) {
        sentinel = (0..<max(additionLines.count, 1)).map { "\0" + String(repeating: " ", count: $0) + "\n" }.joined()
    }
    var placeholder = diff; placeholder.additionLines = splitFileContents(sentinel)
    var result = try canonicalRecompute(placeholder, options: options); result.additionLines = additionLines
    return result
}
private func installHunkUpdate(_ diff: inout FileDiffMetadata, from result: FileDiffMetadata) {
    diff.hunks = result.hunks; diff.splitLineCount = result.splitLineCount; diff.unifiedLineCount = result.unifiedLineCount
    diff.deletionLines = result.deletionLines; diff.additionLines = result.additionLines; diff.type = result.type
}

/// A retained native session model. Its old file remains immutable; line edits reuse
/// a precomputed exact old-line index. Run structural edits on your editing actor.
/// This owns diff regions and expansion state; it does not own AppKit undo or focus.
public struct DiffEditSession: Sendable {
    public private(set) var diff: FileDiffMetadata
    public var expandedHunks: [Int: HunkExpansionRegion]
    public let options: DiffOptions
    private let oldLines: Set<Data>

    public init(diff: FileDiffMetadata, options: DiffOptions = .init(), expandedHunks: [Int: HunkExpansionRegion] = [:]) throws {
        guard !diff.isPartial else { throw DiffError.partialDiff }
        self.diff = diff; self.diff.cacheKey = nil
        self.options = options; self.expandedHunks = expandedHunks
        oldLines = Set(diff.deletionLines.map { Data($0.utf8) })
    }

    /// Replaces source rows without changing their count. Values include their line terminators.
    /// Structural text changes should use `replaceAdditionLines` instead.
    @discardableResult public mutating func updateLines(_ replacements: [Int: String]) throws -> SessionRegionChange? {
        guard !replacements.isEmpty else { return nil }
        guard replacements.keys.allSatisfy({ diff.additionLines.indices.contains($0) }) else { throw TextDocumentError.invalidRange }
        var next = diff
        var previous: [Int: String] = [:]
        for (index, line) in replacements { previous[index] = next.additionLines[index]; next.additionLines[index] = line }
        if try applySpecialDocument(&next) { diff = next; return nil }
        let change = try applySessionLines(&next, changedAdditionLineIndexes: Array(replacements.keys), options: options,
                                          previousAdditionLines: previous, cachedOldLines: oldLines)
        install(next, change: change); return change
    }

    /// Installs the current editor rows, including its empty caret row or trailing empty row.
    @discardableResult public mutating func replaceAdditionLines(_ lines: [String]) throws -> SessionRegionChange? {
        var next = diff; next.additionLines = lines
        if try applySpecialDocument(&next) { diff = next; return nil }
        let change = try rebuildSessionHunks(&next, options: options)
        install(next, change: change); return change
    }

    @discardableResult public mutating func finish(collapsedContextThreshold: Int = 1) throws -> Bool {
        guard diff.editSessionDirty == true else { return false }
        let anchors = try captureExpansionAnchors(diff, expandedHunks: expandedHunks, collapsedContextThreshold: collapsedContextThreshold)
        var next = diff
        try finishEditSessionForDiff(&next, options: options)
        expandedHunks = rebuildExpansionFromAnchors(next, anchors: anchors); diff = next
        return true
    }
    private mutating func install(_ next: FileDiffMetadata, change: SessionRegionChange?) {
        if let change { expandedHunks = remapExpandedHunksForRegionChange(expandedHunks, change: change) }
        diff = next
    }
    private func applySpecialDocument(_ next: inout FileDiffMetadata) throws -> Bool {
        let empty = next.additionLines.count <= 1 && next.additionLines.joined().isEmpty
        guard empty || shouldTopAlignAdditionRecompute(next, additionLines: next.additionLines) else { return false }
        let type = next.type
        let result = try topAlignedRecompute(next, additionLines: empty ? [""] : next.additionLines, options: options)
        installHunkUpdate(&next, from: result)
        next.type = type; next.editSessionDirty = true
        return true
    }
}

#endif

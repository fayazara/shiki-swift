#if os(macOS)
import Foundation

struct Edit: Equatable { enum Kind { case equal, delete, insert }; var kind: Kind; var count: Int }
private struct ExactString: Hashable {
    let value: String
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value.utf16.elementsEqual(rhs.value.utf16) }
    func hash(into hasher: inout Hasher) { for unit in value.utf16 { hasher.combine(unit) } }
}
// JavaScript equality is code-unit exact; Swift String equality folds canonical
// Unicode equivalents. Code review must show those source changes too.
func sequenceDiff(_ a: [String], _ b: [String]) -> [Edit] {
    sequenceDiff(a.map { ExactString(value: $0) }, b.map { ExactString(value: $0) })
}
// Source-faithful native adaptation of jsdiff 9.0.0's pruned Myers frontier.
// Linked, coalesced components share path prefixes; discarded frontier paths release
// their components. Unlike a trace matrix, no copy of each frontier is retained.
private final class EditComponent {
    let edit: Edit
    let previous: EditComponent?
    init(_ edit: Edit, _ previous: EditComponent?) { self.edit = edit; self.previous = previous }
}
private struct EditPath { var oldPosition: Int; var last: EditComponent? }
func sequenceDiff<T: Hashable>(_ a: [T], _ b: [T]) -> [Edit] {
    let oldCount = a.count, newCount = b.count
    if oldCount == 0 { return newCount == 0 ? [] : [.init(kind: .insert, count: newCount)] }
    if newCount == 0 { return [.init(kind: .delete, count: oldCount)] }
    // A proven shortest path for disjoint inputs avoids a quadratic frontier walk.
    if Set(a).isDisjoint(with: b) { return [.init(kind: .delete, count: oldCount), .init(kind: .insert, count: newCount)] }
    func values(_ last: EditComponent?) -> [Edit] {
        var result: [Edit] = [], node = last
        while let current = node { result.append(current.edit); node = current.previous }
        return result.reversed()
    }
    func common(_ path: inout EditPath, _ diagonal: Int) -> Int {
        var old = path.oldPosition, new = old - diagonal, count = 0
        while old + 1 < oldCount && new + 1 < newCount && a[old + 1] == b[new + 1] { old += 1; new += 1; count += 1 }
        if count > 0 { path.last = EditComponent(.init(kind: .equal, count: count), path.last) }
        path.oldPosition = old; return new
    }
    func add(_ path: EditPath, _ kind: Edit.Kind) -> EditPath {
        let component: EditComponent
        if let last = path.last, last.edit.kind == kind { component = EditComponent(.init(kind: kind, count: last.edit.count + 1), last.previous) }
        else { component = EditComponent(.init(kind: kind, count: 1), path.last) }
        return EditPath(oldPosition: path.oldPosition + (kind == .delete ? 1 : 0), last: component)
    }
    var initial = EditPath(oldPosition: -1, last: nil)
    let initialNew = common(&initial, 0)
    if initial.oldPosition + 1 >= oldCount && initialNew + 1 >= newCount { return values(initial.last) }
    var best: [Int: EditPath] = [0: initial]
    var minDiagonal = -(oldCount + newCount), maxDiagonal = oldCount + newCount
    for length in 1...(oldCount + newCount) {
        for diagonal in stride(from: max(minDiagonal, -length), through: min(maxDiagonal, length), by: 2) {
            let removePath = best.removeValue(forKey: diagonal - 1), addPath = best[diagonal + 1]
            let canAdd = addPath.map { let pos = $0.oldPosition - diagonal; return pos >= 0 && pos < newCount } ?? false
            let canRemove = removePath.map { $0.oldPosition + 1 < oldCount } ?? false
            if !canAdd && !canRemove { best[diagonal] = nil; continue }
            var path: EditPath
            if !canRemove || (canAdd && removePath!.oldPosition < addPath!.oldPosition) { path = add(addPath!, .insert) }
            else { path = add(removePath!, .delete) }
            let newPosition = common(&path, diagonal)
            if path.oldPosition + 1 >= oldCount && newPosition + 1 >= newCount { return values(path.last) }
            best[diagonal] = path
            if path.oldPosition + 1 >= oldCount { maxDiagonal = min(maxDiagonal, diagonal - 1) }
            if newPosition + 1 >= newCount { minDiagonal = max(minDiagonal, diagonal + 1) }
        }
    }
    preconditionFailure("Myers frontier did not reach the destination")
}

public struct PatchHeaderOptions: Codable, Equatable, Sendable {
    public var includeIndex: Bool
    public var includeUnderline: Bool
    public var includeFileHeaders: Bool
    public init(includeIndex: Bool = true, includeUnderline: Bool = true, includeFileHeaders: Bool = true) {
        self.includeIndex = includeIndex; self.includeUnderline = includeUnderline; self.includeFileHeaders = includeFileHeaders
    }
    public static let includeHeaders = Self()
    public static let fileHeadersOnly = Self(includeIndex: false, includeUnderline: false)
    public static let omitHeaders = Self(includeIndex: false, includeUnderline: false, includeFileHeaders: false)
}
public struct DiffOptions: Codable, Equatable, Sendable {
    public var context: Int
    public var ignoreWhitespace: Bool
    public var stripTrailingCr: Bool
    public var headerOptions: PatchHeaderOptions?
    public init(context: Int = 4, ignoreWhitespace: Bool = false, stripTrailingCr: Bool = false, headerOptions: PatchHeaderOptions? = nil) {
        self.context = max(0, context); self.ignoreWhitespace = ignoreWhitespace
        self.stripTrailingCr = stripTrailingCr; self.headerOptions = headerOptions
    }
    private enum CodingKeys: String, CodingKey { case context, ignoreWhitespace, stripTrailingCr, headerOptions }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(context: try values.decodeIfPresent(Int.self, forKey: .context) ?? 4,
                  ignoreWhitespace: try values.decodeIfPresent(Bool.self, forKey: .ignoreWhitespace) ?? false,
                  stripTrailingCr: try values.decodeIfPresent(Bool.self, forKey: .stripTrailingCr) ?? false,
                  headerOptions: try values.decodeIfPresent(PatchHeaderOptions.self, forKey: .headerOptions))
    }
}
public func parseDiffFromFile(_ oldFile: FileContents?, _ newFile: FileContents?, options: DiffOptions = .init()) throws -> FileDiffMetadata {
    guard oldFile != nil || newFile != nil else { throw DiffError.missingFiles }
    let old = oldFile ?? FileContents(name: "/dev/null", contents: "")
    let new = newFile ?? FileContents(name: "/dev/null", contents: "")
    let sameName = old.name.utf16.elementsEqual(new.name.utf16)
    let identicalContents = old.contents.utf8.elementsEqual(new.contents.utf8)
    let context = max(0, options.context)
    var diff = FileDiffMetadata(name: newFile?.name ?? old.name)
    diff.isPartial = false; diff.deletionLines = splitFileContents(old.contents)
    diff.additionLines = identicalContents ? diff.deletionLines : splitFileContents(new.contents)
    diff.lang = newFile?.lang ?? (newFile == nil ? oldFile?.lang : nil)
    if let a = oldFile?.cacheKey, let b = newFile?.cacheKey { diff.cacheKey = composeCacheKey("diff", a, b) }
    if oldFile == nil { diff.type = .new }
    else if newFile == nil { diff.type = .deleted }
    else if !sameName { diff.type = .renameChanged; diff.prevName = old.name }
    else if old.contents.isEmpty && !new.contents.isEmpty { diff.type = .new }
    else if !old.contents.isEmpty && new.contents.isEmpty { diff.type = .deleted }
    func comparisonLines(_ lines: [String]) -> [String] {
        guard options.ignoreWhitespace || options.stripTrailingCr else { return lines }
        return lines.map { line in
            let value = options.stripTrailingCr ? line.replacingOccurrences(of: "\r\n", with: "\n") : line
            return options.ignoreWhitespace ? trimECMAScriptWhitespace(value) : value
        }
    }
    // Exact identical sources need no comparison tokens or edit frontier. Keep
    // metadata/header processing below so rename and empty-file semantics match.
    let edits = identicalContents ? [] : sequenceDiff(comparisonLines(diff.deletionLines), comparisonLines(diff.additionLines))
    var blocks: [HunkContent] = [], oi = 0, ni = 0
    for edit in edits {
        switch edit.kind {
        case .equal:
            blocks.append(.init(type: .context, lines: edit.count, deletionLineIndex: oi, additionLineIndex: ni)); oi += edit.count; ni += edit.count
        case .delete:
            blocks.append(.init(type: .change, deletions: edit.count, deletionLineIndex: oi, additionLineIndex: ni)); oi += edit.count
        case .insert:
            if blocks.last?.type == .change { blocks[blocks.count - 1].additions += edit.count }
            else { blocks.append(.init(type: .change, additions: edit.count, deletionLineIndex: oi, additionLineIndex: ni)) }
            ni += edit.count
        }
    }
    var pending: [HunkContent] = []
    func finish() {
        guard let first = pending.first else { return }
        var h = Hunk(); h.hunkContent = pending
        h.deletionLineIndex = first.deletionLineIndex; h.additionLineIndex = first.additionLineIndex
        h.deletionCount = pending.reduce(0) { $0 + $1.oldCount }; h.additionCount = pending.reduce(0) { $0 + $1.newCount }
        h.deletionStart = first.deletionLineIndex + (h.deletionCount > 0 ? 1 : 0)
        h.additionStart = first.additionLineIndex + (h.additionCount > 0 ? 1 : 0)
        // processFile indexes hydrated zero-count sides at start - 1 too.
        // Such indexes may be -1 at file start and must never be dereferenced.
        if h.deletionCount == 0 {
            h.deletionLineIndex -= 1
            for i in h.hunkContent.indices { h.hunkContent[i].deletionLineIndex -= 1 }
        }
        if h.additionCount == 0 {
            h.additionLineIndex -= 1
            for i in h.hunkContent.indices { h.hunkContent[i].additionLineIndex -= 1 }
        }
        h.hunkSpecs = "@@ -\(h.deletionStart),\(h.deletionCount) +\(h.additionStart),\(h.additionCount) @@\n"
        h.noEOFCRDeletions = h.deletionCount > 0 && first.deletionLineIndex + h.deletionCount == diff.deletionLines.count && old.contents.utf8.last != 10
        h.noEOFCRAdditions = h.additionCount > 0 && first.additionLineIndex + h.additionCount == diff.additionLines.count && new.contents.utf8.last != 10
        // jsdiff writes equal context using the new-side token. A context EOF
        // marker therefore applies to both sides, including ignored-whitespace diffs.
        if pending.last?.type == .context,
           first.deletionLineIndex + h.deletionCount == diff.deletionLines.count,
           first.additionLineIndex + h.additionCount == diff.additionLines.count {
            h.noEOFCRDeletions = new.contents.utf8.last != 10
            h.noEOFCRAdditions = h.noEOFCRDeletions
        }
        diff.hunks.append(h); pending = []
    }
    for (i, block) in blocks.enumerated() {
        if block.type == .change { pending.append(block); continue }
        let hasFollowingChange = i + 1 < blocks.count
        if !pending.isEmpty && hasFollowingChange && block.lines - min(block.lines, context) <= context { pending.append(block); continue }
        if !pending.isEmpty {
            var tail = block; tail.lines = min(block.lines, context)
            if tail.lines > 0 { pending.append(tail) }; finish()
        }
        if hasFollowingChange {
            var lead = block; lead.lines = min(block.lines, context)
            lead.deletionLineIndex += block.lines - lead.lines; lead.additionLineIndex += block.lines - lead.lines
            if lead.lines > 0 { pending.append(lead) }
        }
    }
    finish()
    if diff.prevName != nil { diff.type = diff.hunks.isEmpty ? .renamePure : .renameChanged }
    if let headers = options.headerOptions, !headers.includeFileHeaders {
        diff.name = ""; diff.prevName = nil
        diff.type = oldFile == nil || old.contents.isEmpty && !new.contents.isEmpty ? .new
            : newFile == nil || !old.contents.isEmpty && new.contents.isEmpty ? .deleted : .change
        // The upstream parser consumes the first hunk as its header bucket if
        // patch formatting emitted no preamble at all. Preserve that observable shape.
        if !headers.includeUnderline && !(headers.includeIndex && sameName), !diff.hunks.isEmpty { diff.hunks.removeFirst() }
    }
    recomputeGeometry(&diff); realignChangeContentBySimilarity(&diff); return diff
}
func recomputeGeometry(_ diff: inout FileDiffMetadata) {
    diff.splitLineCount = 0; diff.unifiedLineCount = 0; var lastEnd = 0
    for i in diff.hunks.indices {
        var h = diff.hunks[i]
        h.collapsedBefore = max(0, h.newBoundary - lastEnd)
        h.additionLines = 0; h.deletionLines = 0; h.splitLineCount = 0; h.unifiedLineCount = 0
        for c in h.hunkContent {
            h.additionLines += c.additions; h.deletionLines += c.deletions
            h.splitLineCount += c.type == .context ? c.lines : max(c.additions, c.deletions)
            h.unifiedLineCount += c.type == .context ? c.lines : c.additions + c.deletions
        }
        h.splitLineStart = diff.splitLineCount + h.collapsedBefore; h.unifiedLineStart = diff.unifiedLineCount + h.collapsedBefore
        diff.splitLineCount = h.splitLineStart + h.splitLineCount; diff.unifiedLineCount = h.unifiedLineStart + h.unifiedLineCount
        lastEnd = h.newBoundary + h.additionCount; diff.hunks[i] = h
    }
    if !diff.isPartial && !diff.hunks.isEmpty {
        let trailing = max(0, diff.additionLines.count - lastEnd)
        diff.splitLineCount += trailing; diff.unifiedLineCount += trailing
    }
}

#endif

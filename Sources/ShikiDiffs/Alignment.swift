#if os(macOS)
import Foundation

/// Mirrors upstream's bounded, whitespace-insensitive pairing and blank-run anchoring.
public func realignChangeContentBySimilarity(_ diff: inout FileDiffMetadata) {
    func similarity(_ a: [UInt16], _ b: [UInt16]) -> Double {
        if a == b { return 1 }; let n = min(a.count, b.count); if n == 0 { return 0 }
        var prefix = 0, suffix = 0
        while prefix < n && a[prefix] == b[prefix] { prefix += 1 }
        while suffix < n - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return Double(prefix + suffix) / Double(max(a.count, b.count))
    }
    for hi in diff.hunks.indices {
        var blocks: [HunkContent] = []
        for c in diff.hunks[hi].hunkContent {
            let pairs = min(c.deletions, c.additions), surplus = abs(c.additions - c.deletions)
            guard c.type == .change && pairs > 0 && surplus > 0 && pairs * (surplus + 1) <= 4096 else { blocks.append(c); continue }
            func normalized(_ line: String) -> [UInt16] {
                Array(String(String.UnicodeScalarView(line.unicodeScalars.filter { !isECMAScriptWhitespace($0.value) })).utf16)
            }
            let a = diff.deletionLines[c.deletionLineIndex..<(c.deletionLineIndex + c.deletions)].map(normalized)
            let b = diff.additionLines[c.additionLineIndex..<(c.additionLineIndex + c.additions)].map(normalized)
            let longer = c.additions > c.deletions
            var bestOffset = 0, bestScore = -1.0
            for offset in 0...surplus {
                var score = 0.0
                for pair in 0..<pairs { score += similarity(a[pair + (longer ? 0 : offset)], b[pair + (longer ? offset : 0)]) }
                if offset == 0 { bestScore = score + Double(pairs) * 0.5 }
                else if score > bestScore { bestScore = score; bestOffset = offset }
            }
            guard bestOffset > 0 else { blocks.append(c); continue }
            func push(_ d: Int, _ a: Int, _ di: Int, _ ai: Int) {
                if d + a > 0 { blocks.append(.init(type: .change, deletions: d, additions: a, deletionLineIndex: di, additionLineIndex: ai)) }
            }
            let di = c.deletionLineIndex, ai = c.additionLineIndex
            push(longer ? 0 : bestOffset, longer ? bestOffset : 0, di, ai)
            push(pairs, pairs, di + (longer ? 0 : bestOffset), ai + (longer ? bestOffset : 0))
            push(longer ? 0 : surplus - bestOffset, longer ? surplus - bestOffset : 0, di + pairs + (longer ? 0 : bestOffset), ai + pairs + (longer ? bestOffset : 0))
        }
        var i = 1
        while i < blocks.count {
            let block = blocks[i], previous = blocks[i - 1]
            guard block.type == .change, min(block.additions, block.deletions) == 0, previous.type == .context else { i += 1; continue }
            let lines = block.additions > 0 ? diff.additionLines : diff.deletionLines
            let start = block.additions > 0 ? block.additionLineIndex : block.deletionLineIndex
            let count = max(block.additions, block.deletions)
            guard count > 0, start < lines.count else { i += 1; continue }
            let unit = lines[start]
            guard trimECMAScriptWhitespace(unit).isEmpty, lines[start..<(start + count)].allSatisfy({ $0.utf16.elementsEqual(unit.utf16) }) else { i += 1; continue }
            var slide = 0
            while slide < previous.lines && diff.additionLines[previous.additionLineIndex + previous.lines - 1 - slide].utf16.elementsEqual(unit.utf16) { slide += 1 }
            guard slide > 0 && !(i == 1 && slide == previous.lines) else { i += 1; continue }
            blocks[i].additionLineIndex -= slide; blocks[i].deletionLineIndex -= slide
            let ai = blocks[i].additionLineIndex + block.additions, di = blocks[i].deletionLineIndex + block.deletions
            if i + 1 < blocks.count && blocks[i + 1].type == .context { blocks[i + 1].lines += slide; blocks[i + 1].additionLineIndex = ai; blocks[i + 1].deletionLineIndex = di }
            else { blocks.insert(.init(type: .context, lines: slide, deletionLineIndex: di, additionLineIndex: ai), at: i + 1) }
            blocks[i - 1].lines -= slide
            if blocks[i - 1].lines == 0 { blocks.remove(at: i - 1) } else { i += 1 }
        }
        diff.hunks[hi].hunkContent = blocks
    }
}
public func hydratePartialDiff(_ diff: FileDiffMetadata, oldFile: FileContents?, newFile: FileContents) throws -> FileDiffMetadata {
    guard diff.isPartial else { throw DiffError.invalidHydration }
    var result = diff
    if diff.type == .renamePure {
        guard oldFile == nil else { throw DiffError.invalidHydration }
        result.deletionLines = splitFileContents(newFile.contents); result.additionLines = result.deletionLines
    } else {
        guard (diff.type == .change || diff.type == .renameChanged), let oldFile else { throw DiffError.invalidHydration }
        result.deletionLines = splitFileContents(oldFile.contents); result.additionLines = splitFileContents(newFile.contents)
        for i in result.hunks.indices {
            var h = result.hunks[i]
            var ai = max(h.additionStart - 1, 0), di = max(h.deletionStart - 1, 0)
            h.additionLineIndex = ai; h.deletionLineIndex = di
            for j in h.hunkContent.indices {
                h.hunkContent[j].additionLineIndex = ai; h.hunkContent[j].deletionLineIndex = di
                ai += h.hunkContent[j].newCount; di += h.hunkContent[j].oldCount
            }
            guard ai <= result.additionLines.count && di <= result.deletionLines.count else { throw DiffError.invalidHydration }
            result.hunks[i] = h
        }
    }
    result.isPartial = false
    if let key = diff.cacheKey { result.cacheKey = key + ":hydrated" }
    else if let a = oldFile?.cacheKey, let b = newFile.cacheKey { result.cacheKey = composeCacheKey("hydrated-files", a, b) }
    else if oldFile == nil { result.cacheKey = newFile.cacheKey }
    if diff.type != .renamePure { recomputeGeometry(&result) }
    return result
}

/// Returns a hydrated copy, corresponding to upstream's `clone` mode.
public func hydratePartialDiff(_ diff: FileDiffMetadata, files: LoadedDiffFiles) throws -> FileDiffMetadata {
    try hydratePartialDiff(diff, oldFile: files.oldFile, newFile: files.newFile)
}

/// Replaces the caller's partial diff, corresponding to upstream's `merge` mode.
/// Invalid loaded files leave the original value unchanged.
@discardableResult
public func hydratePartialDiff(_ diff: inout FileDiffMetadata, files: LoadedDiffFiles) throws -> FileDiffMetadata {
    let hydrated = try hydratePartialDiff(diff, files: files)
    diff = hydrated
    return hydrated
}

#endif

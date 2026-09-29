#if os(macOS)
import Foundation

/// Direction for navigation through one-based new-file lines.
public enum LineNavigationDirection: Sendable { case up, down }

// Work from hunk metadata rather than materialized rows: cost is independent of
// the number of hidden lines and of the viewport's current virtualization window.
struct FoldedLineNavigation {
    let diff: FileDiffMetadata
    let options: DiffRenderOptions
    var expanded: Set<Int> = []
    var regions: [Int: HunkExpansionRegion] = [:]

    private struct Region {
        let size: Int
        let start: Int
        let end: Int
        var all: Bool { start >= size - end }
    }
    private func region(_ size: Int, index: Int, trailing: Bool = false) -> Region {
        let size = max(0, size)
        if options.expandUnchanged || expanded.contains(index) || size <= options.collapsedContextThreshold {
            return Region(size: size, start: size, end: 0)
        }
        let value = regions[index] ?? .init()
        let start = min(size, max(0, value.fromStart))
        let end = trailing ? 0 : min(size, max(0, value.fromEnd))
        return start >= size - end ? Region(size: size, start: size, end: 0) : Region(size: size, start: start, end: end)
    }
    private func trailing(_ prefix: String) throws -> Region? {
        let size = try getTrailingContextRangeSize(fileDiff: diff, errorPrefix: prefix)
        return size > 0 ? region(size, index: diff.hunks.count, trailing: true) : nil
    }
    func isRenderable(_ line: Int) throws -> Bool {
        if options.expandUnchanged || diff.isPartial { return true }
        for (index, hunk) in diff.hunks.enumerated() {
            let start = hunk.newBoundary + 1
            if line < start {
                let gap = region(hunk.collapsedBefore, index: index)
                return gap.all || line < start - gap.size + gap.start || line >= start - gap.end
            }
            if line < start + hunk.additionCount { return true }
        }
        guard let gap = try trailing("isAdditionLineRenderable"), !gap.all, let last = diff.hunks.last else { return true }
        let start = last.newBoundary + last.additionCount + 1
        return line < start + gap.start || line >= start + gap.size
    }
    func nearest(_ line: Int, direction: LineNavigationDirection) throws -> Int? {
        if options.expandUnchanged || diff.isPartial { return line }
        var ranges: [(start: Int, end: Int)] = []
        var modeledEnd = 1
        for (index, hunk) in diff.hunks.enumerated() {
            let start = hunk.newBoundary + 1
            let end = start + hunk.additionCount
            let gap = region(hunk.collapsedBefore, index: index)
            if gap.all { ranges.append((start - gap.size, start)) }
            else {
                if gap.start > 0 { ranges.append((start - gap.size, start - gap.size + gap.start)) }
                if gap.end > 0 { ranges.append((start - gap.end, start)) }
            }
            ranges.append((start, end))
            modeledEnd = end
        }
        if let gap = try trailing("getNearestRenderableAdditionLine") {
            let start = modeledEnd
            modeledEnd += gap.size
            if gap.all { ranges.append((start, modeledEnd)) }
            else if gap.start > 0 { ranges.append((start, start + gap.start)) }
        }
        if line >= modeledEnd { return line }
        switch direction {
        case .down: return ranges.first(where: { $0.end > line }).map { max($0.start, line) }
        case .up: return ranges.last(where: { $0.start <= line }).map { min($0.end - 1, line) }
        }
    }
    func expansionToReveal(_ line: Int) throws -> (index: Int, count: Int, direction: ExpansionDirection)? {
        if options.expandUnchanged || diff.isPartial { return nil }
        for (index, hunk) in diff.hunks.enumerated() {
            let start = hunk.newBoundary + 1
            if line < start {
                let gap = region(hunk.collapsedBefore, index: index)
                let visibleStart = start - gap.size + gap.start
                let visibleEnd = start - gap.end
                if gap.all || line < visibleStart || line >= visibleEnd { return nil }
                let fromStart = line - visibleStart + 1
                let fromEnd = visibleEnd - line
                return fromStart <= fromEnd
                    ? (index, fromStart + options.expansionLineCount, .up)
                    : (index, fromEnd + options.expansionLineCount, .down)
            }
            if line < start + hunk.additionCount { return nil }
        }
        guard let gap = try trailing("FileDiff.revealLine"), !gap.all, let last = diff.hunks.last else { return nil }
        let start = last.newBoundary + last.additionCount + 1
        if line < start + gap.start || line >= start + gap.size { return nil }
        return (diff.hunks.count, line - (start + gap.start) + 1 + options.expansionLineCount, .up)
    }
}

#endif

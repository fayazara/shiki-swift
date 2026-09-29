#if os(macOS)
import Foundation

public extension DiffTextSelection {
    /// Copies exact source text, including original line endings. For partial
    /// patches, omitted source is never invented or replaced with markers.
    func text(in diff: FileDiffMetadata) -> String {
        let lines = side == .additions ? diff.additionLines : diff.deletionLines
        let (low, high) = ordered
        guard !lines.isEmpty, high.line >= 0 else { return "" }
        var numbered: [(number: Int, index: Int)] = []
        if diff.isPartial {
            for hunk in diff.hunks {
                let count = side == .additions ? hunk.additionCount : hunk.deletionCount
                let start = side == .additions ? hunk.additionStart : hunk.deletionStart
                let index = side == .additions ? hunk.additionLineIndex : hunk.deletionLineIndex
                for offset in 0..<count where low.line...high.line ~= start + offset - 1 {
                    numbered.append((start + offset - 1, index + offset))
                }
            }
        } else {
            let start = max(0, low.line), end = min(lines.count - 1, high.line)
            guard start <= end else { return "" }
            numbered = (start...end).map { ($0, $0) }
        }
        return numbered.compactMap { number, index -> String? in
            guard lines.indices.contains(index) else { return nil }
            let source = lines[index] as NSString
            let start = min(source.length, max(0, number == low.line ? low.character : 0))
            let end = min(source.length, max(start, number == high.line ? high.character : source.length))
            return source.substring(with: NSRange(location: start, length: end - start))
        }.joined()
    }
}
public extension LineSelection {
    func rowRange(in diff: FileDiffMetadata, style: DiffStyle) -> ClosedRange<Int>? {
        guard let start = diff.selectionLineIndex(startLine, side: side),
              let end = diff.selectionLineIndex(endLine, side: endSide ?? side) else { return nil }
        let a = style == .split ? start.split : start.unified
        let b = style == .split ? end.split : end.unified
        return min(a, b)...max(a, b)
    }
    func text(in diff: FileDiffMetadata) -> String {
        if let endSide, endSide != side {
            guard let range = rowRange(in: diff, style: .unified) else { return "" }
            var result = ""
            // Visit contiguous source spans, intersecting before copying. A tiny
            // selection must not allocate a render row for every line in a file.
            func append(_ lines: [String], source: Int, count: Int, logical: Int) {
                let low = max(0, range.lowerBound - logical)
                let high = min(count, range.upperBound - logical + 1)
                guard low < high else { return }
                for offset in low..<high where lines.indices.contains(source + offset) {
                    result += lines[source + offset]
                }
            }
            if diff.hunks.isEmpty {
                if !diff.isPartial {
                    append(diff.additionLines, source: 0, count: min(diff.additionLines.count, diff.deletionLines.count), logical: 0)
                }
                return result
            }
            var newEnd = 0
            for hunk in diff.hunks {
                if !diff.isPartial {
                    append(diff.additionLines, source: newEnd, count: hunk.collapsedBefore, logical: hunk.unifiedLineStart - hunk.collapsedBefore)
                }
                var logical = hunk.unifiedLineStart
                for content in hunk.hunkContent {
                    if content.type == .context {
                        append(diff.additionLines, source: content.additionLineIndex, count: content.lines, logical: logical)
                        logical += content.lines
                    } else {
                        append(diff.deletionLines, source: content.deletionLineIndex, count: content.deletions, logical: logical)
                        logical += content.deletions
                        append(diff.additionLines, source: content.additionLineIndex, count: content.additions, logical: logical)
                        logical += content.additions
                    }
                }
                newEnd = hunk.newBoundary + hunk.additionCount
                if logical > range.upperBound { return result }
            }
            if !diff.isPartial, let last = diff.hunks.last {
                append(diff.additionLines, source: newEnd, count: diff.additionLines.count - newEnd, logical: last.unifiedLineStart + last.unifiedLineCount)
            }
            return result
        }
        return DiffTextSelection(side: side, anchor: .init(line: min(startLine, endLine) - 1, character: 0), head: .init(line: max(startLine, endLine) - 1, character: Int.max)).text(in: diff)
    }
}

/// Compares supplied endpoints and sides without normalizing their direction or optional end side.
public func areSelectionsEqual(_ lhs: LineSelection?, _ rhs: LineSelection?) -> Bool { lhs == rhs }

#endif

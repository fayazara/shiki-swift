#if os(macOS)
/// Logical code-row indexes, before folding, wrapping, or annotation layout.
public struct DiffLineIndexes: Equatable, Sendable {
    public let unified: Int
    public let split: Int
}

extension FileDiffMetadata {
    /// Native unchanged-file presentation has rows even without diff hunks.
    func selectionLineIndex(_ lineNumber: Int, side: DiffSide) -> DiffLineIndexes? {
        if hunks.isEmpty && !isPartial {
            guard lineNumber > 0, lineNumber <= min(deletionLines.count, additionLines.count) else { return nil }
            return .init(unified: lineNumber - 1, split: lineNumber - 1)
        }
        guard !hunks.isEmpty else { return nil }
        // Parsed hunks are ordered by source position. Find the first hunk
        // whose end is beyond this line, preserving omitted-context mapping.
        var low = 0, high = hunks.count
        while low < high {
            let middle = low + (high - low) / 2
            let hunk = hunks[middle]
            let end = side == .deletions ? hunk.oldBoundary + 1 + hunk.deletionCount : hunk.newBoundary + 1 + hunk.additionCount
            if lineNumber < end { high = middle } else { low = middle + 1 }
        }
        return getLineIndex(lineNumber, side: side, startingAt: min(low, hunks.count - 1))
    }
}

public extension FileDiffMetadata {
    /// Mirrors FileDiff.getLineIndex, including indexes in omitted context.
    func getLineIndex(_ lineNumber: Int, side: DiffSide = .additions) -> DiffLineIndexes? {
        getLineIndex(lineNumber, side: side, startingAt: 0)
    }
    private func getLineIndex(_ lineNumber: Int, side: DiffSide, startingAt first: Int) -> DiffLineIndexes? {
        for index in first..<hunks.count {
            let hunk = hunks[index]
            var number = (side == .deletions ? hunk.oldBoundary : hunk.newBoundary) + 1
            let count = side == .deletions ? hunk.deletionCount : hunk.additionCount
            var unified = hunk.unifiedLineStart, split = hunk.splitLineStart
            if lineNumber < number {
                return .init(unified: max(0, unified - (number - lineNumber)), split: max(0, split - (number - lineNumber)))
            }
            if lineNumber >= number + count {
                if index == hunks.count - 1 {
                    let difference = lineNumber - (number + count)
                    return .init(unified: unified + hunk.unifiedLineCount + difference,
                                 split: split + hunk.splitLineCount + difference)
                }
                continue
            }
            for content in hunk.hunkContent {
                let sideCount = content.type == .context ? content.lines : side == .deletions ? content.deletions : content.additions
                if lineNumber < number + sideCount {
                    let difference = lineNumber - number
                    let deleted = content.type == .change && side == .additions ? content.deletions : 0
                    return .init(unified: unified + deleted + difference, split: split + difference)
                }
                number += sideCount
                unified += content.type == .context ? content.lines : content.deletions + content.additions
                split += content.type == .context ? content.lines : max(content.deletions, content.additions)
            }
            return nil
        }
        return nil
    }
}

#endif

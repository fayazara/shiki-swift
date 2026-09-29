import Foundation
import Shiki

public struct EditorHighlightStatistics: Sendable {
    public var retokenizedLines = 0
    public var reusedLines = 0
    public var cachedDocuments = 0
    public var estimatedBytes = 0
}
struct EditorTokenKey: Hashable {
    var session: UUID
    var side: String
    var language: String
    var theme: String
    var limit: Int
}

/// Actor-owned token document. Sparse checkpoints avoid one highlighter call per
/// source line. Suffix reuse requires both identical text and full grammar state.
final class IncrementalTokenDocument {
    private struct Boundary { var state: ShikiGrammarState? }
    private var lines: [ShikiSplitLine] = []
    private var tokens: [[ThemedToken]] = []
    private var boundaries: [Int: Boundary] = [0: .init(state: nil)]
    private var metadata: TokensResult?
    private(set) var estimatedBytes = 0
    private(set) var retokenizedLines = 0
    private(set) var reusedLines = 0
    func copy() -> IncrementalTokenDocument {
        let copy = IncrementalTokenDocument()
        copy.lines = lines; copy.tokens = tokens; copy.boundaries = boundaries; copy.metadata = metadata; copy.estimatedBytes = estimatedBytes
        return copy
    }

    func update(source: String, engine: ShikiHighlighter, language: String, theme: String, maxLineLength: Int) throws -> TokensResult {
        let next = splitLines(source)
        var prefix = 0
        while prefix < min(lines.count, next.count) && lines[prefix].content.utf16.elementsEqual(next[prefix].content.utf16) { prefix += 1 }
        var oldEnd = lines.count, newEnd = next.count
        while oldEnd > prefix && newEnd > prefix && lines[oldEnd - 1].content.utf16.elementsEqual(next[newEnd - 1].content.utf16) { oldEnd -= 1; newEnd -= 1 }
        let start = boundaries.keys.filter { $0 <= prefix }.max() ?? 0
        var nextBoundaries = boundaries.filter { $0.key <= start }
        var output: [[ThemedToken]] = []; output.reserveCapacity(next.count)
        func reused(_ old: Int, _ new: Int) -> [ThemedToken] {
            let delta = next[new].offset - lines[old].offset
            guard delta != 0 else { return tokens[old] }
            return tokens[old].map { var token = $0; token.offset += delta; return token }
        }
        for index in 0..<start { output.append(reused(index, index)) }
        var cursor = start, state = boundaries[start]?.state, work = 0
        var result = metadata
        let oldBoundaryIndexes = boundaries.keys.sorted()
        func equivalent(_ a: ShikiGrammarState?, _ b: ShikiGrammarState?) -> Bool {
            switch (a, b) { case (nil, nil): return true; case let (a?, b?): return a.isEquivalent(to: b); default: return false }
        }
        while cursor < next.count {
            try Task.checkCancellation()
            var end = min(next.count, cursor + 64)
            // Meet an existing checkpoint in the unchanged suffix, even when an
            // insertion/deletion shifted its line number away from a multiple of 64.
            if cursor >= newEnd,
               let oldBoundary = oldBoundaryIndexes.first(where: { $0 > cursor + oldEnd - newEnd }),
               oldBoundary + newEnd - oldEnd <= end {
                end = oldBoundary + newEnd - oldEnd
            } else if cursor < newEnd && newEnd < end { end = newEnd }
            let fragment = next[cursor..<end].map(\.content).joined(separator: "\n")
            let highlighted = try engine.codeToTokens(fragment, language: language, theme: theme,
                options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: maxLineLength, tokenizeTimeLimit: 0), grammarState: state)
            var relative = 0
            for index in cursor..<end {
                let row = highlighted.tokens[index - cursor]
                let delta = next[index].offset - relative
                output.append(row.map { var token = $0; token.offset += delta; return token })
                relative += next[index].content.utf16.count + 1
            }
            state = highlighted.grammarState as? ShikiGrammarState
            nextBoundaries[end] = .init(state: state); result = highlighted; work += end - cursor; cursor = end
            let oldCursor = cursor + oldEnd - newEnd
            if cursor >= newEnd, let boundary = boundaries[oldCursor], equivalent(state, boundary.state) {
                for new in cursor..<next.count { output.append(reused(new + oldEnd - newEnd, new)) }
                for (index, boundary) in boundaries where index > oldCursor { nextBoundaries[index + newEnd - oldEnd] = boundary }
                break
            }
        }
        try Task.checkCancellation()
        guard var final = result else { preconditionFailure("A token document always contains at least its empty first line") }
        final.tokens = output
        final.grammarState = nextBoundaries[next.count]?.state
        lines = next; tokens = output; boundaries = nextBoundaries; metadata = final
        retokenizedLines = work; reusedLines = next.count - work
        estimatedBytes = source.utf8.count + output.reduce(0) { $0 + $1.count * 112 } + next.count * 48 + boundaries.count * 192
        return final
    }
}

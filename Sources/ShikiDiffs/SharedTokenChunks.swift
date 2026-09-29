import Foundation
import Shiki

/// Bounded reuse across complete source revisions. Grammar-state equality
/// is required: identical text can have different scopes after an earlier edit.
final class SharedTokenChunks {
    private final class Chunk {
        let source: String
        let incoming: ShikiGrammarState?
        let result: TokensResult
        let cost: Int
        weak var previous: Chunk?
        weak var next: Chunk?
        init(source: String, incoming: ShikiGrammarState?, result: TokensResult, cost: Int) {
            self.source = source; self.incoming = incoming; self.result = result; self.cost = cost
        }
    }
    private var oldest: Chunk?
    private var newest: Chunk?
    private(set) var evictionCount = 0
    private var chunks: [String: [Chunk]] = [:]
    private(set) var reusedLines = 0
    private(set) var estimatedBytes = 0
    private let capacityBytes: Int
    init(capacityBytes: Int = 64 * 1024 * 1024) { self.capacityBytes = max(0, capacityBytes) }
    func highlight(_ source: String, engine: ShikiHighlighter, language: String, theme: String, limit: Int) throws -> TokensResult {
        try Task.checkCancellation()
        let lines = splitLines(source)
        reusedLines = 0
        var output: [[ThemedToken]] = []
        output.reserveCapacity(lines.count)
        var state: ShikiGrammarState?
        var final: TokensResult?
        for start in stride(from: 0, to: lines.count, by: 64) {
            try Task.checkCancellation()
            let end = min(lines.count, start + 64)
            let fragment = lines[start..<end].map(\.content).joined(separator: "\n")
            let result: TokensResult
            if let cached = chunks[fragment]?.first(where: {
                $0.source.utf16.elementsEqual(fragment.utf16) && equivalent($0.incoming, state)
            }) {
                touch(cached)
                result = cached.result
                reusedLines += end - start
            } else {
                result = try engine.codeToTokens(fragment, language: language, theme: theme,
                    options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: limit, tokenizeTimeLimit: 0), grammarState: state)
                let cost = fragment.utf8.count + result.tokens.reduce(0) { total, row in
                    total + row.reduce(0) { $0 + 112 + $1.content.utf8.count }
                } + 256
                if cost <= capacityBytes {
                    // Keep the newest four grammar contexts for any one text.
                    if let bucket = chunks[fragment], bucket.count >= 4, let victim = bucket.first { discard(victim) }
                    while cost > capacityBytes - estimatedBytes, let victim = oldest { discard(victim) }
                    let chunk = Chunk(source: fragment, incoming: state, result: result, cost: cost)
                    chunks[fragment, default: []].append(chunk)
                    estimatedBytes += cost
                    appendNewest(chunk)
                }
            }
            var relative = 0
            for index in start..<end {
                let delta = lines[index].offset - relative
                output.append(result.tokens[index - start].map { token in
                    var token = token; token.offset += delta; return token
                })
                relative += lines[index].content.utf16.count + 1
            }
            state = result.grammarState as? ShikiGrammarState
            final = result
        }
        try Task.checkCancellation()
        guard var result = final else {
            return try engine.codeToTokens(source, language: language, theme: theme,
                options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: limit, tokenizeTimeLimit: 0))
        }
        result.tokens = output
        return result
    }
    private func unlink(_ chunk: Chunk) {
        let before = chunk.previous, after = chunk.next
        before?.next = after; after?.previous = before
        if oldest === chunk { oldest = after }
        if newest === chunk { newest = before }
        chunk.previous = nil; chunk.next = nil
    }
    private func appendNewest(_ chunk: Chunk) {
        chunk.previous = newest; newest?.next = chunk
        newest = chunk
        if oldest == nil { oldest = chunk }
    }
    private func touch(_ chunk: Chunk) {
        if newest !== chunk { unlink(chunk); appendNewest(chunk) }
        if (chunks[chunk.source]?.count ?? 0) > 1 {
            chunks[chunk.source]?.removeAll { $0 === chunk }
            chunks[chunk.source]?.append(chunk)
        }
    }
    private func discard(_ chunk: Chunk) {
        unlink(chunk)
        chunks[chunk.source]?.removeAll { $0 === chunk }
        if chunks[chunk.source]?.isEmpty == true { chunks.removeValue(forKey: chunk.source) }
        estimatedBytes -= chunk.cost; evictionCount += 1
    }
    private func equivalent(_ a: ShikiGrammarState?, _ b: ShikiGrammarState?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.isEquivalent(to: b)
        default: return false
        }
    }
}

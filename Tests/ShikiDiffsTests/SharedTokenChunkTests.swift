import Foundation
import Shiki
import Testing
@testable import ShikiDiffs

struct SharedTokenChunkTests {
    @Test func saturatedCacheRetainsRecentChunksAndEvictsLeastRecentlyUsed() throws {
        let engine = try ShikiHighlighter()
        func source(_ version: Int) -> String {
            (0..<64).map { "let value\($0) = \"version \(version)\"" }.joined(separator: "\n")
        }
        func highlight(_ source: String, _ cache: SharedTokenChunks) throws -> TokensResult {
            try cache.highlight(source, engine: engine, language: "swift", theme: "github-dark", limit: 1000)
        }
        let probe = SharedTokenChunks()
        _ = try highlight(source(0), probe)
        let budget = probe.estimatedBytes * 2
        let cache = SharedTokenChunks(capacityBytes: budget)
        _ = try highlight(source(0), cache)
        _ = try highlight(source(1), cache)
        _ = try highlight(source(0), cache) // Refresh the first entry.
        #expect(cache.reusedLines == 64)
        _ = try highlight(source(2), cache)
        #expect(cache.evictionCount == 1 && cache.estimatedBytes <= budget)
        _ = try highlight(source(0), cache)
        #expect(cache.reusedLines == 64)
        _ = try highlight(source(1), cache)
        #expect(cache.reusedLines == 0)
        for version in 3..<30 {
            let text = source(version)
            let actual = try highlight(text, cache)
            let expected = try engine.codeToTokens(text, language: "swift", theme: "github-dark", options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: 1000, tokenizeTimeLimit: 0))
            #expect(actual.tokens == expected.tokens)
            _ = try highlight(text, cache)
            #expect(cache.reusedLines == 64 && cache.estimatedBytes <= budget)
        }
        #expect(cache.evictionCount > 20)
    }

    @Test func highlighterRetainsCompatibleChunksAcrossRevisions() async throws {
        let budget = 2 * 1024 * 1024
        let worker = DiffHighlighter(sharedChunkCacheCapacityBytes: budget)
        let fresh = DiffHighlighter(sharedChunkCacheCapacityBytes: 0)
        let rows = (0..<320).map { "let value\($0) = \"item \($0)\"\n" }
        let old = FileContents(name: "f.swift", contents: rows.joined())
        _ = try await worker.prepare(oldFile: old, newFile: old)
        var editedRows = rows; editedRows[140] = "let value140 = 42\n"
        let edited = FileContents(name: old.name, contents: editedRows.joined())
        let reused = try await worker.prepare(oldFile: old, newFile: edited)
        let independent = try await fresh.prepare(oldFile: old, newFile: edited)
        #expect(reused.newTokens == independent.newTokens)
        #expect(await worker.sharedChunkReusedLines >= 256)
        #expect(await worker.sharedChunkCachedBytes > 0)
        #expect(await worker.sharedChunkCachedBytes <= budget)
        #expect(await fresh.sharedChunkCachedBytes == 0)
        var light = DiffRenderOptions(); light.theme = "pierre-light"
        let themed = try await worker.prepare(oldFile: edited, newFile: edited, options: light)
        #expect(await worker.sharedChunkReusedLines == 0)
        #expect(themed.newTokens == (try await fresh.prepare(oldFile: edited, newFile: edited, options: light)).newTokens)
        light.tokenizeMaxLineLength = 2
        let limited = try await worker.prepare(oldFile: edited, newFile: edited, options: light)
        #expect(await worker.sharedChunkReusedLines == 0)
        #expect(limited.newTokens == (try await fresh.prepare(oldFile: edited, newFile: edited, options: light)).newTokens)
        await worker.clearCache()
        #expect(await worker.sharedChunkCachedBytes == 0)
    }

    @Test func megabyteJSONChunkingMatchesDirectTokenization() throws {
        let source = "[\n" + (0..<12_000).map {
            "  { \"id\": \($0), \"name\": \"Item \($0)\", \"enabled\": true, \"region\": \"ap-south-1\", \"score\": 42 }"
        }.joined(separator: ",\n") + "\n]"
        #expect(source.utf8.count > 1_000_000)
        let directEngine = try ShikiHighlighter()
        let start = ContinuousClock.now
        let direct = try directEngine.codeToTokens(source, language: "json", theme: "github-dark",
            options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: 1000, tokenizeTimeLimit: 0))
        let directTime = start.duration(to: .now)
        let chunkEngine = try ShikiHighlighter(), chunks = SharedTokenChunks()
        let chunkStart = ContinuousClock.now
        let chunked = try chunks.highlight(source, engine: chunkEngine, language: "json", theme: "github-dark", limit: 1000)
        let chunkTime = chunkStart.duration(to: .now)
        #expect(chunked.tokens == direct.tokens)
        print("JSON_TOKENIZATION_COMPARISON bytes=\(source.utf8.count) direct=\(directTime) chunks=\(chunkTime)")
    }

    @Test func cacheBudgetFallsBackWithoutChangingTokens() throws {
        let engine = try ShikiHighlighter()
        let source = (0..<320).map { "let item\($0) = \"value 😀\"" }.joined(separator: "\n")
        let expected = try engine.codeToTokens(source, language: "swift", theme: "github-dark",
            options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: 1000, tokenizeTimeLimit: 0))
        for budget in [0, 1, 64_000] {
            let chunks = SharedTokenChunks(capacityBytes: budget)
            _ = try chunks.highlight(source, engine: engine, language: "swift", theme: "github-dark", limit: 1000)
            let actual = try chunks.highlight(source, engine: engine, language: "swift", theme: "github-dark", limit: 1000)
            #expect(actual.tokens == expected.tokens)
            #expect(chunks.estimatedBytes <= budget)
            if budget <= 1 { #expect(chunks.reusedLines == 0 && chunks.estimatedBytes == 0) }
            else { #expect(chunks.reusedLines < 320 && chunks.evictionCount > 0) }
        }
    }
    @Test func embeddedAndMultilineGrammarsMatchFullShiki() throws {
        let engine = try ShikiHighlighter()
        let fixtures = [
            ("typescript", "const value = `", "${item}", "`;"),
            ("html", "<script>", "const value = '😀';", "</script>"),
            ("markdown", "```typescript", "const value = '😀';", "```"),
            ("bash", "cat <<'EOF'", "hello $USER 😀", "EOF"),
            ("python", "value = \"\"\"", "hello 😀", "\"\"\"")
        ]
        for (language, open, body, close) in fixtures {
            var rows = Array(repeating: body, count: 320)
            rows[0] = open; rows[257] = close
            let chunks = SharedTokenChunks()
            for variant in 0..<3 {
                if variant == 1 { rows[63] = close }
                if variant == 2 { rows[63] = body; rows[127] = String(repeating: "x", count: 1100) }
                let source = rows.joined(separator: variant == 1 ? "\r\n" : "\n")
                let full = try engine.codeToTokens(source, language: language, theme: "github-dark",
                    options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: 1000, tokenizeTimeLimit: 0))
                let shared = try chunks.highlight(source, engine: engine, language: language, theme: "github-dark", limit: 1000)
                #expect(shared.tokens == full.tokens, "\(language) variant \(variant)")
                let actual = try #require(shared.grammarState as? ShikiGrammarState)
                let expected = try #require(full.grammarState as? ShikiGrammarState)
                #expect(actual.isEquivalent(to: expected), "\(language) final state \(variant)")
            }
        }
    }
    @Test func movedWholeChunksReuseTokensWithRebasedOffsets() throws {
        let engine = try ShikiHighlighter(), chunks = SharedTokenChunks()
        let rows = (0..<320).map { "let item\($0) = \"😀\"" }
        _ = try chunks.highlight(rows.joined(separator: "\n"), engine: engine, language: "swift", theme: "github-dark", limit: 1000)
        let moved = (Array(rows[..<64]) + Array(repeating: "// inserted", count: 64) + Array(rows[64...])).joined(separator: "\r\n")
        let actual = try chunks.highlight(moved, engine: engine, language: "swift", theme: "github-dark", limit: 1000)
        let expected = try engine.codeToTokens(moved, language: "swift", theme: "github-dark", options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: 1000, tokenizeTimeLimit: 0))
        #expect(actual.tokens == expected.tokens)
        #expect(chunks.reusedLines >= 256)
    }
    @Test func reusedChunksMatchIndependentFullTokenization() throws {
        let engine = try ShikiHighlighter()
        for ending in ["\n", "\r\n"] {
            let original = (0..<320).map { "let item\($0) = \"value 😀 \($0)\"" }
            var edited = original
            edited[2] = "/* open comment"
            edited[195] = "close comment */"
            var inserted = original; inserted.insert("// inserted", at: 63)
            var removed = original; removed.removeSubrange(62..<67)
            let chunks = SharedTokenChunks()
            for rows in [original, edited, inserted, removed, original] {
                let source = rows.joined(separator: ending) + ending
                let full = try engine.codeToTokens(source, language: "swift", theme: "github-dark",
                    options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: 1000, tokenizeTimeLimit: 0))
                let shared = try chunks.highlight(source, engine: engine, language: "swift", theme: "github-dark", limit: 1000)
                #expect(shared.tokens == full.tokens)
                #expect(shared.fg == full.fg && shared.bg == full.bg)
                let actual = try #require(shared.grammarState as? ShikiGrammarState)
                let expected = try #require(full.grammarState as? ShikiGrammarState)
                #expect(actual.isEquivalent(to: expected))
            }
        }
    }
}

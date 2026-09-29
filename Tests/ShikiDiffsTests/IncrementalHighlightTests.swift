import Foundation
import Shiki
import Testing
@testable import ShikiDiffs

@Suite struct IncrementalHighlightTests {
    @Test func editsMatchFullHighlightAndConverge() async throws {
        let highlighter = DiffHighlighter(), session = UUID()
        let old = (0..<2_000).map { "let value\($0) = \($0)\n" }
        var current = old
        let first = try parseDiffFromFile(.init(name: "f.swift", contents: old.joined()), .init(name: "f.swift", contents: current.joined()))
        _ = try await highlighter.prepareForEditing(first, session: session)
        var states: [[String]] = []
        current[500] = "let value500 = \"changed 😀\"\n"; states.append(current)
        current.insert("// inserted\n", at: 700); states.append(current)
        current.removeSubrange(800..<806); states.append(current)
        current[30] = "/* comment opens\n"; states.append(current)
        current[1300] = "comment closes */\n"; states.append(current)
        current[30] = "let value30 = 30\n"; states.append(current)
        states.append(old)
        for (index, lines) in states.enumerated() {
            let diff = try parseDiffFromFile(.init(name: "f.swift", contents: old.joined()), .init(name: "f.swift", contents: lines.joined()))
            let incremental = try await highlighter.prepareForEditing(diff, session: session)
            let stats = await highlighter.editorHighlightStatistics
            let full = try await highlighter.prepare(diff)
            #expect(incremental.oldTokens == full.oldTokens, "Old tokens at edit \(index)")
            #expect(incremental.newTokens == full.newTokens, "New tokens at edit \(index)")
            #expect(incremental.foreground == full.foreground); #expect(incremental.background == full.background)
            if index < 3 { #expect(stats.retokenizedLines <= 128); #expect(stats.reusedLines > 3_800) }
        }
        await highlighter.releaseEditingSession(session)
        #expect(await highlighter.editorHighlightStatistics.cachedDocuments == 0)
    }
    @Test func exactStateComparisonIncludesDynamicHeredocEnd() throws {
        let engine = try ShikiHighlighter()
        let a = try engine.codeToTokens("cat <<AAA", language: "shellscript", theme: "github-dark").grammarState as? ShikiGrammarState
        let b = try engine.codeToTokens("cat <<BBB", language: "shellscript", theme: "github-dark").grammarState as? ShikiGrammarState
        let a2 = try engine.codeToTokens("cat <<AAA", language: "shellscript", theme: "github-dark").grammarState as? ShikiGrammarState
        #expect(try #require(a).isEquivalent(to: #require(a2)))
        #expect(try !#require(a).isEquivalent(to: #require(b)))
        let composed = try engine.codeToTokens("cat <<'é'", language: "shellscript", theme: "github-dark").grammarState as? ShikiGrammarState
        let decomposed = try engine.codeToTokens("cat <<'e\u{301}'", language: "shellscript", theme: "github-dark").grammarState as? ShikiGrammarState
        #expect(try !#require(composed).isEquivalent(to: #require(decomposed)))
    }
    @Test func lineEndingsLimitsThemeChangesAndCacheBound() async throws {
        let highlighter = DiffHighlighter(), session = UUID()
        for theme in ["pierre-dark", "pierre-light"] {
            for source in ["", "a\n", "a\r\n", "é\né\n😀\n", "/*\n\nbody\n*/\nend", "cat <<AAA\nbody\nAAA\nend\n", String(repeating: "x", count: 1001) + "\nnext\n"] {
                let diff = try parseDiffFromFile(.init(name: "f.sh", contents: ""), .init(name: "f.sh", contents: source))
                var options = DiffRenderOptions(); options.theme = theme
                let incremental = try await highlighter.prepareForEditing(diff, session: session, options: options)
                let full = try await highlighter.prepare(diff, options: options)
                #expect(incremental.newTokens == full.newTokens, "Theme \(theme), source \(source.prefix(30))")
            }
        }
        let diff = try parseDiffFromFile(.init(name: "f.txt", contents: "a"), .init(name: "f.txt", contents: "b"))
        for _ in 0..<12 { _ = try await highlighter.prepareForEditing(diff, session: UUID()) }
        #expect(await highlighter.editorHighlightStatistics.cachedDocuments <= 8)
        await highlighter.clearCache()
        #expect(await highlighter.editorHighlightStatistics.cachedDocuments == 0)
    }
    @Test func dynamicHeredocEditDoesNotReuseSameScopeWrongState() async throws {
        let highlighter = DiffHighlighter(), session = UUID()
        var lines = (0..<180).map { "echo line\($0)\n" }
        lines[20] = "cat <<AAA\n"; lines[120] = "AAA\n"
        let old = lines.joined()
        let initial = try parseDiffFromFile(.init(name: "f.sh", contents: old), .init(name: "f.sh", contents: old))
        _ = try await highlighter.prepareForEditing(initial, session: session)
        lines[20] = "cat <<BBB\n"
        let changed = try parseDiffFromFile(.init(name: "f.sh", contents: old), .init(name: "f.sh", contents: lines.joined()))
        let incremental = try await highlighter.prepareForEditing(changed, session: session)
        #expect(await highlighter.editorHighlightStatistics.retokenizedLines > 128)
        let full = try await highlighter.prepare(changed)
        #expect(incremental.newTokens == full.newTokens)
    }
    @Test func largeFileCheckpointUpdate() async throws {
        let highlighter = DiffHighlighter(), session = UUID()
        var lines = (0..<20_000).map { "let item\($0) = \($0)\n" }
        let old = lines.joined()
        _ = try await highlighter.prepareForEditing(parseDiffFromFile(.init(name: "f.swift", contents: old), .init(name: "f.swift", contents: old)), session: session)
        lines[10_000] = "let edited = \"updated\"\n"
        let diff = try parseDiffFromFile(.init(name: "f.swift", contents: old), .init(name: "f.swift", contents: lines.joined()))
        let clock = ContinuousClock(), start = clock.now
        let incremental = try await highlighter.prepareForEditing(diff, session: session)
        let elapsed = start.duration(to: clock.now), stats = await highlighter.editorHighlightStatistics
        print("Incremental syntax update / 20,000 Swift lines: \(elapsed), tokenized=\(stats.retokenizedLines), reused=\(stats.reusedLines)")
        #expect(stats.retokenizedLines <= 128); #expect(stats.reusedLines > 39_800)
        #expect(elapsed < .seconds(1))
        let full = try await highlighter.prepare(diff)
        #expect(incremental.newTokens == full.newTokens)
    }
}

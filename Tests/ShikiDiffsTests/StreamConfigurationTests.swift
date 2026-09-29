import Foundation
import Shiki
import Testing
@testable import ShikiDiffs

struct StreamConfigurationTests {
    @Test(arguments: ["github-light", "github-dark", "pierre-light", "pierre-dark"])
    func directFileStreamsUseTheSamePaletteAsPreparedFiles(theme: String) async throws {
        let source = "let value = 123\n"
        let file = FileContents(name: "fixture.swift", contents: source)
        var options = DiffRenderOptions(); options.theme = theme
        let expected = try await DiffHighlighter().prepare(oldFile: file, newFile: file, options: options)
        let stream = FileStream(name: file.name, theme: theme)
        let empty = try await stream.append("")
        #expect(empty.palette == expected.palette)
        let partial = try await stream.append("let value = ")
        let complete = try await stream.append("123\n")
        let closed = await stream.close()
        for actual in [partial, complete, closed] {
            #expect(actual.palette == expected.palette)
            #expect(actual.foreground == expected.foreground)
            #expect(actual.background == expected.background)
            #expect(actual.sourceID == empty.sourceID)
        }
        #expect(closed.newTokens.first == expected.newTokens.first)
        let neverAppended = FileStream(name: file.name, theme: theme)
        let emptyClosed = await neverAppended.close()
        #expect(emptyClosed.palette == expected.palette)
        #expect(emptyClosed.foreground == expected.foreground)
        #expect(emptyClosed.background == expected.background)
        #expect(emptyClosed.diff.additionLines.isEmpty)
        #expect(await neverAppended.close().sourceID == emptyClosed.sourceID)
    }

    @Test func optionsReachStreamsAndSurviveCloning() async throws {
        let engine = try ShikiHighlighter()
        let source = "let value = 123"
        let limited = TokenizeWithThemeOptions(tokenizeMaxLineLength: 3, tokenizeTimeLimit: 0)
        let configuration = StreamTokenizerConfiguration(language: "swift", highlighter: engine, options: limited)
        let expected = try engine.codeToTokens(source, language: "swift", theme: "github-dark", options: limited).tokens[0]
        #expect(expected.count == 1 && expected[0].color == "")
        let tokenizer = ShikiStreamTokenizer(configuration: configuration)
        #expect(try await tokenizer.enqueue(source).unstable == expected)
        let clone = await tokenizer.clone()
        await clone.clear()
        #expect(try await clone.enqueue(source).unstable == expected)
        let file = FileStream(name: "f.swift", configuration: configuration)
        #expect(try await file.append(source).newTokens == [expected])
        let chunks = AsyncStream<String> { $0.yield(source); $0.finish() }
        var events: [StreamTokenEvent] = []
        for try await event in CodeToTokenTransformStream(chunks, configuration: configuration) { events.append(event) }
        #expect(events == expected.map(StreamTokenEvent.token))

        let context = TokenizeWithThemeOptions(includeExplanation: .scopeName, tokenizeTimeLimit: 0, grammarContextCode: "```swift\n")
        let worker = DiffHighlighter()
        let contextual = try await worker.streamConfiguration(language: "markdown", theme: "github-dark", options: context)
        #expect(contextual.options == context)
        let contextualStream = ShikiStreamTokenizer(configuration: contextual)
        let reference = try engine.codeToTokens(source, language: "markdown", theme: "github-dark", options: context).tokens[0]
        #expect(try await contextualStream.enqueue(source).unstable == reference)
        #expect(reference.contains { $0.explanation != nil })
    }

    @Test func registeredResourcesReachEveryStreamingSurface() async throws {
        let worker = DiffHighlighter()
        try await worker.registerCustomLanguage("stream-fixture") {
            [try JSONDecoder().decode(LanguageRegistration.self, from: Data(#"{"name":"stream-fixture","scopeName":"source.stream-fixture","patterns":[{"match":"hello","name":"keyword.control"}]}"#.utf8))]
        }
        await worker.registerCustomTheme("stream-theme") {
            try JSONDecoder().decode(ShikiTheme.self, from: Data(##"{"name":"stream-theme","type":"light","colors":{"editor.foreground":"#123456","editor.background":"#ffffff","gitDecoration.modifiedResourceForeground":"#445566"},"tokenColors":[{"scope":"keyword.control","settings":{"foreground":"#ff0000"}}]}"##.utf8))
        }
        async let first = worker.streamConfiguration(language: "stream-fixture", theme: "stream-theme")
        async let second = worker.streamConfiguration(language: "stream-fixture", theme: "stream-theme")
        let (configuration, other) = try await (first, second)
        #expect(configuration.highlighter === other.highlighter)
        #expect(await worker.areLanguagesAttached(["stream-fixture"]))
        #expect(await worker.areThemesAttached(["stream-theme"]))
        #expect(configuration.palette.isLight)
        await worker.disposeHighlighter()
        // Retained configurations own their engine even after the factory resets.
        let tokenizer = ShikiStreamTokenizer(configuration: configuration)
        let update = try await tokenizer.enqueue("hello world\n")
        #expect(update.stable.contains { $0.content == "hello" && $0.color?.lowercased() == "#ff0000" })
        #expect(await tokenizer.foreground == "#123456")
        let clone = await tokenizer.clone()
        #expect(try await clone.enqueue("hello").unstable.first?.color?.lowercased() == "#ff0000")
        let file = FileStream(name: "custom.txt", configuration: configuration)
        let document = try await file.append("hello world\n")
        #expect(document.foreground == "#123456" && document.background == "#ffffff")
        #expect(document.palette.isLight && document.palette.modified == "#445566")
        #expect(document.newTokens.first?.first?.color?.lowercased() == "#ff0000")
        let source = AsyncStream<String> { continuation in continuation.yield("hello"); continuation.finish() }
        var output: [StreamTokenEvent] = []
        for try await event in CodeToTokenTransformStream(source, configuration: configuration) { output.append(event) }
        #expect(output.contains { if case .token(let token) = $0 { return token.content == "hello" && token.color?.lowercased() == "#ff0000" }; return false })
    }
}

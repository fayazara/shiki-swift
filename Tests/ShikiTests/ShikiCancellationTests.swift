import Shiki
import XCTest

final class ShikiCancellationTests: XCTestCase {
    func testLargeGrammarRequestObservesTaskCancellationAndRemainsReusable() async throws {
        let highlighter = try ShikiHighlighter()
        _ = try highlighter.codeToTokens("let warmup = 1", language: "swift")
        let source = String(repeating: "let value = 1\n", count: 50_000)
        let (starts, startContinuation) = AsyncStream<Void>.makeStream()

        let task = Task.detached {
            startContinuation.yield()
            startContinuation.finish()
            return try highlighter.codeToTokens(source, language: "swift")
        }

        var startIterator = starts.makeAsyncIterator()
        _ = await startIterator.next()
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the large tokenization request to be cancelled")
        } catch is CancellationError {
            // Expected. Cancellation is checked only between complete lines.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let recovered = try highlighter.codeToTokens("let value = 1", language: "swift")
        let fresh = try ShikiHighlighter().codeToTokens("let value = 1", language: "swift")
        XCTAssertEqual(recovered, fresh)
    }

    func testUncancelledDetachedRequestPreservesContextTokensAndState() async throws {
        let code = "let value = 1\n```"
        let options = TokenizeWithThemeOptions(grammarContextCode: "```swift\n")
        let expected = try ShikiHighlighter().codeToTokens(
            code,
            language: "markdown",
            options: options
        )

        let actual = try await Task.detached {
            try ShikiHighlighter().codeToTokens(
                code,
                language: "markdown",
                options: options
            )
        }.value

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.grammarState?.scopes, expected.grammarState?.scopes)
    }
}

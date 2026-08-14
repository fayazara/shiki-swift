import Shiki
import XCTest

final class ShikiHighlighterTests: XCTestCase {
    func testSwiftGitHubDarkMatchesShikiOracle() throws {
        let code = """
        import Foundation

        struct Café {
          let emoji = "😀" // hello
        }
        """
        let highlighter = try ShikiHighlighter()
        let highlighted = try highlighter.highlight(
            code,
            language: "swift",
            theme: "github-dark",
            options: .init(includeExplanation: .tokenType)
        )

        XCTAssertEqual(highlighted.result.fg, "#e1e4e8")
        XCTAssertEqual(highlighted.result.bg, "#24292e")
        XCTAssertEqual(highlighted.result.themeName, "github-dark")
        XCTAssertEqual(highlighted.grammarState?.language, "swift")
        XCTAssertEqual(highlighted.grammarState?.themes, ["github-dark"])
        XCTAssertEqual(highlighted.grammarState?.scopes, ["source.swift"])

        assertTokens(
            highlighted.result.tokens,
            equalTo: [
                [
                    .init("import", 0, "#F97583"),
                    .init(" ", 6, "#E1E4E8"),
                    .init("Foundation", 7, "#B392F0"),
                ],
                [],
                [
                    .init("struct", 19, "#F97583"),
                    .init(" ", 25, "#E1E4E8"),
                    .init("Café", 26, "#B392F0"),
                    .init(" {", 30, "#E1E4E8"),
                ],
                [
                    .init("  ", 33, "#E1E4E8"),
                    .init("let", 35, "#F97583"),
                    .init(" emoji ", 38, "#E1E4E8"),
                    .init("=", 45, "#F97583"),
                    .init(" ", 46, "#E1E4E8"),
                    .init("\"😀\"", 47, "#9ECBFF", type: .string),
                    .init(" ", 51, "#E1E4E8"),
                    .init("// hello", 52, "#6A737D", type: .comment),
                ],
                [.init("}", 61, "#E1E4E8")],
            ]
        )
    }

    func testMarkdownLoadsLazySwiftEmbeddingOnFirstCall() throws {
        let highlighter = try ShikiHighlighter()
        let highlighted = try highlighter.codeToTokens(
            "```swift\nlet value = 1\n```",
            language: "markdown",
            theme: "github-dark",
            options: .init(includeExplanation: .scopeName)
        )

        assertTokens(
            highlighted.tokens,
            equalTo: [
                [.init("```swift", 0, "#E1E4E8")],
                [
                    .init("let", 9, "#F97583"),
                    .init(" value ", 12, "#E1E4E8"),
                    .init("=", 19, "#F97583"),
                    .init(" ", 20, "#E1E4E8"),
                    .init("1", 21, "#79B8FF"),
                ],
                [.init("```", 23, "#E1E4E8")],
            ]
        )
        XCTAssertTrue(
            highlighted.tokens[1][0].explanation?[0].scopes.contains {
                $0.scopeName == "meta.embedded.block.swift"
            } == true
        )
    }

    func testGrammarContextAndReturnedStateContinueMarkdownFence() throws {
        let highlighter = try ShikiHighlighter()
        let contextResult = try highlighter.codeToTokens(
            "let value = 1\n```",
            language: "markdown",
            options: .init(grammarContextCode: "```swift\n")
        )

        let opening = try highlighter.codeToTokens("```swift", language: "markdown")
        let grammarState = try XCTUnwrap(opening.grammarState)
        let stateResult = try highlighter.codeToTokens(
            "let value = 1\n```",
            language: "markdown",
            grammarState: grammarState
        )

        XCTAssertEqual(grammarState.lang, "markdown")
        XCTAssertEqual(grammarState.theme, "github-dark")
        XCTAssertEqual(grammarState.themes, ["github-dark"])
        XCTAssertEqual(grammarState.scopes, [
            "markup.fenced_code.block.markdown",
            "markup.fenced_code.block.markdown",
            "text.html.markdown",
        ])
        XCTAssertEqual(contextResult, stateResult)
        XCTAssertEqual(contextResult.tokens[0][0].content, "let")
        XCTAssertEqual(contextResult.tokens[0][0].color, "#F97583")
    }

    func testPlainTextAndMaximumLineLengthMatchShikiBypassRules() throws {
        let highlighter = try ShikiHighlighter()
        let plain = try highlighter.codeToTokens("a\n\n😀", language: "txt")

        XCTAssertEqual(plain.tokens.map { $0.map(\.content) }, [["a"], [""], ["😀"]])
        XCTAssertEqual(plain.tokens.map { $0.map(\.offset) }, [[0], [2], [3]])
        XCTAssertNil(plain.tokens[0][0].color)
        XCTAssertNil(plain.grammarState)

        let emptyLanguage = try highlighter.codeToTokens("a\n\n😀", language: "")
        let textLanguage = try highlighter.codeToTokens("a\n\n😀", language: "text")
        XCTAssertEqual(emptyLanguage, textLanguage)
        XCTAssertEqual(emptyLanguage.tokens.map { $0.map(\.offset) }, [[0], [2], [3]])
        XCTAssertNil(emptyLanguage.grammarState)

        let limited = try highlighter.codeToTokens(
            "let x = 1",
            language: "swift",
            options: .init(tokenizeMaxLineLength: 3)
        )
        XCTAssertEqual(limited.tokens.count, 1)
        XCTAssertEqual(limited.tokens[0].count, 1)
        XCTAssertEqual(limited.tokens[0][0].content, "let x = 1")
        XCTAssertEqual(limited.tokens[0][0].color, "")
        XCTAssertEqual(limited.tokens[0][0].fontStyle, FontStyle.none)
    }

    func testScopeExplanationClipsTextMateSentinelToSourceLine() throws {
        let highlighter = try ShikiHighlighter()
        let result = try highlighter.codeToTokens(
            "unmatchedIdentifier",
            language: "swift",
            options: .init(includeExplanation: .scopeName)
        )

        XCTAssertEqual(result.tokens[0].map(\.content).joined(), "unmatchedIdentifier")
        XCTAssertEqual(
            result.tokens[0].flatMap { $0.explanation ?? [] }.map(\.content).joined(),
            "unmatchedIdentifier"
        )
    }

    func testFullExplanationIncludesMatchingThemeRule() throws {
        let highlighter = try ShikiHighlighter()
        let result = try highlighter.codeToTokens(
            "import",
            language: "swift",
            options: .init(includeExplanation: .full)
        )

        let scopes = try XCTUnwrap(result.tokens[0][0].explanation?.first?.scopes)
        XCTAssertEqual(scopes.map(\.scopeName), [
            "source.swift",
            "meta.import.swift",
            "keyword.control.import.swift",
        ])
        XCTAssertEqual(scopes[0].themeMatches, [])
        XCTAssertEqual(scopes[1].themeMatches, [])
        XCTAssertEqual(scopes[2].themeMatches?.count, 1)
        XCTAssertEqual(scopes[2].themeMatches?[0].scope, .string("keyword"))
        XCTAssertEqual(scopes[2].themeMatches?[0].settings?.foreground, "#f97583")
    }

    func testThemeSwitchingAndColorReplacementMatchShikiOracle() throws {
        let highlighter = try ShikiHighlighter()

        let dark = try highlighter.codeToTokens("let", language: "swift")
        let light = try highlighter.codeToTokens(
            "let",
            language: "swift",
            theme: "github-light"
        )
        let darkAgain = try highlighter.codeToTokens("let", language: "swift")
        let replaced = try highlighter.codeToTokens(
            "let",
            language: "swift",
            options: .init(colorReplacements: ["#f97583": .color("#123456")])
        )

        XCTAssertEqual(dark.tokens[0][0].color, "#F97583")
        XCTAssertEqual(light.tokens[0][0].color, "#D73A49")
        XCTAssertEqual(light.fg, "#24292e")
        XCTAssertEqual(light.bg, "#fff")
        XCTAssertEqual(darkAgain.tokens[0][0].color, "#F97583")
        XCTAssertEqual(replaced.tokens[0][0].color, "#123456")
    }

    func testGrammarStateRejectsDifferentLanguageAndTheme() throws {
        let highlighter = try ShikiHighlighter()
        let state = try XCTUnwrap(
            highlighter.highlight("let x = 1", language: "swift").grammarState
        )

        XCTAssertThrowsError(
            try highlighter.codeToTokens(
                "const x = 1",
                language: "javascript",
                grammarState: state
            )
        ) { error in
            XCTAssertEqual(
                error as? ShikiHighlighterError,
                .grammarStateLanguageMismatch(state: "swift", requested: "javascript")
            )
        }

        XCTAssertThrowsError(
            try highlighter.codeToTokens(
                "let y = 2",
                language: "swift",
                theme: "github-light",
                grammarState: state
            )
        ) { error in
            XCTAssertEqual(
                error as? ShikiHighlighterError,
                .grammarStateThemeMismatch(
                    stateThemes: ["github-dark"],
                    requested: "github-light"
                )
            )
        }
    }

    func testDecodedGrammarStateSnapshotCannotResumeTokenization() throws {
        let highlighter = try ShikiHighlighter()
        let opening = try highlighter.codeToTokens(
            "```swift",
            language: "markdown",
            theme: "github-dark"
        )
        let encoded = try JSONEncoder().encode(opening)
        let decoded = try JSONDecoder().decode(TokensResult.self, from: encoded)
        let snapshot = try XCTUnwrap(decoded.grammarState)

        XCTAssertEqual(snapshot.lang, "markdown")
        XCTAssertEqual(snapshot.theme, "github-dark")
        XCTAssertEqual(snapshot.scopes, [
            "markup.fenced_code.block.markdown",
            "markup.fenced_code.block.markdown",
            "text.html.markdown",
        ])
        XCTAssertThrowsError(
            try highlighter.codeToTokens(
                "let value = 1\n```",
                language: "markdown",
                theme: "github-dark",
                grammarState: snapshot
            )
        ) { error in
            XCTAssertEqual(error as? ShikiHighlighterError, .invalidGrammarState)
        }
    }

    func testMultiThemeGrammarStateDeduplicatesMixedRealAndNoneThemes() throws {
        let highlighter = try ShikiHighlighter()
        let highlighted = try highlighter.highlightWithThemes(
            "let value = 1",
            language: "swift",
            themes: [
                .init(colorName: "dark-first", themeName: "github-dark"),
                .init(colorName: "none-first", themeName: "none"),
                .init(colorName: "dark-last", themeName: "github-dark"),
                .init(colorName: "none-last", themeName: "none"),
            ]
        )
        let state = try XCTUnwrap(highlighted.grammarState)

        XCTAssertEqual(state.themes, ["github-dark", "none"])
        XCTAssertEqual(state.getScopes(theme: "github-dark"), ["source.swift"])
        XCTAssertEqual(state.getScopes(theme: "none"), [])
    }

    private struct ExpectedToken {
        let content: String
        let offset: Int
        let color: String
        let type: StandardTokenType

        init(
            _ content: String,
            _ offset: Int,
            _ color: String,
            type: StandardTokenType = .other
        ) {
            self.content = content
            self.offset = offset
            self.color = color
            self.type = type
        }
    }

    private func assertTokens(
        _ actual: [[ThemedToken]],
        equalTo expected: [[ExpectedToken]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (lineIndex, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(
                pair.0.count,
                pair.1.count,
                "line \(lineIndex)",
                file: file,
                line: line
            )
            for (actualToken, expectedToken) in zip(pair.0, pair.1) {
                XCTAssertEqual(actualToken.content, expectedToken.content, file: file, line: line)
                XCTAssertEqual(actualToken.offset, expectedToken.offset, file: file, line: line)
                XCTAssertEqual(actualToken.color, expectedToken.color, file: file, line: line)
                XCTAssertEqual(actualToken.fontStyle, FontStyle.none, file: file, line: line)
                XCTAssertEqual(actualToken.type ?? .other, expectedToken.type, file: file, line: line)
            }
        }
    }
}

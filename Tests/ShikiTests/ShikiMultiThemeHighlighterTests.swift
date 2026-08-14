import Foundation
import Shiki
import XCTest

final class ShikiMultiThemeHighlighterTests: XCTestCase {
    private let oracleThemes: [ShikiThemeVariant] = [
        .init(colorName: "light", themeName: "vitesse-light"),
        .init(colorName: "dark", themeName: "nord"),
    ]

    func testTokenTypeRuntimeShapeMatchesShiki443Oracle() throws {
        let highlighter = try ShikiHighlighter()
        let tokens = try highlighter.codeToTokensWithThemes(
            "const s = \"hi\" // yo",
            language: "javascript",
            themes: oracleThemes,
            options: .init(includeExplanation: .tokenType)
        )

        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].map(\.content), [
            "const", " ", "s", " ", "=", " ", "\"", "hi", "\"", " ", "// yo",
        ])
        XCTAssertEqual(tokens[0].map(\.offset), [0, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15])

        let string = try XCTUnwrap(tokens[0].first(where: { $0.content == "hi" }))
        XCTAssertNil(string.type)
        XCTAssertNil(string.explanation)
        XCTAssertEqual(string.variants["light"]?.color, "#B56959")
        XCTAssertEqual(string.variants["dark"]?.color, "#A3BE8C")
        XCTAssertEqual(string.variants["light"]?.fontStyle, FontStyle.none)
        XCTAssertEqual(string.variants["dark"]?.fontStyle, FontStyle.none)
        XCTAssertEqual(string.variants["light"]?.type, .string)
        XCTAssertEqual(string.variants["dark"]?.type, .string)

        let comment = try XCTUnwrap(tokens[0].last)
        XCTAssertEqual(comment.content, "// yo")
        XCTAssertEqual(comment.variants["light"]?.color, "#A0ADA0")
        XCTAssertEqual(comment.variants["dark"]?.color, "#616E88")
        XCTAssertEqual(comment.variants["light"]?.type, .comment)
        XCTAssertEqual(comment.variants["dark"]?.type, .comment)

        let encoded = try JSONEncoder().encode(string)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(object["type"], "Merged tokens have no top-level type in Shiki 4.4.3.")
        XCTAssertNil(object["explanation"])
        let variants = try XCTUnwrap(object["variants"] as? [String: Any])
        let light = try XCTUnwrap(variants["light"] as? [String: Any])
        let dark = try XCTUnwrap(variants["dark"] as? [String: Any])
        XCTAssertEqual((light["type"] as? NSNumber)?.uint32Value, StandardTokenType.string.rawValue)
        XCTAssertEqual((dark["type"] as? NSNumber)?.uint32Value, StandardTokenType.string.rawValue)
    }

    func testFullExplanationComesOnlyFromFirstThemeAndVariantTypesAreAbsent() throws {
        let highlighter = try ShikiHighlighter()
        let options = TokenizeWithThemeOptions(includeExplanation: .full)
        let merged = try highlighter.codeToTokensWithThemes(
            "const",
            language: "javascript",
            themes: oracleThemes,
            options: options
        )
        let firstTheme = try highlighter.codeToTokens(
            "const",
            language: "javascript",
            theme: "vitesse-light",
            options: options
        )

        let token = try XCTUnwrap(merged.first?.first)
        XCTAssertEqual(token.explanation, firstTheme.tokens[0][0].explanation)
        XCTAssertTrue(
            token.explanation?.first?.scopes.contains {
                $0.scopeName == "storage.type.js"
            } == true
        )
        XCTAssertNil(token.type)
        XCTAssertNil(token.variants["light"]?.type)
        XCTAssertNil(token.variants["dark"]?.type)

        let encoded = try JSONEncoder().encode(token)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(object["explanation"])
        XCTAssertNil(object["type"])
        let variants = try XCTUnwrap(object["variants"] as? [String: Any])
        for name in ["light", "dark"] {
            let styles = try XCTUnwrap(variants[name] as? [String: Any])
            XCTAssertNil(styles["type"])
        }
    }

    func testAlignmentAndOffsetsUseExactUTF16Units() throws {
        let code = "console.log(\"🙂\")"
        let highlighter = try ShikiHighlighter()
        let tokens = try highlighter.codeToTokensWithThemes(
            code,
            language: "javascript",
            themes: oracleThemes
        )

        let line = try XCTUnwrap(tokens.first)
        XCTAssertEqual(line.map(\.content).joined(), code)
        var expectedOffset = 0
        for token in line {
            XCTAssertEqual(token.offset, expectedOffset)
            XCTAssertEqual(Set(token.variants.keys), Set(["light", "dark"]))
            expectedOffset += token.content.utf16.count
        }
        XCTAssertEqual(expectedOffset, code.utf16.count)

        let emojiIndex = try XCTUnwrap(line.firstIndex { $0.content.contains("🙂") })
        let emojiToken = line[emojiIndex]
        XCTAssertEqual(emojiToken.offset, code.utf16.distance(
            from: code.utf16.startIndex,
            to: code.utf16.firstIndex(of: Array("🙂".utf16)[0])!
        ))
        if emojiToken.content == "🙂" {
            XCTAssertEqual(emojiToken.content.utf16.count, 2)
        }
    }

    func testContinuationKeepsOneStackPerUnderlyingTheme() throws {
        let highlighter = try ShikiHighlighter()
        let options = TokenizeWithThemeOptions(includeExplanation: .tokenType)
        let opening = try highlighter.highlightWithThemes(
            "/* open",
            language: "javascript",
            themes: oracleThemes,
            options: options
        )
        let state = try XCTUnwrap(opening.grammarState)

        XCTAssertEqual(state.language, "javascript")
        XCTAssertEqual(state.themes, ["vitesse-light", "nord"])
        XCTAssertEqual(state.theme, "vitesse-light")

        let continued = try highlighter.highlightWithThemes(
            "close */",
            language: "javascript",
            themes: oracleThemes,
            options: options,
            grammarState: state
        )
        let token = try XCTUnwrap(
            continued.tokens[0].first(where: { $0.content.contains("close") })
        )
        XCTAssertEqual(token.variants["light"]?.color, "#A0ADA0")
        XCTAssertEqual(token.variants["dark"]?.color, "#616E88")
        XCTAssertEqual(token.variants["light"]?.type, .comment)
        XCTAssertEqual(token.variants["dark"]?.type, .comment)
        XCTAssertEqual(continued.grammarState?.themes, ["vitesse-light", "nord"])

        let oneShot = try highlighter.codeToTokensWithThemes(
            "/* open\nclose */",
            language: "javascript",
            themes: oracleThemes,
            options: options
        )
        XCTAssertEqual(
            continued.tokens[0].map { ComparableToken($0) },
            oneShot[1].map { ComparableToken($0) }
        )
    }

    func testVariantValidationAndRepeatedUnderlyingTheme() throws {
        let highlighter = try ShikiHighlighter()

        XCTAssertThrowsError(
            try highlighter.codeToTokensWithThemes(
                "let",
                language: "swift",
                themes: []
            )
        ) { error in
            XCTAssertEqual(error as? ShikiHighlighterError, .emptyThemeVariants)
        }
        XCTAssertThrowsError(
            try highlighter.codeToTokensWithThemes(
                "let",
                language: "swift",
                themes: [.init(colorName: "", themeName: "nord")]
            )
        ) { error in
            XCTAssertEqual(error as? ShikiHighlighterError, .emptyThemeColorName(index: 0))
        }
        XCTAssertThrowsError(
            try highlighter.codeToTokensWithThemes(
                "let",
                language: "swift",
                themes: [.init(colorName: "dark", themeName: "")]
            )
        ) { error in
            XCTAssertEqual(error as? ShikiHighlighterError, .emptyThemeName(index: 0))
        }
        XCTAssertThrowsError(
            try highlighter.codeToTokensWithThemes(
                "let",
                language: "swift",
                themes: [
                    .init(colorName: "dark", themeName: "nord"),
                    .init(colorName: "dark", themeName: "github-dark"),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? ShikiHighlighterError,
                .duplicateThemeColorName("dark")
            )
        }

        let repeated = try highlighter.highlightWithThemes(
            "let",
            language: "swift",
            themes: [
                .init(colorName: "one", themeName: "nord"),
                .init(colorName: "two", themeName: "nord"),
            ]
        )
        XCTAssertEqual(Set(repeated.tokens[0][0].variants.keys), Set(["one", "two"]))
        XCTAssertEqual(repeated.grammarState?.themes, ["nord"])

        let realThenNone = try highlighter.highlightWithThemes(
            "/* open\n\n",
            language: "javascript",
            themes: [
                .init(colorName: "styled", themeName: "vitesse-light"),
                .init(colorName: "plain", themeName: "none"),
            ]
        )
        let mixedState = try XCTUnwrap(realThenNone.grammarState)
        XCTAssertEqual(mixedState.themes, ["vitesse-light", "none"])
        XCTAssertTrue(mixedState.getScopes(theme: "vitesse-light").contains("source.js"))
        XCTAssertEqual(mixedState.getScopes(theme: "none"), [])
        XCTAssertEqual(realThenNone.tokens[1], [])
        XCTAssertEqual(realThenNone.tokens[2], [])

        let initial = try ShikiGrammarState.initial(
            language: "javascript",
            themes: ["vitesse-light", "nord", "vitesse-light"]
        )
        XCTAssertEqual(initial.themes, ["vitesse-light", "nord"])
        XCTAssertEqual(initial.getScopes(theme: "nord"), [])
        XCTAssertThrowsError(
            try ShikiGrammarState.initial(language: "javascript", themes: [])
        ) { error in
            XCTAssertEqual(error as? ShikiHighlighterError, .emptyThemeVariants)
        }
        XCTAssertThrowsError(
            try ShikiGrammarState.initial(language: "javascript", themes: [""])
        ) { error in
            XCTAssertEqual(
                error as? ShikiHighlighterError,
                .emptyThemeName(index: 0)
            )
        }
    }

    private struct ComparableToken: Equatable {
        let content: String
        let type: StandardTokenType?
        let explanation: [ThemedTokenExplanation]?
        let variants: [String: TokenStyles]

        init(_ token: ThemedTokenWithVariants) {
            content = token.content
            type = token.type
            explanation = token.explanation
            variants = token.variants
        }
    }
}

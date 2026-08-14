import XCTest
@testable import ShikiCore

final class ShikiTokensTests: XCTestCase {
    func testThemedTokenCodableRoundTripPreservesPublicShape() throws {
        let match = ShikiThemeRule(
            name: "Regex",
            scope: .string("string.regexp"),
            settings: .init(foreground: "#ff0000")
        )
        let token = ThemedToken(
            content: "/x/",
            offset: 2,
            type: .regex,
            explanation: [
                .init(
                    content: "/x/",
                    scopes: [
                        .init(scopeName: "source.js"),
                        .init(scopeName: "string.regexp.js", themeMatches: [match]),
                    ]
                ),
            ],
            color: "#ff0000",
            bgColor: "#101010",
            fontStyle: [.italic, .bold],
            htmlStyle: ["text-decoration": "none"],
            htmlAttrs: ["data-scope": "regex"]
        )

        let encoded = try JSONEncoder().encode(token)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["offset"] as? Int, 2)
        XCTAssertEqual(object["type"] as? Int, 3)
        XCTAssertEqual(object["fontStyle"] as? Int, 3)
        XCTAssertEqual(try JSONDecoder().decode(ThemedToken.self, from: encoded), token)
        XCTAssertEqual(ThemedToken(base: token.base, styles: token.styles), token)
    }

    func testTokenOffsetCanRepresentJavaScriptIndexAfterEmoji() {
        let code = "😀let"
        let token = ThemedToken(content: "let", offset: "😀".utf16.count)

        XCTAssertEqual(token.offset, 2)
        XCTAssertEqual(Array(code.utf16)[token.offset...].count, 3)
    }

    func testExplanationModeDecodesBooleanAndNamedForms() throws {
        XCTAssertEqual(try decodeMode("false"), .none)
        XCTAssertEqual(try decodeMode("true"), .full)
        XCTAssertEqual(try decodeMode(#""scopeName""#), .scopeName)
        XCTAssertEqual(try decodeMode(#""tokenType""#), .tokenType)
        XCTAssertThrowsError(try decodeMode(#""full""#))
    }

    func testTokenizationOptionsDecodeAndExposeShikiDefaults() throws {
        let omitted = TokenizeWithThemeOptions()
        XCTAssertEqual(omitted.resolvedExplanationMode, .none)
        XCTAssertEqual(omitted.resolvedMaxLineLength, 0)
        XCTAssertEqual(omitted.resolvedTimeLimit, 500)

        let data = Data(
            #"""
            {
              "includeExplanation": "scopeName",
              "colorReplacements": {
                "#111111": "#222222",
                "night": { "#333333": "var(--token)" }
              },
              "tokenizeMaxLineLength": 20000,
              "tokenizeTimeLimit": 125,
              "grammarContextCode": "function wrapper() {"
            }
            """#
                .utf8
        )

        let options = try JSONDecoder().decode(TokenizeWithThemeOptions.self, from: data)
        XCTAssertEqual(options.includeExplanation, .scopeName)
        XCTAssertEqual(options.colorReplacements?["#111111"], .color("#222222"))
        XCTAssertEqual(options.colorReplacements?["night"], .theme(["#333333": "var(--token)"]))
        XCTAssertEqual(options.resolvedMaxLineLength, 20_000)
        XCTAssertEqual(options.resolvedTimeLimit, 125)
        XCTAssertEqual(options.grammarContextCode, "function wrapper() {")
    }

    func testTokensResultSupportsStringAndDisabledRootStyles() throws {
        let result = TokensResult(
            tokens: [[.init(content: "let", offset: 0, color: "#ffffff")]],
            fg: "#ffffff",
            bg: "#000000",
            themeName: "night",
            rootStyle: .style("padding:1rem")
        )
        let encoded = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(TokensResult.self, from: encoded), result)

        let disabled = try JSONDecoder().decode(
            TokensResult.self,
            from: Data(#"{"tokens":[],"rootStyle":false}"#.utf8)
        )
        XCTAssertEqual(disabled.rootStyle, .disabled)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TokensResult.self,
                from: Data(#"{"tokens":[],"rootStyle":true}"#.utf8)
            )
        )
    }

    func testTokensResultEncodesExactGrammarStateSnapshotAndDecodesMetadata() throws {
        let state = TestGrammarState(
            lang: "typescript",
            theme: "vitesse-dark",
            themes: ["vitesse-dark", "github-light"],
            scopes: ["meta.type.annotation.ts", "source.ts"]
        )
        let result = TokensResult(
            tokens: [[.init(content: "let", offset: 0, color: "#ffffff")]],
            fg: "#ffffff",
            bg: "#000000",
            themeName: "vitesse-dark",
            grammarState: state
        )

        let encoded = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let snapshot = try XCTUnwrap(object["grammarState"] as? [String: Any])

        XCTAssertEqual(
            Set(snapshot.keys),
            Set(["lang", "theme", "themes", "scopes"])
        )
        XCTAssertEqual(snapshot["lang"] as? String, "typescript")
        XCTAssertEqual(snapshot["theme"] as? String, "vitesse-dark")
        XCTAssertEqual(
            snapshot["themes"] as? [String],
            ["vitesse-dark", "github-light"]
        )
        XCTAssertEqual(
            snapshot["scopes"] as? [String],
            ["meta.type.annotation.ts", "source.ts"]
        )

        let decoded = try JSONDecoder().decode(TokensResult.self, from: encoded)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.grammarState?.lang, "typescript")
        XCTAssertEqual(decoded.grammarState?.theme, "vitesse-dark")
        XCTAssertEqual(
            decoded.grammarState?.getScopes(),
            ["meta.type.annotation.ts", "source.ts"]
        )
        XCTAssertEqual(
            decoded.grammarState?.getScopes(theme: "github-light"),
            []
        )
    }

    func testTokensResultOmitsNilGrammarState() throws {
        let encoded = try JSONEncoder().encode(TokensResult(tokens: []))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertNil(object["grammarState"])
        XCTAssertNil(
            try JSONDecoder().decode(TokensResult.self, from: encoded).grammarState
        )
    }

    private func decodeMode(_ json: String) throws -> TokenExplanationMode {
        try JSONDecoder().decode(TokenExplanationMode.self, from: Data(json.utf8))
    }

    private final class TestGrammarState: GrammarState {
        let lang: String
        let theme: String
        let themes: [String]
        let scopes: [String]

        init(
            lang: String,
            theme: String,
            themes: [String],
            scopes: [String]
        ) {
            self.lang = lang
            self.theme = theme
            self.themes = themes
            self.scopes = scopes
        }

        func getScopes(theme requestedTheme: String?) -> [String] {
            guard requestedTheme == nil || requestedTheme == theme else {
                return []
            }
            return scopes
        }
    }
}

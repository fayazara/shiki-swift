import Foundation
import ShikiCore
import XCTest
@testable import Shiki

/// Regression coverage for issues found in review.
final class ShikiRegressionTests: XCTestCase {
    /// Token offsets are document-relative, so compare text and style only.
    private func styled(_ line: [ThemedToken]?) -> [String] {
        (line ?? []).map { "\($0.content)|\($0.color ?? "")|\($0.fontStyle?.rawValue ?? -1)" }
    }

    // Previously trapped with "No compiled TextMate rule for id …" because
    // loading a language rebuilt the registry and orphaned existing states.
    func testGrammarStateSurvivesLoadingAnotherLanguage() throws {
        let highlighter = try ShikiHighlighter()
        let opened = try highlighter.highlight("let a = 1\n/* open", language: "javascript")
        let state = try XCTUnwrap(opened.grammarState)

        _ = try highlighter.codeToTokens("def f():\n    return 1", language: "python")
        _ = try highlighter.codeToTokens("# Title\n\n```rust\nfn main() {}\n```", language: "markdown")

        let resumed = try highlighter.codeToTokens(
            "still comment */ let b = 2", language: "javascript", grammarState: state
        )
        let reference = try ShikiHighlighter().codeToTokens(
            "let a = 1\n/* open\nstill comment */ let b = 2", language: "javascript"
        )
        XCTAssertEqual(styled(resumed.tokens.first), styled(reference.tokens.last))
    }

    func testGrammarStateFromAnotherHighlighterIsRejected() throws {
        let first = try ShikiHighlighter()
        let second = try ShikiHighlighter()
        let state = try XCTUnwrap(first.highlight("/* open", language: "javascript").grammarState)
        XCTAssertThrowsError(
            try second.codeToTokens("x */", language: "javascript", grammarState: state)
        ) { error in
            guard case ShikiHighlighterError.invalidGrammarState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testGetLastGrammarStateResumesTokenization() throws {
        let highlighter = try ShikiHighlighter()
        let state = try highlighter.getLastGrammarState("const s = `open", language: "ts")
        // Like Shiki, getScopes reports `name` scopes (the template rule only
        // sets `contentName`), innermost first.
        XCTAssertEqual(state.getScopes().last, "source.ts")
        XCTAssertGreaterThan(state.getScopes().count, 1)
        let resumed = try highlighter.codeToTokens("close` + 1", language: "ts", grammarState: state)
        let reference = try highlighter.codeToTokens("const s = `open\nclose` + 1", language: "ts")
        XCTAssertEqual(styled(resumed.tokens.first), styled(reference.tokens.last))

        XCTAssertThrowsError(try highlighter.getLastGrammarState("plain", language: "text")) { error in
            guard case ShikiHighlighterError.grammarStateUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInjectionKeyOrderFollowsSourceJSON() throws {
        let json = Data("""
        {"scopeName":"source.t","patterns":[],"injections":{
          "z.selector":{"patterns":[]},"a.selector":{"patterns":[]},"m.selector":{"patterns":[]}
        }}
        """.utf8)
        for _ in 0..<5 {
            let grammar = try RawGrammar.decodePreservingKeyOrder(from: json)
            XCTAssertEqual(grammar.orderedInjections.map(\.selector),
                           ["z.selector", "a.selector", "m.selector"])
        }
    }

    func testRepeatedHighlightingIsDeterministic() throws {
        let code = "<template><div :a=\"x + 1\">{{ y }}</div></template>\n<script setup lang=\"ts\">const y = 1</script>"
        let expected = try ShikiHighlighter().codeToTokens(code, language: "vue")
        for _ in 0..<3 {
            XCTAssertEqual(try ShikiHighlighter().codeToTokens(code, language: "vue"), expected)
        }
    }

    func testAnsiEscapesBecomeColoredTokens() throws {
        let highlighter = try ShikiHighlighter()
        let result = try highlighter.codeToTokens("\u{1B}[31mred\u{1B}[0m plain\n\u{1B}[1mbold", language: "ansi")
        XCTAssertEqual(result.tokens.count, 2)
        let line = result.tokens[0]
        XCTAssertEqual(line.map(\.content).joined(), "red plain")
        let red = try XCTUnwrap(line.first { $0.content == "red" })
        let plain = try XCTUnwrap(line.first { $0.content.contains("plain") })
        XCTAssertNotNil(red.color)
        XCTAssertNotEqual(red.color, plain.color)
        let bold = try XCTUnwrap(result.tokens[1].first)
        XCTAssertEqual(bold.content, "bold")
        XCTAssertTrue(bold.fontStyle?.contains(.bold) == true)
    }

    func testThemeTypeAcceptsUnknownValues() throws {
        let hc = try JSONDecoder().decode(
            ShikiTheme.self, from: Data(#"{"name":"x","type":"hc","settings":[]}"#.utf8)
        )
        XCTAssertEqual(hc.type?.rawValue, "hc")
        XCTAssertEqual(hc.type?.isLight, false)
        let light = try JSONDecoder().decode(
            ShikiTheme.self, from: Data(#"{"name":"y","type":"light","settings":[]}"#.utf8)
        )
        XCTAssertEqual(light.type, .light)
        XCTAssertEqual(light.type?.isLight, true)
    }

    func testMultiThemeCodeToTokensFlattensVariants() throws {
        let highlighter = try ShikiHighlighter()
        let themes = [
            ShikiThemeVariant(colorName: "light", themeName: "github-light"),
            ShikiThemeVariant(colorName: "dark", themeName: "github-dark"),
        ]
        let result = try highlighter.codeToTokens("let x = 1", language: "swift", themes: themes)
        let keyword = try XCTUnwrap(result.tokens.first?.first { $0.content == "let" })
        let style = try XCTUnwrap(keyword.htmlStyle)
        XCTAssertNotNil(style["color"])
        XCTAssertNotNil(style["--shiki-dark"])
        XCTAssertNil(result.rootStyle)

        let disabled = try highlighter.codeToTokens(
            "let x = 1", language: "swift", themes: themes, defaultColor: .disabled
        )
        let disabledStyle = try XCTUnwrap(disabled.tokens.first?.first { $0.content == "let" }?.htmlStyle)
        XCTAssertNil(disabledStyle["color"])
        XCTAssertNotNil(disabledStyle["--shiki-light"])
        XCTAssertNotNil(disabledStyle["--shiki-dark"])
        XCTAssertNotNil(disabled.rootStyle)

        XCTAssertThrowsError(try highlighter.codeToTokens(
            "x", language: "swift", themes: themes, defaultColor: .variant("sepia")
        )) { error in
            guard case ShikiHighlighterError.missingDefaultColorVariant = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLanguageAliases() throws {
        let highlighter = try ShikiHighlighter(languageAliases: ["mine": "js", "chained": "mine"])
        XCTAssertEqual(try highlighter.resolveLanguageAlias("chained"), "js")
        XCTAssertEqual(
            try highlighter.codeToTokens("let a", language: "mine"),
            try highlighter.codeToTokens("let a", language: "javascript")
        )

        let circular = try ShikiHighlighter(languageAliases: ["a": "b", "b": "a"])
        XCTAssertThrowsError(try circular.resolveLanguageAlias("a")) { error in
            guard case ShikiHighlighterError.circularLanguageAlias = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDisposedHighlighterRemainsUsable() throws {
        let highlighter = try ShikiHighlighter()
        let before = try highlighter.codeToTokens("let a = 1", language: "swift")
        highlighter.dispose()
        XCTAssertEqual(try highlighter.codeToTokens("let a = 1", language: "swift"), before)
    }
}

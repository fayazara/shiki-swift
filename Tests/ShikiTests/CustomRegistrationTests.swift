import Shiki
import XCTest

final class CustomRegistrationTests: XCTestCase {
    func testRegistersRawAndResolvedThemesLanguageAliasesAndLateInjection() throws {
        let highlighter = try ShikiHighlighter()
        let rawTheme = makeRawTheme(name: "runtime-dark")
        try highlighter.loadThemes([rawTheme])

        let base = LanguageRegistration(
            name: "spark",
            grammar: RawGrammar(
                scopeName: "source.spark",
                patterns: [
                    RawRule(name: "keyword.spark", match: #"\bfoo\b"#),
                ]
            ),
            aliases: ["sp"]
        )
        try highlighter.registerLanguage(base)

        let beforeInjection = try highlighter.codeToTokens(
            "foo bar",
            language: "sp",
            theme: "runtime-dark"
        )
        XCTAssertEqual(beforeInjection.tokens[0].map(\.content), ["foo", " bar"])
        XCTAssertEqual(beforeInjection.tokens[0].map(\.color), ["#FF3366", "#CCCCCC"])

        let injection = LanguageRegistration(
            name: "spark-injection",
            grammar: RawGrammar(
                scopeName: "injection.spark",
                patterns: [
                    RawRule(name: "constant.injected.spark", match: #"\bbar\b"#),
                ],
                injectionSelector: "L:source.spark"
            ),
            injectTo: ["source.spark"]
        )
        try highlighter.loadLanguages([injection])

        let afterInjection = try highlighter.codeToTokens(
            "foo bar",
            language: "spark",
            theme: "runtime-dark"
        )
        XCTAssertEqual(afterInjection.tokens[0].map(\.content), ["foo", " ", "bar"])
        XCTAssertEqual(
            afterInjection.tokens[0].map(\.color),
            ["#FF3366", "#CCCCCC", "#33AAFF"]
        )
        XCTAssertTrue(highlighter.getLoadedLanguages().contains("spark"))
        XCTAssertTrue(highlighter.loadedLanguageNames.contains("sp"))
        XCTAssertTrue(highlighter.getLoadedLanguages().contains("spark-injection"))
        XCTAssertTrue(highlighter.getLoadedThemes().contains("runtime-dark"))

        let resolved = makeRawTheme(name: "runtime-light").normalized()
        try highlighter.registerThemes([resolved])
        XCTAssertTrue(highlighter.loadedThemeNames.contains("runtime-light"))
        XCTAssertEqual(
            try highlighter.codeToTokens(
                "foo",
                language: "sp",
                theme: "runtime-light"
            ).tokens[0][0].color,
            "#FF3366"
        )
    }

    func testCustomBatchLoadsCustomEmbeddedGrammarDeclaredAfterParent() throws {
        let highlighter = try ShikiHighlighter()
        try highlighter.loadTheme(makeRawTheme(name: "runtime-dark"))

        let parent = LanguageRegistration(
            name: "parent-runtime",
            grammar: RawGrammar(
                scopeName: "source.parent-runtime",
                patterns: [
                    RawRule(
                        name: "meta.embedded.child-runtime",
                        begin: #"\["#,
                        end: #"\]"#,
                        patterns: [RawRule(include: "source.child-runtime")]
                    ),
                ]
            ),
            embeddedLangs: ["child-runtime"]
        )
        let child = LanguageRegistration(
            name: "child-runtime",
            grammar: RawGrammar(
                scopeName: "source.child-runtime",
                patterns: [
                    RawRule(name: "keyword.child-runtime", match: "inside"),
                ]
            ),
            aliases: ["child-alias"]
        )

        try highlighter.registerLanguages([parent, child])
        let result = try highlighter.codeToTokens(
            "[inside]",
            language: "parent-runtime",
            theme: "runtime-dark"
        )

        XCTAssertEqual(result.tokens[0].map(\.content), ["[", "inside", "]"])
        XCTAssertEqual(result.tokens[0][1].color, "#FF3366")
        XCTAssertTrue(highlighter.getLoadedLanguages().contains("child-alias"))
    }

    func testCustomLanguageAutomaticallyLoadsBundledEagerDependency() throws {
        let highlighter = try ShikiHighlighter()
        let wrapper = LanguageRegistration(
            name: "swift-wrapper",
            grammar: RawGrammar(
                scopeName: "source.swift-wrapper",
                patterns: [RawRule(include: "source.swift")]
            ),
            embeddedLangs: ["swift"]
        )

        try highlighter.loadLanguage(wrapper)
        let result = try highlighter.codeToTokens(
            "let value = 1",
            language: "swift-wrapper",
            theme: "github-dark"
        )

        XCTAssertTrue(highlighter.getLoadedLanguages().contains("swift"))
        XCTAssertEqual(result.tokens[0][0].content, "let")
        XCTAssertEqual(result.tokens[0][0].color, "#F97583")
    }

    func testRejectsUnnamedThemeAndMissingCustomDependency() throws {
        let highlighter = try ShikiHighlighter()
        var unnamed = makeRawTheme(name: "temporary")
        unnamed.name = nil
        XCTAssertThrowsError(try highlighter.loadTheme(unnamed)) { error in
            XCTAssertEqual(error as? ShikiHighlighterError, .unnamedTheme)
        }

        let missing = LanguageRegistration(
            name: "missing-parent",
            grammar: RawGrammar(scopeName: "source.missing-parent"),
            embeddedLangs: ["not-a-real-runtime-language"]
        )
        XCTAssertThrowsError(try highlighter.loadLanguage(missing)) { error in
            XCTAssertEqual(
                error as? ShikiHighlighterError,
                .missingLanguageDependency(
                    language: "missing-parent",
                    dependency: "not-a-real-runtime-language"
                )
            )
        }
        XCTAssertFalse(highlighter.getLoadedLanguages().contains("missing-parent"))
    }

    private func makeRawTheme(name: String) -> ShikiTheme {
        ShikiTheme(
            name: name,
            type: .dark,
            settings: [
                ShikiThemeRule(
                    settings: ShikiThemeTokenSettings(
                        foreground: "#CCCCCC",
                        background: "#111111"
                    )
                ),
                ShikiThemeRule(
                    scope: .string("keyword"),
                    settings: ShikiThemeTokenSettings(foreground: "#FF3366")
                ),
                ShikiThemeRule(
                    scope: .string("constant.injected.spark"),
                    settings: ShikiThemeTokenSettings(foreground: "#33AAFF")
                ),
            ],
            foreground: "#CCCCCC",
            background: "#111111"
        )
    }
}

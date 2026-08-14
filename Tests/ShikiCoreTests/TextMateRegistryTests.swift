import XCTest
@testable import ShikiCore

final class TextMateRegistryTests: XCTestCase {
    func testStoresRawGrammarsInjectionsAndCachesCompiledGrammar() throws {
        let theme = try ShikiResolvedTheme(
            name: "test",
            type: .dark,
            settings: [
                .init(settings: .init(foreground: "#ffffff", background: "#000000")),
            ],
            foreground: "#ffffff",
            background: "#000000"
        ).compile()
        let registry = TextMateRegistry(theme: theme)
        let grammar = RawGrammar(
            scopeName: "source.test",
            patterns: [.init(name: "keyword.test", match: "x")]
        )

        registry.addGrammar(grammar, injectionScopeNames: ["source.injected"])

        XCTAssertEqual(registry.lookup(scopeName: "source.test"), grammar)
        XCTAssertEqual(registry.injections(scopeName: "source.test"), ["source.injected"])
        let first = try XCTUnwrap(registry.grammarForScopeName("source.test"))
        let second = try XCTUnwrap(registry.grammarForScopeName("source.test"))
        XCTAssertTrue(first === second)
    }

    func testSwitchingThemeUpdatesProviderWithoutRecompilingGrammar() throws {
        let light = try makeTheme(foreground: "#111111", background: "#eeeeee")
        let dark = try makeTheme(foreground: "#dddddd", background: "#111111")
        let registry = TextMateRegistry(theme: light)
        registry.addGrammar(RawGrammar(scopeName: "source.test"))
        let grammar = try XCTUnwrap(registry.grammarForScopeName("source.test"))

        XCTAssertEqual(registry.getDefaults(), light.getDefaults())
        registry.setTheme(dark)

        XCTAssertEqual(registry.getDefaults(), dark.getDefaults())
        XCTAssertTrue(grammar === registry.grammarForScopeName("source.test"))
    }

    private func makeTheme(
        foreground: String,
        background: String
    ) throws -> Theme {
        try ShikiResolvedTheme(
            name: "test",
            type: .dark,
            settings: [
                .init(settings: .init(foreground: foreground, background: background)),
            ],
            foreground: foreground,
            background: background
        ).compile()
    }
}

/*---------------------------------------------------------
 * Copyright (C) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------*/

import XCTest
@testable import ShikiCore

final class TextMateThemeTests: XCTestCase {
    func testThemeParsingMatchesVscodeTextMate() {
        let source = ShikiTheme(
            settings: [
                .init(settings: .init(foreground: "#F8F8F2", background: "#272822")),
                .init(scope: .string("source, something"), settings: .init(background: "#100000")),
                .init(scope: .array(["bar", "baz"]), settings: .init(background: "#010000")),
                .init(scope: .string("source.css selector bar"), settings: .init(fontStyle: "bold")),
                .init(scope: .string("constant"), settings: .init(fontStyle: "italic", foreground: "#ff0000")),
                .init(scope: .string("constant.numeric"), settings: .init(foreground: "#00ff00")),
                .init(scope: .string("constant.numeric.hex"), settings: .init(fontStyle: "bold")),
                .init(scope: .string("constant.numeric.oct"), settings: .init(fontStyle: "bold italic underline")),
                .init(scope: .string("constant.numeric.bin"), settings: .init(fontStyle: "bold strikethrough")),
                .init(scope: .string("constant.numeric.dec"), settings: .init(fontStyle: "", foreground: "#0000ff")),
                .init(scope: .string("foo"), settings: .init(fontStyle: "", foreground: "#CFA")),
                .init(scope: .string("ignored"), settings: nil),
            ]
        )

        XCTAssertEqual(
            parseTheme(source),
            [
                .init("", nil, 0, .notSet, "#F8F8F2", "#272822"),
                .init("source", nil, 1, .notSet, nil, "#100000"),
                .init("something", nil, 1, .notSet, nil, "#100000"),
                .init("bar", nil, 2, .notSet, nil, "#010000"),
                .init("baz", nil, 2, .notSet, nil, "#010000"),
                .init("bar", ["selector", "source.css"], 3, .bold, nil, nil),
                .init("constant", nil, 4, .italic, "#ff0000", nil),
                .init("constant.numeric", nil, 5, .notSet, "#00ff00", nil),
                .init("constant.numeric.hex", nil, 6, .bold, nil, nil),
                .init("constant.numeric.oct", nil, 7, [.bold, .italic, .underline], nil, nil),
                .init("constant.numeric.bin", nil, 8, [.bold, .strikethrough], nil, nil),
                .init("constant.numeric.dec", nil, 9, .none, "#0000ff", nil),
                .init("foo", nil, 10, .none, "#CFA", nil),
            ]
        )
    }

    func testInvalidColorsAreIgnoredAndTrailingCommasAreRemoved() {
        let rules = parseTheme(
            ShikiTheme(
                settings: [
                    .init(
                        scope: .string(
                            [
                                "meta.at-rule.return.scss,",
                                "meta.at-rule.return.scss punctuation.definition,",
                                "meta.at-rule.else.scss,",
                            ].joined(separator: "\n")
                        ),
                        settings: .init(foreground: "#CC7832")
                    ),
                    .init(
                        scope: .string("variable.parameter"),
                        settings: .init(fontStyle: "italic", foreground: "")
                    ),
                    .init(
                        scope: .string("variable.other"),
                        settings: .init(fontStyle: "normal", foreground: "not-a-color")
                    ),
                ]
            )
        )

        XCTAssertEqual(
            Array(rules.prefix(3)),
            [
                .init("meta.at-rule.return.scss", nil, 0, .notSet, "#CC7832", nil),
                .init("punctuation.definition", ["meta.at-rule.return.scss"], 0, .notSet, "#CC7832", nil),
                .init("meta.at-rule.else.scss", nil, 0, .notSet, "#CC7832", nil),
            ]
        )
        XCTAssertNil(rules[3].foreground)
        XCTAssertEqual(rules[3].fontStyle, .italic)
        XCTAssertNil(rules[4].foreground)
        XCTAssertEqual(rules[4].fontStyle, .none)
    }

    func testDefaultResolutionColorIDsAndTrieInheritance() throws {
        let theme = try Theme.createFromParsedTheme([
            .init("", nil, -1, .notSet, "#F8F8F2", "#272822"),
            .init("var", nil, 1, .bold, "#ff0000", nil),
            .init("var", nil, 0, .notSet, nil, "#010101"),
            .init("var.identifier", nil, 2, .notSet, "#00ff00", nil),
            .init("constant.numeric", nil, 3, .italic, "#123456", nil),
            .init("constant.numeric.hex", nil, 4, .bold, nil, nil),
        ])

        XCTAssertEqual(theme.getColorMap()[0], nil)
        XCTAssertEqual(color(of: theme.getDefaults().foregroundID, in: theme), "#F8F8F2")
        XCTAssertEqual(color(of: theme.getDefaults().backgroundID, in: theme), "#272822")

        let identifier = try XCTUnwrap(theme.match(ScopeStack.from("var.identifier.swift")))
        XCTAssertEqual(identifier.fontStyle, .bold)
        XCTAssertEqual(color(of: identifier.foregroundID, in: theme), "#00FF00")
        XCTAssertEqual(color(of: identifier.backgroundID, in: theme), "#010101")

        let hex = try XCTUnwrap(theme.match(ScopeStack.from("constant.numeric.hex.swift")))
        XCTAssertEqual(hex.fontStyle, .bold)
        XCTAssertEqual(color(of: hex.foregroundID, in: theme), "#123456")
    }

    func testResolvedShikiThemeCompilesAndMatchesSynchronously() throws {
        let resolved = ShikiResolvedTheme(
            name: "native",
            type: .dark,
            settings: [
                .init(settings: .init(foreground: "#D0D0D0", background: "#101010")),
                .init(scope: .string("keyword.control"), settings: .init(fontStyle: "bold", foreground: "#FF0088")),
            ],
            foreground: "#D0D0D0",
            background: "#101010"
        )

        let theme: TextMateTheme = try resolved.compile()
        let match = try XCTUnwrap(theme.match(ScopeStack.from("source.swift", "keyword.control.swift")))

        XCTAssertEqual(match.fontStyle, .bold)
        XCTAssertEqual(color(of: match.foregroundID, in: theme), "#FF0088")
        XCTAssertEqual(theme.match(nil), theme.getDefaults())
    }

    func testParentScopesAndChildCombinatorsMatchExactly() throws {
        let theme = try makeTheme([
            (nil, "#100000"),
            ("b a", "#200000"),
            ("b > a", "#300000"),
            ("c > b > a", "#400000"),
            ("a", "#500000"),
        ])

        XCTAssertEqual(matchColor(theme, ["b", "a"]), "#300000")
        XCTAssertEqual(matchColor(theme, ["b", "c", "a"]), "#200000")
        XCTAssertEqual(matchColor(theme, ["c", "b", "a"]), "#400000")
        XCTAssertEqual(matchColor(theme, ["c", "b", "d", "a"]), "#200000")
    }

    func testSpecificityUsesDeepestScopeThenDepthFirstParentScopes() throws {
        let theme = try makeTheme([
            (nil, "#100000"),
            ("y.z a.b", "#200000"),
            ("x y a.b", "#300000"),
            ("meta.tag entity", "#400000"),
            ("meta.selector.css entity.name.tag", "#500000"),
        ])

        XCTAssertEqual(matchColor(theme, ["x", "y", "a.b"]), "#300000")
        XCTAssertEqual(matchColor(theme, ["x", "y.z", "a.b"]), "#200000")
        XCTAssertEqual(
            matchColor(
                theme,
                [
                    "text.html.cshtml",
                    "meta.tag.structure.any.html",
                    "entity.name.tag.structure.any.html",
                ]
            ),
            "#400000"
        )
    }

    func testFrozenColorMapKeepsIDsAndRejectsMissingColors() throws {
        let parsed: [ParsedThemeRule] = [
            .init("", nil, 0, .notSet, "#000000", "#FFFFFF"),
            .init("keyword", nil, 1, .bold, "#ABCDEF", nil),
        ]
        let frozen: [String?] = [nil, "#000000", "#FFFFFF", "#ABCDEF"]

        let theme = try Theme.createFromParsedTheme(parsed, colorMap: frozen)
        XCTAssertEqual(theme.getColorMap(), frozen)
        XCTAssertEqual(theme.getDefaults().foregroundID, 1)
        XCTAssertEqual(theme.getDefaults().backgroundID, 2)
        XCTAssertEqual(theme.match(ScopeStack.from("keyword"))?.foregroundID, 3)

        XCTAssertThrowsError(
            try Theme.createFromParsedTheme(parsed, colorMap: [nil, "#000000", "#FFFFFF"])
        ) { error in
            XCTAssertEqual(error as? TextMateThemeError, .missingColorInColorMap("#ABCDEF"))
        }

        // This oddity is intentional parity with the upstream truthiness check:
        // ID zero remains the sentinel even if a caller puts a color there.
        XCTAssertThrowsError(
            try Theme.createFromParsedTheme(parsed, colorMap: ["#000000", "#FFFFFF", "#ABCDEF"])
        ) { error in
            XCTAssertEqual(error as? TextMateThemeError, .missingColorInColorMap("#000000"))
        }
    }

    func testScopeStackRetainsIdentityBasedAncestry() {
        let base = ScopeStack.from("source.swift")
        let nested = base.push("meta.function.swift").push("entity.name.function.swift")

        XCTAssertEqual(nested.getSegments(), [
            "source.swift",
            "meta.function.swift",
            "entity.name.function.swift",
        ])
        XCTAssertEqual(nested.description, "source.swift meta.function.swift entity.name.function.swift")
        XCTAssertTrue(nested.extends(base))
        XCTAssertEqual(
            nested.getExtensionIfDefined(base),
            ["meta.function.swift", "entity.name.function.swift"]
        )
        XCTAssertEqual(nested.getExtensionIfDefined(nil), nested.getSegments())

        let equalValueButDifferentNode = ScopeStack.from("source.swift")
        XCTAssertFalse(nested.extends(equalValueButDifferentNode))
        XCTAssertNil(nested.getExtensionIfDefined(equalValueButDifferentNode))
        XCTAssertNil(ScopeStack.push(nil, []))
    }

    private func makeTheme(_ rules: [(scope: String?, foreground: String)]) throws -> Theme {
        try Theme.createFromRawTheme(
            ShikiTheme(
                settings: rules.map { rule in
                    ShikiThemeRule(
                        scope: rule.scope.map(ShikiThemeScope.string),
                        settings: .init(foreground: rule.foreground)
                    )
                }
            )
        )
    }

    private func matchColor(_ theme: Theme, _ path: [String]) -> String? {
        guard let style = theme.match(ScopeStack.from(path)) else {
            return nil
        }
        return color(of: style.foregroundID, in: theme)
    }

    private func color(of id: Int, in theme: Theme) -> String? {
        guard id != 0 else {
            return nil
        }
        return theme.getColorMap()[id]
    }
}

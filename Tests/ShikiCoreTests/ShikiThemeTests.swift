import XCTest
@testable import ShikiCore

final class ShikiThemeTests: XCTestCase {
    func testDecodesVSCodeThemeScopesWithoutLosingTheirJSONShape() throws {
        let data = Data(
            #"""
            {
              "$schema": "vscode://schemas/color-theme",
              "name": "Shape Test",
              "displayName": "Shape Test Display",
              "type": "dark",
              "tokenColors": [
                {
                  "name": "Comment",
                  "scope": "comment.line",
                  "settings": { "fontStyle": "italic", "foreground": "#667788" }
                },
                {
                  "scope": ["keyword", "storage.type"],
                  "settings": { "foreground": "#ff0000" }
                },
                {
                  "settings": { "foreground": "#eeeeee", "background": "#111111" }
                }
              ],
              "semanticTokenColors": {
                "variable.readonly": "#abcdef",
                "*.declaration": { "foreground": "#fedcba", "bold": true }
              }
            }
            """#
                .utf8
        )

        let theme = try JSONDecoder().decode(ShikiTheme.self, from: data)

        XCTAssertEqual(theme.name, "Shape Test")
        XCTAssertEqual(theme.displayName, "Shape Test Display")
        XCTAssertEqual(theme.type, .dark)
        XCTAssertEqual(theme.schema, "vscode://schemas/color-theme")
        XCTAssertEqual(theme.tokenColors?[0].scope, .string("comment.line"))
        XCTAssertEqual(theme.tokenColors?[1].scope, .array(["keyword", "storage.type"]))
        XCTAssertNil(theme.tokenColors?[2].scope)
        XCTAssertEqual(theme.tokenColors?[0].settings?.fontStyle, "italic")
        XCTAssertEqual(theme.semanticTokenColors?["variable.readonly"], .color("#abcdef"))
        XCTAssertEqual(
            theme.semanticTokenColors?["*.declaration"],
            .settings(.init(foreground: "#fedcba", bold: true))
        )
    }

    func testTokenColorsFallbackOnlyWhenSettingsIsAbsent() {
        let globalRule = ShikiThemeRule(
            settings: .init(foreground: "#eeeeee", background: "#111111")
        )

        let fallback = normalizeTheme(
            ShikiTheme(name: "fallback", tokenColors: [globalRule])
        )
        XCTAssertEqual(fallback.settings, [globalRule])
        XCTAssertNil(fallback.tokenColors)

        let explicitEmptySettings = normalizeTheme(
            ShikiTheme(
                name: "no-fallback",
                settings: [],
                tokenColors: [globalRule]
            )
        )
        XCTAssertEqual(explicitEmptySettings.settings.count, 1)
        XCTAssertNil(explicitEmptySettings.settings[0].scope)
        XCTAssertEqual(explicitEmptySettings.settings[0].settings?.foreground, "#bbbbbb")
        XCTAssertEqual(explicitEmptySettings.tokenColors, [globalRule])
    }

    func testForegroundBackgroundPrecedenceMatchesShiki() {
        let theme = ShikiTheme(
            name: "precedence",
            type: .light,
            settings: [
                .init(settings: .init(foreground: "#global-fg")),
            ],
            foreground: "#explicit-fg",
            colors: [
                "editor.foreground": "#editor-fg",
                "editor.background": "#editor-bg",
            ]
        )

        let resolved = normalizeTheme(theme)

        // Once either top-level value is missing, Shiki reads both values from
        // the global rule before consulting editor colors.
        XCTAssertEqual(resolved.foreground, "#global-fg")
        XCTAssertEqual(resolved.background, "#editor-bg")
        XCTAssertEqual(resolved.settings.count, 1, "The leading global rule is retained as the default rule")
    }

    func testDefaultFallbacksAndLeadingDefaultRuleInsertion() {
        let scopedRule = ShikiThemeRule(
            scope: .string("keyword"),
            settings: .init(foreground: "#ff0000")
        )

        let light = normalizeTheme(
            ShikiTheme(name: "light", type: .light, settings: [scopedRule])
        )
        XCTAssertEqual(light.foreground, "#333333")
        XCTAssertEqual(light.background, "#fffffe")
        XCTAssertEqual(light.settings.count, 2)
        XCTAssertNil(light.settings[0].scope)
        XCTAssertEqual(light.settings[0].settings?.foreground, "#333333")
        XCTAssertEqual(light.settings[0].settings?.background, "#fffffe")
        XCTAssertEqual(light.settings[1], scopedRule)

        let dark = normalizeTheme(ShikiTheme(name: "dark"))
        XCTAssertEqual(dark.type, .dark)
        XCTAssertEqual(dark.foreground, "#bbbbbb")
        XCTAssertEqual(dark.background, "#1e1e1e")
    }

    func testEmptyStringScopeIsGlobalButEmptyArrayScopeIsScoped() {
        let emptyString = normalizeTheme(
            ShikiTheme(
                settings: [
                    .init(
                        scope: .string(""),
                        settings: .init(foreground: "#111111", background: "#222222")
                    ),
                ]
            )
        )
        XCTAssertEqual(emptyString.settings.count, 1)

        let emptyArray = normalizeTheme(
            ShikiTheme(
                settings: [
                    .init(
                        scope: .array([]),
                        settings: .init(foreground: "#111111", background: "#222222")
                    ),
                ]
            )
        )
        XCTAssertEqual(emptyArray.settings.count, 2)
        XCTAssertNil(emptyArray.settings[0].scope)
        XCTAssertEqual(emptyArray.settings[1].scope, .array([]))
    }

    func testNonHexColorsReceiveStableDeduplicatedSyntheticColors() {
        let resolved = normalizeTheme(
            ShikiTheme(
                name: "css-colors",
                settings: [
                    .init(
                        scope: .string("keyword"),
                        settings: .init(
                            foreground: "var(--code-fg)",
                            background: "hsl(10 20% 30%)"
                        )
                    ),
                    .init(
                        scope: .string("storage"),
                        settings: .init(foreground: "var(--code-fg)")
                    ),
                ],
                foreground: "var(--code-fg)",
                background: "var(--code-bg)",
                colors: [
                    "terminal.ansiRed": "var(--code-fg)",
                    "editor.foreground": "oklch(80% 0.1 20)",
                    "editor.background": "#101010",
                    "editor.selectionBackground": "var(--selection)",
                ]
            )
        )

        XCTAssertEqual(resolved.settings[0].settings?.foreground, "#00000001")
        XCTAssertEqual(resolved.settings[0].settings?.background, "#00000002")
        XCTAssertEqual(resolved.settings[1].settings?.foreground, "#00000001")
        XCTAssertEqual(resolved.settings[1].settings?.background, "#00000003")
        XCTAssertEqual(resolved.settings[2].settings?.foreground, "#00000001")

        XCTAssertEqual(resolved.colorReplacements["#00000001"], "var(--code-fg)")
        XCTAssertEqual(resolved.colorReplacements["#00000002"], "var(--code-bg)")
        XCTAssertEqual(resolved.colorReplacements["#00000003"], "hsl(10 20% 30%)")
        XCTAssertEqual(resolved.colorReplacements["#00000004"], "oklch(80% 0.1 20)")
        XCTAssertEqual(resolved.colors?["terminal.ansiRed"], "#00000001")
        XCTAssertEqual(resolved.colors?["editor.foreground"], "#00000004")
        XCTAssertEqual(resolved.colors?["editor.background"], "#101010")
        XCTAssertEqual(resolved.colors?["editor.selectionBackground"], "var(--selection)")
    }

    func testSyntheticCollisionCheckMatchesShiki443() {
        let resolved = normalizeTheme(
            ShikiTheme(
                settings: [],
                foreground: "var(--fg)",
                background: "#101010",
                colorReplacements: [
                    "##00000001": "occupied",
                    "#00000002": "old-value",
                ]
            )
        )

        // Shiki 4.4.3 checks a double-hash key when looking for collisions.
        // It skips #1, then writes through the ordinary #2 key.
        XCTAssertEqual(resolved.settings[0].settings?.foreground, "#00000002")
        XCTAssertEqual(resolved.colorReplacements["##00000001"], "occupied")
        XCTAssertEqual(resolved.colorReplacements["#00000002"], "var(--fg)")
    }

    func testColorReplacementResolutionAndLookupMatchShiki() {
        let theme = ShikiResolvedTheme(
            name: "night",
            type: .dark,
            settings: [],
            foreground: "#ffffff",
            background: "#000000",
            colorReplacements: ["#111111": "theme-base"]
        )

        let replacements = resolveColorReplacements(
            for: theme,
            overrides: [
                "#222222": .color("global"),
                "night": .theme(["#333333": "night-only"]),
                "day": .theme(["#444444": "day-only"]),
            ]
        )

        XCTAssertEqual(replacements["#111111"], "theme-base")
        XCTAssertEqual(replacements["#222222"], "global")
        XCTAssertEqual(replacements["#333333"], "night-only")
        XCTAssertNil(replacements["#444444"])

        XCTAssertEqual(applyColorReplacements("#ABCDEF", replacements: ["#abcdef": "replacement"]), "replacement")
        XCTAssertEqual(applyColorReplacements("#ABCDEF", replacements: ["#abcdef": ""]), "#ABCDEF")
        XCTAssertEqual(applyColorReplacements("", replacements: replacements), "")
        XCTAssertNil(applyColorReplacements(nil, replacements: replacements))
    }

    func testNonStringWorkbenchColorsAreIgnoredButRoundTripLosslessly() throws {
        let source = Data(
            ##"{"name":"permissive","colors":{"editor.foreground":"#fff","symbolIcon.constantForeground":["#0f0","#080"],"unused":null}}"##.utf8
        )
        let theme = try JSONDecoder().decode(ShikiTheme.self, from: source)

        XCTAssertEqual(theme.colors?["editor.foreground"], "#fff")
        XCTAssertEqual(
            theme.nonStringColors?["symbolIcon.constantForeground"],
            .array([.string("#0f0"), .string("#080")])
        )
        XCTAssertEqual(theme.nonStringColors?["unused"], .null)

        let roundTrip = try JSONDecoder().decode(
            ShikiTheme.self,
            from: JSONEncoder().encode(theme)
        )
        XCTAssertEqual(roundTrip, theme)
        XCTAssertEqual(normalizeTheme(theme).nonStringColors, theme.nonStringColors)
    }
}

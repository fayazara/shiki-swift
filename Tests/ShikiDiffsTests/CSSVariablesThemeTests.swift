import Foundation
import Shiki
import Testing
@testable import ShikiDiffs

struct CSSVariablesThemeTests {
    @Test func factoryMatchesUpstream() throws {
        struct Options: Decodable {
            var name: String?; var variablePrefix: String?
            var variableDefaults: [String: String]?; var fontStyle: Bool?
        }
        struct Fixture: Decodable { var options: Options; var expected: ShikiTheme }
        let url = try #require(fixtureURL("css-theme-oracle"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        #expect(fixtures.count == 7)
        for fixture in fixtures {
            let input = fixture.options
            #expect(createCSSVariablesTheme(.init(name: input.name ?? "css-variables",
                variablePrefix: input.variablePrefix ?? "--shiki-", variableDefaults: input.variableDefaults ?? [:],
                fontStyle: input.fontStyle ?? true)) == fixture.expected)
        }
    }

    private var defaults: [String: String] {
        let raw = createCSSVariablesTheme()
        let expressions = Array((raw.colors ?? [:]).values) + (raw.tokenColors ?? []).compactMap { $0.settings?.foreground }
        return Dictionary(expressions.map { (String($0.dropFirst("var(--shiki-".count).dropLast()), "#abcdef") }, uniquingKeysWith: { a, _ in a })
    }

    @Test func nativeResolutionAndErrors() throws {
        let options = CSSVariablesThemeOptions(variableDefaults: defaults)
        let theme = try createResolvedCSSVariablesTheme(options, variables: ["--shiki-foreground": "#1234"])
        #expect(theme.colors?["editor.foreground"] == "#11223344")
        #expect(theme.colors?["editor.background"] == "#abcdef")
        #expect(throws: CSSVariableThemeError.missingValue("--shiki-foreground")) {
            try createResolvedCSSVariablesTheme()
        }
        #expect(throws: CSSVariableThemeError.invalidColor(variable: "--shiki-foreground", value: "red")) {
            try createResolvedCSSVariablesTheme(options, variables: ["--shiki-foreground": "red"])
        }
    }

    @Test func lazyRegistrationHighlightsAndRetainsFirstLoader() async throws {
        let highlighter = DiffHighlighter()
        var values = defaults
        values["foreground"] = "#eeeeee"; values["background"] = "#101010"
        values["token-keyword"] = "#ff0000"
        #expect(await highlighter.registerCustomCSSVariableTheme("custom-vars", variableDefaults: values))
        #expect(await highlighter.registerCustomCSSVariableTheme("custom-vars", variableDefaults: [:]) == false)
        #expect(await highlighter.hasResolvedThemes(["custom-vars"]) == false)
        var options = DiffRenderOptions(); options.theme = "custom-vars"
        let file = FileContents(name: "test.swift", contents: "let value = 42\n")
        let document = try await highlighter.prepare(oldFile: file, newFile: file, options: options)
        #expect(document.foreground == "#EEEEEE" || document.foreground == "#eeeeee")
        #expect(document.background == "#101010")
        #expect(document.newTokens[0].contains { $0.content.contains("let") && $0.color?.lowercased() == "#ff0000" })
        #expect(await highlighter.hasResolvedThemes(["custom-vars"]))
        let registered = try await highlighter.getResolvedThemes(["custom-vars"])
        #expect(registered[0].settings.allSatisfy { $0.settings?.fontStyle == nil })
    }
}

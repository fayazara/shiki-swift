import Testing
@testable import ShikiDiffs

struct ThemeEqualityTests {
    @Test func adaptiveModelUsesExactNames() {
        let original = DiffThemeNames(light: "é", dark: "dark")
        #expect(original == DiffThemeNames(light: "é", dark: "dark"))
        #expect(original != DiffThemeNames(light: "e\u{301}", dark: "dark"))
        #expect(DiffThemeNames(light: "light", dark: "é") != DiffThemeNames(light: "light", dark: "e\u{301}"))
    }
    @Test func matchesUpstreamThemeFormsAndCodeUnits() {
        #expect(areThemesEqual(nil, nil))
        #expect(!areThemesEqual(nil, .single("dark")))
        #expect(areThemesEqual(.single("dark"), .single("dark")))
        #expect(!areThemesEqual(.single("dark"), .single("light")))
        let pair = DiffThemeSelection.adaptive(.init(light: "same", dark: "same"))
        #expect(!areThemesEqual(.single("same"), pair))
        #expect(areThemesEqual(pair, pair))
        #expect(!areThemesEqual(pair, .adaptive(.init(light: "other", dark: "same"))))
        #expect(!areThemesEqual(pair, .adaptive(.init(light: "same", dark: "other"))))
        #expect(!areThemesEqual(.single("é"), .single("e\u{301}")))
        #expect(!areThemesEqual(.adaptive(.init(light: "é", dark: "same")), .adaptive(.init(light: "e\u{301}", dark: "same"))))
        #expect(!areThemesEqual(.adaptive(.init(light: "same", dark: "é")), .adaptive(.init(light: "same", dark: "e\u{301}"))))
    }
}

import Shiki
import XCTest

final class ShikiModuleTests: XCTestCase {
    func testUmbrellaModuleExportsCore() throws {
        let scanner = try OnigScanner(patterns: ["swift"])
        XCTAssertNotNil(try scanner.findNextMatchSync("shiki-swift", startPosition: 0))
    }

    func testBundledCatalogLoadsCanonicalLanguageAliasAndTheme() throws {
        let assets = BundledShikiAssets.shared

        XCTAssertEqual(assets.languages.filter { $0.kind == .grammar }.count, 242)
        XCTAssertEqual(assets.languages.filter { $0.kind == .injection }.count, 18)
        XCTAssertEqual(assets.themes.count, 65)
        XCTAssertEqual(assets.canonicalLanguageID(for: "ts"), "typescript")

        let typescript = try assets.loadLanguage(named: "ts")
        XCTAssertEqual(typescript.name, "typescript")
        XCTAssertEqual(typescript.scopeName, "source.ts")

        let theme = try assets.loadTheme(named: "github-dark")
        XCTAssertEqual(theme.name, "github-dark")
        XCTAssertEqual(theme.type, .dark)
        XCTAssertEqual(theme.background.lowercased(), "#24292e")
        XCTAssertGreaterThan(theme.settings.count, 40)
    }

    func testBundledDependencyClosurePreservesShikiLazySplit() throws {
        let assets = BundledShikiAssets.shared

        let eagerIDs = try assets.dependencyOrder(for: "markdown").map(\.id)
        XCTAssertEqual(eagerIDs, ["markdown"])

        let allIDs = try assets.dependencyOrder(
            for: "markdown",
            includingLazyDependencies: true
        ).map(\.id)
        XCTAssertTrue(allIDs.contains("typescript"))
        XCTAssertTrue(allIDs.contains("html"))
        XCTAssertEqual(allIDs.last, "markdown")
        XCTAssertEqual(Set(allIDs).count, allIDs.count)
    }

    func testEveryBundledGrammarAndThemeDecodes() throws {
        let assets = BundledShikiAssets.shared

        for language in assets.languages {
            let registration = try assets.loadLanguage(named: language.id)
            XCTAssertEqual(registration.name, language.id)
            XCTAssertEqual(registration.scopeName, language.scopeName)
        }
        for themeInfo in assets.themes {
            let theme = try assets.loadTheme(named: themeInfo.id)
            XCTAssertEqual(theme.name, themeInfo.id)
            XCTAssertEqual(theme.type, themeInfo.type)
        }
    }
}

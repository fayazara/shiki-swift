import Foundation
import Shiki
import XCTest

final class BundledLanguageSmokeTests: XCTestCase {
    func testEveryDirectlyHighlightableBundledLanguageCompilesAndTokenizes() throws {
        let assets = BundledShikiAssets.shared
        let languages = assets.languages.filter { $0.kind == .grammar }
        XCTAssertEqual(languages.count, 242)
        XCTAssertEqual(assets.languages.filter { $0.kind == .injection }.count, 18)

        // Keep the corpus probe grammar-neutral while including a non-BMP
        // scalar so every grammar exercises absolute UTF-16 accounting.
        let source = "x😀=1"
        let sourceLength = source.utf16.count
        let highlighter = try ShikiHighlighter(defaultTheme: "github-dark", assets: assets)
        // Register the complete corpus in one batch. Besides exercising the 18
        // injection registrations, this avoids rebuilding the growing registry
        // once per canonical language during the smoke loop.
        let registrations = try assets.languages.map {
            try assets.loadLanguage(named: $0.id)
        }
        try highlighter.loadLanguages(registrations)
        var failures: [String] = []

        for language in languages {
            do {
                let result = try highlighter.codeToTokens(
                    source,
                    language: language.id,
                    theme: "github-dark",
                    options: .init(tokenizeTimeLimit: 25)
                )
                guard result.tokens.count == 1 else {
                    failures.append(
                        "\(language.id): expected one line, got \(result.tokens.count)"
                    )
                    continue
                }

                let tokens = result.tokens[0]
                let reconstructed = tokens.map(\.content).joined()
                guard reconstructed == source else {
                    failures.append(
                        "\(language.id): reconstructed \(String(reflecting: reconstructed))"
                    )
                    continue
                }

                var expectedOffset = 0
                var offsetsAreValid = true
                for token in tokens {
                    if token.offset != expectedOffset {
                        failures.append(
                            "\(language.id): token \(String(reflecting: token.content)) "
                                + "started at UTF-16 offset \(token.offset), expected \(expectedOffset)"
                        )
                        offsetsAreValid = false
                        break
                    }
                    expectedOffset += token.content.utf16.count
                }
                if offsetsAreValid, expectedOffset != sourceLength {
                    failures.append(
                        "\(language.id): tokens covered \(expectedOffset) UTF-16 units, "
                            + "expected \(sourceLength)"
                    )
                }
            } catch {
                failures.append("\(language.id): threw \(String(describing: error))")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Bundled language smoke failures:\n" + failures.joined(separator: "\n")
        )
    }

    func testAsciidocColdCompilationRemainsInteractive() throws {
        let highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
        let clock = ContinuousClock()
        let start = clock.now

        let result = try highlighter.codeToTokens(
            "= Title",
            language: "asciidoc",
            theme: "github-dark"
        )

        let elapsed = start.duration(to: clock.now)
        XCTAssertEqual(result.tokens.flatMap { $0 }.map(\.content).joined(), "= Title")
        XCTAssertLessThan(
            elapsed,
            .seconds(5),
            "AsciiDoc's first grammar compilation took \(elapsed)"
        )
    }
}

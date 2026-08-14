import Foundation
import Shiki
import XCTest

final class ShikiDifferentialGoldenTests: XCTestCase {
    func testRepresentativeTokensMatchShiki443() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.shikiVersion, "4.4.3")

        let highlighter = try ShikiHighlighter()
        for goldenCase in fixture.cases {
            let actual = try highlighter.codeToTokens(
                goldenCase.code,
                language: goldenCase.language,
                theme: goldenCase.theme,
                options: .init(includeExplanation: .tokenType)
            )

            if let divergence = firstDivergence(
                actual: actual,
                expected: goldenCase.result
            ) {
                XCTFail(
                    "Shiki 4.4.3 divergence in \(goldenCase.name): \(divergence)"
                )
                return
            }
        }
    }

    private func loadFixture() throws -> GoldenFixture {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Shiki443DifferentialGoldens.json")
        return try JSONDecoder().decode(
            GoldenFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
    }

    private func firstDivergence(
        actual: TokensResult,
        expected: GoldenResult
    ) -> String? {
        if actual.fg != expected.fg {
            return fieldDifference("fg", actual.fg, expected.fg)
        }
        if actual.bg != expected.bg {
            return fieldDifference("bg", actual.bg, expected.bg)
        }
        if actual.themeName != expected.themeName {
            return fieldDifference("themeName", actual.themeName, expected.themeName)
        }
        if actual.tokens.count != expected.tokens.count {
            return "line count expected \(expected.tokens.count), got \(actual.tokens.count)"
        }

        for lineIndex in expected.tokens.indices {
            let actualLine = actual.tokens[lineIndex]
            let expectedLine = expected.tokens[lineIndex]
            if actualLine.count != expectedLine.count {
                return "line \(lineIndex) token count expected \(expectedLine.count), got \(actualLine.count)"
            }

            for tokenIndex in expectedLine.indices {
                let actualToken = actualLine[tokenIndex]
                let expectedToken = expectedLine[tokenIndex]
                let location = "line \(lineIndex), token \(tokenIndex)"

                if actualToken.content != expectedToken.content {
                    return fieldDifference(
                        "\(location), content",
                        actualToken.content,
                        expectedToken.content
                    )
                }
                if actualToken.offset != expectedToken.offset {
                    return fieldDifference(
                        "\(location), UTF-16 offset",
                        actualToken.offset,
                        expectedToken.offset
                    )
                }
                if actualToken.color != expectedToken.color {
                    return fieldDifference(
                        "\(location), color",
                        actualToken.color,
                        expectedToken.color
                    )
                }
                if actualToken.fontStyle?.rawValue != expectedToken.fontStyle {
                    return fieldDifference(
                        "\(location), fontStyle",
                        actualToken.fontStyle?.rawValue,
                        expectedToken.fontStyle
                    )
                }
                if actualToken.type?.rawValue != expectedToken.type {
                    return fieldDifference(
                        "\(location), tokenType",
                        actualToken.type?.rawValue,
                        expectedToken.type
                    )
                }
            }
        }

        return nil
    }

    private func fieldDifference<T>(
        _ field: String,
        _ actual: T,
        _ expected: T
    ) -> String {
        "\(field) expected \(String(reflecting: expected)), got \(String(reflecting: actual))"
    }
}

private struct GoldenFixture: Decodable {
    let shikiVersion: String
    let cases: [GoldenCase]
}

private struct GoldenCase: Decodable {
    let name: String
    let language: String
    let theme: String
    let code: String
    let result: GoldenResult
}

private struct GoldenResult: Decodable {
    let tokens: [[GoldenToken]]
    let fg: String
    let bg: String
    let themeName: String
}

private struct GoldenToken: Decodable {
    let content: String
    let offset: Int
    let color: String
    let fontStyle: Int32
    let type: UInt32
}

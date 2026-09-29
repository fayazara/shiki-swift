import Foundation
import Shiki
import ShikiCore
import XCTest

/// Compares `applyShikiNotations` with the real `@shikijs/transformers`
/// (diff, highlight, focus, error level, and word highlight, chained) on
/// bundled-language samples with injected `[!code …]` comments.
/// Regenerate with `Scripts/generate-notation-goldens.mjs`.
final class ShikiNotationGoldenTests: XCTestCase {
    private struct Fixture: Decodable {
        let shikiVersion: String
        let cases: [GoldenCase]
    }

    private struct GoldenCase: Decodable {
        let lang: String
        let style: String
        let code: String
        let variants: [String: [GoldenLine]]
    }

    private struct GoldenLine: Decodable, Equatable {
        let t: String
        let c: [String]
        let w: [[Int]]
    }

    func testNotationsMatchShikiTransformers() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.shikiVersion, "4.4.3")
        XCTAssertGreaterThan(fixture.cases.count, 50)

        let highlighter = try ShikiHighlighter()
        var annotatedLines = 0
        var wordRanges = 0
        for item in fixture.cases {
            let tokens = try highlighter.codeToTokens(
                item.code,
                language: item.lang,
                theme: "github-dark",
                options: .init(tokenizeTimeLimit: 0)
            ).tokens

            for (name, expected) in item.variants.sorted(by: { $0.key < $1.key }) {
                let result = applyShikiNotations(
                    to: tokens,
                    language: item.lang,
                    matchAlgorithm: name == "v1" ? .v1 : .v3
                )
                let actual = golden(result)
                if name == "v3" {
                    annotatedLines += actual.filter { !$0.c.isEmpty }.count
                    wordRanges += actual.reduce(0) { $0 + $1.w.count }
                }
                guard actual != expected else { continue }

                let index = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                XCTFail(
                    "\(item.lang)/\(item.style) \(name): "
                        + (index.map { "line \($0): got \(actual[$0]) want \(expected[$0])" }
                            ?? "\(actual.count) lines, expected \(expected.count)")
                )
                return
            }
        }
        // The fixture must actually exercise the notations.
        XCTAssertGreaterThan(annotatedLines, 100)
        XCTAssertGreaterThan(wordRanges, 10)
    }

    /// The same shape the generator records from Shiki's HAST: line text,
    /// the CSS classes upstream would add, and highlighted-word ranges.
    private func golden(_ result: ShikiNotationResult) -> [GoldenLine] {
        var ranges: [Int: [[Int]]] = [:]
        for word in result.wordHighlights {
            ranges[word.line, default: []].append([word.range.lowerBound, word.range.upperBound])
        }
        return result.tokens.indices.map { index in
            GoldenLine(
                t: result.tokens[index].map(\.content).joined(),
                c: classes(result.lineNotations[index]),
                w: ranges[index] ?? []
            )
        }
    }

    private func classes(_ notations: Set<ShikiLineNotation>) -> [String] {
        var out = Set<String>()
        for notation in notations {
            switch notation {
            case .added: out.formUnion(["diff", "add"])
            case .removed: out.formUnion(["diff", "remove"])
            case .highlighted: out.insert("highlighted")
            case .focused: out.insert("focused")
            case .error: out.formUnion(["highlighted", "error"])
            case .warning: out.formUnion(["highlighted", "warning"])
            case .info: out.formUnion(["highlighted", "info"])
            }
        }
        return out.sorted()
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("ShikiNotationGoldens.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

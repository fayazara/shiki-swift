import XCTest
@testable import ShikiCore

final class ShikiNotationTests: XCTestCase {
    /// Token lines from plain strings, with running UTF-16 offsets like Shiki's.
    private func lines(_ rows: [[String]]) -> [[ThemedToken]] {
        var offset = 0
        return rows.map { row in
            defer { offset += 1 }
            return row.map { part in
                defer { offset += part.utf16.count }
                return ThemedToken(content: part, offset: offset, color: "#fff")
            }
        }
    }

    private func text(_ result: ShikiNotationResult) -> [String] {
        result.tokens.map { $0.map(\.content).joined() }
    }

    func testSourceWithoutNotationsIsReturnedUnchanged() {
        let input = lines([["let a = 1", " ", "// note // more"], ["b"]])
        let result = applyShikiNotations(to: input)
        XCTAssertEqual(result.tokens, input)
        XCTAssertEqual(result.lineNotations, [[], []])
        XCTAssertTrue(result.wordHighlights.isEmpty)
        XCTAssertFalse(result.contains(.added))
    }

    func testTrailingCommentMarksItsOwnLineAndIsRemoved() {
        let result = applyShikiNotations(to: lines([["let a = 1", " ", "// [!code ++]"], ["let b = 2"]]))
        XCTAssertEqual(text(result), ["let a = 1", "let b = 2"])
        XCTAssertEqual(result.lineNotations, [[.added], []])
    }

    func testStandaloneCommentMarksTheNextLinesAndDisappears() {
        let result = applyShikiNotations(to: lines([
            ["a"], ["  ", "// [!code focus:2]"], ["b"], ["c"], ["d"],
        ]))
        XCTAssertEqual(text(result), ["a", "b", "c", "d"])
        XCTAssertEqual(result.lineNotations, [[], [.focused], [.focused], []])
    }

    func testCommentsWithOtherTextKeepTheirTextAndMarkTheirOwnLine() {
        let result = applyShikiNotations(to: lines([["run()", " ", "// keep me [!code hl]"], ["next"]]))
        XCTAssertEqual(text(result), ["run() // keep me", "next"])
        XCTAssertEqual(result.lineNotations, [[.highlighted], []])
    }

    func testMultipleNotationsInOneCommentApplyToTheSameLine() {
        let result = applyShikiNotations(to: lines([["x", " ", "// [!code ++] [!code highlight]"]]))
        XCTAssertEqual(text(result), ["x"])
        XCTAssertEqual(result.lineNotations, [[.added, .highlighted]])
    }

    func testErrorLevelsAndCaseSensitiveKeys() {
        let result = applyShikiNotations(to: lines([
            ["a", " // [!code error]"], ["b", " // [!code warning]"], ["c", " // [!code info]"],
            ["d", " // [!code HIGHLIGHT]"],
        ]))
        XCTAssertEqual(text(result), ["a", "b", "c", "d"])
        // The regex is case-insensitive but the key lookup is not, exactly as upstream:
        // the comment is consumed without marking anything.
        XCTAssertEqual(result.lineNotations, [[.error], [.warning], [.info], []])
    }

    func testCountZeroConsumesTheCommentButMarksNothing() {
        let result = applyShikiNotations(to: lines([["a", " // [!code ++:0]"], ["b"]]))
        XCTAssertEqual(text(result), ["a", "b"])
        XCTAssertEqual(result.lineNotations, [[], []])
    }

    func testNestedCommentsSplitSoOnlyTheNotationComment() {
        let result = applyShikiNotations(to: lines([["call()", " // why // [!code --]"]]))
        XCTAssertEqual(text(result), ["call() // why"])
        XCTAssertEqual(result.lineNotations, [[.removed]])
    }

    func testTokenSplitComments() {
        // Some themes color `//` and the text after it differently.
        let result = applyShikiNotations(to: lines([["value", " ", "//", " [!code --]"]]))
        XCTAssertEqual(text(result), ["value"])
        XCTAssertEqual(result.lineNotations, [[.removed]])
    }

    func testCommentSyntaxes() {
        let cases: [(String, String)] = [
            ("x # [!code ++]", "x"), ("x -- [!code ++]", "x"), ("x ; [!code ++]", "x"),
            ("x % [!code ++]", "x"), ("x /* [!code ++] */", "x"), ("x <!-- [!code ++] -->", "x"),
        ]
        for (source, expected) in cases {
            let parts = source.components(separatedBy: " ")
            let result = applyShikiNotations(to: lines([[parts[0], " " + parts.dropFirst().joined(separator: " ")]]))
            XCTAssertEqual(text(result), [expected], source)
            XCTAssertEqual(result.lineNotations, [[.added]], source)
        }
    }

    func testAlgorithmV1AppliesStandaloneCommentsToTheirOwnLine() {
        let result = applyShikiNotations(
            to: lines([["// [!code ++]"], ["b"]]), matchAlgorithm: .v1
        )
        // Nothing is left to mark, and the comment line is removed.
        XCTAssertEqual(text(result), ["b"])
        XCTAssertEqual(result.lineNotations, [[]])
    }

    func testWordHighlightMarksEveryOccurrenceInTheCoveredLines() {
        let result = applyShikiNotations(to: lines([
            ["// [!code word:foo:2]"], ["foo(foo)"], ["foo"], ["foo"],
        ]))
        XCTAssertEqual(text(result), ["foo(foo)", "foo", "foo"])
        XCTAssertEqual(result.wordHighlights, [
            ShikiWordHighlight(line: 0, range: 0..<3),
            ShikiWordHighlight(line: 0, range: 4..<7),
            ShikiWordHighlight(line: 1, range: 0..<3),
        ])
    }

    func testWordHighlightAcrossTokensAndEscapes() {
        let trailing = applyShikiNotations(to: lines([["let ", "value", " = 1", " // [!code word:value = 1]"]]))
        XCTAssertEqual(text(trailing), ["let value = 1"])
        XCTAssertEqual(trailing.wordHighlights, [ShikiWordHighlight(line: 0, range: 4..<13)])

        let escaped = applyShikiNotations(to: lines([["a:b a:b", " // [!code word:a\\:b]"]]))
        XCTAssertEqual(text(escaped), ["a:b a:b"])
        XCTAssertEqual(escaped.wordHighlights.map(\.range), [0..<3, 4..<7])
    }

    func testOffsetsAreRecomputedForTheCleanedCode() {
        let result = applyShikiNotations(to: lines([["a", " ", "// [!code ++]"], ["// [!code hl]"], ["bc"]]))
        XCTAssertEqual(result.code, "a\nbc")
        let utf16 = Array(result.code.utf16)
        for row in result.tokens {
            for token in row {
                let range = token.offset..<(token.offset + token.content.utf16.count)
                XCTAssertEqual(String(decoding: utf16[range], as: UTF16.self), token.content)
            }
        }
    }

    func testOnlyRequestedNotationFamiliesAreApplied() {
        let result = applyShikiNotations(
            to: lines([["a", " // [!code ++]"], ["b", " // [!code hl]"]]), notations: [.diff]
        )
        XCTAssertEqual(text(result), ["a", "b // [!code hl]"])
        XCTAssertEqual(result.lineNotations, [[.added], []])
    }

    func testJSXCommentsRemoveTheirBraces() {
        let input = lines([
            ["<div>"],
            ["{", "/* [!code ++] */", "}"],
            ["<b/>", " ", "{", "/* [!code highlight] */", "}"],
            ["</div>"],
        ])
        // A whole-line `{/* … */}` marks the next line; a trailing one marks its own.
        // Both take their braces with them, but only for jsx and tsx.
        for language in ["jsx", "tsx"] {
            let result = applyShikiNotations(to: input, language: language)
            XCTAssertEqual(text(result), ["<div>", "<b/>", "</div>"], language)
            XCTAssertEqual(result.lineNotations, [[], [.added, .highlighted], []], language)
        }
    }

    func testWhitespaceMergingMatchesShikisDefault() {
        let merged = mergingWhitespaceTokens([[
            ThemedToken(content: "  ", offset: 0), ThemedToken(content: "a", offset: 2, color: "#f00"),
            ThemedToken(content: " ", offset: 3), ThemedToken(content: "  ", offset: 4),
        ]])
        XCTAssertEqual(merged[0].map(\.content), ["  a", "   "])
        XCTAssertEqual(merged[0].map(\.offset), [0, 3])
        XCTAssertEqual(merged[0][0].color, "#f00")
    }
}

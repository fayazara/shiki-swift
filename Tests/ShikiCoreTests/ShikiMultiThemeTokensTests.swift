import XCTest
@testable import ShikiCore

final class ShikiMultiThemeTokensTests: XCTestCase {
    func testAlignsTwoUpstreamThemeTokenizationsAtEveryBoundary() throws {
        let first = [makeLine(
            ["console", ".", "log", "(", "\"", "hello", "\"", ")"],
            color: "#111111"
        )]
        let second = [makeLine(
            ["console", ".log", "(", "\"hello\"", ")"],
            color: "#222222"
        )]

        let aligned = try alignThemesTokenization([first, second])
        let expected = ["console", ".", "log", "(", "\"", "hello", "\"", ")"]

        XCTAssertEqual(aligned[0][0].map(\.content), expected)
        XCTAssertEqual(aligned[1][0].map(\.content), expected)
        XCTAssertEqual(
            aligned[1][0].map(\.offset),
            [0, 7, 8, 11, 12, 13, 18, 19]
        )
        XCTAssertTrue(aligned[1][0].allSatisfy { $0.color == "#222222" })
    }

    func testAlignsThreeUpstreamThemeTokenizations() throws {
        let first = [makeLine(
            ["console", ".", "log", "(", "\"", "hello", "\"", ");"]
        )]
        let second = [makeLine(
            ["console", ".log", "(", "\"hello\"", ");"]
        )]
        let third = [makeLine(
            ["console", ".", "log", "(", "\"", "hello", "\"", ")", ";"]
        )]

        let aligned = try alignThemesTokenization([first, second, third])
        let expected = "console . log ( \" hello \" ) ;"

        XCTAssertEqual(aligned.count, 3)
        XCTAssertTrue(
            aligned.allSatisfy {
                $0[0].map(\.content).joined(separator: " ") == expected
            }
        )
    }

    func testSplitsByUTF16AndPreservesTokenBaseAndStyles() throws {
        let explanation = [
            ThemedTokenExplanation(
                content: "🙂ab",
                scopes: [.init(scopeName: "string.quoted.test")]
            )
        ]
        let first = [[
            ThemedToken(
                content: "🙂ab",
                offset: 10,
                type: .string,
                explanation: explanation,
                color: "#111111",
                bgColor: "#AAAAAA",
                fontStyle: [.bold, .italic],
                htmlStyle: ["opacity": "0.5"],
                htmlAttrs: ["data-token": "one"]
            )
        ]]
        let second = [[
            ThemedToken(content: "🙂", offset: 10, type: .regex),
            ThemedToken(content: "a", offset: 12, type: .regex),
            ThemedToken(content: "b", offset: 13, type: .regex),
        ]]

        let aligned = try alignThemesTokenization([first, second])

        XCTAssertEqual(aligned[0][0].map(\.content), ["🙂", "a", "b"])
        XCTAssertEqual(aligned[0][0].map(\.offset), [10, 12, 13])
        for token in aligned[0][0] {
            XCTAssertEqual(token.type, .string)
            XCTAssertEqual(token.explanation, explanation)
            XCTAssertEqual(token.color, "#111111")
            XCTAssertEqual(token.bgColor, "#AAAAAA")
            XCTAssertEqual(token.fontStyle, [.bold, .italic])
            XCTAssertEqual(token.htmlStyle, ["opacity": "0.5"])
            XCTAssertEqual(token.htmlAttrs, ["data-token": "one"])
        }
        XCTAssertTrue(aligned[1][0].allSatisfy { $0.type == .regex })
    }

    func testMergesNamedStylesAndOptionallyFirstThemeExplanation() throws {
        let explanation = [
            ThemedTokenExplanation(
                content: "a.b",
                scopes: [.init(scopeName: "source.test")]
            )
        ]
        let light = [[
            ThemedToken(
                content: "a.b",
                offset: 4,
                type: .other,
                explanation: explanation,
                color: "#111111",
                fontStyle: .italic
            )
        ]]
        let dark = [[
            ThemedToken(content: "a", offset: 4, color: "#EEEEEE"),
            ThemedToken(content: ".", offset: 5, color: "#BBBBBB"),
            ThemedToken(content: "b", offset: 6, color: "#EEEEEE"),
        ]]
        let themes = [
            NamedThemeTokenization(name: "light", tokens: light),
            NamedThemeTokenization(name: "dark", tokens: dark),
        ]

        let merged = try mergeThemesTokenization(
            themes,
            includeExplanation: true
        )

        XCTAssertEqual(merged[0].map(\.content), ["a", ".", "b"])
        XCTAssertEqual(merged[0].map(\.offset), [4, 5, 6])
        XCTAssertTrue(merged[0].allSatisfy { $0.type == nil })
        XCTAssertTrue(merged[0].allSatisfy { $0.explanation == explanation })
        XCTAssertEqual(merged[0][0].variants["light"]?.color, "#111111")
        XCTAssertEqual(merged[0][0].variants["light"]?.fontStyle, .italic)
        XCTAssertEqual(merged[0][0].variants["light"]?.type, .other)
        XCTAssertEqual(merged[0][1].variants["dark"]?.color, "#BBBBBB")
        XCTAssertNil(merged[0][1].variants["dark"]?.type)

        let withoutExplanation = try mergeThemesTokenization(themes)
        XCTAssertTrue(withoutExplanation[0].allSatisfy { $0.explanation == nil })
        XCTAssertTrue(withoutExplanation[0].allSatisfy { $0.type == nil })
    }

    func testPreservesLineTopologyAbsoluteOffsetsAndEmptyLines() throws {
        let first = [
            makeLine(["ab"], startOffset: 0),
            [],
            makeLine(["🙂x"], startOffset: 4),
        ]
        let second = [
            makeLine(["a", "b"], startOffset: 0),
            [],
            makeLine(["🙂", "x"], startOffset: 4),
        ]

        let aligned = try alignThemesTokenization([first, second])

        XCTAssertEqual(aligned[0].count, 3)
        XCTAssertEqual(aligned[0][1], [])
        XCTAssertEqual(aligned[0][2].map(\.content), ["🙂", "x"])
        XCTAssertEqual(aligned[0][2].map(\.offset), [4, 6])
    }

    func testAllowsMatchingPlainLanguageEmptyTokens() throws {
        let empty = ThemedToken(content: "", offset: 12)
        let aligned = try alignThemesTokenization([[[empty]], [[empty]]])

        XCTAssertEqual(aligned[0][0], [empty])
        XCTAssertEqual(aligned[1][0], [empty])
    }

    func testAlignsGrammarAndNoneThemeEmptyLineLikeUpstream() throws {
        let empty = ThemedToken(content: "", offset: 12)
        let aligned = try alignThemesTokenization([[[]], [[empty]]])

        XCTAssertEqual(aligned[0][0], [])
        XCTAssertEqual(aligned[1][0], [])
    }

    func testRejectsInvalidThemeTopologies() throws {
        XCTAssertThrowsError(try alignThemesTokenization([])) {
            XCTAssertEqual($0 as? MultiThemeTokenizationError, .noThemes)
        }

        XCTAssertThrowsError(
            try alignThemesTokenization([
                [makeLine(["a"])],
                [makeLine(["a"]), makeLine(["b"], startOffset: 2)],
            ])
        ) {
            XCTAssertEqual(
                $0 as? MultiThemeTokenizationError,
                .lineCountMismatch(theme: 1, expected: 1, actual: 2)
            )
        }

        XCTAssertThrowsError(
            try alignThemesTokenization([
                [makeLine(["abc"])],
                [makeLine(["abd"])],
            ])
        ) {
            XCTAssertEqual(
                $0 as? MultiThemeTokenizationError,
                .lineContentMismatch(theme: 1, line: 0)
            )
        }

        // Swift considers these canonically equivalent Strings, while Shiki
        // compares and slices their distinct JavaScript UTF-16 sequences.
        XCTAssertThrowsError(
            try alignThemesTokenization([
                [makeLine(["\u{00E9}"])],
                [makeLine(["e\u{0301}"])],
            ])
        ) {
            XCTAssertEqual(
                $0 as? MultiThemeTokenizationError,
                .lineContentMismatch(theme: 1, line: 0)
            )
        }

        let discontinuous = [[
            ThemedToken(content: "a", offset: 0),
            ThemedToken(content: "b", offset: 9),
        ]]
        XCTAssertThrowsError(
            try alignThemesTokenization([[makeLine(["ab"])], discontinuous])
        ) {
            XCTAssertEqual(
                $0 as? MultiThemeTokenizationError,
                .discontinuousTokenOffset(
                    theme: 1,
                    line: 0,
                    token: 1,
                    expected: 1,
                    actual: 9
                )
            )
        }

        XCTAssertThrowsError(
            try mergeThemesTokenization([
                .init(name: "dark", tokens: [makeLine(["a"])]),
                .init(name: "dark", tokens: [makeLine(["a"])]),
            ])
        ) {
            XCTAssertEqual(
                $0 as? MultiThemeTokenizationError,
                .duplicateVariantName("dark")
            )
        }
    }

    func testVariantModelCodableRoundTripPreservesPublicShape() throws {
        let token = ThemedTokenWithVariants(
            content: "let",
            offset: 2,
            type: .other,
            explanation: nil,
            variants: [
                "light": TokenStyles(color: "#111111", fontStyle: .bold),
                "dark": TokenStyles(color: "#EEEEEE", fontStyle: .italic),
            ]
        )

        let data = try JSONEncoder().encode(token)
        XCTAssertEqual(try JSONDecoder().decode(ThemedTokenWithVariants.self, from: data), token)
    }
}

private func makeLine(
    _ contents: [String],
    startOffset: Int = 0,
    color: String? = nil
) -> [ThemedToken] {
    var offset = startOffset
    return contents.map { content in
        defer { offset += content.utf16.count }
        return ThemedToken(content: content, offset: offset, color: color)
    }
}

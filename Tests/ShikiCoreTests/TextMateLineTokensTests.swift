import XCTest
@testable import ShikiCore

final class TextMateLineTokensTests: XCTestCase {
    func testNonBinaryTokensPreserveScopeBoundariesAndUTF16Indices() {
        let line = LineTokens(
            emitBinaryTokens: false,
            lineText: "a😀b\n",
            tokenTypeOverrides: [],
            balancedBracketSelectors: nil
        )

        line.produceFromScopes(
            scopeNames: ["source.swift"],
            tokenAttributes: 0,
            endIndex: 1
        )
        line.produceFromScopes(
            scopeNames: ["source.swift", "constant.character"],
            tokenAttributes: 0,
            endIndex: 3
        )
        line.produceFromScopes(
            scopeNames: ["source.swift"],
            tokenAttributes: 0,
            endIndex: 4
        )

        XCTAssertEqual(
            line.getResult(
                fallbackScopeNames: [],
                fallbackTokenAttributes: 0,
                lineLength: 5
            ),
            [
                TextMateToken(startIndex: 0, endIndex: 1, scopes: ["source.swift"]),
                TextMateToken(
                    startIndex: 1,
                    endIndex: 3,
                    scopes: ["source.swift", "constant.character"]
                ),
                TextMateToken(startIndex: 3, endIndex: 4, scopes: ["source.swift"]),
            ]
        )
    }

    func testBinaryTokensMergeAdjacentEqualMetadata() {
        let metadata = EncodedTokenMetadata.set(
            0,
            languageID: 5,
            foreground: 3,
            background: 4
        )
        let line = LineTokens(
            emitBinaryTokens: true,
            lineText: "abc\n",
            tokenTypeOverrides: [],
            balancedBracketSelectors: nil
        )

        line.produceFromScopes(
            scopeNames: ["source.swift"],
            tokenAttributes: metadata,
            endIndex: 1
        )
        line.produceFromScopes(
            scopeNames: ["source.swift", "identifier.swift"],
            tokenAttributes: metadata,
            endIndex: 3
        )

        XCTAssertEqual(
            line.getBinaryResult(
                fallbackScopeNames: [],
                fallbackTokenAttributes: 0,
                lineLength: 4
            ),
            [0, metadata]
        )
    }

    func testTokenTypeOverrideAndBalancedBracketFlagUpdateMetadata() {
        let override = TokenTypeMatcher(
            matcher: ScopeSelector.parse("string")[0].matcher,
            type: .string
        )
        let brackets = BalancedBracketSelectors(
            balancedBracketScopes: ["*"],
            unbalancedBracketScopes: ["comment"]
        )
        let line = LineTokens(
            emitBinaryTokens: true,
            lineText: "x\n",
            tokenTypeOverrides: [override],
            balancedBracketSelectors: brackets
        )

        line.produceFromScopes(
            scopeNames: ["source.swift", "string.quoted.swift"],
            tokenAttributes: 0,
            endIndex: 1
        )
        let result = line.getBinaryResult(
            fallbackScopeNames: [],
            fallbackTokenAttributes: 0,
            lineLength: 2
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(EncodedTokenMetadata.getTokenType(result[1]), .string)
        XCTAssertTrue(EncodedTokenMetadata.containsBalancedBrackets(result[1]))
    }

    func testNewlineOnlyTokenIsRemovedAndFallbackStartsAtZero() {
        let line = LineTokens(
            emitBinaryTokens: false,
            lineText: "\n",
            tokenTypeOverrides: [],
            balancedBracketSelectors: nil
        )
        line.produceFromScopes(
            scopeNames: ["source.swift"],
            tokenAttributes: 0,
            endIndex: 1
        )

        XCTAssertEqual(
            line.getResult(
                fallbackScopeNames: ["source.swift"],
                fallbackTokenAttributes: 0,
                lineLength: 1
            ),
            [TextMateToken(startIndex: 0, endIndex: 1, scopes: ["source.swift"])]
        )
    }
}

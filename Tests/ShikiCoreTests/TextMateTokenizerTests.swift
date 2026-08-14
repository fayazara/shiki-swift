/*---------------------------------------------------------
 * Copyright (C) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------*/

import XCTest
@testable import ShikiCore

// Expected token vectors in this suite were cross-checked against
// @shikijs/vscode-textmate 10.0.2 using its Oniguruma WASM engine.
final class TextMateTokenizerTests: XCTestCase {
    func testBeginEndCapturesAndMatchRulesUseUTF16Offsets() throws {
        let grammar = makeGrammar(
            patterns: [
                RawRule(
                    name: "string.quoted.test",
                    contentName: "string.quoted.content.test",
                    begin: #"""#,
                    beginCaptures: [
                        "0": RawRule(name: "punctuation.definition.string.begin.test")
                    ],
                    end: #"""#,
                    endCaptures: [
                        "0": RawRule(name: "punctuation.definition.string.end.test")
                    ]
                ),
                RawRule(name: "keyword.control.test", match: #"\bif\b"#),
            ]
        )

        let result = try grammar.tokenizeLine(#"🙂 "x" if"#)

        XCTAssertFalse(result.stoppedEarly)
        XCTAssertEqual(result.ruleStack.depth, 1)
        XCTAssertEqual(
            result.tokens,
            [
                token(0, 3, "source.test"),
                token(
                    3,
                    4,
                    "source.test",
                    "string.quoted.test",
                    "punctuation.definition.string.begin.test"
                ),
                token(
                    4,
                    5,
                    "source.test",
                    "string.quoted.test",
                    "string.quoted.content.test"
                ),
                token(
                    5,
                    6,
                    "source.test",
                    "string.quoted.test",
                    "punctuation.definition.string.end.test"
                ),
                token(6, 7, "source.test"),
                token(7, 9, "source.test", "keyword.control.test"),
            ]
        )
    }

    func testBeginEndStateContinuesAcrossLinesAndResolvesBackReference() throws {
        let grammar = makeGrammar(
            patterns: [
                RawRule(
                    name: "string.quoted.test",
                    contentName: "string.quoted.content.test",
                    begin: #"([\"'])"#,
                    end: #"\1"#
                )
            ]
        )

        let first = try grammar.tokenizeLine(#"'alpha"#)
        XCTAssertEqual(first.ruleStack.depth, 2)
        XCTAssertEqual(first.ruleStack.endRule, "'")
        XCTAssertEqual(
            first.tokens,
            [
                token(0, 1, "source.test", "string.quoted.test"),
                token(
                    1,
                    7,
                    "source.test",
                    "string.quoted.test",
                    "string.quoted.content.test"
                ),
            ]
        )

        let second = try grammar.tokenizeLine(
            #"beta'"#,
            previousState: first.ruleStack
        )
        XCTAssertEqual(second.ruleStack.depth, 1)
        XCTAssertEqual(
            second.tokens,
            [
                token(
                    0,
                    4,
                    "source.test",
                    "string.quoted.test",
                    "string.quoted.content.test"
                ),
                token(4, 5, "source.test", "string.quoted.test"),
            ]
        )
    }

    func testBeginWhileChecksBottomToTopAndPopsWhenConditionFails() throws {
        let grammar = makeGrammar(
            patterns: [
                RawRule(
                    name: "markup.quote.test",
                    contentName: "markup.quote.content.test",
                    begin: "^(>)",
                    beginCaptures: [
                        "1": RawRule(name: "punctuation.definition.quote.begin.test")
                    ],
                    whilePattern: "^(>)",
                    whileCaptures: [
                        "1": RawRule(name: "punctuation.definition.quote.continue.test")
                    ]
                )
            ]
        )

        let first = try grammar.tokenizeLine("> one")
        XCTAssertEqual(first.ruleStack.depth, 2)
        XCTAssertEqual(
            first.tokens.first,
            token(
                0,
                1,
                "source.test",
                "markup.quote.test",
                "punctuation.definition.quote.begin.test"
            )
        )

        let second = try grammar.tokenizeLine(
            "> two",
            previousState: first.ruleStack
        )
        XCTAssertEqual(second.ruleStack.depth, 2)
        XCTAssertEqual(
            second.tokens,
            [
                token(
                    0,
                    1,
                    "source.test",
                    "markup.quote.test",
                    "markup.quote.content.test",
                    "punctuation.definition.quote.continue.test"
                ),
                token(
                    1,
                    6,
                    "source.test",
                    "markup.quote.test",
                    "markup.quote.content.test"
                ),
            ]
        )

        let third = try grammar.tokenizeLine(
            "plain",
            previousState: second.ruleStack
        )
        XCTAssertEqual(third.ruleStack.depth, 1)
        XCTAssertEqual(third.tokens, [token(0, 6, "source.test")])
    }

    func testCaptureRetokenizationRunsNestedRulesInsideCaptureBounds() throws {
        let grammar = makeGrammar(
            patterns: [
                RawRule(
                    name: "meta.brackets.test",
                    match: #"\[([^]]+)\]"#,
                    captures: [
                        "1": RawRule(
                            name: "meta.inner.test",
                            patterns: [
                                RawRule(name: "constant.numeric.test", match: #"\d+"#),
                                RawRule(name: "variable.word.test", match: "[a-z]+"),
                            ]
                        )
                    ]
                )
            ]
        )

        let result = try grammar.tokenizeLine("[12x]")

        XCTAssertEqual(
            result.tokens,
            [
                token(0, 1, "source.test", "meta.brackets.test"),
                token(
                    1,
                    3,
                    "source.test",
                    "meta.brackets.test",
                    "meta.inner.test",
                    "constant.numeric.test"
                ),
                token(
                    3,
                    4,
                    "source.test",
                    "meta.brackets.test",
                    "meta.inner.test",
                    "variable.word.test"
                ),
                token(4, 5, "source.test", "meta.brackets.test"),
            ]
        )
    }

    func testLeftInjectionWinsSamePositionWhileNormalRuleWinsRightInjection() throws {
        let leftGrammar = makeGrammar(
            patterns: [RawRule(name: "normal.test", match: "x")],
            injections: [
                "L:source.test": RawRule(name: "injected.left.test", match: "x")
            ]
        )
        XCTAssertEqual(
            try leftGrammar.tokenizeLine("x").tokens,
            [token(0, 1, "source.test", "injected.left.test")]
        )

        let rightGrammar = makeGrammar(
            patterns: [RawRule(name: "normal.test", match: "x")],
            injections: [
                "R:source.test": RawRule(name: "injected.right.test", match: "x")
            ]
        )
        XCTAssertEqual(
            try rightGrammar.tokenizeLine("x").tokens,
            [token(0, 1, "source.test", "normal.test")]
        )
    }

    func testAAndGAnchorsUseFirstLineAndBeginAnchorPositions() throws {
        let grammar = makeGrammar(
            patterns: [
                RawRule(name: "first.line.test", match: #"\Afirst"#),
                RawRule(
                    name: "meta.anchor.test",
                    begin: "@",
                    end: "#",
                    patterns: [
                        RawRule(name: "anchored.word.test", match: #"\G[a-z]+"#),
                        RawRule(name: "ordinary.word.test", match: "[a-z]+"),
                    ]
                ),
            ]
        )

        let first = try grammar.tokenizeLine("first")
        XCTAssertEqual(
            first.tokens,
            [token(0, 5, "source.test", "first.line.test")]
        )
        let next = try grammar.tokenizeLine(
            "first",
            previousState: first.ruleStack
        )
        XCTAssertEqual(next.tokens, [token(0, 6, "source.test")])

        let anchored = try grammar.tokenizeLine("@abc def#")
        XCTAssertEqual(
            anchored.tokens,
            [
                token(0, 1, "source.test", "meta.anchor.test"),
                token(
                    1,
                    4,
                    "source.test",
                    "meta.anchor.test",
                    "anchored.word.test"
                ),
                token(4, 5, "source.test", "meta.anchor.test"),
                token(
                    5,
                    8,
                    "source.test",
                    "meta.anchor.test",
                    "ordinary.word.test"
                ),
                token(8, 9, "source.test", "meta.anchor.test"),
            ]
        )
    }

    func testZeroWidthMatchStopsWithoutLoopingAndTimeLimitCanStopEarly() throws {
        let grammar = makeGrammar(
            patterns: [RawRule(name: "invalid.zero.width.test", match: "")]
        )

        let zeroWidth = try grammar.tokenizeLine("abc")
        XCTAssertFalse(zeroWidth.stoppedEarly)
        XCTAssertEqual(zeroWidth.ruleStack.depth, 1)
        XCTAssertEqual(zeroWidth.tokens, [token(0, 4, "source.test")])

        let timedOut = try grammar.tokenizeLine("abc", timeLimit: -1)
        XCTAssertTrue(timedOut.stoppedEarly)
        XCTAssertEqual(timedOut.tokens, [token(0, 4, "source.test")])
    }

    func testBinaryTokenizerReturnsPackedMetadataPairs() throws {
        let grammar = makeGrammar(
            patterns: [RawRule(name: "keyword.control.test", match: "if")]
        )

        let result = try grammar.tokenizeLine2("if x")

        XCTAssertFalse(result.stoppedEarly)
        XCTAssertEqual(result.tokens.count, 4)
        XCTAssertEqual(result.tokens[0], 0)
        XCTAssertEqual(result.tokens[2], 2)
        XCTAssertEqual(
            EncodedTokenMetadata.getLanguageID(result.tokens[1]),
            7
        )
    }
}

private func makeGrammar(
    patterns: [RawRule],
    injections: [String: RawRule]? = nil
) -> Grammar {
    Grammar(
        scopeName: "source.test",
        grammar: RawGrammar(
            scopeName: "source.test",
            patterns: patterns,
            injections: injections
        ),
        initialLanguage: 7,
        grammarRepository: TokenizerTestRepository()
    )
}

private func token(
    _ start: Int,
    _ end: Int,
    _ scopes: ScopeName...
) -> TextMateToken {
    TextMateToken(startIndex: start, endIndex: end, scopes: scopes)
}

private final class TokenizerTestRepository:
    TextMateGrammarRepositoryWithTheme
{
    func lookup(scopeName: ScopeName) -> RawGrammar? { nil }
    func injections(scopeName: ScopeName) -> [ScopeName] { [] }
    func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes? {
        guard scopePath.scopeName.hasPrefix("keyword.") else { return nil }
        return StyleAttributes(
            fontStyle: .bold,
            foregroundID: 3,
            backgroundID: 0
        )
    }

    func getDefaults() -> StyleAttributes {
        StyleAttributes(
            fontStyle: .none,
            foregroundID: 1,
            backgroundID: 2
        )
    }
}

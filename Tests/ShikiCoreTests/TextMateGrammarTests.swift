import XCTest
@testable import ShikiCore

final class TextMateGrammarTests: XCTestCase {
    func testRootRuleCompilationIsDeterministicAcrossRecursiveRegistrations() {
        let repository = MockGrammarRepository()
        let grammar = Grammar(
            scopeName: "source.test",
            grammar: RawGrammar(
                scopeName: "source.test",
                patterns: [RawRule(name: "constant.a", match: "a")]
            ),
            initialLanguage: 7,
            grammarRepository: repository
        )

        XCTAssertEqual(grammar.prepareForTokenization(), 1)
        XCTAssertEqual(grammar.prepareForTokenization(), 1)
        XCTAssertTrue(grammar.getRule(1) is IncludeOnlyRule)
        XCTAssertTrue(grammar.getRule(2) is MatchRule)
        XCTAssertEqual(
            grammar.getRule(1).getName(
                lineText: nil as String?,
                captureIndices: nil as [OnigCaptureIndex]?
            ),
            "source.test"
        )
    }

    func testInjectionPrioritiesSortStablyAndExternalGrammarsAreCached() {
        let right = injectionGrammar(
            scopeName: "injection.right",
            selector: "R:source.test"
        )
        let left = injectionGrammar(
            scopeName: "injection.left",
            selector: "L:source.test"
        )
        let normal = injectionGrammar(
            scopeName: "injection.normal",
            selector: "source.test"
        )
        let repository = MockGrammarRepository(
            grammars: [
                right.scopeName: right,
                left.scopeName: left,
                normal.scopeName: normal,
            ],
            injectionScopes: [right.scopeName, left.scopeName, normal.scopeName]
        )
        let grammar = Grammar(
            scopeName: "source.test",
            grammar: RawGrammar(scopeName: "source.test"),
            initialLanguage: 1,
            grammarRepository: repository
        )

        let injections = grammar.getInjections()
        XCTAssertEqual(injections.map(\.debugSelector), [
            "L:source.test",
            "source.test",
            "R:source.test",
        ])
        XCTAssertEqual(injections.map(\.priority), [-1, 0, 1])
        XCTAssertTrue(injections.allSatisfy { $0.matcher(["source.test.embedded"]) })
        XCTAssertEqual(grammar.getInjections().map(\.ruleID), injections.map(\.ruleID))

        let first = grammar.getExternalGrammar("injection.left")
        let second = grammar.getExternalGrammar("injection.left")
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first?.repository["$self"])
        XCTAssertNotNil(first?.repository["$base"])
        XCTAssertEqual(repository.lookupCounts["injection.left"], 1)
    }

    func testInitialStateMergesDefaultMetadataAndReusesPreviousState() throws {
        let repository = MockGrammarRepository(
            defaults: StyleAttributes(
                fontStyle: .bold,
                foregroundID: 5,
                backgroundID: 6
            )
        )
        let grammar = Grammar(
            scopeName: "source.test",
            grammar: RawGrammar(scopeName: "source.test"),
            initialLanguage: 7,
            grammarRepository: repository
        )

        let initial = grammar.stateForTokenizingLine(previousState: nil)
        XCTAssertTrue(initial.isFirstLine)
        XCTAssertEqual(initial.state.ruleID, 1)
        XCTAssertEqual(
            initial.state.contentNameScopesList?.getScopeNames(),
            ["source.test"]
        )

        let metadata = try XCTUnwrap(
            initial.state.contentNameScopesList?.tokenAttributes
        )
        XCTAssertEqual(EncodedTokenMetadata.getLanguageID(metadata), 7)
        XCTAssertEqual(EncodedTokenMetadata.getFontStyle(metadata), .bold)
        XCTAssertEqual(EncodedTokenMetadata.getForeground(metadata), 5)
        XCTAssertEqual(EncodedTokenMetadata.getBackground(metadata), 6)

        let pushed = initial.state.push(
            ruleID: 2,
            enterPos: 8,
            anchorPos: 3,
            beginRuleCapturedEOL: false,
            endRule: nil,
            nameScopesList: initial.state.nameScopesList,
            contentNameScopesList: initial.state.contentNameScopesList
        )
        let continued = grammar.stateForTokenizingLine(previousState: pushed)
        XCTAssertFalse(continued.isFirstLine)
        XCTAssertTrue(continued.state === pushed)
        XCTAssertEqual(pushed.getEnterPos(), -1)
        XCTAssertEqual(pushed.getAnchorPos(), -1)
        XCTAssertEqual(initial.state.getEnterPos(), -1)
    }

    func testGrammarLineTokensApplyConfiguredOverrides() {
        let repository = MockGrammarRepository()
        let grammar = Grammar(
            scopeName: "source.test",
            grammar: RawGrammar(scopeName: "source.test"),
            initialLanguage: 1,
            tokenTypes: ["string": .comment],
            balancedBracketSelectors: BalancedBracketSelectors(
                balancedBracketScopes: ["*"],
                unbalancedBracketScopes: []
            ),
            grammarRepository: repository
        )
        let tokens = grammar.makeLineTokens(
            emitBinaryTokens: true,
            lineText: "x\n"
        )
        tokens.produceFromScopes(
            scopeNames: ["source.test", "string.quoted.test"],
            tokenAttributes: 0,
            endIndex: 1
        )

        let result = tokens.getBinaryResult(
            fallbackScopeNames: [],
            fallbackTokenAttributes: 0,
            lineLength: 2
        )
        XCTAssertEqual(EncodedTokenMetadata.getTokenType(result[1]), .comment)
        XCTAssertTrue(EncodedTokenMetadata.containsBalancedBrackets(result[1]))
    }
}

private func injectionGrammar(
    scopeName: ScopeName,
    selector: String
) -> RawGrammar {
    RawGrammar(
        scopeName: scopeName,
        patterns: [RawRule(name: "meta.\(scopeName)", match: ".")],
        injectionSelector: selector
    )
}

private final class MockGrammarRepository: TextMateGrammarRepositoryWithTheme {
    private let grammars: [ScopeName: RawGrammar]
    private let injectionScopes: [ScopeName]
    private let defaults: StyleAttributes
    var lookupCounts: [ScopeName: Int] = [:]

    init(
        grammars: [ScopeName: RawGrammar] = [:],
        injectionScopes: [ScopeName] = [],
        defaults: StyleAttributes = StyleAttributes(
            fontStyle: .none,
            foregroundID: 1,
            backgroundID: 2
        )
    ) {
        self.grammars = grammars
        self.injectionScopes = injectionScopes
        self.defaults = defaults
    }

    func lookup(scopeName: ScopeName) -> RawGrammar? {
        lookupCounts[scopeName, default: 0] += 1
        return grammars[scopeName]
    }

    func injections(scopeName: ScopeName) -> [ScopeName] {
        injectionScopes
    }

    func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes? {
        nil
    }

    func getDefaults() -> StyleAttributes {
        defaults
    }
}

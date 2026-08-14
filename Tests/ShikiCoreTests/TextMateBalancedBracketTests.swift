import XCTest
@testable import ShikiCore

final class TextMateBalancedBracketTests: XCTestCase {
    func testWildcardMatchesAlwaysWithoutExclusions() {
        let selectors = BalancedBracketSelectors(
            balancedBracketScopes: ["*"],
            unbalancedBracketScopes: []
        )

        XCTAssertTrue(selectors.matchesAlways)
        XCTAssertFalse(selectors.matchesNever)
        XCTAssertTrue(selectors.match(["source.swift", "string.quoted.swift"]))
    }

    func testExclusionWinsOverInclusionAndWildcard() {
        let selectors = BalancedBracketSelectors(
            balancedBracketScopes: ["*", "meta.object"],
            unbalancedBracketScopes: ["string", "comment"]
        )

        XCTAssertFalse(selectors.matchesAlways)
        XCTAssertTrue(selectors.match(["source.swift", "meta.object.swift"]))
        XCTAssertFalse(
            selectors.match(["source.swift", "meta.object.swift", "string.quoted.swift"])
        )
    }

    func testEmptyIncludesMatchNever() {
        let selectors = BalancedBracketSelectors(
            balancedBracketScopes: [],
            unbalancedBracketScopes: ["comment"]
        )

        XCTAssertTrue(selectors.matchesNever)
        XCTAssertFalse(selectors.match(["source.swift"]))
    }
}

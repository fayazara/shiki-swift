import XCTest
@testable import ShikiCore

final class TextMateScopeSelectorTests: XCTestCase {
    func testMatchesVscodeTextMateSelectorCases() {
        let cases: [(expression: String, input: [String], expected: Bool)] = [
            ("foo", ["foo"], true),
            ("foo", ["bar"], false),
            ("- foo", ["foo"], false),
            ("- foo", ["bar"], true),
            ("- - foo", ["bar"], false),
            ("bar foo", ["foo"], false),
            ("bar foo", ["bar"], false),
            ("bar foo", ["bar", "foo"], true),
            ("bar - foo", ["bar"], true),
            ("bar - foo", ["foo", "bar"], false),
            ("bar - foo", ["foo"], false),
            ("bar, foo", ["foo"], true),
            ("bar, foo", ["bar"], true),
            ("bar, foo", ["bar", "foo"], true),
            ("bar, -foo", ["bar", "foo"], true),
            ("bar, -foo", ["yo"], true),
            ("bar, -foo", ["foo"], false),
            ("(foo)", ["foo"], true),
            ("(foo - bar)", ["foo"], true),
            ("(foo - bar)", ["foo", "bar"], false),
            ("foo bar - (yo man)", ["foo", "bar"], true),
            ("foo bar - (yo man)", ["foo", "bar", "yo"], true),
            ("foo bar - (yo man)", ["foo", "bar", "yo", "man"], false),
            ("foo bar - (yo | man)", ["foo", "bar", "yo", "man"], false),
            ("foo bar - (yo | man)", ["foo", "bar", "yo"], false),
            (
                "R:text.html - (comment.block, text.html source)",
                ["text.html", "bar", "source"],
                false
            ),
            (
                "text.html.php - (meta.embedded | meta.tag), "
                    + "L:text.html.php meta.tag, L:source.js.embedded.html",
                ["text.html.php", "bar", "source.js"],
                true
            ),
        ]

        for testCase in cases {
            let matchers = createMatchers(testCase.expression, matchesName: exactStackMatch)
            let actual = matchers.contains { $0.matcher(testCase.input) }
            XCTAssertEqual(
                actual,
                testCase.expected,
                "selector: \(testCase.expression), input: \(testCase.input)"
            )
        }
    }

    func testExtractsIndependentTopLevelPriorities() {
        let matchers = ScopeSelector.parse("R:source.ts, source.js, L:text.html")

        XCTAssertEqual(matchers.count, 3)
        XCTAssertEqual(matchers.map(\.priority), [1, 0, -1])
        XCTAssertTrue(matchers[0].matcher(["source.ts"]))
        XCTAssertTrue(matchers[1].matcher(["source.js"]))
        XCTAssertTrue(matchers[2].matcher(["text.html"]))
    }

    func testStandardScopeMatchingAllowsDottedSpecializationAndOrderedAncestors() {
        XCTAssertTrue(
            matchesScopeNames(
                ["source.ts", "meta.function", "variable"],
                scopes: ["source.ts", "meta.function.arrow.ts", "variable.parameter.ts"]
            )
        )
        XCTAssertFalse(
            matchesScopeNames(
                ["source.ts", "variable"],
                scopes: ["variable.parameter.ts", "source.ts"]
            )
        )
        XCTAssertFalse(matchesScopeNames(["source.ts"], scopes: ["source.tsx"]))
    }

    func testTokenizerUsesUTF16RangeWhenSkippingUnsupportedCharacters() {
        let matchers = createMatchers("🙂foo", matchesName: exactStackMatch)

        XCTAssertEqual(matchers.count, 1)
        XCTAssertTrue(matchers[0].matcher(["foo"]))
    }

    private func exactStackMatch(_ identifiers: [String], _ scopes: [String]) -> Bool {
        var nextScopeIndex = 0
        return identifiers.allSatisfy { identifier in
            while nextScopeIndex < scopes.count {
                defer { nextScopeIndex += 1 }
                if scopes[nextScopeIndex] == identifier {
                    return true
                }
            }
            return false
        }
    }
}

/*---------------------------------------------------------
 * Copyright (C) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------*/

/// Selects which TextMate scopes may contain balanced brackets.
public final class BalancedBracketSelectors {
    private let balancedBracketScopes: [Matcher<[ScopeName]>]
    private let unbalancedBracketScopes: [Matcher<[ScopeName]>]
    private let allowAny: Bool

    public init(
        balancedBracketScopes: [String],
        unbalancedBracketScopes: [String]
    ) {
        var allowAny = false
        var included: [Matcher<[ScopeName]>] = []
        for selector in balancedBracketScopes {
            if selector == "*" {
                allowAny = true
                continue
            }
            included.append(contentsOf: createMatchers(
                selector,
                matchesName: matchesScopeNames
            ).map(\.matcher))
        }

        self.allowAny = allowAny
        self.balancedBracketScopes = included
        self.unbalancedBracketScopes = unbalancedBracketScopes.flatMap {
            createMatchers($0, matchesName: matchesScopeNames).map(\.matcher)
        }
    }

    public var matchesAlways: Bool {
        allowAny && unbalancedBracketScopes.isEmpty
    }

    public var matchesNever: Bool {
        balancedBracketScopes.isEmpty && !allowAny
    }

    public func match(_ scopes: [ScopeName]) -> Bool {
        for excluder in unbalancedBracketScopes where excluder(scopes) {
            return false
        }
        for includer in balancedBracketScopes where includer(scopes) {
            return true
        }
        return allowAny
    }
}

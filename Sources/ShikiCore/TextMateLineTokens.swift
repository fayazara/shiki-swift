/*---------------------------------------------------------
 * Copyright (C) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------*/

/// One scope-bearing token emitted by TextMate's debug/non-binary API.
public struct TextMateToken: Equatable, Sendable {
    public var startIndex: Int
    public var endIndex: Int
    public var scopes: [ScopeName]

    public init(startIndex: Int, endIndex: Int, scopes: [ScopeName]) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.scopes = scopes
    }
}

/// Accumulates contiguous TextMate tokens for one UTF-16-indexed line.
///
/// The scanner-facing overloads accepting `AttributedScopeStack` and
/// `StateStackImpl` live alongside those types. This core surface makes the
/// token emitter independently testable and keeps the eventual tokenizer loop
/// free of metadata policy.
public final class LineTokens {
    private let emitBinaryTokens: Bool
    private var tokens: [TextMateToken] = []
    private var binaryTokens: [UInt32] = []
    private var lastTokenEndIndex = 0
    private let tokenTypeOverrides: [TokenTypeMatcher]
    private let balancedBracketSelectors: BalancedBracketSelectors?

    public init(
        emitBinaryTokens: Bool,
        lineText: String,
        tokenTypeOverrides: [TokenTypeMatcher],
        balancedBracketSelectors: BalancedBracketSelectors?
    ) {
        self.emitBinaryTokens = emitBinaryTokens
        self.tokenTypeOverrides = tokenTypeOverrides
        self.balancedBracketSelectors = balancedBracketSelectors
        // `lineText` is retained by upstream only while debug logging is on.
        _ = lineText
    }

    /// Emits through an attributed scope stack after its names and metadata
    /// have been resolved. All positions are UTF-16 code-unit offsets.
    public func produceFromScopes(
        scopeNames: [ScopeName],
        tokenAttributes: EncodedTokenAttributes,
        endIndex: Int
    ) {
        guard lastTokenEndIndex < endIndex else {
            return
        }

        if emitBinaryTokens {
            produceBinary(
                scopeNames: scopeNames,
                tokenAttributes: tokenAttributes,
                endIndex: endIndex
            )
        } else {
            tokens.append(
                TextMateToken(
                    startIndex: lastTokenEndIndex,
                    endIndex: endIndex,
                    scopes: scopeNames
                )
            )
            lastTokenEndIndex = endIndex
        }
    }

    public func getResult(
        fallbackScopeNames: [ScopeName],
        fallbackTokenAttributes: EncodedTokenAttributes,
        lineLength: Int
    ) -> [TextMateToken] {
        if tokens.last?.startIndex == lineLength - 1 {
            tokens.removeLast()
        }

        if tokens.isEmpty {
            lastTokenEndIndex = -1
            produceFromScopes(
                scopeNames: fallbackScopeNames,
                tokenAttributes: fallbackTokenAttributes,
                endIndex: lineLength
            )
            tokens[tokens.count - 1].startIndex = 0
        }
        return tokens
    }

    public func getBinaryResult(
        fallbackScopeNames: [ScopeName],
        fallbackTokenAttributes: EncodedTokenAttributes,
        lineLength: Int
    ) -> [UInt32] {
        if binaryTokens.count >= 2,
           binaryTokens[binaryTokens.count - 2] == UInt32(truncatingIfNeeded: lineLength - 1)
        {
            binaryTokens.removeLast(2)
        }

        if binaryTokens.isEmpty {
            lastTokenEndIndex = -1
            produceFromScopes(
                scopeNames: fallbackScopeNames,
                tokenAttributes: fallbackTokenAttributes,
                endIndex: lineLength
            )
            binaryTokens[binaryTokens.count - 2] = 0
        }
        return binaryTokens
    }

    private func produceBinary(
        scopeNames: [ScopeName],
        tokenAttributes: EncodedTokenAttributes,
        endIndex: Int
    ) {
        var metadata = tokenAttributes
        var containsBalancedBrackets = balancedBracketSelectors?.matchesAlways ?? false

        let mustEvaluateScopes = !tokenTypeOverrides.isEmpty
            || balancedBracketSelectors.map {
                !$0.matchesAlways && !$0.matchesNever
            } == true

        if mustEvaluateScopes {
            for tokenType in tokenTypeOverrides where tokenType.matcher(scopeNames) {
                metadata = EncodedTokenMetadata.set(
                    metadata,
                    tokenType: toOptionalTokenType(tokenType.type)
                )
            }
            if let balancedBracketSelectors {
                containsBalancedBrackets = balancedBracketSelectors.match(scopeNames)
            }
        }

        if containsBalancedBrackets {
            metadata = EncodedTokenMetadata.set(
                metadata,
                containsBalancedBrackets: true
            )
        }

        if binaryTokens.last == metadata {
            lastTokenEndIndex = endIndex
            return
        }

        binaryTokens.append(UInt32(truncatingIfNeeded: lastTokenEndIndex))
        binaryTokens.append(metadata)
        lastTokenEndIndex = endIndex
    }
}

public extension LineTokens {
    /// Scanner-facing compatibility overload matching `vscode-textmate`.
    func produce(_ stack: StateStackImpl, endIndex: Int) {
        produceFromScopes(stack.contentNameScopesList, endIndex: endIndex)
    }

    /// Scanner-facing compatibility overload matching `vscode-textmate`.
    func produceFromScopes(
        _ scopesList: AttributedScopeStack?,
        endIndex: Int
    ) {
        produceFromScopes(
            scopeNames: scopesList?.getScopeNames() ?? [],
            tokenAttributes: scopesList?.tokenAttributes ?? 0,
            endIndex: endIndex
        )
    }

    func getResult(
        _ stack: StateStackImpl,
        lineLength: Int
    ) -> [TextMateToken] {
        getResult(
            fallbackScopeNames: stack.contentNameScopesList?.getScopeNames() ?? [],
            fallbackTokenAttributes: stack.contentNameScopesList?.tokenAttributes ?? 0,
            lineLength: lineLength
        )
    }

    func getBinaryResult(
        _ stack: StateStackImpl,
        lineLength: Int
    ) -> [UInt32] {
        getBinaryResult(
            fallbackScopeNames: stack.contentNameScopesList?.getScopeNames() ?? [],
            fallbackTokenAttributes: stack.contentNameScopesList?.tokenAttributes ?? 0,
            lineLength: lineLength
        )
    }
}

import Foundation

/// Language and standard-token metadata inferred from one TextMate scope.
public struct BasicScopeAttributes: Equatable, Sendable {
    public let languageID: Int
    public let tokenType: OptionalStandardTokenType

    /// Compatibility spelling matching `vscode-textmate`.
    public var languageId: Int { languageID }

    public init(
        languageID: Int,
        tokenType: OptionalStandardTokenType
    ) {
        self.languageID = languageID
        self.tokenType = tokenType
    }

    public init(_ languageID: Int, _ tokenType: OptionalStandardTokenType) {
        self.init(languageID: languageID, tokenType: tokenType)
    }
}

/// Infers embedded-language IDs and standard token types from scope names.
public struct BasicScopeAttributesProvider: Sendable {
    private let defaultAttributes: BasicScopeAttributes
    private let embeddedLanguages: [(scope: ScopeName, languageID: Int)]

    public init(
        initialLanguageID: Int,
        embeddedLanguages: [ScopeName: Int]? = nil
    ) {
        defaultAttributes = BasicScopeAttributes(initialLanguageID, .notSet)

        // The upstream matcher sorts escaped scope strings and reverses them
        // before building its regular expression. Scope names are ASCII in
        // TextMate grammars, so descending String order is equivalent here.
        self.embeddedLanguages = (embeddedLanguages ?? [:])
            .map { (scope: $0.key, languageID: $0.value) }
            .sorted { $0.scope > $1.scope }
    }

    /// Compatibility initializer matching the TypeScript constructor label.
    public init(
        initialLanguageId: Int,
        embeddedLanguages: [ScopeName: Int]? = nil
    ) {
        self.init(
            initialLanguageID: initialLanguageId,
            embeddedLanguages: embeddedLanguages
        )
    }

    public func getDefaultAttributes() -> BasicScopeAttributes {
        defaultAttributes
    }

    public func getBasicScopeAttributes(
        _ scopeName: ScopeName?
    ) -> BasicScopeAttributes {
        guard let scopeName else {
            return BasicScopeAttributes(0, .other)
        }

        return BasicScopeAttributes(
            languageID(for: scopeName),
            standardTokenType(for: scopeName)
        )
    }

    private func languageID(for scopeName: ScopeName) -> Int {
        for entry in embeddedLanguages {
            if scopeName == entry.scope || scopeName.hasPrefix("\(entry.scope).") {
                return entry.languageID
            }
        }
        return 0
    }

    private func standardTokenType(
        for scopeName: ScopeName
    ) -> OptionalStandardTokenType {
        let source = Array(scopeName.utf16)
        let candidates: [(units: [UInt16], type: OptionalStandardTokenType)] = [
            (Array("comment".utf16), .comment),
            (Array("string".utf16), .string),
            (Array("regex".utf16), .regex),
            (Array("meta.embedded".utf16), .other),
        ]

        for start in source.indices {
            for candidate in candidates {
                let end = start + candidate.units.count
                guard end <= source.count else { continue }
                guard source[start..<end].elementsEqual(candidate.units) else {
                    continue
                }
                guard isWordBoundary(in: source, at: start),
                      isWordBoundary(in: source, at: end) else {
                    continue
                }
                return candidate.type
            }
        }

        return .notSet
    }
}

/// The grammar seam used while attributing persistent scope stacks.
///
/// The grammar runtime can conform by forwarding `getMetadataForScope` to its
/// `BasicScopeAttributesProvider` and `themeMatch` to `Theme.match`.
public protocol AttributedScopeStackMetadataProvider: AnyObject {
    func getMetadataForScope(_ scopeName: ScopeName?) -> BasicScopeAttributes
    func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes?
}

/// A ready-to-use metadata provider composed from the currently compiled
/// basic-scope and theme implementations.
public final class TextMateScopeMetadataProvider: AttributedScopeStackMetadataProvider {
    public let basicScopeAttributesProvider: BasicScopeAttributesProvider
    public let theme: Theme

    public init(
        basicScopeAttributesProvider: BasicScopeAttributesProvider,
        theme: Theme
    ) {
        self.basicScopeAttributesProvider = basicScopeAttributesProvider
        self.theme = theme
    }

    public func getMetadataForScope(
        _ scopeName: ScopeName?
    ) -> BasicScopeAttributes {
        basicScopeAttributesProvider.getBasicScopeAttributes(scopeName)
    }

    public func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes? {
        theme.match(scopePath)
    }
}

/// One serializable extension frame of an attributed scope stack.
public struct AttributedScopeStackFrame: Codable, Equatable, Sendable {
    public var encodedTokenAttributes: EncodedTokenAttributes
    public var scopeNames: [ScopeName]

    public init(
        encodedTokenAttributes: EncodedTokenAttributes,
        scopeNames: [ScopeName]
    ) {
        self.encodedTokenAttributes = encodedTokenAttributes
        self.scopeNames = scopeNames
    }
}

/// A persistent linked scope stack carrying fully merged token metadata.
public final class AttributedScopeStack: @unchecked Sendable,
    Equatable, CustomStringConvertible
{
    public let parent: AttributedScopeStack?
    public let scopePath: ScopeStack
    public let tokenAttributes: EncodedTokenAttributes

    public var scopeName: ScopeName { scopePath.scopeName }

    private init(
        parent: AttributedScopeStack?,
        scopePath: ScopeStack,
        tokenAttributes: EncodedTokenAttributes
    ) {
        self.parent = parent
        self.scopePath = scopePath
        self.tokenAttributes = tokenAttributes
    }

    public static func fromExtension(
        _ namesScopeList: AttributedScopeStack?,
        _ contentNameScopesList: [AttributedScopeStackFrame]
    ) -> AttributedScopeStack? {
        var current = namesScopeList
        var scopeNames = namesScopeList?.scopePath

        for frame in contentNameScopesList {
            scopeNames = ScopeStack.push(scopeNames, frame.scopeNames)
            guard let scopeNames else {
                // A valid frame always extends the path by at least one scope.
                // Returning nil matches the runtime value of TypeScript's
                // non-null assertion for malformed empty-root input.
                current = nil
                continue
            }
            current = AttributedScopeStack(
                parent: current,
                scopePath: scopeNames,
                tokenAttributes: frame.encodedTokenAttributes
            )
        }

        return current
    }

    public static func createRoot(
        _ scopeName: ScopeName,
        _ tokenAttributes: EncodedTokenAttributes
    ) -> AttributedScopeStack {
        AttributedScopeStack(
            parent: nil,
            scopePath: ScopeStack(parent: nil, scopeName: scopeName),
            tokenAttributes: tokenAttributes
        )
    }

    public static func createRootAndLookUpScopeName(
        _ scopeName: ScopeName,
        _ tokenAttributes: EncodedTokenAttributes,
        _ provider: any AttributedScopeStackMetadataProvider
    ) -> AttributedScopeStack {
        let rawRootMetadata = provider.getMetadataForScope(scopeName)
        let scopePath = ScopeStack(parent: nil, scopeName: scopeName)
        let rootStyle = provider.themeMatch(scopePath)
        let resolvedTokenAttributes = mergeAttributes(
            tokenAttributes,
            rawRootMetadata,
            rootStyle
        )

        return AttributedScopeStack(
            parent: nil,
            scopePath: scopePath,
            tokenAttributes: resolvedTokenAttributes
        )
    }

    public static func == (
        lhs: AttributedScopeStack,
        rhs: AttributedScopeStack
    ) -> Bool {
        equals(lhs, rhs)
    }

    public func equals(_ other: AttributedScopeStack) -> Bool {
        Self.equals(self, other)
    }

    public static func equals(
        _ first: AttributedScopeStack?,
        _ second: AttributedScopeStack?
    ) -> Bool {
        var left = first
        var right = second

        while true {
            switch (left, right) {
            case (nil, nil):
                return true
            case (nil, _), (_, nil):
                return false
            case let (leftValue?, rightValue?):
                if leftValue === rightValue {
                    return true
                }
                if leftValue.scopeName != rightValue.scopeName
                    || leftValue.tokenAttributes != rightValue.tokenAttributes {
                    return false
                }
                left = leftValue.parent
                right = rightValue.parent
            }
        }
    }

    /// Merges basic scope and theme styling into existing packed metadata.
    public static func mergeAttributes(
        _ existingTokenAttributes: EncodedTokenAttributes,
        _ basicScopeAttributes: BasicScopeAttributes,
        _ styleAttributes: StyleAttributes?
    ) -> EncodedTokenAttributes {
        let fontStyle = styleAttributes?.fontStyle ?? .notSet
        let foreground = styleAttributes?.foregroundID ?? 0
        let background = styleAttributes?.backgroundID ?? 0

        return EncodedTokenMetadata.set(
            existingTokenAttributes,
            languageID: basicScopeAttributes.languageID,
            tokenType: basicScopeAttributes.tokenType,
            containsBalancedBrackets: nil,
            fontStyle: fontStyle,
            foreground: foreground,
            background: background
        )
    }

    public func pushAttributed(
        _ scopePath: ScopePath?,
        _ provider: any AttributedScopeStackMetadataProvider
    ) -> AttributedScopeStack {
        guard let scopePath else {
            return self
        }

        if !scopePath.contains(" ") {
            return Self.pushAttributed(self, scopePath, provider)
        }

        var result = self
        let scopes = scopePath.split(
            separator: " ",
            omittingEmptySubsequences: false
        )
        for scope in scopes {
            result = Self.pushAttributed(result, String(scope), provider)
        }
        return result
    }

    public func getScopeNames() -> [ScopeName] {
        scopePath.getSegments()
    }

    public func getExtensionIfDefined(
        _ base: AttributedScopeStack?
    ) -> [AttributedScopeStackFrame]? {
        var result: [AttributedScopeStackFrame] = []
        var current: AttributedScopeStack? = self

        while let value = current, value !== base {
            guard let scopeNames = value.scopePath.getExtensionIfDefined(
                value.parent?.scopePath
            ) else {
                return nil
            }
            result.append(
                AttributedScopeStackFrame(
                    encodedTokenAttributes: value.tokenAttributes,
                    scopeNames: scopeNames
                )
            )
            current = value.parent
        }

        return current === base ? result.reversed() : nil
    }

    public var description: String {
        getScopeNames().joined(separator: " ")
    }

    private static func pushAttributed(
        _ target: AttributedScopeStack,
        _ scopeName: ScopeName,
        _ provider: any AttributedScopeStackMetadataProvider
    ) -> AttributedScopeStack {
        let rawMetadata = provider.getMetadataForScope(scopeName)
        let newPath = target.scopePath.push(scopeName)
        let scopeThemeMatchResult = provider.themeMatch(newPath)
        let metadata = mergeAttributes(
            target.tokenAttributes,
            rawMetadata,
            scopeThemeMatchResult
        )

        return AttributedScopeStack(
            parent: target,
            scopePath: newPath,
            tokenAttributes: metadata
        )
    }
}

/// Compatibility name used by older Shiki releases for the packed metadata
/// accessors now named `EncodedTokenMetadata`.
public typealias StackElementMetadata = EncodedTokenMetadata

private func isWordBoundary(in source: [UInt16], at index: Int) -> Bool {
    let previousIsWord = index > 0 && isASCIIWord(source[index - 1])
    let nextIsWord = index < source.count && isASCIIWord(source[index])
    return previousIsWord != nextIsWord
}

private func isASCIIWord(_ codeUnit: UInt16) -> Bool {
    switch codeUnit {
    case 0x0030...0x0039, 0x0041...0x005A, 0x005F, 0x0061...0x007A:
        true
    default:
        false
    }
}

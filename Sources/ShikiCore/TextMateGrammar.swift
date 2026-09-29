/*---------------------------------------------------------
 * Copyright (C) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------*/

import Foundation

/// Theme operations required by the TextMate grammar runtime.
public protocol TextMateThemeProvider {
    func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes?
    func getDefaults() -> StyleAttributes
}

extension Theme: TextMateThemeProvider {
    public func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes? {
        match(scopePath)
    }
}

/// Raw grammar lookup and injection contributions required while compiling a
/// root grammar.
public protocol TextMateGrammarRepository {
    func lookup(scopeName: ScopeName) -> RawGrammar?
    func injections(scopeName: ScopeName) -> [ScopeName]
}

/// A repository in `vscode-textmate` also serves the active theme.
public protocol TextMateGrammarRepositoryWithTheme:
    TextMateGrammarRepository, TextMateThemeProvider {}

/// Holds a grammar's repository either strongly (standalone grammars) or
/// weakly (grammars owned by a ``TextMateRegistry``, which would otherwise
/// form a retain cycle with the registry).
final class GrammarRepositoryReference {
    private let strong: (any TextMateGrammarRepositoryWithTheme)?
    private weak var weak: (AnyObject & TextMateGrammarRepositoryWithTheme)?

    init(strong repository: any TextMateGrammarRepositoryWithTheme) {
        strong = repository
    }

    init(weak repository: AnyObject & TextMateGrammarRepositoryWithTheme) {
        strong = nil
        weak = repository
    }

    var value: (any TextMateGrammarRepositoryWithTheme)? {
        strong ?? weak
    }
}

/// Theme provider used after an owning registry has been released.
private struct DetachedThemeProvider: TextMateThemeProvider {
    func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes? { nil }
    func getDefaults() -> StyleAttributes {
        StyleAttributes(fontStyle: .none, foregroundID: 0, backgroundID: 0)
    }
}

/// One compiled injection selector and the rule it activates.
public struct Injection {
    public let debugSelector: String
    public let matcher: Matcher<[ScopeName]>

    /// `-1` for `L:`, `1` for `R:`, and zero for the default priority.
    public let priority: Int
    public let ruleID: RuleID
    public let grammar: RawGrammar

    /// Compatibility spelling matching `vscode-textmate`.
    public var ruleId: RuleID { ruleID }

    public init(
        debugSelector: String,
        matcher: @escaping Matcher<[ScopeName]>,
        priority: Int,
        ruleID: RuleID,
        grammar: RawGrammar
    ) {
        self.debugSelector = debugSelector
        self.matcher = matcher
        self.priority = priority
        self.ruleID = ruleID
        self.grammar = grammar
    }
}

/// Compiled token-type selector used by the binary token emitter.
public struct TokenTypeMatcher {
    public let matcher: Matcher<[ScopeName]>
    public let type: StandardTokenType

    public init(
        matcher: @escaping Matcher<[ScopeName]>,
        type: StandardTokenType
    ) {
        self.matcher = matcher
        self.type = type
    }
}

/// Native shell around `vscode-textmate`'s rule compiler and grammar registry.
///
/// Line scanning is deliberately split into a separate tokenizer. The methods
/// here expose the exact preparation seams it needs: deterministic root-rule
/// compilation, initial metadata, Oniguruma construction, injection lookup,
/// and line-token creation.
public final class Grammar:
    TextMateRuleFactoryHelper,
    TextMateRuleCompilerContext,
    TextMateOnigLibrary,
    AttributedScopeStackMetadataProvider
{
    public let rootScopeName: ScopeName
    public let balancedBracketSelectors: BalancedBracketSelectors?

    private var rootID: RuleID?
    private var lastRuleID = 0
    private var ruleIDToDescriptor: [Rule?] = [nil]
    private var includedGrammars: [ScopeName: RawGrammar] = [:]
    /// External scopes that were referenced but not registered when a rule
    /// was compiled. Registering one of them refreshes the affected rules.
    private var unresolvedExternalScopes: Set<ScopeName> = []
    private let repositoryReference: GrammarRepositoryReference
    private let grammar: RawGrammar
    private var cachedInjections: [Injection]?
    private var cachedInjectionScopeNames: [ScopeName] = []
    private let basicScopeAttributesProvider: BasicScopeAttributesProvider
    private let onigLibrary: any TextMateOnigLibrary
    private let ruleFactory = RuleFactory()
    private let tokenTypeMatchers: [TokenTypeMatcher]

    private var grammarRepository: (any TextMateGrammarRepositoryWithTheme)? {
        repositoryReference.value
    }

    public var themeProvider: any TextMateThemeProvider {
        grammarRepository ?? DetachedThemeProvider()
    }

    public convenience init(
        scopeName: ScopeName,
        grammar: RawGrammar,
        initialLanguage: Int,
        embeddedLanguages: EmbeddedLanguagesMap? = nil,
        tokenTypes: TokenTypeMap? = nil,
        balancedBracketSelectors: BalancedBracketSelectors? = nil,
        grammarRepository: any TextMateGrammarRepositoryWithTheme,
        onigLibrary: any TextMateOnigLibrary = NativeTextMateOnigLibrary()
    ) {
        self.init(
            scopeName: scopeName,
            grammar: grammar,
            initialLanguage: initialLanguage,
            embeddedLanguages: embeddedLanguages,
            tokenTypes: tokenTypes,
            balancedBracketSelectors: balancedBracketSelectors,
            repositoryReference: GrammarRepositoryReference(strong: grammarRepository),
            onigLibrary: onigLibrary
        )
    }

    init(
        scopeName: ScopeName,
        grammar: RawGrammar,
        initialLanguage: Int,
        embeddedLanguages: EmbeddedLanguagesMap?,
        tokenTypes: TokenTypeMap?,
        balancedBracketSelectors: BalancedBracketSelectors?,
        repositoryReference: GrammarRepositoryReference,
        onigLibrary: any TextMateOnigLibrary
    ) {
        rootScopeName = scopeName
        self.balancedBracketSelectors = balancedBracketSelectors
        self.repositoryReference = repositoryReference
        self.grammar = initializeGrammar(grammar, base: nil)
        self.onigLibrary = onigLibrary
        basicScopeAttributesProvider = BasicScopeAttributesProvider(
            initialLanguageID: initialLanguage,
            embeddedLanguages: embeddedLanguages
        )

        var compiledTokenTypes: [TokenTypeMatcher] = []
        // Sorted so overlapping selectors resolve identically in every run.
        let tokenTypes = tokenTypes ?? [:]
        for selector in orderedKeys(of: tokenTypes, preferredOrder: nil) {
            let type = tokenTypes[selector]!
            for parsed in createMatchers(selector, matchesName: matchesScopeNames) {
                compiledTokenTypes.append(
                    TokenTypeMatcher(matcher: parsed.matcher, type: type)
                )
            }
        }
        tokenTypeMatchers = compiledTokenTypes
    }

    deinit {
        dispose()
    }

    public func dispose() {
        for rule in ruleIDToDescriptor.compactMap({ $0 }) {
            rule.dispose()
        }
    }

    public func createOnigScanner(
        _ sources: [String]
    ) throws -> any TextMateOnigScanner {
        try onigLibrary.createOnigScanner(sources)
    }

    public func createOnigString(_ string: String) -> OnigString {
        onigLibrary.createOnigString(string)
    }

    public func getMetadataForScope(
        _ scope: ScopeName?
    ) -> BasicScopeAttributes {
        basicScopeAttributesProvider.getBasicScopeAttributes(scope)
    }

    public func getMetadataForScope(
        _ scope: ScopeName
    ) -> BasicScopeAttributes {
        basicScopeAttributesProvider.getBasicScopeAttributes(scope)
    }

    public func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes? {
        themeProvider.themeMatch(scopePath)
    }

    public func getDefaultMetadata() -> EncodedTokenAttributes {
        let basic = basicScopeAttributesProvider.getDefaultAttributes()
        let style = themeProvider.getDefaults()
        return EncodedTokenMetadata.set(
            0,
            languageID: basic.languageID,
            tokenType: basic.tokenType,
            fontStyle: style.fontStyle,
            foreground: style.foregroundID,
            background: style.backgroundID
        )
    }

    /// Compiles the root descriptor before collecting injections. This order
    /// is observable in rule IDs and matches the renderer/worker determinism
    /// guarantee in `vscode-textmate`.
    @discardableResult
    public func prepareForTokenization() -> RuleID {
        if let rootID {
            return rootID
        }
        guard let root = grammar.repository["$self"] else {
            preconditionFailure("Initialized TextMate grammar has no $self rule")
        }
        let result = ruleFactory.getCompiledRuleID(
            root,
            helper: self,
            repository: grammar.repository
        )
        rootID = result
        _ = getInjections()
        return result
    }

    public func makeLineTokens(
        emitBinaryTokens: Bool,
        lineText: String
    ) -> LineTokens {
        LineTokens(
            emitBinaryTokens: emitBinaryTokens,
            lineText: lineText,
            tokenTypeOverrides: tokenTypeMatchers,
            balancedBracketSelectors: balancedBracketSelectors
        )
    }

    /// Creates or resets the persistent state consumed by the line tokenizer.
    /// The boolean is true only for the first line, matching `_tokenize`.
    public func stateForTokenizingLine(
        previousState: StateStackImpl?
    ) -> (state: StateStackImpl, isFirstLine: Bool) {
        if let previousState, previousState !== StateStackImpl.NULL {
            return (previousState.resettingLinePositions(), false)
        }

        let rootRuleID = prepareForTokenization()
        let rootScopeName = getRule(rootRuleID).getName(
            lineText: nil,
            captureIndices: nil
        )
        let defaultMetadata = getDefaultMetadata()
        let scopeList: AttributedScopeStack
        if let rootScopeName {
            scopeList = AttributedScopeStack.createRootAndLookUpScopeName(
                rootScopeName,
                defaultMetadata,
                self
            )
        } else {
            scopeList = AttributedScopeStack.createRoot(
                "unknown",
                defaultMetadata
            )
        }

        return (
            StateStackImpl(
                parent: nil,
                ruleID: rootRuleID,
                enterPos: -1,
                anchorPos: -1,
                beginRuleCapturedEOL: false,
                endRule: nil,
                nameScopesList: scopeList,
                contentNameScopesList: scopeList
            ),
            true
        )
    }

    /// Updates an already compiled grammar after its repository gained new
    /// raw grammars or injection contributions.
    ///
    /// Unlike recompiling from scratch, this keeps every existing rule ID
    /// valid: previously dropped includes are resolved into newly allocated
    /// rules and scanners are rebuilt lazily. Grammar states created before
    /// the change can therefore continue tokenizing with this grammar.
    public func refreshAfterRepositoryChange(addedScopeNames: Set<ScopeName>) {
        let resolvable = unresolvedExternalScopes.intersection(addedScopeNames)
        if !resolvable.isEmpty {
            unresolvedExternalScopes.subtract(resolvable)
            if ruleFactory.refreshIncompletePatterns(helper: self) {
                // Parent rules flatten included rules into their scanners, so
                // every cached scanner may be stale. They are rebuilt lazily.
                for rule in ruleIDToDescriptor.compactMap({ $0 }) {
                    rule.dispose()
                }
            }
        }

        if cachedInjections != nil {
            let current = grammarRepository?.injections(scopeName: rootScopeName) ?? []
            if current != cachedInjectionScopeNames
                || !resolvable.isDisjoint(with: current)
            {
                cachedInjections = nil
                _ = getInjections()
            }
        }
    }

    public func getInjections() -> [Injection] {
        if let cachedInjections {
            return cachedInjections
        }
        let result = collectInjections()
        cachedInjections = result
        return result
    }

    public func registerRule(_ factory: (RuleID) -> Rule) -> Rule {
        lastRuleID += 1
        let id = lastRuleID

        // Reserve the actual numeric slot before compiling nested rules. A
        // recursive factory can register additional descriptors before this
        // factory returns.
        while ruleIDToDescriptor.count <= id {
            ruleIDToDescriptor.append(nil)
        }
        let result = factory(id)
        ruleIDToDescriptor[id] = result
        return result
    }

    public func rule(with ruleID: RuleID) -> Rule? {
        guard ruleID >= 0, ruleID < ruleIDToDescriptor.count else {
            return nil
        }
        return ruleIDToDescriptor[ruleID]
    }

    /// Compatibility spelling matching `vscode-textmate`.
    public func getRule(_ ruleID: RuleID) -> Rule {
        guard let result = rule(with: ruleID) else {
            preconditionFailure("No compiled TextMate rule for id \(ruleID)")
        }
        return result
    }

    public func externalGrammar(
        scopeName: String,
        repository: RawRepository
    ) -> RawGrammar? {
        getExternalGrammar(scopeName, repository: repository)
    }

    public func getExternalGrammar(
        _ scopeName: ScopeName,
        repository: RawRepository? = nil
    ) -> RawGrammar? {
        if let cached = includedGrammars[scopeName] {
            return cached
        }
        guard let raw = grammarRepository?.lookup(scopeName: scopeName) else {
            unresolvedExternalScopes.insert(scopeName)
            return nil
        }

        let initialized = initializeGrammar(raw, base: repository?["$base"])
        includedGrammars[scopeName] = initialized
        return initialized
    }

    private func collectInjections() -> [Injection] {
        var collected: [(injection: Injection, index: Int)] = []

        func append(selector: String, rule: RawRule, source: RawGrammar) {
            let ruleID = ruleFactory.getCompiledRuleID(
                rule,
                helper: self,
                repository: source.repository
            )
            for parsed in createMatchers(selector, matchesName: matchesScopeNames) {
                collected.append((
                    Injection(
                        debugSelector: selector,
                        matcher: parsed.matcher,
                        priority: parsed.priority,
                        ruleID: ruleID,
                        grammar: source
                    ),
                    collected.count
                ))
            }
        }

        for (selector, rule) in grammar.orderedInjections {
            append(selector: selector, rule: rule, source: grammar)
        }

        let injectionScopeNames = grammarRepository?.injections(
            scopeName: rootScopeName
        ) ?? []
        cachedInjectionScopeNames = injectionScopeNames
        for injectionScopeName in injectionScopeNames {
            guard
                let injectionGrammar = getExternalGrammar(injectionScopeName),
                let selector = injectionGrammar.injectionSelector
            else { continue }
            append(
                selector: selector,
                rule: injectionGrammar.repository["$self"]!,
                source: injectionGrammar
            )
        }

        // ECMAScript Array.sort is stable. Include the original index so this
        // property does not depend on Swift's sorting implementation.
        collected.sort {
            if $0.injection.priority != $1.injection.priority {
                return $0.injection.priority < $1.injection.priority
            }
            return $0.index < $1.index
        }
        return collected.map(\.injection)
    }
}

/// Compatibility constructor matching `vscode-textmate`'s `createGrammar`.
public func createGrammar(
    scopeName: ScopeName,
    grammar: RawGrammar,
    initialLanguage: Int,
    embeddedLanguages: EmbeddedLanguagesMap? = nil,
    tokenTypes: TokenTypeMap? = nil,
    balancedBracketSelectors: BalancedBracketSelectors? = nil,
    grammarRepository: any TextMateGrammarRepositoryWithTheme,
    onigLibrary: any TextMateOnigLibrary = NativeTextMateOnigLibrary()
) -> Grammar {
    Grammar(
        scopeName: scopeName,
        grammar: grammar,
        initialLanguage: initialLanguage,
        embeddedLanguages: embeddedLanguages,
        tokenTypes: tokenTypes,
        balancedBracketSelectors: balancedBracketSelectors,
        grammarRepository: grammarRepository,
        onigLibrary: onigLibrary
    )
}

private func initializeGrammar(
    _ source: RawGrammar,
    base: RawRule?
) -> RawGrammar {
    var grammar = source
    var repository = grammar.repository
    let selfRule = RawRule(
        name: grammar.scopeName,
        patterns: grammar.patterns,
        location: grammar.location
    )
    repository["$self"] = selfRule
    repository["$base"] = base ?? selfRule
    grammar.repository = repository
    return grammar
}

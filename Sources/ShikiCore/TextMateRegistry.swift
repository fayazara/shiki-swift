/*---------------------------------------------------------
 * Copyright (C) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------*/

/// Synchronous registry for raw and compiled TextMate grammars.
///
/// This is the native counterpart of `vscode-textmate`'s `SyncRegistry`. A
/// theme can be switched without recompiling rule scanners, but callers must
/// not reuse state stacks created under an earlier theme.
public final class TextMateRegistry: TextMateGrammarRepositoryWithTheme {
    private var grammars: [ScopeName: Grammar] = [:]
    private var rawGrammars: [ScopeName: RawGrammar] = [:]
    private var injectionGrammars: [ScopeName: [ScopeName]] = [:]
    private var theme: Theme
    private let onigLibrary: any TextMateOnigLibrary

    public init(
        theme: Theme,
        onigLibrary: any TextMateOnigLibrary = NativeTextMateOnigLibrary()
    ) {
        self.theme = theme
        self.onigLibrary = onigLibrary
    }

    deinit {
        dispose()
    }

    public func dispose() {
        // Compiled grammars may still be referenced by persisted state stacks;
        // they release their scanners through ARC when the last state goes.
        grammars.removeAll(keepingCapacity: false)
    }

    public func setTheme(_ theme: Theme) {
        self.theme = theme
    }

    public func getColorMap() -> [String?] {
        theme.getColorMap()
    }

    public func addGrammar(
        _ grammar: RawGrammar,
        injectionScopeNames: [ScopeName] = []
    ) {
        rawGrammars[grammar.scopeName] = grammar
        injectionGrammars[grammar.scopeName] = injectionScopeNames
    }

    /// Adds raw grammars without discarding compiled grammars.
    ///
    /// Compiled grammars that previously referenced one of the new scopes (for
    /// example Markdown fences for a lazily embedded language), or whose
    /// injection contributions changed, are refreshed in place so that rule
    /// IDs held by existing state stacks remain valid. A scope whose raw
    /// grammar is replaced has its compiled grammar evicted; states created
    /// from the evicted grammar keep it alive and remain self-consistent.
    public func addGrammars(
        _ newGrammars: [RawGrammar],
        injections: [ScopeName: [ScopeName]]
    ) {
        var added: Set<ScopeName> = []
        for grammar in newGrammars {
            if rawGrammars[grammar.scopeName] != nil {
                grammars.removeValue(forKey: grammar.scopeName)
            }
            rawGrammars[grammar.scopeName] = grammar
            added.insert(grammar.scopeName)
        }
        injectionGrammars = injections
        for scopeName in grammars.keys.sorted() {
            grammars[scopeName]?.refreshAfterRepositoryChange(addedScopeNames: added)
        }
    }

    public func removeCompiledGrammar(scopeName: ScopeName) {
        if let grammar = grammars.removeValue(forKey: scopeName) {
            grammar.dispose()
        }
    }

    public func lookup(scopeName: ScopeName) -> RawGrammar? {
        rawGrammars[scopeName]
    }

    public func injections(scopeName: ScopeName) -> [ScopeName] {
        injectionGrammars[scopeName] ?? []
    }

    public func getDefaults() -> StyleAttributes {
        theme.getDefaults()
    }

    public func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes? {
        theme.match(scopePath)
    }

    public func grammarForScopeName(
        _ scopeName: ScopeName,
        initialLanguage: Int = 0,
        embeddedLanguages: EmbeddedLanguagesMap? = nil,
        tokenTypes: TokenTypeMap? = nil,
        balancedBracketSelectors: BalancedBracketSelectors? = nil
    ) -> Grammar? {
        if let existing = grammars[scopeName] {
            return existing
        }
        guard let rawGrammar = rawGrammars[scopeName] else {
            return nil
        }
        // The registry owns its grammars; a weak back-reference avoids a
        // registry <-> grammar retain cycle that would leak every scanner.
        let grammar = Grammar(
            scopeName: scopeName,
            grammar: rawGrammar,
            initialLanguage: initialLanguage,
            embeddedLanguages: embeddedLanguages,
            tokenTypes: tokenTypes,
            balancedBracketSelectors: balancedBracketSelectors,
            repositoryReference: GrammarRepositoryReference(weak: self),
            onigLibrary: onigLibrary
        )
        grammars[scopeName] = grammar
        return grammar
    }
}

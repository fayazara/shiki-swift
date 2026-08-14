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
        for grammar in grammars.values {
            grammar.dispose()
        }
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
        let grammar = createGrammar(
            scopeName: scopeName,
            grammar: rawGrammar,
            initialLanguage: initialLanguage,
            embeddedLanguages: embeddedLanguages,
            tokenTypes: tokenTypes,
            balancedBracketSelectors: balancedBracketSelectors,
            grammarRepository: self,
            onigLibrary: onigLibrary
        )
        grammars[scopeName] = grammar
        return grammar
    }
}

import Foundation
import ShikiCore

/// Failures reported by the high-level bundled Shiki API.
public enum ShikiHighlighterError: Error, Equatable, Sendable, CustomStringConvertible {
    case grammarUnavailable(language: String, scopeName: String)
    case invalidGrammarState
    case grammarStateLanguageMismatch(state: String, requested: String)
    case grammarStateThemeMismatch(stateThemes: [String], requested: String)
    case unnamedTheme
    case invalidLanguageRegistration(name: String, reason: String)
    case missingLanguageDependency(language: String, dependency: String)
    case emptyThemeVariants
    case emptyThemeColorName(index: Int)
    case emptyThemeName(index: Int)
    case duplicateThemeColorName(String)

    public var description: String {
        switch self {
        case let .grammarUnavailable(language, scopeName):
            "The TextMate grammar for \(String(reflecting: language)) "
                + "(\(String(reflecting: scopeName))) could not be compiled."
        case .invalidGrammarState:
            "Invalid grammar state"
        case let .grammarStateLanguageMismatch(state, requested):
            "Grammar state language \(String(reflecting: state)) does not match "
                + "highlight language \(String(reflecting: requested))."
        case let .grammarStateThemeMismatch(stateThemes, requested):
            "Grammar state themes \(stateThemes) do not contain highlight theme "
                + "\(String(reflecting: requested))."
        case .unnamedTheme:
            "A runtime theme must have a name before it can be registered."
        case let .invalidLanguageRegistration(name, reason):
            "Invalid language registration \(String(reflecting: name)): \(reason)"
        case let .missingLanguageDependency(language, dependency):
            "Language \(String(reflecting: language)) requires missing language "
                + "\(String(reflecting: dependency))."
        case .emptyThemeVariants:
            "At least one theme variant is required."
        case let .emptyThemeColorName(index):
            "Theme variant \(index) has an empty color name."
        case let .emptyThemeName(index):
            "Theme variant \(index) has an empty theme name."
        case let .duplicateThemeColorName(name):
            "Theme color name \(String(reflecting: name)) occurs more than once."
        }
    }
}

/// The persistent TextMate stack returned after highlighting a source fragment.
///
/// Pass this object back to ``ShikiHighlighter/highlight(_:language:theme:options:grammarState:)``
/// to continue a multi-line construct in a later fragment. State is tied to its
/// canonical language and theme, as it is in Shiki's JavaScript API.
public final class ShikiGrammarState: GrammarState, @unchecked Sendable {
    public let language: String
    public let themes: [String]
    public let scopes: [String]

    /// Compatibility spelling matching Shiki's `GrammarState.lang`.
    public var lang: String { language }

    /// The first (and, for single-theme tokenization, only) active theme.
    public var theme: String { themes[0] }

    private let stacksByTheme: [String: StateStackImpl]

    fileprivate convenience init(
        stack: StateStackImpl,
        language: String,
        theme: String
    ) {
        self.init(stacks: [(theme, stack)], language: language)
    }

    fileprivate init(
        stacks: [(theme: String, stack: StateStackImpl?)],
        language: String
    ) {
        precondition(!stacks.isEmpty, "Grammar state requires at least one theme stack.")

        var orderedThemes: [String] = []
        var seenThemes: Set<String> = []
        var resolvedStacks: [String: StateStackImpl] = [:]
        for entry in stacks {
            if seenThemes.insert(entry.theme).inserted {
                orderedThemes.append(entry.theme)
            }
            // Match Object.fromEntries in Shiki: a repeated underlying theme
            // keeps its original key position while its last stack wins.
            if let stack = entry.stack {
                resolvedStacks[entry.theme] = stack
            } else {
                // Object.fromEntries retains a key whose value is undefined.
                // The separate ordered `themes` array models that key while
                // the stack lookup correctly remains empty.
                resolvedStacks.removeValue(forKey: entry.theme)
            }
        }

        stacksByTheme = resolvedStacks
        self.language = language
        themes = orderedThemes
        scopes = resolvedStacks[orderedThemes[0]].map(Self.collectScopes) ?? []
    }

    fileprivate func stack(for theme: String) -> StateStackImpl? {
        stacksByTheme[theme]
    }

    /// Creates Shiki's `INITIAL` state for a canonical language and theme.
    public static func initial(language: String, theme: String) -> ShikiGrammarState {
        ShikiGrammarState(
            stack: StateStackImpl.NULL,
            language: language,
            theme: theme
        )
    }

    /// Creates Shiki's `INITIAL` state for multiple underlying themes.
    /// Repeated names collapse in first-seen order, matching `Object.fromEntries`.
    public static func initial(
        language: String,
        themes: [String]
    ) throws -> ShikiGrammarState {
        guard !themes.isEmpty else {
            throw ShikiHighlighterError.emptyThemeVariants
        }
        for (index, theme) in themes.enumerated() where theme.isEmpty {
            throw ShikiHighlighterError.emptyThemeName(index: index)
        }
        return ShikiGrammarState(
            stacks: themes.map { ($0, StateStackImpl.NULL) },
            language: language
        )
    }

    /// Scope chain for one underlying theme, or the first theme when omitted.
    /// Themes such as `none` that intentionally have no TextMate stack return
    /// an empty scope list.
    public func getScopes(theme requestedTheme: String? = nil) -> [String] {
        guard let stack = stacksByTheme[requestedTheme ?? theme] else {
            return []
        }
        return Self.collectScopes(from: stack)
    }

    private static func collectScopes(from stack: StateStackImpl) -> [String] {
        var result: [String] = []
        var visited: Set<ObjectIdentifier> = []
        var current: StateStackImpl? = stack

        while let frame = current, visited.insert(ObjectIdentifier(frame)).inserted {
            if let scopeName = frame.nameScopesList?.scopeName {
                result.append(scopeName)
            }
            current = frame.parent
        }
        return result
    }
}

/// Tokens plus the persistent grammar state produced by one highlight call.
public struct ShikiHighlightResult: Sendable {
    public let result: TokensResult
    public let grammarState: ShikiGrammarState?

    public init(result: TokensResult, grammarState: ShikiGrammarState?) {
        self.result = result
        self.grammarState = grammarState
    }
}

/// One ordered entry in Shiki's multi-theme `themes` option.
///
/// `colorName` becomes the key in every token's `variants` dictionary, while
/// `themeName` identifies the underlying VS Code/Shiki theme and grammar state.
public struct ShikiThemeVariant: Codable, Equatable, Sendable {
    public var colorName: String
    public var themeName: String

    public init(colorName: String, themeName: String) {
        self.colorName = colorName
        self.themeName = themeName
    }
}

/// Multi-theme tokens plus the TextMate continuation state for every theme.
public struct ShikiMultiThemeHighlightResult: Sendable {
    public let tokens: [[ThemedTokenWithVariants]]
    public let grammarState: ShikiGrammarState?

    public init(
        tokens: [[ThemedTokenWithVariants]],
        grammarState: ShikiGrammarState?
    ) {
        self.tokens = tokens
        self.grammarState = grammarState
    }
}

/// A synchronous, native Swift highlighter backed by Shiki's bundled grammars
/// and themes and the native TextMate/Oniguruma runtime in `ShikiCore`.
///
/// The instance lazily decodes assets. It loads each language's eager dependency
/// closure and scans source for Shiki's lazily embedded language markers, so a
/// fresh Markdown call can highlight fenced code without decoding every grammar.
public final class ShikiHighlighter: @unchecked Sendable {
    public let defaultTheme: String
    public let assets: BundledShikiAssets

    private struct CachedTheme {
        let resolved: ShikiResolvedTheme
        let compiled: TextMateTheme
    }

    private let lock = NSRecursiveLock()
    private var themeCache: [String: CachedTheme] = [:]
    private var loadedThemeOrder: [String] = []
    private var loadedLanguageRegistrations: [LanguageRegistration] = []
    private var loadedLanguageIDs: Set<String> = []
    private var customLanguagesByName: [String: LanguageRegistration] = [:]
    private var customLanguageAliases: [String: String] = [:]
    private var activeThemeName: String
    private var registry: TextMateRegistry

    public init(
        defaultTheme: String = "github-dark",
        assets: BundledShikiAssets = .shared
    ) throws {
        self.defaultTheme = defaultTheme
        self.assets = assets

        // A registry is not used for the special `none` theme, but retaining a
        // real compiled theme lets the same highlighter switch to one later.
        let bootstrapName = defaultTheme == "none" ? "github-dark" : defaultTheme
        let resolved = try assets.loadTheme(named: bootstrapName)
        let cached = CachedTheme(resolved: resolved, compiled: try resolved.compile())
        themeCache[bootstrapName] = cached
        loadedThemeOrder = [bootstrapName]
        activeThemeName = bootstrapName
        registry = TextMateRegistry(theme: cached.compiled)
    }

    /// Registers one raw VS Code/Shiki theme after applying Shiki's normalizer.
    public func loadTheme(_ theme: ShikiTheme) throws {
        try loadThemes([theme])
    }

    /// Registers raw VS Code/Shiki themes as one atomic batch.
    public func loadThemes(_ themes: [ShikiTheme]) throws {
        try loadResolvedThemes(themes.map(normalizeTheme))
    }

    /// Registers one already normalized Shiki theme.
    public func loadTheme(_ theme: ShikiResolvedTheme) throws {
        try loadThemes([theme])
    }

    /// Registers already normalized Shiki themes as one atomic batch.
    public func loadThemes(_ themes: [ShikiResolvedTheme]) throws {
        try loadResolvedThemes(themes)
    }

    /// Compatibility spelling for clients that prefer registration terminology.
    public func registerTheme(_ theme: ShikiTheme) throws {
        try loadTheme(theme)
    }

    /// Compatibility spelling for clients that prefer registration terminology.
    public func registerTheme(_ theme: ShikiResolvedTheme) throws {
        try loadTheme(theme)
    }

    public func registerThemes(_ themes: [ShikiTheme]) throws {
        try loadThemes(themes)
    }

    public func registerThemes(_ themes: [ShikiResolvedTheme]) throws {
        try loadThemes(themes)
    }

    /// Registers one runtime TextMate grammar and its aliases/injection targets.
    public func loadLanguage(_ language: LanguageRegistration) throws {
        try loadLanguages([language])
    }

    /// Registers runtime TextMate grammars as one batch before rebuilding the
    /// registry, allowing registrations in the batch to depend on each other.
    public func loadLanguages(_ languages: [LanguageRegistration]) throws {
        lock.lock()
        defer { lock.unlock() }
        try loadCustomLanguageBatch(languages)
    }

    /// Compatibility spelling for clients that prefer registration terminology.
    public func registerLanguage(_ language: LanguageRegistration) throws {
        try loadLanguage(language)
    }

    public func registerLanguages(_ languages: [LanguageRegistration]) throws {
        try loadLanguages(languages)
    }

    /// Canonical names and aliases currently available for synchronous use.
    public func getLoadedLanguages() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        var result: [String] = []
        var seen: Set<String> = []
        for registration in loadedLanguageRegistrations
        where seen.insert(registration.name).inserted {
            result.append(registration.name)
        }
        for registration in loadedLanguageRegistrations {
            for alias in registration.aliases ?? [] where seen.insert(alias).inserted {
                result.append(alias)
            }
        }
        return result
    }

    /// Theme names currently cached and available for synchronous use.
    public func getLoadedThemes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadedThemeOrder
    }

    public var loadedLanguageNames: [String] { getLoadedLanguages() }
    public var loadedThemeNames: [String] { getLoadedThemes() }

    /// Highlights source and returns Shiki's single-theme token result.
    public func codeToTokens(
        _ code: String,
        language: String = "text",
        theme: String? = nil,
        options: TokenizeWithThemeOptions = .init(),
        grammarState: (any GrammarState)? = nil
    ) throws -> TokensResult {
        try highlight(
            code,
            language: language,
            theme: theme,
            options: options,
            grammarState: grammarState
        ).result
    }

    /// Highlights source once per ordered theme and merges the aligned token
    /// boundaries into Shiki's `ThemedTokenWithVariants` representation.
    public func codeToTokensWithThemes(
        _ code: String,
        language: String = "text",
        themes: [ShikiThemeVariant],
        options: TokenizeWithThemeOptions = .init(),
        grammarState: (any GrammarState)? = nil
    ) throws -> [[ThemedTokenWithVariants]] {
        try highlightWithThemes(
            code,
            language: language,
            themes: themes,
            options: options,
            grammarState: grammarState
        ).tokens
    }

    /// Multi-theme highlighting that also exposes the merged continuation
    /// state, keyed internally by the underlying theme names.
    public func highlightWithThemes(
        _ code: String,
        language: String = "text",
        themes: [ShikiThemeVariant],
        options: TokenizeWithThemeOptions = .init(),
        grammarState: (any GrammarState)? = nil
    ) throws -> ShikiMultiThemeHighlightResult {
        try Task.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()

        try Self.validateThemeVariants(themes)

        var namedTokenizations: [NamedThemeTokenization] = []
        namedTokenizations.reserveCapacity(themes.count)
        var stateStacks: [(theme: String, stack: StateStackImpl?)] = []
        stateStacks.reserveCapacity(themes.count)
        var stateLanguage: String?
        var firstProducedState = false

        for (index, variant) in themes.enumerated() {
            let highlighted = try highlight(
                code,
                language: language,
                theme: variant.themeName,
                options: options,
                grammarState: grammarState
            )
            namedTokenizations.append(
                NamedThemeTokenization(
                    name: variant.colorName,
                    tokens: highlighted.result.tokens
                )
            )

            if index == 0 {
                firstProducedState = highlighted.grammarState != nil
            }
            if let producedState = highlighted.grammarState {
                stateLanguage = stateLanguage ?? producedState.language
                stateStacks.append((
                    producedState.theme,
                    producedState.stack(for: producedState.theme)
                ))
            } else {
                // Preserve every Object.fromEntries key. A special `none`
                // theme contributes no TextMate stack but remains observable
                // through GrammarState.themes whenever the first theme did.
                stateStacks.append((variant.themeName, nil))
            }
        }

        let merged = try mergeThemesTokenization(
            namedTokenizations,
            includeExplanation: options.resolvedExplanationMode != .none
        )
        let mergedState: ShikiGrammarState?
        if firstProducedState, let stateLanguage, !stateStacks.isEmpty {
            mergedState = ShikiGrammarState(
                stacks: stateStacks,
                language: stateLanguage
            )
        } else {
            // Shiki only returns a multi-theme state when the first themed
            // tokenization returned one (plain languages and `none` do not).
            mergedState = nil
        }

        return ShikiMultiThemeHighlightResult(
            tokens: merged,
            grammarState: mergedState
        )
    }

    /// Highlights source and also returns the final TextMate grammar state.
    public func highlight(
        _ code: String,
        language: String = "text",
        theme requestedTheme: String? = nil,
        options: TokenizeWithThemeOptions = .init(),
        grammarState: (any GrammarState)? = nil
    ) throws -> ShikiHighlightResult {
        try Task.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()

        let themeName = requestedTheme ?? defaultTheme
        let effectiveLanguage = language.isEmpty ? "text" : language
        let canonicalLanguage = resolveLanguageID(effectiveLanguage) ?? effectiveLanguage

        if Self.isPlainLanguage(canonicalLanguage) || themeName == "none" {
            let tokens = try Self.plainTokens(code)
            if themeName == "none" {
                return ShikiHighlightResult(
                    result: TokensResult(
                        tokens: tokens,
                        fg: "",
                        bg: "",
                        themeName: "none"
                    ),
                    grammarState: nil
                )
            }

            let theme = try activateTheme(named: themeName).resolved
            let replacements = resolveColorReplacements(
                for: theme,
                overrides: options.colorReplacements ?? [:]
            )
            return ShikiHighlightResult(
                result: TokensResult(
                    tokens: tokens,
                    fg: applyColorReplacements(theme.foreground, replacements: replacements),
                    bg: applyColorReplacements(theme.background, replacements: replacements),
                    themeName: theme.name
                ),
                grammarState: nil
            )
        }

        let cachedTheme = try activateTheme(named: themeName)
        let detectionSource: String
        if grammarState == nil, let context = options.grammarContextCode {
            detectionSource = context + "\n" + code
        } else {
            detectionSource = code
        }
        let registration = try ensureLanguageLoaded(
            named: canonicalLanguage,
            source: detectionSource
        )
        let resolvedThemeName = cachedTheme.resolved.name ?? themeName

        let operationalGrammarState: ShikiGrammarState?
        if let grammarState {
            guard grammarState.lang == registration.name else {
                throw ShikiHighlighterError.grammarStateLanguageMismatch(
                    state: grammarState.lang,
                    requested: registration.name
                )
            }
            guard grammarState.themes.contains(resolvedThemeName) else {
                throw ShikiHighlighterError.grammarStateThemeMismatch(
                    stateThemes: grammarState.themes,
                    requested: resolvedThemeName
                )
            }
            guard let state = grammarState as? ShikiGrammarState else {
                throw ShikiHighlighterError.invalidGrammarState
            }
            operationalGrammarState = state
        } else {
            operationalGrammarState = nil
        }

        let balancedBrackets = BalancedBracketSelectors(
            balancedBracketScopes: registration.balancedBracketSelectors ?? ["*"],
            unbalancedBracketScopes: registration.unbalancedBracketSelectors ?? []
        )
        guard let grammar = registry.grammarForScopeName(
            registration.scopeName,
            initialLanguage: 1,
            balancedBracketSelectors: balancedBrackets
        ) else {
            throw ShikiHighlighterError.grammarUnavailable(
                language: registration.name,
                scopeName: registration.scopeName
            )
        }

        let replacements = resolveColorReplacements(
            for: cachedTheme.resolved,
            overrides: options.colorReplacements ?? [:]
        )
        let tokenized = try tokenize(
            code,
            grammar: grammar,
            theme: cachedTheme.resolved,
            colorMap: registry.getColorMap(),
            replacements: replacements,
            options: options,
            initialState: operationalGrammarState?.stack(for: resolvedThemeName)
        )
        let finalState = ShikiGrammarState(
            stack: tokenized.state,
            language: registration.name,
            theme: resolvedThemeName
        )
        let result = TokensResult(
            tokens: tokenized.tokens,
            fg: applyColorReplacements(cachedTheme.resolved.foreground, replacements: replacements),
            bg: applyColorReplacements(cachedTheme.resolved.background, replacements: replacements),
            themeName: cachedTheme.resolved.name,
            grammarState: finalState
        )
        return ShikiHighlightResult(result: result, grammarState: finalState)
    }

    private func loadResolvedThemes(_ themes: [ShikiResolvedTheme]) throws {
        let prepared: [(name: String, cached: CachedTheme)] = try themes.map { theme in
            guard let name = theme.name, !name.isEmpty else {
                throw ShikiHighlighterError.unnamedTheme
            }
            return (
                name,
                CachedTheme(resolved: theme, compiled: try theme.compile())
            )
        }

        lock.lock()
        defer { lock.unlock() }
        for item in prepared {
            if themeCache[item.name] == nil {
                loadedThemeOrder.append(item.name)
            }
            themeCache[item.name] = item.cached
        }
        if let active = themeCache[activeThemeName] {
            // Replacing the active named theme is immediately visible to all
            // already compiled grammars, matching TextMate's setTheme model.
            registry.setTheme(active.compiled)
        }
    }

    private func loadCustomLanguageBatch(
        _ languages: [LanguageRegistration]
    ) throws {
        var batch: [LanguageRegistration] = []
        var batchNames: Set<String> = []
        var batchAliases: [String: String] = [:]

        for language in languages {
            guard !language.name.isEmpty else {
                throw ShikiHighlighterError.invalidLanguageRegistration(
                    name: language.name,
                    reason: "the name is empty"
                )
            }
            guard !language.scopeName.isEmpty else {
                throw ShikiHighlighterError.invalidLanguageRegistration(
                    name: language.name,
                    reason: "the TextMate scope name is empty"
                )
            }
            guard !loadedLanguageIDs.contains(language.name) else { continue }
            guard batchNames.insert(language.name).inserted else { continue }
            batch.append(language)
            batchAliases[language.name] = language.name
            for alias in language.aliases ?? [] {
                batchAliases[alias] = language.name
            }
        }
        guard !batch.isEmpty else { return }

        var dependencyRegistrations: [LanguageRegistration] = []
        var preparedNames = loadedLanguageIDs.union(batchNames)
        for language in batch {
            let dependencies = language.embeddedLanguages ?? language.embeddedLangs ?? []
            for dependency in dependencies {
                if batchAliases[dependency] != nil {
                    continue
                }
                if let existingID = resolveLanguageID(dependency),
                   loadedLanguageIDs.contains(existingID) {
                    continue
                }
                guard let bundledID = assets.canonicalLanguageID(for: dependency) else {
                    throw ShikiHighlighterError.missingLanguageDependency(
                        language: language.name,
                        dependency: dependency
                    )
                }
                let closure = try assets.loadLanguageClosure(
                    named: bundledID,
                    includingLazyDependencies: false
                )
                for registration in closure
                where preparedNames.insert(registration.name).inserted {
                    dependencyRegistrations.append(registration)
                }
            }
        }

        for registration in dependencyRegistrations {
            loadedLanguageIDs.insert(registration.name)
            loadedLanguageRegistrations.append(registration)
        }
        for registration in batch {
            customLanguagesByName[registration.name] = registration
            customLanguageAliases[registration.name] = registration.name
            for alias in registration.aliases ?? [] {
                customLanguageAliases[alias] = registration.name
            }
            loadedLanguageIDs.insert(registration.name)
            loadedLanguageRegistrations.append(registration)
        }
        rebuildRegistry()
    }

    private func resolveLanguageID(_ name: String) -> String? {
        if customLanguagesByName[name] != nil {
            return name
        }
        if let customName = customLanguageAliases[name] {
            return customName
        }
        return assets.canonicalLanguageID(for: name)
    }

    private func activateTheme(named name: String) throws -> CachedTheme {
        let cached: CachedTheme
        if let existing = themeCache[name] {
            cached = existing
        } else {
            let resolved = try assets.loadTheme(named: name)
            cached = CachedTheme(resolved: resolved, compiled: try resolved.compile())
            themeCache[name] = cached
            loadedThemeOrder.append(name)
        }

        if activeThemeName != name {
            registry.setTheme(cached.compiled)
            activeThemeName = name
        }
        return cached
    }

    @discardableResult
    private func ensureLanguageLoaded(
        named name: String,
        source: String
    ) throws -> LanguageRegistration {
        guard let canonicalID = resolveLanguageID(name) else {
            throw ShikiAssetError.unknownLanguage(name)
        }

        var addedLanguage = false

        func loadEagerClosure(named language: String) throws {
            guard
                let detectedID = resolveLanguageID(language),
                !loadedLanguageIDs.contains(detectedID)
            else { return }

            if let custom = customLanguagesByName[detectedID] {
                loadedLanguageIDs.insert(custom.name)
                loadedLanguageRegistrations.append(custom)
                addedLanguage = true
                return
            }

            let closure = try assets.loadLanguageClosure(
                named: detectedID,
                includingLazyDependencies: false
            )
            for registration in closure
            where loadedLanguageIDs.insert(registration.name).inserted {
                loadedLanguageRegistrations.append(registration)
                addedLanguage = true
            }
        }

        try loadEagerClosure(named: canonicalID)
        for detectedLanguage in guessEmbeddedLanguages(source) {
            // Shiki's bundle shorthand drops guesses that are not in the
            // bundled-language table, including LaTeX environments such as
            // `equation` that are scopes but not standalone grammars.
            guard resolveLanguageID(detectedLanguage) != nil else {
                continue
            }
            try loadEagerClosure(named: detectedLanguage)
        }
        if addedLanguage {
            rebuildRegistry()
        }

        // Return the canonical root rather than a detected embedded grammar.
        if let registration = loadedLanguageRegistrations.first(where: { $0.name == canonicalID }) {
            return registration
        }
        throw ShikiAssetError.unknownLanguage(name)
    }

    private func rebuildRegistry() {
        let activeTheme = themeCache[activeThemeName]!.compiled
        let replacement = TextMateRegistry(theme: activeTheme)

        var injectionsByTarget: [String: [String]] = [:]
        for registration in loadedLanguageRegistrations {
            for target in registration.injectTo ?? [] {
                injectionsByTarget[target, default: []].append(registration.scopeName)
            }
        }

        for registration in loadedLanguageRegistrations {
            let components = registration.scopeName.split(separator: ".")
            var injectionScopeNames: [String] = []
            for prefixLength in 1...components.count {
                let prefix = components.prefix(prefixLength).joined(separator: ".")
                injectionScopeNames.append(contentsOf: injectionsByTarget[prefix] ?? [])
            }
            replacement.addGrammar(
                registration.rawGrammar,
                injectionScopeNames: injectionScopeNames
            )
        }
        registry = replacement
    }

    private func tokenize(
        _ code: String,
        grammar: Grammar,
        theme: ShikiResolvedTheme,
        colorMap: [String?],
        replacements: [String: String],
        options: TokenizeWithThemeOptions,
        initialState: StateStackImpl?
    ) throws -> (tokens: [[ThemedToken]], state: StateStackImpl) {
        try Task.checkCancellation()

        var state: StateStackImpl
        if let initialState {
            state = initialState
        } else if let context = options.grammarContextCode {
            var contextOptions = options
            contextOptions.grammarContextCode = nil
            state = try tokenize(
                context,
                grammar: grammar,
                theme: theme,
                colorMap: colorMap,
                replacements: replacements,
                options: contextOptions,
                initialState: nil
            ).state
        } else {
            state = StateStackImpl.NULL
        }

        let explanationMode = options.resolvedExplanationMode
        let maxLineLength = options.resolvedMaxLineLength
        let timeLimit = options.resolvedTimeLimit
        let explanationThemeSelectors = explanationMode == .full
            ? Self.makeExplanationSelectors(theme.settings)
            : []
        var final: [[ThemedToken]] = []

        for splitLine in splitLines(code) {
            // A TextMate line and its resulting state are one atomic unit. Stop
            // only at this boundary so cancellation can never expose a partial
            // line or alter successful token/state parity.
            try Task.checkCancellation()
            let line = splitLine.content
            if line.isEmpty {
                final.append([])
                continue
            }

            let utf16 = Array(line.utf16)
            if maxLineLength > 0 && utf16.count >= maxLineLength {
                final.append([
                    ThemedToken(
                        content: line,
                        offset: splitLine.offset,
                        color: "",
                        fontStyle: FontStyle.none
                    ),
                ])
                continue
            }

            var scopedTokens: [TextMateToken] = []
            if explanationMode == .scopeName || explanationMode == .full {
                scopedTokens = try grammar.tokenizeLine(
                    line,
                    previousState: state,
                    timeLimit: timeLimit
                ).tokens
            }

            let binary = try grammar.tokenizeLine2(
                line,
                previousState: state,
                timeLimit: timeLimit
            )
            var lineTokens: [ThemedToken] = []
            var scopedTokenIndex = 0
            let tokenCount = binary.tokens.count / 2

            for tokenIndex in 0..<tokenCount {
                let start = Int(binary.tokens[tokenIndex * 2])
                let end = tokenIndex + 1 < tokenCount
                    ? Int(binary.tokens[(tokenIndex + 1) * 2])
                    : utf16.count
                guard start != end else { continue }

                let metadata = binary.tokens[tokenIndex * 2 + 1]
                let foregroundID = EncodedTokenMetadata.getForeground(metadata)
                let rawColor = colorMap.indices.contains(foregroundID)
                    ? colorMap[foregroundID]
                    : nil
                var token = ThemedToken(
                    content: Self.substring(utf16, from: start, to: end),
                    offset: splitLine.offset + start,
                    color: applyColorReplacements(rawColor, replacements: replacements),
                    fontStyle: EncodedTokenMetadata.getFontStyle(metadata)
                )

                switch explanationMode {
                case .tokenType:
                    token.type = EncodedTokenMetadata.getTokenType(metadata)
                case .scopeName, .full:
                    var explanation: [ThemedTokenExplanation] = []
                    var consumed = 0
                    while start + consumed < end, scopedTokenIndex < scopedTokens.count {
                        let scoped = scopedTokens[scopedTokenIndex]
                        let content = Self.substring(
                            utf16,
                            from: scoped.startIndex,
                            to: scoped.endIndex
                        )
                        consumed += content.utf16.count
                        let scopes: [ThemedTokenScopeExplanation]
                        if explanationMode == .scopeName {
                            scopes = scoped.scopes.map {
                                ThemedTokenScopeExplanation(scopeName: $0)
                            }
                        } else {
                            scopes = Self.explainScopes(
                                scoped.scopes,
                                selectors: explanationThemeSelectors
                            )
                        }
                        explanation.append(
                            ThemedTokenExplanation(content: content, scopes: scopes)
                        )
                        scopedTokenIndex += 1
                    }
                    token.explanation = explanation
                case .none:
                    break
                }
                lineTokens.append(token)
            }

            final.append(lineTokens)
            state = binary.ruleStack
        }
        try Task.checkCancellation()
        return (final, state)
    }

    private struct ExplanationThemeSelector {
        let setting: ShikiThemeRule
        let selectors: [[String]]
    }

    private static func makeExplanationSelectors(
        _ settings: [ShikiThemeRule]
    ) -> [ExplanationThemeSelector] {
        settings.compactMap { setting in
            let selectors: [String]
            switch setting.scope {
            case let .string(scope):
                selectors = scope
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            case let .array(scopeList):
                selectors = scopeList
            case nil:
                return nil
            }
            return ExplanationThemeSelector(
                setting: setting,
                selectors: selectors.map { $0.components(separatedBy: " ") }
            )
        }
    }

    private static func explainScopes(
        _ scopes: [String],
        selectors: [ExplanationThemeSelector]
    ) -> [ThemedTokenScopeExplanation] {
        scopes.enumerated().map { index, scope in
            let parents = Array(scopes[..<index])
            let matches = selectors.compactMap { candidate -> ShikiThemeRule? in
                candidate.selectors.contains(where: {
                    selectorMatches($0, scope: scope, parentScopes: parents)
                }) ? candidate.setting : nil
            }
            return ThemedTokenScopeExplanation(
                scopeName: scope,
                themeMatches: matches
            )
        }
    }

    private static func selectorMatches(
        _ selector: [String],
        scope: String,
        parentScopes: [String]
    ) -> Bool {
        guard let last = selector.last, scopeMatches(last, scope) else {
            return false
        }

        var selectorParentIndex = selector.count - 2
        var parentIndex = parentScopes.count - 1
        while selectorParentIndex >= 0, parentIndex >= 0 {
            if scopeMatches(selector[selectorParentIndex], parentScopes[parentIndex]) {
                selectorParentIndex -= 1
            }
            parentIndex -= 1
        }
        return selectorParentIndex == -1
    }

    private static func scopeMatches(_ selector: String, _ scope: String) -> Bool {
        guard !selector.isEmpty else { return false }
        if selector == scope { return true }
        guard scope.hasPrefix(selector) else { return false }
        let boundary = scope.index(scope.startIndex, offsetBy: selector.count)
        return boundary < scope.endIndex && scope[boundary] == "."
    }

    private static func validateThemeVariants(
        _ themes: [ShikiThemeVariant]
    ) throws {
        guard !themes.isEmpty else {
            throw ShikiHighlighterError.emptyThemeVariants
        }

        var colorNames: Set<String> = []
        for (index, variant) in themes.enumerated() {
            guard !variant.colorName.isEmpty else {
                throw ShikiHighlighterError.emptyThemeColorName(index: index)
            }
            guard !variant.themeName.isEmpty else {
                throw ShikiHighlighterError.emptyThemeName(index: index)
            }
            guard colorNames.insert(variant.colorName).inserted else {
                throw ShikiHighlighterError.duplicateThemeColorName(
                    variant.colorName
                )
            }
        }
    }

    private static func plainTokens(_ code: String) throws -> [[ThemedToken]] {
        var result: [[ThemedToken]] = []
        for line in splitLines(code) {
            try Task.checkCancellation()
            result.append([ThemedToken(content: line.content, offset: line.offset)])
        }
        try Task.checkCancellation()
        return result
    }

    private static func isPlainLanguage(_ language: String) -> Bool {
        ["plaintext", "txt", "text", "plain"].contains(language)
    }

    private static func substring(
        _ utf16: [UInt16],
        from start: Int,
        to end: Int
    ) -> String {
        // JavaScript `substring` clamps indices to the string bounds. The
        // non-binary TextMate API can expose the synthetic sentinel newline at
        // `line.length + 1`, so this is observable in explanation mode.
        let clampedStart = min(max(start, 0), utf16.count)
        let clampedEnd = min(max(end, 0), utf16.count)
        let lowerBound = min(clampedStart, clampedEnd)
        let upperBound = max(clampedStart, clampedEnd)
        return String(decoding: utf16[lowerBound..<upperBound], as: UTF16.self)
    }
}

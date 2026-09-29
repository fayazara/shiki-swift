#if os(macOS)
import Foundation
import Shiki

/// Retains the configured engine so streams can use registered themes and languages.
/// Create through DiffHighlighter.streamConfiguration to resolve lazy loaders.
public struct StreamTokenizerConfiguration: Sendable {
    public let language: String
    public let theme: String
    public let palette: DiffPalette
    public let options: TokenizeWithThemeOptions
    let highlighter: ShikiHighlighter?
    public init(language: String, theme: String = "github-dark", highlighter: ShikiHighlighter? = nil, palette: DiffPalette = .init(), options: TokenizeWithThemeOptions = .init(includeExplanation: .tokenType)) {
        self.language = language; self.theme = theme; self.highlighter = highlighter; self.palette = palette; self.options = options
    }
}

/// Prepared light/dark tokenizers consume each chunk once per theme. Appearance
/// changes select cached snapshots and never replay the source stream.
public struct ThemedStreamTokenizerConfiguration: Sendable {
    public let light: StreamTokenizerConfiguration
    public let dark: StreamTokenizerConfiguration
    public init(light: StreamTokenizerConfiguration, dark: StreamTokenizerConfiguration) throws {
        guard light.language.utf16.elementsEqual(dark.language.utf16) else {
            throw DiffError.invalidPatch("Streaming themes must use the same language")
        }
        self.light = light; self.dark = dark
    }
}
public extension DiffHighlighter {
    func streamConfiguration(language: String, themes: DiffThemeNames, options: TokenizeWithThemeOptions = .init(includeExplanation: .tokenType)) async throws -> ThemedStreamTokenizerConfiguration {
        let light = try await streamConfiguration(language: language, theme: themes.light, options: options)
        let dark = try await streamConfiguration(language: language, theme: themes.dark, options: options)
        return try .init(light: light, dark: dark)
    }
}

public struct StreamTokenUpdate: Sendable {
    public var recall: Int
    public var stable: [ThemedToken]
    public var unstable: [ThemedToken]
}
/// Line-stable streaming tokenizer. Only the incomplete last line is re-tokenized
/// when another chunk arrives; complete lines retain their TextMate continuation.
public actor ShikiStreamTokenizer {
    public let language: String
    public let theme: String
    private let core: StreamTokenizerCore
    public var tokensStable: [ThemedToken] { core.tokensStable }
    public var tokensUnstable: [ThemedToken] { core.tokensUnstable }
    public var lastUnstableCodeChunk: String { core.lastUnstableCodeChunk }
    public var foreground: String { core.foreground }
    public var background: String { core.background }
    public init(language: String, theme: String = "github-dark") {
        self.language = language; self.theme = theme
        core = .init(language: language, theme: theme)
    }
    public init(configuration: StreamTokenizerConfiguration) {
        language = configuration.language; theme = configuration.theme
        core = .init(language: language, theme: theme, highlighter: configuration.highlighter, options: configuration.options)
    }
    private init(snapshot: StreamTokenizerSnapshot) {
        language = snapshot.language; theme = snapshot.theme
        core = .init(snapshot: snapshot)
    }
    /// Like upstream, clones share accumulated stable tokens until `clear()`;
    /// pending text and grammar continuation branch independently.
    public func clone() -> ShikiStreamTokenizer { .init(snapshot: core.snapshot) }
    public func enqueue(_ chunk: String) throws -> StreamTokenUpdate { try core.enqueue(chunk) }
    @discardableResult public func close() -> [ThemedToken] { core.close() }
    public func clear() { core.clear() }
}

// Upstream clone() aliases tokensStable. Lock only this shared accumulation;
// the highlighter itself is Sendable and serializes access internally.
private final class StreamStableTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [ThemedToken] = []
    var value: [ThemedToken] {
        lock.lock(); defer { lock.unlock() }; return tokens
    }
    func append(_ value: [ThemedToken]) {
        lock.lock(); defer { lock.unlock() }; tokens.append(contentsOf: value)
    }
}
private struct StreamTokenizerSnapshot: Sendable {
    let language, theme: String
    let stable: StreamStableTokens
    let unstable: [ThemedToken]
    let pending: String
    let state: (any GrammarState)?
    let engine: ShikiHighlighter?
    let foreground, background: String
    let options: TokenizeWithThemeOptions
}

// Owned exclusively by one actor. Enqueue, buffer updates and snapshot creation
// can run without actor hops or suspension between their state transitions.
private final class StreamTokenizerCore {
    let language: String
    let theme: String
    let options: TokenizeWithThemeOptions
    private var stableBuffer = StreamStableTokens()
    var tokensStable: [ThemedToken] { stableBuffer.value }
    private(set) var tokensUnstable: [ThemedToken] = []
    private(set) var lastUnstableCodeChunk = ""
    private var state: (any GrammarState)?
    private var engine: ShikiHighlighter?
    private(set) var foreground = "#c9d1d9"
    private(set) var background = "#0d1117"
    private(set) var palette = DiffPalette()
    init(language: String, theme: String = "github-dark", highlighter: ShikiHighlighter? = nil, options: TokenizeWithThemeOptions = .init(includeExplanation: .tokenType)) {
        self.language = language; self.theme = theme; engine = highlighter; self.options = options
    }
    init(snapshot: StreamTokenizerSnapshot) {
        language = snapshot.language; theme = snapshot.theme; stableBuffer = snapshot.stable
        tokensUnstable = snapshot.unstable; lastUnstableCodeChunk = snapshot.pending
        state = snapshot.state; engine = snapshot.engine
        foreground = snapshot.foreground; background = snapshot.background
        options = snapshot.options
    }
    var snapshot: StreamTokenizerSnapshot {
        .init(language: language, theme: theme, stable: stableBuffer, unstable: tokensUnstable,
              pending: lastUnstableCodeChunk, state: state, engine: engine, foreground: foreground, background: background, options: options)
    }
    func enqueue(_ chunk: String) throws -> StreamTokenUpdate {
        if engine == nil {
            let value = try ShikiHighlighter()
            if theme == "pierre-dark" || theme == "pierre-light", let url = Bundle.module.url(forResource: theme, withExtension: "json") {
                let resolved = try JSONDecoder().decode(ShikiTheme.self, from: Data(contentsOf: url))
                try value.registerTheme(resolved)
                palette = DiffHighlighter.palette(colors: resolved.colors, isLight: resolved.type == .light)
            } else {
                let resolved = try value.assets.loadTheme(named: theme)
                palette = DiffHighlighter.palette(colors: resolved.colors, isLight: resolved.type == .light)
            }
            engine = value
        }
        let lines = (lastUnstableCodeChunk + chunk).components(separatedBy: "\n")
        let recall = tokensUnstable.count
        var stable: [ThemedToken] = [], unstable: [ThemedToken] = []
        for (i, line) in lines.enumerated() {
            let result = try engine!.codeToTokens(line, language: language, theme: theme, options: options, grammarState: state)
            foreground = result.fg ?? foreground; background = result.bg ?? background
            var tokens = result.tokens.first ?? []
            if i < lines.count - 1 {
                tokens.append(.init(content: "\n", offset: 0)); state = result.grammarState; stable += tokens
            } else { unstable = tokens; lastUnstableCodeChunk = line }
        }
        stableBuffer.append(stable); tokensUnstable = unstable
        return .init(recall: recall, stable: stable, unstable: unstable)
    }
    @discardableResult func close() -> [ThemedToken] {
        let result = tokensUnstable; tokensUnstable = []; lastUnstableCodeChunk = ""; state = nil; return result
    }
    func clear() { stableBuffer = StreamStableTokens(); tokensUnstable = []; lastUnstableCodeChunk = ""; state = nil }
}

public func getSingularPatch(_ patch: String) throws -> FileDiffMetadata {
    let result = try parsePatchFiles(patch)
    guard result.count == 1, result[0].files.count == 1 else { throw DiffError.invalidPatch("Expected exactly one patch containing one file") }
    return result[0].files[0]
}
public enum LineEnding: String, Sendable { case CRLF, CR, LF, none }
public func getLineEndingType(_ content: String) -> LineEnding {
    if content.contains("\r\n") { return .CRLF }
    if content.contains("\r") { return .CR }
    return content.contains("\n") ? .LF : .none
}

/// A growing read-only file, prepared from streaming tokens without highlighting
/// its stable prefix again. Snapshots preserve native scroll and selection identity.
public struct FileStreamAppendResult: Sendable {
    public var document: HighlightedDiff
    public var tokens: StreamTokenUpdate
}
public actor FileStream {
    public let name: String
    private let tokenizer: StreamTokenizerCore
    private let palette: DiffPalette?
    private let sourceID = UUID()
    private var completeLines: [String] = []
    private var completeTokens: [[ThemedToken]] = []
    private var pendingTokens: [ThemedToken] = []
    private var pendingLine = ""
    private var isClosed = false
    public init(name: String, language: String? = nil, theme: String = "github-dark") {
        self.name = name; tokenizer = .init(language: language ?? getFiletypeFromFileName(name), theme: theme, options: .init(includeExplanation: .tokenType)); palette = nil
    }
    public init(name: String, configuration: StreamTokenizerConfiguration) {
        self.name = name
        palette = configuration.palette
        tokenizer = .init(language: configuration.language, theme: configuration.theme, highlighter: configuration.highlighter, options: configuration.options)
    }
    public func append(_ chunk: String) async throws -> HighlightedDiff {
        try await appendWithUpdate(chunk).document
    }
    /// Append once and expose the same recall/token update used for this snapshot.
    public func appendWithUpdate(_ chunk: String) async throws -> FileStreamAppendResult {
        guard !isClosed else { throw DiffError.invalidPatch("Stream is already closed") }
        let update = try tokenizer.enqueue(chunk)
        var row: [ThemedToken] = []
        for token in update.stable {
            if token.content == "\n" {
                completeTokens.append(row); completeLines.append(row.map(\.content).joined() + "\n"); row = []
            } else { row.append(token) }
        }
        pendingTokens = update.unstable; pendingLine = update.unstable.map(\.content).joined()
        return .init(document: snapshot(), tokens: update)
    }
    public func close() async -> HighlightedDiff {
        // An empty stream still needs its theme before its first snapshot.
        // Preserve this nonthrowing API's fallback if theme loading fails.
        if !isClosed && completeLines.isEmpty && pendingLine.isEmpty {
            _ = try? tokenizer.enqueue("")
        }
        _ = tokenizer.close(); isClosed = true
        return snapshot()
    }
    private func snapshot() -> HighlightedDiff {
        var lines = completeLines, tokens = completeTokens
        if !pendingLine.isEmpty { lines.append(pendingLine); tokens.append(pendingTokens) }
        var diff = FileDiffMetadata(name: name); diff.isPartial = false
        diff.deletionLines = lines; diff.additionLines = lines
        return .init(sourceID: sourceID, diff: diff, oldTokens: tokens, newTokens: tokens, foreground: tokenizer.foreground, background: tokenizer.background, palette: palette ?? tokenizer.palette)
    }
}

#endif

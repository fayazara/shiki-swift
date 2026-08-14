import Foundation

/// Public metadata exposed by Shiki's persistent TextMate grammar state.
///
/// Concrete highlighters may retain additional engine-specific state for
/// continuation. A state decoded from ``TokensResult`` is intentionally only a
/// metadata snapshot and cannot be resumed by a highlighter.
public protocol GrammarState: AnyObject, Sendable {
    var lang: String { get }
    var theme: String { get }
    var themes: [String] { get }
    var scopes: [String] { get }

    func getScopes(theme: String?) -> [String]
}

public extension GrammarState {
    /// Scope chain for the first theme, matching Shiki's no-argument call.
    func getScopes() -> [String] {
        getScopes(theme: nil)
    }
}

/// Why a token matched a particular theme scope.
public struct ThemedTokenScopeExplanation: Codable, Equatable, Sendable {
    public var scopeName: String
    public var themeMatches: [ShikiThemeRule]?

    public init(
        scopeName: String,
        themeMatches: [ShikiThemeRule]? = nil
    ) {
        self.scopeName = scopeName
        self.themeMatches = themeMatches
    }
}

/// One contiguous explanation segment within a themed token.
public struct ThemedTokenExplanation: Codable, Equatable, Sendable {
    public var content: String
    public var scopes: [ThemedTokenScopeExplanation]

    public init(
        content: String,
        scopes: [ThemedTokenScopeExplanation]
    ) {
        self.content = content
        self.scopes = scopes
    }
}

/// The fields common to Shiki's token representations.
public struct TokenBase: Codable, Equatable, Sendable {
    public var content: String

    /// Absolute zero-based offset into the original source, in UTF-16 code
    /// units. This intentionally follows JavaScript `String.length` rather
    /// than Swift `Character` indexing.
    public var offset: Int

    public var type: StandardTokenType?
    public var explanation: [ThemedTokenExplanation]?

    public init(
        content: String,
        offset: Int,
        type: StandardTokenType? = nil,
        explanation: [ThemedTokenExplanation]? = nil
    ) {
        self.content = content
        self.offset = offset
        self.type = type
        self.explanation = explanation
    }
}

/// Visual styles attached to a Shiki token.
public struct TokenStyles: Codable, Equatable, Sendable {
    public var color: String?
    public var bgColor: String?
    public var fontStyle: FontStyle?
    public var htmlStyle: [String: String]?
    public var htmlAttrs: [String: String]?

    /// Present inside multi-theme variants when Shiki's `tokenType`
    /// explanation mode is enabled. Shiki 4.4.3 emits this at runtime even
    /// though its TypeScript `TokenStyles` declaration omits the field.
    public var type: StandardTokenType?

    public init(
        color: String? = nil,
        bgColor: String? = nil,
        fontStyle: FontStyle? = nil,
        htmlStyle: [String: String]? = nil,
        htmlAttrs: [String: String]? = nil,
        type: StandardTokenType? = nil
    ) {
        self.color = color
        self.bgColor = bgColor
        self.fontStyle = fontStyle
        self.htmlStyle = htmlStyle
        self.htmlAttrs = htmlAttrs
        self.type = type
    }
}

/// A single token styled by one theme.
public struct ThemedToken: Codable, Equatable, Sendable {
    public var content: String

    /// Absolute zero-based offset into the original source, in UTF-16 code
    /// units. A non-BMP scalar such as an emoji advances this value by two.
    public var offset: Int

    public var type: StandardTokenType?
    public var explanation: [ThemedTokenExplanation]?
    public var color: String?
    public var bgColor: String?
    public var fontStyle: FontStyle?
    public var htmlStyle: [String: String]?
    public var htmlAttrs: [String: String]?

    public init(
        content: String,
        offset: Int,
        type: StandardTokenType? = nil,
        explanation: [ThemedTokenExplanation]? = nil,
        color: String? = nil,
        bgColor: String? = nil,
        fontStyle: FontStyle? = nil,
        htmlStyle: [String: String]? = nil,
        htmlAttrs: [String: String]? = nil
    ) {
        self.content = content
        self.offset = offset
        self.type = type
        self.explanation = explanation
        self.color = color
        self.bgColor = bgColor
        self.fontStyle = fontStyle
        self.htmlStyle = htmlStyle
        self.htmlAttrs = htmlAttrs
    }

    public init(base: TokenBase, styles: TokenStyles = .init()) {
        self.init(
            content: base.content,
            offset: base.offset,
            type: base.type,
            explanation: base.explanation,
            color: styles.color,
            bgColor: styles.bgColor,
            fontStyle: styles.fontStyle,
            htmlStyle: styles.htmlStyle,
            htmlAttrs: styles.htmlAttrs
        )
    }

    public var base: TokenBase {
        TokenBase(
            content: content,
            offset: offset,
            type: type,
            explanation: explanation
        )
    }

    public var styles: TokenStyles {
        TokenStyles(
            color: color,
            bgColor: bgColor,
            fontStyle: fontStyle,
            htmlStyle: htmlStyle,
            htmlAttrs: htmlAttrs,
            type: type
        )
    }
}

/// Shiki's `boolean | "scopeName" | "tokenType"` explanation option.
public enum TokenExplanationMode: Equatable, Sendable {
    case none
    case full
    case scopeName
    case tokenType
}

extension TokenExplanationMode: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let enabled = try? container.decode(Bool.self) {
            self = enabled ? .full : .none
            return
        }

        switch try container.decode(String.self) {
        case "scopeName":
            self = .scopeName
        case "tokenType":
            self = .tokenType
        case let value:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported explanation mode \(String(reflecting: value))."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encode(false)
        case .full:
            try container.encode(true)
        case .scopeName:
            try container.encode("scopeName")
        case .tokenType:
            try container.encode("tokenType")
        }
    }
}

/// The serializable part of Shiki's single-theme tokenization options.
public struct TokenizeWithThemeOptions: Codable, Equatable, Sendable {
    public var includeExplanation: TokenExplanationMode?
    public var colorReplacements: [String: ShikiColorReplacementOption]?
    public var tokenizeMaxLineLength: Int?
    public var tokenizeTimeLimit: Int?
    public var grammarContextCode: String?

    public init(
        includeExplanation: TokenExplanationMode? = nil,
        colorReplacements: [String: ShikiColorReplacementOption]? = nil,
        tokenizeMaxLineLength: Int? = nil,
        tokenizeTimeLimit: Int? = nil,
        grammarContextCode: String? = nil
    ) {
        self.includeExplanation = includeExplanation
        self.colorReplacements = colorReplacements
        self.tokenizeMaxLineLength = tokenizeMaxLineLength
        self.tokenizeTimeLimit = tokenizeTimeLimit
        self.grammarContextCode = grammarContextCode
    }

    /// Shiki's effective default when `includeExplanation` is omitted.
    public var resolvedExplanationMode: TokenExplanationMode {
        includeExplanation ?? .none
    }

    /// Shiki's effective default: zero disables the maximum line length.
    public var resolvedMaxLineLength: Int {
        tokenizeMaxLineLength ?? 0
    }

    /// Shiki's v4.4.3 default time limit for tokenizing one line.
    public var resolvedTimeLimit: Int {
        tokenizeTimeLimit ?? 500
    }
}

/// Shiki's `string | false` root-style result field.
public enum TokenRootStyle: Equatable, Sendable {
    case style(String)
    case disabled
}

extension TokenRootStyle: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let style = try? container.decode(String.self) {
            self = .style(style)
            return
        }

        let enabled = try container.decode(Bool.self)
        guard !enabled else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Shiki rootStyle accepts a string or false, but not true."
            )
        }
        self = .disabled
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .style(style):
            try container.encode(style)
        case .disabled:
            try container.encode(false)
        }
    }
}

/// The single-theme result returned by `codeToTokens`.
///
/// Encoding writes the same grammar-state metadata snapshot as Shiki's
/// `GrammarState.toJSON()`. Decoding recreates that public snapshot, but not the
/// private tokenizer stack required to continue tokenization.
public struct TokensResult: Codable, Equatable, Sendable {
    public var tokens: [[ThemedToken]]
    public var fg: String?
    public var bg: String?
    public var themeName: String?
    public var rootStyle: TokenRootStyle?
    public var grammarState: (any GrammarState)?

    public init(
        tokens: [[ThemedToken]],
        fg: String? = nil,
        bg: String? = nil,
        themeName: String? = nil,
        rootStyle: TokenRootStyle? = nil,
        grammarState: (any GrammarState)? = nil
    ) {
        self.tokens = tokens
        self.fg = fg
        self.bg = bg
        self.themeName = themeName
        self.rootStyle = rootStyle
        self.grammarState = grammarState
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decode([[ThemedToken]].self, forKey: .tokens)
        fg = try container.decodeIfPresent(String.self, forKey: .fg)
        bg = try container.decodeIfPresent(String.self, forKey: .bg)
        themeName = try container.decodeIfPresent(String.self, forKey: .themeName)
        rootStyle = try container.decodeIfPresent(TokenRootStyle.self, forKey: .rootStyle)
        grammarState = try container
            .decodeIfPresent(GrammarStateSnapshot.self, forKey: .grammarState)
            .map(DecodedGrammarState.init)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tokens, forKey: .tokens)
        try container.encodeIfPresent(fg, forKey: .fg)
        try container.encodeIfPresent(bg, forKey: .bg)
        try container.encodeIfPresent(themeName, forKey: .themeName)
        try container.encodeIfPresent(rootStyle, forKey: .rootStyle)
        if let grammarState {
            try container.encode(
                GrammarStateSnapshot(grammarState),
                forKey: .grammarState
            )
        }
    }

    public static func == (lhs: TokensResult, rhs: TokensResult) -> Bool {
        lhs.tokens == rhs.tokens
            && lhs.fg == rhs.fg
            && lhs.bg == rhs.bg
            && lhs.themeName == rhs.themeName
            && lhs.rootStyle == rhs.rootStyle
            && lhs.grammarState.map(GrammarStateSnapshot.init)
                == rhs.grammarState.map(GrammarStateSnapshot.init)
    }

    private enum CodingKeys: String, CodingKey {
        case tokens
        case fg
        case bg
        case themeName
        case rootStyle
        case grammarState
    }
}

private struct GrammarStateSnapshot: Codable, Equatable, Sendable {
    let lang: String
    let theme: String
    let themes: [String]
    let scopes: [String]

    init(_ state: any GrammarState) {
        lang = state.lang
        theme = state.theme
        themes = state.themes
        scopes = state.scopes
    }
}

private final class DecodedGrammarState: GrammarState {
    let lang: String
    let theme: String
    let themes: [String]
    let scopes: [String]

    init(_ snapshot: GrammarStateSnapshot) {
        lang = snapshot.lang
        theme = snapshot.theme
        themes = snapshot.themes
        scopes = snapshot.scopes
    }

    func getScopes(theme requestedTheme: String?) -> [String] {
        guard requestedTheme == nil || requestedTheme == theme else {
            return []
        }
        return scopes
    }
}

import Foundation

/// Whether a color theme is intended for a light or dark editor surface.
public enum ShikiThemeType: String, Codable, Sendable {
    case light
    case dark
}

/// A TextMate rule's scope, preserving the shape used by VS Code theme JSON.
///
/// A single scope and an array containing one scope have subtly different JSON
/// representations, so the decoder does not flatten them into a common array.
public enum ShikiThemeScope: Equatable, Sendable {
    case string(String)
    case array([String])

    /// The scope values in a convenient, flattened form.
    public var values: [String] {
        switch self {
        case let .string(value):
            [value]
        case let .array(values):
            values
        }
    }
}

extension ShikiThemeScope: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }

        if let values = try? container.decode([String].self) {
            self = .array(values)
            return
        }

        throw DecodingError.typeMismatch(
            ShikiThemeScope.self,
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "A theme scope must be a string or an array of strings."
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values)
        }
    }
}

/// The styling payload of a TextMate theme rule.
public struct ShikiThemeTokenSettings: Codable, Equatable, Sendable {
    public var fontStyle: String?
    public var foreground: String?
    public var background: String?

    public init(
        fontStyle: String? = nil,
        foreground: String? = nil,
        background: String? = nil
    ) {
        self.fontStyle = fontStyle
        self.foreground = foreground
        self.background = background
    }
}

/// A raw TextMate token-color rule contained in a Shiki theme.
public struct ShikiThemeRule: Codable, Equatable, Sendable {
    public var name: String?
    public var scope: ShikiThemeScope?
    public var settings: ShikiThemeTokenSettings?

    public init(
        name: String? = nil,
        scope: ShikiThemeScope? = nil,
        settings: ShikiThemeTokenSettings? = nil
    ) {
        self.name = name
        self.scope = scope
        self.settings = settings
    }
}

/// The object form accepted by VS Code for a semantic-token color.
public struct ShikiSemanticTokenSettings: Codable, Equatable, Sendable {
    public var foreground: String?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?

    public init(
        foreground: String? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        strikethrough: Bool? = nil
    ) {
        self.foreground = foreground
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
    }
}

/// A semantic-token color as either VS Code's shorthand string or object form.
public enum ShikiSemanticTokenColor: Equatable, Sendable {
    case color(String)
    case settings(ShikiSemanticTokenSettings)
}

extension ShikiSemanticTokenColor: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let color = try? container.decode(String.self) {
            self = .color(color)
        } else {
            self = .settings(try container.decode(ShikiSemanticTokenSettings.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .color(color):
            try container.encode(color)
        case let .settings(settings):
            try container.encode(settings)
        }
    }
}

/// A Shiki/VS Code theme as it appears before Shiki normalization.
///
/// `settings` remains optional here so an absent value can be distinguished
/// from an explicitly empty array. Shiki only falls back to `tokenColors` in
/// the former case.
public struct ShikiTheme: Codable, Equatable, Sendable {
    public var name: String?
    public var displayName: String?
    public var type: ShikiThemeType?
    public var settings: [ShikiThemeRule]?
    public var tokenColors: [ShikiThemeRule]?
    public var foreground: String?
    public var background: String?
    public var colorReplacements: [String: String]?
    public var colors: [String: String]?
    /// Invalid-but-real workbench color values retained losslessly. Shiki only
    /// reads string values for editor/terminal keys, so these do not affect
    /// tokenization.
    public var nonStringColors: [String: ShikiJSONValue]?
    public var schema: String?
    public var include: String?
    public var semanticHighlighting: Bool?
    public var semanticTokenColors: [String: ShikiSemanticTokenColor]?

    /// Shiki's source-level spelling for `foreground`.
    public var fg: String? {
        get { foreground }
        set { foreground = newValue }
    }

    /// Shiki's source-level spelling for `background`.
    public var bg: String? {
        get { background }
        set { background = newValue }
    }

    public init(
        name: String? = nil,
        displayName: String? = nil,
        type: ShikiThemeType? = nil,
        settings: [ShikiThemeRule]? = nil,
        tokenColors: [ShikiThemeRule]? = nil,
        foreground: String? = nil,
        background: String? = nil,
        colorReplacements: [String: String]? = nil,
        colors: [String: String]? = nil,
        nonStringColors: [String: ShikiJSONValue]? = nil,
        schema: String? = nil,
        include: String? = nil,
        semanticHighlighting: Bool? = nil,
        semanticTokenColors: [String: ShikiSemanticTokenColor]? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.type = type
        self.settings = settings
        self.tokenColors = tokenColors
        self.foreground = foreground
        self.background = background
        self.colorReplacements = colorReplacements
        self.colors = colors
        self.nonStringColors = nonStringColors
        self.schema = schema
        self.include = include
        self.semanticHighlighting = semanticHighlighting
        self.semanticTokenColors = semanticTokenColors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedColors = try decodeThemeColors(from: container, forKey: .colors)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            type: try container.decodeIfPresent(ShikiThemeType.self, forKey: .type),
            settings: try container.decodeIfPresent([ShikiThemeRule].self, forKey: .settings),
            tokenColors: try container.decodeIfPresent(
                [ShikiThemeRule].self,
                forKey: .tokenColors
            ),
            foreground: try container.decodeIfPresent(String.self, forKey: .foreground),
            background: try container.decodeIfPresent(String.self, forKey: .background),
            colorReplacements: try container.decodeIfPresent(
                [String: String].self,
                forKey: .colorReplacements
            ),
            colors: decodedColors.strings,
            nonStringColors: decodedColors.other,
            schema: try container.decodeIfPresent(String.self, forKey: .schema),
            include: try container.decodeIfPresent(String.self, forKey: .include),
            semanticHighlighting: try container.decodeIfPresent(
                Bool.self,
                forKey: .semanticHighlighting
            ),
            semanticTokenColors: try container.decodeIfPresent(
                [String: ShikiSemanticTokenColor].self,
                forKey: .semanticTokenColors
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(settings, forKey: .settings)
        try container.encodeIfPresent(tokenColors, forKey: .tokenColors)
        try container.encodeIfPresent(foreground, forKey: .foreground)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(colorReplacements, forKey: .colorReplacements)
        try encodeThemeColors(
            strings: colors,
            other: nonStringColors,
            to: &container,
            forKey: .colors
        )
        try container.encodeIfPresent(schema, forKey: .schema)
        try container.encodeIfPresent(include, forKey: .include)
        try container.encodeIfPresent(semanticHighlighting, forKey: .semanticHighlighting)
        try container.encodeIfPresent(semanticTokenColors, forKey: .semanticTokenColors)
    }

    public func normalized() -> ShikiResolvedTheme {
        normalizeTheme(self)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case displayName
        case type
        case settings
        case tokenColors
        case foreground = "fg"
        case background = "bg"
        case colorReplacements
        case colors
        case schema = "$schema"
        case include
        case semanticHighlighting
        case semanticTokenColors
    }
}

/// A theme after applying Shiki's TextMate normalization rules.
public struct ShikiResolvedTheme: Codable, Equatable, Sendable {
    public var name: String?
    public var displayName: String?
    public var type: ShikiThemeType
    public var settings: [ShikiThemeRule]
    public var tokenColors: [ShikiThemeRule]?
    public var foreground: String
    public var background: String
    public var colorReplacements: [String: String]
    public var colors: [String: String]?
    public var nonStringColors: [String: ShikiJSONValue]?
    public var schema: String?
    public var include: String?
    public var semanticHighlighting: Bool?
    public var semanticTokenColors: [String: ShikiSemanticTokenColor]?

    /// Shiki's source-level spelling for `foreground`.
    public var fg: String {
        get { foreground }
        set { foreground = newValue }
    }

    /// Shiki's source-level spelling for `background`.
    public var bg: String {
        get { background }
        set { background = newValue }
    }

    public init(
        name: String? = nil,
        displayName: String? = nil,
        type: ShikiThemeType,
        settings: [ShikiThemeRule],
        tokenColors: [ShikiThemeRule]? = nil,
        foreground: String,
        background: String,
        colorReplacements: [String: String] = [:],
        colors: [String: String]? = nil,
        nonStringColors: [String: ShikiJSONValue]? = nil,
        schema: String? = nil,
        include: String? = nil,
        semanticHighlighting: Bool? = nil,
        semanticTokenColors: [String: ShikiSemanticTokenColor]? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.type = type
        self.settings = settings
        self.tokenColors = tokenColors
        self.foreground = foreground
        self.background = background
        self.colorReplacements = colorReplacements
        self.colors = colors
        self.nonStringColors = nonStringColors
        self.schema = schema
        self.include = include
        self.semanticHighlighting = semanticHighlighting
        self.semanticTokenColors = semanticTokenColors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedColors = try decodeThemeColors(from: container, forKey: .colors)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            type: try container.decode(ShikiThemeType.self, forKey: .type),
            settings: try container.decode([ShikiThemeRule].self, forKey: .settings),
            tokenColors: try container.decodeIfPresent(
                [ShikiThemeRule].self,
                forKey: .tokenColors
            ),
            foreground: try container.decode(String.self, forKey: .foreground),
            background: try container.decode(String.self, forKey: .background),
            colorReplacements: try container.decodeIfPresent(
                [String: String].self,
                forKey: .colorReplacements
            ) ?? [:],
            colors: decodedColors.strings,
            nonStringColors: decodedColors.other,
            schema: try container.decodeIfPresent(String.self, forKey: .schema),
            include: try container.decodeIfPresent(String.self, forKey: .include),
            semanticHighlighting: try container.decodeIfPresent(
                Bool.self,
                forKey: .semanticHighlighting
            ),
            semanticTokenColors: try container.decodeIfPresent(
                [String: ShikiSemanticTokenColor].self,
                forKey: .semanticTokenColors
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(type, forKey: .type)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(tokenColors, forKey: .tokenColors)
        try container.encode(foreground, forKey: .foreground)
        try container.encode(background, forKey: .background)
        try container.encode(colorReplacements, forKey: .colorReplacements)
        try encodeThemeColors(
            strings: colors,
            other: nonStringColors,
            to: &container,
            forKey: .colors
        )
        try container.encodeIfPresent(schema, forKey: .schema)
        try container.encodeIfPresent(include, forKey: .include)
        try container.encodeIfPresent(semanticHighlighting, forKey: .semanticHighlighting)
        try container.encodeIfPresent(semanticTokenColors, forKey: .semanticTokenColors)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case displayName
        case type
        case settings
        case tokenColors
        case foreground = "fg"
        case background = "bg"
        case colorReplacements
        case colors
        case schema = "$schema"
        case include
        case semanticHighlighting
        case semanticTokenColors
    }
}

private func decodeThemeColors<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> (strings: [String: String]?, other: [String: ShikiJSONValue]?) {
    guard let raw = try container.decodeIfPresent(
        [String: ShikiJSONValue].self,
        forKey: key
    ) else {
        return (nil, nil)
    }

    var strings: [String: String] = [:]
    var other: [String: ShikiJSONValue] = [:]
    for (name, value) in raw {
        if case let .string(color) = value {
            strings[name] = color
        } else {
            other[name] = value
        }
    }
    return (strings, other.isEmpty ? nil : other)
}

private func encodeThemeColors<Key: CodingKey>(
    strings: [String: String]?,
    other: [String: ShikiJSONValue]?,
    to container: inout KeyedEncodingContainer<Key>,
    forKey key: Key
) throws {
    guard strings != nil || other != nil else { return }
    var raw = other ?? [:]
    for (name, value) in strings ?? [:] {
        raw[name] = .string(value)
    }
    try container.encode(raw, forKey: key)
}

private let vscodeFallbackEditorForeground: [ShikiThemeType: String] = [
    .light: "#333333",
    .dark: "#bbbbbb",
]

private let vscodeFallbackEditorBackground: [ShikiThemeType: String] = [
    .light: "#fffffe",
    .dark: "#1e1e1e",
]

/// Normalizes a TextMate/VS Code theme using Shiki v4.4.3's precedence rules.
public func normalizeTheme(_ rawTheme: ShikiTheme) -> ShikiResolvedTheme {
    let type = rawTheme.type ?? .dark

    var settings: [ShikiThemeRule]
    var tokenColors = rawTheme.tokenColors
    if let rawSettings = rawTheme.settings {
        // JavaScript treats an empty array as truthy, so it suppresses the
        // tokenColors fallback just like a populated settings array does.
        settings = rawSettings
    } else if let fallbackSettings = rawTheme.tokenColors {
        settings = fallbackSettings
        tokenColors = nil
    } else {
        settings = []
    }

    var foreground = rawTheme.foreground
    var background = rawTheme.background

    // JavaScript's `!bg || !fg` treats empty strings as missing.
    if !isTruthy(foreground) || !isTruthy(background) {
        let globalSetting = settings.first { rule in
            !isTruthy(rule.name) && isFalsyScope(rule.scope)
        }

        // These assignments intentionally happen even if the corresponding
        // top-level color was present. This is how Shiki v4.4.3 behaves once
        // either top-level color is missing.
        if let globalForeground = globalSetting?.settings?.foreground,
           isTruthy(globalForeground) {
            foreground = globalForeground
        }
        if let globalBackground = globalSetting?.settings?.background,
           isTruthy(globalBackground) {
            background = globalBackground
        }

        if !isTruthy(foreground),
           let editorForeground = rawTheme.colors?["editor.foreground"],
           isTruthy(editorForeground) {
            foreground = editorForeground
        }
        if !isTruthy(background),
           let editorBackground = rawTheme.colors?["editor.background"],
           isTruthy(editorBackground) {
            background = editorBackground
        }

        if !isTruthy(foreground) {
            foreground = vscodeFallbackEditorForeground[type]
        }
        if !isTruthy(background) {
            background = vscodeFallbackEditorBackground[type]
        }
    }

    // The branches above always produce nonempty values. The nil coalescing is
    // only a static guarantee for Swift and matches Shiki's final fallback.
    let resolvedForeground = foreground ?? vscodeFallbackEditorForeground[type]!
    let resolvedBackground = background ?? vscodeFallbackEditorBackground[type]!

    // JS checks the first rule's settings object and the truthiness of scope.
    let firstRuleIsGlobal = settings.first.map { rule in
        rule.settings != nil && isFalsyScope(rule.scope)
    } ?? false

    if !firstRuleIsGlobal {
        settings.insert(
            ShikiThemeRule(
                settings: ShikiThemeTokenSettings(
                    foreground: resolvedForeground,
                    background: resolvedBackground
                )
            ),
            at: 0
        )
    }

    var colorReplacements = rawTheme.colorReplacements ?? [:]
    var replacementCount = 0
    var replacementMap: [String: String] = [:]

    func replacementColor(for value: String) -> String {
        if let replacement = replacementMap[value] {
            return replacement
        }

        while true {
            replacementCount += 1
            let digits = String(replacementCount, radix: 16, uppercase: false)
            let padding = String(repeating: "0", count: max(0, 8 - digits.count))
            let candidate = "#\(padding)\(digits)"

            // This deliberately includes the extra leading '#'. Shiki 4.4.3
            // checks `colorReplacements[`#${hex}`]` after `hex` already gained
            // a '#', and only skips the candidate for a truthy mapped value.
            if let existing = colorReplacements["#\(candidate)"], !existing.isEmpty {
                continue
            }

            replacementMap[value] = candidate
            return candidate
        }
    }

    settings = settings.map { rule in
        guard var tokenSettings = rule.settings else {
            return rule
        }

        let replaceForeground = tokenSettings.foreground.map {
            !$0.isEmpty && !$0.hasPrefix("#")
        } ?? false
        let replaceBackground = tokenSettings.background.map {
            !$0.isEmpty && !$0.hasPrefix("#")
        } ?? false

        guard replaceForeground || replaceBackground else {
            return rule
        }

        if replaceForeground, let original = tokenSettings.foreground {
            let replacement = replacementColor(for: original)
            colorReplacements[replacement] = original
            tokenSettings.foreground = replacement
        }
        if replaceBackground, let original = tokenSettings.background {
            let replacement = replacementColor(for: original)
            colorReplacements[replacement] = original
            tokenSettings.background = replacement
        }

        var copy = rule
        copy.settings = tokenSettings
        return copy
    }

    var colors = rawTheme.colors
    for key in colors?.keys.map({ $0 }) ?? [] {
        guard isColorPatchedByShiki(key), let original = colors?[key] else {
            continue
        }
        if !original.hasPrefix("#") {
            let replacement = replacementColor(for: original)
            colorReplacements[replacement] = original
            colors?[key] = replacement
        }
    }

    return ShikiResolvedTheme(
        name: rawTheme.name,
        displayName: rawTheme.displayName,
        type: type,
        settings: settings,
        tokenColors: tokenColors,
        foreground: resolvedForeground,
        background: resolvedBackground,
        colorReplacements: colorReplacements,
        colors: colors,
        nonStringColors: rawTheme.nonStringColors,
        schema: rawTheme.schema,
        include: rawTheme.include,
        semanticHighlighting: rawTheme.semanticHighlighting,
        semanticTokenColors: rawTheme.semanticTokenColors
    )
}

/// Resolved themes are idempotent under Shiki normalization.
public func normalizeTheme(_ theme: ShikiResolvedTheme) -> ShikiResolvedTheme {
    theme
}

private func isTruthy(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.isEmpty
}

private func isFalsyScope(_ scope: ShikiThemeScope?) -> Bool {
    switch scope {
    case nil:
        true
    case let .string(value):
        value.isEmpty
    case .array:
        // Arrays are JavaScript objects and remain truthy even when empty.
        false
    }
}

private func isColorPatchedByShiki(_ key: String) -> Bool {
    key == "editor.foreground"
        || key == "editor.background"
        || key.hasPrefix("terminal.ansi")
}

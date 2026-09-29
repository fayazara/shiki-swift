import Foundation

/// One entry in Shiki's `colorReplacements` tokenization option.
///
/// A string applies globally. An object is applied only when its key matches
/// the active theme name.
public enum ShikiColorReplacementOption: Equatable, Sendable {
    case color(String)
    case theme([String: String])
}

extension ShikiColorReplacementOption: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let color = try? container.decode(String.self) {
            self = .color(color)
        } else {
            self = .theme(try container.decode([String: String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .color(color):
            try container.encode(color)
        case let .theme(replacements):
            try container.encode(replacements)
        }
    }
}

/// Merges a resolved theme's replacements with Shiki tokenization overrides.
public func resolveColorReplacements(
    for theme: ShikiResolvedTheme,
    overrides: [String: ShikiColorReplacementOption] = [:]
) -> [String: String] {
    resolveColorReplacements(
        themeName: theme.name,
        themeReplacements: theme.colorReplacements,
        overrides: overrides
    )
}

/// Merges a raw theme's replacements with Shiki tokenization overrides.
public func resolveColorReplacements(
    for theme: ShikiTheme,
    overrides: [String: ShikiColorReplacementOption] = [:]
) -> [String: String] {
    resolveColorReplacements(
        themeName: theme.name,
        themeReplacements: theme.colorReplacements ?? [:],
        overrides: overrides
    )
}

/// Resolves replacements when the active theme is referenced only by name.
public func resolveColorReplacements(
    forThemeNamed themeName: String,
    overrides: [String: ShikiColorReplacementOption] = [:]
) -> [String: String] {
    resolveColorReplacements(
        themeName: themeName,
        themeReplacements: [:],
        overrides: overrides
    )
}

/// Applies Shiki's case-normalized replacement lookup to one color.
///
/// Replacement keys are expected to already be lowercase, matching Shiki's
/// public contract. An empty replacement is falsy in JavaScript and therefore
/// leaves the input color unchanged.
public func applyColorReplacements(
    _ color: String?,
    replacements: [String: String]?
) -> String? {
    guard let color, !color.isEmpty else {
        return color
    }

    if let replacement = replacements?[color.lowercased()], !replacement.isEmpty {
        return replacement
    }
    return color
}

private func resolveColorReplacements(
    themeName: String?,
    themeReplacements: [String: String],
    overrides: [String: ShikiColorReplacementOption]
) -> [String: String] {
    var replacements = themeReplacements

    // Shiki applies options in object insertion order. Swift dictionaries
    // have no stable order, so apply global string replacements first (in
    // sorted key order) and then the active theme's scoped object. A theme-
    // specific replacement therefore wins over a global one for the same key
    // in every run.
    for key in overrides.keys.sorted() {
        if case let .color(color) = overrides[key]! {
            replacements[key] = color
        }
    }
    if let themeName, case let .theme(scopedReplacements)? = overrides[themeName] {
        replacements.merge(scopedReplacements) { _, new in new }
    }

    return replacements
}

/// Precomputes replaced colors for a whole color map so tokenization can apply
/// replacements with one array lookup per token instead of lowercasing and
/// hashing each token's color.
public func applyColorReplacements(
    toColorMap colorMap: [String?],
    replacements: [String: String]
) -> [String?] {
    guard !replacements.isEmpty else { return colorMap }
    return colorMap.map { applyColorReplacements($0, replacements: replacements) }
}

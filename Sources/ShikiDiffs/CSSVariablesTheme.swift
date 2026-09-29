#if os(macOS)
import Shiki

/// Source-compatible inputs for Shiki's CSS-variable theme factory.
public struct CSSVariablesThemeOptions: Sendable {
    public var name: String
    public var variablePrefix: String
    public var variableDefaults: [String: String]
    public var fontStyle: Bool
    public init(name: String = "css-variables", variablePrefix: String = "--shiki-",
                variableDefaults: [String: String] = [:], fontStyle: Bool = true) {
        self.name = name; self.variablePrefix = variablePrefix
        self.variableDefaults = variableDefaults; self.fontStyle = fontStyle
    }
}

/// Produces the same raw theme as Shiki, including CSS var() expressions.
/// Resolve it with `createResolvedCSSVariablesTheme` before native rendering.
public func createCSSVariablesTheme(_ options: CSSVariablesThemeOptions = .init()) -> ShikiTheme {
    cssVariablesTheme(options) { role in
        let key = options.variablePrefix + role
        if let fallback = options.variableDefaults[role], !fallback.isEmpty {
            return "var(\(key), \(fallback))"
        }
        return "var(\(key))"
    }
}

public enum CSSVariableThemeError: Error, Equatable, Sendable {
    case missingValue(String)
    case invalidColor(variable: String, value: String)
}

/// Native adaptation: resolves fully prefixed variable keys over unprefixed defaults.
/// Every referenced role must resolve to a hex color; no browser cascade is assumed.
/// Recreate/register the theme when host appearance values change.
public func createResolvedCSSVariablesTheme(_ options: CSSVariablesThemeOptions = .init(),
                                           variables: [String: String] = [:]) throws -> ShikiTheme {
    try cssVariablesTheme(options) { role in
        let key = options.variablePrefix + role
        guard let value = variables[key] ?? options.variableDefaults[role], !value.isEmpty else {
            throw CSSVariableThemeError.missingValue(key)
        }
        let digits = Array(value.dropFirst())
        guard value.first == "#", [3, 4, 6, 8].contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw CSSVariableThemeError.invalidColor(variable: key, value: value)
        }
        return digits.count <= 4 ? "#" + String(digits.flatMap { [$0, $0] }) : value
    }
}

public extension DiffHighlighter {
    /// Lazy, first-registration-wins like upstream. Values are resolved when loaded.
    /// Defaults are unprefixed; overrides use the upstream `--diffs-` prefix.
    @discardableResult
    func registerCustomCSSVariableTheme(_ name: String, variableDefaults: [String: String],
                                        fontStyle: Bool = false,
                                        variables: [String: String] = [:]) -> Bool {
        let options = CSSVariablesThemeOptions(name: name, variablePrefix: formatCSSVariablePrefix(.global),
                                               variableDefaults: variableDefaults, fontStyle: fontStyle)
        return registerCustomTheme(name) { try createResolvedCSSVariablesTheme(options, variables: variables) }
    }
}

// Scope order and shape from Shiki v3.13.0 packages/core/src/theme-css-variables.ts.
// Copyright Shiki contributors, MIT; see LICENSES/Shiki-MIT.txt.
private func cssVariablesTheme(_ options: CSSVariablesThemeOptions,
                               variable: (String) throws -> String) rethrows -> ShikiTheme {
    ShikiTheme(name: options.name, type: .dark, tokenColors: [
        .init(scope: .array(["keyword.operator.accessor", "meta.group.braces.round.function.arguments", "meta.template.expression", "markup.fenced_code meta.embedded.block"]), settings: .init(foreground: try variable("foreground"))),
        .init(scope: .string("emphasis"), settings: .init(fontStyle: options.fontStyle ? "italic" : nil)),
        .init(scope: .array(["strong", "markup.heading.markdown", "markup.bold.markdown"]), settings: .init(fontStyle: options.fontStyle ? "bold" : nil)),
        .init(scope: .array(["markup.italic.markdown"]), settings: .init(fontStyle: options.fontStyle ? "italic" : nil)),
        .init(scope: .string("meta.link.inline.markdown"), settings: .init(fontStyle: options.fontStyle ? "underline" : nil, foreground: try variable("token-link"))),
        .init(scope: .array(["string", "markup.fenced_code", "markup.inline"]), settings: .init(foreground: try variable("token-string"))),
        .init(scope: .array(["comment", "string.quoted.docstring.multi"]), settings: .init(foreground: try variable("token-comment"))),
        .init(scope: .array(["constant.numeric", "constant.language", "constant.other.placeholder", "constant.character.format.placeholder", "variable.language.this", "variable.other.object", "variable.other.class", "variable.other.constant", "meta.property-name", "meta.property-value", "support"]), settings: .init(foreground: try variable("token-constant"))),
        .init(scope: .array(["keyword", "storage.modifier", "storage.type", "storage.control.clojure", "entity.name.function.clojure", "entity.name.tag.yaml", "support.function.node", "support.type.property-name.json", "punctuation.separator.key-value", "punctuation.definition.template-expression"]), settings: .init(foreground: try variable("token-keyword"))),
        .init(scope: .string("variable.parameter.function"), settings: .init(foreground: try variable("token-parameter"))),
        .init(scope: .array(["support.function", "entity.name.type", "entity.other.inherited-class", "meta.function-call", "meta.instance.constructor", "entity.other.attribute-name", "entity.name.function", "constant.keyword.clojure"]), settings: .init(foreground: try variable("token-function"))),
        .init(scope: .array(["entity.name.tag", "string.quoted", "string.regexp", "string.interpolated", "string.template", "string.unquoted.plain.out.yaml", "keyword.other.template"]), settings: .init(foreground: try variable("token-string-expression"))),
        .init(scope: .array(["punctuation.definition.arguments", "punctuation.definition.dict", "punctuation.separator", "meta.function-call.arguments"]), settings: .init(foreground: try variable("token-punctuation"))),
        .init(scope: .array(["markup.underline.link", "punctuation.definition.metadata.markdown"]), settings: .init(foreground: try variable("token-link"))),
        .init(scope: .array(["beginning.punctuation.definition.list.markdown"]), settings: .init(foreground: try variable("token-string"))),
        .init(scope: .array(["punctuation.definition.string.begin.markdown", "punctuation.definition.string.end.markdown", "string.other.link.title.markdown", "string.other.link.description.markdown"]), settings: .init(foreground: try variable("token-keyword"))),
        .init(scope: .array(["markup.inserted", "meta.diff.header.to-file", "punctuation.definition.inserted"]), settings: .init(foreground: try variable("token-inserted"))),
        .init(scope: .array(["markup.deleted", "meta.diff.header.from-file", "punctuation.definition.deleted"]), settings: .init(foreground: try variable("token-deleted"))),
        .init(scope: .array(["markup.changed", "punctuation.definition.changed"]), settings: .init(foreground: try variable("token-changed"))),
    ], colors: [
        "editor.foreground": try variable("foreground"),
        "editor.background": try variable("background"),
        "terminal.ansiBlack": try variable("ansi-black"),
        "terminal.ansiRed": try variable("ansi-red"),
        "terminal.ansiGreen": try variable("ansi-green"),
        "terminal.ansiYellow": try variable("ansi-yellow"),
        "terminal.ansiBlue": try variable("ansi-blue"),
        "terminal.ansiMagenta": try variable("ansi-magenta"),
        "terminal.ansiCyan": try variable("ansi-cyan"),
        "terminal.ansiWhite": try variable("ansi-white"),
        "terminal.ansiBrightBlack": try variable("ansi-bright-black"),
        "terminal.ansiBrightRed": try variable("ansi-bright-red"),
        "terminal.ansiBrightGreen": try variable("ansi-bright-green"),
        "terminal.ansiBrightYellow": try variable("ansi-bright-yellow"),
        "terminal.ansiBrightBlue": try variable("ansi-bright-blue"),
        "terminal.ansiBrightMagenta": try variable("ansi-bright-magenta"),
        "terminal.ansiBrightCyan": try variable("ansi-bright-cyan"),
        "terminal.ansiBrightWhite": try variable("ansi-bright-white"),
    ])
}

#endif

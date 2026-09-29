import Foundation

/// Shiki's `defaultColor` option for multi-theme `codeToTokens`.
public enum ShikiDefaultColor: Equatable, Sendable {
    /// The named variant (for example `light`) supplies plain CSS properties;
    /// the other variants are emitted as CSS variables.
    case variant(String)
    /// Emits `light-dark(light, dark)` for color properties.
    case lightDark
    /// Every variant, including the first, is emitted as CSS variables.
    case disabled

    /// Shiki's default, `'light'`.
    public static let light = ShikiDefaultColor.variant("light")
}

/// Shiki's `colorsRendering` option.
public enum ShikiColorsRendering: String, Equatable, Sendable {
    case cssVars = "css-vars"
    case none
}

public enum ShikiThemeVariantStyleError: Error, Equatable, Sendable, CustomStringConvertible {
    case lightDarkRequiresLightAndDark

    public var description: String {
        "When using `defaultColor: \"light-dark()\"`, you must provide both `light` and `dark` themes"
    }
}

/// CSS declarations for one theme's token styles, in Shiki's key order.
public func getTokenStyleObject(_ styles: TokenStyles) -> [(key: String, value: String)] {
    var result: [(String, String)] = []
    if let color = styles.color, !color.isEmpty {
        result.append(("color", color))
    }
    if let background = styles.bgColor, !background.isEmpty {
        result.append(("background-color", background))
    }
    if let fontStyle = styles.fontStyle, fontStyle != .none, fontStyle != .notSet {
        if fontStyle.contains(.italic) { result.append(("font-style", "italic")) }
        if fontStyle.contains(.bold) { result.append(("font-weight", "bold")) }
        var decorations: [String] = []
        if fontStyle.contains(.underline) { decorations.append("underline") }
        if fontStyle.contains(.strikethrough) { decorations.append("line-through") }
        if !decorations.isEmpty {
            result.append(("text-decoration", decorations.joined(separator: " ")))
        }
    }
    return result
}

/// Native port of Shiki's `flatTokenVariants`: collapses a multi-theme token
/// into a single token whose `htmlStyle` carries CSS properties/variables.
public func flatTokenVariants(
    _ merged: ThemedTokenWithVariants,
    variantsOrder: [String],
    cssVariablePrefix: String = "--shiki-",
    defaultColor: ShikiDefaultColor = .light,
    colorsRendering: ShikiColorsRendering = .cssVars
) throws -> ThemedToken {
    var token = ThemedToken(
        content: merged.content,
        offset: merged.offset,
        explanation: merged.explanation
    )

    let styles = variantsOrder.map { name in
        getTokenStyleObject(merged.variants[name] ?? TokenStyles())
    }
    var styleKeys: [String] = []
    var seenKeys: Set<String> = []
    for style in styles {
        for entry in style where seenKeys.insert(entry.key).inserted {
            styleKeys.append(entry.key)
        }
    }

    func lookup(_ index: Int, _ key: String) -> String? {
        styles[index].first(where: { $0.key == key })?.value
    }
    func varKey(_ index: Int, _ key: String) -> String {
        let suffix = key == "color" ? "" : key == "background-color" ? "-bg" : "-\(key)"
        return cssVariablePrefix + variantsOrder[index] + suffix
    }

    var merged: [String: String] = [:]
    for index in styles.indices {
        for key in styleKeys {
            let value = lookup(index, key) ?? "inherit"
            let isColorKey = key == "color" || key == "background-color"
            if index == 0, defaultColor != .disabled, isColorKey {
                if defaultColor == .lightDark, styles.count > 1 {
                    guard
                        let light = variantsOrder.firstIndex(of: "light"),
                        let dark = variantsOrder.firstIndex(of: "dark")
                    else {
                        throw ShikiThemeVariantStyleError.lightDarkRequiresLightAndDark
                    }
                    merged[key] = "light-dark(\(lookup(light, key) ?? "inherit"), \(lookup(dark, key) ?? "inherit"))"
                    if colorsRendering == .cssVars {
                        merged[varKey(index, key)] = value
                    }
                } else {
                    merged[key] = value
                }
            } else if colorsRendering == .cssVars {
                merged[varKey(index, key)] = value
            }
        }
    }

    token.htmlStyle = merged
    return token
}

import Foundation

/// Native port of Shiki's `ansi` pseudo-language (`tokenizeAnsiWithTheme`,
/// backed by `ansi-sequence-parser`).
///
/// SGR escape sequences (`ESC [ … m`) are removed from the token content and
/// turned into colors and font styles. Colors come from the theme's
/// `terminal.ansi*` workbench colors with VS Code fallbacks.
///
/// Offsets are the UTF-16 position of each token's text in the original
/// source (escape sequences excluded from the content but counted in the
/// offset). Upstream currently reports the line offset for every token.
public func tokenizeAnsiWithTheme(
    _ code: String,
    theme: ShikiResolvedTheme,
    options: TokenizeWithThemeOptions = .init()
) -> [[ThemedToken]] {
    let replacements = resolveColorReplacements(
        for: theme,
        overrides: options.colorReplacements ?? [:]
    )
    let palette = AnsiColorPalette(theme: theme)
    var parser = AnsiSequenceParser()

    return splitLines(code).map { line in
        parser.parse(line.content).map { token in
            var color: String?
            var bgColor: String?
            if token.decorations.contains(.reverse) {
                color = token.background.map(palette.value) ?? theme.background
                bgColor = token.foreground.map(palette.value) ?? theme.foreground
            } else {
                color = token.foreground.map(palette.value) ?? theme.foreground
                bgColor = token.background.map(palette.value)
            }

            color = applyColorReplacements(color, replacements: replacements)
            bgColor = applyColorReplacements(bgColor, replacements: replacements)

            if token.decorations.contains(.dim), let current = color {
                color = dimAnsiColor(current)
            }

            var fontStyle: FontStyle = .none
            if token.decorations.contains(.bold) { fontStyle.insert(.bold) }
            if token.decorations.contains(.italic) { fontStyle.insert(.italic) }
            if token.decorations.contains(.underline) { fontStyle.insert(.underline) }
            if token.decorations.contains(.strikethrough) { fontStyle.insert(.strikethrough) }

            return ThemedToken(
                content: token.value,
                offset: line.offset + token.utf16Offset,
                color: color,
                bgColor: bgColor,
                fontStyle: fontStyle
            )
        }
    }
}

// MARK: - Parser

enum AnsiColor: Equatable {
    case named(Int)
    case table(Int)
    case rgb(Int, Int, Int)
}

struct AnsiDecorations: OptionSet {
    let rawValue: UInt16

    static let bold = Self(rawValue: 1 << 0)
    static let dim = Self(rawValue: 1 << 1)
    static let italic = Self(rawValue: 1 << 2)
    static let underline = Self(rawValue: 1 << 3)
    static let reverse = Self(rawValue: 1 << 4)
    static let hidden = Self(rawValue: 1 << 5)
    static let strikethrough = Self(rawValue: 1 << 6)
    static let overline = Self(rawValue: 1 << 7)

    /// SGR parameters 1…9 (and 21…29 to reset them).
    static func forCode(_ code: Int) -> AnsiDecorations? {
        switch code {
        case 1: .bold
        case 2: .dim
        case 3: .italic
        case 4: .underline
        case 7: .reverse
        case 8: .hidden
        case 9: .strikethrough
        default: nil
        }
    }
}

struct AnsiToken {
    let value: String
    let utf16Offset: Int
    let foreground: AnsiColor?
    let background: AnsiColor?
    let decorations: AnsiDecorations
}

/// Stateful across lines, like `createAnsiSequenceParser()`.
struct AnsiSequenceParser {
    private var foreground: AnsiColor?
    private var background: AnsiColor?
    private var decorations: AnsiDecorations = []

    mutating func parse(_ line: String) -> [AnsiToken] {
        let units = Array(line.utf16)
        var tokens: [AnsiToken] = []
        var position = 0

        while position < units.count {
            let sequence = findSequence(units, from: position)
            let textEnd = sequence?.start ?? units.count
            if textEnd > position {
                tokens.append(AnsiToken(
                    value: String(decoding: units[position..<textEnd], as: UTF16.self),
                    utf16Offset: position,
                    foreground: foreground,
                    background: background,
                    decorations: decorations
                ))
            }
            guard let sequence else { break }
            apply(parameters: sequence.parameters)
            position = sequence.end
        }
        return tokens
    }

    private func findSequence(
        _ units: [UInt16],
        from start: Int
    ) -> (start: Int, end: Int, parameters: String)? {
        var index = start
        while index < units.count {
            if units[index] == 0x1B, index + 1 < units.count, units[index + 1] == 0x5B {
                // CSI: parameters are 0x30–0x3F, intermediates 0x20–0x2F, and
                // the final byte is 0x40–0x7E. Only SGR (`m`) changes style;
                // other control sequences are removed from the output.
                var cursor = index + 2
                while cursor < units.count, (0x20...0x3F).contains(units[cursor]) {
                    cursor += 1
                }
                if cursor < units.count, (0x40...0x7E).contains(units[cursor]) {
                    let parameters = units[cursor] == 0x6D
                        ? String(decoding: units[(index + 2)..<cursor], as: UTF16.self)
                        : nil
                    return (index, cursor + 1, parameters ?? "\u{0}")
                }
                return nil
            }
            index += 1
        }
        return nil
    }

    private mutating func apply(parameters: String) {
        // A non-SGR control sequence: strip it without changing style.
        if parameters == "\u{0}" { return }

        let codes = parameters.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) }
        var setForeground: AnsiColor??
        var setBackground: AnsiColor??
        var addDecorations: AnsiDecorations = []
        var removeDecorations: AnsiDecorations = []
        var resetAll = false

        // `ESC[m` is equivalent to `ESC[0m`.
        if codes.count == 1, codes[0] == nil { resetAll = true }

        var index = 0
        while index < codes.count {
            guard let code = codes[index] else {
                index += 1
                continue
            }
            switch code {
            case 0:
                resetAll = true
            case 1...9:
                if let decoration = AnsiDecorations.forCode(code) {
                    addDecorations.insert(decoration)
                }
            case 21...29:
                if let decoration = AnsiDecorations.forCode(code - 20) {
                    removeDecorations.insert(decoration)
                    if decoration == .dim { removeDecorations.insert(.bold) }
                }
            case 30...37:
                setForeground = .some(.named(code - 30))
            case 38, 48:
                if let (color, consumed) = parseExtendedColor(codes, at: index) {
                    if code == 38 { setForeground = .some(color) } else { setBackground = .some(color) }
                    index += consumed
                }
            case 39:
                setForeground = .some(nil)
            case 40...47:
                setBackground = .some(.named(code - 40))
            case 49:
                setBackground = .some(nil)
            case 53:
                addDecorations.insert(.overline)
            case 55:
                removeDecorations.insert(.overline)
            case 90...97:
                setForeground = .some(.named(code - 90 + 8))
            case 100...107:
                setBackground = .some(.named(code - 100 + 8))
            default:
                break
            }
            index += 1
        }

        // ansi-sequence-parser applies all resets before all sets.
        if resetAll {
            foreground = nil
            background = nil
            decorations = []
        }
        if case .some(nil) = setForeground { foreground = nil }
        if case .some(nil) = setBackground { background = nil }
        decorations.subtract(removeDecorations)
        if case let .some(.some(color)) = setForeground { foreground = color }
        if case let .some(.some(color)) = setBackground { background = color }
        decorations.formUnion(addDecorations)
    }

    private func parseExtendedColor(
        _ codes: [Int?],
        at index: Int
    ) -> (AnsiColor, Int)? {
        guard index + 1 < codes.count, let mode = codes[index + 1] else { return nil }
        if mode == 5, index + 2 < codes.count, let value = codes[index + 2] {
            return (.table(value), 2)
        }
        if mode == 2, index + 4 < codes.count,
           let red = codes[index + 2], let green = codes[index + 3], let blue = codes[index + 4]
        {
            return (.rgb(red, green, blue), 4)
        }
        return nil
    }
}

// MARK: - Palette

private let ansiNamedColorKeys = [
    "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
    "BrightBlack", "BrightRed", "BrightGreen", "BrightYellow",
    "BrightBlue", "BrightMagenta", "BrightCyan", "BrightWhite",
]

private let ansiDefaultColors = [
    "#000000", "#cd3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
    "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#FFFFFF",
]

struct AnsiColorPalette {
    private let named: [String]
    private var table: [String] = []

    init(theme: ShikiResolvedTheme) {
        named = ansiNamedColorKeys.enumerated().map { index, key in
            if let value = theme.colors?["terminal.ansi\(key)"], !value.isEmpty {
                return value
            }
            return ansiDefaultColors[index]
        }
        var table = named
        let levels = [0, 95, 135, 175, 215, 255]
        for red in levels {
            for green in levels {
                for blue in levels {
                    table.append(Self.hex(red, green, blue))
                }
            }
        }
        var level = 8
        for _ in 0..<24 {
            table.append(Self.hex(level, level, level))
            level += 10
        }
        self.table = table
    }

    func value(_ color: AnsiColor) -> String {
        switch color {
        case let .named(index):
            return named.indices.contains(index) ? named[index] : named[0]
        case let .table(index):
            return table.indices.contains(index) ? table[index] : ""
        case let .rgb(red, green, blue):
            return Self.hex(red, green, blue)
        }
    }

    private static func hex(_ red: Int, _ green: Int, _ blue: Int) -> String {
        "#" + [red, green, blue].map { component in
            let clamped = max(0, min(component, 255))
            let digits = String(clamped, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}

/// Adds 50% alpha to a hex color, or a `-dim` suffix to an ANSI CSS variable.
func dimAnsiColor(_ color: String) -> String {
    let units = Array(color.utf8)
    if let hashIndex = units.firstIndex(of: UInt8(ascii: "#")) {
        var end = hashIndex + 1
        while end < units.count, end - hashIndex - 1 < 8, isHexDigit(units[end]) {
            end += 1
        }
        let hex = String(decoding: units[(hashIndex + 1)..<end], as: UTF8.self)
        let chars = Array(hex)
        func halfAlpha(_ value: String) -> String {
            let alpha = Int((Double(Int(value, radix: 16) ?? 0) / 2).rounded())
            let digits = String(alpha, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }
        switch chars.count {
        case 8:
            return "#\(String(chars[0..<6]))\(halfAlpha(String(chars[6..<8])))"
        case 6:
            return "#\(hex)80"
        case 4:
            let (r, g, b, a) = (chars[0], chars[1], chars[2], chars[3])
            return "#\(r)\(r)\(g)\(g)\(b)\(b)\(halfAlpha("\(a)\(a)"))"
        case 3:
            let (r, g, b) = (chars[0], chars[1], chars[2])
            return "#\(r)\(r)\(g)\(g)\(b)\(b)80"
        default:
            break
        }
    }

    if let range = color.range(of: #"var\((--[\w-]+-ansi-[\w-]+)\)"#, options: .regularExpression) {
        let inner = color[range].dropFirst(4).dropLast()
        return "var(\(inner)-dim)"
    }
    return color
}

private func isHexDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
}

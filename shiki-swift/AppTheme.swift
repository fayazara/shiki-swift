import AppKit
import Observation
import Shiki
import ShikiUI
import SwiftUI

/// The app-wide Shiki theme. Code *and* window chrome are derived from the
/// selected VS Code theme's `colors`, so switching themes restyles everything.
@Observable
final class AppTheme {
    static let all: [ShikiThemeInfo] = BundledShikiAssets.shared.themes.sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    static let dark = all.filter { !$0.type.isLight }
    static let light = all.filter { $0.type.isLight }

    /// How the app picks between its light and dark theme.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var symbol: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max"
            case .dark: "moon"
            }
        }
    }

    private enum Key {
        static let appearance = "appAppearance"
        static let light = "appLightThemeID"
        static let dark = "appDarkThemeID"
        static let legacy = "appThemeID"
        static let codeFont = "codeFontFamily"
    }

    var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    /// Theme shown in light mode / dark mode.
    /// The family used for code, or `nil` for the system monospaced font.
    /// Only fixed-pitch families from `CodeFonts.families` are accepted.
    var codeFontFamily: String? {
        didSet {
            UserDefaults.standard.set(codeFontFamily, forKey: Key.codeFont)
            fontCache.removeAll()
        }
    }
    @ObservationIgnored private var fontCache: [CGFloat: NSFont] = [:]

    private(set) var lightThemeID: String { didSet { UserDefaults.standard.set(lightThemeID, forKey: Key.light) } }
    private(set) var darkThemeID: String { didSet { UserDefaults.standard.set(darkThemeID, forKey: Key.dark) } }

    /// The system's appearance, tracked so `.system` can follow it live.
    private var systemIsDark: Bool
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    var isDark: Bool {
        switch appearance {
        case .system: systemIsDark
        case .light: false
        case .dark: true
        }
    }

    /// The active theme. Setting one stores it as the light or dark theme
    /// (by its type) and switches the appearance to show it.
    var themeID: String {
        get { isDark ? darkThemeID : lightThemeID }
        set {
            guard let info = Self.all.first(where: { $0.id == newValue }) else { return }
            if info.type.isLight { lightThemeID = newValue } else { darkThemeID = newValue }
            if info.type.isLight == isDark { appearance = info.type.isLight ? .light : .dark }
        }
    }

    var palette: Palette { Palette.cached(themeID) }

    init() {
        let defaults = UserDefaults.standard
        func valid(_ id: String?, light: Bool) -> String? {
            id.flatMap { id in Self.all.contains { $0.id == id && $0.type.isLight == light } ? id : nil }
        }
        let legacy = defaults.string(forKey: Key.legacy)
        lightThemeID = valid(defaults.string(forKey: Key.light), light: true)
            ?? valid(legacy, light: true) ?? Self.light.first { $0.id == "github-light" }?.id ?? Self.light[0].id
        darkThemeID = valid(defaults.string(forKey: Key.dark), light: false)
            ?? valid(legacy, light: false) ?? Self.dark.first { $0.id == "github-dark" }?.id ?? Self.dark[0].id
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        systemIsDark = Self.systemPrefersDark()
        codeFontFamily = defaults.string(forKey: Key.codeFont).flatMap { CodeFonts.families.contains($0) ? $0 : nil }
        applyAppearance()

        // Re-read the system setting whenever the app's appearance changes;
        // while following the system, that is exactly the OS toggle.
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.systemIsDark = Self.systemPrefersDark() }
        }
    }

    var info: ShikiThemeInfo? { Self.all.first { $0.id == themeID } }

    /// The code font at `size`; the same instance is returned while the family
    /// is unchanged, so views can pass it to AppKit without triggering rebuilds.
    func codeNSFont(size: CGFloat) -> NSFont {
        if let cached = fontCache[size] { return cached }
        let font = CodeFonts.font(family: codeFontFamily, size: size)
        fontCache[size] = font
        return font
    }

    func codeFont(size: CGFloat) -> Font {
        Font(codeNSFont(size: size) as CTFont)
    }

    /// Width of one column, for gutters and alignment.
    func codeAdvance(size: CGFloat) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: codeNSFont(size: size)]).width
    }

    /// Drives window chrome; `nil` lets AppKit follow the system.
    private func applyAppearance() {
        systemIsDark = Self.systemPrefersDark()
        NSApplication.shared.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private static func systemPrefersDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// Themes matching the current appearance, so cycling never flips modes.
    private var current: [ShikiThemeInfo] { isDark ? Self.dark : Self.light }

    /// Cycles through the current appearance's themes in display order.
    func step(_ offset: Int) {
        let themes = current
        guard let index = themes.firstIndex(where: { $0.id == themeID }) else { return }
        let count = themes.count
        themeID = themes[((index + offset) % count + count) % count].id
    }

    func shuffle() {
        themeID = current.filter { $0.id != themeID }.randomElement()?.id ?? themeID
    }
}

/// The system's monospaced font families.
enum CodeFonts {
    static let systemName = "System Mono"

    /// Every installed family whose regular face is monospaced, sorted by
    /// name: either flagged fixed-pitch, or measured (so coding fonts with a
    /// missing flag still appear) with equal advances for `i M W . l 0`.
    /// Hidden system families and symbol-only faces are left out.
    static let families: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .filter { family in
                guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 16) else { return false }
                return drawsLetters(font) && (font.isFixedPitch || hasEqualAdvances(font))
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    private static func glyph(_ character: String, in font: NSFont) -> CGGlyph? {
        var glyph = CGGlyph(0)
        let units = Array(character.utf16)
        return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyph, 1) && glyph != 0 ? glyph : nil
    }

    private static func drawsLetters(_ font: NSFont) -> Bool {
        ["A", "a", "0"].allSatisfy { glyph($0, in: font) != nil }
    }

    private static func hasEqualAdvances(_ font: NSFont) -> Bool {
        var widths: [CGFloat] = []
        for character in ["i", "M", "W", ".", "l", "0"] {
            guard var glyph = glyph(character, in: font) else { return false }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyph, &advance, 1)
            widths.append(advance.width)
        }
        return widths[0] > 0 && widths.allSatisfy { abs($0 - widths[0]) < 0.01 }
    }

    /// The regular face of `family`, or the system monospaced font.
    static func font(family: String?, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let family,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size),
           font.isFixedPitch {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// Toolbar button that opens a searchable list of monospaced system fonts,
/// each row previewed in its own face.
struct CodeFontPicker: View {
    @Environment(AppTheme.self) private var appTheme
    @State private var showing = false
    @State private var query = ""

    private var families: [String] {
        let all = [CodeFonts.systemName] + CodeFonts.families
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var selection: String { appTheme.codeFontFamily ?? CodeFonts.systemName }

    var body: some View {
        Button { showing.toggle() } label: {
            Label("Code Font", systemImage: "textformat")
        }
        .help("Code font: \(selection)")
        .popover(isPresented: $showing, arrowEdge: .bottom) { content }
    }

    private var content: some View {
        VStack(spacing: 0) {
            TextField("Search \(CodeFonts.families.count) monospaced fonts", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(families, id: \.self) { family in
                    row(family)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appTheme.codeFontFamily = family == CodeFonts.systemName ? nil : family
                        }
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .frame(width: 360, height: 440)
    }

    private func row(_ family: String) -> some View {
        let previewFont = CodeFonts.font(family: family == CodeFonts.systemName ? nil : family, size: 13)
        return HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
                .opacity(family == selection ? 1 : 0)
            Text(family)
            Spacer(minLength: 8)
            Text("Aa 0O1lI {}=>")
                .font(Font(previewFont as CTFont))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// Chrome colors derived from a theme's VS Code `colors` with sane fallbacks.
struct Palette: Equatable {
    let themeID: String
    let isLight: Bool
    let background: Color
    let foreground: Color
    let panel: Color
    let border: Color
    let accent: Color
    let secondaryText: Color
    let lineNumber: Color
    let lineHighlight: Color
    let inserted: Color
    let removed: Color
    let error: Color
    let warning: Color

    var colorScheme: ColorScheme { isLight ? .light : .dark }

    private static var cache: [String: Palette] = [:]

    /// Palettes are derived by parsing theme JSON; reuse them across renders.
    static func cached(_ themeID: String) -> Palette {
        if let palette = cache[themeID] { return palette }
        let palette = Palette(themeID: themeID)
        cache[themeID] = palette
        return palette
    }

    init(themeID: String) {
        let theme = try? BundledShikiAssets.shared.loadTheme(named: themeID)
        let colors = theme?.colors ?? [:]
        let isLight = theme?.type.isLight ?? false
        self.themeID = themeID
        self.isLight = isLight

        func color(_ keys: String..., opaque: Bool = false) -> Color? {
            for key in keys {
                guard let value = colors[key], var rgba = ShikiRGBAColor(hex: value) else { continue }
                if opaque {
                    // Accent colors are sometimes translucent; tints need them solid.
                    guard rgba.alpha > 60 else { continue }
                    rgba = ShikiRGBAColor(red: rgba.red, green: rgba.green, blue: rgba.blue)
                }
                return rgba.swiftUIColor
            }
            return nil
        }

        let foreground = theme.flatMap { Color(shikiHex: $0.fg) } ?? (isLight ? .black : .white)
        background = theme.flatMap { Color(shikiHex: $0.bg) } ?? (isLight ? .white : .black)
        self.foreground = foreground
        panel = color("editorWidget.background", "sideBar.background", "editorGroupHeader.tabsBackground")
            ?? foreground.opacity(0.04)
        border = color("panel.border", "editorGroup.border", "sideBar.border", "widget.border")
            ?? foreground.opacity(0.12)
        accent = color("focusBorder", "button.background", "textLink.foreground",
                       "activityBarBadge.background", opaque: true) ?? .accentColor
        secondaryText = color("descriptionForeground", "editorLineNumber.activeForeground")
            ?? foreground.opacity(0.65)
        lineNumber = color("editorLineNumber.foreground") ?? foreground.opacity(0.35)
        lineHighlight = color("editor.lineHighlightBackground", "editor.selectionHighlightBackground")
            ?? foreground.opacity(0.06)
        inserted = color("diffEditor.insertedLineBackground", "diffEditor.insertedTextBackground")
            ?? Color.green.opacity(0.16)
        removed = color("diffEditor.removedLineBackground", "diffEditor.removedTextBackground")
            ?? Color.red.opacity(0.16)
        error = color("editorError.foreground", "errorForeground", opaque: true) ?? .red
        warning = color("editorWarning.foreground", opaque: true) ?? .orange
    }
}

/// Toolbar theme switcher: appearance, grouped menu, swatch preview, and shuffle.
struct ThemeSwitcher: View {
    @Environment(AppTheme.self) private var appTheme

    var body: some View {
        @Bindable var appTheme = appTheme
        Menu {
            Picker("Appearance", selection: $appTheme.appearance) {
                ForEach(AppTheme.Appearance.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Appearance", systemImage: appTheme.appearance.symbol)
        }
        .help("Appearance (⇧⌘L to toggle light/dark)")

        Menu {
            Section("Dark") { items(AppTheme.dark) }
            Section("Light") { items(AppTheme.light) }
        } label: {
            HStack(spacing: 6) {
                ThemeSwatch(themeID: appTheme.themeID)
                Text(appTheme.info?.displayName ?? appTheme.themeID)
            }
        }
        .help("Theme (⌘[ / ⌘] to cycle)")

        CodeFontPicker()

        Button { appTheme.shuffle() } label: {
            Label("Random Theme", systemImage: "shuffle")
        }
        .help("Random theme")
    }

    @ViewBuilder
    private func items(_ themes: [ShikiThemeInfo]) -> some View {
        ForEach(themes) { theme in
            Toggle(theme.displayName, isOn: Binding(
                get: { appTheme.themeID == theme.id },
                set: { if $0 { appTheme.themeID = theme.id } }
            ))
        }
    }
}

/// A small background/foreground/accent preview of a theme.
struct ThemeSwatch: View {
    let themeID: String
    var size: CGFloat = 14

    var body: some View {
        let palette = Palette(themeID: themeID)
        // Diagonal split (background / accent) kept inside the circle; a
        // corner-aligned accent dot sat outside the round outline.
        Circle()
            .fill(LinearGradient(stops: [.init(color: palette.background, location: 0.5),
                                         .init(color: palette.accent, location: 0.5)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Circle().strokeBorder(palette.foreground.opacity(0.35), lineWidth: 1))
            .frame(width: size, height: size)
    }
}

/// Menu bar commands: View ▸ Theme.
struct ThemeCommands: Commands {
    let appTheme: AppTheme

    var body: some Commands {
        CommandMenu("Theme") {
            Picker("Appearance", selection: Binding(get: { appTheme.appearance },
                                                    set: { appTheme.appearance = $0 })) {
                ForEach(AppTheme.Appearance.allCases) { Text($0.title).tag($0) }
            }
            Button("Toggle Light/Dark") { appTheme.appearance = appTheme.isDark ? .light : .dark }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Next Theme") { appTheme.step(1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Theme") { appTheme.step(-1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Random Theme") { appTheme.shuffle() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Menu("Dark Themes") { themeButtons(AppTheme.dark) }
            Menu("Light Themes") { themeButtons(AppTheme.light) }
        }
    }

    @ViewBuilder
    private func themeButtons(_ themes: [ShikiThemeInfo]) -> some View {
        ForEach(themes) { theme in
            Button(theme.displayName) { appTheme.themeID = theme.id }
        }
    }
}

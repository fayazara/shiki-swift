import Shiki
import SwiftUI

/// One tokenization pass that carries both a light and a dark theme — the
/// basis for dual-theme HTML (CSS variables) and appearance-adaptive views.
struct LightDarkDemo: View {
    @Environment(AppTheme.self) private var appTheme
    @Environment(\.colorScheme) private var colorScheme
    @State private var lightTheme = "github-light"
    @State private var darkTheme = "github-dark"
    @State private var sample = DemoSamples.gallery[1]
    @State private var variants: [[ThemedTokenWithVariants]] = []
    @State private var html = ""

    private var key: String { "\(lightTheme)|\(darkTheme)|\(sample.id)" }

    var body: some View {
        let palette = appTheme.palette
        DemoPage(title: "Light & Dark",
                 subtitle: "codeToTokensWithThemes tokenizes once and returns colors for every theme. Render either variant natively, follow the current appearance, or export dual-theme HTML with CSS variables.") {
            AdaptiveRow {
                Picker("Light", selection: $lightTheme) {
                    ForEach(AppTheme.light) { Text($0.displayName).tag($0.id) }
                }.frame(maxWidth: 240)
                Picker("Dark", selection: $darkTheme) {
                    ForEach(AppTheme.dark) { Text($0.displayName).tag($0.id) }
                }.frame(maxWidth: 240)
                Picker("Snippet", selection: $sample) {
                    ForEach(DemoSamples.gallery) { Text(DemoLanguages.name(for: $0.language)).tag($0) }
                }.frame(maxWidth: 200)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    variantPane("light", title: "Light variant", themeID: lightTheme).frame(minWidth: 340)
                    variantPane("dark", title: "Dark variant", themeID: darkTheme).frame(minWidth: 340)
                }
                VStack(spacing: 16) {
                    variantPane("light", title: "Light variant", themeID: lightTheme)
                    variantPane("dark", title: "Dark variant", themeID: darkTheme)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Follows the app's appearance (currently \(colorScheme == .dark ? "dark" : "light"))",
                      systemImage: "circle.lefthalf.filled")
                    .font(.headline)
                Text("Same tokens, no re-highlighting. Pick a light theme from the toolbar and this block flips.")
                    .font(.callout).foregroundStyle(palette.secondaryText)
                variantPane(colorScheme == .dark ? "dark" : "light", title: nil,
                            themeID: colorScheme == .dark ? darkTheme : lightTheme)
                    .animation(.easeInOut, value: colorScheme)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Dual-theme HTML export", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.headline)
                Text("Shiki's CSS-variable output: light colors inline, dark colors as --shiki-dark variables. Highlighted with the HTML grammar, of course.")
                    .font(.callout).foregroundStyle(palette.secondaryText)
                if !html.isEmpty {
                    CodeBlock(code: html, language: "html", title: "snippet.html", showsLineNumbers: false,
                              fontSize: 11)
                }
            }
        }
        .task(id: key) { await load() }
    }

    private func variantPane(_ name: String, title: String?, themeID: String) -> some View {
        let palette = Palette(themeID: themeID)
        let lines = variants.map { line in
            line.map { token in
                let style = token.variants[name]
                return ThemedToken(content: token.content, offset: token.offset, color: style?.color,
                                   bgColor: style?.bgColor, fontStyle: style?.fontStyle)
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack {
                    Text(title).font(.caption.weight(.semibold))
                    Spacer()
                    Text(AppTheme.all.first { $0.id == themeID }?.displayName ?? themeID).font(.caption)
                }
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider().overlay(palette.border)
            }
            CodeLines(lines: lines, palette: palette, showsLineNumbers: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.border))
    }

    private func load() async {
        let themes = [
            ShikiThemeVariant(colorName: "light", themeName: lightTheme),
            ShikiThemeVariant(colorName: "dark", themeName: darkTheme),
        ]
        do {
            variants = try await DemoEngine.shared.variants(sample.code, language: sample.language, themes: themes)
            let css = try await DemoEngine.shared.cssVariableTokens(sample.code, language: sample.language,
                                                                    themes: themes)
            html = """
            <style>
              @media (prefers-color-scheme: dark) {
                .shiki, .shiki span {
                  color: var(--shiki-dark) !important;
                  background-color: var(--shiki-dark-bg) !important;
                }
              }
            </style>
            \(HTMLExport.document(css).replacingOccurrences(of: "<span class=\"line\">", with: "\n<span class=\"line\">"))
            """
        } catch {
            html = "<!-- \(error) -->"
        }
    }
}

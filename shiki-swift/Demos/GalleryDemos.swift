import Shiki
import SwiftUI

/// Every sample language, highlighted with the app theme.
struct LanguageGalleryDemo: View {
    @Environment(AppTheme.self) private var appTheme
    @State private var search = ""

    private var samples: [CodeSample] {
        guard !search.isEmpty else { return DemoSamples.gallery }
        return DemoSamples.gallery.filter {
            DemoLanguages.name(for: $0.language).localizedCaseInsensitiveContains(search)
                || $0.title.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        DemoPage(title: "Languages",
                 subtitle: "\(DemoSamples.gallery.count) samples from the \(DemoLanguages.all.count) bundled TextMate grammars. Embedded languages (HTML ▸ CSS/JS, Vue, Markdown fences) load on demand.") {
            TextField("Filter languages", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)],
                      spacing: 16) {
                ForEach(samples) { sample in
                    CodeBlock(code: sample.code, language: sample.language, title: sample.title)
                }
            }
        }
    }
}

/// The same snippet in every bundled theme; click one to apply it app-wide.
struct ThemeGalleryDemo: View {
    enum Filter: String, CaseIterable { case all = "All", dark = "Dark", light = "Light" }

    @Environment(AppTheme.self) private var appTheme
    @State private var filter: Filter = .all
    @State private var sample = DemoSamples.gallery[0]

    private var themes: [ShikiThemeInfo] {
        switch filter {
        case .all: AppTheme.all
        case .dark: AppTheme.dark
        case .light: AppTheme.light
        }
    }

    var body: some View {
        DemoPage(title: "Themes",
                 subtitle: "All \(AppTheme.all.count) bundled VS Code themes. Click a card to make it the app theme — the window chrome is derived from the theme's colors too.") {
            AdaptiveRow {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Picker("Snippet", selection: $sample) {
                    ForEach(DemoSamples.gallery) { Text("\(DemoLanguages.name(for: $0.language))").tag($0) }
                }
                .frame(maxWidth: 220)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)],
                      spacing: 16) {
                ForEach(themes) { theme in
                    card(theme)
                }
            }
        }
    }

    private func card(_ theme: ShikiThemeInfo) -> some View {
        let selected = theme.id == appTheme.themeID
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ThemeSwatch(themeID: theme.id, size: 12)
                Text(theme.displayName).font(.callout.weight(.semibold))
                Text(theme.type.isLight ? "Light" : "Dark")
                    .font(.caption2).foregroundStyle(appTheme.palette.secondaryText)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(appTheme.palette.accent)
                }
            }
            CodeBlock(code: sample.code, language: sample.language, title: sample.title,
                      theme: theme.id, showsLineNumbers: false, fontSize: 11)
                .frame(height: 230, alignment: .top)
                .clipped()
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(appTheme.palette.accent, lineWidth: selected ? 3 : 0)
                }
                .overlay {
                    // Whole card is a button; text selection isn't needed here.
                    Button { appTheme.themeID = theme.id } label: { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .help("Use \(theme.displayName)")
                }
        }
    }
}

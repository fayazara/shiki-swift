import Shiki
import SwiftUI

/// ANSI escape sequences rendered with the theme's terminal palette.
struct TerminalDemo: View {
    @Environment(AppTheme.self) private var appTheme
    @State private var selection = 0
    @State private var showRaw = false
    @State private var lines: [[ThemedToken]] = []

    private var sample: (title: String, text: String) { TerminalSamples.all[selection] }

    var body: some View {
        let palette = appTheme.palette
        DemoPage(title: "Terminal (ANSI)",
                 subtitle: "language: \"ansi\" parses SGR escape codes — 16 colors, 256 colors, true color, bold, dim, italic, underline, reverse — and maps them to the theme's terminal.ansi* colors. Useful for CI logs, build output, and embedded terminals.") {
            AdaptiveRow {
                Picker("Transcript", selection: $selection) {
                    ForEach(TerminalSamples.all.indices, id: \.self) { Text(TerminalSamples.all[$0].title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Show raw escapes", isOn: $showRaw).toggleStyle(.switch)
            }

            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { color in
                        Circle().fill(color.opacity(0.85)).frame(width: 11, height: 11)
                    }
                    Spacer()
                    Text("zsh — \(sample.title)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Color.clear.frame(width: 45, height: 1)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(palette.panel)
                Divider().overlay(palette.border)

                if showRaw {
                    ScrollView(.horizontal) {
                        Text(sample.text.replacingOccurrences(of: "\u{1B}", with: "␛"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.secondaryText)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    CodeLines(lines: lines, palette: palette, showsLineNumbers: false)
                }
            }
            .background(palette.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.border))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        }
        .task(id: "\(selection)|\(appTheme.themeID)") {
            lines = (try? await DemoEngine.shared.tokens(sample.text, language: "ansi",
                                                         theme: appTheme.themeID).tokens) ?? []
        }
    }
}

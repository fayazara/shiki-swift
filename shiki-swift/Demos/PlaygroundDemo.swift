import AppKit
import Shiki
import ShikiUI
import SwiftUI

/// Type or paste code and see it highlighted live.
struct PlaygroundDemo: View {
    @Environment(AppTheme.self) private var appTheme
    @State private var code = DemoSamples.gallery[0].code
    @State private var language = "swift"
    @State private var themeOverride: String?
    @State private var showsLineNumbers = true
    @State private var fontSize: CGFloat = 13
    @State private var result: TokensResult?
    @State private var elapsed: Duration = .zero
    @State private var error: String?
    @State private var generation = 0
    /// Start with the caret at the top. With the default (caret at the end),
    /// focusing the editor on launch scrolled it — and every enclosing scroll
    /// view in the window — to the last line, shoving the layout upward.
    @State private var selection: TextSelection? = TextSelection(insertionPoint: DemoSamples.gallery[0].code.startIndex)

    private var themeID: String { themeOverride ?? appTheme.themeID }
    private var requestKey: String { "\(language)|\(themeID)|\(code.hashValue)" }
    /// Beyond this, the TextKit-backed virtualized view is used.
    private let virtualizeAbove = 800

    var body: some View {
        let palette = appTheme.palette
        DemoPage(title: "Playground",
                 subtitle: "Type or paste anything. It re-highlights as you type (debounced), using any of the \(DemoLanguages.all.count) bundled grammars.",
                 scrolls: false) {
            controls(palette)
            // Plain SwiftUI panes: AppKit-backed HSplitView ignores the
            // proposed height and made the page overflow the window.
            HStack(spacing: 0) {
                editor(palette).frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(palette.border).frame(width: 1)
                output(palette).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.border))
            stats(palette)
        }
        .task(id: requestKey) { await render() }
    }

    private func controls(_ palette: Palette) -> some View {
        HStack(spacing: 10) {
            LanguagePicker(selection: $language).frame(minWidth: 140, maxWidth: 220)
            Picker("Theme", selection: $themeOverride) {
                Text("App theme").tag(String?.none)
                Divider()
                ForEach(AppTheme.all) { Text($0.displayName).tag(Optional($0.id)) }
            }
            .frame(minWidth: 140, maxWidth: 220)
            Menu("Samples") {
                ForEach(DemoSamples.gallery) { sample in
                    Button("\(DemoLanguages.name(for: sample.language)) — \(sample.title)") {
                        language = sample.language
                        code = sample.code
                        selection = TextSelection(insertionPoint: code.startIndex)
                    }
                }
            }
            .fixedSize()
            Spacer(minLength: 0)
            Menu {
                Toggle("Line Numbers", isOn: $showsLineNumbers)
                Picker("Font Size", selection: $fontSize) {
                    ForEach([11, 12, 13, 15, 18, 22] as [CGFloat], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
                Divider()
                Section("Export") {
                    Button("Copy as HTML") { copy(html()) }.disabled(result == nil)
                    Button("Copy as JSON Tokens") { copy(json()) }.disabled(result == nil)
                    Button("Copy Plain Text") { copy(code) }
                }
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .fixedSize()
        }
    }

    private func editor(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader("Input", palette: palette)
            TextEditor(text: $code, selection: $selection)
                .font(appTheme.codeFont(size: fontSize))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
                // TextEditor reports its wrapped content height as a minimum
                // (measured at tiny widths that is huge), which inflated the
                // whole window. Explicit zero minimums stop that.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(palette.panel)
        }
    }

    private func output(_ palette: Palette) -> some View {
        let codePalette = Palette(themeID: themeID)
        return VStack(alignment: .leading, spacing: 0) {
            paneHeader("Highlighted · \(AppTheme.all.first { $0.id == themeID }?.displayName ?? themeID)",
                       palette: palette)
            Group {
                if let error {
                    ContentUnavailableView("Highlighting failed", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if let result, result.tokens.count > virtualizeAbove {
                    GeometryReader { proxy in
                        ShikiVirtualizedCodeView(
                            result: result, renderID: generation,
                            font: appTheme.codeNSFont(size: fontSize),
                            contentPadding: 12, viewportHeight: proxy.size.height
                        )
                    }
                } else if let result {
                    ScrollView(.vertical) {
                        CodeLines(lines: result.tokens, palette: codePalette,
                                  showsLineNumbers: showsLineNumbers, fontSize: fontSize)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(codePalette.background)
        }
    }

    private func paneHeader(_ title: String, palette: Palette) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private func stats(_ palette: Palette) -> some View {
        let lines = result?.tokens.count ?? 0
        let tokens = result?.tokens.reduce(0) { $0 + $1.count } ?? 0
        return HStack(spacing: 18) {
            Label("\(lines.formatted()) lines", systemImage: "text.alignleft")
            Label("\(tokens.formatted()) tokens", systemImage: "number")
            Label(elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))),
                  systemImage: "stopwatch")
            if lines > virtualizeAbove {
                Label("Virtualized TextKit view", systemImage: "square.stack.3d.down.right")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(palette.secondaryText)
    }

    private func render() async {
        // Debounce keystrokes; `.task(id:)` cancels superseded renders.
        try? await Task.sleep(for: .milliseconds(result == nil ? 0 : 180))
        guard !Task.isCancelled else { return }
        do {
            let start = ContinuousClock.now
            let rendered = try await DemoEngine.shared.tokens(code, language: language, theme: themeID)
            guard !Task.isCancelled else { return }
            elapsed = ContinuousClock.now - start
            result = rendered
            generation += 1
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = String(describing: error)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func html() -> String {
        guard let result else { return "" }
        return HTMLExport.document(result)
    }

    private func json() -> String {
        guard let result else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(result.tokens)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// Minimal Shiki-style HTML output (`<pre class="shiki">` with styled spans).
enum HTMLExport {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func document(_ result: TokensResult) -> String {
        var html = "<pre class=\"shiki\" style=\"background-color:\(result.bg ?? "#fff");color:\(result.fg ?? "#000")\"><code>"
        for (index, line) in result.tokens.enumerated() {
            if index > 0 { html += "\n" }
            html += "<span class=\"line\">"
            for token in line {
                var style: [String] = []
                if let htmlStyle = token.htmlStyle {
                    style = htmlStyle.sorted { lhs, rhs in
                        let l = lhs.key.hasPrefix("--"), r = rhs.key.hasPrefix("--")
                        return l == r ? lhs.key < rhs.key : !l
                    }.map { "\($0.key):\($0.value)" }
                } else {
                    if let color = token.color { style.append("color:\(color)") }
                    if let bg = token.bgColor { style.append("background-color:\(bg)") }
                    // `.notSet` is all bits set; treat it as no style.
                    let fontStyle = token.fontStyle == .notSet ? [] : (token.fontStyle ?? [])
                    if fontStyle.contains(.italic) { style.append("font-style:italic") }
                    if fontStyle.contains(.bold) { style.append("font-weight:bold") }
                    if fontStyle.contains(.underline) { style.append("text-decoration:underline") }
                }
                html += "<span style=\"\(style.joined(separator: ";"))\">\(escape(token.content))</span>"
            }
            html += "</span>"
        }
        return html + "</code></pre>"
    }
}

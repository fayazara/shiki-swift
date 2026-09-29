import AppKit
import Shiki
import ShikiUI
import SwiftUI

// MARK: - Token rendering

enum TokenText {
    /// - Parameter highlights: UTF-16 ranges within the line (Shiki's
    ///   `[!code word:…]`) drawn with `highlightColor` behind the text.
    static func attributed(
        _ tokens: [ThemedToken],
        font: Font,
        fallback: Color,
        highlights: [Range<Int>] = [],
        highlightColor: Color = .yellow.opacity(0.3)
    ) -> AttributedString {
        var output = AttributedString()
        var position = 0
        for token in tokens {
            let units = Array(token.content.utf16)
            var cuts = Set([0, units.count])
            for range in highlights {
                for edge in [range.lowerBound - position, range.upperBound - position] where edge > 0 && edge < units.count {
                    cuts.insert(edge)
                }
            }
            let style = token.fontStyle == .notSet ? FontStyle.none : (token.fontStyle ?? .none)
            var tokenFont = font
            if style.contains(.bold) { tokenFont = tokenFont.bold() }
            if style.contains(.italic) { tokenFont = tokenFont.italic() }
            let sorted = cuts.sorted()
            for (start, end) in zip(sorted, sorted.dropFirst()) {
                var piece = AttributedString(String(decoding: units[start..<end], as: UTF16.self))
                piece.font = tokenFont
                piece.foregroundColor = token.color.flatMap(Color.init(shikiHex:)) ?? fallback
                if highlights.contains(where: { $0.lowerBound <= position + start && position + end <= $0.upperBound }) {
                    piece.backgroundColor = highlightColor
                } else if let background = token.bgColor.flatMap(Color.init(shikiHex:)) {
                    piece.backgroundColor = background
                }
                if style.contains(.underline) { piece.underlineStyle = .single }
                if style.contains(.strikethrough) { piece.strikethroughStyle = .single }
                output.append(piece)
            }
            position += units.count
        }
        // Empty lines still need a line's height.
        if output.characters.isEmpty {
            output = AttributedString(" ")
            output.font = font
        }
        return output
    }
}

/// Renders token lines with an optional gutter and line decorations.
struct CodeLines: View {
    let lines: [[ThemedToken]]
    let palette: Palette
    /// Notations per line (from `applyingNotations`), parallel to `lines`.
    var notations: [Set<ShikiLineNotation>] = []
    var wordHighlights: [ShikiWordHighlight] = []
    var showsLineNumbers = true
    var fontSize: CGFloat = 13
    /// Content appended after the last line, e.g. a streaming cursor.
    var trailingCursor = false

    @State private var hovering = false

    @Environment(AppTheme.self) private var appTheme

    private var font: Font { appTheme.codeFont(size: fontSize) }
    private var hasFocus: Bool { notations.contains { $0.contains(.focused) } }

    /// The notation that decides a line's marker and tint; focus only dims the rest.
    private static let priority: [ShikiLineNotation] = [.error, .warning, .added, .removed, .info, .highlighted]

    private func decoration(at index: Int) -> ShikiLineNotation? {
        guard index < notations.count else { return nil }
        return Self.priority.first { notations[index].contains($0) }
    }

    private func words(on index: Int) -> [Range<Int>] {
        wordHighlights.filter { $0.line == index }.map(\.range)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    line(index)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.2), value: hovering)
    }

    private func line(_ index: Int) -> some View {
        let decoration = decoration(at: index)
        let focused = index < notations.count && notations[index].contains(.focused)
        let dimmed = hasFocus && !focused && !hovering
        var text = TokenText.attributed(lines[index], font: font, fallback: palette.foreground,
                                        highlights: words(on: index),
                                        highlightColor: palette.accent.opacity(0.35))
        if trailingCursor && index == lines.count - 1 {
            var cursor = AttributedString("▍")
            cursor.foregroundColor = palette.accent
            cursor.font = font
            text.append(cursor)
        }
        return HStack(spacing: 0) {
            if showsLineNumbers {
                Text("\(index + 1)")
                    .font(font)
                    .foregroundStyle(palette.lineNumber)
                    .frame(minWidth: gutterWidth, alignment: .trailing)
                    .padding(.trailing, 14)
            }
            Text(marker(for: decoration))
                .font(font.weight(.bold))
                .foregroundStyle(markerColor(for: decoration))
                .frame(width: 16, alignment: .leading)
            Text(text)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: 16)
        }
        .padding(.leading, 12)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(for: decoration))
        .overlay(alignment: .leading) {
            if let decoration {
                Rectangle().fill(markerColor(for: decoration)).frame(width: 3)
            }
        }
        .blur(radius: dimmed ? 1.1 : 0)
        .opacity(dimmed ? 0.45 : 1)
    }

    private var gutterWidth: CGFloat {
        CGFloat(String(lines.count).count) * appTheme.codeAdvance(size: fontSize)
    }

    private func marker(for decoration: ShikiLineNotation?) -> String {
        switch decoration {
        case .added: "+"
        case .removed: "-"
        case .error: "✕"
        case .warning: "!"
        case .info: "i"
        default: " "
        }
    }

    private func markerColor(for decoration: ShikiLineNotation?) -> Color {
        switch decoration {
        case .added: .green
        case .removed: .red
        case .error: palette.error
        case .warning: palette.warning
        case .info, .highlighted: palette.accent
        default: .clear
        }
    }

    private func background(for decoration: ShikiLineNotation?) -> Color {
        switch decoration {
        case .added: palette.inserted
        case .removed: palette.removed
        case .error: palette.error.opacity(0.14)
        case .warning: palette.warning.opacity(0.14)
        case .info: palette.accent.opacity(0.12)
        case .highlighted: palette.lineHighlight.opacity(1)
        default: .clear
        }
    }
}

// MARK: - Code block card

/// A highlighted, copyable code card. Uses the app theme unless `theme` is set.
struct CodeBlock: View {
    let code: String
    let language: String
    var title: String?
    var theme: String?
    var showsLineNumbers = true
    var parsesAnnotations = false
    var fontSize: CGFloat = 13

    @Environment(AppTheme.self) private var appTheme
    @State private var rendered: Rendered?
    @State private var failure: String?

    private struct Rendered {
        let key: String
        let lines: [[ThemedToken]]
        let notations: [Set<ShikiLineNotation>]
        let words: [ShikiWordHighlight]
        let code: String
        let palette: Palette
    }

    private var themeID: String { theme ?? appTheme.themeID }
    private var key: String { "\(themeID)|\(language)|\(parsesAnnotations)|\(code.hashValue)" }

    var body: some View {
        let palette = rendered?.palette ?? Palette(themeID: themeID)
        VStack(spacing: 0) {
            header(palette)
            Divider().overlay(palette.border)
            Group {
                if let rendered {
                    CodeLines(lines: rendered.lines, palette: rendered.palette,
                              notations: rendered.notations, wordHighlights: rendered.words,
                              showsLineNumbers: showsLineNumbers, fontSize: fontSize)
                } else if let failure {
                    Text(failure).foregroundStyle(.red).padding()
                } else {
                    ProgressView().controlSize(.small).padding(20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.border))
        .task(id: key) { await render() }
    }

    private func header(_ palette: Palette) -> some View {
        HStack(spacing: 8) {
            Text(title ?? DemoLanguages.name(for: language))
                .font(.system(size: 12, weight: .medium, design: title == nil ? .default : .monospaced))
                .foregroundStyle(palette.secondaryText)
            Spacer()
            if title != nil {
                Text(DemoLanguages.name(for: language))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(palette.foreground.opacity(0.08), in: Capsule())
            }
            CopyButton(text: rendered?.code ?? code, color: palette.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func render() async {
        do {
            // Highlight the source as written, comments included, then let the
            // library strip the `[!code …]` notations and report what they marked.
            let result = try await DemoEngine.shared.tokens(code, language: language, theme: themeID)
            let annotated = parsesAnnotations ? result.applyingNotations(language: language) : nil
            rendered = Rendered(
                key: key, lines: annotated?.tokens ?? result.tokens,
                notations: annotated?.lineNotations ?? [], words: annotated?.wordHighlights ?? [],
                code: annotated?.code ?? code, palette: Palette(themeID: themeID)
            )
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = String(describing: error)
        }
    }
}

struct CopyButton: View {
    let text: String
    var color: Color = .secondary
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? .green : color)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help("Copy code")
    }
}

// MARK: - Shared chrome

/// Page scaffold: title, subtitle, and themed background.
struct DemoPage<Content: View>: View {
    let title: String
    let subtitle: String
    var scrolls = true
    @ViewBuilder var content: Content

    @Environment(AppTheme.self) private var appTheme

    var body: some View {
        let palette = appTheme.palette
        Group {
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        heading(palette)
                        content
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    heading(palette)
                    content
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }
        }
        // Extend under the floating sidebar and toolbar so there is no seam.
        .background(palette.background.ignoresSafeArea())
        .foregroundStyle(palette.foreground)
    }

    private func heading(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                // Fixed-height pages: when macOS measures the window's minimum
                // size it proposes a near-zero width, and an unbounded wrapped
                // subtitle then reports a huge height, making the window taller
                // than the screen and pushing everything off the top.
                .lineLimit(scrolls ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// A themed panel surface.
    func panel(_ palette: Palette, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.border))
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(palette, padding: 12)
    }
}

/// Picker over every bundled grammar, popular languages first.
struct LanguagePicker: View {
    @Binding var selection: String

    var body: some View {
        Picker("Language", selection: $selection) {
            Section("Popular") {
                ForEach(DemoLanguages.popular, id: \.self) { id in
                    Text(DemoLanguages.name(for: id)).tag(id)
                }
            }
            Section("All \(DemoLanguages.all.count) languages") {
                ForEach(DemoLanguages.all) { info in
                    Text(DemoLanguages.name(info)).tag(info.id)
                }
            }
        }
    }
}

// MARK: - Layout helpers for narrow windows

/// A horizontal row that falls back to a vertical stack when it doesn't fit.
struct AdaptiveRow<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

/// Wraps children onto new lines, like text. Used for chips and buttons.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

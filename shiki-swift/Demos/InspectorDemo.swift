import Shiki
import ShikiUI
import SwiftUI

/// Click a token to see its TextMate scopes and the theme rule that colored it.
struct InspectorDemo: View {
    struct Position: Hashable { let line: Int; let token: Int }

    @Environment(AppTheme.self) private var appTheme
    @State private var sample = DemoSamples.inspector
    @State private var lines: [[ThemedToken]] = []
    @State private var selected: Position?
    @State private var hovered: Position?

    private var samples: [CodeSample] { [DemoSamples.inspector] + DemoSamples.gallery }

    var body: some View {
        let palette = appTheme.palette
        DemoPage(title: "Token Inspector",
                 subtitle: "includeExplanation: .full returns every token's scope stack and the theme rules that matched — like VS Code's “Inspect Editor Tokens and Scopes”. Handy for theme authoring and debugging grammars.") {
            Picker("Snippet", selection: $sample) {
                ForEach(samples) { Text("\(DemoLanguages.name(for: $0.language)) — \($0.title)").tag($0) }
            }
            .frame(maxWidth: 320)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    codeView(Palette(themeID: appTheme.themeID)).frame(minWidth: 420)
                    details(palette).frame(width: 320)
                }
                VStack(alignment: .leading, spacing: 16) {
                    codeView(Palette(themeID: appTheme.themeID))
                    details(palette)
                }
            }
        }
        .task(id: "\(sample.id)|\(appTheme.themeID)") {
            selected = nil
            let options = TokenizeWithThemeOptions(includeExplanation: .full)
            lines = (try? await DemoEngine.shared.tokens(sample.code, language: sample.language,
                                                         theme: appTheme.themeID, options: options).tokens) ?? []
            selected = firstInterestingToken()
        }
    }

    private func codeView(_ palette: Palette) -> some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines.indices, id: \.self) { lineIndex in
                    HStack(spacing: 0) {
                        Text("\(lineIndex + 1)")
                            .foregroundStyle(palette.lineNumber)
                            .frame(width: 28, alignment: .trailing)
                            .padding(.trailing, 14)
                        ForEach(lines[lineIndex].indices, id: \.self) { tokenIndex in
                            token(Position(line: lineIndex, token: tokenIndex), palette: palette)
                        }
                        if lines[lineIndex].isEmpty { Text(" ") }
                    }
                }
            }
            .font(appTheme.codeFont(size: 13))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.border))
    }

    private func token(_ position: Position, palette: Palette) -> some View {
        let token = lines[position.line][position.token]
        let isSelected = selected == position
        let isHovered = hovered == position
        return Text(TokenText.attributed([token], font: appTheme.codeFont(size: 13),
                                         fallback: palette.foreground))
            .fixedSize()
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.accent.opacity(isSelected ? 0.3 : isHovered ? 0.15 : 0))
            )
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.accent, lineWidth: isSelected ? 1 : 0))
            .onHover { hovered = $0 ? position : (hovered == position ? nil : hovered) }
            .onTapGesture { selected = position }
    }

    @ViewBuilder
    private func details(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selected, selected.line < lines.count, selected.token < lines[selected.line].count {
                let token = lines[selected.line][selected.token]
                Text("“\(token.content)”")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .lineLimit(2)
                HStack(spacing: 16) {
                    detail("Foreground") {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(token.color.flatMap(Color.init(shikiHex:)) ?? palette.foreground)
                                .frame(width: 14, height: 14)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.border))
                            Text(token.color ?? "default").font(.system(.caption, design: .monospaced))
                        }
                    }
                    detail("Font style") { Text(fontStyle(token.fontStyle)).font(.caption) }
                    detail("Offset") { Text("\(token.offset)").font(.caption).monospacedDigit() }
                }
                Divider()
                ForEach(Array((token.explanation ?? []).enumerated()), id: \.offset) { _, explanation in
                    VStack(alignment: .leading, spacing: 6) {
                        if (token.explanation?.count ?? 0) > 1 {
                            Text("Segment “\(explanation.content)”").font(.caption.weight(.semibold))
                        }
                        Text("SCOPES (outer → inner)").font(.caption2.weight(.bold))
                            .foregroundStyle(palette.secondaryText)
                        ForEach(Array(explanation.scopes.enumerated()), id: \.offset) { depth, scope in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(String(repeating: "  ", count: depth) + "›")
                                    .foregroundStyle(palette.secondaryText)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scope.scopeName)
                                    if let rule = scope.themeMatches?.last {
                                        Text("theme: \(rule.scope?.values.joined(separator: ", ") ?? "*")"
                                             + (rule.settings?.foreground.map { " → \($0)" } ?? ""))
                                            .foregroundStyle(palette.accent)
                                    }
                                }
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Select a token", systemImage: "cursorarrow.click",
                                       description: Text("Click any token in the code."))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(palette)
    }

    private func detail<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(appTheme.palette.secondaryText)
            content()
        }
    }

    private func fontStyle(_ style: FontStyle?) -> String {
        guard let style, style != .notSet, !style.isEmpty else { return "normal" }
        var names: [String] = []
        if style.contains(.bold) { names.append("bold") }
        if style.contains(.italic) { names.append("italic") }
        if style.contains(.underline) { names.append("underline") }
        if style.contains(.strikethrough) { names.append("strike") }
        return names.joined(separator: " ")
    }

    private func firstInterestingToken() -> Position? {
        for (lineIndex, line) in lines.enumerated() {
            for (tokenIndex, token) in line.enumerated()
            where (token.explanation?.first?.scopes.count ?? 0) > 2 && !token.content.allSatisfy(\.isWhitespace) {
                return Position(line: lineIndex, token: tokenIndex)
            }
        }
        return nil
    }
}

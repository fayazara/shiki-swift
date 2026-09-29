import SwiftUI

/// A tiny Markdown renderer whose fenced code blocks are highlighted natively:
/// the building block for documentation viewers, READMEs, and chat UIs.
struct DocsDemo: View {
    enum Mode: String, CaseIterable { case rendered = "Rendered", source = "Source" }

    @Environment(AppTheme.self) private var appTheme
    @State private var mode: Mode = .rendered

    var body: some View {
        DemoPage(title: "Docs & Markdown",
                 subtitle: "Render Markdown with native Text and highlighted code fences (```lang title=\"…\"). The Source tab highlights the raw Markdown — fenced languages are detected and loaded on demand.") {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Group {
                switch mode {
                case .rendered: rendered
                case .source: CodeBlock(code: DemoSamples.docs, language: "markdown", title: "getting-started.md")
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
        }
    }

    private var rendered: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(MarkdownBlocks.parse(DemoSamples.docs).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    Text(inline(text))
                        .font(.system(size: level == 1 ? 28 : 20, weight: .bold))
                        .padding(.top, level == 1 ? 0 : 8)
                case let .paragraph(text):
                    Text(inline(text))
                        .font(.body)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                case let .code(language, title, code):
                    CodeBlock(code: code, language: language, title: title)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}

enum MarkdownBlocks {
    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case code(language: String, title: String?, code: String)
    }

    /// Headings, paragraphs, and fenced code — enough for docs and chat.
    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var fence: (info: String, lines: [String])?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph.removeAll()
        }

        for line in markdown.components(separatedBy: "\n") {
            if var open = fence {
                if line.hasPrefix("```") {
                    let (language, title) = info(open.info)
                    blocks.append(.code(language: language, title: title, code: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(line)
                    fence = open
                }
            } else if line.hasPrefix("```") {
                flush()
                fence = (String(line.dropFirst(3)), [])
            } else if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
                      line[hashes] == " " {
                flush()
                blocks.append(.heading(line.distance(from: line.startIndex, to: hashes),
                                       String(line[line.index(after: hashes)...])))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Splits "swift title=\"Package.swift\"" into language and title.
    private static func info(_ info: String) -> (String, String?) {
        let language = info.split(separator: " ").first.map(String.init) ?? "text"
        let title = info.firstMatch(of: #/title="([^"]*)"/#).map { String($0.output.1) }
        return (language.isEmpty ? "text" : language, title)
    }
}

import Shiki
import ShikiUI
import SwiftUI

/// Tokenizes large generated files off the main thread and shows them in the
/// virtualized TextKit view, which only lays out visible lines.
struct LargeFileDemo: View {
    enum Shape: String, CaseIterable { case lines = "Many lines", minified = "One minified line" }

    @Environment(AppTheme.self) private var appTheme
    @State private var language = "swift"
    @State private var lineCount = 20_000
    @State private var shape: Shape = .lines
    @State private var result: TokensResult?
    @State private var characters = 0
    @State private var elapsed: Duration?
    @State private var generation = 0
    @State private var running = false
    /// Shiki's default `tokenizeTimeLimit`: past 500 ms, the rest of a line is
    /// emitted as one plain token. A long minified line hits it by design.
    @State private var timeLimited = true
    @State private var hitTimeLimit = false

    private let languages = ["swift", "typescript", "python", "json", "rust"]
    private let sizes = [1_000, 10_000, 20_000, 50_000, 100_000]

    var body: some View {
        let palette = appTheme.palette
        DemoPage(title: "Large Files",
                 subtitle: "Generate big inputs and time native tokenization. The result is shown in ShikiVirtualizedCodeView, which keeps selection, copy, and scrolling smooth by only laying out what's on screen — even for a 200k-character minified line.",
                 scrolls: false) {
            AdaptiveRow {
                Picker("Language", selection: $language) {
                    ForEach(languages, id: \.self) { Text(DemoLanguages.name(for: $0)).tag($0) }
                }.frame(maxWidth: 180)
                Picker("Shape", selection: $shape) {
                    ForEach(Shape.allCases, id: \.self) { Text($0.rawValue) }
                }.pickerStyle(.segmented).frame(maxWidth: 280)
                Picker("Size", selection: $lineCount) {
                    ForEach(sizes, id: \.self) { Text("\($0.formatted()) lines").tag($0) }
                }
                .frame(maxWidth: 170)
                .disabled(shape == .minified)
                Toggle("500 ms line limit", isOn: $timeLimited)
                    .help("Shiki's tokenizeTimeLimit. Off tokenizes every line fully, however long it takes.")
                Button {
                    Task { await run() }
                } label: {
                    Label(running ? "Highlighting…" : "Generate & Highlight", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                StatTile(label: "Lines", value: (result?.tokens.count ?? 0).formatted(), palette: palette)
                StatTile(label: "Characters", value: characters.formatted(), palette: palette)
                StatTile(label: "Tokens",
                         value: (result?.tokens.reduce(0) { $0 + $1.count } ?? 0).formatted(), palette: palette)
                StatTile(label: "Tokenize time",
                         value: elapsed.map { $0.formatted(.units(allowed: [.milliseconds, .seconds], width: .narrow)) } ?? "—",
                         palette: palette)
                StatTile(label: "Throughput", value: throughput, palette: palette)
            }

            if hitTimeLimit {
                Label("Stopped at Shiki's 500 ms per-line time limit, so the rest of the line is plain text (same as Shiki in JS). Turn off the limit to highlight all of it.",
                      systemImage: "timer")
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
            }

            GeometryReader { proxy in
                Group {
                    if let result {
                        ShikiVirtualizedCodeView(
                            result: result, renderID: generation,
                            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                            contentPadding: 14, viewportHeight: proxy.size.height
                        )
                    } else {
                        ContentUnavailableView("Nothing generated yet", systemImage: "doc.text.magnifyingglass",
                                               description: Text("Pick a size and press Generate & Highlight."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.border))
                .overlay { if running { ProgressView().controlSize(.large) } }
            }
        }
        .onChange(of: appTheme.themeID) { if result != nil { Task { await run() } } }
    }

    private var throughput: String {
        guard let elapsed, let result, elapsed > .zero else { return "—" }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return shape == .minified
            ? "\(Int(Double(characters) / seconds / 1000).formatted())k chars/s"
            : "\(Int(Double(result.tokens.count) / seconds).formatted()) lines/s"
    }

    private func run() async {
        running = true
        defer { running = false }
        let sample = DemoSamples.gallery.first { $0.language == language }?.code ?? ""
        let shape = shape
        let lineCount = lineCount
        // Minified input is JavaScript unless JSON/Python is selected.
        let language = shape == .minified && !["json", "python"].contains(language) ? "javascript" : language
        // Build the input off the main thread too.
        let code = await Task.detached(priority: .userInitiated) {
            Self.generate(sample: sample, language: language, lines: lineCount, minified: shape == .minified)
        }.value
        let limit = timeLimited ? 500 : 0
        do {
            let (tokens, time) = try await DemoEngine.shared.timedTokens(
                code, language: language, theme: appTheme.themeID,
                options: .init(tokenizeTimeLimit: limit)
            )
            result = tokens
            elapsed = time
            // The limit is per line, so the total time only tells for one line.
            hitTimeLimit = shape == .minified && limit > 0 && time >= .milliseconds(limit)
            characters = code.utf16.count
            generation += 1
        } catch {
            result = nil
        }
    }

    nonisolated private static func generate(sample: String, language: String, lines: Int, minified: Bool) -> String {
        if minified {
            // ~200k characters on a single line.
            let unit: String
            switch language {
            case "json": unit = #"{"id":1,"name":"shiki","tags":["a","b"],"ok":true,"n":null},"#
            case "python": unit = "x = [i * 2 for i in range(10) if i % 3]; print(f'{x!r}'); "
            default: unit = "const a=(b)=>b+1;if(a(2)>1){console.log(\"x\",[1,2,3].map(c=>c*2))};"
            }
            let body = String(repeating: unit, count: 200_000 / unit.count)
            return language == "json" ? "[" + body.dropLast() + "]" : body
        }
        let sampleLines = sample.components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines)
        if language == "json" {
            // Keep the document valid JSON: an array of repeated objects.
            output.append("[")
            while output.count < lines - 1 {
                output.append(contentsOf: sampleLines.map { "  " + $0 })
                output[output.count - 1] += ","
            }
            output[output.count - 1].removeLast()
            output.append("]")
            return output.joined(separator: "\n")
        }
        while output.count < lines {
            output.append(contentsOf: sampleLines)
            output.append("")
        }
        return output.prefix(lines).joined(separator: "\n")
    }
}

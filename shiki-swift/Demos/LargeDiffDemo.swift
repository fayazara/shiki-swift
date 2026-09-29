import Shiki
import ShikiDiffs
import SwiftUI

/// Diffs two generated versions of a large file with ShikiDiffs: jsdiff-style
/// line and inline (word) changes, highlighted with Shiki and shown in the
/// native split/unified diff view, which only lays out what is on screen.
struct LargeDiffDemo: View {
    @Environment(AppTheme.self) private var appTheme
    @State private var language = "swift"
    @State private var lineCount = 10_000
    @State private var density = 0.02
    @State private var style: DiffStyle = .split
    @State private var expandUnchanged = false
    @State private var document: HighlightedDiff?
    @State private var prepareTime: Duration?
    @State private var status: String?
    @State private var running = false
    @State private var failure: String?

    private let languages = ["swift", "typescript", "python", "json", "rust"]
    private let sizes = [1_000, 10_000, 30_000, 100_000]
    private let densities: [(String, Double)] = [("0.5%", 0.005), ("2%", 0.02), ("5%", 0.05), ("15%", 0.15)]

    /// One highlighter for the page: it caches grammars, themes and tokens.
    private static let highlighter = DiffHighlighter()

    private var options: DiffRenderOptions {
        var options = DiffRenderOptions()
        options.theme = appTheme.themeID
        options.diffStyle = style
        options.expandUnchanged = expandUnchanged
        options.fontName = appTheme.codeFontFamily.map { _ in appTheme.codeNSFont(size: 12).fontName }
        options.fontSize = 12
        options.lineHeight = 20
        // The edited copy of a 100k-line file is a little longer than that;
        // keep it highlighted (the default stops at 100,000 lines).
        options.tokenizeMaxLength = 150_000
        return options
    }

    var body: some View {
        let palette = appTheme.palette
        DemoPage(title: "Large File Diff",
                 subtitle: "Diff two versions of a big file with ShikiDiffs: line and word-level changes, highlighted by Shiki, in the native split or unified view. Only the rows on screen are laid out, and unchanged stretches fold into expandable separators.",
                 scrolls: false) {
            AdaptiveRow {
                Picker("Language", selection: $language) {
                    ForEach(languages, id: \.self) { Text(DemoLanguages.name(for: $0)).tag($0) }
                }.frame(maxWidth: 180)
                Picker("Size", selection: $lineCount) {
                    ForEach(sizes, id: \.self) { Text("\($0.formatted()) lines").tag($0) }
                }.frame(maxWidth: 170)
                Picker("Edited", selection: $density) {
                    ForEach(densities, id: \.1) { Text($0.0).tag($0.1) }
                }.frame(maxWidth: 140)
                Picker("Layout", selection: $style) {
                    Text("Split").tag(DiffStyle.split)
                    Text("Unified").tag(DiffStyle.unified)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Expand unchanged", isOn: $expandUnchanged)
                Button {
                    Task { await run() }
                } label: {
                    Label(running ? "Working…" : "Generate & Diff", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                StatTile(label: "Old lines", value: (document?.diff.deletionLines.count ?? 0).formatted(), palette: palette)
                StatTile(label: "New lines", value: (document?.diff.additionLines.count ?? 0).formatted(), palette: palette)
                StatTile(label: "Added", value: "+" + (document?.diff.additions ?? 0).formatted(), palette: palette)
                StatTile(label: "Removed", value: "−" + (document?.diff.deletions ?? 0).formatted(), palette: palette)
                StatTile(label: "Hunks", value: (document?.diff.hunks.count ?? 0).formatted(), palette: palette)
                StatTile(label: "Diff + highlight", value: prepareTime.map {
                    $0.formatted(.units(allowed: [.milliseconds, .seconds], width: .narrow))
                } ?? "—", palette: palette)
            }

            Group {
                if let document {
                    FileDiffView(document: document, options: options)
                } else if let failure {
                    ContentUnavailableView("Couldn’t prepare the diff", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ContentUnavailableView("No diff yet", systemImage: "arrow.left.arrow.right",
                                           description: Text("Pick a size and press Generate & Diff."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.border))
            .overlay {
                if running {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        if let status { Text(status).font(.callout).foregroundStyle(palette.secondaryText) }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        // Theme changes need new tokens; layout and font are presentation only.
        .onChange(of: appTheme.themeID) { if document != nil { Task { await run() } } }
    }

    private func run() async {
        running = true
        failure = nil
        defer { running = false; status = nil }
        status = "Generating two versions…"
        let sample = DemoSamples.gallery.first { $0.language == language }?.code ?? ""
        let (language, lineCount, density) = (language, lineCount, density)
        let (oldCode, newCode) = await Task.detached(priority: .userInitiated) {
            Self.makeVersions(sample: sample, language: language, lines: lineCount, density: density)
        }.value
        let extensions = ["swift": "swift", "typescript": "ts", "python": "py", "json": "json", "rust": "rs"]
        let name = "Generated." + (extensions[language] ?? language)
        status = "Diffing and highlighting…"
        do {
            let clock = ContinuousClock()
            let started = clock.now
            let prepared = try await Self.highlighter.prepare(
                oldFile: FileContents(name: name, contents: oldCode, lang: language),
                newFile: FileContents(name: name, contents: newCode, lang: language),
                options: options
            )
            prepareTime = clock.now - started
            document = prepared
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Inputs

    /// The original file plus a deterministic edited copy: lines are deleted,
    /// changed, or followed by inserted lines at the requested density.
    nonisolated private static func makeVersions(
        sample: String, language: String, lines: Int, density: Double
    ) -> (old: String, new: String) {
        let original = LargeFileDemo.generate(sample: sample, language: language, lines: lines, minified: false)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }

        var edited: [String] = []
        edited.reserveCapacity(lines + lines / 20)
        for line in original.components(separatedBy: "\n") {
            let roll = random()
            if roll < density * 0.3 {
                continue // deleted
            } else if roll < density * 0.7 {
                edited.append(changed(line))
            } else if roll < density {
                edited.append(line)
                for _ in 0..<(1 + Int(random() * 3)) { edited.append(changed(line)) }
            } else {
                edited.append(line)
            }
        }
        return (original + "\n", edited.joined(separator: "\n") + "\n")
    }

    /// Renames the first identifier on the line, so the inline diff has a
    /// word-level change to show.
    nonisolated private static func changed(_ line: String) -> String {
        if let word = line.firstMatch(of: /[A-Za-z_]{3,}/) {
            var copy = line
            copy.insert(contentsOf: "V2", at: word.range.upperBound)
            return copy
        }
        return line + " // edited"
    }
}

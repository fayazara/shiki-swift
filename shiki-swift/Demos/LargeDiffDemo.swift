import Shiki
import ShikiUI
import SwiftUI

/// Diffs two generated versions of a large file and shows the result in the
/// virtualized viewport: unified rows, syntax-highlighted by Shiki, with
/// changed lines tinted and unchanged stretches folded into hunks.
struct LargeDiffDemo: View {
    @Environment(AppTheme.self) private var appTheme
    @State private var language = "swift"
    @State private var lineCount = 10_000
    @State private var density = 0.02
    @State private var changesOnly = true
    @State private var model: Model?
    @State private var rows: TokensResult?
    @State private var status: String?
    @State private var running = false
    @State private var generation = 0

    private let languages = ["swift", "typescript", "python", "json", "rust"]
    private let sizes = [1_000, 10_000, 30_000, 100_000]
    private let densities: [(String, Double)] = [("0.5%", 0.005), ("2%", 0.02), ("5%", 0.05), ("15%", 0.15)]

    /// Everything the rows are built from, so toggling views needs no new work.
    private struct Model: Sendable {
        let oldTokens: TokensResult
        let newTokens: TokensResult
        let diff: LineDiff.Result
        let oldLines: Int
        let newLines: Int
        let highlightTime: Duration
        let diffTime: Duration
    }

    var body: some View {
        let palette = appTheme.palette
        DemoPage(title: "Large File Diff",
                 subtitle: "Diff two versions of a big file and highlight both with Shiki. A linear-space Myers diff finds the changes; the result is one unified view in ShikiVirtualizedCodeView, so only the visible rows are ever laid out.",
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
                Toggle("Changes only", isOn: $changesOnly)
                    .help("Show 3 lines of context around each change and fold the rest.")
                Button {
                    Task { await run(regenerate: true) }
                } label: {
                    Label(running ? "Working…" : "Generate & Diff", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                StatTile(label: "Old lines", value: (model?.oldLines ?? 0).formatted(), palette: palette)
                StatTile(label: "New lines", value: (model?.newLines ?? 0).formatted(), palette: palette)
                StatTile(label: "Added", value: "+" + (model?.diff.added ?? 0).formatted(), palette: palette)
                StatTile(label: "Removed", value: "−" + (model?.diff.removed ?? 0).formatted(), palette: palette)
                StatTile(label: "Hunks", value: (model?.diff.hunks ?? 0).formatted(), palette: palette)
                StatTile(label: "Diff time", value: format(model?.diffTime), palette: palette)
                StatTile(label: "Highlight time", value: format(model?.highlightTime), palette: palette)
                StatTile(label: "Rows shown", value: (rows?.tokens.count ?? 0).formatted(), palette: palette)
            }

            if model?.diff.timedOut == true {
                Label("The diff hit its time limit, so part of the file is reported as replaced rather than minimally changed.",
                      systemImage: "timer")
                    .font(.callout).foregroundStyle(palette.secondaryText)
            }

            GeometryReader { proxy in
                Group {
                    if let rows {
                        ShikiVirtualizedCodeView(
                            result: rows, renderID: generation,
                            font: appTheme.codeNSFont(size: 12),
                            contentPadding: 12, viewportHeight: proxy.size.height
                        )
                    } else {
                        ContentUnavailableView("No diff yet", systemImage: "arrow.left.arrow.right",
                                               description: Text("Pick a size and press Generate & Diff."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
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
        }
        .onChange(of: changesOnly) { Task { await rebuildRows() } }
        .onChange(of: appTheme.themeID) { if model != nil { Task { await run(regenerate: false) } } }
    }

    private func format(_ duration: Duration?) -> String {
        duration.map { $0.formatted(.units(allowed: [.milliseconds, .seconds], width: .narrow)) } ?? "—"
    }

    // MARK: - Work

    private func run(regenerate: Bool) async {
        running = true
        defer { running = false; status = nil }
        do {
            var oldCode = ""
            var newCode = ""
            var diff = model?.diff
            var diffTime = model?.diffTime ?? .zero
            if regenerate || model == nil {
                status = "Generating two versions…"
                let sample = DemoSamples.gallery.first { $0.language == language }?.code ?? ""
                let (language, lineCount, density) = (language, lineCount, density)
                (oldCode, newCode) = await Task.detached(priority: .userInitiated) {
                    Self.makeVersions(sample: sample, language: language, lines: lineCount, density: density)
                }.value
                status = "Diffing…"
                let clock = ContinuousClock()
                let started = clock.now
                diff = await Task.detached(priority: .userInitiated) {
                    LineDiff.compute(old: oldCode.components(separatedBy: "\n"),
                                     new: newCode.components(separatedBy: "\n"))
                }.value
                diffTime = clock.now - started
            } else if let model {
                // Theme change: the text is unchanged; only colors need redoing.
                oldCode = model.oldTokens.tokens.map { $0.map(\.content).joined() }.joined(separator: "\n")
                newCode = model.newTokens.tokens.map { $0.map(\.content).joined() }.joined(separator: "\n")
            }

            let language = language
            let theme = appTheme.themeID
            status = "Highlighting old version…"
            let (oldTokens, oldTime) = try await DemoEngine.shared.timedTokens(oldCode, language: language, theme: theme)
            status = "Highlighting new version…"
            let (newTokens, newTime) = try await DemoEngine.shared.timedTokens(newCode, language: language, theme: theme)

            guard let diff else { return }
            model = Model(
                oldTokens: oldTokens, newTokens: newTokens, diff: diff,
                oldLines: oldTokens.tokens.count, newLines: newTokens.tokens.count,
                highlightTime: oldTime + newTime, diffTime: diffTime
            )
            status = "Building rows…"
            await rebuildRows()
        } catch {
            status = String(describing: error)
        }
    }

    private func rebuildRows() async {
        guard let model else { return }
        let changesOnly = changesOnly
        rows = await Task.detached(priority: .userInitiated) {
            Self.unifiedRows(model, changesOnly: changesOnly)
        }.value
        generation += 1
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
        return (original, edited.joined(separator: "\n"))
    }

    nonisolated private static func changed(_ line: String) -> String {
        if let word = line.firstMatch(of: /[A-Za-z_]{3,}/) {
            var copy = line
            copy.insert(contentsOf: "V2", at: word.range.upperBound)
            return copy
        }
        return line + " "
    }

    // MARK: - Rows

    nonisolated private static let addedTint = "#2ea04340"
    nonisolated private static let removedTint = "#f8514940"
    nonisolated private static let hunkTint = "#388bfd26"

    /// One token row per diff row: `old new │ ± code`, highlighted with the
    /// tokens from the version the line came from.
    nonisolated private static func unifiedRows(_ model: Model, changesOnly: Bool) -> TokensResult {
        let ops = changesOnly ? LineDiff.collapsing(model.diff.ops, context: 3) : model.diff.ops
        let oldRows = model.oldTokens.tokens
        let newRows = model.newTokens.tokens
        let dim = (model.newTokens.fg ?? "#8b949e") + "80"
        let numberWidth = String(max(model.oldLines, model.newLines)).count
        func number(_ value: Int?) -> String {
            let text = value.map { String($0 + 1) } ?? ""
            return String(repeating: " ", count: max(0, numberWidth - text.count)) + text
        }
        let filler = String(repeating: " ", count: 160)

        var rows: [[ThemedToken]] = []
        rows.reserveCapacity(ops.count)
        for op in ops {
            switch op {
            case let .equal(old, new):
                rows.append([gutter(number(old), number(new), " ", nil, dim)] + newRows[new])
            case let .removed(old):
                rows.append([gutter(number(old), number(nil), "−", "#f85149", dim, tint: removedTint)]
                    + tinted(oldRows[old], removedTint)
                    + [ThemedToken(content: filler, offset: 0, bgColor: removedTint)])
            case let .added(new):
                rows.append([gutter(number(nil), number(new), "+", "#3fb950", dim, tint: addedTint)]
                    + tinted(newRows[new], addedTint)
                    + [ThemedToken(content: filler, offset: 0, bgColor: addedTint)])
            case let .gap(old, new, count):
                let text = "\(String(repeating: " ", count: numberWidth * 2 + 1)) ··· \(count.formatted()) unchanged lines (old \(old + 1), new \(new + 1))"
                rows.append([ThemedToken(content: text + filler, offset: 0, color: dim, bgColor: hunkTint)])
            }
        }
        return TokensResult(tokens: rows, fg: model.newTokens.fg, bg: model.newTokens.bg)
    }

    nonisolated private static func gutter(
        _ old: String, _ new: String, _ marker: String, _ markerColor: String?, _ dim: String, tint: String? = nil
    ) -> ThemedToken {
        // One token keeps rows cheap; the marker shares the dimmed gutter color
        // unless the line changed, where the tint carries the meaning.
        ThemedToken(content: "\(old) \(new) \(marker) ", offset: 0, color: markerColor ?? dim, bgColor: tint)
    }

    nonisolated private static func tinted(_ tokens: [ThemedToken], _ tint: String) -> [ThemedToken] {
        tokens.map { token in
            var copy = token
            copy.bgColor = tint
            return copy
        }
    }
}

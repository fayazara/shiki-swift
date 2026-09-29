import SwiftUI
import ShikiDiffs
import Shiki

enum DemoStreamMode: String, CaseIterable, Identifiable {
    case snapshots = "File snapshots", component = "Managed stream", tokens = "Token recalls", clones = "Tokenizer branches"
    var id: String { rawValue }
}

private actor DemoStreamChunks {
    private var index = 0
    private let chunks = ["/* A streamed comment\n", "contin", "ues here */\n", "let greet", "ing = \"", "Hello 👋", "\"\n", "print(gree", "ting)"]
    func next() async throws -> String? {
        guard index < chunks.count else { return nil }
        try await Task.sleep(for: .milliseconds(350))
        defer { index += 1 }
        return chunks[index]
    }
}

@MainActor private final class DemoStreamHost { weak var view: NativeFileStreamView? }

struct DemoStreamingView: View {
    let mode: DemoStreamMode
    let options: DiffRenderOptions
    let configuration: StreamTokenizerConfiguration
    let highlighter: DiffHighlighter
    @State private var componentSource: AsyncThrowingStream<String, any Error>?
    @State private var componentID = UUID()
    @State private var adaptiveConfiguration: ThemedStreamTokenizerConfiguration?
    @State private var streamAppearance: DiffThemeAppearance = .light
    @State private var streamHost = DemoStreamHost()
    @State private var streamWrites = 0
    @State private var allowRecalls = true
    @State private var replay = 0
    @State private var generation = UUID()
    @State private var first: HighlightedDiff?
    @State private var second: HighlightedDiff?
    @State private var status = "Preparing…"
    @State private var failure: String?
    private var runKey: String { mode.rawValue + options.theme + String(allowRecalls) + String(replay) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if mode == .component {
                    Button("Stop") { streamHost.view?.cancel() }
                    Picker("Appearance", selection: $streamAppearance) {
                        ForEach(DiffThemeAppearance.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.frame(width: 180)
                }
                if mode == .tokens { Toggle("Show incomplete tokens", isOn: $allowRecalls) }
                Text(mode == .component ? "The library owns streaming, cancellation and lifecycle callbacks." : mode == .tokens ? "Incomplete tokens are replaced as new text arrives." : "Both branches inherit the same comment, then receive different text.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Replay", systemImage: "arrow.clockwise") { replay += 1 }
            }.padding(12)
            Divider()
            if mode == .component, let componentSource {
                FileStreamView(source: componentSource, streamID: componentID, name: "Stream.swift", configuration: configuration, options: options, startingLineIndex: 42, adaptiveConfiguration: adaptiveConfiguration, themeAppearance: streamAppearance,
                    onPreRender: { streamHost.view = $0 },
                    onStreamStart: { status = "Stream started" },
                    onStreamWrite: { _ in streamWrites += 1; status = "\(streamWrites) token events" },
                    onStreamClose: { status = "Closed · \(streamWrites) token events" },
                    onStreamAbort: { error in Task { @MainActor in status = error is CancellationError ? "Stream stopped" : error.localizedDescription } })
            } else if let failure {
                ContentUnavailableView("Couldn’t stream code", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else if let first {
                if mode == .clones {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) { Text("Branch A").font(.headline).padding(10); FileView(document: first, options: options) }
                        Divider()
                        VStack(spacing: 0) {
                            Text("Branch B").font(.headline).padding(10)
                            if let second { FileView(document: second, options: options) }
                        }
                    }
                } else { FileView(document: first, options: options) }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Divider()
            Text(status).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .task(id: runKey) { await run() }
    }

    @MainActor private func run() async {
        let request = UUID(); generation = request
        first = nil; second = nil; failure = nil; status = "Preparing…"
        if mode == .component {
            do { adaptiveConfiguration = try await highlighter.streamConfiguration(language: configuration.language, themes: .init()) }
            catch { failure = error.localizedDescription; return }
            guard generation == request, !Task.isCancelled else { return }
            let chunks = DemoStreamChunks()
            streamWrites = 0; componentID = UUID()
            componentSource = AsyncThrowingStream(unfolding: { try await chunks.next() })
            return
        }
        let sourceA = UUID(), sourceB = UUID()
        do {
            var empty = FileDiffMetadata(name: "Stream.swift"); empty.isPartial = false
            let template = try await highlighter.prepare(empty, options: options)
            try Task.checkCancellation()
            guard generation == request else { return }
            first = snapshot([], template: template, source: sourceA, name: "Stream.swift")
            if mode == .tokens {
                let chunks = DemoStreamChunks()
                let input = AsyncThrowingStream<String, any Error>(unfolding: { try await chunks.next() })
                let stream = CodeToTokenTransformStream(input, configuration: configuration, allowRecalls: allowRecalls)
                var tokens: [ThemedToken] = [], emitted = 0, recalled = 0
                for try await event in stream {
                    try Task.checkCancellation()
                    guard generation == request else { return }
                    switch event {
                    case .token(let token): tokens.append(token); emitted += 1
                    case .recall(let count):
                        guard count <= tokens.count else { throw DiffError.invalidPatch("Stream recalled unavailable tokens") }
                        tokens.removeLast(count); recalled += count
                    }
                    first = snapshot(tokens, template: template, source: sourceA, name: "Stream.swift")
                    status = "\(emitted) tokens emitted · \(recalled) recalled"
                }
                status += " · Complete"
            } else {
                let original = ShikiStreamTokenizer(configuration: configuration)
                let opening = try await original.enqueue("/* Shared opening comment\ncontinued")
                let branch = await original.clone()
                var left = opening.stable + opening.unstable, right = left
                try Task.checkCancellation()
                guard generation == request else { return }
                first = snapshot(left, template: template, source: sourceA, name: "BranchA.swift")
                second = snapshot(right, template: template, source: sourceB, name: "BranchB.swift")
                for (a, b) in [(" in A */\n", " in B */\n"), ("let choice = \"left\"\n", "let choice = \"right\"\n")] {
                    try await Task.sleep(for: .milliseconds(700))
                    let updateA = try await original.enqueue(a), updateB = try await branch.enqueue(b)
                    try Task.checkCancellation()
                    guard generation == request else { return }
                    left.removeLast(updateA.recall); left += updateA.stable + updateA.unstable
                    right.removeLast(updateB.recall); right += updateB.stable + updateB.unstable
                    first = snapshot(left, template: template, source: sourceA, name: "BranchA.swift")
                    second = snapshot(right, template: template, source: sourceB, name: "BranchB.swift")
                    let sharedCount = await original.tokensStable.count
                    try Task.checkCancellation()
                    guard generation == request else { return }
                    status = "Independent pending text · \(sharedCount) tokens in the shared stable buffer"
                }
                _ = await original.close(); _ = await branch.close()
            }
        } catch is CancellationError { }
        catch { if generation == request { failure = error.localizedDescription; status = "Stream stopped" } }
    }

    private func snapshot(_ tokens: [ThemedToken], template: HighlightedDiff, source: UUID, name: String) -> HighlightedDiff {
        var lines: [String] = [], rows: [[ThemedToken]] = [], current: [ThemedToken] = [], text = ""
        for token in tokens {
            if token.content == "\n" { lines.append(text + "\n"); rows.append(current); current = []; text = "" }
            else { var positioned = token; positioned.offset = text.utf16.count; current.append(positioned); text += token.content }
        }
        if !text.isEmpty { lines.append(text); rows.append(current) }
        var diff = FileDiffMetadata(name: name); diff.isPartial = false; diff.deletionLines = lines; diff.additionLines = lines
        return .init(sourceID: source, diff: diff, oldTokens: rows, newTokens: rows,
                     foreground: template.foreground, background: template.background, palette: template.palette)
    }
}

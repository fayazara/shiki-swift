import Observation
import Shiki
import SwiftUI

/// Highlights text that arrives in chunks (e.g. from an LLM) without
/// re-tokenizing everything: completed lines are tokenized once, then the
/// grammar state is carried forward; only the in-progress line is redone.
@Observable
final class IncrementalHighlighter {
    let language: String
    let theme: String
    private(set) var committed: [[ThemedToken]] = []
    private(set) var partial: [ThemedToken] = []
    private(set) var source = ""
    /// Characters actually tokenized vs. what naive full re-highlighting costs.
    private(set) var tokenizedChars = 0
    private(set) var naiveChars = 0
    private(set) var lastTick: Duration = .zero

    private var state: ShikiGrammarState?
    private var pendingLine = ""

    init(language: String, theme: String) {
        self.language = language
        self.theme = theme
    }

    var lines: [[ThemedToken]] { committed + [partial] }

    func append(_ chunk: String) async throws {
        let start = ContinuousClock.now
        source += chunk
        pendingLine += chunk
        naiveChars += source.utf16.count

        if let newline = pendingLine.lastIndex(of: "\n") {
            let complete = String(pendingLine[..<newline])
            pendingLine = String(pendingLine[pendingLine.index(after: newline)...])
            // Resume from the saved state so multi-line constructs (block
            // comments, strings) stay correct; save the new state.
            let result = try await DemoEngine.shared.highlight(complete, language: language, theme: theme,
                                                               resumingFrom: state)
            committed += result.result.tokens
            state = result.grammarState
            tokenizedChars += complete.utf16.count
        }
        // The in-progress line is re-tokenized each tick, but its state is discarded.
        let partialResult = try await DemoEngine.shared.highlight(pendingLine, language: language, theme: theme,
                                                                  resumingFrom: state)
        partial = partialResult.result.tokens.first ?? []
        tokenizedChars += pendingLine.utf16.count
        lastTick = ContinuousClock.now - start
    }
}

struct StreamingDemo: View {
    struct Message: Identifiable {
        let id = UUID()
        let prompt: String
        var prose = ""
        var language: String
        var code = ""
        var highlighter: IncrementalHighlighter?
        var done = false
    }

    @Environment(AppTheme.self) private var appTheme
    @State private var messages: [Message] = []
    @State private var speed = 1.0
    @State private var streaming: Task<Void, Never>?

    var body: some View {
        let palette = appTheme.palette
        DemoPage(title: "Streaming Chat",
                 subtitle: "Simulates an AI assistant streaming a code answer. Each tick only the unfinished line is re-tokenized; finished lines resume from the saved grammar state. Compare the work done with naive re-highlighting.",
                 scrolls: false) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if messages.isEmpty {
                            ContentUnavailableView("Pick a prompt below", systemImage: "sparkles",
                                                   description: Text("The response streams in with live syntax highlighting."))
                                .frame(maxWidth: .infinity, minHeight: 260)
                        }
                        ForEach(messages) { message in
                            bubble(message, palette: palette)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(4)
                }
                .onChange(of: messages.last?.code.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: messages.last?.prose.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)

            composer(palette)
        }
        .onDisappear { streaming?.cancel() }
    }

    private func bubble(_ message: Message, palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 120)
                Text(message.prompt)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(palette.accent.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(palette.accent)
                    .frame(width: 26, height: 26)
                    .background(palette.panel, in: Circle())
                VStack(alignment: .leading, spacing: 12) {
                    if !message.prose.isEmpty {
                        Text((try? AttributedString(markdown: message.prose)) ?? AttributedString(message.prose))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if message.done {
                        CodeBlock(code: message.code, language: message.language)
                    } else if let highlighter = message.highlighter {
                        streamingBlock(highlighter, palette: palette)
                    }
                    if let highlighter = message.highlighter {
                        metrics(highlighter, palette: palette)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }

    private func streamingBlock(_ highlighter: IncrementalHighlighter, palette: Palette) -> some View {
        let codePalette = Palette(themeID: highlighter.theme)
        return VStack(spacing: 0) {
            HStack {
                Text(DemoLanguages.name(for: highlighter.language))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                ProgressView().controlSize(.mini)
            }
            .foregroundStyle(codePalette.secondaryText)
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider().overlay(codePalette.border)
            CodeLines(lines: highlighter.lines, palette: codePalette, trailingCursor: true)
        }
        .background(codePalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(codePalette.border))
    }

    private func metrics(_ highlighter: IncrementalHighlighter, palette: Palette) -> some View {
        let saved = highlighter.naiveChars == 0 ? 0 :
            100 - Double(highlighter.tokenizedChars) / Double(highlighter.naiveChars) * 100
        return HStack(spacing: 14) {
            Label("\(highlighter.tokenizedChars.formatted()) chars tokenized", systemImage: "bolt")
            Label("naive: \(highlighter.naiveChars.formatted())", systemImage: "tortoise")
            Label("\(saved.formatted(.number.precision(.fractionLength(0))))% less work", systemImage: "leaf")
            Label("tick \(highlighter.lastTick.formatted(.units(allowed: [.microseconds, .milliseconds], width: .narrow)))",
                  systemImage: "stopwatch")
        }
        .font(.caption)
        .foregroundStyle(palette.secondaryText)
    }

    private func composer(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout {
                ForEach(StreamingSamples.all.indices, id: \.self) { index in
                    Button(StreamingSamples.all[index].prompt) { send(StreamingSamples.all[index]) }
                        .buttonStyle(.bordered)
                        .disabled(streaming != nil)
                }
            }
            HStack(spacing: 12) {
                Text("Speed").font(.caption)
                Slider(value: $speed, in: 0.25...4).frame(maxWidth: 200)
                Text("\(speed.formatted(.number.precision(.fractionLength(2))))×").font(.caption).monospacedDigit()
                Spacer()
                if streaming != nil {
                    Button("Stop", systemImage: "stop.fill") { streaming?.cancel() }
                }
                Button("Clear", systemImage: "trash") { messages.removeAll() }
                    .disabled(streaming != nil || messages.isEmpty)
            }
        }
        .panel(palette, padding: 12)
    }

    private func send(_ response: StreamingSamples.Response) {
        let highlighter = IncrementalHighlighter(language: response.language, theme: appTheme.themeID)
        messages.append(Message(prompt: response.prompt, language: response.language, highlighter: highlighter))
        let index = messages.count - 1
        streaming = Task {
            defer {
                messages[index].done = true
                streaming = nil
            }
            // Prose first, a few characters at a time.
            var prose = Substring(response.prose)
            while !prose.isEmpty, !Task.isCancelled {
                messages[index].prose += String(prose.prefix(3))
                prose = prose.dropFirst(3)
                try? await Task.sleep(for: .milliseconds(Int(12 / speed)))
            }
            // Then code in irregular, token-sized chunks.
            var code = Substring(response.code)
            while !code.isEmpty, !Task.isCancelled {
                let chunk = String(code.prefix(Int.random(in: 2...7)))
                code = code.dropFirst(chunk.count)
                messages[index].code += chunk
                try? await highlighter.append(chunk)
                try? await Task.sleep(for: .milliseconds(Int(28 / speed)))
            }
        }
    }
}

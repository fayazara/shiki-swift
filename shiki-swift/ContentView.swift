import Foundation
import Shiki
import ShikiUI
import SwiftUI

private actor DemoSyntaxHighlighter {
    private var highlighter: ShikiHighlighter?

    func highlight(
        _ code: String,
        language: String,
        theme: String
    ) throws -> DemoHighlightResult {
        try Task.checkCancellation()

        let highlighter: ShikiHighlighter
        if let existing = self.highlighter {
            highlighter = existing
        } else {
            let created = try ShikiHighlighter(defaultTheme: theme)
            self.highlighter = created
            highlighter = created
        }

        let result = try highlighter.codeToTokens(
            code,
            language: language,
            theme: theme
        )
        try Task.checkCancellation()
        let tokenCount = result.tokens.reduce(into: 0) { count, line in
            count += line.count
        }
        return DemoHighlightResult(
            result: result,
            tokenCount: tokenCount,
            utf16Count: code.utf16.count
        )
    }
}

private struct DemoHighlightResult: Sendable {
    let result: TokensResult
    let tokenCount: Int
    let utf16Count: Int
}

struct ContentView: View {
    @State private var highlightedCode: TokensResult?
    @State private var errorMessage: String?
    @State private var codeInput: String
    @State private var highlightRequest: HighlightRequest
    @State private var nextRequestID = 1
    @State private var isHighlighting = false
    @State private var renderSummary: String?
    @State private var selectedLanguage = "swift"
    @State private var selectedTheme = "github-dark"
    @State private var syntaxHighlighter = DemoSyntaxHighlighter()

    private struct DemoLanguage: Identifiable, Sendable {
        let id: String
        let title: String
        let code: String
    }

    private struct HighlightRequest: Equatable, Sendable {
        let id: Int
        let code: String
        let language: String
        let theme: String
    }

    private static let demos: [DemoLanguage] = [
        DemoLanguage(
            id: "swift",
            title: "Swift",
            code: """
            import SwiftUI

            struct Greeting: View {
                let name = "Shiki 👋"

                var body: some View {
                    Text("Hello, \\(name)!")
                        .font(.headline)
                }
            }
            """
        ),
        DemoLanguage(
            id: "typescript",
            title: "TypeScript",
            code: """
            type User = { name: string; active: boolean }

            const greet = ({ name, active }: User) => {
              const emoji = active ? "👋" : "💤"
              return `Hello, ${name} ${emoji}`
            }

            console.log(greet({ name: "Shiki", active: true }))
            """
        ),
        DemoLanguage(
            id: "javascript",
            title: "JavaScript",
            code: """
            const themes = ["github-dark", "nord", "vitesse-light"]

            function pickTheme(index) {
              return themes[index % themes.length]
            }

            console.log(`Using ${pickTheme(1)} ✨`)
            """
        ),
        DemoLanguage(
            id: "html",
            title: "HTML",
            code: """
            <article class="welcome">
              <h1>Hello, Shiki 👋</h1>
              <p>Native syntax highlighting for Swift apps.</p>
              <button type="button">Change theme</button>
            </article>
            """
        ),
        DemoLanguage(
            id: "markdown",
            title: "Markdown",
            code: """
            # Shiki for Swift

            Native highlighting with **VS Code themes**.

            ```swift
            let greeting = "Hello 👋"
            ```

            - 242 languages
            - Zero JavaScript at runtime
            """
        ),
        DemoLanguage(
            id: "python",
            title: "Python",
            code: """
            from dataclasses import dataclass

            @dataclass
            class Greeting:
                name: str
                emoji: str = "👋"

            print(f"Hello, {Greeting('Shiki').name}!")
            """
        ),
        DemoLanguage(
            id: "go",
            title: "Go",
            code: """
            package main

            import "fmt"

            func main() {
                name := "Shiki"
                fmt.Printf("Hello, %s 👋\\n", name)
            }
            """
        ),
        DemoLanguage(
            id: "rust",
            title: "Rust",
            code: """
            fn main() {
                let languages = ["Swift", "Rust", "Go"];

                for language in languages {
                    println!("Hello, {language}! 👋");
                }
            }
            """
        ),
        DemoLanguage(
            id: "json",
            title: "JSON",
            code: """
            {
              "name": "shiki-swift",
              "native": true,
              "languages": 242,
              "themes": ["github-dark", "nord"]
            }
            """
        ),
        DemoLanguage(
            id: "css",
            title: "CSS",
            code: """
            .code-card {
              color: light-dark(#24292e, #e1e4e8);
              background: var(--shiki-background);
              border-radius: 1rem;
              overflow-x: auto;
            }
            """
        ),
        DemoLanguage(
            id: "sql",
            title: "SQL",
            code: """
            SELECT language, COUNT(*) AS themes
            FROM highlights
            WHERE runtime = 'native'
            GROUP BY language
            ORDER BY themes DESC;
            """
        ),
    ]

    private static let themes = BundledShikiAssets.shared.themes.sorted {
        $0.displayName < $1.displayName
    }

    init() {
        let initialDemo = Self.demos[0]
        _codeInput = State(initialValue: initialDemo.code)
        _highlightRequest = State(
            initialValue: HighlightRequest(
                id: 0,
                code: initialDemo.code,
                language: initialDemo.id,
                theme: "github-dark"
            )
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.063, blue: 0.082),
                    Color(red: 0.085, green: 0.094, blue: 0.125),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shiki, now native.")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("TextMate grammars, VS Code themes, and Oniguruma — all running directly in Swift.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        languagePicker
                        themePicker
                        badge("Native Oniguruma", systemImage: "bolt.fill")
                    }

                    inputPanel
                    outputPanel
                    renderStatus
                }
                .padding(34)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .preferredColorScheme(.dark)
        .task(id: highlightRequest) {
            await highlight(highlightRequest)
        }
    }

    private var inputPanel: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Paste code to stress test", systemImage: "doc.on.clipboard")
                        .font(.headline)

                    Spacer()

                    if hasUnrenderedChanges {
                        Label("Changes not rendered", systemImage: "circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    Text("The selected language and theme are used exactly. Changes render only when you click Render code.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 16)

                    Button("Load \(selectedDemo.title) sample") {
                        codeInput = selectedDemo.code
                    }
                    .buttonStyle(.bordered)

                    Button(action: submitCode) {
                        Label("Render code", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(16)

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $codeInput)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .accessibilityLabel("Code to highlight")
                    .accessibilityHint(
                        "Paste code here, choose its language and theme, then activate Render code."
                    )

                if codeInput.isEmpty {
                    Text("Paste a large code block here…")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 190)
            .background(Color.black.opacity(0.18))
        }
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
    }

    private var outputPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Highlighted output", systemImage: "text.page")
                    .font(.headline)

                Spacer()

                Text(languageName(for: highlightRequest.language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Group {
                if let highlightedCode {
                    StressTestCodeView(
                        result: highlightedCode,
                        renderID: highlightRequest.id,
                        fontSize: 15,
                        contentPadding: 22,
                        viewportHeight: outputViewportHeight
                    )
                    .frame(height: outputViewportHeight)
                    .accessibilityLabel("Highlighted code output")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Highlighting failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    .frame(minHeight: 120)
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            "Rendering \(languageName(for: highlightRequest.language)) "
                                + "with \(themeName(for: highlightRequest.theme))…"
                        )
                        .foregroundStyle(.secondary)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
    }

    private var renderStatus: some View {
        HStack(spacing: 7) {
            Image(systemName: statusSystemImage)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Render status")
        .accessibilityValue(statusText)
    }

    private var languagePicker: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")

            Picker("Language", selection: $selectedLanguage) {
                ForEach(Self.demos) { demo in
                    Text(demo.title)
                        .tag(demo.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06), in: Capsule())
        .accessibilityLabel("Syntax language")
        .accessibilityValue(selectedDemo.title)
    }

    private var themePicker: some View {
        HStack(spacing: 5) {
            Image(systemName: "paintpalette")

            Picker("Theme", selection: $selectedTheme) {
                ForEach(Self.themes) { theme in
                    Text(theme.displayName)
                        .tag(theme.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06), in: Capsule())
        .accessibilityLabel("Syntax theme")
        .accessibilityValue(selectedThemeName)
    }

    private var selectedThemeName: String {
        themeName(for: selectedTheme)
    }

    private var selectedDemo: DemoLanguage {
        Self.demos.first { $0.id == selectedLanguage } ?? Self.demos[0]
    }

    private var hasUnrenderedChanges: Bool {
        codeInput != highlightRequest.code
            || selectedLanguage != highlightRequest.language
            || selectedTheme != highlightRequest.theme
    }

    private var outputViewportHeight: CGFloat {
        guard let highlightedCode else { return 120 }
        let estimatedHeight = CGFloat(max(highlightedCode.tokens.count, 1)) * 20 + 44
        return min(max(estimatedHeight, 100), 480)
    }

    private var statusSystemImage: String {
        if errorMessage != nil { return "xmark.circle.fill" }
        if isHighlighting { return "circle.dotted" }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if errorMessage != nil { return .red }
        if isHighlighting { return .secondary }
        return .green
    }

    private var statusText: String {
        if errorMessage != nil {
            return "The last render failed"
        }
        if isHighlighting {
            return "Highlighting locally…"
        }
        return renderSummary
            ?? "Highlighted locally — no JavaScript runtime or web view"
    }

    private func badge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func languageName(for id: String) -> String {
        Self.demos.first { $0.id == id }?.title ?? id
    }

    private func themeName(for id: String) -> String {
        Self.themes.first { $0.id == id }?.displayName ?? id
    }

    private func submitCode() {
        highlightRequest = HighlightRequest(
            id: nextRequestID,
            code: codeInput,
            language: selectedLanguage,
            theme: selectedTheme
        )
        nextRequestID += 1
    }

    @MainActor
    private func highlight(_ request: HighlightRequest) async {
        highlightedCode = nil
        errorMessage = nil
        renderSummary = nil
        isHighlighting = true
        let startedAt = Date()

        do {
            // Let AppKit close the picker menu before starting synchronous
            // grammar preparation, then serialize work through one reusable
            // highlighter. Superseded queued selections observe cancellation
            // before doing any expensive work.
            await Task.yield()
            let rendered = try await syntaxHighlighter.highlight(
                request.code,
                language: request.language,
                theme: request.theme
            )

            guard !Task.isCancelled,
                  highlightRequest.id == request.id
            else { return }
            highlightedCode = rendered.result
            isHighlighting = false

            let elapsed = Date().timeIntervalSince(startedAt)
            renderSummary = "Highlighted \(rendered.result.tokens.count.formatted()) lines · "
                + "\(rendered.tokenCount.formatted()) tokens · "
                + "\(rendered.utf16Count.formatted()) UTF-16 units in "
                + String(format: "%.2f s", elapsed)
        } catch {
            guard !Task.isCancelled,
                  highlightRequest.id == request.id
            else { return }
            isHighlighting = false
            errorMessage = String(describing: error)
        }
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}

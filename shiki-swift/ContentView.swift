import Shiki
import ShikiUI
import SwiftUI

private actor DemoSyntaxHighlighter {
    private var highlighter: ShikiHighlighter?

    func highlight(
        _ code: String,
        language: String,
        theme: String
    ) throws -> TokensResult {
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
        return result
    }
}

struct ContentView: View {
    @State private var highlightedCode: TokensResult?
    @State private var errorMessage: String?
    @State private var selectedLanguage = "swift"
    @State private var selectedTheme = "github-dark"
    @State private var syntaxHighlighter = DemoSyntaxHighlighter()

    private struct DemoLanguage: Identifiable, Sendable {
        let id: String
        let title: String
        let code: String
    }

    private struct HighlightSelection: Equatable {
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

                Group {
                    if let highlightedCode {
                        ShikiCodeView(
                            result: highlightedCode,
                            font: .system(size: 15, design: .monospaced),
                            contentPadding: 22
                        )
                    } else if let errorMessage {
                        ContentUnavailableView(
                            "Highlighting failed",
                            systemImage: "exclamationmark.triangle",
                            description: Text(errorMessage)
                        )
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Highlighting \(selectedDemo.title) with \(selectedThemeName)…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color.black.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                }

                HStack(spacing: 7) {
                    Image(systemName: highlightedCode == nil ? "circle.dotted" : "checkmark.circle.fill")
                        .foregroundStyle(highlightedCode == nil ? Color.secondary : Color.green)
                    Text(highlightedCode == nil
                         ? "Preparing the native highlighter"
                         : "Highlighted locally — no JavaScript runtime or web view")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(34)
            .frame(maxWidth: 920)
        }
        .frame(minWidth: 720, minHeight: 560)
        .task(id: highlightSelection) {
            await highlightSample(theme: selectedTheme, demo: selectedDemo)
        }
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
        .accessibilityLabel("Demo language")
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
        Self.themes.first { $0.id == selectedTheme }?.displayName
            ?? selectedTheme
    }

    private var selectedDemo: DemoLanguage {
        Self.demos.first { $0.id == selectedLanguage } ?? Self.demos[0]
    }

    private var highlightSelection: HighlightSelection {
        HighlightSelection(language: selectedLanguage, theme: selectedTheme)
    }

    private func badge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: Capsule())
    }

    @MainActor
    private func highlightSample(theme: String, demo: DemoLanguage) async {
        highlightedCode = nil
        errorMessage = nil

        do {
            // Let AppKit close the picker menu before starting synchronous
            // grammar preparation, then serialize work through one reusable
            // highlighter. Superseded queued selections observe cancellation
            // before doing any expensive work.
            await Task.yield()
            let result = try await syntaxHighlighter.highlight(
                demo.code,
                language: demo.id,
                theme: theme
            )

            guard !Task.isCancelled,
                  selectedTheme == theme,
                  selectedLanguage == demo.id
            else { return }
            highlightedCode = result
        } catch {
            guard !Task.isCancelled,
                  selectedTheme == theme,
                  selectedLanguage == demo.id
            else { return }
            errorMessage = String(describing: error)
        }
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}

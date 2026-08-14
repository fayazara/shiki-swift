import Shiki
import XCTest

final class DetachedTaskHighlightingTests: XCTestCase {
    func testTypeScriptCompilesFromDetachedTask() async throws {
        let result = try await Task.detached(priority: .userInitiated) {
            let highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
            return try highlighter.codeToTokens(
                """
                type User = { name: string; active: boolean }

                const greet = ({ name, active }: User) => {
                  const emoji = active ? "👋" : "💤"
                  return `Hello, ${name} ${emoji}`
                }

                console.log(greet({ name: "Shiki", active: true }))
                """,
                language: "typescript",
                theme: "github-dark"
            )
        }.value

        XCTAssertEqual(result.tokens.count, 8)
        XCTAssertEqual(
            result.tokens.map { $0.map(\.content).joined() }.joined(separator: "\n"),
            """
            type User = { name: string; active: boolean }

            const greet = ({ name, active }: User) => {
              const emoji = active ? "👋" : "💤"
              return `Hello, ${name} ${emoji}`
            }

            console.log(greet({ name: "Shiki", active: true }))
            """
        )
    }

    func testTypeScriptAndJavaScriptCompileConcurrently() async throws {
        let languages = ["typescript", "javascript"]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for language in languages {
                group.addTask {
                    let highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
                    _ = try highlighter.codeToTokens(
                        "const value = `Hello, ${language}`",
                        language: language,
                        theme: "github-dark"
                    )
                }
            }
            try await group.waitForAll()
        }
    }
}

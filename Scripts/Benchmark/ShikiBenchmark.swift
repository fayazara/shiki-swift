import Foundation
import Shiki
import ShikiUI

/// Preparation timings only: excludes text layout, drawing, and scrolling.
///
/// Reports cold start (a fresh highlighter: asset decode + grammar/scanner
/// compile + first highlight) and warm medians/p95 over repeated runs for a
/// mix of inputs, including a minified single-line file and Markdown with
/// lazily embedded fences.
@main
struct ShikiBenchmark {
    static let runs = 10

    static func measure<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try operation()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    static func stats(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return String(format: "median=%8.2f p95=%8.2f", median, p95)
    }

    struct Case {
        let name: String
        let language: String
        let code: String
    }

    static func cases() -> [Case] {
        let swift = """
        struct Greeting {
            let name: String
            func greet() -> String {
                // A small Unicode example
                return "Hello, \\(name) 👋"
            }
        }
        """
        let tsx = """
        import { useState } from 'react'
        export function Counter({ start = 0 }: { start?: number }) {
          const [count, setCount] = useState<number>(start)
          return <button onClick={() => setCount(c => c + 1)}>Count: {count}</button>
        }
        """
        let markdown = """
        # Title

        Some *prose* with `code`.

        ```swift
        let value = [1, 2, 3].map { $0 * 2 }
        ```

        ```python
        def greet(name: str) -> str:
            return f"Hello {name}"
        ```

        ```ts
        const answer: number = 42
        ```
        """
        var json = "[\n"
        for index in 0..<4_000 {
            json += "  {\"id\": \(index), \"name\": \"item \(index)\", \"tags\": [\"a\", \"b\"], \"ok\": true},\n"
        }
        json += "  {}\n]"
        let minified = Array(
            repeating: "function f(a,b){return a.map(function(x){return x*b+\"s\"})}var q={k:1,v:[1,2,3]};",
            count: 2_500
        ).joined()

        return [
            Case(name: "swift x1429 (10k lines)", language: "swift",
                 code: Array(repeating: swift, count: 1_429).joined(separator: "\n")),
            Case(name: "tsx x1000 (5k lines)", language: "tsx",
                 code: Array(repeating: tsx, count: 1_000).joined(separator: "\n")),
            Case(name: "markdown+fences x300", language: "markdown",
                 code: Array(repeating: markdown, count: 300).joined(separator: "\n")),
            Case(name: "json 4k lines", language: "json", code: json),
            Case(name: "minified js 1 line (\(minified.utf16.count / 1024)k)", language: "javascript",
                 code: minified),
        ]
    }

    static func main() throws {
        print("Release preparation timings in milliseconds; \(runs) warm runs each")

        // `shiki-benchmark <substring>` limits the run to matching cases.
        let filter = CommandLine.arguments.dropFirst().first
        let all = cases().filter { filter == nil || $0.name.contains(filter!) }
        for item in all {
            try autoreleasepool {
                let (_, coldMS) = try measure {
                    let highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
                    return try highlighter.codeToTokens(item.code, language: item.language)
                }
                print(String(format: "%-34@ cold (new highlighter) %8.2f", item.name as NSString, coldMS))
            }
        }

        let highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
        for item in all {
            _ = try highlighter.codeToTokens(item.code, language: item.language)
            var highlight: [Double] = []
            var multi: [Double] = []
            var attributes: [Double] = []
            for _ in 0..<runs {
                try autoreleasepool {
                    let (result, highlightMS) = try measure {
                        try highlighter.codeToTokens(item.code, language: item.language)
                    }
                    highlight.append(highlightMS)
                    let (_, multiMS) = try measure {
                        try highlighter.codeToTokensWithThemes(
                            item.code,
                            language: item.language,
                            themes: [
                                .init(colorName: "light", themeName: "github-light"),
                                .init(colorName: "dark", themeName: "github-dark"),
                            ]
                        )
                    }
                    multi.append(multiMS)
                    let (_, attributesMS) = measure { result.attributedString() }
                    attributes.append(attributesMS)
                }
            }
            print("\(item.name.padding(toLength: 34, withPad: " ", startingAt: 0)) highlight \(stats(highlight))  2-theme \(stats(multi))  attributed \(stats(attributes))")
        }
    }
}

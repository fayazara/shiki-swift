import Foundation
import Shiki
import ShikiUI

/// Preparation timings only: excludes text layout, drawing, and scrolling.
@main
struct ShikiBenchmark {
    static func measure<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try operation()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    static func main() throws {
        let highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
        let sample = """
        struct Greeting {
            let name: String
            func greet() -> String {
                // A small Unicode example
                return "Hello, \\(name) 👋"
            }
        }
        """
        let warmup = try highlighter.codeToTokens(sample, language: "swift")
        _ = warmup.attributedString()
        print("Warm Swift / github-dark; milliseconds; 3 runs per size")
        for repetitions in [143, 1_429] {
            let code = Array(repeating: sample, count: repetitions).joined(separator: "\n")
            for run in 1...3 {
                try autoreleasepool {
                    let (result, highlightMS) = try measure {
                        try highlighter.codeToTokens(code, language: "swift")
                    }
                    let (attributed, renderMS) = measure { result.attributedString() }
                    let (visible, visibleMS) = measure {
                        ShikiAttributedStringRenderer().render(result, lines: 0..<60)
                    }
                    print(String(format: "lines=%d run=%d highlight=%.2f attributes=%.2f 60-line-attributes=%.2f chars=%d/%d",
                                 result.tokens.count, run, highlightMS, renderMS, visibleMS,
                                 attributed.characters.count, visible.characters.count))
                }
            }
        }
    }
}

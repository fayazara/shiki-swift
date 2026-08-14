import Shiki
import XCTest

final class EmbeddedLanguageDetectionTests: XCTestCase {
    func testMatchesShikiDetectionPatternsAndFirstSeenOrder() {
        let code = """
        <template lang="Pug"></template>
        <script lang=' ts '></script>
        <component :lang="javascript"></component>
        ```Python
        print("hi")
        ```
        ~~~js
        console.log("hi")
        ~~~
        \\begin{equation}\\end{equation}\\begin{align}\\end{align}
        <script type="text/javascript"></script>
        <SCRIPT TYPE="application/typescript"></SCRIPT>
        """

        XCTAssertEqual(guessEmbeddedLanguages(code), [
            "pug",
            "ts",
            "javascript",
            "python",
            "js",
            "equation",
            "align",
            "typescript",
        ])
    }

    func testDetectsFrontmatterOnlyAtDocumentStart() {
        XCTAssertEqual(
            guessEmbeddedLanguages("  \n---\r\nfoo: bar\r\n---\r\n# Title"),
            ["yaml"]
        )
        XCTAssertEqual(
            guessEmbeddedLanguages("# Title\n---\nfoo: bar\n---"),
            []
        )
    }

    func testDeduplicatesExactIdentifiersBeforeAliasResolution() {
        XCTAssertEqual(
            guessEmbeddedLanguages("```js\n```\n```js\n```\n```javascript\n```"),
            ["js", "javascript"]
        )
    }

    func testUnknownDetectedLanguageIsIgnoredByBundledHighlighter() throws {
        let highlighter = try ShikiHighlighter()
        let result = try highlighter.codeToTokens(
            "```not-a-real-language\nhello\n```",
            language: "markdown"
        )

        XCTAssertEqual(result.tokens.count, 3)
        XCTAssertEqual(result.tokens[1].map(\.content).joined(), "hello")
    }
}

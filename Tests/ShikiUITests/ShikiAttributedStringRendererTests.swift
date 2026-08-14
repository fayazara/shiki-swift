#if canImport(SwiftUI)
import ShikiCore
import SwiftUI
import XCTest
@testable import ShikiUI

final class ShikiAttributedStringRendererTests: XCTestCase {
    func testRendersTokensAndPreservesEmptyAndTrailingLines() {
        let result = TokensResult(
            tokens: [
                [
                    .init(
                        content: "let",
                        offset: 0,
                        color: "#f00",
                        bgColor: "#0008",
                        fontStyle: [.bold, .italic]
                    ),
                    .init(content: " value", offset: 3),
                ],
                [],
                [.init(content: "done", offset: 11)],
                [],
            ],
            fg: "#123456",
            bg: "#ffffff",
            themeName: "test"
        )

        let rendered = result.attributedString()
        XCTAssertEqual(String(rendered.characters), "let value\n\ndone\n")
        XCTAssertEqual(ShikiUI.attributedString(from: result), rendered)
    }

    func testAppliesForegroundBackgroundBoldAndItalic() throws {
        let baseFont = Font.system(size: 15, design: .monospaced)
        let token = ThemedToken(
            content: "styled",
            offset: 0,
            color: "#abc",
            bgColor: "#1234",
            fontStyle: [.bold, .italic]
        )
        let rendered = ShikiAttributedStringRenderer(font: baseFont).render(
            TokensResult(tokens: [[token]], fg: "#000000")
        )
        let run = try XCTUnwrap(rendered.runs.first)

        XCTAssertEqual(run.font, baseFont.bold().italic())
        XCTAssertEqual(run.foregroundColor, ShikiRGBAColor(hex: "#abc")?.swiftUIColor)
        XCTAssertEqual(run.backgroundColor, ShikiRGBAColor(hex: "#1234")?.swiftUIColor)
        XCTAssertNil(run.underlineStyle)
        XCTAssertNil(run.strikethroughStyle)
    }

    func testAppliesUnderlineAndStrikethroughIndependently() throws {
        let result = TokensResult(tokens: [[
            .init(content: "under", offset: 0, fontStyle: .underline),
            .init(content: "strike", offset: 5, fontStyle: .strikethrough),
        ]])
        let rendered = ShikiAttributedStringRenderer().render(result)
        let runs = Array(rendered.runs)
        XCTAssertEqual(runs.count, 2)

        XCTAssertEqual(String(rendered[runs[0].range].characters), "under")
        XCTAssertEqual(runs[0].underlineStyle, .single)
        XCTAssertNil(runs[0].strikethroughStyle)

        XCTAssertEqual(String(rendered[runs[1].range].characters), "strike")
        XCTAssertNil(runs[1].underlineStyle)
        XCTAssertEqual(runs[1].strikethroughStyle, .single)
    }

    func testInvalidTokenColorFallsBackToResultForeground() throws {
        let result = TokensResult(
            tokens: [[
                .init(
                    content: "safe",
                    offset: 0,
                    color: "not-a-color",
                    bgColor: "also-invalid",
                    fontStyle: .notSet
                ),
            ]],
            fg: "#0f08"
        )
        let baseFont = Font.system(.body, design: .monospaced)
        let rendered = ShikiAttributedStringRenderer(font: baseFont).render(result)
        let run = try XCTUnwrap(rendered.runs.first)

        XCTAssertEqual(run.font, baseFont)
        XCTAssertEqual(run.foregroundColor, ShikiRGBAColor(hex: "#0f08")?.swiftUIColor)
        XCTAssertNil(run.backgroundColor)
        XCTAssertNil(run.underlineStyle)
        XCTAssertNil(run.strikethroughStyle)
    }

    func testInvalidColorsCanRemainUnspecified() throws {
        let rendered = ShikiAttributedStringRenderer().render(
            TokensResult(
                tokens: [[.init(content: "plain", offset: 0, color: "var(--fg)")]],
                fg: "still-invalid"
            )
        )
        let run = try XCTUnwrap(rendered.runs.first)
        XCTAssertNil(run.foregroundColor)
        XCTAssertNil(run.backgroundColor)
    }

    @MainActor
    func testCodeViewRetainsConfiguration() {
        let result = TokensResult(tokens: [[.init(content: "code", offset: 0)]])
        let font = Font.system(size: 13, design: .monospaced)
        let view = ShikiCodeView(result: result, font: font, contentPadding: 12)

        XCTAssertEqual(view.result, result)
        XCTAssertEqual(view.font, font)
        XCTAssertEqual(view.contentPadding, 12)
    }
}
#endif

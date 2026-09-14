#if canImport(AppKit)
import AppKit
import ShikiCore
import SwiftUI
import XCTest
@testable import ShikiUI

final class ShikiTextDocumentTests: XCTestCase {
    @MainActor
    func testStylesRequestedParagraphsWithoutMaterializingOtherRows() throws {
        let row: [ThemedToken] = [
            .init(content: "let ", offset: 0, color: "#f00", fontStyle: .bold),
            .init(content: "🙂 = 1", offset: 4, color: "#00f", bgColor: "#1234", fontStyle: [.underline, .strikethrough]),
        ]
        let document = ShikiTextDocument(
            result: TokensResult(tokens: Array(repeating: row, count: 10_000), fg: "#fff"),
            font: .monospacedSystemFont(ofSize: 15, weight: .regular)
        )
        XCTAssertEqual(document.renderedParagraphCount, 0)
        let range = document.rowRanges[5_000]
        let paragraph = try XCTUnwrap(document.paragraph(in: range))
        XCTAssertEqual(paragraph.string, "let 🙂 = 1\n")
        XCTAssertEqual(paragraph.length, range.length)
        let font = try XCTUnwrap(paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(paragraph.attribute(.underlineStyle, at: 4, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual(document.renderedParagraphCount, 1)
        XCTAssertTrue(document.paragraph(in: range) === paragraph)
        XCTAssertEqual(document.renderedParagraphCount, 1)
        for row in 0..<1_000 { _ = document.paragraph(in: document.rowRanges[row]) }
        XCTAssertLessThanOrEqual(document.cachedParagraphCount, 256)
        XCTAssertLessThanOrEqual(document.cachedUTF16Count, 262_144)
    }

    @MainActor
    func testParagraphRangesUseDisplayOffsetsAndHandleSeparatorsInsideTokens() throws {
        let document = ShikiTextDocument(result: TokensResult(tokens: [
            [.init(content: "a\rb🙂", offset: 0, color: "#f00")],
            [],
            [.init(content: "end", offset: 100)],
            [],
        ]), font: .monospacedSystemFont(ofSize: 15, weight: .regular))
        XCTAssertEqual(document.source as String, "a\rb🙂\n\nend\n")
        let range = NSRange(location: 2, length: 4)
        let paragraph = try XCTUnwrap(document.paragraph(in: range))
        XCTAssertEqual(paragraph.string, "b🙂\n")
        XCTAssertEqual(paragraph.length, 4)
        XCTAssertEqual(document.paragraph(in: NSRange(location: document.source.length, length: 0))?.length, 0)
        XCTAssertNil(document.paragraph(in: NSRange(location: document.source.length, length: 1)))
    }

    func testSwiftRendererCanRenderOnlyRequestedRows() {
        let result = TokensResult(tokens: [
            [.init(content: "before", offset: 0)], [],
            [.init(content: "🙂", offset: 8, color: "#f00")], [],
        ])
        let renderer = ShikiAttributedStringRenderer()
        XCTAssertEqual(String(renderer.render(result, lines: 1..<4).characters), "\n🙂\n")
        XCTAssertEqual(String(renderer.render(result, lines: 8..<10).characters), "")
    }

    @MainActor
    func testMountedViewportCachesStayBoundedAcrossJumpsResizeAndReplacement() throws {
        _ = NSApplication.shared
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let result = TokensResult(tokens: (0..<10_000).map { index in
            [.init(content: "line \(index) 🙂", offset: 0, color: "#ff0000", fontStyle: .bold)]
        }, bg: "#222222")
        let view = ShikiTextViewport(result: result, renderID: 1, font: font, padding: 16)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let document = try XCTUnwrap(coordinator.document)
        XCTAssertEqual(document.renderedParagraphCount, 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let layout = try XCTUnwrap(text.textLayoutManager)
        scroll.layoutSubtreeIfNeeded()
        layout.textViewportLayoutController.layoutViewport()
        XCTAssertGreaterThan(document.renderedParagraphCount, 0)
        XCTAssertLessThan(document.renderedParagraphCount, 200)

        for row in [4_000, 9_900, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(row) * document.lineHeight))
            scroll.reflectScrolledClipView(scroll.contentView)
            layout.textViewportLayoutController.layoutViewport()
            // Distant anchor estimation may request intervening fragments.
            // Those must receive styles too, but our retained cache stays bounded.
            XCTAssertLessThanOrEqual(document.cachedParagraphCount, 256)
            XCTAssertLessThanOrEqual(document.cachedUTF16Count, 262_144)
            let range = try XCTUnwrap(layout.textViewportLayoutController.viewportRange)
            let content = try XCTUnwrap(layout.textContentManager)
            let offset = content.offset(from: content.documentRange.location, to: range.location)
            let expected = document.visualLineOffsets[max(0, row - 1)]
            XCTAssertLessThanOrEqual(abs(offset - expected), 100)
            var hasRed = false
            layout.enumerateRenderingAttributes(from: range.location, reverse: false) { _, attributes, _ in
                hasRed = (attributes[.foregroundColor] as? NSColor) == ShikiRGBAColor(hex: "#f00")?.appKitColor
                return false
            }
            XCTAssertTrue(hasRed)
        }

        text.setSelectedRange(NSRange(location: 0, length: 6))
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), "line 0")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        let origin = scroll.contentView.bounds.origin
        view.updateScrollView(scroll, coordinator: coordinator)
        XCTAssertTrue(coordinator.document === document)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 6))
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        scroll.setFrameSize(NSSize(width: 450, height: 700))
        scroll.layoutSubtreeIfNeeded()
        layout.textViewportLayoutController.layoutViewport()
        XCTAssertNotNil(text.textLayoutManager)
        XCTAssertLessThanOrEqual(document.cachedParagraphCount, 256)

        let replacement = ShikiTextViewport(result: TokensResult(tokens: [[.init(content: "new", offset: 0)]]),
                                            renderID: 2, font: font, padding: 20)
        replacement.updateScrollView(scroll, coordinator: coordinator)
        layout.textViewportLayoutController.layoutViewport()
        XCTAssertEqual(text.string, "new")
        XCTAssertEqual(scroll.contentView.bounds.origin, .zero)
        XCTAssertFalse(coordinator.document === document)
        let changedFont = ShikiTextViewport(result: replacement.result, renderID: 2,
                                            font: .monospacedSystemFont(ofSize: 20, weight: .regular), padding: 20)
        let previous = coordinator.document
        changedFont.updateScrollView(scroll, coordinator: coordinator)
        XCTAssertFalse(coordinator.document === previous)
        XCTAssertEqual(coordinator.document?.font.pointSize, 20)
    }

    @MainActor
    func testNativePlainTextCopy() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        guard pasteboard.types?.contains(.string) == true else {
            throw XCTSkip("The macOS pasteboard service is unavailable in this environment.")
        }
        let view = ShikiTextViewport(result: TokensResult(tokens: [[.init(content: "copy 🙂", offset: 0)]]),
                                     renderID: 0, font: .monospacedSystemFont(ofSize: 15, weight: .regular), padding: 8)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        text.setSelectedRange(NSRange(location: 0, length: 7))
        XCTAssertTrue(text.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "copy 🙂")
    }

    @MainActor
    func testRapidScrollReversalsKeepEveryVisibleLineHighlighted() throws {
        _ = NSApplication.shared
        let result = TokensResult(tokens: (0..<588).map { index in
            [.init(content: "let", offset: 0, color: "#f00"),
             .init(content: " value\(index) = 🙂", offset: 3, color: "#00f")]
        }, fg: "#ffffff", bg: "#222222")
        let view = ShikiTextViewport(result: result, renderID: 1,
                                     font: .monospacedSystemFont(ofSize: 15, weight: .regular), padding: 22)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let document = try XCTUnwrap(coordinator.document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let layout = try XCTUnwrap(text.textLayoutManager)
        scroll.layoutSubtreeIfNeeded()

        func checkVisibleLines(_ label: String) throws {
            layout.textViewportLayoutController.layoutViewport()
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            var redRows: [Int] = []
            var blueRows: [Int] = []
            for y in 0..<bitmap.pixelsHigh {
                var hasRed = false
                var hasBlue = false
                for x in 0..<min(bitmap.pixelsWide, 250) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    hasRed = hasRed || (color.redComponent > 0.5 && color.greenComponent < 0.3 && color.blueComponent < 0.3)
                    hasBlue = hasBlue || (color.blueComponent > 0.5 && color.greenComponent < 0.3 && color.redComponent < 0.3)
                }
                if hasRed { redRows.append(y) }
                if hasBlue { blueRows.append(y) }
            }
            func bands(_ rows: [Int]) -> Int {
                rows.enumerated().reduce(0) { count, item in
                    count + (item.offset == 0 || item.element - rows[item.offset - 1] > 2 ? 1 : 0)
                }
            }
            let expectedLines = Int((scroll.contentView.bounds.height - 44) / document.lineHeight) - 1
            XCTAssertGreaterThanOrEqual(bands(redRows), expectedLines, "Missing keyword colors: \(label)")
            XCTAssertGreaterThanOrEqual(bands(blueRows), expectedLines, "Missing value colors: \(label)")

        }

        try checkVisibleLines("initial")
        // Reverse direction repeatedly before TextKit gets a chance to draw.
        for burst in [[200, 450, 120, 550, 0], [580, 20, 420, 240, 0], [350, 100, 500], [100, 0]] {
            for row in burst {
                let point = NSPoint(x: 0, y: CGFloat(row) * document.lineHeight)
                scroll.contentView.scroll(to: point)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            try checkVisibleLines("after burst \(burst)")
        }
    }

}
#endif

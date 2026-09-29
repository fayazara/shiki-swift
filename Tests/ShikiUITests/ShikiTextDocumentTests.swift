#if os(macOS)
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
        XCTAssertLessThan(document.renderedParagraphCount, 100)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        let text = try XCTUnwrap(scroll.documentView as? ShikiCodeDocumentView)
        scroll.layoutSubtreeIfNeeded()
        text.layoutVisibleText()
        XCTAssertGreaterThan(document.renderedParagraphCount, 0)
        XCTAssertLessThan(document.renderedParagraphCount, 200)

        for row in [4_000, 9_900, 0] {
            let renderedBefore = document.renderedParagraphCount
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(row) * document.lineHeight))
            scroll.reflectScrolledClipView(scroll.contentView)
            text.layoutVisibleText()
            XCTAssertLessThanOrEqual(document.cachedParagraphCount, 256)
            XCTAssertLessThanOrEqual(document.cachedUTF16Count, 262_144)
            XCTAssertLessThanOrEqual(text.loadedLines.count, Int(ceil(scroll.contentSize.height / document.lineHeight)) + 34)
            XCTAssertTrue(text.loadedLines.contains(row))
            XCTAssertLessThan(document.renderedParagraphCount - renderedBefore, 100, "A jump must never style intervening lines")
            XCTAssertEqual(text.textView.string, document.source.substring(with: text.loadedRange))
            let color = text.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            XCTAssertEqual(color, ShikiRGBAColor(hex: "#f00")?.appKitColor)
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
        text.layoutVisibleText()
        XCTAssertNotNil(text.textView.textLayoutManager)
        XCTAssertLessThanOrEqual(document.cachedParagraphCount, 256)

        let replacement = ShikiTextViewport(result: TokensResult(tokens: [[.init(content: "new", offset: 0)]]),
                                            renderID: 2, font: font, padding: 20)
        replacement.updateScrollView(scroll, coordinator: coordinator)
        text.layoutVisibleText()
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
        let text = try XCTUnwrap(scroll.documentView as? ShikiCodeDocumentView)
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
        let text = try XCTUnwrap(scroll.documentView as? ShikiCodeDocumentView)
        scroll.layoutSubtreeIfNeeded()

        func checkVisibleLines(_ label: String) throws {
            text.layoutVisibleText()
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

    @MainActor
    func testGlobalSelectionKeyboardMouseAndAccessibilityAcrossWindows() throws {
        _ = NSApplication.shared
        let result = TokensResult(tokens: (0..<2_000).map { index in
            [.init(content: "line \(index) 🙂 value", offset: 0, color: "#f00")]
        })
        let view = ShikiTextViewport(result: result, renderID: 1,
                                     font: .monospacedSystemFont(ofSize: 15, weight: .regular), padding: 16)
        let scroll = view.makeScrollView(coordinator: view.makeCoordinator())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        let text = try XCTUnwrap(scroll.documentView as? ShikiCodeDocumentView)
        let document = try XCTUnwrap(text.document)
        scroll.layoutSubtreeIfNeeded()
        func jump(_ row: Int) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(row) * document.lineHeight))
            scroll.reflectScrolledClipView(scroll.contentView)
            text.layoutVisibleText()
        }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            text.textView.keyDown(with: event)
        }
        text.textView.selectAll(nil)
        jump(1_500)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: document.source.length))
        XCTAssertEqual(text.accessibilitySelectedText(), document.source as String)
        XCTAssertEqual(text.accessibilityNumberOfCharacters(), document.source.length)
        XCTAssertEqual(text.textView.selectedRange().length, text.loadedRange.length)
        XCTAssertLessThan(text.textView.string.utf16.count, document.source.length / 10)

        let start = document.visualLineOffsets[1_500]
        let selection = NSRange(location: start + 10, length: 2) // The emoji, two UTF-16 units.
        XCTAssertEqual(document.source.substring(with: selection), "🙂")
        text.setSelectedRange(selection)
        try key(124) // Collapse to the right, then move over the whole emoji to the left.
        XCTAssertEqual(text.selectedRange(), NSRange(location: start + 12, length: 0))
        try key(123, [.shift])
        XCTAssertEqual(text.selectedRange(), selection)
        jump(0)
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertEqual(text.accessibilitySelectedText(), "🙂")
        try key(126, [.command, .shift]) // Extend selection to the start of the full document.
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: start + 12))
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        try key(125, [.command])
        XCTAssertEqual(text.selectedRange(), NSRange(location: document.source.length, length: 0))
        XCTAssertTrue(text.loadedLines.contains(1_999))

        // A shift-click after replacing the window must extend the original global anchor.
        text.setSelectedRange(NSRange(location: 0, length: 0))
        jump(1_000)
        let point = text.convert(NSPoint(x: 16, y: 16 + CGFloat(1_000) * document.lineHeight + 5), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.shift],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: true)
        text.textView.mouseDown(with: try mouse(.leftMouseDown))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: document.visualLineOffsets[1_000]))
        XCTAssertEqual(text.accessibilityString(for: NSRange(location: start + 10, length: 2)), "🙂")
        text.setAccessibilitySelectedTextRange(selection)
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertTrue(text.loadedLines.contains(1_500))
    }

    @MainActor
    func testEmptyDocumentAndSeparatorsRemainBounded() throws {
        _ = NSApplication.shared
        for result in [TokensResult(tokens: []), TokensResult(tokens: [[.init(content: "a\rb\u{2028}🙂\n", offset: 0)]])] {
            let view = ShikiTextViewport(result: result, renderID: 1,
                font: .monospacedSystemFont(ofSize: 15, weight: .regular), padding: 8)
            let scroll = view.makeScrollView(coordinator: view.makeCoordinator())
            let text = try XCTUnwrap(scroll.documentView as? ShikiCodeDocumentView)
            text.layoutVisibleText()
            XCTAssertEqual(text.textView.string, text.string)
            text.selectAll(nil)
            XCTAssertEqual(text.accessibilitySelectedText(), text.string)
            XCTAssertEqual(text.loadedRange.length, text.string.utf16.count)
        }
    }

    @MainActor
    func testLongRowsClipInsteadOfWrappingOverTheNextRow() throws {
        _ = NSApplication.shared
        let long = String(repeating: "abcdefghij", count: 20_000) // 200k columns.
        let result = TokensResult(tokens: [[.init(content: long, offset: 0)], [.init(content: "next", offset: 0)]])
        let view = ShikiTextViewport(result: result, renderID: 1,
                                     font: .monospacedSystemFont(ofSize: 15, weight: .regular), padding: 8)
        let scroll = view.makeScrollView(coordinator: view.makeCoordinator())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(scroll.documentView as? ShikiCodeDocumentView)
        XCTAssertGreaterThan(text.frame.width, 1_000_000, "The full row must be reachable")
        XCTAssertLessThanOrEqual(text.frame.width, ShikiTextDocument.maximumWidth)
        let layout = try XCTUnwrap(text.textView.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var lines = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            lines += fragment.textLineFragments.filter { $0.characterRange.length > 0 }.count
            return true
        }
        XCTAssertEqual(lines, 2)
    }

    @MainActor
    func testTextViewPasteboardWritesUseTheFullDocumentSelection() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        guard pasteboard.types?.contains(.string) == true else {
            throw XCTSkip("The macOS pasteboard service is unavailable in this environment.")
        }
        let result = TokensResult(tokens: (0..<2_000).map { [.init(content: "row \($0)", offset: 0)] })
        let view = ShikiTextViewport(result: result, renderID: 1,
                                     font: .monospacedSystemFont(ofSize: 15, weight: .regular), padding: 8)
        let scroll = view.makeScrollView(coordinator: view.makeCoordinator())
        let text = try XCTUnwrap(scroll.documentView as? ShikiCodeDocumentView)
        text.layoutVisibleText()
        text.selectAll(nil)
        XCTAssertLessThan(text.textView.string.utf16.count, text.string.utf16.count)
        XCTAssertTrue(text.textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), text.string)
        XCTAssertEqual(text.textView.writablePasteboardTypes, [.string])
    }

    @MainActor
    func testLargeResultsBuildOffTheMainThreadAndIgnoreStaleBuilds() async throws {
        _ = NSApplication.shared
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let count = ShikiTextViewport.backgroundTokenThreshold + 1
        let large = TokensResult(tokens: (0..<count).map { [.init(content: "t\($0)", offset: 0)] })
        let view = ShikiTextViewport(result: large, renderID: 1, font: font, padding: 8)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        XCTAssertNil(coordinator.document, "Large documents must not be built synchronously")
        let build = try XCTUnwrap(coordinator.build)
        await build.value
        let document = try XCTUnwrap(coordinator.document)
        XCTAssertEqual(document.rowRanges.count, count)

        // A newer small result supersedes an in-flight large build.
        ShikiTextViewport(result: large, renderID: 2, font: font, padding: 8)
            .updateScrollView(scroll, coordinator: coordinator)
        let stale = try XCTUnwrap(coordinator.build)
        ShikiTextViewport(result: TokensResult(tokens: [[.init(content: "small", offset: 0)]]),
                          renderID: 3, font: font, padding: 8)
            .updateScrollView(scroll, coordinator: coordinator)
        await stale.value
        XCTAssertEqual(coordinator.document?.source, "small")
    }

}
#endif

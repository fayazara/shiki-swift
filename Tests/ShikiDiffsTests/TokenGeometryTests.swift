import AppKit
import CoreText
import Shiki
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct TokenGeometryTests {
    @Test @MainActor func visualClustersHandleBidiAndComposedCharacters() throws {
        let font = try #require(NSFont(name: "Helvetica", size: 20))
        func line(_ text: String) -> CTLine { CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])) }
        let plain = line("abc")
        let rects = TokenLineGeometry(plain).rects(for: .init(location: 1, length: 1), origin: .zero, height: 24)
        #expect(rects.count == 1)
        #expect(abs(rects[0].minX - CTLineGetOffsetForStringIndex(plain, 1, nil)) < 0.01)
        #expect(abs(rects[0].maxX - CTLineGetOffsetForStringIndex(plain, 2, nil)) < 0.01)
        let bidi = line("aאבb")
        let split = TokenLineGeometry(bidi).rects(for: .init(location: 0, length: 2), origin: .zero, height: 24)
        #expect(split.count == 2)
        #expect(split[0].maxX < split[1].minX)
        #expect(TokenLineGeometry(bidi).rects(for: .init(location: 0, length: 4), origin: .zero, height: 24).count == 1)
        let composed = TokenLineGeometry(line("e\u{301}😀"))
        #expect(composed.clusters.map(\.range) == [.init(location: 0, length: 2), .init(location: 2, length: 2)])
        #expect(composed.rects(for: .init(location: 1, length: 1), origin: .zero, height: 24) == composed.rects(for: .init(location: 0, length: 2), origin: .zero, height: 24))
    }
    @Test @MainActor func wrappedTokenGeometryIsVisibleAndRejectsStaleRevision() async throws {
        let text = String(repeating: "one two three four ", count: 20)
        let file = FileContents(name: "wrapped.txt", contents: text + "\n")
        let diff = try parseDiffFromFile(file, file)
        let tokens = [[ThemedToken(content: text, offset: 0)]]
        let document = HighlightedDiff(diff: diff, oldTokens: tokens, newTokens: tokens, foreground: "#ffffff", background: "#000000")
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 300, height: 260)); window.contentView = view
        var options = DiffRenderOptions(); options.diffStyle = .unified; options.overflow = .wrap; options.fontName = "Menlo"
        view.render(document, options: options)
        let plan = try await DiffWrapLayout.shared.layout(plan: DiffRenderPlan(diff: diff, options: options), diff: diff, width: view.scrollView.contentSize.width - 72, fontName: "Menlo", fontSize: 13)
        view.installRenderPlan(plan); view.layoutSubtreeIfNeeded()
        let canvas = try #require(view.scrollView.documentView)
        var received: DiffTokenClickEvent?
        view.interactionHandlers = .init(onTokenEnter: { received = $0 })
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(.init(x: 80, y: 10), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        canvas.mouseMoved(with: event)
        let token = try #require(received)
        let rects = token.visibleRects
        #expect(rects.count > 2 && rects.count <= 12)
        #expect(rects.contains { $0.contains(.init(x: 80, y: 10)) })
        #expect(rects.allSatisfy { canvas.visibleRect.contains($0) && $0.minX >= 60 })
        #expect(token.lineCharStart == 0 && token.lineCharEnd == text.utf16.count)
        let next = HighlightedDiff(diff: diff, oldTokens: tokens, newTokens: tokens, foreground: "#ffffff", background: "#000000")
        view.render(next, options: options)
        #expect(token.visibleRects.isEmpty)
    }
}

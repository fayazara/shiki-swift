import AppKit
import CoreText
import Shiki
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct TokenInteractionTests {
    @Test func highlightedTokensRetainOriginalUTF16BoundariesAndEmptyLines() async throws {
        let source = "let   greeting = \"😀e\u{301}\"\n\n\tprint(greeting)\n"
        let file = FileContents(name: "f.swift", contents: source)
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        #expect(document.diff.additionLines.count == 3)
        #expect(document.newTokens.count >= 3)
        for line in document.diff.additionLines.indices {
            let original = cleanLastNewline(document.diff.additionLines[line])
            let tokens = document.newTokens[line]
            #expect(tokens.map(\.content).joined().utf16.elementsEqual(original.utf16))
            let index = TokenInteractionIndex(contents: tokens.map(\.content), fallback: original)
            var offset = 0
            for token in tokens {
                let length = token.content.utf16.count
                defer { offset += length }
                guard length > 0 else { continue }
                let hit = try #require(index.token(at: offset, includeWhitespace: true))
                #expect(hit.lineCharStart == offset && hit.lineCharEnd == offset + length)
                #expect(hit.tokenText.utf16.elementsEqual(token.content.utf16))
                #expect(index.token(at: offset + length - 1, includeWhitespace: true) == hit)
            }
            #expect(index.token(at: original.utf16.count, includeWhitespace: true) == nil)
        }
        #expect(document.newTokens[1].allSatisfy { $0.content.isEmpty })
        #expect(LineSelection(side: .additions, startLine: 1, endLine: 3).text(in: document.diff).utf16.elementsEqual(source.utf16))
    }
    @Test func utf16WhitespaceAndOriginalTokenBoundaries() {
        let index = TokenInteractionIndex(contents: ["foo", "  ", "😀bar", "\u{FEFF}", "\u{0085}"], fallback: "")
        #expect(index.token(at: 0, includeWhitespace: false)?.tokenText == "foo")
        #expect(index.token(at: 2, includeWhitespace: false)?.lineCharStart == 0)
        #expect(index.token(at: 3, includeWhitespace: false) == nil)
        #expect(index.token(at: 4, includeWhitespace: true)?.tokenText == "  ")
        #expect(index.token(at: 6, includeWhitespace: false)?.lineCharStart == 5)
        #expect(index.token(at: 9, includeWhitespace: false)?.lineCharEnd == 10)
        #expect(index.token(at: 10, includeWhitespace: false) == nil)
        #expect(index.token(at: 11, includeWhitespace: false)?.tokenText == "\u{0085}")
        #expect(index.token(at: -1, includeWhitespace: true) == nil)
        #expect(index.token(at: 12, includeWhitespace: true) == nil)
        #expect(TokenInteractionIndex(contents: [], fallback: "plain").token(at: 1, includeWhitespace: false)?.tokenText == "plain")
        #expect(TokenInteractionIndex(contents: [], fallback: "").spans.isEmpty)
    }
    @Test func longLineLookup() {
        let index = TokenInteractionIndex(contents: Array(repeating: "word ", count: 20000), fallback: "")
        for position in stride(from: 0, to: 100000, by: 97) {
            #expect(index.token(at: position, includeWhitespace: false)?.lineCharStart == position / 5 * 5)
        }
    }
    @Test @MainActor func tokenClickPrecedesLineAndKeepsInlineTokenWhole() throws {
        let diff = try parseDiffFromFile(.init(name: "f.txt", contents: "foo  bar\n"), .init(name: "f.txt", contents: "foo  bar\n"))
        let tokens = [ThemedToken(content: "foo", offset: 0), ThemedToken(content: "  ", offset: 3), ThemedToken(content: "bar", offset: 5)]
        let document = HighlightedDiff(diff: diff, oldTokens: [tokens], newTokens: [tokens], oldSpans: [0: [.init(.init(location: 1, length: 1))]], foreground: "#ffffff", background: "#000000")
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = view
        view.render(document)
        let canvas = try #require(view.scrollView.documentView)
        var order: [String] = [], received: DiffTokenClickEvent?
        view.interactionHandlers = .init(onLineClick: { _ in order.append("line") }, onTokenClick: { received = $0; order.append("token:" + $0.tokenText) })
        let advance = ("M" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
        func click(_ x: CGFloat) {
            let point = canvas.convert(.init(x: x, y: 10), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
            }
        }
        click(60 + advance)
        #expect(order == ["token:foo", "line"])
        #expect(received?.lineCharStart == 0 && received?.lineCharEnd == 3 && received?.side == .deletions)
        order = []; click(60 + advance * 4)
        #expect(order == ["line"])
        view.interactionHandlers.enableTokenInteractionsOnWhitespace = true
        order = []; click(60 + advance * 4)
        #expect(order == ["token:  ", "line"])
        order = []; click(10)
        #expect(order == ["line"])
        order = []; click(350)
        #expect(order == ["line"])
    }
    @Test @MainActor func tokenHoverPrecedesLineTransitionsAndSkipsWhitespace() throws {
        let contents = "foo  bar\nbaz\n"
        let diff = try parseDiffFromFile(.init(name: "f.txt", contents: contents), .init(name: "f.txt", contents: contents))
        let tokens = [[ThemedToken(content: "foo", offset: 0), ThemedToken(content: "  ", offset: 3), ThemedToken(content: "bar", offset: 5)], [ThemedToken(content: "baz", offset: 9)]]
        let document = HighlightedDiff(diff: diff, oldTokens: tokens, newTokens: tokens, foreground: "#ffffff", background: "#000000")
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = view
        view.render(document)
        let canvas = try #require(view.scrollView.documentView)
        var events: [String] = []
        view.interactionHandlers = .init(onLineEnter: { events.append("line-enter:\($0.lineNumber)") }, onLineLeave: { events.append("line-leave:\($0.lineNumber)") },
                                         onTokenEnter: { events.append("token-enter:" + $0.tokenText) }, onTokenLeave: { events.append("token-leave:" + $0.tokenText) })
        let advance = ("M" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
        func move(_ column: CGFloat, y: CGFloat = 10) {
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(.init(x: 60 + advance * column, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
            canvas.mouseMoved(with: event)
        }
        move(1); move(2)
        #expect(events == ["token-enter:foo", "line-enter:1"])
        move(4)
        #expect(events.last == "token-leave:foo")
        move(6)
        #expect(events.last == "token-enter:bar")
        move(1, y: 30)
        #expect(events.suffix(4) == ["token-leave:bar", "token-enter:baz", "line-leave:1", "line-enter:2"])
        view.interactionHandlers.enableTokenInteractionsOnWhitespace = true
        move(4)
        #expect(events.suffix(4) == ["token-leave:baz", "token-enter:  ", "line-leave:2", "line-enter:1"])
        view.interactionHandlers = .init(onTokenEnter: { events.append("only:" + $0.tokenText) })
        #expect(canvas.trackingAreas.count == 1)
        move(1)
        #expect(events.last == "only:foo")
        view.interactionHandlers = .init()
        #expect(canvas.trackingAreas.isEmpty)
    }

    @Test @MainActor func repeatedHoverReusesOversizedLineIndexAndSource() throws {
        let text = String(repeating: "a", count: 1_048_576)
        let file = FileContents(name: "large.txt", contents: text + "\n")
        let diff = try parseDiffFromFile(file, file)
        let tokens = [[ThemedToken(content: text, offset: 0)]]
        let document = HighlightedDiff(diff: diff, oldTokens: tokens, newTokens: tokens, foreground: "#ffffff", background: "#000000")
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = view
        var options = DiffRenderOptions(); options.fontName = "Menlo"
        view.render(document, options: options)
        let canvas = try #require(view.scrollView.documentView)
        var entered = 0
        view.interactionHandlers = .init(onTokenEnter: { _ in entered += 1 })
        func move(_ x: CGFloat) {
            canvas.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(.init(x: x, y: 10), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!)
        }
        move(80)
        let start = ContinuousClock.now
        for index in 0..<100 { move(80 + CGFloat(index % 50)) }
        print("100 repeated token hovers on a 1 MiB line: \(start.duration(to: .now))")
        #expect(entered == 1)
        #expect(view.metrics.tokenIndexesBuilt == 1)
        #expect(view.metrics.pointerSourcesBuilt == 1)
        #expect(view.metrics.oversizedTokenIndexUTF16Units == text.utf16.count)
        let small = FileContents(name: "small.txt", contents: "small\n")
        let next = HighlightedDiff(diff: try parseDiffFromFile(small, small), oldTokens: [], newTokens: [], foreground: "#ffffff", background: "#000000")
        view.render(next, options: options); move(80)
        #expect(view.metrics.tokenIndexesBuilt == 2)
        #expect(view.metrics.pointerSourcesBuilt == 2)
        #expect(view.metrics.oversizedTokenIndexUTF16Units == 0)
    }

    @Test @MainActor func tokenHitUsesBoldMetricsBeforeFirstPaint() throws {
        let first = String(repeating: "i", count: 12), text = String(repeating: "i", count: 12) + "MMMM"
        let file = FileContents(name: "font.txt", contents: text + "\n")
        let tokens = [[ThemedToken(content: first, offset: 0, fontStyle: .bold), ThemedToken(content: "MMMM", offset: 12)]]
        let document = HighlightedDiff(diff: try parseDiffFromFile(file, file), oldTokens: tokens, newTokens: tokens, foreground: "#ffffff", background: "#000000")
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = view
        var options = DiffRenderOptions(); options.fontName = "Helvetica"; options.fontSize = 20
        view.render(document, options: options)
        let canvas = try #require(view.scrollView.documentView)
        let font = try #require(NSFont(name: "Helvetica", size: 20))
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let expected = NSMutableAttributedString(string: text, attributes: [.font: font])
        expected.addAttribute(.font, value: bold, range: .init(location: 0, length: 12))
        let line = CTLineCreateWithAttributedString(expected)
        let x = CTLineGetOffsetForStringIndex(line, 10, nil) + 0.1
        let plain = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        #expect(CTLineGetStringIndexForPosition(plain, .init(x: x, y: 0)) >= 12)
        var received: String?
        view.interactionHandlers = .init(onTokenClick: { received = $0.tokenText })
        let location = canvas.convert(.init(x: 60 + x, y: 10), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
        }
        #expect(received == first)
        #expect(view.metrics.styledLines == 1)
    }

}

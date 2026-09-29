import Testing
import AppKit
@testable import ShikiDiffs

@Suite(.serialized) struct SelectionTests {
    @Test @MainActor func characterSelectionCopiesAcrossLinesAndMovesByGrapheme() async throws {
        let source = "hello 👩🏽‍💻 world\nsecond line\n"
        let file = FileContents(name: "f.txt", contents: source)
        let worker = DiffHighlighter()
        let prepared = try await worker.prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeDiffView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        window.contentView = view; view.render(prepared)
        let emojiEnd = ("hello 👩🏽‍💻" as NSString).length
        view.selectText(.init(side: .additions, anchor: .init(line: 0, character: 6), head: .init(line: 0, character: emojiEnd)))
        #expect(view.selectedText() == "👩🏽‍💻")
        view.selectText(.init(side: .additions, anchor: .init(line: 0, character: 6), head: .init(line: 1, character: 6)))
        #expect(view.selectedText() == "👩🏽‍💻 world\nsecond")
        view.selectText(.init(side: .additions, anchor: .init(line: 0, character: 6), head: .init(line: 0, character: 6)))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        view.scrollView.documentView!.keyDown(with: key)
        #expect(view.selectedText() == "👩🏽‍💻")
        #expect(view.selectedTextRange?.head.character == emojiEnd)
        view.scrollToRow(1); view.render(prepared)
        #expect(view.selectedText() == "👩🏽‍💻")
        view.selectLines(.init(side: .additions, startLine: 1, endLine: 1))
        #expect(view.selectedText() == "hello 👩🏽‍💻 world\n")
        window.close()
    }
    @Test @MainActor func mouseSelectsCharactersWhileGutterSelectsWholeLine() async throws {
        let file = FileContents(name: "f.txt", contents: "hello world\n")
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        var options = DiffRenderOptions(); options.diffStyle = .unified; options.disableFileHeader = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeDiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window.contentView = view; view.render(prepared, options: options)
        let canvas = view.scrollView.documentView!
        let width = ("hello" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(NSPoint(x: x, y: 11), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, x: 60))
        canvas.mouseDragged(with: try event(.leftMouseDragged, x: 60 + width))
        canvas.mouseUp(with: try event(.leftMouseUp, x: 60 + width))
        #expect(view.selectedText() == "hello")
        view.interactionHandlers.enableLineSelection = true
        canvas.mouseDown(with: try event(.leftMouseDown, x: 20))
        #expect(view.selectedText() == "hello world\n")
        window.close()
    }
}

struct SelectionEqualityTests {
    @Test func preservesExplicitEndSideAndDirection() {
        let a = LineSelection(side: .additions, startLine: 1, endLine: 3)
        let explicit = LineSelection(side: .additions, startLine: 1, endLine: 3, endSide: .additions)
        #expect(explicit.endSide == .additions)
        #expect(!areSelectionsEqual(a, explicit))
        #expect(areSelectionsEqual(a, a))
        #expect(areSelectionsEqual(nil, nil))
        #expect(!areSelectionsEqual(a, nil))
        #expect(!areSelectionsEqual(a, .init(side: .additions, startLine: 3, endLine: 1)))
        #expect(!areSelectionsEqual(a, .init(side: .deletions, startLine: 1, endLine: 3)))
        #expect(!areSelectionsEqual(a, .init(side: .additions, startLine: 1, endLine: 4)))
    }
}

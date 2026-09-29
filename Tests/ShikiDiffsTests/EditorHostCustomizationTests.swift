import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct EditorHostCustomizationTests {
    actor ClipboardGate {
        var types: [String?] = []
        var pending: [CheckedContinuation<String, any Error>] = []
        func read(_ type: String?) async throws -> String {
            types.append(type)
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func finish(_ text: String) { pending.removeFirst().resume(returning: text) }
        var count: Int { types.count }
    }
    func awaitRead(_ gate: ClipboardGate, count: Int) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while await gate.count < count, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await gate.count == count)
    }
    @Test @MainActor func asynchronousPairedPasteUsesDocumentOrderEOLAndOneUndo() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, _, editor) = try await helper.mount("one\r\ntwo\r\nthree"); defer { window.close() }
        editor.setSelections([.init(anchor: .init(line: 1, character: 0), focus: .init(line: 1, character: 3)),
                              .init(anchor: .init(line: 0, character: 0), focus: .init(line: 0, character: 3))])
        let selections = editor.getSelections(), gate = ClipboardGate()
        editor.clipboard = .init { try await gate.read($0) }
        editor.paste(nil)
        try await awaitRead(gate, count: 1); #expect(editor.isReadingClipboard)
        await gate.finish("fallback")
        try await awaitRead(gate, count: 2)
        #expect(await gate.types == [nil, EditorClipboardProvider.selectionType])
        await gate.finish("[\"first\\nline\",\"second\"]")
        try await helper.wait { !editor.isReadingClipboard }
        #expect(editor.getText() == "first\r\nline\r\nsecond\r\nthree")
        editor.undo(nil); #expect(editor.getText() == "one\r\ntwo\r\nthree" && editor.getSelections() == selections)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func pasteRejectsMovedSelectionReplacedProviderAndSuspendedSession() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, view, editor) = try await helper.mount("abc\ndef"); defer { window.close() }
        let gate = ClipboardGate()
        editor.clipboard = .init { try await gate.read($0) }
        editor.paste(nil); try await awaitRead(gate, count: 1)
        editor.select(.init(location: 1, length: 0)); await gate.finish("stale")
        try await Task.sleep(for: .milliseconds(20)); #expect(editor.getText() == "abc\ndef")
        editor.paste(nil); try await awaitRead(gate, count: 2)
        editor.clipboard = .init { _ in "replacement" }; await gate.finish("old")
        try await Task.sleep(for: .milliseconds(20)); #expect(editor.getText() == "abc\ndef")
        editor.clipboard = .init { try await gate.read($0) }
        editor.paste(nil); try await awaitRead(gate, count: 3)
        editor.suspend(); await gate.finish("detached")
        try await Task.sleep(for: .milliseconds(20)); #expect(editor.getText() == "abc\ndef")
        try view.resumeEditing(editor); await editor.waitForRendering()
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func malformedPairMetadataFallsBackAndExplicitPasteboardBypassesProvider() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, _, editor) = try await helper.mount("abc"); defer { window.close() }
        editor.setSelections([.init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0)),
                              .init(start: .init(line: 0, character: 3), end: .init(line: 0, character: 3))])
        editor.clipboard = .init { type in type == nil ? "x" : "[null,1]" }
        editor.paste(nil); try await helper.wait { !editor.isReadingClipboard }
        #expect(editor.getText() == "xabcx")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("native", forType: .string)
        editor.setSelections([.init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 5))])
        editor.pasteSelection(from: board); #expect(editor.getText() == "native")
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func selectionActionRequiresUserGestureReadsLiveSelectionAndExpires() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, view, editor) = try await helper.mount("one two three\n" + String(repeating: "next\n", count: 60)); defer { window.close() }
        var contexts: [SelectionActionContext] = []
        editor.selectionActionRenderer = .init { context in
            contexts.append(context); return NSButton(title: "Uppercase", target: nil, action: nil)
        }
        editor.enabledSelectionAction = true
        editor.select(.init(location: 0, length: 3)); try helper.paint(view)
        #expect(contexts.isEmpty)
        editor.selectionGestureBegan(); editor.select(.init(location: 0, length: 7)); try helper.paint(view)
        #expect(contexts.isEmpty)
        editor.selectionGestureEnded(); try helper.paint(view, path: "/tmp/swift-diffs-selection-action.png")
        let context = try #require(contexts.first)
        #expect(context.isActive && context.getSelectionText() == "one two")
        editor.select(.init(location: 4, length: 3)); try helper.paint(view)
        #expect(contexts.count == 1 && context.getSelectionText() == "two")
        #expect(try context.replaceSelectionText("TWO")); #expect(editor.getText().hasPrefix("one TWO three"))
        editor.undo(nil); #expect(editor.getText().hasPrefix("one two three"))
        editor.suspend(); #expect(!context.isActive && context.textDocument == nil)
        #expect(try !context.replaceSelectionText("stale"))
        try view.resumeEditing(editor); await editor.waitForRendering()
        editor.select(.init(location: 0, length: 3)); editor.selectionGestureEnded(); try helper.paint(view)
        let next = try #require(contexts.last); #expect(next !== context && next.isActive)
        context.close(); #expect(next.isActive)
        next.close(); try helper.paint(view); #expect(!next.isActive)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func customCaretsVirtualizeReuseAndHandleReentrantRenderer() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, view, editor) = try await helper.mount(String(repeating: "value\n", count: 500)); defer { window.close() }
        var rendered: [NSView] = []
        editor.caretRenderer = .init { _ in
            let label = NSTextField(labelWithString: "Collaborator"); label.textColor = .systemPurple
            rendered.append(label); return label
        }
        editor.setCarets((0..<500).map { .init(anchor: .init(line: $0, character: 0), focus: .init(line: $0, character: 2), metadata: .init(color: "#8800ff")) })
        try helper.paint(view)
        let initial = rendered.count; #expect(initial > 0 && initial < 30)
        try helper.paint(view); #expect(rendered.count == initial)
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 1400)); try helper.paint(view)
        #expect(rendered.count > initial && rendered.filter { $0.superview != nil }.count < 30)
        #expect(rendered.prefix(initial).allSatisfy { $0.superview == nil })
        editor.caretRenderer = .init { [weak editor] _ in editor?.setCarets([]); return NSView(frame: .init(x: 0, y: 0, width: 20, height: 20)) }
        try helper.paint(view)
        #expect(editor.carets.isEmpty && rendered.allSatisfy { $0.superview == nil })
        _ = try await editor.complete(.discard)
    }
    @Test func popoverFlipsWithHysteresis() {
        var placement = EditorPopoverPlacement()
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 100)
        let fallback = CGRect(x: 0, y: 10, width: 80, height: 25)
        #expect(placement.choose(preferred: .init(x: 0, y: 80, width: 80, height: 25), fallback: fallback, viewport: viewport) == fallback)
        #expect(placement.choose(preferred: .init(x: 0, y: 74, width: 80, height: 25), fallback: fallback, viewport: viewport) == fallback)
        #expect(placement.choose(preferred: .init(x: 0, y: 70, width: 80, height: 25), fallback: fallback, viewport: viewport) != fallback)
    }
    @Test @MainActor func pendingPasteRejectsEditThenUndoAndReportsOnlyCurrentFailure() async throws {
        enum Failure: Error { case unavailable }
        let helper = EditorPredictionIntegrationTests()
        let (window, _, editor) = try await helper.mount("abc"); defer { window.close() }
        let gate = ClipboardGate()
        editor.clipboard = .init { try await gate.read($0) }
        editor.paste(nil); try await awaitRead(gate, count: 1)
        editor.insertText("x", replacementRange: .init(location: NSNotFound, length: 0)); editor.undo(nil)
        await gate.finish("stale")
        try await Task.sleep(for: .milliseconds(20)); #expect(editor.getText() == "abc")
        editor.paste(nil); try await awaitRead(gate, count: 2)
        editor.breakUndoCoalescing(); await gate.finish("history changed")
        try await helper.wait { !editor.isReadingClipboard }
        #expect(editor.getText() == "abc")
        var failures = 0
        editor.onError = { _ in failures += 1 }
        editor.clipboard = .init { _ in throw Failure.unavailable }
        editor.paste(nil); try await helper.wait { !editor.isReadingClipboard }
        #expect(failures == 1 && editor.getText() == "abc")
        _ = try await editor.complete(.discard)
    }
    @MainActor final class SizedContent: NSView {
        var size = CGSize(width: 100, height: 24)
        override var intrinsicContentSize: NSSize { size }
    }
    @Test @MainActor func actionTracksRealMouseSelectionResizesAndStaysInsideSplitViewport() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, view, editor) = try await helper.mount("one two three\n" + String(repeating: "next\n", count: 60), style: .split, overflow: .wrap); defer { window.close() }
        let content = SizedContent(frame: .zero)
        var context: SelectionActionContext?
        editor.selectionActionRenderer = .init { context = $0; return content }
        editor.enabledSelectionAction = true
        let canvas = try #require(view.scrollView.documentView)
        let start = editor.firstRect(forCharacterRange: .init(location: 0, length: 0), actualRange: nil)
        let end = editor.firstRect(forCharacterRange: .init(location: 7, length: 0), actualRange: nil)
        func event(_ type: NSEvent.EventType, _ rect: NSRect) throws -> NSEvent {
            let point = window.convertPoint(fromScreen: .init(x: rect.minX + 1, y: rect.midY))
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, start))
        canvas.mouseDragged(with: try event(.leftMouseDragged, end))
        #expect(context == nil)
        canvas.mouseUp(with: try event(.leftMouseUp, end)); try helper.paint(view)
        let action = try #require(context)
        #expect(action.getSelectionText() == "one two")
        let host = try #require(canvas.subviews.first { $0.identifier?.rawValue == "ShikiDiffs.selectionAction" })
        let initialHeight = host.frame.height
        content.size = .init(width: 900, height: 72); content.invalidateIntrinsicContentSize(); editor.invalidateWidgetLayout()
        #expect(host.frame.height > initialHeight && host.frame.minX > view.bounds.width / 2 && host.frame.maxX <= canvas.visibleRect.maxX)
        try helper.paint(view, path: "/tmp/swift-diffs-selection-action-split.png")
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 800)); try helper.paint(view)
        #expect(!action.isActive && host.superview == nil)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func selectionRendererCanReplaceOrCloseItselfWithoutMountingStaleContent() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, view, editor) = try await helper.mount("one two\n"); defer { window.close() }
        var contexts: [SelectionActionContext] = []
        let staleView = NSView(frame: .init(x: 0, y: 0, width: 50, height: 20))
        editor.selectionActionRenderer = .init { [weak editor] context in
            contexts.append(context); editor?.selectionActionRenderer = nil; return staleView
        }
        editor.enabledSelectionAction = true
        editor.select(.init(location: 0, length: 3)); editor.selectionGestureEnded(); try helper.paint(view)
        #expect(staleView.superview == nil && contexts.count == 1 && !contexts[0].isActive)
        editor.selectionActionRenderer = .init { context in context.close(); return staleView }
        editor.selectionGestureEnded(); try helper.paint(view)
        #expect(staleView.superview == nil)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func renderersCannotMountGeometryFromBeforeTheirOwnDocumentEdit() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, view, editor) = try await helper.mount("one two\n"); defer { window.close() }
        let caretView = NSView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        var caretCalls = 0
        editor.caretRenderer = .init { [weak editor] _ in
            caretCalls += 1
            if caretCalls == 1 { editor?.insertText("x", replacementRange: .init(location: NSNotFound, length: 0)) }
            return caretView
        }
        editor.setCarets([.init(anchor: .init(line: 0, character: 0), focus: .init(line: 0, character: 3), metadata: .init(color: "#f00"))])
        #expect(caretCalls == 1 && caretView.superview == nil)
        await editor.waitForRendering(); try helper.paint(view); #expect(caretView.superview != nil)
        let staleAction = NSView(frame: .init(x: 0, y: 0, width: 30, height: 20))
        var actionContext: SelectionActionContext?
        editor.selectionActionRenderer = .init { [weak editor] context in
            actionContext = context
            editor?.insertText("new", replacementRange: .init(location: NSNotFound, length: 0))
            return staleAction
        }
        editor.enabledSelectionAction = true
        editor.select(.init(location: 0, length: 3)); editor.selectionGestureEnded()
        #expect(staleAction.superview == nil && actionContext?.isActive == false)
        _ = try await editor.complete(.discard)
    }
}

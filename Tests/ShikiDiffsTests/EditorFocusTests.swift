import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct EditorFocusTests {
    @Test @MainActor func activeLineIsIndependentOfSelectionAndSurvivesRerender() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\nthree\n")
        var options = DiffRenderOptions(); options.expandUnchanged = true; options.diffStyle = .unified
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file, options: options)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 500, height: 200)); view.render(document, options: options)
        let selected = LineSelection(side: .additions, startLine: 1, endLine: 1)
        view.selectLines(selected)
        view.setEditorActiveLine(3, options: .init(side: .additions, lineNumberOnly: true))
        #expect(view.selectedLines == selected && view.editorActiveLine == 3)
        view.rerender(); #expect(view.editorActiveLine == 3 && view.editorActiveLineOptions.lineNumberOnly)
        view.selectLines(nil); #expect(view.editorActiveLine == 3)
        view.setEditorActiveLine(nil); #expect(view.editorActiveLine == nil)
        view.setEditorActiveLine(2); view.cleanUp(); #expect(view.editorActiveLine == nil)
    }
    @Test @MainActor func focusTargetsVisibleSourceAndPreservesRequestedScroll() async throws {
        let source = (1...100).map { "line \($0)\n" }.joined()
        let file = FileContents(name: "f.txt", contents: source)
        var options = DiffRenderOptions(); options.expandUnchanged = true; options.disableFileHeader = true; options.diffStyle = .unified
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file, options: options)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 500, height: 200)); window.contentView = view
        view.render(document, options: options)
        let editor = try view.beginEditing(); await editor.waitForRendering()
        var focused = 0, blurred = 0
        editor.onFocus = { focused += 1 }; editor.onBlur = { blurred += 1 }
        editor.blur(); #expect(!editor.isFocused)
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 500))
        let origin = view.scrollView.contentView.bounds.origin
        editor.focus(.init(preventScroll: true, line: .number(2), character: 2))
        #expect(editor.isFocused && focused == 1 && blurred == 1)
        #expect(editor.document.positionAt(editor.selectedRange().location) == .init(line: 1, character: 2))
        #expect(view.scrollView.contentView.bounds.origin == origin)
        editor.focus(.init(preventScroll: true, line: .firstVisible, offset: 25))
        let position = editor.document.positionAt(editor.selectedRange().location)
        #expect(position.line > 20 && position.character == 0)
        #expect(view.editorActiveLine == position.line + 1)
        #expect(view.scrollView.contentView.bounds.origin == origin)
        editor.focus(.init(line: .number(100), character: Int.max))
        #expect(editor.document.positionAt(editor.selectedRange().location) == .init(line: 99, character: 8))
        #expect(view.scrollView.contentView.bounds.minY > origin.y)
        #expect(focused == 1)
        _ = try await editor.complete(.discard)
        #expect(!editor.isFocused && blurred == 2)
    }
    @Test @MainActor func focusCallbackMayDetachEditor() async throws {
        let file = FileContents(name: "f.txt", contents: "text")
        let view = NativeDiffView(); view.render(try await DiffHighlighter().prepare(oldFile: file, newFile: file))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; defer { window.close() }
        let editor = try view.beginEditing(); editor.blur()
        editor.onFocus = { editor.suspend() }
        editor.focus(.init(line: .number(1)))
        #expect(editor.isSuspended && !editor.isFocused)
        editor.onFocus = nil; editor.abandon()
    }
}

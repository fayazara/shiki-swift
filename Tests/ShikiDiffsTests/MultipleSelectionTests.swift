import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct MultipleSelectionTests {
    struct Oracle: Decodable {
        struct Merge: Decodable { var selections: [EditorSelection]; var expected: [EditorSelection] }
        struct Replacement: Decodable {
            var text: String; var selections: [EditorSelection]; var texts: [String]; var documentOrder: Bool
            var expectedText: String; var expectedSelections: [EditorSelection]
        }
        var merges: [Merge]; var replacements: [Replacement]
    }
    @Test func selectionGeometryMatchesActualUpstream() throws {
        let url = try #require(fixtureURL("multiselection-oracle"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        for (index, fixture) in oracle.merges.enumerated() {
            #expect(mergeOverlappingSelections(fixture.selections) == fixture.expected, "Merge \(index)")
        }
        for (index, fixture) in oracle.replacements.enumerated() {
            var document = TextDocument(uri: "f.txt", text: fixture.text)
            let resolved = try resolveSelectionReplacements(document, selections: fixture.selections, texts: fixture.texts, documentOrder: fixture.documentOrder)
            try document.applyResolvedEdits(resolved.edits)
            let next = resolved.selections.map { EditorSelection(anchor: document.positionAt($0.anchor), focus: document.positionAt($0.focus)) }
            #expect(document.getText().utf16.elementsEqual(fixture.expectedText.utf16), "Text \(index)")
            #expect(next == fixture.expectedSelections, "Selections \(index)")
        }
    }
    @MainActor func makeEditor(_ text: String) async throws -> (NativeDiffView, DiffEditor) {
        let file = FileContents(name: "f.txt", contents: text)
        var options = DiffRenderOptions(); options.expandUnchanged = true; options.diffStyle = .unified; options.disableFileHeader = true
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 500, height: 250))
        view.render(try await DiffHighlighter().prepare(oldFile: file, newFile: file, options: options), options: options)
        return (view, try view.beginEditing())
    }
    func selection(_ line: Int, _ start: Int, _ end: Int? = nil) -> EditorSelection {
        .init(anchor: .init(line: line, character: start), focus: .init(line: line, character: end ?? start))
    }
    @Test @MainActor func typingUndoAndNavigationKeepEveryCaret() async throws {
        let (view, editor) = try await makeEditor("alpha\nbeta\ngamma\n")
        let original = [selection(2, 0), selection(0, 0)]
        editor.setSelections(original)
        editor.insertText("😀", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.getText() == "😀alpha\nbeta\n😀gamma\n")
        #expect(editor.getSelections().map(\.focus) == [.init(line: 2, character: 2), .init(line: 0, character: 2)])
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(editor.getSelections().allSatisfy { $0.focus.character == 3 })
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.getText() == "😀lpha\nbeta\n😀amma\n")
        editor.undo(nil); editor.undo(nil)
        #expect(editor.getText() == "alpha\nbeta\ngamma\n" && editor.getSelections() == original)
        editor.redo(nil); #expect(editor.getSelections().count == 2)
        #expect(view.attachedEditor === editor)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func pairedClipboardUsesDocumentOrderAndPlainTextRepeats() async throws {
        let (view, editor) = try await makeEditor("one two\nAAA BBB\n")
        let pasteboard = NSPasteboard(name: .init("ShikiDiffs.multi.\(UUID())")); defer { pasteboard.releaseGlobally() }
        editor.setSelections([selection(0, 4, 7), selection(0, 0, 3)])
        editor.copySelection(to: pasteboard)
        editor.setSelections([selection(1, 4, 7), selection(1, 0, 3)])
        editor.pasteSelection(from: pasteboard)
        #expect(editor.getText() == "one two\none two\n")
        editor.undo(nil); #expect(editor.getSelections().count == 2)
        pasteboard.clearContents(); pasteboard.setString("Q", forType: .string)
        editor.pasteSelection(from: pasteboard); #expect(editor.getText() == "one two\nQ Q\n")
        editor.undo(nil); editor.cutSelection(to: pasteboard)
        #expect(editor.getText() == "one two\n \n")
        editor.undo(nil); #expect(editor.getText() == "one two\nAAA BBB\n")
        #expect(view.attachedEditor === editor); _ = try await editor.complete(.discard)
    }
    @Test @MainActor func surroundingCompositionCommitCancelAndHistoryRestoreAllSelections() async throws {
        let (view, editor) = try await makeEditor("one\ntwo")
        editor.setSelections([selection(0, 0, 3), selection(1, 0, 3)])
        editor.insertText("(", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.getText() == "(one)\n(two)")
        #expect(editor.getSelections().allSatisfy { $0.start.character == 1 && $0.end.character == 4 })
        let selected = editor.getSelections()
        editor.setMarkedText("候補", selectedRange: .init(location: 0, length: 2), replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.getText() == "(候補)\n(候補)")
        editor.setMarkedText("候補二", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(editor.getText() == "(one)\n(two)" && editor.getSelections() == selected)
        editor.setMarkedText("候補", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        editor.insertText("完成", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.getText() == "(完成)\n(完成)")
        editor.undo(nil); #expect(editor.getText() == "(one)\n(two)" && editor.getSelections() == selected)
        editor.undo(nil); #expect(editor.getText() == "one\ntwo")
        #expect(view.attachedEditor === editor); _ = try await editor.complete(.discard)
    }
    @Test @MainActor func indentationCommentsAndLineMovementOperateOncePerSelectedLine() async throws {
        let (view, editor) = try await makeEditor("one\ntwo\nthree\nlast")
        editor.setSelections([selection(0, 0), selection(0, 2), selection(2, 0)])
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(editor.getText() == "  on  e\ntwo\n  three\nlast")
        editor.undo(nil)
        editor.performLineCommand(.moveDown)
        #expect(editor.getText() == "two\none\nlast\nthree")
        #expect(editor.getSelections().map(\.start.line) == [1, 1, 3])
        editor.undo(nil)
        editor.languageCommentConfig = ["text": .init(lineComment: .token("//"))]
        editor.toggleComment(); #expect(editor.getText() == "// one\ntwo\n// three\nlast")
        editor.undo(nil); #expect(editor.getSelections().count == 3)
        #expect(view.attachedEditor === editor); _ = try await editor.complete(.discard)
    }
    @Test func occurrenceSearchCrossesPieceBoundariesAndWrapsExactly() throws {
        var document = TextDocument(uri: "f.txt", text: "é é aba aba\naba")
        try document.applyResolvedEdits([.init(range: .init(location: 6, length: 1), newText: "b")])
        #expect(document.findNextNonOverlappingSubstring("é", occupied: []) == 0)
        #expect(document.findNextNonOverlappingSubstring("é", occupied: []) == 2)
        #expect(document.findNextNonOverlappingSubstring("aba", occupied: [.init(location: 5, length: 3)]) == 9)
        #expect(document.findNextNonOverlappingSubstring("aba", occupied: [.init(location: 13, length: 3)]) == 5)
        #expect(document.findNextNonOverlappingSubstring("aba", occupied: [.init(location: 5, length: 11)]) == nil)
        #expect(document.findNextNonOverlappingSubstring("a\na", occupied: []) == 11)
    }
    @Test @MainActor func commandDViewStateAndRetainedSelections() async throws {
        let (view, editor) = try await makeEditor("word word word\n" + String(repeating: "line\n", count: 80))
        editor.select(.init(location: 1, length: 0))
        editor.selectNextOccurrence(); #expect(editor.getSelections() == [selection(0, 0, 4)])
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        #expect(editor.handleKeyEvent(event))
        #expect(editor.getSelections().count == 2)
        editor.selectNextOccurrence(); editor.selectNextOccurrence()
        #expect(editor.getSelections().count == 3)
        editor.insertText("Q", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.getText().hasPrefix("Q Q Q\n"))
        editor.undo(nil); #expect(editor.getSelections().count == 3)
        await editor.waitForRendering()
        let state = EditorViewState(selections: editor.getSelections(), view: .init(scrollLeft: 0, scrollTop: 400))
        try editor.setViewState(state)
        #expect(editor.getViewState() == state)
        editor.suspend(); #expect(editor.getViewState() == state)
        try view.resumeEditing(editor); await editor.waitForRendering()
        #expect(editor.getViewState() == state)
        _ = try await editor.complete(.discard)
        #expect(editor.getViewState() == state)

        let manager = EditStateManager()
        let retained = try view.beginEditing(editStateKey: "many", stateManager: manager)
        retained.setSelections([selection(0, 0, 4), selection(0, 10, 14)])
        retained.insertText("Z", replacementRange: .init(location: NSNotFound, length: 0))
        _ = try await retained.complete(.discard)
        let resumed = try view.beginEditing(editStateKey: "many", stateManager: manager)
        #expect(resumed.getSelections().count == 2 && resumed.getText().hasPrefix("Z word Z"))
        resumed.undo(nil); #expect(resumed.getSelections().map(\.start.character) == [0, 10])
        #expect(manager.get(.fileDiff, editStateKey: "many")?.selections.count == 2)
        _ = try await resumed.complete(.discard)
    }
    @Test @MainActor func optionDragPreservesExistingSelectionAndPaintsSecondaryCaret() async throws {
        let (view, editor) = try await makeEditor("alpha\nbeta\ngamma\n")
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; defer { window.close() }
        await editor.waitForRendering(); editor.select(.init(location: 0, length: 0))
        let canvas = try #require(view.scrollView.documentView)
        func event(_ type: NSEvent.EventType, at position: TextPosition) throws -> NSEvent {
            let rect = view.editorRect(position)
            let point = window.convertPoint(fromScreen: .init(x: rect.minX + 0.25, y: rect.midY))
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.option], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, at: .init(line: 2, character: 1)))
        #expect(editor.getSelections().count == 2)
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: .init(line: 2, character: 3)))
        canvas.mouseUp(with: try event(.leftMouseUp, at: .init(line: 2, character: 3)))
        #expect(editor.getSelections().count == 2)
        #expect(editor.getSelections().first == selection(0, 0))
        #expect(editor.getSelections().last == selection(2, 1, 3))
        func bitmap() throws -> Data {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let withSecondary = try bitmap()
        try withSecondary.write(to: URL(fileURLWithPath: "/tmp/swift-diffs-multiple-carets.png"))
        editor.setSelections([selection(2, 1, 3)])
        #expect(try bitmap() != withSecondary)
        _ = try await editor.complete(.discard)
    }

}

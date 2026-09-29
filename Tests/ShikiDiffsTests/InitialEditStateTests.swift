import AppKit
import Testing
import SwiftUI
@testable import ShikiDiffs

@Suite(.serialized) struct InitialEditStateTests {
    @Test @MainActor func snapshotImportsDraftUndoRedoAnnotationsAndViewportIndependently() async throws {
        let helper = MultipleSelectionTests(), (source, editor) = try await helper.makeEditor("one\ntwo\n" + String(repeating: "line\n", count: 100))
        editor.setAnnotations([.init(id: "note", side: .additions, lineNumber: 2, text: "comment")])
        editor.setSelections([helper.selection(0, 0), helper.selection(1, 0)])
        editor.insertText("A", replacementRange: .init(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        editor.insertText("B", replacementRange: .init(location: NSNotFound, length: 0))
        editor.undo(nil)
        await editor.waitForRendering()
        try editor.setViewState(.init(selections: editor.getSelections(), view: .init(scrollLeft: 0, scrollTop: 400)))
        let snapshot = editor.getEditState(), draft = editor.getText()
        let target = NativeDiffView(frame: source.frame)
        var options = DiffRenderOptions(); options.expandUnchanged = true; options.diffStyle = .unified; options.disableFileHeader = true
        target.render(try #require(source.displayedDocument), options: options)
        let imported = try target.beginEditing(initialState: .init(snapshot))
        var changes = 0; imported.onChange = { _ in changes += 1 }
        await imported.waitForRendering()
        #expect(imported.getText() == draft && imported.getSelections() == snapshot.selections)
        #expect(imported.getViewState().view?.scrollTop == 400 && changes == 0)
        #expect(imported.currentAnnotations == snapshot.annotations)
        #expect(imported.canUndo() && imported.canRedo())
        imported.redo(nil); #expect(imported.getText().hasPrefix("ABone\nABtwo\n"))
        imported.undo(nil); imported.undo(nil); #expect(imported.getText().hasPrefix("one\ntwo\n"))
        #expect(editor.getText() == draft && editor.canRedo())
        #expect(snapshot.document.getText() == draft)
        _ = try await editor.complete(.discard); _ = try await imported.complete(.discard)
        let preservedTop = target.editorScrollOrigin.y
        let partial = try target.beginEditing(initialState: .init(type: .fileDiff,
            editor: .init(selections: [], view: .init(scrollLeft: 0))))
        await partial.waitForRendering()
        #expect(partial.getViewState().view?.scrollTop == preservedTop)
        _ = try await partial.complete(.discard)
    }
    @Test @MainActor func provisionalCompositionExportsWithoutCommittingAndImportsOneUndoGroup() async throws {
        let (source, editor) = try await MultipleSelectionTests().makeEditor("tail")
        editor.setMarkedText("候", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        editor.setMarkedText("候補", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        let snapshot = editor.getEditState()
        #expect(editor.hasMarkedText())
        let target = NativeDiffView(frame: source.frame); target.render(try #require(source.displayedDocument))
        let imported = try target.beginEditing(initialState: .init(snapshot))
        #expect(!imported.hasMarkedText() && imported.getText() == "候補tail")
        imported.undo(nil); #expect(imported.getText() == "tail" && !imported.canUndo())
        imported.redo(nil); #expect(imported.getText() == "候補tail")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(editor.getText() == "tail" && imported.getText() == "候補tail")
        _ = try await editor.complete(.discard); _ = try await imported.complete(.discard)
    }
    @Test @MainActor func explicitStateWinsOverDormantKeyAndWrongTypeDoesNotConsumeIt() async throws {
        let (view, first) = try await MultipleSelectionTests().makeEditor("original")
        _ = try await first.complete(.discard)
        let manager = EditStateManager(), retained = try view.beginEditing(editStateKey: "draft", stateManager: manager)
        retained.insertText("old ", replacementRange: .init(location: NSNotFound, length: 0))
        _ = try await retained.complete(.discard)
        #expect(throws: EditStateError.self) {
            try view.beginEditing(editStateKey: "draft", stateManager: manager, initialState: .init(type: .file))
        }
        #expect(manager.get(.fileDiff, editStateKey: "draft")?.document.getText() == "old original")
        var document = TextDocument(uri: "f.txt", text: "replacement", editStack: .init(maxEntries: 3))
        try document.applyResolvedEdits([.init(range: .init(location: 0, length: 0), newText: "new ")])
        let imported = try view.beginEditing(editStateKey: "draft", stateManager: manager, initialState: .init(type: .fileDiff, document: document))
        #expect(imported.maximumUndoGroups == 3 && imported.getText() == "new replacement")
        imported.undo(nil); #expect(imported.getText() == "replacement")
        _ = try await imported.complete(.discard)
        #expect(manager.get(.fileDiff, editStateKey: "draft")?.document.getText() == "replacement")
    }
    @Test @MainActor func partialStateUsesAttachedTextAndRestoresEmptySelections() async throws {
        let (view, first) = try await MultipleSelectionTests().makeEditor("source")
        _ = try await first.complete(.discard)
        let editor = try view.beginEditing(historyMaxEntries: 4, initialState: .init(type: .fileDiff, editor: .init(selections: [])))
        #expect(editor.getText() == "source" && editor.getSelections().isEmpty && editor.maximumUndoGroups == 4)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func metadataLessHistoryRemapsLiveSelectionsAndAnnotations() async throws {
        let (view, first) = try await MultipleSelectionTests().makeEditor("abcdefgh")
        _ = try await first.complete(.discard)
        var document = TextDocument(uri: "f.txt", text: "abcdefgh")
        try document.applyResolvedEdits([.init(range: .init(location: 0, length: 0), newText: "one\ntwo\n")])
        let position = TextPosition(line: 2, character: 4)
        let editor = try view.beginEditing(initialState: .init(type: .fileDiff, document: document,
            editor: .init(selections: [.init(start: position, end: position)]),
            annotations: [.init(id: "note", side: .additions, lineNumber: 3, text: "comment")]))
        editor.undo(nil)
        #expect(editor.getSelections().last?.focus == .init(line: 0, character: 4))
        #expect(editor.currentAnnotations.first?.lineNumber == 1)
        editor.redo(nil)
        #expect(editor.getSelections().last?.focus == position && editor.currentAnnotations.first?.lineNumber == 3)
        _ = try await editor.complete(.discard)
    }

    @Test @MainActor func importedCoalescingKeepsUnknownBeforeAndKnownAfterSelection() async throws {
        let (view, first) = try await MultipleSelectionTests().makeEditor("abc")
        _ = try await first.complete(.discard)
        var document = TextDocument(uri: "f.txt", text: "abc")
        try document.applyResolvedEdits([.init(range: .init(location: 0, length: 0), newText: "X")])
        let position = TextPosition(line: 0, character: 1)
        let editor = try view.beginEditing(initialState: .init(type: .fileDiff, document: document,
            editor: .init(selections: [.init(start: position, end: position)])))
        editor.insertText("Y", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.document.history.undoStack.count == 1 && editor.getText() == "XYabc")
        editor.undo(nil); #expect(editor.getText() == "abc")
        editor.select(.init(location: 2, length: 0)); editor.redo(nil)
        #expect(editor.getText() == "XYabc" && editor.getSelections().last?.focus.character == 2)
        _ = try await editor.complete(.discard)
    }

    @Test @MainActor func explicitEmptyExpansionStateOverridesExpandedTarget() async throws {
        let old = (0..<80).map { "line \($0)\n" }.joined(), new = old.replacingOccurrences(of: "line 40", with: "changed 40")
        let prepared = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: old), newFile: .init(name: "f.txt", contents: new))
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 500, height: 250)); view.render(prepared)
        view.expandHunk(0, lines: 5); #expect(!view.editorExpansions.isEmpty)
        let editor = try view.beginEditing(initialState: .init(type: .fileDiff, editor: .init(selections: []), expandedHunks: [:]))
        #expect(editor.getEditState().expandedHunks.isEmpty)
        await editor.waitForRendering(); #expect(view.editorExpansions.isEmpty)
        _ = try await editor.complete(.discard)
    }

    @Test @MainActor func swiftUIAttachmentCallbackReceivesImportedEditorOnce() async throws {
        let (source, original) = try await MultipleSelectionTests().makeEditor("source")
        let prepared = try #require(source.displayedDocument); _ = try await original.complete(.discard)
        let state = EditorInitialState(type: .fileDiff, document: .init(uri: "f.txt", text: "restored"))
        var attached: DiffEditor?, callbacks = 0
        let content = EditableFileDiffView(document: prepared, isEditing: .constant(true), initialState: state,
            onEditorAttached: { attached = $0; callbacks += 1 })
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { attached?.abandon(); window.close() }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if attached != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try #require(attached)
        #expect(editor.getText() == "restored" && callbacks == 1)
        var update = content; update.initialState = .init(type: .fileDiff, document: .init(uri: "f.txt", text: "later"))
        host.rootView = update; host.layoutSubtreeIfNeeded(); await Task.yield()
        #expect(editor.getText() == "restored" && callbacks == 1)
    }

    @Test @MainActor func developerModifiedSnapshotRebuildsStaleInteractionGroups() async throws {
        let (view, editor) = try await MultipleSelectionTests().makeEditor("abc")
        editor.insertText("A", replacementRange: .init(location: NSNotFound, length: 0))
        var state = editor.getEditState()
        try state.document.applyResolvedEdits([.init(range: .init(location: 1, length: 0), newText: "B")])
        state.selection = .init(start: .init(line: 0, character: 2), end: .init(line: 0, character: 2))
        _ = try await editor.complete(.discard)
        let imported = try view.beginEditing(initialState: .init(state))
        imported.undo(nil); #expect(imported.getText() == "abc")
        imported.redo(nil)
        #expect(imported.getText() == "ABabc" && imported.getSelections().last?.focus.character == 2)
        _ = try await imported.complete(.discard)
    }

    @Test @MainActor func sourceIdentityResetsUnkeyedImportsAndPreservesExplicitKeyedDrafts() async throws {
        let (_, original) = try await MultipleSelectionTests().makeEditor("source")
        original.insertText("draft ", replacementRange: .init(location: NSNotFound, length: 0))
        let state = original.getEditState()
        let file = FileContents(name: "another.txt", contents: "target")
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let target = NativeDiffView(); target.render(prepared)
        let fresh = try target.beginEditing(initialState: .init(state))
        #expect(fresh.getText() == "target" && !fresh.canUndo() && fresh.getFile().name == "another.txt")
        _ = try await fresh.complete(.discard)
        let keyed = try target.beginEditing(editStateKey: "moved", stateManager: EditStateManager(), initialState: .init(state))
        #expect(keyed.getText() == "draft source" && keyed.canUndo() && keyed.getFile().name == "f.txt")
        _ = try await keyed.complete(.discard); _ = try await original.complete(.discard)
    }

}

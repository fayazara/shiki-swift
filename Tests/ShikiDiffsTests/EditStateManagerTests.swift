import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct EditStateManagerTests {
    private func prepared() async throws -> HighlightedDiff {
        let file = FileContents(name: "draft.txt", contents: "one\ntwo\n")
        return try await DiffHighlighter().prepare(oldFile: file, newFile: file)
    }
    @Test @MainActor func restoresDraftUndoRedoSelectionAndReleasesOldEditor() async throws {
        let manager = EditStateManager(), source = try await prepared()
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 500, height: 300)); view.render(source)
        var editor: DiffEditor? = try view.beginEditing(editStateKey: "key", stateManager: manager)
        weak var previous = editor
        editor!.select(.init(location: 0, length: 0)); editor!.insertText("A", replacementRange: .init(location: NSNotFound, length: 0))
        editor!.breakUndoCoalescing()
        editor!.insertText("B", replacementRange: .init(location: NSNotFound, length: 0)); editor!.undo(nil)
        let selection = editor!.getEditState().selection
        #expect(!manager.clear(.fileDiff, editStateKey: "key"))
        _ = try await editor!.complete(.discard)
        editor = nil
        #expect(previous == nil)
        #expect(manager.get(.fileDiff, editStateKey: "key")?.document.getText() == "Aone\ntwo\n")
        let restored = try view.beginEditing(editStateKey: "key", stateManager: manager)
        #expect(restored.document.getText() == "Aone\ntwo\n")
        #expect(restored.getEditState().selection == selection)
        #expect(restored.undoManager.canUndo && restored.undoManager.canRedo)
        restored.redo(nil); #expect(restored.document.getText() == "ABone\ntwo\n")
        restored.undo(nil); restored.undo(nil); #expect(restored.document.getText() == "one\ntwo\n")
        _ = try await restored.complete(.discard)
    }
    @Test @MainActor func keysAreExclusiveExactAndSeparatedByPresentationType() async throws {
        let manager = EditStateManager(), source = try await prepared()
        let first = NativeDiffView(); first.render(source)
        let editor = try first.beginEditing(editStateKey: "é", stateManager: manager)
        let second = NativeDiffView(); second.render(source)
        #expect(throws: EditStateError.self) { try second.beginEditing(editStateKey: "é", stateManager: manager) }
        let distinct = try second.beginEditing(editStateKey: "e\u{301}", stateManager: manager)
        let file = NativeFileView(); file.render(source, file: .init(name: "draft.txt", contents: "one\ntwo\n"))
        let fileEditor = try file.diffView.beginEditing(editStateKey: "é", stateManager: manager)
        #expect(manager.get(.file, editStateKey: "é") != nil)
        _ = try await editor.complete(.discard); _ = try await distinct.complete(.discard)
        _ = try await fileEditor.complete(.discard)
    }
    @Test @MainActor func dormantStateSupportsSelectiveClearingAndBoundedEviction() async throws {
        let manager = EditStateManager(), source = try await prepared()
        try manager.setCapacity(1)
        #expect(throws: EditStateError.self) { try manager.setCapacity(0) }
        let view = NativeDiffView(); view.render(source)
        let first = try view.beginEditing(editStateKey: "first", stateManager: manager)
        first.insertText("draft ", replacementRange: .init(location: NSNotFound, length: 0))
        _ = try await first.complete(.discard)
        #expect(manager.clear(.fileDiff, editStateKey: "first", parts: .init(history: true, selections: true)))
        let state = try #require(manager.get(.fileDiff, editStateKey: "first"))
        #expect(state.document.getText() == "draft one\ntwo\n" && !state.document.canUndo && state.selection == nil)
        let second = try view.beginEditing(editStateKey: "second", stateManager: manager)
        manager.clearAll() // Active editors remain claimed.
        #expect(manager.get(.fileDiff, editStateKey: "second") != nil)
        _ = try await second.complete(.discard)
        let third = try view.beginEditing(editStateKey: "third", stateManager: manager)
        _ = try await third.complete(.discard)
        #expect(manager.get(.fileDiff, editStateKey: "second") == nil)
        #expect(manager.clear(.fileDiff, editStateKey: "third"))
    }
    @Test @MainActor func reviewFactoryGetsRetentionKeyAcrossCompletedSessions() async throws {
        let manager = EditStateManager(), source = try await prepared()
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var item = CodeViewItem(id: "review", document: source, edit: true)
        view.getEditStateKey = { "draft-" + $0.id }
        view.createEditor = { host, item, key in
            #expect(key == "draft-" + item.id)
            return try host.beginEditing(editStateKey: key, stateManager: manager)
        }
        try view.setItems([item])
        let first = try #require(view.getEditor(item.id))
        first.insertText("saved ", replacementRange: .init(location: NSNotFound, length: 0))
        item.edit = false; #expect(try view.updateItem(item)); await view.waitForPendingEdits()
        #expect(view.getItem(item.id)?.document.diff.additionLines.joined() == "one\ntwo\n")
        item.edit = true; #expect(try view.updateItem(item))
        let second = try #require(view.getEditor(item.id))
        #expect(second !== first && second.document.getText() == "saved one\ntwo\n")
        second.undo(nil); #expect(second.document.getText() == "one\ntwo\n")
        view.reset(); await view.waitForPendingEdits()
    }
}

import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct EditHistoryTests {
    struct Edit: Decodable { var start: Int; var end: Int; var text: String
        var native: ResolvedTextEdit { .init(range: .init(location: start, length: end - start), newText: text) }
    }
    struct Entry: Decodable {
        var forwardEdits: [Edit]; var inverseEdits: [Edit]; var versionBefore: Int; var versionAfter: Int
        var selectionsBefore: [EditorSelection]?; var selectionsAfter: [EditorSelection]?
        var coalescingMode: EditHistoryCoalescingMode?; var undoBoundary: Bool?
    }
    struct Action: Decodable {
        var kind: String; var edits: [Edit]?; var selections: [EditorSelection]?; var undoBoundary: Bool?; var updateHistory: Bool?
        var text: String; var version: Int; var undoCount: Int; var redoCount: Int; var canCoalesce: Bool; var top: Entry?
    }
    struct Fixture: Decodable { var text: String; var maxEntries: Int; var actions: [Action] }
    @Test func documentHistoryMatchesActualUpstream() throws {
        let url = try #require(fixtureURL("history-oracle"))
        for (index, fixture) in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)).enumerated() {
            var document = TextDocument(uri: "f.txt", text: fixture.text, editStack: .init(maxEntries: fixture.maxEntries))
            for (step, action) in fixture.actions.enumerated() {
                if action.kind == "undo" { document.undo() }
                else if action.kind == "redo" { document.redo() }
                else { try document.applyResolvedEdits(action.edits!.map(\.native), updateHistory: action.updateHistory ?? true, selectionsBefore: action.selections, undoBoundary: action.undoBoundary ?? false) }
                let history = document.history
                #expect(document.getText().utf16.elementsEqual(action.text.utf16), "History text \(index):\(step)")
                #expect(document.version == action.version && history.undoStack.count == action.undoCount && history.redoStack.count == action.redoCount, "History counts \(index):\(step)")
                #expect(history.canCoalesce == action.canCoalesce, "Coalescing \(index):\(step)")
                if let expected = action.top, let top = history.undoStack.last {
                    for (native, oracle) in [(top.forwardEdits, expected.forwardEdits), (top.inverseEdits, expected.inverseEdits)] {
                        #expect(native.count == oracle.count)
                        for (a, b) in zip(native, oracle) { #expect(a.range == b.native.range && a.newText.utf16.elementsEqual(b.text.utf16), "History edits \(index):\(step)") }
                    }
                    #expect(top.versionBefore == expected.versionBefore && top.versionAfter == expected.versionAfter)
                    #expect(top.selectionsBefore == expected.selectionsBefore && top.selectionsAfter == expected.selectionsAfter)
                    #expect(top.coalescingMode == expected.coalescingMode && top.undoBoundary == (expected.undoBoundary ?? false))
                } else { #expect((history.undoStack.last == nil) == (action.top == nil)) }
            }
        }
    }
    @Test func snapshotsTransferIndependentlyAndKeepRedo() throws {
        var document = TextDocument(uri: "first", text: "original")
        try document.applyResolvedEdits([.init(range: .init(location: 0, length: 0), newText: "a")])
        try document.applyResolvedEdits([.init(range: .init(location: 1, length: 0), newText: "b")])
        #expect(document.history.undoStack.count == 1)
        document.undo()
        let snapshot = document.history
        var copy = TextDocument(uri: "second", text: document.getText(), version: document.version, editStack: .init(state: snapshot))
        copy.redo(); #expect(copy.getText() == "aboriginal" && document.getText() == "original")
        #expect(snapshot.undoStack.isEmpty && snapshot.redoStack.count == 1)
        document.clearHistory(); #expect(copy.canUndo && !document.canRedo)
    }
    @Test @MainActor func typingDeletingAndBoundaryRestoreMultipleCarets() async throws {
        let helper = MultipleSelectionTests(), (view, editor) = try await helper.makeEditor("alpha\nbeta")
        let carets = [helper.selection(0, 0), helper.selection(1, 0)]
        editor.setSelections(carets)
        for letter in ["x", "y", "z"] { editor.insertText(letter, replacementRange: .init(location: NSNotFound, length: 0)) }
        #expect(editor.document.history.undoStack.count == 1)
        editor.undo(nil); #expect(editor.getText() == "alpha\nbeta" && editor.getSelections() == carets)
        editor.redo(nil); #expect(editor.getText() == "xyzalpha\nxyzbeta")
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.getText() == "xalpha\nxbeta")
        editor.undo(nil); #expect(editor.getText() == "xyzalpha\nxyzbeta")
        editor.insertText("Q", replacementRange: .init(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        editor.insertText("R", replacementRange: .init(location: NSNotFound, length: 0))
        editor.undo(nil); #expect(editor.getText() == "xyzQalpha\nxyzQbeta")
        editor.undo(nil); #expect(editor.getText() == "xyzalpha\nxyzbeta")
        #expect(view.attachedEditor === editor); _ = try await editor.complete(.discard)
    }
    @Test @MainActor func historyCapCountsIMEAsOneGroupAndKeepsAnnotations() async throws {
        let (view, editor) = try await MultipleSelectionTests().makeEditor("tail")
        editor.setAnnotations([.init(id: "note", side: .additions, lineNumber: 1, text: "tail")])
        for _ in 0..<105 { editor.insertText("\n", replacementRange: .init(location: NSNotFound, length: 0)) }
        #expect(editor.document.history.undoStack.count == 100)
        #expect(editor.currentAnnotations.first?.lineNumber == 106)
        for text in ["候", "候補", "候補三"] {
            editor.setMarkedText(text, selectedRange: .init(location: text.utf16.count, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        }
        editor.insertText("完成", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.document.history.undoStack.count == 103) // 99 ordinary groups + four composition transactions.
        var undos = 0
        while editor.canUndo() { editor.undo(nil); undos += 1 }
        #expect(undos == 100 && editor.getText() == String(repeating: "\n", count: 6) + "tail")
        #expect(editor.currentAnnotations.first?.lineNumber == 7)
        var redos = 0
        while editor.canRedo() { editor.redo(nil); redos += 1 }
        #expect(redos == 100 && editor.getText() == String(repeating: "\n", count: 105) + "完成tail")
        #expect(view.attachedEditor === editor); _ = try await editor.complete(.discard)
    }
    @Test @MainActor func changeCallbackSeesUndoAndCanImmediatelyReplayIt() async throws {
        let (view, editor) = try await MultipleSelectionTests().makeEditor("text")
        var changes = 0
        editor.onChange = { _ in
            changes += 1
            if changes == 1 { #expect(editor.canUndo()); editor.undo(nil) }
        }
        editor.insertText("a", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(changes == 2 && editor.getText() == "text" && editor.canRedo())
        #expect(view.attachedEditor === editor); _ = try await editor.complete(.discard)
    }
    @Test @MainActor func emptySelectionSurvivesRetentionAndSurrogateInsertionRemapsCarets() async throws {
        let (view, first) = try await MultipleSelectionTests().makeEditor("a😀b")
        first.setSelections([.init(start: .init(line: 0, character: 2), end: .init(line: 0, character: 2))])
        first.insertText("x", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(first.getText() == "ax😀b" && first.getSelections().last?.focus.character == 2)
        _ = try await first.complete(.discard)
        let manager = EditStateManager(), second = try view.beginEditing(editStateKey: "empty", stateManager: manager)
        second.setSelections([]); _ = try await second.complete(.discard)
        let resumed = try view.beginEditing(editStateKey: "empty", stateManager: manager)
        #expect(resumed.getSelections().isEmpty && !resumed.hasEditableSelection)
        _ = try await resumed.complete(.discard)
    }
    @Test @MainActor func configuredHistoryLimitSurvivesKeyedRetention() async throws {
        let (view, first) = try await MultipleSelectionTests().makeEditor("tail")
        _ = try await first.complete(.discard)
        let manager = EditStateManager(), editor = try view.beginEditing(editStateKey: "cap", stateManager: manager, historyMaxEntries: 2)
        for _ in 0..<5 { editor.insertText("\n", replacementRange: .init(location: NSNotFound, length: 0)) }
        _ = try await editor.complete(.discard)
        let resumed = try view.beginEditing(editStateKey: "cap", stateManager: manager)
        #expect(resumed.maximumUndoGroups == 2)
        var count = 0
        while resumed.canUndo() { resumed.undo(nil); count += 1 }
        #expect(count == 2 && resumed.getText() == "\n\n\ntail")
        _ = try await resumed.complete(.discard)
        let clamped = try view.beginEditing(historyMaxEntries: 0)
        #expect(clamped.maximumUndoGroups == 1); _ = try await clamped.complete(.discard)
    }

    @Test @MainActor func provisionalCompositionInvalidatesRedoAndCanBeUndone() async throws {
        let (view, editor) = try await MultipleSelectionTests().makeEditor("tail")
        editor.insertText("previous", replacementRange: .init(location: NSNotFound, length: 0))
        editor.undo(nil); #expect(editor.canRedo() && !editor.canUndo())
        editor.setMarkedText("候補", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.canUndo() && !editor.canRedo())
        editor.redo(nil)
        #expect(!editor.hasMarkedText() && editor.getText() == "候補tail")
        #expect(editor.getSelections().last?.focus.character == 2)
        editor.undo(nil); #expect(editor.getText() == "tail")
        editor.redo(nil); #expect(editor.getText() == "候補tail")
        #expect(view.attachedEditor === editor); _ = try await editor.complete(.discard)
    }

}

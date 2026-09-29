import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct ManagedReviewEditingTests {
    private func item(_ id: String = "edit", edit: Bool = true, collapsed: Bool = false) async throws -> CodeViewItem {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        return .init(id: id, document: document, collapsed: collapsed, edit: edit)
    }
    @Test @MainActor func editFlagIsLazyAndRequiresFactory() async throws {
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var first = try await item(collapsed: true)
        try view.setItems([first])
        #expect(view.getEditor(first.id) == nil)
        var creations = 0
        view.createEditor = { host, _, _ in creations += 1; return try host.beginEditing() }
        #expect(creations == 0)
        first.collapsed = false
        #expect(try view.updateItem(first))
        #expect(creations == 1 && view.getEditor(first.id) != nil)
        try view.setItems([first])
        #expect(creations == 1)
        view.reset(); await view.waitForPendingEdits()
    }
    @Test(arguments: [true, false]) @MainActor func hostAcceptsOrRejectsCompletedEdit(_ accept: Bool) async throws {
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var input = try await item()
        var changes: [String] = [], completions = 0, installed = 0
        view.createEditor = { host, _, _ in try host.beginEditing() }
        view.onItemEditChange = { _, item, _ in changes.append(item.id) }
        view.onItemEditComplete = { event, item, editor in
            completions += 1
            #expect(item.id == "renamed")
            #expect(event.newFile?.contents == "prefix one\ntwo\n")
            #expect(!editor.isActive)
            return accept ? .accept : .reject
        }
        view.onItemsChange = { _ in installed += 1 }
        try view.setItems([input])
        let editor = try #require(view.getEditor(input.id))
        #expect(view.updateItemID(input.id, to: "renamed"))
        editor.select(.init(location: 0, length: 0))
        editor.insertText("prefix ", replacementRange: .init(location: NSNotFound, length: 0))
        input = try #require(view.getItem("renamed")); input.edit = false
        #expect(try view.updateItem(input))
        await view.waitForPendingEdits()
        #expect(changes == ["renamed"] && completions == 1)
        #expect(installed == (accept ? 1 : 0))
        #expect(view.getEditor("renamed") == nil)
        #expect(view.getItem("renamed")?.document.diff.additionLines.joined() == (accept ? "prefix one\ntwo\n" : "one\ntwo\n"))
        #expect(view.getItem("renamed")?.edit == false)
        view.reset()
    }
    @Test @MainActor func collapseSuspendsWithoutCompletionAndRemovalNotifiesOnce() async throws {
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var input = try await item()
        view.createEditor = { host, _, _ in try host.beginEditing() }
        var completions = 0
        view.onItemEditComplete = { _, item, _ in completions += 1; #expect(item.id == "edit"); return .accept }
        try view.setItems([input])
        let editor = try #require(view.getEditor(input.id))
        input.collapsed = true
        #expect(try view.updateItem(input))
        #expect(editor.isSuspended && completions == 0)
        input.collapsed = false
        #expect(try view.updateItem(input))
        #expect(view.getEditor(input.id) === editor && !editor.isSuspended)
        #expect(try view.removeItem(input.id))
        await view.waitForPendingEdits()
        #expect(completions == 1)
        #expect(view.fileCount == 0)
    }
    @Test @MainActor func collapsedEditorReceivesHostReplacementAndReportsOwningItem() async throws {
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var input = try await item()
        view.createEditor = { host, _, _ in try host.beginEditing() }
        var reported: [String] = []
        view.onItemEditChange = { _, item, _ in reported.append(item.id) }
        try view.setItems([input])
        let editor = try #require(view.getEditor(input.id))
        input.collapsed = true; #expect(try view.updateItem(input))
        let file = FileContents(name: "f.txt", contents: "external\n")
        input.document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        #expect(try view.updateItem(input))
        #expect(editor.isSuspended && editor.document.getText() == "external\n")
        #expect(reported == ["edit"])
        input.collapsed = false; #expect(try view.updateItem(input))
        #expect(view.getEditor(input.id) === editor && reported == ["edit"])
        editor.undo(nil); #expect(editor.document.getText() == "one\ntwo\n")
        view.reset(); await view.waitForPendingEdits()
    }
    @Test @MainActor func defaultDecisionRejectsAndLateFactoryDoesNotActivateReadOnlyItems() async throws {
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var input = try await item(edit: false)
        try view.setItems([input])
        var creations = 0
        view.createEditor = { host, _, _ in creations += 1; return try host.beginEditing() }
        #expect(creations == 0)
        input.edit = true; #expect(try view.updateItem(input))
        let editor = try #require(view.getEditor(input.id))
        editor.select(.init(location: 0, length: 0)); editor.insertText("draft", replacementRange: .init(location: NSNotFound, length: 0))
        input.edit = false; #expect(try view.updateItem(input))
        await view.waitForPendingEdits()
        #expect(view.getItem(input.id)?.document.diff.additionLines.joined() == "one\ntwo\n")
        view.reset()
    }
}

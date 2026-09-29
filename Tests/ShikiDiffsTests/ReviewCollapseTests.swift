import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct ReviewCollapseTests {
    private func prepared() async throws -> HighlightedDiff {
        let old = FileContents(name: "f.txt", contents: String(repeating: "unchanged content\n", count: 80))
        let new = FileContents(name: "f.txt", contents: old.contents + "added\n")
        return try await DiffHighlighter().prepare(oldFile: old, newFile: new)
    }
    @MainActor private func settle(_ view: NativeCodeView) async throws {
        view.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)); view.layoutSubtreeIfNeeded() }
        #expect(!view.isPreparingWrappedLayout)
    }
    @Test(arguments: [DiffOverflow.scroll, .wrap]) @MainActor
    func collapseOnlyChangesItsOwnFileAndNavigation(_ overflow: DiffOverflow) async throws {
        let document = try await prepared()
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 500, height: 500))
        var options = DiffRenderOptions(); options.expandUnchanged = true; options.overflow = overflow
        var first = CodeViewItem(id: "first", document: document)
        let second = CodeViewItem(id: "second", document: document, file: .init(name: "f.txt", contents: document.diff.additionLines.joined()))
        try view.setItems([first, second], options: options)
        try await settle(view)
        let before = try #require(view.getTopForItem("second"))
        first.collapsed = true
        #expect(try view.updateItem(first))
        try await settle(view)
        let after = try #require(view.getTopForItem("second"))
        #expect(after < before)
        let firstView = try #require(view.getRenderedItems().first { $0.id == "first" })
        #expect(firstView.instance.rowCount == 0)
        #expect(view.getRenderedItems().first { $0.id == "second" }?.instance.rowCount ?? 0 > 0)
        #expect(view.scrollToRange(.init(side: .additions, startLine: 80, endLine: 81), inItem: "first"))
        first.collapsed = false
        #expect(try view.updateItem(first))
        try await settle(view)
        #expect(abs((view.getTopForItem("second") ?? 0) - before) < 0.1)
        view.reset()
    }
    @Test @MainActor func collapseRetainsEditorDraftUndoAndDoesNotComplete() async throws {
        let document = try await prepared()
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 500))
        var item = CodeViewItem(id: "edit", document: document)
        try view.setItems([item])
        let editor = try view.beginEditingItem(item.id)
        var completions = 0
        editor.onEditComplete = { _ in completions += 1; return true }
        editor.select(.init(location: 0, length: 0))
        editor.insertText("draft ", replacementRange: .init(location: NSNotFound, length: 0))
        item.collapsed = true
        #expect(try view.updateItem(item))
        #expect(editor.isActive && editor.isSuspended)
        #expect(completions == 0)
        #expect(view.getRenderedItems().first?.instance.rowCount == 0)
        item.collapsed = false
        #expect(try view.updateItem(item))
        #expect(editor.isActive && !editor.isSuspended)
        #expect(editor.document.getText().hasPrefix("draft "))
        editor.undo(nil)
        #expect(editor.document.getText() == document.diff.additionLines.joined())
        #expect(completions == 0)
        view.reset()
    }
    @Test @MainActor func perItemFalseOverridesGlobalCollapseAndSurvivesRename() async throws {
        let document = try await prepared()
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 500))
        var options = DiffRenderOptions(); options.collapsed = true
        try view.setItems([.init(id: "open", document: document, collapsed: false), .init(id: "closed", document: document)], options: options)
        #expect(view.getRenderedItems().first { $0.id == "open" }?.instance.rowCount ?? 0 > 0)
        #expect(view.updateItemID("open", to: "renamed"))
        #expect(view.getItem("renamed")?.collapsed == false)
        view.reset()
    }
}

import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct ExpansionStateTests {
    private func prepared() async throws -> HighlightedDiff {
        let lines = (1...200).map { "line \($0)" }
        var changed = lines; changed[99] = "changed"
        return try await DiffHighlighter().prepare(oldFile: .init(name: "folds.txt", contents: lines.joined(separator: "\n")),
                                                  newFile: .init(name: "folds.txt", contents: changed.joined(separator: "\n")))
    }
    @Test @MainActor func snapshotsReplaceClearAndResetWithSource() async throws {
        let document = try await prepared()
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.render(document)
        let originalRows = view.rowCount
        #expect(view.getExpandedHunk(0) == .init())
        #expect(try !view.isLineRenderable(1))
        let regions = [0: HunkExpansionRegion(fromStart: 8, fromEnd: 4)]
        view.setExpandedHunksMap(regions)
        #expect(try view.isLineRenderable(1))
        #expect(try !view.isLineRenderable(50))
        #expect(view.rowCount > originalRows)
        var snapshot = view.getExpandedHunksMap()
        snapshot[0]?.fromStart = 50
        #expect(view.getExpandedHunk(0).fromStart == 8)
        view.setExpandedHunksMap([:])
        #expect(view.rowCount == originalRows)
        #expect(try !view.isLineRenderable(1))
        view.setExpandedHunksMap(regions)
        view.rerender()
        #expect(view.getExpandedHunksMap() == regions)
        view.render(document.identifyingSource(as: UUID()))
        #expect(view.getExpandedHunksMap().isEmpty)
        view.setExpandedHunksMap([0: .init(fromStart: Int.max, fromEnd: Int.max)])
        view.expandHunk(0, lines: 10, direction: .both)
        #expect(view.getExpandedHunk(0).fromStart == Int.max)
        #expect(try view.isLineRenderable(50))
        view.cleanUp()
        #expect(view.getExpandedHunksMap().isEmpty)
    }
    @Test @MainActor func pendingEditorRenderKeepsExplicitReplacementIncludingEmptyMap() async throws {
        let document = try await prepared()
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.render(document)
        let editor = try view.beginEditing()
        await editor.waitForRendering()
        let offset = editor.document.offsetAt(.init(line: 99, character: 0))
        editor.select(.init(location: offset, length: 0))
        editor.insertText("prefix ", replacementRange: .init(location: NSNotFound, length: 0))
        let regions = [0: HunkExpansionRegion(fromStart: 12)]
        view.setExpandedHunksMap(regions)
        await editor.waitForRendering()
        #expect(view.getExpandedHunksMap() == regions)
        #expect(editor.getEditState().expandedHunks == regions)
        editor.insertText("more ", replacementRange: .init(location: NSNotFound, length: 0))
        view.setExpandedHunksMap([:])
        await editor.waitForRendering()
        #expect(view.getExpandedHunksMap().isEmpty)
        #expect(editor.getEditState().expandedHunks.isEmpty)
        #expect(editor.document.getLineText(99).hasPrefix("prefix more "))
        editor.abandon()
    }
    @Test @MainActor func accessibilityExpansionAndMapReplacementPreserveHorizontalPosition() async throws {
        let lines = (1...120).map { "// Context line \($0) " + String(repeating: "x", count: 40) }
        var changed = lines; changed[59] = "changed"
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: lines.joined(separator: "\n")),
                                                          newFile: .init(name: "f.txt", contents: changed.joined(separator: "\n")))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        window.contentView = view; view.render(document)
        let canvas = try #require(view.scrollView.documentView)
        #expect(view.scrollView.contentView.bounds.minX == 0)
        let action = try #require(canvas.accessibilityCustomActions()?.first { $0.name == "Expand all context at hunk 1" }?.handler)
        #expect(action())
        view.layoutSubtreeIfNeeded()
        #expect(view.scrollView.contentView.bounds.minX == 0)
        let snapshot = view.getExpandedHunksMap()
        view.restoreEditorScrollOrigin(.init(x: 120, y: 0))
        #expect(view.scrollView.contentView.bounds.minX == 120)
        view.setExpandedHunksMap([:]); view.setExpandedHunksMap(snapshot)
        #expect(view.scrollView.contentView.bounds.minX == 120)
        view.cleanUp()
    }
    @Test(arguments: [DiffOverflow.scroll, .wrap]) @MainActor
    func reviewRecyclesFullReplacementAndUpdatesOffsets(_ overflow: DiffOverflow) async throws {
        let document = try await prepared()
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 200))
        var options = DiffRenderOptions(); options.overflow = overflow
        func settle() async throws {
            view.layoutSubtreeIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while view.isPreparingWrappedLayout && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5)); view.layoutSubtreeIfNeeded()
            }
            #expect(!view.isPreparingWrappedLayout)
        }
        try view.setItems((0..<40).map { .init(id: "file-\($0)", document: document) }, options: options)
        try await settle()
        let first = try #require(view.getRenderedItems().first { $0.id == "file-0" }?.instance)
        let initialTop = try #require(view.getTopForItem("file-1"))
        let regions = [0: HunkExpansionRegion(fromStart: 20)]
        first.setExpandedHunksMap(regions)
        try await settle()
        #expect((view.getTopForItem("file-1") ?? 0) > initialTop)
        #expect(view.scrollToItem("file-39"))
        view.layoutSubtreeIfNeeded()
        #expect(!view.getRenderedItems().contains { $0.id == "file-0" })
        #expect(view.scrollToItem("file-0"))
        view.layoutSubtreeIfNeeded()
        let restored = try #require(view.getRenderedItems().first { $0.id == "file-0" }?.instance)
        #expect(restored.getExpandedHunksMap() == regions)
        #expect(try restored.isLineRenderable(1))
        restored.setExpandedHunksMap([:])
        try await settle()
        #expect(abs((view.getTopForItem("file-1") ?? 0) - initialTop) < 0.1)
        view.cleanUp()
    }
}

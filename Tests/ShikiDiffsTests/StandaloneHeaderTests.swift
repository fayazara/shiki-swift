import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct StandaloneHeaderTests {
    @MainActor private func fixture() async throws -> (NativeDiffView, HighlightedDiff, DiffRenderOptions) {
        let file = FileContents(name: "f.txt", contents: String(repeating: "source line\n", count: 100))
        var options = DiffRenderOptions(); options.expandUnchanged = true; options.diffStyle = .unified
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file, options: options)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 240))
        view.render(document, options: options)
        return (view, document, options)
    }
    @Test @MainActor func scrollingDefaultAndPinnedModePreserveSourceAnchor() async throws {
        let (view, document, initial) = try await fixture()
        let header = try #require(view.subviews.compactMap { $0 as? DiffHeaderView }.first)
        #expect(!initial.stickyHeader)
        #expect(view.scrollView.contentInsets.top == 44)
        #expect(view.editorScrollOrigin == .zero && header.frame.maxY == 240)
        #expect(view.scrollView.frame.height == 240)
        view.restoreEditorScrollOrigin(.init(x: 0, y: 24))
        #expect(header.frame.minY == 220 && !header.isHidden)
        view.restoreEditorScrollOrigin(.init(x: 0, y: 164))
        #expect(header.isHidden && view.scrollView.contentView.bounds.minY == 120)
        var options = initial; options.stickyHeader = true
        view.render(document, options: options)
        #expect(view.scrollView.contentInsets.top == 0 && view.scrollView.frame.height == 196)
        #expect(!header.isHidden && header.frame.maxY == 240)
        #expect(view.scrollView.contentView.bounds.minY == 120)
        view.restoreEditorScrollOrigin(.init(x: 0, y: 200))
        #expect(!header.isHidden && header.frame.maxY == 240)
        options.stickyHeader = false; view.render(document, options: options)
        #expect(header.isHidden && view.scrollView.contentView.bounds.minY == 200)
        view.restoreEditorScrollOrigin(.zero)
        #expect(!header.isHidden && header.frame.maxY == 240)
        options.disableFileHeader = true; view.render(document, options: options)
        #expect(header.isHidden && view.scrollView.contentInsets.top == 0)
    }
    @Test @MainActor func changingCustomHeaderHeightKeepsPartialVisibilityAndShortDocumentsFit() async throws {
        let (view, _, _) = try await fixture()
        let custom = NSView(frame: .init(x: 0, y: 0, width: 600, height: 80))
        view.headerRenderers.renderCustomHeader = { _ in custom }; view.layoutSubtreeIfNeeded()
        let header = try #require(view.subviews.compactMap { $0 as? DiffHeaderView }.first)
        #expect(view.scrollView.contentInsets.top == 80 && view.editorScrollOrigin.y == 0)
        view.restoreEditorScrollOrigin(.init(x: 0, y: 20))
        custom.setFrameSize(.init(width: 600, height: 120)); view.layoutSubtreeIfNeeded()
        #expect(view.scrollView.contentInsets.top == 120 && view.editorScrollOrigin.y == 20)
        #expect(header.frame.minY == 140)
        let empty = FileContents(name: "empty.txt", contents: "")
        let short = try await DiffHighlighter().prepare(oldFile: empty, newFile: empty)
        view.render(short)
        #expect(view.editorScrollOrigin.y == 0)
        let clip = view.scrollView.contentView
        let constrained = clip.constrainBoundsRect(.init(origin: .init(x: 0, y: 1000), size: clip.bounds.size))
        #expect(constrained.minY == -view.scrollView.contentInsets.top)
    }
    @Test @MainActor func editorViewportSnapshotAndSearchIncludeScrollingHeader() async throws {
        let (view, document, options) = try await fixture()
        let editor = try view.beginEditing(); await editor.waitForRendering()
        try editor.setViewState(.init(view: .init(scrollLeft: 0, scrollTop: 24)))
        #expect(editor.getViewState().view?.scrollTop == 24)
        #expect(view.scrollView.contentView.bounds.minY == -20)
        let snapshot = editor.getEditState()
        #expect(snapshot.scrollOrigin?.y == 24)
        _ = editor.openSearch(); view.layoutSubtreeIfNeeded()
        let header = try #require(view.subviews.compactMap { $0 as? DiffHeaderView }.first)
        #expect(!header.isHidden && header.frame.maxY > view.bounds.maxY)
        #expect(view.scrollView.frame.height < view.bounds.height)
        _ = try await editor.complete(.discard)
        let restored = NativeDiffView(frame: view.frame); restored.render(document, options: options)
        let next = try restored.beginEditing(initialState: .init(snapshot)); await next.waitForRendering()
        #expect(next.getViewState().view?.scrollTop == 24)
        #expect(restored.scrollView.contentView.bounds.minY == -20)
        _ = try await next.complete(.discard)
    }
}

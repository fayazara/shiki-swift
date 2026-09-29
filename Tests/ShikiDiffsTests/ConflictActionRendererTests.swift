import AppKit
import SwiftUI
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct ConflictActionRendererTests {
    @MainActor private final class Content: NSView {
        var height: CGFloat = 60
        override var intrinsicContentSize: NSSize { .init(width: 300, height: height) }
    }
    private func fixture() throws -> MergeConflictResult {
        try parseMergeConflictDiffFromFile(.init(name: "f.swift", contents: "before\n<<<<<<< HEAD\nlet value = 1\n=======\nlet value = 2\n>>>>>>> branch\nafter\n"))
    }
    @Test @MainActor func largeConflictFilesOnlyMountVisibleControls() async throws {
        let source = (0..<100).map { "line \($0)\n<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> branch\n" }.joined()
        let parsed = try parseMergeConflictDiffFromFile(.init(name: "many.txt", contents: source))
        let document = try await DiffHighlighter().prepare(parsed.fileDiff)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.mergeConflictActionsType = .custom
        var callbacks: [Int: DiffConflictActionRenderer.Resolve] = [:]
        var creations = 0
        view.conflictActionRenderer = DiffConflictActionRenderer { action, resolve in
            creations += 1; callbacks[action.conflictIndex] = resolve
            return Content(frame: .zero)
        }
        view.mergeConflictActions = parsed.actions
        view.onResolveConflict = { _, _ in }
        view.render(document, options: options, markerRows: parsed.markerRows)
        #expect(creations > 0 && creations < 5)
        let first = try #require(callbacks[0])
        #expect(first(.both))
        view.scrollToRow(view.rowCount - 1); view.layoutSubtreeIfNeeded()
        #expect(!first(.both))
        #expect(creations < 10)
        #expect(view.scrollView.documentView!.subviews.filter { $0 is Content }.count < 5)
    }
    @Test func markerMetadataUsesExactSourceText() throws {
        var first = try fixture().actions[0], second = first
        first.markerLines.start = "<<<<<<< é"
        second.markerLines.start = "<<<<<<< e\u{301}"
        #expect(first != second)
        first.markerLines.start = second.markerLines.start
        #expect(first == second)
    }
    @Test @MainActor func customActionsRetainMetadataMeasureHeightAndRejectStaleControls() async throws {
        let parsed = try fixture(), document = try await DiffHighlighter().prepare(parsed.fileDiff)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 350), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 350)); window.contentView = view
        var options = DiffRenderOptions(); options.mergeConflictActionsType = .custom; options.disableFileHeader = true
        var calls = 0, payload: MergeConflictDiffAction?, resolve: DiffConflictActionRenderer.Resolve?, content: Content?
        var received: (Int, DiffResolution)?
        view.onResolveConflict = { received = ($0, $1) }
        view.mergeConflictActions = parsed.actions
        view.conflictActionRenderer = DiffConflictActionRenderer { action, callback in
            calls += 1; payload = action; resolve = callback
            let result = Content(frame: .zero); content = result; return result
        }
        view.render(document, options: options, markerRows: parsed.markerRows)
        #expect(payload == parsed.actions.first)
        #expect(calls == 1)
        let canvas = try #require(view.scrollView.documentView)
        #expect(canvas.accessibilityCustomActions() == nil)
        let plan = DiffRenderPlan(diff: parsed.fileDiff, options: options, markerRows: parsed.markerRows)
        let row = try #require(plan.rows.firstIndex { if case .conflictMarker(_, .start) = $0.kind { return true }; return false })
        #expect(view.measuredRowHeights.height(of: row) == 80)
        view.invalidateConflictActionLayout()
        #expect(calls == 1)
        let perform = try #require(resolve)
        #expect(perform(.both)); #expect(received?.0 == 0 && received?.1 == .both)
        content?.height = 90
        view.invalidateConflictActionLayout()
        #expect(view.measuredRowHeights.height(of: row) == 110)
        options.mergeConflictActionsType = .none
        view.render(document, options: options, markerRows: parsed.markerRows)
        #expect(content?.superview == nil)
        #expect(!perform(.additions))
        options.mergeConflictActionsType = .custom
        view.render(document, options: options, markerRows: parsed.markerRows)
        #expect(calls == 2)
        let replacement = try #require(resolve)
        view.mergeConflictActions = []
        #expect(!replacement(.deletions))
        #expect(content?.superview == nil)
        #expect(view.measuredRowHeights.height(of: row) == 20)
        view.conflictActionRenderer = DiffConflictActionRenderer { _, _ in nil }
        view.mergeConflictActions = parsed.actions
        #expect(view.measuredRowHeights.height(of: row) == 48)
    }
    @Test @MainActor func reentrantRendererDoesNotInstallOldControls() async throws {
        let parsed = try fixture(), document = try await DiffHighlighter().prepare(parsed.fileDiff)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 350))
        var options = DiffRenderOptions(); options.mergeConflictActionsType = .custom
        var orphan: Content?
        view.mergeConflictActions = parsed.actions
        view.conflictActionRenderer = DiffConflictActionRenderer { [weak view] _, _ in
            let result = Content(frame: .zero); orphan = result
            view?.mergeConflictActions = []
            return result
        }
        view.render(document, options: options, markerRows: parsed.markerRows)
        #expect(orphan != nil && orphan?.superview == nil)
    }
    @Test @MainActor func swiftUIAdapterForwardsParsedActionsAndRenderer() async throws {
        let parsed = try fixture(), document = try await DiffHighlighter().prepare(parsed.fileDiff)
        var options = DiffRenderOptions(); options.mergeConflictActionsType = .custom
        let renderer = DiffConflictActionRenderer { _, _ in Content(frame: .zero) }
        let host = NSHostingView(rootView: FileDiffView(document: document, options: options, markerRows: parsed.markerRows, conflictActionRenderer: renderer, mergeConflictActions: parsed.actions))
        host.frame = .init(x: 0, y: 0, width: 800, height: 400); host.layoutSubtreeIfNeeded()
        func find(_ root: NSView) -> NativeDiffView? {
            if let view = root as? NativeDiffView { return view }
            return root.subviews.lazy.compactMap(find).first
        }
        let view = try #require(find(host))
        #expect(view.conflictActionRenderer === renderer)
        #expect(view.mergeConflictActions == parsed.actions)
        #expect(view.scrollView.documentView?.subviews.contains { $0 is Content } == true)
    }
}

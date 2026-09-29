import AppKit
import SwiftUI
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct SeparatorRendererTests {
    @MainActor private final class Content: NSView {
        var preferredHeight: CGFloat = 40
        var heightDependsOnWidth = false
        override var intrinsicContentSize: NSSize {
            .init(width: 100, height: preferredHeight + (heightDependsOnWidth && frame.width < 400 ? 30 : 0))
        }
    }
    private func document() async throws -> HighlightedDiff {
        let old = (0..<10_000).map { "line \($0)\n" }.joined()
        var lines = old.components(separatedBy: "\n")
        for index in stride(from: 200, to: 10_000, by: 400) { lines[index] = "changed \(index)" }
        return try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: old),
            newFile: .init(name: "f.txt", contents: lines.joined(separator: "\n")))
    }
    @Test @MainActor func customColumnsExpandAndUnmountWithBoundedViews() async throws {
        let document = try await document()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 900, height: 250))
        window.contentView = view
        var options = DiffRenderOptions(); options.hunkSeparators = .custom; options.disableFileHeader = true
        var calls: [HunkData] = []
        var actions: [String: DiffSeparatorRenderer.Expand] = [:]
        view.separatorRenderer = DiffSeparatorRenderer { data, expand in
            calls.append(data); actions[data.slotName] = expand
            let content = Content(frame: .zero)
            content.preferredHeight = data.type == .additions ? 60 : 40
            return content
        }
        view.render(document, options: options); view.layoutSubtreeIfNeeded()
        let canvas = try #require(view.scrollView.documentView)
        let initial = canvas.subviews.compactMap { $0 as? Content }
        #expect(initial.count > 0 && initial.count < 12)
        #expect(calls.contains { $0.type == .deletions } && calls.contains { $0.type == .additions })
        #expect(initial.allSatisfy { $0.frame.height == 60 })
        let callCount = calls.count
        view.layoutSubtreeIfNeeded(); view.invalidateSeparatorLayout()
        #expect(calls.count == callCount)
        let first = try #require(calls.first)
        let expand = try #require(actions[first.slotName])
        let before = view.rowCount
        #expect(!expand(.up)) // Leading gap only expands downward.
        #expect(expand(.down))
        #expect(view.rowCount > before)
        #expect(!expand(.down)) // Metadata changed: retained old controls are inert.
        view.scrollToRow(view.rowCount - 1); view.layoutSubtreeIfNeeded()
        #expect(initial.allSatisfy { $0.superview == nil })
        #expect(canvas.subviews.compactMap { $0 as? Content }.count < 12)
        options.diffStyle = .unified
        view.render(document, options: options); view.layoutSubtreeIfNeeded()
        #expect(calls.contains { $0.type == .unified })
        let latest = Array(actions.values)
        view.separatorRenderer = nil
        #expect(canvas.subviews.compactMap { $0 as? Content }.isEmpty)
        #expect(latest.allSatisfy { !$0(.all) })
    }

    @Test @MainActor func rendererReplacementAndReentrancyDiscardStaleViews() async throws {
        let document = try await document()
        let empty = try await DiffHighlighter().prepare(oldFile: .init(name: "empty", contents: ""), newFile: .init(name: "empty", contents: ""))
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 400))
        var options = DiffRenderOptions(); options.hunkSeparators = .custom
        var orphan: Content?
        var didReplace = false
        view.separatorRenderer = DiffSeparatorRenderer { [weak view] _, _ in
            let result = Content(frame: .zero); orphan = result
            if !didReplace {
                didReplace = true
                view?.render(empty, options: options)
            }
            return result
        }
        view.render(document, options: options); view.layoutSubtreeIfNeeded()
        #expect(didReplace)
        #expect(view.displayedDocument?.id == empty.id)
        #expect(orphan?.superview == nil)
        #expect(view.rowCount == 0)
    }

    @Test @MainActor func representableRetainsRendererAndCustomHeight() async throws {
        let document = try await document()
        var options = DiffRenderOptions(); options.hunkSeparators = .custom
        var content: Content?
        let renderer = DiffSeparatorRenderer { _, _ in
            let result = Content(frame: .zero); content = result; return result
        }
        let host = NSHostingView(rootView: FileDiffView(document: document, options: options, separatorRenderer: renderer))
        host.frame = .init(x: 0, y: 0, width: 900, height: 400)
        host.layoutSubtreeIfNeeded()
        func find(_ root: NSView) -> NativeDiffView? {
            if let result = root as? NativeDiffView { return result }
            return root.subviews.lazy.compactMap(find).first
        }
        let view = try #require(find(host))
        #expect(view.separatorRenderer === renderer)
        let mounted = try #require(content)
        mounted.preferredHeight = 90
        view.invalidateSeparatorLayout()
        #expect(mounted.frame.height == 90)
        host.rootView = FileDiffView(document: document, options: options, separatorRenderer: renderer)
        host.layoutSubtreeIfNeeded()
        #expect(mounted.superview != nil)
    }

    @Test @MainActor func reviewMountsCustomSeparatorsOnlyForVisibleFiles() async throws {
        let document = try await document()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 900, height: 400))
        window.contentView = view
        var creations = 0
        view.separatorRenderer = DiffSeparatorRenderer { _, _ in
            creations += 1
            let content = Content(frame: .zero); content.preferredHeight = 80
            content.heightDependsOnWidth = true; return content
        }
        var options = DiffRenderOptions(); options.hunkSeparators = .custom
        view.render(Array(repeating: document, count: 100), options: options)
        view.layoutSubtreeIfNeeded()
        #expect(creations > 0 && creations < 20)
        #expect(view.mountedFileCount < 5)
        view.scrollToFile(at: 90); view.layoutSubtreeIfNeeded()
        #expect(creations < 40)
        #expect(view.mountedFileCount < 5)
        view.scrollToFile(at: 0); view.layoutSubtreeIfNeeded()
        #expect(creations < 60)
        #expect(view.scrollView.contentView.bounds.minY.isFinite)
        window.setContentSize(.init(width: 600, height: 400)); view.layoutSubtreeIfNeeded()
        func contents(_ root: NSView) -> [Content] {
            (root as? Content).map { [$0] } ?? root.subviews.flatMap(contents)
        }
        let visibleContent = contents(view)
        #expect(!visibleContent.isEmpty)
        #expect(visibleContent.allSatisfy { $0.frame.height == 110 })
        for content in visibleContent { content.preferredHeight = 100 }
        view.invalidateSeparatorLayout(); view.layoutSubtreeIfNeeded()
        #expect(visibleContent.filter { $0.superview != nil }.allSatisfy { $0.frame.height == 130 })
    }
}

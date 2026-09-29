import Testing
import AppKit
@testable import ShikiDiffs

@Suite struct WrapTests {
    @Test @MainActor func wrappedFragmentsReconstructUnicodeSource() async throws {
        let source = "let greeting = \"👩🏽‍💻 café こんにちは\"; " + String(repeating: "many words ", count: 20) + "\n"
        let diff = try parseDiffFromFile(.init(name: "f.swift", contents: source), .init(name: "f.swift", contents: source))
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let wrapped = try await DiffWrapLayout.shared.layout(plan: .init(diff: diff), diff: diff, width: 220, fontName: font.fontName, fontSize: 13)
        #expect(wrapped.rows.count > 5)
        let ns = cleanLastNewline(source) as NSString
        let reconstructed = wrapped.rows.compactMap { $0.newRange.map { ns.substring(with: $0) } }.joined()
        #expect(reconstructed.utf16.elementsEqual(cleanLastNewline(source).utf16))
        let continuations = wrapped.rows.dropFirst().allSatisfy { $0.isContinuation }
        #expect(continuations)
        #expect(wrapped.visibleRange(y: 100, height: 300, lineHeight: 22).count < 30)
    }
    @Test func contextExpandsByConfiguredBatch() throws {
        let old = (0..<500).map { "line \($0)\n" }.joined()
        let diff = try parseDiffFromFile(.init(name: "f", contents: old), .init(name: "f", contents: old.replacingOccurrences(of: "line 400\n", with: "changed\n")))
        let collapsed = DiffRenderPlan(diff: diff)
        let firstBatch = DiffRenderPlan(diff: diff, expandedLineCounts: [0: 100])
        #expect(firstBatch.rows.count == collapsed.rows.count + 100)
        #expect(firstBatch.rows.contains(where: { if case .separator(let hidden, let hi) = $0.kind { return hi == 0 && hidden == 296 }; return false }))
        let fromEnd = DiffRenderPlan(diff: diff, expandedRegions: [0: .init(fromEnd: 100)])
        #expect(fromEnd.rows.first?.kind == .separator(hidden: 296, hunk: 0))
        #expect(fromEnd.rows[1].newNumber == 297)
        let both = DiffRenderPlan(diff: diff, expandedRegions: [0: .init(fromStart: 300, fromEnd: 300)])
        #expect(both.rows.filter { $0.newNumber.map { $0 <= 396 } ?? false }.count == 396)
    }
}

@Suite(.serialized) struct MultiFileWrapTests {
    @Test(arguments: [0.0, 600.0]) @MainActor func wrappingComputesWholeReviewGeometryOffMainActor(overscroll: Double) async throws {
        let worker = DiffHighlighter()
        let text = "let values = [" + (0..<50).map(String.init).joined(separator: ", ") + "]\n"
        let prepared = try await worker.prepare(oldFile: .init(name: "f.swift", contents: text), newFile: .init(name: "f.swift", contents: text))
        var options = DiffRenderOptions(); options.overflow = .wrap
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeCodeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.overscrollSize = CGFloat(overscroll)
        window.contentView = view; view.render(Array(repeating: prepared, count: 100), options: options)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.isPreparingWrappedLayout)
        #expect(view.scrollView.documentView!.frame.height > 15_000)
        view.scrollToFile(at: 90); #expect(view.mountedFileCount < (overscroll == 0 ? 8 : 20))
        for width: CGFloat in [500, 1200, 650, 1000, 450, 900] {
            window.setContentSize(.init(width: width, height: 600)); view.layoutSubtreeIfNeeded()
            #expect(view.isPreparingWrappedLayout)
            await Task.yield()
        }
        let resizeDeadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < resizeDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.isPreparingWrappedLayout)
        let reference = NativeCodeView(frame: .init(x: 0, y: 0, width: 900, height: 600))
        reference.render(Array(repeating: prepared, count: 100), options: options)
        let referenceDeadline = ContinuousClock.now + .seconds(5)
        while reference.isPreparingWrappedLayout && ContinuousClock.now < referenceDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!reference.isPreparingWrappedLayout)
        #expect(view.scrollView.documentView?.frame.height == reference.scrollView.documentView?.frame.height)
        view.scrollToFile(at: 90); reference.scrollToFile(at: 90)
        #expect(abs(view.scrollView.contentView.bounds.minY - reference.scrollView.contentView.bounds.minY) < 0.01)
        #expect(view.mountedFileCount < (overscroll == 0 ? 8 : 20))
        let position = view.scrollView.contentView.bounds.origin
        view.overscrollSize = 0
        #expect(view.mountedFileCount == reference.mountedFileCount)
        #expect(view.scrollView.contentView.bounds.origin == position)
        window.close()
    }
}

@Suite(.serialized) struct NativeWrapTests {
    @Test @MainActor func wrappedNativeViewportDrawsFragments() async throws {
        let worker = DiffHighlighter()
        let source = "let message = \"👩🏽‍💻 café こんにちは\"; " + String(repeating: "word ", count: 75) + "\n"
        let prepared = try await worker.prepare(oldFile: .init(name: "f.swift", contents: source), newFile: .init(name: "f.swift", contents: source.replacingOccurrences(of: "café", with: "hello")))
        var options = DiffRenderOptions(); options.overflow = .wrap
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeDiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window.contentView = view; view.render(prepared, options: options)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while view.rowCount < 5 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.rowCount > 5)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: "/tmp/swift-diffs-wrap.png")) }
        #expect(view.scrollView.documentView!.frame.width == view.scrollView.contentSize.width)
        view.selectLines(.init(side: .deletions, startLine: 1, endLine: 1))
        #expect(view.selectedText() == source)
        window.close()
    }
}

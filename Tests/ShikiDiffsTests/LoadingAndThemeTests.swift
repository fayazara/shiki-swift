import Testing
import AppKit
@testable import ShikiDiffs

private actor LoadGate {
    private var requests: [CheckedContinuation<LoadedDiffFiles, any Error>?] = []
    var count: Int { requests.count }
    func load(_ diff: FileDiffMetadata) async throws -> LoadedDiffFiles {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    func finish(_ index: Int, _ files: LoadedDiffFiles) { requests[index]?.resume(returning: files); requests[index] = nil }
    func fail(_ index: Int) { requests[index]?.resume(throwing: DiffError.invalidHydration); requests[index] = nil }
}
@Suite(.serialized) struct LoadingAndThemeTests {
    @Test @MainActor func unknownTrailingContextTransitionsThroughHydration() async throws {
        let partial = try #require(try processFile("--- f\n+++ f\n@@ -1 +1 @@\n-old\n+new\n"))
        let prepared = try await DiffHighlighter().prepare(partial)
        let gate = LoadGate()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render(prepared, options: options)
        #expect(view.rowCount == 1)
        view.loadDiffFiles = { try await gate.load($0) }
        view.layoutSubtreeIfNeeded()
        try await waitUntil { await gate.count == 1 }
        #expect(view.rowCount == 2)
        let canvas = try #require(view.scrollView.documentView)
        let action = try #require(canvas.accessibilityCustomActions()?.first { $0.name == "Expand up context at hunk 2" })
        let stale = try #require(action.handler)
        view.selectLines(.init(side: .additions, startLine: 1, endLine: 1))
        await gate.finish(0, .init(oldFile: .init(name: "f", contents: "old\n"), newFile: .init(name: "f", contents: "new\n")))
        try await waitUntil { !view.isLoadingFiles }
        #expect(view.displayedDocument?.diff.isPartial == false)
        #expect(view.rowCount == 1)
        #expect(canvas.accessibilityCustomActions() == nil)
        #expect(!stale())
        #expect(view.selectedText() == "new\n")
    }

    @Test func labMixUsesPerceptualMidpointAndPremultipliedAlpha() throws {
        let middle = try #require(NSColor.diffLabMix(.black, .white, fraction: 0.5).usingColorSpace(.sRGB))
        #expect(abs(middle.redComponent - 0.4663) < 0.015)
        #expect(abs(middle.redComponent - middle.greenComponent) < 0.001)
        let alpha = NSColor.diffLabMix(.clear, .red, fraction: 0.25)
        #expect(abs(alpha.alphaComponent - 0.25) < 0.001)
    }
    @MainActor private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await predicate())
    }
    @Test @MainActor func loaderDeduplicatesAndIgnoresLateSourceResults() async throws {
        let worker = DiffHighlighter(), gate = LoadGate()
        func partial(_ name: String) throws -> FileDiffMetadata {
            try #require(try processFile("--- \(name)\n+++ \(name)\n@@ -3 +3 @@\n-old\n+new\n", throwOnError: true))
        }
        let a = try await worker.prepare(partial("a.txt")), b = try await worker.prepare(partial("b.txt"))
        let view = NativeDiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.loadDiffFiles = { try await gate.load($0) }
        view.render(a); view.render(a)
        try await waitUntil { await gate.count == 1 }
        view.render(b)
        try await waitUntil { await gate.count == 2 }
        let files = LoadedDiffFiles(oldFile: .init(name: "b.txt", contents: "one\ntwo\nold\nfour\n"), newFile: .init(name: "b.txt", contents: "one\ntwo\nnew\nfour\n"))
        await gate.finish(0, files)
        try await Task.sleep(for: .milliseconds(10))
        #expect(view.isLoadingFiles); #expect(view.displayedDocument?.diff.name == "b.txt")
        var options = DiffRenderOptions(); options.theme = "pierre-light"
        view.render(b, options: options)
        view.selectLines(.init(side: .additions, startLine: 3, endLine: 3))
        await gate.finish(1, files)
        try await waitUntil { !view.isLoadingFiles }
        #expect(view.displayedDocument?.diff.isPartial == false)
        #expect(view.displayedDocument?.palette.isLight == true)
        #expect(view.selectedText() == "new\n")
        view.render(b, options: options)
        #expect(view.displayedDocument?.diff.isPartial == false)
        #expect(await gate.count == 2)
    }
    @Test @MainActor func loaderFailureCanRetryAndNewFilesDoNotLoad() async throws {
        let partial = try #require(try processFile("--- f\n+++ f\n@@ -1 +1 @@\n-old\n+new\n"))
        let prepared = try await DiffHighlighter().prepare(partial)
        let gate = LoadGate(), view = NativeDiffView(frame: .zero)
        view.loadDiffFiles = { try await gate.load($0) }; view.render(prepared)
        try await waitUntil { await gate.count == 1 }; await gate.fail(0)
        try await waitUntil { view.fileLoadError != nil }
        view.loadDiffFiles = { try await gate.load($0) }
        #expect(await gate.count == 1)
        view.retryLoadingFiles(); try await waitUntil { await gate.count == 2 }
        await gate.finish(1, .init(oldFile: .init(name: "f", contents: "old\n"), newFile: .init(name: "f", contents: "new\n")))
        try await waitUntil { !view.isLoadingFiles }; #expect(view.fileLoadError == nil)
        let newFile = try #require(try processFile("diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1 @@\n+new\n"))
        view.render(try await DiffHighlighter().prepare(newFile))
        #expect(!view.isLoadingFiles); #expect(await gate.count == 2)
    }
    @Test @MainActor func appearanceSwitchUsesPreparedTokensAndPreservesSelection() async throws {
        let file = FileContents(name: "f.swift", contents: (0..<200).map { "let a\($0) = \($0)\n" }.joined())
        let worker = DiffHighlighter(), document = try await worker.prepareThemes(oldFile: file, newFile: file)
        let stats = await worker.cacheStatistics
        let view = NativeThemedDiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.themeAppearance = .dark; view.render(document)
        view.diffView.selectText(.init(side: .additions, anchor: .init(line: 50, character: 4), head: .init(line: 50, character: 7)))
        view.diffView.scrollToLine(50)
        let y = view.diffView.scrollView.contentView.bounds.minY
        view.themeAppearance = .light
        #expect(view.diffView.displayedDocument?.palette.isLight == true)
        #expect(view.diffView.selectedText() == "a50")
        #expect(view.diffView.scrollView.contentView.bounds.minY == y)
        view.themeAppearance = .system; view.appearance = NSAppearance(named: .darkAqua); view.viewDidChangeEffectiveAppearance()
        #expect(view.diffView.displayedDocument?.palette.isLight == false)
        #expect(await worker.cacheStatistics.misses == stats.misses)
    }
}

import AppKit
import Shiki
import Testing
@testable import ShikiDiffs

struct PreviewTests {
    @Test func cancellingLargeIdenticalFileAllowsNextPreparation() async throws {
        let worker = DiffHighlighter()
        try await worker.preload(languages: ["json"])
        let source = "[\n" + (0..<30_000).map { "{\"id\":\($0),\"enabled\":true,\"name\":\"Example item\"}" }.joined(separator: ",\n") + "\n]"
        let file = FileContents(name: "large.json", contents: source)
        let diff = try parseDiffFromFile(file, file)
        let task = Task.detached { try await worker.prepare(diff) }
        try await Task.sleep(for: .milliseconds(50))
        let cancelled = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled large preparation completed") }
        catch is CancellationError { }
        let next = FileContents(name: "small.json", contents: "{\"ok\":true}")
        let result = try await worker.prepare(oldFile: next, newFile: next)
        #expect(result.diff.name == "small.json")
        #expect(await worker.cacheStatistics.entries == 1)
        print("IDENTICAL_JSON_CANCEL_AND_REPLACE elapsed=\(cancelled.duration(to: .now))")
    }

    @Test func highlightedPrefixMatchesCompleteGrammarOutput() async throws {
        let source = "/* open\r\n" + String(repeating: "comment 😀\r\n", count: 80) + "*/\r\nlet value = 42\r\n"
        let file = FileContents(name: "f.swift", contents: source)
        let diff = try parseDiffFromFile(file, file)
        let worker = DiffHighlighter()
        let preview = try await worker.preparePreview(diff, highlightedLineCount: 64)
        let full = try await worker.prepare(diff, sourceID: preview.sourceID)
        #expect(preview.oldTokens.count == 64)
        #expect(preview.newTokens == Array(full.newTokens.prefix(64)))
        #expect(preview.oldTokens == Array(full.oldTokens.prefix(64)))
        #expect(preview.diff.additionLines == full.diff.additionLines)
        let huge = FileContents(name: "f.swift", contents: String(repeating: "x", count: 70_000))
        let bounded = try await worker.preparePreview(parseDiffFromFile(huge, huge), highlightedLineCount: Int.max)
        #expect(bounded.newTokens.isEmpty && bounded.oldTokens.isEmpty)
    }

    @Test func previewsMatchBuiltInAndCustomThemeColors() async throws {
        let file = FileContents(name: "f.swift", contents: "let value = 42\n")
        let diff = try parseDiffFromFile(file, file)
        let worker = DiffHighlighter()
        await worker.registerCustomTheme("preview-light") {
            .init(name: "preview-light", type: .light, colors: [
                "editor.background": "#faf4ed", "editor.foreground": "#123456",
                "gitDecoration.addedResourceForeground": "#117733",
                "gitDecoration.deletedResourceForeground": "#cc3311",
                "gitDecoration.modifiedResourceForeground": "#3366cc"
            ])
        }
        for name in ["pierre-dark", "pierre-light", "preview-light"] {
            var options = DiffRenderOptions(); options.theme = name
            let preview = try await worker.preparePreview(diff, options: options)
            let highlighted = try await worker.prepare(diff, options: options, sourceID: preview.sourceID)
            #expect(preview.foreground == highlighted.foreground)
            #expect(preview.background == highlighted.background)
            #expect(preview.palette == highlighted.palette)
            if name == "preview-light" {
                #expect(preview.palette.isLight)
                #expect(preview.palette.modified == "#3366cc")
            }
        }
    }
    @Test func cancelledPreparationDoesNotTouchTokenCache() async throws {
        let worker = DiffHighlighter()
        let file = FileContents(name: "f.swift", contents: String(repeating: "let value = 1\n", count: 1000))
        let diff = try parseDiffFromFile(file, file)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.prepare(diff)
        }
        do { _ = try await task.value; Issue.record("Cancelled preparation completed") }
        catch is CancellationError { }
        let stats = await worker.cacheStatistics
        #expect(stats.hits == 0 && stats.misses == 0 && stats.entries == 0)
    }
    @Test(arguments: [0, 64]) @MainActor func megabytePreviewBenchmark(highlightedLines: Int) async throws {
        let row = "    { \"id\": 123, \"name\": \"Example item\", \"enabled\": true, \"region\": \"ap-south-1\", \"score\": 42 },\n"
        let source = "[\n" + String(repeating: row, count: 12_000) + "null\n]\n"
        let file = FileContents(name: "catalog.json", contents: source)
        #expect(source.utf8.count > 1_000_000)
        let start = ContinuousClock.now
        let diff = try parseDiffFromFile(file, file)
        let parsed = ContinuousClock.now
        let preview = try await DiffHighlighter().preparePreview(diff, highlightedLineCount: highlightedLines)
        let prepared = ContinuousClock.now
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 1100, height: 650)); window.contentView = view
        view.render(preview); view.layoutSubtreeIfNeeded()
        let canvas = try #require(view.scrollView.documentView)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1100, pixelsHigh: 650, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let paintStart = ContinuousClock.now
        canvas.draw(.init(x: 0, y: 0, width: 1100, height: 650))
        let painted = ContinuousClock.now
        #expect(view.metrics.drawnRows > 0 && view.metrics.drawnRows < 50)
        #expect(view.metrics.cachedLines < 100)
        print("PREVIEW_BENCHMARK highlightedLines=\(highlightedLines) bytes=\(source.utf8.count) parse=\(start.duration(to: parsed)) prepare=\(parsed.duration(to: prepared)) paint=\(paintStart.duration(to: painted)) totalIncludingWindow=\(start.duration(to: painted))")
    }
    @Test @MainActor func highlightingPreviewPreservesScrollAndSelection() async throws {
        let file = FileContents(name: "f.swift", contents: (0..<1000).map { "let value\($0) = \($0)\n" }.joined())
        let diff = try parseDiffFromFile(file, file)
        let worker = DiffHighlighter()
        let preview = try await worker.preparePreview(diff)
        #expect(preview.oldTokens.isEmpty && preview.newTokens.isEmpty)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.render(preview); view.scrollToLine(500)
        view.selectLines(.init(side: .additions, startLine: 500, endLine: 502))
        let scroll = view.scrollView.contentView.bounds.origin, selection = view.selectedLines
        let highlighted = try await worker.prepare(diff, sourceID: preview.sourceID)
        #expect(highlighted.id != preview.id && highlighted.sourceID == preview.sourceID)
        #expect(!highlighted.newTokens.isEmpty)
        #expect(highlighted.foreground == preview.foreground && highlighted.background == preview.background)
        #expect(highlighted.palette == preview.palette)
        view.render(highlighted)
        #expect(view.scrollView.contentView.bounds.origin == scroll)
        #expect(view.selectedLines == selection)
    }
}

import Testing
import AppKit
@testable import ShikiDiffs

@Suite(.serialized) struct ViewportTests {
    @Test @MainActor func demoJSONChangesSurviveScrollingAndLayoutSwitches() async throws {
        // Match the demo fixture, including its sparse edits on both sides.
        var rows = ["{\n  \"items\": [\n"]
        for index in 0..<12_000 {
            rows.append("    { \"id\": \(index), \"name\": \"Item \(index)\", \"enabled\": true, \"region\": \"ap-south-1\", \"score\": 42 }" + (index == 11_999 ? "\n" : ",\n"))
        }
        rows.append("  ]\n}\n")
        let old = rows.joined()
        for index in stride(from: 42, to: 12_000, by: 701) {
            rows[index] = rows[index].replacingOccurrences(of: "true", with: "false").replacingOccurrences(of: "42", with: "99")
        }
        let new = rows.joined()
        #expect(old.utf8.count > 1_000_000)
        let prepared = try await DiffHighlighter().prepare(
            oldFile: .init(name: "fixtures/catalog.json", contents: old),
            newFile: .init(name: "fixtures/catalog.json", contents: new))
        #expect(prepared.diff.hunks.count > 1)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 1100, height: 650))
        window.contentView = view
        var jumps = 0
        for style in DiffStyle.allCases {
            for overflow in DiffOverflow.allCases {
                for expanded in [false, true, false] {
                    var options = DiffRenderOptions()
                    options.diffStyle = style; options.overflow = overflow; options.expandUnchanged = expanded
                    view.render(prepared, options: options)
                    view.layoutSubtreeIfNeeded()
                    let initialCount = view.rowCount
                    if !expanded {
                        view.expandHunk(1, lines: 20, direction: .up)
                        #expect(view.rowCount > initialCount)
                    }
                    for step in 0..<32 {
                        if step.isMultiple(of: 8) {
                            view.frame.size = .init(width: step.isMultiple(of: 16) ? 720 : 1100, height: 650)
                            view.layoutSubtreeIfNeeded()
                        }
                        view.resetMetrics()
                        let row = step.isMultiple(of: 2) ? (step * 7919) % view.rowCount : view.rowCount - 1 - (step * 3571) % view.rowCount
                        view.scrollToRow(row)
                        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let bounds = view.scrollView.contentView.bounds
                        #expect(bounds.minY.isFinite && bounds.minY >= 0)
                        #expect(view.metrics.cachedLines <= 512)
                        #expect(view.metrics.cachedUTF16Units <= 262_144)
                        #expect(view.displayedDocument?.id == prepared.id)
                        jumps += 1
                        // Let pending AppKit/layout tasks run between simulated events.
                        await Task.yield()
                    }
                }
            }
        }
        print("DEMO_JSON_SCROLL_STRESS bytes=\(old.utf8.count) jumps=\(jumps) split/unified scroll/wrap collapsed/expanded")
    }

    @Test @MainActor func splitColumnsShareHorizontalTokenGeometry() async throws {
        let file = FileContents(name: "wide.txt", contents: String(repeating: "abcdefghij", count: 1_000))
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        var options = DiffRenderOptions()
        options.diffStyle = .split; options.disableFileHeader = true; options.expandUnchanged = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NativeDiffView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        window.contentView = view; view.render(prepared, options: options)
        let canvas = try #require(view.scrollView.documentView)
        let geometry = try #require(canvas as? any TokenGeometryProviding)
        for x in [CGFloat(0), 400, 2_000, 400, 0] {
            view.scrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
            let range = NSRange(location: 0, length: file.contents.utf16.count)
            let left = geometry.visibleTokenRects(lineNumber: 1, side: .deletions, range: range, revision: prepared.id)
            let right = geometry.visibleTokenRects(lineNumber: 1, side: .additions, range: range, revision: prepared.id)
            #expect(!left.isEmpty)
            #expect(left.count == right.count)
            for (a, b) in zip(left, right) {
                #expect(abs((b.minX - a.minX) - canvas.visibleRect.width / 2) < 0.01)
                #expect(abs(a.width - b.width) < 0.01)
                #expect(a.minY == b.minY)
            }
        }
    }
    @Test @MainActor func distantScrollThenDocumentReplacementKeepsViewportValid() async throws {
        let highlighter = DiffHighlighter()
        let large = FileContents(name: "large.json", contents: "[\n" + (0..<16_000).map {
            "  {\"id\":\($0),\"description\":\"replacement stress workload with a long source row\"}"
        }.joined(separator: ",\n") + "\n]")
        #expect(large.contents.utf8.count > 1_000_000)
        let files = [large, FileContents(name: "short.json", contents: "{}\n"), FileContents(name: "empty.json", contents: "")]
        var documents: [HighlightedDiff] = []
        for file in files { documents.append(try await highlighter.prepare(oldFile: file, newFile: file)) }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 1000, height: 600))
        window.contentView = view
        var options = DiffRenderOptions(); options.expandUnchanged = true
        for iteration in 0..<48 {
            view.render(documents[0], options: options)
            view.scrollToRow(15_950 - iteration * 97)
            view.render(documents[1 + iteration % 2], options: options)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(view.scrollView.contentView.bounds.minY >= -view.scrollView.contentInsets.top)
            #expect(view.editorScrollOrigin.y == 0)
            #expect(view.metrics.cachedLines <= 512)
            #expect(view.metrics.cachedUTF16Units <= 262_144)
            #expect(view.displayedDocument?.id == documents[1 + iteration % 2].id)
        }
    }

    @Test @MainActor func sustainedMegabyteJSONJumpsKeepCachesBounded() async throws {
        let rows = (0..<16_000).map { "  {\"id\":\($0),\"name\":\"record-\($0)\",\"enabled\":true,\"description\":\"scroll workload\"}" }
        let source = "[\n" + rows.joined(separator: ",\n") + "\n]"
        #expect(source.utf8.count > 1_000_000)
        var options = DiffRenderOptions(); options.expandUnchanged = true; options.disableFileHeader = true
        let file = FileContents(name: "large.json", contents: source)
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file, options: options)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 1100, height: 650)); window.contentView = view
        view.render(prepared, options: options); view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        var timings: [Double] = []
        var samples: [(step: Int, scroll: Double, paint: Double, canvas: Double)] = []
        for step in 0..<256 {
            let row = step.isMultiple(of: 2) ? (step * 7919) % 15_950 : 15_950 - (step * 3571) % 15_950
            view.resetMetrics()
            let start = CACurrentMediaTime()
            view.scrollToRow(row)
            let afterScroll = CACurrentMediaTime()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let end = CACurrentMediaTime()
            timings.append((end - start) * 1000)
            samples.append((step, (afterScroll - start) * 1000, (end - afterScroll) * 1000, view.metrics.lastDrawMilliseconds))
            #expect(view.metrics.styledLines < 100)
            #expect(view.metrics.cachedLines <= 512)
            #expect(view.metrics.cachedUTF16Units <= 262_144)
        }
        let slowest = samples.max { $0.scroll + $0.paint < $1.scroll + $1.paint }!
        print("JSON_SCROLL_SLOWEST step=\(slowest.step) scroll_ms=\(slowest.scroll) bitmap_ms=\(slowest.paint) canvas_ms=\(slowest.canvas)")
        let csv = "step,scroll_ms,bitmap_ms,canvas_ms\n" + samples.map { "\($0.step),\($0.scroll),\($0.paint),\($0.canvas)" }.joined(separator: "\n")
        try csv.write(to: URL(fileURLWithPath: "/tmp/swift-diffs-json-scroll-samples.csv"), atomically: true, encoding: .utf8)
        timings.sort()
        print("JSON_SCROLL_STRESS bytes=\(source.utf8.count) jumps=256 p50_ms=\(timings[128]) p95_ms=\(timings[243]) max_ms=\(timings.last!)")
    }
    @Test @MainActor func megabyteASCIILineUsesBoundedHorizontalShaping() async throws {
        let source = String(repeating: "1234567890", count: 100_000)
        let file = FileContents(name: "long.json", contents: source)
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeDiffView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        window.contentView = view; view.render(prepared)
        for x in [CGFloat(0), 100_000, 500_000, 3_000_000] {
            view.scrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(view.metrics.cachedUTF16Units > 0)
            #expect(view.metrics.cachedUTF16Units < 4096)
            #expect(view.metrics.styledLines <= 8)
        }
        view.selectText(.init(side: .additions, anchor: .init(line: 0, character: 900_000), head: .init(line: 0, character: 900_010)))
        #expect(view.selectedText() == "1234567890")
        window.close()
    }
    @Test @MainActor func distantJumpsHaveBoundedWorkAndPreserveSelection() async throws {
        let old = (0..<20_000).map { "let value\($0) = \($0)\n" }.joined()
        let worker = DiffHighlighter()
        var options = DiffRenderOptions(); options.expandUnchanged = true; options.disableFileHeader = true
        let prepared = try await worker.prepare(oldFile: .init(name: "f.swift", contents: old), newFile: .init(name: "f.swift", contents: old.replacingOccurrences(of: "value9000 = 9000", with: "value9000 = 9001")), options: options)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeDiffView(frame: NSRect(x: 0, y: 0, width: 1100, height: 650))
        window.contentView = view
        view.render(prepared, options: options)
        view.layoutSubtreeIfNeeded()
        func paint() throws -> NSBitmapImageRep {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        _ = try paint()
        #expect(view.metrics.styledLines < 100)
        view.selectLines(.init(side: .additions, startLine: 9000, endLine: 9002))
        let selected = view.selectedText()
        var timings: [Double] = []
        for row in [19_000, 1_000, 15_000, 100, 18_000, 500, 9000] {
            view.resetMetrics()
            let start = CACurrentMediaTime()
            view.scrollToRow(row)
            _ = try paint()
            timings.append((CACurrentMediaTime() - start) * 1000)
            #expect(view.metrics.styledLines < 100, "Jump to \(row) styled too many lines")
            #expect(view.metrics.cachedLines <= 512)
            #expect(view.metrics.cachedUTF16Units <= 262_144)
            #expect(view.selectedText() == selected)
        }
        let snapshot = try paint()
        if let png = snapshot.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: "/tmp/swift-diffs-viewport.png")) }
        let previousY = view.scrollView.contentView.bounds.minY
        view.render(prepared, options: options)
        #expect(view.scrollView.contentView.bounds.minY == previousY)
        #expect(view.selectedText() == selected)
        view.frame.size = NSSize(width: 800, height: 450); view.layoutSubtreeIfNeeded(); _ = try paint()
        #expect(view.metrics.cachedLines <= 512)
        print("VIEWPORT_BENCHMARK jump paint ms: \(timings.map { String(format: "%.2f", $0) }.joined(separator: ", ")); prepare ms: \(prepared.preparationMilliseconds)")
        window.close()
    }
}

@Suite(.serialized) struct MultiFileViewportTests {
    @Test @MainActor func mountsOnlyDestinationFiles() async throws {
        let worker = DiffHighlighter()
        let base = try await worker.prepare(oldFile: .init(name: "file.swift", contents: "let a = 1\n"), newFile: .init(name: "file.swift", contents: "let a = 2\n"))
        let documents = Array(repeating: base, count: 1000)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeCodeView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = view; view.render(documents); view.layoutSubtreeIfNeeded()
        #expect(view.fileCount == 1000); #expect(view.mountedFileCount <= 11)
        #expect(view.scrollView.contentView.bounds.minY == 0)
        view.selectLines(.init(side: .additions, startLine: 1, endLine: 1), inFileAt: 0, activeLineSide: .additions, lineNumberOnly: true)
        view.scrollToFile(at: 900)
        let expectedDestination: CGFloat = 64_808 // 8 top padding + 900 files at 72 points
        #expect(view.scrollView.contentView.bounds.minY == expectedDestination)
        #expect(view.mountedFileCount <= 11)
        #expect(view.selectedText(inFileAt: 0) == "let a = 2\n")
        view.scrollToFile(at: 0)
        #expect(view.scrollView.contentView.bounds.minY == 8)
        #expect(view.mountedFileCount <= 11)
        #expect(view.scrollView.documentView!.subviews.compactMap { $0 as? NativeDiffView }.contains { $0.selectedText() == "let a = 2\n" && $0.selectionHighlightSide == .additions && $0.selectionLineNumberOnly })
        window.close()
    }
}

@Suite(.serialized) struct NativeEditorTests {
    @Test @MainActor func nativeEditingPreservesSelectionAndSupportsUndo() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeEditor(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = view
        view.render(.init(name: "f.swift", contents: "let greeting = \"Hello 👋\"\n"))
        view.layoutSubtreeIfNeeded()
        view.select([NSRange(location: 4, length: 8)])
        view.render(.init(name: "f.swift", contents: view.textView.string))
        #expect(view.textView.selectedRange() == NSRange(location: 4, length: 8))
        view.replaceCharacters(in: NSRange(location: 4, length: 8), with: "message")
        #expect(view.textView.string == "let message = \"Hello 👋\"\n")
        #expect(view.textView.undoManager?.canUndo == true)
        view.textView.undoManager?.undo()
        #expect(view.textView.string == "let greeting = \"Hello 👋\"\n")
        view.wrapsLines = true; view.layoutSubtreeIfNeeded()
        #expect(view.textView.textContainer?.widthTracksTextView == true)
        #expect(view.textView.layoutManager?.allowsNonContiguousLayout == true)
        window.close()
    }
}

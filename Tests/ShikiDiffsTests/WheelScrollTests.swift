import AppKit
import CoreGraphics
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct WheelScrollTests {
    // AppKit drops wheel events while the display sleeps, even for a plain
    // NSScrollView. Skipping explicitly preserves the movement assertion and
    // avoids presenting an inactive-display run as scrolling verification.
    @Test(.enabled(if: CGDisplayIsAsleep(CGMainDisplayID()) == 0,
                   "Requires an awake display: AppKit ignores wheel events while the display sleeps"))
    @MainActor func megabyteJSONSurvivesWheelReversalResizeAndReplacement() async throws {
        let rows = (0..<16_000).map { "  {\"id\":\($0),\"name\":\"record-\($0)\",\"enabled\":true,\"description\":\"wheel workload\"}" }
        let file = FileContents(name: "large.json", contents: "[\n" + rows.joined(separator: ",\n") + "\n]")
        #expect(file.contents.utf8.count > 1_000_000)
        let worker = DiffHighlighter()
        var options = DiffRenderOptions(); options.expandUnchanged = true; options.disableFileHeader = true
        let diff = try parseDiffFromFile(file, file)
        let preview = try await worker.preparePreview(diff, options: options)
        let prefix = try await worker.preparePreview(diff, options: options, highlightedLineCount: 64)
            .identifyingSource(as: preview.sourceID)
        let prepared = try await worker.prepare(diff, options: options, sourceID: preview.sourceID)
        let tiny = FileContents(name: "tiny.json", contents: "{}\n")
        let replacement = try await worker.prepare(oldFile: tiny, newFile: tiny, options: options)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 1100, height: 650)); window.contentView = view
        view.render(prepared, options: options)
        view.scrollToRow(8000)
        var positions = Set<Int>(), wheelEvents = 0, samples: [Double] = []
        func wheel(delta: Int32, phase: Int64 = 0) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            return try #require(NSEvent(cgEvent: cg))
        }
        // NSScrollView applies these deltas on the AppKit run loop. Task.yield
        // alone can keep rescheduling this test without advancing that loop.
        func flushScrollEvents() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.004)) }
        let began = try wheel(delta: -1200, phase: 1)
        #expect(began.phase == .began && began.hasPreciseScrollingDeltas)
        for burst in 0..<12 {
            if view.displayedDocument?.id != prepared.id { view.render(prepared, options: options); view.scrollToRow(8000) }
            if burst.isMultiple(of: 3) { view.render(preview, options: options) }
            let sign: Int32 = burst.isMultiple(of: 2) ? -1 : 1
            view.scrollView.scrollWheel(with: try wheel(delta: sign * 1200, phase: 1))
            flushScrollEvents()
            for _ in 0..<5 {
                view.scrollView.scrollWheel(with: try wheel(delta: sign * 2400, phase: 2))
                flushScrollEvents()
            }
            for tick in 0..<24 {
                let event = try wheel(delta: sign * Int32(1800 - tick * 50), phase: 2)
                #expect(event.phase == .changed && event.momentumPhase.isEmpty)
                wheelEvents += 1
                view.scrollView.scrollWheel(with: event)
                if burst.isMultiple(of: 3), tick == 6 || tick == 12 {
                    let before = view.scrollView.contentView.bounds.origin
                    view.render(tick == 6 ? prefix : prepared, options: options)
                    #expect(view.scrollView.contentView.bounds.origin == before)
                }
                if tick == 8 && burst.isMultiple(of: 3) {
                    view.setFrameSize(.init(width: burst.isMultiple(of: 2) ? 700 : 1100, height: 500))
                    view.needsLayout = true
                }
                if burst == 5 && tick == 12 { view.render(replacement, options: options) }
                flushScrollEvents()
                view.layoutSubtreeIfNeeded()
                let bounds = view.scrollView.contentView.bounds
                #expect(bounds.minY.isFinite && bounds.minX.isFinite)
                positions.insert(Int(bounds.minY))
                if tick.isMultiple(of: 4) {
                    view.resetMetrics()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    let start = CACurrentMediaTime()
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    samples.append((CACurrentMediaTime() - start) * 1000)
                    #expect(view.metrics.styledLines < 180)
                    #expect(view.metrics.cachedLines <= 512 && view.metrics.cachedUTF16Units <= 262_144)
                }
                await Task.yield()
            }
            view.scrollView.scrollWheel(with: try wheel(delta: 0, phase: 4))
            flushScrollEvents()
        }
        #expect(positions.count > 20, "Wheel events must actually move the clip view")
        #expect(view.displayedDocument?.id == prepared.id)
        samples.sort()
        print("JSON_WHEEL drag_events=\(wheelEvents) positions=\(positions.count) preview_transitions=8 paint_p50_ms=\(samples[samples.count / 2]) paint_max_ms=\(samples.last!)")
    }
}

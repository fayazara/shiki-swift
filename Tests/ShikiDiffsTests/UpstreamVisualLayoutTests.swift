import AppKit
import Testing
@testable import ShikiDiffs

@Suite struct UpstreamVisualLayoutTests {
    @Test @MainActor func classicIndicatorsHaveSeparateCodeColumn() async throws {
        let old = FileContents(name: "example.swift", contents: "same\n/// Comment\nfinal class A {\n}\n")
        let new = FileContents(name: old.name, contents: "same\n")
        let worker = DiffHighlighter()
        var options = DiffRenderOptions(); options.theme = "pierre-light"
        options.diffStyle = .unified; options.diffIndicators = .classic
        options.fontName = "Menlo"; options.fontSize = 20; options.lineHeight = 30; options.disableFileHeader = true
        let prepared = try await worker.prepare(oldFile: old, newFile: new, options: options)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 180)); window.contentView = view
        view.render(prepared, options: options)
        let canvas = try #require(view.scrollView.documentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/swift-diffs-classic-indicators.png"))
        var clicked: DiffLineClickEvent?
        view.interactionHandlers = .init(onLineClick: { clicked = $0 })
        let location = canvas.convert(.init(x: 110, y: 45), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
        }
        let hit = try #require(clicked)
        let advance = ("M" as NSString).size(withAttributes: [.font: NSFont(name: "Menlo", size: 20)!]).width
        #expect(abs(hit.lineRect.minX - (60 + 2 * advance)) < 0.1)
    }
    @Test @MainActor func hiddenConflictActionsRemoveHeightAndInteraction() async throws {
        let parsed = try parseMergeConflictDiffFromFile(.init(name: "auth-session.ts", contents: "before\n<<<<<<< HEAD\nconst current = 1;\n=======\nconst incoming = 2;\n>>>>>>> branch\nafter\n"))
        let prepared = try await DiffHighlighter().prepare(parsed.fileDiff)
        var options = DiffRenderOptions(); options.disableFileHeader = true
        let plan = DiffRenderPlan(diff: parsed.fileDiff, options: options, markerRows: parsed.markerRows)
        let start = try #require(plan.rows.firstIndex { if case .conflictMarker(_, .start) = $0.kind { return true }; return false })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 900, height: 300)); window.contentView = view
        var resolved = 0
        view.onResolveConflict = { _, _ in resolved += 1 }
        view.render(prepared, options: options, markerRows: parsed.markerRows)
        let initialHeight = view.measuredRowHeights.totalHeight
        let canvas = try #require(view.scrollView.documentView)
        let actions = try #require(canvas.accessibilityCustomActions())
        #expect(actions.count == 3)
        let previousAction = try #require(actions.first?.handler)
        options.mergeConflictActionsType = .none
        view.render(prepared, options: options, markerRows: parsed.markerRows)
        #expect(view.measuredRowHeights.totalHeight == initialHeight - 28)
        #expect(abs(Double(view.measuredRowHeights.height(of: start)) - options.lineHeight) < 0.001)
        #expect(view.rowCount == plan.rows.count)
        #expect(canvas.accessibilityCustomActions() == nil)
        #expect(!previousAction())
        canvas.updateTrackingAreas()
        #expect(canvas.trackingAreas.isEmpty)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(.init(x: 90, y: view.measuredRowHeights.origin(of: start) + 14), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        #expect(resolved == 0)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/swift-diffs-conflict-hidden-actions.png"))
        options.mergeConflictActionsType = .default
        view.render(prepared, options: options, markerRows: parsed.markerRows)
        #expect(view.measuredRowHeights.totalHeight == initialHeight)
        let restored = try #require(canvas.accessibilityCustomActions()?.first?.handler)
        #expect(restored())
        #expect(resolved == 1)
    }

    @Test @MainActor func conflictsOverrideSplitAndInlineHighlightOptions() async throws {
        let file = FileContents(name: "auth-session.ts", contents: "before\n<<<<<<< HEAD\nconst data = 1;\n=======\nconst sessionData = 2;\n>>>>>>> feature/session\nafter\n")
        let parsed = try parseMergeConflictDiffFromFile(file)
        let prepared = try await DiffHighlighter().prepare(parsed.fileDiff)
        #expect(!prepared.oldSpans.isEmpty || !prepared.newSpans.isEmpty)
        var requested = DiffRenderOptions(); requested.diffStyle = .split; requested.lineDiffType = .wordAlt
        var canonical = requested; canonical.diffStyle = .unified; canonical.lineDiffType = .none
        let requestedPlan = DiffRenderPlan(diff: parsed.fileDiff, options: requested, markerRows: parsed.markerRows)
        let canonicalPlan = DiffRenderPlan(diff: parsed.fileDiff, options: canonical, markerRows: parsed.markerRows)
        #expect(requestedPlan.rows == canonicalPlan.rows)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 900, height: 400)); window.contentView = view
        func snapshot(_ options: DiffRenderOptions) throws -> Data {
            view.render(prepared, options: options, markerRows: parsed.markerRows)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let expected = try snapshot(canonical)
        #expect(try snapshot(requested) == expected)
        try expected.write(to: URL(fileURLWithPath: "/tmp/swift-diffs-conflict-header-current.png"))
        view.render(prepared, options: requested)
        #expect(view.rowCount == DiffRenderPlan(diff: parsed.fileDiff, options: requested).rows.count)
    }

    @Test @MainActor func conflictControlsTargetTheirOwnRegion() async throws {
        let file = FileContents(name: "conflict.swift", contents: "top\n<<<<<<< HEAD\ncurrent1\n=======\nincoming1\n>>>>>>> branch\nmiddle\n<<<<<<< HEAD\ncurrent2\n=======\nincoming2\n>>>>>>> branch\nbottom\n")
        let parsed = try parseMergeConflictDiffFromFile(file)
        let prepared = try await DiffHighlighter().prepare(parsed.fileDiff)
        var options = DiffRenderOptions(); options.diffStyle = .unified; options.disableFileHeader = true
        let plan = DiffRenderPlan(diff: parsed.fileDiff, options: options, markerRows: parsed.markerRows)
        #expect(plan.rows.contains { $0.conflictIndex == 1 && $0.conflictSide == .deletions })
        #expect(plan.rows.contains { $0.conflictIndex == 1 && $0.conflictSide == .additions })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 900, height: 600)); window.contentView = view
        view.render(prepared, options: options, markerRows: parsed.markerRows)
        let row = try #require(plan.rows.firstIndex { $0.conflictIndex == 1 && { if case .conflictMarker(_, .start) = $0.kind { return true }; return false }($0) })
        #expect(abs(Double(view.measuredRowHeights.height(of: row)) - (options.lineHeight + 28)) < 0.001)
        var received: (Int, DiffResolution)?
        view.onResolveConflict = { received = ($0, $1) }
        let canvas = try #require(view.scrollView.documentView)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(.init(x: 90, y: view.measuredRowHeights.origin(of: row) + 14), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/swift-diffs-conflict-visual.png"))
        canvas.mouseDown(with: event)
        #expect(received?.0 == 1); #expect(received?.1 == .deletions)
    }

    @Test(arguments: [false, true]) @MainActor func decorationHoverWorksWithoutLineCallbacks(conflict: Bool) async throws {
        var options = DiffRenderOptions(); options.diffStyle = .unified; options.disableFileHeader = true
        let highlighter = DiffHighlighter()
        let prepared: HighlightedDiff
        let markers: [MergeConflictMarkerRow]
        if conflict {
            let parsed = try parseMergeConflictDiffFromFile(.init(name: "f.txt", contents: "top\n<<<<<<< HEAD\ncurrent\n=======\nincoming\n>>>>>>> branch\nbottom\n"))
            prepared = try await highlighter.prepare(parsed.fileDiff); markers = parsed.markerRows
        } else {
            let old = (0..<200).map { "line \($0)\n" }; var new = old; new[90] = "changed\n"
            prepared = try await highlighter.prepare(oldFile: .init(name: "f.txt", contents: old.joined()), newFile: .init(name: "f.txt", contents: new.joined()))
            markers = []
        }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 700, height: 300)); window.contentView = view
        view.render(prepared, options: options, markerRows: markers)
        let canvas = try #require(view.scrollView.documentView)
        canvas.updateTrackingAreas()
        #expect(!canvas.trackingAreas.isEmpty)
        func snapshot() throws -> Data {
            let rect = canvas.visibleRect
            let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: rect))
            canvas.cacheDisplay(in: rect, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let baseline = try snapshot()
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(.init(x: 90, y: conflict ? 34 : 16), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        canvas.mouseMoved(with: event)
        #expect(try snapshot() != baseline)
        canvas.mouseExited(with: event)
        #expect(try snapshot() == baseline)
        let plainFile = FileContents(name: "plain.txt", contents: "plain\n")
        let plain = try await highlighter.prepare(oldFile: plainFile, newFile: plainFile)
        view.render(plain, options: options)
        canvas.updateTrackingAreas()
        #expect(canvas.trackingAreas.isEmpty)
    }

    @Test func offscreenEstimatesMatchDecoratedRowHeights() throws {
        let old = (0..<200).map { "line \($0)\n" }; var new = old; new[90] = "changed\n"
        let diff = try parseDiffFromFile(.init(name: "f.txt", contents: old.joined()), .init(name: "f.txt", contents: new.joined()))
        for style in [HunkSeparators.lineInfo, .lineInfoBasic, .simple, .metadata] {
            var options = DiffRenderOptions(); options.hunkSeparators = style
            let plan = DiffRenderPlan(diff: diff, options: options)
            let actual = RowHeightIndex(rows: plan.rows, options: options).totalHeight
            #expect(DiffRenderPlan.estimatedHeight(diff, options: options, expandedRegions: [:]) == actual)
        }
    }

    @Test func separatorStylesOmitUpstreamExcludedGaps() throws {
        let old = (0..<300).map { "line \($0)\n" }
        var new = old; new[90] = "first change\n"; new[210] = "second change\n"
        var diff = try parseDiffFromFile(.init(name: "f.txt", contents: old.joined()), .init(name: "f.txt", contents: new.joined()))
        #expect(diff.hunks.count == 2)
        diff.hunks[0].hunkSpecs = "@@ first @@"
        diff.hunks[1].hunkSpecs = "@@ second @@"
        for partial in [false, true] {
            diff.isPartial = partial
            for style in HunkSeparators.allCases {
                var options = DiffRenderOptions(); options.hunkSeparators = style
                for expanded in [[:], [0: HunkExpansionRegion(fromStart: 20), 1: .init(fromEnd: 20)]] {
                    let plan = DiffRenderPlan(diff: diff, options: options, expandedRegions: expanded)
                    let indices = plan.rows.compactMap { row -> Int? in
                        if case .separator(_, let index) = row.kind { return index }; return nil
                    }
                    let expected = style == .simple ? (partial ? [1] : [1, 2])
                        : style == .metadata ? [0, 1] : (partial ? [0, 1] : [0, 1, 2])
                    #expect(indices == expected)
                    #expect(DiffRenderPlan.unannotatedRowCount(diff, options: options, expandedRegions: expanded) == plan.rows.count)
                    #expect(DiffRenderPlan.estimatedHeight(diff, options: options, expandedRegions: expanded)
                            == RowHeightIndex(rows: plan.rows, options: options).totalHeight)
                }
            }
        }
        diff.hunks[0].hunkSpecs = nil
        var options = DiffRenderOptions(); options.hunkSeparators = .metadata
        let plan = DiffRenderPlan(diff: diff, options: options)
        #expect(plan.rows.filter { if case .separator = $0.kind { return true }; return false }.count == 1)
        #expect(DiffRenderPlan.unannotatedRowCount(diff, options: options, expandedRegions: [:]) == plan.rows.count)
    }
}

import AppKit
import Testing
@testable import ShikiDiffs

struct NoNewlineLayoutTests {
    @Test func warningsFollowTheirSourceLinesAndPreserveHeightEstimates() throws {
        for (old, new) in [("old", "new"), ("old\n", "new"), ("old", "new\n"), ("old\nsame", "new\nsame")] {
            let diff = try parseDiffFromFile(.init(name: "f.txt", contents: old), .init(name: "f.txt", contents: new))
            for style in [DiffStyle.split, .unified] {
                var options = DiffRenderOptions(); options.diffStyle = style
                let plan = DiffRenderPlan(diff: diff, options: options)
                let markers = plan.rows.enumerated().filter { $0.element.kind == .noNewline }
                let missingOld = !old.hasSuffix("\n"), missingNew = !new.hasSuffix("\n")
                #expect(markers.count == (style == .split ? 1 : (missingOld ? 1 : 0) + (missingNew ? 1 : 0)))
                for (index, marker) in markers {
                    #expect(marker.noNewlineChanged == !old.contains("same"))
                    if style == .unified {
                        let preceding = plan.rows[..<index].last { $0.oldIndex != nil || $0.newIndex != nil }
                        if let oldNumber = marker.oldNumber { #expect(preceding?.oldNumber == oldNumber) }
                        if let newNumber = marker.newNumber { #expect(preceding?.newNumber == newNumber) }
                        #expect((marker.oldNumber == nil) != (marker.newNumber == nil))
                    } else {
                        #expect((marker.oldNumber != nil) == missingOld)
                        #expect((marker.newNumber != nil) == missingNew)
                    }
                }
                #expect(DiffRenderPlan.unannotatedRowCount(diff, options: options, expandedRegions: [:]) == plan.rows.count)
                #expect(DiffRenderPlan.estimatedHeight(diff, options: options, expandedRegions: [:])
                        == RowHeightIndex(rows: plan.rows, options: options).totalHeight)
            }
        }
    }

    @Test @MainActor func rightSideWarningDrawsInAdditionColumn() async throws {
        let prepared = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "old\n"), newFile: .init(name: "f.txt", contents: "new"))
        var options = DiffRenderOptions(); options.disableFileHeader = true
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 1000, height: 150))
        view.render(prepared, options: options)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/swift-diffs-no-newline.png"))
        #expect(view.metrics.drawnRows == 2)
    }
}

import AppKit
import Testing
@testable import ShikiDiffs

@Suite struct FoldedLineNavigationTests {
    private struct Fixture: Decodable {
        var starts: [Int]; var count: Int; var partial: Bool; var all: Bool
        var threshold: Int; var fromStart: Int; var fromEnd: Int
        var probes: [Probe]
        struct Probe: Decodable {
            var line: Int; var visible: Bool; var up: Int?; var down: Int?
            var revealed: Bool; var expansion: Expansion?
        }
        struct Expansion: Decodable { var index: Int; var count: Int; var direction: String }
    }
    @Test func matchesUpstreamNavigationAndReveal() throws {
        let url = try #require(fixtureURL("navigation-oracle"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            var diff = FileDiffMetadata(name: "f.txt"); diff.isPartial = fixture.partial
            diff.additionLines = Array(repeating: "x\n", count: 45); diff.deletionLines = diff.additionLines
            var previousEnd = 0
            for start in fixture.starts {
                var hunk = Hunk(); hunk.additionStart = start; hunk.deletionStart = start
                hunk.additionCount = fixture.count; hunk.deletionCount = fixture.count
                hunk.collapsedBefore = max(0, hunk.newBoundary - previousEnd)
                previousEnd = hunk.newBoundary + hunk.additionCount; diff.hunks.append(hunk)
            }
            var options = DiffRenderOptions(); options.expandUnchanged = fixture.all
            options.collapsedContextThreshold = fixture.threshold; options.expansionLineCount = 3
            let regions = Dictionary(uniqueKeysWithValues: (0...diff.hunks.count).map { ($0, HunkExpansionRegion(fromStart: fixture.fromStart, fromEnd: fixture.fromEnd)) })
            let navigation = FoldedLineNavigation(diff: diff, options: options, regions: regions)
            for probe in fixture.probes {
                #expect(try navigation.isRenderable(probe.line) == probe.visible)
                #expect(try navigation.nearest(probe.line, direction: .up) == probe.up)
                #expect(try navigation.nearest(probe.line, direction: .down) == probe.down)
                let expansion = try navigation.expansionToReveal(probe.line)
                #expect((expansion != nil) == probe.revealed)
                #expect(expansion?.index == probe.expansion?.index)
                #expect(expansion?.count == probe.expansion?.count)
                if let expansion, let expected = probe.expansion {
                    #expect((expansion.direction == .up ? "up" : "down") == expected.direction)
                }
            }
        }
    }
    @Test @MainActor func nativeRevealExpandsThroughCallbackAndIsIdempotent() async throws {
        let lines = (1...100).map { "line \($0)" }
        var changed = lines; changed[49] = "changed"
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: lines.joined(separator: "\n")), newFile: .init(name: "f.txt", contents: changed.joined(separator: "\n")))
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 700, height: 200))
        #expect(try view.isLineRenderable(10))
        #expect(try view.getNearestRenderableLine(10, direction: .down) == 10)
        #expect(try !view.revealLine(10))
        var options = DiffRenderOptions(); options.expansionLineCount = 3
        view.render(document, options: options)
        var callbacks: [(Int, Int, ExpansionDirection)] = []
        view.onExpansion = { callbacks.append(($0, $1, $2)) }
        for line in [10, 40, 80] {
            #expect(try !view.isLineRenderable(line))
            #expect(try view.revealLine(line))
            #expect(try view.isLineRenderable(line))
            #expect(try !view.revealLine(line))
        }
        #expect(callbacks.count == 3)
        #expect(callbacks[0].2 == .up)
        #expect(callbacks[1].2 == .down)
        #expect(callbacks[2].0 == document.diff.hunks.count)
    }
    @Test func inconsistentTrailingMetadataThrows() throws {
        var diff = FileDiffMetadata(name: "bad.txt"); diff.isPartial = false
        diff.additionLines = Array(repeating: "x", count: 10); diff.deletionLines = Array(repeating: "x", count: 9)
        var hunk = Hunk(); hunk.additionStart = 1; hunk.deletionStart = 1; hunk.additionCount = 1; hunk.deletionCount = 1
        diff.hunks = [hunk]
        let navigation = FoldedLineNavigation(diff: diff, options: .init())
        #expect(throws: TrailingContextMismatch.self) { try navigation.isRenderable(5) }
        #expect(throws: TrailingContextMismatch.self) { try navigation.nearest(5, direction: .down) }
        #expect(throws: TrailingContextMismatch.self) { try navigation.expansionToReveal(5) }
    }
}

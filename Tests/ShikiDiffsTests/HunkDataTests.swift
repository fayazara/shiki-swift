import Testing
import Foundation
@testable import ShikiDiffs

struct HunkDataTests {
    @Test func partialTrailingContextRemainsUnknownUntilHydrated() throws {
        var diff = try #require(parsePatchFiles("--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new\n").first?.files.first)
        #expect(diff.isPartial)
        let plain = DiffRenderPlan(diff: diff)
        let hydrated = DiffRenderPlan(diff: diff, canHydrateContext: true)
        #expect(hydrated.rows.count == plain.rows.count + 1)
        let data = try #require(hydrated.rows.last?.hunkData(in: diff, type: .unified, canHydrateContext: true))
        #expect(!data.lineCountKnown && data.lines == 0)
        #expect(data.expansionActions == [.up])
        for style in [HunkSeparators.simple, .metadata] {
            var options = DiffRenderOptions(); options.hunkSeparators = style
            #expect(DiffRenderPlan(diff: diff, options: options, canHydrateContext: true).rows.count == plain.rows.count)
        }
        for type in [ChangeType.new, .deleted, .renamePure] {
            diff.type = type
            #expect(DiffRenderPlan(diff: diff, canHydrateContext: true).rows.count == plain.rows.count)
        }
    }

    @Test func trailingContextMatchesUpstreamOracle() throws {
        struct Fixture: Decodable {
            let additions, deletions, additionStart, deletionStart, additionCount, deletionCount: Int
            let partial, hasHunk: Bool
            let result: Int?
            let error: String?
        }
        let url = try #require(fixtureURL("trailing-context-oracle"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        #expect(fixtures.count == 5184)
        for (index, fixture) in fixtures.enumerated() {
            var diff = FileDiffMetadata(name: "f.txt"); diff.isPartial = fixture.partial
            diff.additionLines = Array(repeating: "x\n", count: fixture.additions)
            diff.deletionLines = Array(repeating: "x\n", count: fixture.deletions)
            var hunk = Hunk(); hunk.additionStart = fixture.additionStart; hunk.deletionStart = fixture.deletionStart
            hunk.additionCount = fixture.additionCount; hunk.deletionCount = fixture.deletionCount
            diff.hunks = fixture.hasHunk ? [hunk] : []
            do {
                let actual = try getTrailingContextRangeSize(fileDiff: diff, errorPrefix: "oracle")
                #expect(fixture.error == nil && actual == fixture.result, "case \(index)")
            } catch {
                #expect(error.localizedDescription == fixture.error, "case \(index)")
            }
        }
    }

    @Test func trailingContextValidatesBothSides() throws {
        let old = FileContents(name: "f.txt", contents: "one\ntwo\nthree\nfour\n")
        let new = FileContents(name: "f.txt", contents: "one\nchanged\nthree\nfour\n")
        var options = DiffOptions(); options.context = 0
        let diff = try parseDiffFromFile(old, new, options: options)
        #expect(try getTrailingContextRangeSize(fileDiff: diff) == 2)
        var partial = diff; partial.isPartial = true
        #expect(try getTrailingContextRangeSize(fileDiff: partial) == 0)
        var invalid = diff; invalid.additionLines.append("extra\n")
        #expect(throws: TrailingContextMismatch.self) { try getTrailingContextRangeSize(fileDiff: invalid) }
        #expect(DiffRow(kind: .separator(hidden: 3, hunk: diff.hunks.count)).hunkData(in: invalid, type: .unified) == nil)
        var empty = diff; empty.additionLines = []
        #expect(try getTrailingContextRangeSize(fileDiff: empty) == 0)
    }

    @Test func expansionControlsMatchUpstreamOrdering() {
        var data = HunkData(slotName: "slot", hunkIndex: 0, lines: 10, lineCountKnown: true, type: .unified)
        #expect(data.expansionActions.isEmpty)
        for (up, down, unchunked, chunked) in [
            (true, true, [HunkExpansionAction.both], [HunkExpansionAction.up, .down, .all]),
            (false, true, [.down], [.down, .all]),
            (true, false, [.up], [.up, .all])
        ] {
            data.expandable = .init(chunked: false, up: up, down: down)
            #expect(data.expansionActions == unchunked)
            data.expandable?.chunked = true
            #expect(data.expansionActions == chunked)
        }
    }

    @Test func renderPlanExposesLeadingAndTrailingExpansionDirections() throws {
        let lines = (0..<400).map { "line \($0)\n" }
        var edited = lines; edited[200] = "changed\n"
        let diff = try parseDiffFromFile(.init(name: "f.txt", contents: lines.joined()), .init(name: "f.txt", contents: edited.joined()))
        let plan = DiffRenderPlan(diff: diff, options: .init())
        let metadata = plan.rows.compactMap { $0.hunkData(in: diff, type: .unified) }
        #expect(metadata.count == 2)
        #expect(metadata.first?.slotName == "hunk-separator-unified-0")
        #expect(metadata.first?.expandable == .init(chunked: true, up: false, down: true))
        #expect(metadata.last?.expandable == .init(chunked: true, up: true, down: false))
        #expect(DiffRow(kind: .context).hunkData(in: diff, type: .additions) == nil)
        var partial = diff; partial.isPartial = true
        let row = DiffRow(kind: .separator(hidden: 100, hunk: 0))
        #expect(row.hunkData(in: partial, type: .deletions)?.expandable == nil)
        #expect(row.hunkData(in: partial, type: .deletions, canHydrateContext: true)?.expandable?.chunked == true)
        let expanded = DiffRenderPlan(diff: diff, options: .init(), expandedRegions: [0: .init(fromStart: 150), diff.hunks.count: .init(fromStart: 150)])
        let remaining = expanded.rows.compactMap { $0.hunkData(in: diff, type: .unified) }
        #expect(remaining.count == 2)
        #expect(remaining.allSatisfy { $0.lines < 100 && $0.expandable?.chunked == true })
    }

    @Test func everyUpstreamFieldParticipates() {
        let base = HunkData(slotName: "é", hunkIndex: 1, lines: 20, lineCountKnown: true, type: .unified,
                            expandable: .init(chunked: true, up: true, down: true))
        #expect(areHunkDataEqual(base, base))
        var changed = base; changed.slotName = "e\u{301}"
        #expect(!areHunkDataEqual(base, changed))
        changed = base; changed.hunkIndex += 1; #expect(!areHunkDataEqual(base, changed))
        changed = base; changed.lines += 1; #expect(!areHunkDataEqual(base, changed))
        changed = base; changed.lineCountKnown = false; #expect(!areHunkDataEqual(base, changed))
        for column in [CodeColumnType.additions, .deletions] {
            changed = base; changed.type = column; #expect(!areHunkDataEqual(base, changed))
        }
        for flags in [HunkData.Expandable(chunked: false, up: true, down: true),
                      .init(chunked: true, up: false, down: true), .init(chunked: true, up: true, down: false)] {
            changed = base; changed.expandable = flags; #expect(!areHunkDataEqual(base, changed))
        }
        changed = base; changed.expandable = nil
        #expect(!areHunkDataEqual(base, changed))
        #expect(areHunkDataEqual(changed, changed))
        var disabled = changed; disabled.expandable = .init(chunked: false, up: false, down: false)
        #expect(!areHunkDataEqual(changed, disabled))
    }
}

import Testing
@testable import ShikiDiffs

struct LineIndexTests {
    @Test func manyHunkLookupBenchmark() throws {
        var patch = "--- a/f.txt\n+++ b/f.txt\n"
        for index in 0..<2000 {
            let line = index * 10 + 1
            patch += "@@ -\(line) +\(line) @@\n-old \(index)\n+new \(index)\n"
        }
        let diff = try #require(try parsePatchFiles(patch, throwOnError: true).first?.files.first)
        #expect(diff.hunks.count == 2000)
        let queries = (0..<10_000).map { ($0 * 7919) % 20_000 + 1 }
        let start = ContinuousClock.now
        let indexed = queries.map { diff.selectionLineIndex($0, side: .additions) }
        let indexedTime = start.duration(to: .now)
        let linearStart = ContinuousClock.now
        let linear = queries.map { diff.getLineIndex($0, side: .additions) }
        let linearTime = linearStart.duration(to: .now)
        #expect(indexed == linear)
        print("SELECTION_LOOKUP 10000 queries / 2000 hunks: indexed \(indexedTime), linear \(linearTime)")
    }
    @Test func crossSideCopyMatchesExpandedRowsAcrossSeparatedHunks() throws {
        let old = (1...80).map { "line \($0)\r\n" }
        var new = old
        new[10] = "replacement\r\n"; new.insert("inserted\r\n", at: 60)
        let diff = try parseDiffFromFile(.init(name: "f.txt", contents: old.joined()), .init(name: "f.txt", contents: new.joined()))
        #expect(diff.hunks.count > 1)
        var options = DiffRenderOptions(); options.diffStyle = .unified; options.expandUnchanged = true
        let rows = DiffRenderPlan(diff: diff, options: options).rows
        for start in stride(from: 1, through: 80, by: 7) {
            for end in stride(from: 1, through: 81, by: 9) {
                let selection = LineSelection(side: .deletions, startLine: start, endLine: end, endSide: .additions)
                let range = try #require(selection.rowRange(in: diff, style: .unified))
                let expected = rows.compactMap { row -> String? in
                    let side: DiffSide = row.newNumber == nil ? .deletions : .additions
                    guard let number = row.newNumber ?? row.oldNumber,
                          let index = diff.selectionLineIndex(number, side: side), range.contains(index.unified) else { return nil }
                    if let index = row.newIndex { return diff.additionLines[index] }
                    if let index = row.oldIndex { return diff.deletionLines[index] }
                    return nil
                }.joined()
                #expect(selection.text(in: diff) == expected)
            }
        }
    }
    @Test func partialCrossSideCopyOmitsMissingContextAndPreservesEOF() throws {
        let patch = "--- a/f.txt\n+++ b/f.txt\n@@ -10,2 +10,2 @@\n-old\n+new\n context\n@@ -90 +90 @@\n-last old\n\\ No newline at end of file\n+last new\n\\ No newline at end of file\n"
        let diff = try #require(try parsePatchFiles(patch, throwOnError: true).first?.files.first)
        #expect(diff.isPartial)
        let selection = LineSelection(side: .deletions, startLine: 10, endLine: 90, endSide: .additions)
        #expect(selection.text(in: diff) == "old\nnew\ncontext\nlast oldlast new")
        let reverse = LineSelection(side: .additions, startLine: 90, endLine: 10, endSide: .deletions)
        #expect(reverse.text(in: diff) == selection.text(in: diff))
        let omitted = LineSelection(side: .deletions, startLine: 30, endLine: 60, endSide: .additions)
        #expect(omitted.text(in: diff).isEmpty)
    }
    @Test func indexedSelectionLookupMatchesLinearMapping() throws {
        let old = (0..<2000).map { "line \($0)\n" }
        var new = old
        for index in stride(from: 1990, through: 10, by: -20) {
            switch index % 3 {
            case 0: new.remove(at: index)
            case 1: new.insert("inserted\n", at: index)
            default: new[index] = "changed\n"
            }
        }
        let diff = try parseDiffFromFile(.init(name: "f.txt", contents: old.joined()), .init(name: "f.txt", contents: new.joined()), options: .init(context: 0))
        #expect(diff.hunks.count > 90)
        for side in [DiffSide.deletions, .additions] {
            for number in -2...2010 {
                #expect(diff.selectionLineIndex(number, side: side) == diff.getLineIndex(number, side: side))
            }
        }
    }
    @Test func unchangedNativeRowsSupportCrossSideSelection() throws {
        let file = FileContents(name: "f.txt", contents: "a\nb\nc\n")
        let diff = try parseDiffFromFile(file, file)
        #expect(diff.hunks.isEmpty)
        #expect(diff.getLineIndex(2) == nil)
        let selection = LineSelection(side: .deletions, startLine: 1, endLine: 2, endSide: .additions)
        #expect(selection.rowRange(in: diff, style: .split) == 0...1)
        #expect(selection.rowRange(in: diff, style: .unified) == 0...1)
        #expect(selection.text(in: diff) == "a\nb\n")
        #expect(diff.selectionLineIndex(0, side: .additions) == nil)
        #expect(diff.selectionLineIndex(4, side: .deletions) == nil)
    }
    @Test func changedBlocksMapBothSourceSides() throws {
        let diff = try parseDiffFromFile(.init(name: "f.txt", contents: "a\nold\nz\n"), .init(name: "f.txt", contents: "a\nx\ny\nz\n"))
        #expect(diff.getLineIndex(1) == .init(unified: 0, split: 0))
        #expect(diff.getLineIndex(2, side: .deletions) == .init(unified: 1, split: 1))
        #expect(diff.getLineIndex(2) == .init(unified: 2, split: 1))
        #expect(diff.getLineIndex(3) == .init(unified: 3, split: 2))
        #expect(diff.getLineIndex(3, side: .deletions) == .init(unified: 4, split: 3))
        #expect(diff.getLineIndex(5) == .init(unified: 5, split: 4))
        #expect(diff.getLineIndex(0) == .init(unified: 0, split: 0))
        let range = LineSelection(side: .deletions, startLine: 2, endLine: 3, endSide: .additions)
        #expect(range.rowRange(in: diff, style: .unified) == 1...3)
        #expect(range.rowRange(in: diff, style: .split) == 1...2)
        #expect(range.text(in: diff) == "old\nx\ny\n")
        #expect(LineSelection(side: .additions, startLine: 3, endLine: 2, endSide: .deletions).text(in: diff) == range.text(in: diff))
    }
}

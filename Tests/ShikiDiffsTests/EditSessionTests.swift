import Testing
import Foundation
@testable import ShikiDiffs

@Suite struct EditSessionTests {
    struct Step: Decodable {
        var lines: [String]
        var changed: [Int]?
        var change: SessionRegionChange?
        var error: String?
        var expected: FileDiffMetadata
        var expansions: [String: HunkExpansionRegion]
    }
    struct Fixture: Decodable {
        var name: String
        var context: Int
        var input: FileDiffMetadata
        var steps: [Step]
        var anchors: [[Int]]
        var anchorError: String?
        var finished: Bool
        var expected: FileDiffMetadata
        var expansions: [String: HunkExpansionRegion]
    }
    @Test func upstreamSessionOracle() throws {
        let url = fixtureURL("editor-oracle")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            var diff = fixture.input
            let options = DiffOptions(context: fixture.context)
            var expansions = Dictionary(uniqueKeysWithValues: (0...diff.hunks.count).map { ($0, HunkExpansionRegion(fromStart: $0 % 3 + 1, fromEnd: $0 % 2 + 1)) })
            for (index, step) in fixture.steps.enumerated() {
                let previous = diff.additionLines
                diff.additionLines = step.lines
                var change: SessionRegionChange?
                do {
                    if let changed = step.changed {
                        let previousLines = Dictionary(uniqueKeysWithValues: Set(changed).compactMap { i in previous.indices.contains(i) ? (i, previous[i]) : nil })
                        change = try applySessionChangedLines(&diff, changedAdditionLineIndexes: changed, options: options, previousAdditionLines: previousLines)
                    } else { change = try rebuildSessionHunks(&diff, options: options) }
                    #expect(step.error == nil, "Expected upstream error: \(fixture.name) step \(index)")
                } catch {
                    #expect(step.error != nil, "Unexpected session error: \(fixture.name) step \(index): \(error)")
                }
                #expect(change == step.change, "Region mapping: \(fixture.name) step \(index)")
                #expect(diff == step.expected, "Session metadata: \(fixture.name) context \(fixture.context) step \(index)")
                if let change { expansions = remapExpandedHunksForRegionChange(expansions, change: change) }
                #expect(expansions == step.expansions.reduce(into: [:]) { $0[Int($1.key)!] = $1.value })
            }
            var anchors: [Range<Int>] = []
            if fixture.anchorError != nil {
                #expect(throws: DiffError.self) { try captureExpansionAnchors(diff, expandedHunks: expansions, collapsedContextThreshold: 1) }
            } else {
                anchors = try captureExpansionAnchors(diff, expandedHunks: expansions, collapsedContextThreshold: 1)
                #expect(anchors == fixture.anchors.map { $0[0]..<$0[1] }, "Expansion anchors: \(fixture.name)")
            }
            #expect(try finishEditSessionForDiff(&diff, options: options) == fixture.finished)
            #expect(diff == fixture.expected, "Session exit: \(fixture.name) context \(fixture.context)")
            #expect(rebuildExpansionFromAnchors(diff, anchors: anchors) == fixture.expansions.reduce(into: [:]) { $0[Int($1.key)!] = $1.value })
            #expect(try !finishEditSessionForDiff(&diff, options: options))
        }
    }
    @Test func retainedSessionRendererDispatch() throws {
        let url = fixtureURL("retained-editor-oracle")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let expansions = Dictionary(uniqueKeysWithValues: (0...fixture.input.hunks.count).map { ($0, HunkExpansionRegion(fromStart: $0 % 3 + 1, fromEnd: $0 % 2 + 1)) })
            var session = try DiffEditSession(diff: fixture.input, options: .init(context: fixture.context), expandedHunks: expansions)
            #expect(session.diff.cacheKey == nil)
            for (index, step) in fixture.steps.enumerated() {
                let change: SessionRegionChange?
                if let changed = step.changed {
                    let replacements = Dictionary(uniqueKeysWithValues: Set(changed).compactMap { i in step.lines.indices.contains(i) ? (i, step.lines[i]) : nil })
                    change = try session.updateLines(replacements)
                } else { change = try session.replaceAdditionLines(step.lines) }
                #expect(change == step.change, "Retained mapping: \(fixture.name) step \(index)")
                #expect(session.diff == step.expected, "Retained metadata: \(fixture.name) context \(fixture.context) step \(index)")
                #expect(session.expandedHunks == step.expansions.reduce(into: [:]) { $0[Int($1.key)!] = $1.value })
            }
            #expect(try session.finish() == fixture.finished)
            #expect(session.diff == fixture.expected, "Retained exit: \(fixture.name)")
            #expect(session.expandedHunks == fixture.expansions.reduce(into: [:]) { $0[Int($1.key)!] = $1.value })
            #expect(try !session.finish())
        }
    }
    @Test func repeatedLargeFileLineEditsAndAtomicFailure() throws {
        let old = (0..<50_000).map { "let item\($0) = \($0)\n" }
        var new = old; new[25_000] = "let changed = 1\n"
        let original = try parseDiffFromFile(.init(name: "f.swift", contents: old.joined()), .init(name: "f.swift", contents: new.joined()))
        var session = try DiffEditSession(diff: original)
        let hunks = session.diff.hunks
        let clock = ContinuousClock(), start = clock.now
        for index in 0..<200 {
            #expect(try session.updateLines([25_000: "let changed = \(index + 2)\n"]) == nil)
        }
        let elapsed = start.duration(to: clock.now)
        print("200 cached editor line updates in a 50,000-line file: \(elapsed)")
        #expect(elapsed < .seconds(3))
        #expect(session.diff.hunks == hunks)
        #expect(session.diff.deletionLines == old)
        let before = session.diff
        #expect(throws: TextDocumentError.self) { try session.updateLines([-1: "invalid\n", 25_000: "should not install\n"]) }
        #expect(session.diff == before)
        #expect(original.additionLines[25_000] == "let changed = 1\n")
        #expect(try session.finish())
        let expected = try parseDiffFromFile(.init(name: "f.swift", contents: old.joined()), .init(name: "f.swift", contents: session.diff.additionLines.joined()))
        #expect(session.diff == expected)
    }
}

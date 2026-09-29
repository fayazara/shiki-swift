import Testing
import Foundation
@testable import ShikiDiffs

@Suite struct ConflictParityTests {
    @Test func unresolvedStateResolvesConflictsInEitherOrder() throws {
        let source = "top\n<<<<<<< HEAD\ncurrent-one\n||||||| base\nbase-one\n=======\nincoming-one\n>>>>>>> branch\nmiddle\n<<<<<<< HEAD\ncurrent-two\n=======\nincoming-two\n>>>>>>> branch\nbottom\n"
        for order in [[0, 1], [1, 0]] {
            var state = try UnresolvedFileState(file: .init(name: "f.txt", contents: source, cacheKey: "file"))
            for index in order { try state.resolve(conflictIndex: index, resolution: index == 0 ? .both : .additions) }
            #expect(state.file.contents == "top\ncurrent-one\nincoming-one\nmiddle\nincoming-two\nbottom\n")
            #expect(state.result.actions.isEmpty); #expect(state.result.markerRows.isEmpty)
            #expect(state.result.fileDiff.deletionLines == state.result.fileDiff.additionLines)
            #expect(throws: DiffError.self) { try state.resolve(conflictIndex: 0, resolution: .deletions) }
        }
    }
    struct Fixture: Decodable { var name: String; var context: Int; var file: FileContents; var expected: MergeConflictResult? }
    @Test func sourceConflictOracle() throws {
        let url = fixtureURL("conflict-oracle")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            if let expected = fixture.expected {
                let actual = try parseMergeConflictDiffFromFile(fixture.file, maxContextLines: fixture.context)
                #expect(actual == expected, "Merge conflict mismatch: \(fixture.name), context \(fixture.context)")
            } else {
                #expect(throws: DiffError.self) { try parseMergeConflictDiffFromFile(fixture.file, maxContextLines: fixture.context) }
            }
        }
    }
    struct Resolution: Decodable { var name: String; var input: FileDiffMetadata; var action: MergeConflictDiffAction; var mode: String; var expected: FileDiffMetadata }
    @Test func sourceConflictResolutionOracle() throws {
        let url = fixtureURL("conflict-resolution-oracle")!
        let fixtures = try JSONDecoder().decode([Resolution].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let mode: DiffResolution = fixture.mode == "current" ? .deletions : fixture.mode == "incoming" ? .additions : .both
            let result = try resolveConflict(fixture.input, conflict: fixture.action, resolution: mode)
            #expect(result == fixture.expected, "Conflict resolution mismatch: \(fixture.name)")
        }
    }
}

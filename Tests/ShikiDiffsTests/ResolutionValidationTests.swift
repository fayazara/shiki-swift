import Foundation
import Testing
@testable import ShikiDiffs

struct ResolutionValidationTests {
    @Test func sourceLookupsMatchUpstream() throws {
        struct Fixture: Decodable {
            let name: String
            let input: FileDiffMetadata
            let resolution: String
            let indexesToDelete: [Int]
            let expected: FileDiffMetadata?
            let error: String?
        }
        let url = try #require(fixtureURL("resolution-validation-oracle"))
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        #expect(cases.count == 24)
        for fixture in cases {
            do {
                let result = try resolveRegion(fixture.input, hunkIndex: 0, startContentIndex: 0, endContentIndex: 0,
                    resolution: try #require(DiffResolution(rawValue: fixture.resolution)), indexesToDelete: Set(fixture.indexesToDelete))
                #expect(fixture.error == nil && result == fixture.expected, "\(fixture.name)")
            } catch {
                #expect(fixture.error != nil, "Unexpected rejection: \(fixture.name): \(error)")
            }
        }
    }
    @Test func integerExtremesThrowInsteadOfTrapping() throws {
        let base = try parseDiffFromFile(.init(name: "f", contents: "old\n"), .init(name: "f", contents: "new\n"))
        let mutations: [(inout FileDiffMetadata) -> Void] = [
            { $0.hunks[0].hunkContent[0].deletionLineIndex = Int.max },
            { $0.hunks[0].hunkContent[0].additionLineIndex = Int.min },
            { $0.hunks[0].hunkContent[0].additions = Int.max },
            { $0.hunks[0].hunkContent[0].deletions = -1 },
            { $0.hunks[0].deletionStart = Int.min },
            { $0.hunks[0].additionStart = Int.max; $0.hunks[0].additionCount = Int.max },
            { $0.isPartial = true; $0.hunks[0].collapsedBefore = Int.max },
            { $0.isPartial = true; $0.hunks[0].collapsedBefore = Int.max - 2 }
        ]
        for mutation in mutations {
            var input = base; mutation(&input)
            #expect(throws: DiffError.self) { try diffAcceptRejectHunk(input, hunkIndex: 0, resolution: .both) }
        }
        // Callers' value metadata is unchanged after rejected resolutions.
        #expect(base.additionLines == ["new\n"] && base.deletionLines == ["old\n"])
    }
}

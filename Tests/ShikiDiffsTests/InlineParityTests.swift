import Testing
import Foundation
@testable import ShikiDiffs

@Suite struct InlineParityTests {
    struct Ranges: Decodable { var deletions: [[Int]]; var additions: [[Int]] }
    struct Fixture: Decodable { var old: String; var next: String; var type: String; var maxLength: Int; var expected: Ranges }
    @Test func upstreamInlineRanges() throws {
        let url = fixtureURL("inline-oracle")!
        for (index, fixture) in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)).enumerated() {
            let actual = inlineDiff(fixture.old, fixture.next, type: LineDiffType(rawValue: fixture.type)!, maxLength: fixture.maxLength)
            #expect(actual.deletions.map { [$0.range.location, $0.range.length] } == fixture.expected.deletions, "deletions fixture \(index)")
            #expect(actual.additions.map { [$0.range.location, $0.range.length] } == fixture.expected.additions, "additions fixture \(index)")
        }
    }
}

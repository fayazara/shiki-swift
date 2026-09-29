import Foundation
import Testing
@testable import ShikiDiffs

@Suite struct DiffOptionsTests {
    struct Fixture: Decodable {
        var name: String
        var oldFile: FileContents
        var newFile: FileContents
        var options: DiffOptions
        var expected: FileDiffMetadata?
        var error: String?
    }
    @Test func upstreamOptionOracle() throws {
        let url = fixtureURL("options-oracle")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for (index, fixture) in fixtures.enumerated() {
            if let expected = fixture.expected {
                let actual = try parseDiffFromFile(fixture.oldFile, fixture.newFile, options: fixture.options)
                #expect(actual == expected, "Option case \(index): \(fixture.name), \(fixture.options)")
            } else {
                #expect(throws: DiffError.self) { try parseDiffFromFile(fixture.oldFile, fixture.newFile, options: fixture.options) }
            }
        }
    }
    @Test func unlimitedContextAndOriginalLineEndings() throws {
        let old = FileContents(name: "a.txt", contents: "first\r\nold\r\nlast\r\n")
        let new = FileContents(name: "b.txt", contents: "first\nnew\nlast\n")
        let result = try parseDiffFromFile(old, new, options: .init(context: .max, stripTrailingCr: true))
        #expect(result.hunks.count == 1)
        #expect(result.hunks[0].deletionCount == 3)
        #expect(result.additions == 1); #expect(result.deletions == 1)
        #expect(result.deletionLines.joined() == old.contents)
        #expect(result.additionLines.joined() == new.contents)
        let same = try parseDiffFromFile(old, .init(name: "b.txt", contents: "first\nold\nlast\n"), options: .init(stripTrailingCr: true))
        #expect(same.type == .renamePure); #expect(same.hunks.isEmpty)
    }
    @Test func stripTrailingCrSessionRebuildsBalancedChanges() throws {
        let options = DiffOptions(stripTrailingCr: true)
        let initial = try parseDiffFromFile(.init(name: "f.swift", contents: "let value = 1\r\n"),
                                           .init(name: "f.swift", contents: "let value = 2\r\n"), options: options)
        var session = try DiffEditSession(diff: initial, options: options)
        try session.updateLines([0: "let value = 1\n"])
        #expect(session.diff.additions == 0); #expect(session.diff.deletions == 0)
        #expect(!session.diff.hunks.isEmpty)
        try session.finish()
        #expect(session.diff.hunks.isEmpty)
        #expect(session.diff.deletionLines == ["let value = 1\r\n"])
        #expect(session.diff.additionLines == ["let value = 1\n"])
    }
}

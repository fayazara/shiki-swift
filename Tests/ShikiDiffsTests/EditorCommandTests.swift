import Foundation
import Testing
@testable import ShikiDiffs

@Suite struct EditorCommandTests {
    struct Edit: Decodable { var range: ShikiDiffs.TextRange; var newText: String }
    struct LineFixture: Decodable {
        struct Result: Decodable { var edits: [Edit]; var selections: [EditorSelection] }
        var text: String; var selections: [EditorSelection]; var command: EditorLineCommand; var expected: Result
    }
    struct CommentFixture: Decodable {
        var text: String; var selections: [EditorSelection]; var kind: String; var token: String?
        var tokens: [String]?; var linewise: Bool?; var edits: [Edit]?; var offsets: [[Int]]?
    }
    func compare(_ actual: [TextEdit], _ expected: [Edit], index: Int) {
        #expect(actual.count == expected.count, "Command edit count \(index)")
        for (a, b) in zip(actual, expected) { #expect(a.range == b.range && a.newText.utf16.elementsEqual(b.newText.utf16), "Command edit \(index)") }
    }
    @Test func upstreamLineCommandOracle() throws {
        let url = fixtureURL("line-command-oracle")!
        for (index, fixture) in try JSONDecoder().decode([LineFixture].self, from: Data(contentsOf: url)).enumerated() {
            let result = resolveLineCommandEdits(TextDocument(uri: "test", text: fixture.text), selections: fixture.selections, command: fixture.command)
            compare(result.edits, fixture.expected.edits, index: index)
            #expect(result.selections == fixture.expected.selections, "Line command selection \(index)")
        }
    }
    @Test func upstreamCommentOracle() throws {
        let url = fixtureURL("comment-oracle")!
        for (index, fixture) in try JSONDecoder().decode([CommentFixture].self, from: Data(contentsOf: url)).enumerated() {
            let document = TextDocument(uri: "test", text: fixture.text)
            if fixture.kind == "line" { compare(resolveLineCommentEdits(document, selections: fixture.selections, token: fixture.token!), fixture.edits!, index: index) }
            else {
                let tokens = fixture.tokens!
                let result = resolveBlockCommentEdits(document, selections: fixture.selections, tokens: .init(tokens[0], tokens[1]), linewise: fixture.linewise!)
                #expect((result == nil) == (fixture.edits == nil), "Comment result \(index)")
                if let result, let edits = fixture.edits {
                    compare(result.edits, edits, index: index)
                    #expect(result.nextSelectionOffsets.map { [$0.start, $0.end, $0.direction.rawValue] } == fixture.offsets, "Comment offsets \(index)")
                }
            }
        }
    }
    @Test func upstreamLanguageCommentConfiguration() throws {
        struct Fixture: Decodable {
            struct Expected: Decodable { var lineComment: String?; var blockComment: [String] }
            var language: String; var expected: Expected
        }
        let url = fixtureURL("comment-config-oracle")!
        for fixture in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)) {
            let result = resolveCommentConfig(fixture.language)
            #expect(result.lineComment == fixture.expected.lineComment)
            #expect([result.blockComment.open, result.blockComment.close] == fixture.expected.blockComment)
        }
        let custom = resolveCommentConfig("python", overrides: ["python": .init(lineComment: .disabled, blockComment: .init("<", ">"))])
        #expect(custom.lineComment == nil); #expect(custom.blockComment == .init("<", ">"))
    }
}

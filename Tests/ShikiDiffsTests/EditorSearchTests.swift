import Foundation
import Testing
@testable import ShikiDiffs

@Suite struct EditorSearchTests {
    struct Fixture: Decodable {
        var text: String; var params: EditorSearchParams; var matches: [[Int]]; var replacements: [String]?
    }
    @Test func upstreamSearchOracle() throws {
        let url = fixtureURL("search-oracle")!
        for (index, fixture) in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)).enumerated() {
            let document = TextDocument(uri: "test", text: fixture.text)
            let result = try document.search(fixture.params)
            #expect(result.map { [$0.location, NSMaxRange($0)] } == fixture.matches, "Search case \(index), \(fixture.params)")
            if let expected = fixture.replacements {
                for (match, replacement) in zip(result, expected) {
                    let actual = try buildSearchReplacementText(document, params: fixture.params, match: match)
                    #expect(actual.utf16.elementsEqual(replacement.utf16), "Replacement case \(index), \(fixture.params)")
                }
            }
        }
    }
    @Test func boundedResultsAndLineSearchPerformance() throws {
        let text = String(repeating: "let value = 42; // value\n", count: 60_000)
        let document = TextDocument(uri: "test.swift", text: text)
        let clock = ContinuousClock(), start = clock.now
        let matches = try document.search(.init(text: "value", wholeWord: true))
        let elapsed = start.duration(to: clock.now)
        print("Native search: \(text.utf8.count) bytes / \(matches.count) matches in \(elapsed)")
        #expect(matches.count == 100_000)
        #expect(elapsed < .seconds(3))
        #expect(try document.search(.init(text: "value\\nlet", regex: false)).isEmpty)
        #expect(try document.search(.init(text: "[", regex: true)).isEmpty)
        #expect(try document.search(.init(text: "^", regex: true)).isEmpty)
    }
    @Test func nativeECMAScriptSemantics() throws {
        let document = TextDocument(uri: "test", text: "😀\n١ 1\nK K\nword\u{00a0}word")
        #expect(try document.search(.init(text: "😀")).map(\.length) == [2])
        #expect(try document.search(.init(text: "😀", regex: true)).map(\.length) == [2])
        let dots = try document.search(.init(text: ".", regex: true))
        #expect(dots.prefix(2).map(\.length) == [1, 1])
        #expect(try document.search(.init(text: "\\d", regex: true)).count == 1)
        #expect(try document.search(.init(text: "k", regex: true)).count == 1)
        #expect(try document.search(.init(text: "word", wholeWord: true)).isEmpty)
    }
    @Test func replacementBatchReusesLargeLine() throws {
        let document = TextDocument(uri: "test", text: String(repeating: "word42 ", count: 15_000))
        let clock = ContinuousClock(), start = clock.now
        let edits = try buildSearchReplacementEdits(document, params: .init(text: "(word)([0-9]+)", replaceText: "$2:$1", regex: true))
        let elapsed = start.duration(to: clock.now)
        print("Regex replacement batch: \(edits.count) matches on one long line in \(elapsed)")
        #expect(edits.count == 15_000)
        #expect(edits.allSatisfy { $0.newText == "42:word" })
        #expect(elapsed < .seconds(3))
    }

}

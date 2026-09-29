import Foundation
import Testing
@testable import ShikiDiffs

@Suite struct EditorSelectionTests {
    struct NavigationFixture: Decodable {
        var text: String
        var softLineOffsets: [Int: [Int]]?
        var renderableLines: [Int]?
        var selection: EditorSelection
        var movement: EditorCursorMovement
        var shift: Bool
        var expected: EditorSelection
    }
    struct DeletionFixture: Decodable {
        var text: String
        var selection: EditorSelection
        var kind: String
        var expected: ShikiDiffs.TextRange
    }
    @Test func upstreamNavigationOracle() throws {
        let url = fixtureURL("selection-oracle")!
        let fixtures = try JSONDecoder().decode([NavigationFixture].self, from: Data(contentsOf: url))
        for (index, fixture) in fixtures.enumerated() {
            let document = TextDocument(uri: "test", text: fixture.text)
            let layout = EditorCursorLayout(softLineOffsets: fixture.softLineOffsets, renderableLines: fixture.renderableLines)
            let actual = fixture.shift
                ? mapSelectionShift(document, selections: [fixture.selection], movement: fixture.movement, layout: layout)
                : mapCursorMove(document, selections: [fixture.selection], movement: fixture.movement, layout: layout)
            #expect(actual == [fixture.expected], "Navigation case \(index), \(fixture.movement), shift \(fixture.shift)")
        }
    }
    @Test func upstreamDeletionOracle() throws {
        let url = fixtureURL("deletion-oracle")!
        let fixtures = try JSONDecoder().decode([DeletionFixture].self, from: Data(contentsOf: url))
        for (index, fixture) in fixtures.enumerated() {
            let document = TextDocument(uri: "test", text: fixture.text)
            let actual = fixture.kind == "wordBackward"
                ? resolveDeleteWordBackwardRange(document, selection: fixture.selection)
                : resolveDeleteHardLineForwardRange(document, selection: fixture.selection)
            #expect(actual == fixture.expected, "Deletion case \(index), \(fixture.kind)")
        }
    }
    struct IndentFixture: Decodable {
        struct Edit: Decodable { var range: ShikiDiffs.TextRange; var newText: String }
        var text: String
        var selection: EditorSelection
        var tabSize: Int
        var outdent: Bool
        var edits: [Edit]
        var nextSelection: EditorSelection
    }
    @Test func upstreamIndentationOracle() throws {
        let url = fixtureURL("indent-oracle")!
        let fixtures = try JSONDecoder().decode([IndentFixture].self, from: Data(contentsOf: url))
        for (index, fixture) in fixtures.enumerated() {
            let document = TextDocument(uri: "test", text: fixture.text)
            let actual = resolveIndentEdits(document, selection: fixture.selection, tabSize: fixture.tabSize, outdent: fixture.outdent)
            #expect(actual.selection == fixture.nextSelection, "Indent selection \(index)")
            #expect(actual.edits.count == fixture.edits.count, "Indent edit count \(index)")
            for (a, b) in zip(actual.edits, fixture.edits) {
                #expect(a.range == b.range && a.newText.utf16.elementsEqual(b.newText.utf16), "Indent edit \(index)")
            }
        }
    }

}

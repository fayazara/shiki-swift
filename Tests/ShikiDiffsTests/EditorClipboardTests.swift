import Foundation
import Testing
@testable import ShikiDiffs

@Suite struct EditorClipboardTests {
    struct Fixture: Decodable {
        struct Cut: Decodable {
            struct Edit: Decodable { var start: Int; var end: Int; var text: String }
            var text: String; var edits: [Edit]; var nextSelectionOffsets: [Int]
        }
        var text: String; var selections: [EditorSelection]; var clipboard: [String]; var expected: Cut
    }
    @Test func upstreamClipboardOracle() throws {
        let url = fixtureURL("clipboard-oracle")!
        for (index, fixture) in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)).enumerated() {
            let document = TextDocument(uri: "test", text: fixture.text)
            #expect(getSelectionClipboardTexts(document, selections: fixture.selections) == fixture.clipboard, "Clipboard values \(index)")
            let cut = resolveSelectionCut(document, selections: fixture.selections)
            #expect(cut.text.utf16.elementsEqual(fixture.expected.text.utf16), "Clipboard text \(index)")
            #expect(cut.nextSelectionOffsets == fixture.expected.nextSelectionOffsets, "Cut selections \(index)")
            #expect(cut.edits.count == fixture.expected.edits.count, "Cut edit count \(index)")
            for (a, b) in zip(cut.edits, fixture.expected.edits) {
                #expect(a.range == .init(location: b.start, length: b.end - b.start) && a.newText == b.text, "Cut edit \(index)")
            }
        }
    }
}

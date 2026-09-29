import Foundation
import Testing
@testable import ShikiDiffs

@Suite struct BatchEditingTests {
    @Test func largeReplacementAndUndo() throws {
        let source = String(repeating: "let value = 42;\n", count: 30_000)
        var document = TextDocument(uri: "test", text: source)
        let edits = try buildSearchReplacementEdits(document, params: .init(text: "value", replaceText: "renamed"))
        let clock = ContinuousClock(), start = clock.now
        try document.applyResolvedEdits(edits)
        let applied = start.duration(to: clock.now)
        #expect(document.getText() == source.replacingOccurrences(of: "value", with: "renamed"))
        let undoStart = clock.now
        document.undo()
        let undone = undoStart.duration(to: clock.now)
        #expect(document.getText() == source)
        #expect(document.lineCount == 30_001)
        document.redo()
        #expect(document.getLineText(29_999) == "let renamed = 42;")
        print("30,000 replacement edits: apply \(applied), undo \(undone)")
        #expect(applied < .seconds(3)); #expect(undone < .seconds(3))
    }
    @Test func fragmentedBatchesPreserveTextAndLineIndexes() throws {
        var document = TextDocument(uri: "test", text: "alpha\r\nbeta\r\ngamma\r\n"), reference = document.getText()
        var seed: UInt64 = 9182
        func random(_ limit: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int(seed >> 32) % max(1, limit) }
        for step in 0..<150 {
            let original = reference as NSString
            var cursor = 0, edits: [ResolvedTextEdit] = []
            while cursor < original.length && edits.count < 5 {
                let start = min(original.length, cursor + random(5)), end = min(original.length, start + random(3))
                let text = ["x", "", "a\r\nb", " ", "\r\n"][random(5)]
                edits.append(.init(range: .init(location: start, length: end - start), newText: text))
                cursor = end + 1
            }
            if edits.isEmpty { edits = [.init(range: .init(location: 0, length: 0), newText: "restored\r\n")] }
            let before = reference
            for edit in edits.reversed() { reference = (reference as NSString).replacingCharacters(in: edit.range, with: document.normalizeEol(edit.newText)) }
            try document.applyResolvedEdits(edits)
            #expect(document.getText() == reference, "Batch \(step)")
            let flat = TextDocument(uri: "reference", text: reference)
            #expect(document.lineCount == flat.lineCount)
            for offset in 0...document.utf16Length { #expect(document.positionAt(offset) == flat.positionAt(offset), "Batch index \(step)") }
            if step % 7 == 0 {
                document.undo(); #expect(document.getText() == before)
                document.redo(); #expect(document.getText() == reference)
            }
        }
    }
}

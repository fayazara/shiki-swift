import Testing
import Foundation
@testable import ShikiDiffs

@Suite struct EditingTests {
    @Test func utf16PositionsAndCRLF() {
        let doc = TextDocument(uri: "f.swift", text: "a😀b\r\nsecond\r\n")
        #expect(doc.lineCount == 3); #expect(doc.eol == "\r\n")
        #expect(doc.offsetAt(.init(line: 0, character: 3)) == 3)
        #expect(doc.positionAt(5) == .init(line: 0, character: 4))
        #expect(doc.positionAt(6) == .init(line: 1, character: 0))
        #expect(doc.getLineText(0) == "a😀b")
        #expect(doc.offsetAt(.init(line: 100, character: 100)) == doc.utf16Length)
    }
    @Test func editBatchUndoRedoAndAtomicFailure() throws {
        var doc = TextDocument(uri: "f", text: "one\ntwo\nthree\n")
        try doc.applyResolvedEdits([.init(range: NSRange(location: 0, length: 3), newText: "ONE"), .init(range: NSRange(location: 8, length: 5), newText: "THREE\nFOUR")])
        #expect(doc.getText() == "ONE\ntwo\nTHREE\nFOUR\n"); #expect(doc.lineCount == 5)
        #expect(doc.version == 1); doc.undo(); #expect(doc.getText() == "one\ntwo\nthree\n"); #expect(doc.version == 0)
        doc.redo(); #expect(doc.getText() == "ONE\ntwo\nTHREE\nFOUR\n"); #expect(doc.version == 1)
        let before = doc.getText()
        #expect(throws: TextDocumentError.self) { try doc.applyResolvedEdits([.init(range: NSRange(location: 0, length: 4), newText: "a"), .init(range: NSRange(location: 2, length: 4), newText: "b")]) }
        #expect(doc.getText() == before)
    }
    @Test func pieceTableAndIncrementalLineIndexAgainstFlatString() throws {
        var doc = TextDocument(uri: "f", text: "start\nalpha\nbeta\nend\n", editStack: .init(maxEntries: 500))
        let original = doc.getText()
        let flat = NSMutableString(string: original)
        var seed: UInt64 = 412
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(max(n, 1))) }
        for _ in 0..<300 {
            let start = random(flat.length + 1), length = random(min(flat.length - start, 6) + 1)
            let text = ["x", "\n", "ab\ncd", "", " "][random(5)]
            try doc.applyResolvedEdits([.init(range: NSRange(location: start, length: length), newText: text)])
            flat.replaceCharacters(in: NSRange(location: start, length: length), with: text)
            #expect(doc.getText() == flat as String)
            let oracle = TextDocument(uri: "f", text: flat as String)
            #expect(doc.lineCount == oracle.lineCount)
            for i in 0...flat.length { #expect(doc.positionAt(i) == oracle.positionAt(i)) }
        }
        let final = doc.getText()
        while doc.canUndo { doc.undo() }
        #expect(doc.getText() == original)
        while doc.canRedo { doc.redo() }
        #expect(doc.getText() == final)
    }
    @Test func insertionInsideSurrogateDoesNotCorruptUTF16() throws {
        var doc = TextDocument(uri: "f", text: "a😀b")
        try doc.applyResolvedEdits([.init(range: NSRange(location: 2, length: 0), newText: "x")])
        #expect(doc.getText() == "ax😀b")
        doc.undo(); #expect(doc.getText() == "a😀b")
    }
}

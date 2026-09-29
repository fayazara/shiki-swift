import Foundation
import Testing
@testable import ShikiDiffs

@Suite struct TextDocumentContractTests {
    @Test func positionsCheckedLinesSlicesAndRawCodeUnits() throws {
        let document = TextDocument(uri: "f.txt", text: "a😀b\r\nsecond\r\n")
        #expect(document.positionsAt([Int.min, 3, 5, Int.max]) == [.init(line: 0, character: 0), .init(line: 0, character: 3), .init(line: 0, character: 4), .init(line: 2, character: 0)])
        #expect(document.normalizePosition(.init(line: 1, character: Int.max)) == .init(line: 1, character: 6))
        #expect(try document.getLineLength(0) == 4 && document.getLineLength(0, includeLineBreak: true) == 6)
        #expect(try document.getLineTextChecked(1, includeLineBreak: true) == "second\r\n")
        #expect(throws: TextDocumentError.self) { try document.getLineLength(Int.max) }
        #expect(throws: TextDocumentError.self) { try document.getLineTextChecked(-1) }
        #expect(document.getTextSlice(start: Int.min, end: Int.max) == document.getText())
        #expect(document.getTextSlice(start: 6, end: 0).isEmpty)
        #expect(document.getText(.init(start: .init(line: 1, character: 2), end: .init(line: 0, character: 0))).isEmpty)
        #expect(document.charAt(.init(line: 1, character: 0)) == "s")
        #expect(document.charAt(-1).isEmpty && document.charAt(Int.max).isEmpty)
        #expect(document.utf16CodeUnit(at: 1) == 0xD83D && document.utf16CodeUnit(at: 2) == 0xDE00)
        #expect(document.charAt(1) == "�")
    }
    @Test func replayReturnsInteractionMetadataOrMappingEdits() throws {
        var document = TextDocument(uri: "f.txt", text: "abc")
        let before = EditorSelection(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0))
        let after = EditorSelection(start: .init(line: 0, character: 1), end: .init(line: 0, character: 1))
        try document.applyResolvedEdits([.init(range: .init(location: 0, length: 0), newText: "x")], selectionsBefore: [before], selectionsAfter: [after])
        let annotation = LineAnnotation(id: "note", side: .additions, lineNumber: 1, text: "comment")
        document.setLastUndoLineAnnotations(before: [], after: [annotation])
        let undoResult = document.undoResult(); let undone = try #require(undoResult)
        #expect(undone.selections == [before] && undone.annotations == [] && undone.selectionEdits == nil)
        let redoResult = document.redoResult(); let redone = try #require(redoResult)
        #expect(redone.selections == [after] && redone.annotations == [annotation] && redone.selectionEdits == nil)
        document.clearHistory()
        try document.applyResolvedEdits([.init(range: .init(location: 1, length: 0), newText: "y")], updateHistory: false,
                                       selectionsBefore: [before], selectionsAfter: [after], undoBoundary: true)
        #expect(document.canUndo && document.history.undoStack.last?.undoBoundary == false)
        let mappingResult = document.undoResult(); let mapped = try #require(mappingResult)
        #expect(mapped.selections == nil && mapped.selectionEdits?.first?.range == .init(location: 1, length: 1))
    }
}

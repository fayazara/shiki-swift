import Foundation
import Testing
@testable import ShikiDiffs

@Suite struct AnnotationChangeTests {
    @Test func typedMetadataRetainsIdentityAcrossMapping() throws {
        struct Review: Sendable, Equatable { var author: String; var resolved: Bool }
        let payload = Review(author: "Reviewer", resolved: false)
        let metadata = LineAnnotationMetadata(payload)
        let annotation = LineAnnotation(id: "note", lineNumber: 1, text: "Review", metadata: metadata)
        #expect(metadata.value(as: Review.self) == payload)
        #expect(metadata.value(as: String.self) == nil)
        #expect(metadata != LineAnnotationMetadata(payload))
        var document = TextDocument(uri: "f", text: "one\ntwo")
        let applied = try document.applyResolvedEdits([.init(range: .init(location: 0, length: 0), newText: "new\n")])
        let change = try #require(applied)
        let mapped = try #require(applyDocumentChangeToLineAnnotations(change, annotations: [annotation]))
        #expect(mapped.first?.lineNumber == 2)
        #expect(mapped.first?.metadata === metadata)
    }
    struct Fixture: Decodable {
        struct Edit: Decodable { var range: ShikiDiffs.TextRange; var newText: String }
        struct Annotation: Decodable {
            var id: String; var side: DiffSide; var lineNumber: Int; var text: String
            var value: LineAnnotation { .init(id: id, side: side, lineNumber: lineNumber, text: text) }
        }
        var text: String; var expectedText: String; var edits: [Edit]; var annotations: [Annotation]; var expected: [Annotation]?
    }
    @Test func upstreamAnnotationOracle() throws {
        let url = try #require(fixtureURL("annotation-oracle"))
        for (index, fixture) in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)).enumerated() {
            var document = TextDocument(uri: "f", text: fixture.text)
            let change: TextDocumentChange?
            do { change = try document.applyEdits(fixture.edits.map { .init(range: $0.range, newText: $0.newText) }) }
            catch { Issue.record("Annotation oracle case \(index) rejected: \(error)"); continue }
            let actual = change.flatMap { applyDocumentChangeToLineAnnotations($0, annotations: fixture.annotations.map(\.value)) }
            #expect(actual == fixture.expected?.map(\.value), "Annotation oracle case \(index)")
            #expect(document.getText().utf16.elementsEqual(fixture.expectedText.utf16), "Batch text case \(index)")
            document.undo()
            #expect(document.getText().utf16.elementsEqual(fixture.text.utf16), "Batch undo case \(index)")
            document.redo()
            #expect(document.getText().utf16.elementsEqual(fixture.expectedText.utf16), "Batch redo case \(index)")
        }
    }

    @Test func mapperPreservesIdentityAndFixedSides() throws {
        let annotations: [LineAnnotation] = [
            .init(id: "file", lineNumber: 0, text: "File"),
            .init(id: "old", side: .deletions, lineNumber: 3, text: "Old"),
            .init(id: "first", lineNumber: 1, text: "First"),
            .init(id: "deleted", lineNumber: 3, text: "Deleted"),
            .init(id: "last", lineNumber: 4, text: "Last")
        ]
        var document = TextDocument(uri: "f", text: "aa\nbb\ncc\ndd")
        let applied = try document.applyResolvedEdits([
            .init(range: .init(location: 0, length: 0), newText: "insert\n"),
            .init(range: .init(location: 6, length: 3), newText: "")
        ])
        let change = try #require(applied)
        let mapped = try #require(applyDocumentChangeToLineAnnotations(change, annotations: annotations))
        #expect(mapped.map(\.id) == ["file", "old", "first", "last"])
        #expect(mapped.map(\.lineNumber) == [0, 3, 2, 4])
        #expect(mapped.map(\.text) == ["File", "Old", "First", "Last"])
    }
    @Test func mapperDistinguishesInsertionColumn() throws {
        for column in [0, 1] {
            var document = TextDocument(uri: "f", text: "abc\ndef")
            let applied = try document.applyResolvedEdits([.init(range: .init(location: column, length: 0), newText: "\n")])
            let change = try #require(applied)
            let result = try #require(applyDocumentChangeToLineAnnotations(change, annotations: [.init(lineNumber: 1, text: "Note")]))
            #expect(result.first?.lineNumber == (column == 0 ? 2 : 1))
        }
    }

    @Test func batchesRetainConstituentChangesThroughHistory() throws {
        var document = TextDocument(uri: "f.txt", text: "aa\nbb\ncc\ndd")
        let applied = try document.applyResolvedEdits([
            .init(range: .init(location: 0, length: 0), newText: "insert\n"),
            .init(range: .init(location: 6, length: 3), newText: "")
        ])
        let change = try #require(applied)
        #expect(change.lineDelta == 0)
        #expect(change.changedLineChanges.map(\.lineDelta) == [1, -1])
        #expect(change.changedLineChanges.map(\.startLine) == [0, 3])
        #expect(change.changedLineChanges.map(\.endLine) == [1, 3])
        let undone = document.undo()
        let undo = try #require(undone)
        #expect(undo.changedLineChanges.map(\.lineDelta) == [-1, 1])
        #expect(document.getText() == "aa\nbb\ncc\ndd")
        let redone = document.redo()
        #expect(redone?.changedLineChanges == change.changedLineChanges)
    }
    @Test func partialLineAndDocumentEndAreRecorded() throws {
        var document = TextDocument(uri: "f.txt", text: "aa\r\nbb\r\ncc")
        let applied = try document.applyResolvedEdits([
            .init(range: .init(location: 1, length: 9), newText: "x\r\ny")
        ])
        let change = try #require(applied)
        let edit = try #require(change.changedLineChanges.first)
        #expect(edit.startCharacter == 1)
        #expect(edit.endCharacter == 2)
        #expect(edit.endedAtDocumentEnd)
        #expect(edit.lineDelta == -1)
        #expect(edit.endLine == 1)
    }
}

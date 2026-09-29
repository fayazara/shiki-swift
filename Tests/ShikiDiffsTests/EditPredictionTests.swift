import Foundation
import CryptoKit
import Testing
@testable import ShikiDiffs

struct EditPredictionTests {
    struct Request: Decodable {
        var text: String; var cursor: Int; var blocked: [Int]; var history: [EditPredictionHistoryRecord]; var expected: EditPredictRequest?
    }
    struct Action: Decodable {
        var kind: String; var edits: [EditHistoryTests.Edit]?; var gap: Double; var at: Double; var source: EditPredictionSource; var path: String
        var expected: String
    }
    struct History: Decodable { var text: String; var actions: [Action] }
    struct Pattern: Decodable { var path: String; var pattern: String; var flags: String?; var expected: Bool }
    struct Fixture: Decodable { var requests: [Request]; var histories: [History]; var patterns: [Pattern] }
    func fixture() throws -> Fixture {
        let url = try #require(fixtureURL("prediction-oracle"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    @Test func boundedRequestsMatchActualUpstream() throws {
        for (index, test) in try fixture().requests.enumerated() {
            let document = TextDocument(uri: "a.ts", text: test.text, version: 17)
            var calls: [Int: Int] = [:]
            let result = buildEditPredictionRequest(path: "a.ts", document: document, cursorOffset: test.cursor, history: test.history) { line in
                calls[line, default: 0] += 1; return !test.blocked.contains(line)
            }
            #expect(result == test.expected, "Request \(index)")
            #expect(calls.values.allSatisfy { $0 == 1 })
        }
        let document = TextDocument(uri: "a", text: "😀\r\nnext")
        #expect(buildEditPredictionRequest(path: "a", document: document, cursorOffset: Int.min)?.cursorOffsetInExcerpt == 0)
        #expect(buildEditPredictionRequest(path: "a", document: document, cursorOffset: Int.max)?.cursorOffsetInExcerpt == 8)
    }
    @Test func boundedHistoryAndUndoTransactionsMatchActualUpstream() throws {
        for (index, test) in try fixture().histories.enumerated() {
            var document = TextDocument(uri: "a.ts", text: test.text), history: [EditPredictionHistoryRecord] = [], at = 0.0
            for (step, action) in test.actions.enumerated() {
                if action.kind == "undo" { document.undo() }
                else if action.kind == "redo" { document.redo() }
                else { try document.applyResolvedEdits(action.edits!.map(\.native)) }
                at = action.at
                let transaction = try #require(document.lastChangeTransaction)
                history = recordEditPrediction(history: history, path: action.path, document: document, transaction: transaction, source: action.source, at: at)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let digest = SHA256.hash(data: try encoder.encode(history)).map { String(format: "%02x", $0) }.joined()
                #expect(digest == action.expected, "History \(index):\(step)")
                #expect(history.count <= 10 && history.allSatisfy { $0.hunk.utf8.count <= 6144 })
            }
        }
    }
    @Test func globAndECMAScriptFlagsMatchActualUpstream() throws {
        for test in try fixture().patterns {
            let pattern: EditPredictionPattern = test.flags.map { .regex(test.pattern, flags: $0) } ?? .glob(test.pattern)
            #expect(matchesEditPredictionPattern(path: test.path, pattern: pattern) == test.expected, "\(test.path):\(test.pattern):\(test.flags ?? "glob")")
        }
        for flags in ["ii", "uv", "z"] { #expect(!matchesEditPredictionPattern(path: "a", pattern: .regex("a", flags: flags))) }
        #expect(!matchesEditPredictionPattern(path: "a", pattern: .regex("[")))
        #expect(matchesEditPredictionPattern(path: "a😀b", pattern: .glob("a😀b")))
    }
    @Test func responseValidationRejectsUnsafeAndStaleEdits() throws {
        let document = TextDocument(uri: "a", text: "a😀b\nsecond\nlast", version: 7)
        let request = try #require(buildEditPredictionRequest(path: "a", document: document, cursorOffset: 0))
        func edit(_ start: Int, _ end: Int, _ text: String) -> TextEdit {
            .init(range: .init(start: .init(line: 0, character: start), end: .init(line: 0, character: end)), newText: text)
        }
        func valid(_ edits: [TextEdit], _ cursor: TextPosition = .init(line: 0, character: 0), _ request: EditPredictRequest? = nil) -> EditPredictResponse? {
            validateEditPredictionResponse(.init(edits: edits, newCursor: cursor), request: request ?? requestValue, document: document)
        }
        let requestValue = request
        let replacement = edit(1, 3, "XY\nZ")
        let result = try #require(valid([replacement], .init(line: 1, character: 2)))
        #expect(result.edits.count == 1 && result.newCursor == .init(line: 1, character: 2))
        #expect(document.getText() == "a😀b\nsecond\nlast")
        #expect(valid([edit(2, 2, "x")]) == nil)
        #expect(valid([edit(1, 2, "x")]) == nil)
        #expect(valid([edit(-1, 0, "x")]) == nil)
        #expect(valid([edit(0, 99, "x")]) == nil)
        #expect(valid([edit(3, 1, "x")]) == nil)
        #expect(valid([edit(0, 3, "x"), edit(1, 4, "y")]) == nil)
        #expect(valid([edit(0, 1, "a")]) == nil)
        #expect(valid([edit(0, 0, String(repeating: "x", count: 128 * 1024 + 1))]) == nil)
        #expect(valid(Array(repeating: edit(0, 0, "x"), count: 257)) == nil)
        #expect(valid([edit(0, 0, "x")], .init(line: Int.max, character: 0)) == nil)
        #expect(valid([edit(0, 0, "x")], .init(line: 0, character: 3)) == nil) // post-edit surrogate interior
        #expect(valid([replacement], .init(line: 3, character: 4)) != nil) // unchanged trailing line maps back
        #expect(valid([replacement], .init(line: 3, character: 5)) == nil)
        var stale = request; stale.version -= 1; #expect(valid([replacement], .init(line: 0, character: 0), stale) == nil)
        var bounded = request; bounded.editableRange = .init(start: 0, end: 1)
        #expect(valid([replacement], .init(line: 0, character: 0), bounded) == nil)
        #expect(valid([edit(0, 0, "x"), edit(0, 0, "y")])?.edits.count == 2)
    }
    @Test func hugeLinesAndMalformedTransactionStayBounded() throws {
        var document = TextDocument(uri: "large", text: String(repeating: "x", count: 1_000_000))
        let start = ContinuousClock.now
        for _ in 0..<100 { #expect(buildEditPredictionRequest(path: "large", document: document, cursorOffset: 500_000) == nil) }
        #expect(start.duration(to: .now) < .seconds(1))
        try document.applyResolvedEdits([.init(range: .init(location: 500_000, length: 1), newText: "y")])
        let transaction = try #require(document.lastChangeTransaction)
        #expect(recordEditPrediction(history: [], path: "large", document: document, transaction: transaction, source: .user).isEmpty)
        let invalid = TextDocumentChangeTransaction(appliedEdits: [], inverseEdits: [.init(range: .init(location: Int.max, length: Int.max), newText: "")])
        #expect(recordEditPrediction(history: [], path: "large", document: document, transaction: invalid, source: .user).isEmpty)
    }

}

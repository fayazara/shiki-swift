import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct BracketMatchingTests {
    @Test func adjacencyNestingAndLineLocalBoundaries() {
        let document = TextDocument(uri: "f", text: "((x))[]\nnext\n{\n}\n")
        func match(_ line: Int, _ column: Int) -> [ShikiDiffs.TextRange]? { findBracketMatchRanges(document, position: .init(line: line, character: column)) }
        #expect(match(0, 1)?.map(\.start.character) == [0, 4])
        #expect(match(0, 2)?.map(\.start.character) == [1, 3])
        #expect(match(0, 5)?.map(\.start.character) == [0, 4])
        #expect(match(0, 7)?.map(\.start.character) == [5, 6])
        #expect(match(1, 0) == nil)
        #expect(match(3, 1)?.map(\.start.line) == [2, 3])
        #expect(findBracketMatchRanges(TextDocument(uri: "f", text: "<x>"), position: .init(line: 0, character: 0)) == nil)
    }
    @Test func ignoredRangesWorkInBothDirections() {
        let document = TextDocument(uri: "f", text: "(\")\" /* ( */ [x])")
        let ranges = [NSRange(location: 1, length: 3), NSRange(location: 5, length: 7)]
        for column in [0, document.utf16Length] {
            let result = findBracketMatchRanges(document, position: .init(line: 0, character: column)) { _ in ranges }
            #expect(result?.map(\.start.character) == [0, document.utf16Length - 1])
        }
        #expect(findBracketMatchRanges(document, position: .init(line: 0, character: 3)) { _ in ranges } == nil)
    }
    @Test func scansStopAtExactCharacterAndLineLimits() {
        for count in [49_998, 49_999, 1_000_000] {
            let text = "(" + String(repeating: "x", count: count) + ")"
            let document = TextDocument(uri: "f", text: text)
            for column in [0, document.utf16Length] {
                let result = findBracketMatchRanges(document, position: .init(line: 0, character: column)) { _ in [.init(location: 1, length: count)] }
                #expect((result != nil) == (count == 49_998))
            }
        }
        for count in [999, 1_000] {
            let document = TextDocument(uri: "f", text: "(" + String(repeating: "\n", count: count) + ")")
            #expect((findBracketMatchRanges(document, position: .init(line: 0, character: 0)) != nil) == (count == 999))
        }
    }
    @Test func surroundingModesAndMultipleSelections() {
        let document = TextDocument(uri: "f", text: "😀word")
        let ranges = [EditorSelection(start: .init(line: 0, character: 0), end: .init(line: 0, character: 2)),
                      EditorSelection(start: .init(line: 0, character: 2), end: .init(line: 0, character: 6))]
        #expect(getAutoSurroundReplacementTexts(document, selections: ranges, character: "(") == ["(😀)", "(word)"])
        #expect(getAutoSurroundReplacementTexts(document, selections: ranges, character: "'", autoSurround: .brackets) == nil)
        #expect(getAutoSurroundReplacementTexts(document, selections: ranges, character: "<", autoSurround: .quotes) == nil)
        #expect(getAutoSurroundReplacementTexts(document, selections: ranges, character: "`", autoSurround: .languageDefined) == ["`😀`", "`word`"])
        #expect(getAutoSurroundReplacementTexts(document, selections: ranges, character: "(", autoSurround: .never) == nil)
        #expect(getAutoSurroundReplacementTexts(document, selections: [], character: "(") == nil)
    }
    @Test @MainActor func nativeTypingSurroundsSelectionWithUndoButNotMarkedText() async throws {
        let file = FileContents(name: "f.txt", contents: "😀word")
        let view = NativeDiffView(); view.render(try await DiffHighlighter().prepare(oldFile: file, newFile: file))
        let editor = try view.beginEditing(); editor.select(.init(location: 0, length: 2))
        editor.insertText("(", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.getText() == "(😀)word")
        #expect(editor.selectedRange() == .init(location: 1, length: 2))
        editor.undo(nil); #expect(editor.getText() == "😀word" && editor.selectedRange() == .init(location: 0, length: 2))
        editor.redo(nil); #expect(editor.selectedText == "😀")
        editor.autoSurround = .never
        editor.insertText("[", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.getText() == "([)word")
        editor.select(.init(location: 1, length: 1)); editor.autoSurround = .default
        editor.setMarkedText("候補", selectedRange: .init(location: 0, length: 2), replacementRange: .init(location: NSNotFound, length: 0))
        editor.insertText("{", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.getText() == "({)word")
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func nativeMatchesUseSyntaxAndRefreshAfterUndoAndEdits() async throws {
        let file = FileContents(name: "f.ts", contents: "const f = (x: string) => { return \"}\"; /* } */ };\n")
        let view = NativeDiffView(); view.render(try await DiffHighlighter().prepare(oldFile: file, newFile: file))
        let editor = try view.beginEditing(); await editor.waitForRendering()
        let text = editor.getText() as NSString
        let open = text.range(of: "{").location, close = text.range(of: "};").location
        editor.select(.init(location: open + 1, length: 0))
        #expect(editor.bracketMatchRanges.map(\.start.character) == [open, close])
        editor.select(.init(location: text.range(of: "\"}\"").location + 2, length: 0))
        #expect(editor.bracketMatchRanges.isEmpty)
        editor.select(.init(location: open, length: 0)); editor.matchBrackets = false
        #expect(editor.bracketMatchRanges.isEmpty)
        editor.matchBrackets = true; #expect(editor.bracketMatchRanges.count == 2)
        editor.insertText("x", replacementRange: .init(location: 0, length: 0))
        #expect(editor.bracketMatchRanges.isEmpty)
        await editor.waitForRendering(); editor.select(.init(location: open + 1, length: 0))
        #expect(editor.bracketMatchRanges.map(\.start.character) == [open + 1, close + 1])
        editor.undo(nil); await editor.waitForRendering(); editor.select(.init(location: open, length: 0))
        #expect(editor.bracketMatchRanges.map(\.start.character) == [open, close])
        _ = try await editor.complete(.discard)
    }
}

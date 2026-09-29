import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct NativeEditorNavigationTests {
    @Test @MainActor func nativeWordAndParagraphDestinationsMatchTextView() {
        let reference = NSTextView(frame: .init(x: 0, y: 0, width: 1000, height: 300))
        let commands: [(String, NativeEditorNavigation)] = [
            ("moveWordBackward:", .wordBackward), ("moveWordForward:", .wordForward),
            ("moveToBeginningOfParagraph:", .paragraphStart), ("moveToEndOfParagraph:", .paragraphEnd),
            ("moveParagraphBackwardAndModifySelection:", .paragraphBackward), ("moveParagraphForwardAndModifySelection:", .paragraphForward)
        ]
        for text in ["abc def\n  ghi\n\nlast", "foo++ bar  \n\t  \n baz", "日本語 👨‍👩‍👧‍👦 cafe\u{301}\n世界", "a\r\nb\r\n", "   \n\n  ", ""] {
            reference.string = text
            let document = TextDocument(uri: "test", text: text)
            var offsets = [0], offset = 0
            for character in text { offset += String(character).utf16.count; offsets.append(offset) }
            for offset in offsets {
                let position = document.positionAt(offset)
                guard document.offsetAt(position) == offset else { continue }
                for (selector, movement) in commands {
                    reference.setSelectedRange(.init(location: offset, length: 0))
                    reference.doCommand(by: NSSelectorFromString(selector))
                    let range = reference.selectedRange(), expected = movement.forward ? NSMaxRange(range) : range.location
                    let actual = document.offsetAt(nativeEditorDestination(document, from: position, movement: movement))
                    #expect(actual == expected, "\(selector), offset \(offset), \(text.debugDescription): \(actual) vs \(expected)")
                }
            }
        }
    }
    @Test func wordMovementSkipsFoldedLinesAndParagraphIgnoresSoftWrap() {
        let document = TextDocument(uri: "test", text: "first\nhidden\n  final word\nlast")
        let layout = EditorCursorLayout(softLineOffsets: [2: [0, 6, 12]], renderableLines: [0, 2, 3])
        #expect(nativeEditorDestination(document, from: .init(line: 0, character: 5), movement: .wordForward, layout: layout) == .init(line: 2, character: 7))
        #expect(nativeEditorDestination(document, from: .init(line: 2, character: 2), movement: .wordBackward, layout: layout) == .init(line: 0, character: 0))
        #expect(nativeEditorDestination(document, from: .init(line: 2, character: 6), movement: .paragraphEnd, layout: layout) == .init(line: 2, character: 12))
        #expect(nativeEditorDestination(document, from: .init(line: 2, character: 0), movement: .paragraphBackward, layout: layout) == .init(line: 0, character: 0))
    }
    @Test @MainActor func multiCaretWordSelectionDeletionAndUndo() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, _, editor) = try await helper.mount("one two\nthree four\n"); defer { window.close() }
        editor.setSelections([.init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0)),
                              .init(start: .init(line: 1, character: 0), end: .init(line: 1, character: 0))])
        let before = editor.getSelections()
        editor.doCommand(by: NSSelectorFromString("moveWordForwardAndModifySelection:"))
        #expect(editor.getSelections().map(\.end.character) == [3, 5])
        #expect(editor.getSelections().allSatisfy { $0.direction == .forward })
        editor.doCommand(by: NSSelectorFromString("moveWordBackwardAndModifySelection:"))
        #expect(editor.getSelections() == before)
        editor.doCommand(by: NSSelectorFromString("deleteWordForward:"))
        #expect(editor.getText() == " two\n four\n")
        editor.undo(nil); #expect(editor.getText() == "one two\nthree four\n" && editor.getSelections() == before)
        editor.setSelections([.init(anchor: .init(line: 1, character: 10), focus: .init(line: 1, character: 6))])
        editor.doCommand(by: NSSelectorFromString("moveToBeginningOfParagraphAndModifySelection:"))
        #expect(editor.getSelections().last == .init(anchor: .init(line: 1, character: 10), focus: .init(line: 1, character: 0)))
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func optionArrowRoutesThroughAppKitAndSelectionAction() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, view, editor) = try await helper.mount("one two\n"); defer { window.close() }
        var context: SelectionActionContext?
        editor.selectionActionRenderer = .init { context = $0; return NSButton(title: "Action", target: nil, action: nil) }
        editor.enabledSelectionAction = true
        editor.select(.init(location: 0, length: 0)); editor.focus(.init(preventScroll: true))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!), isARepeat: false, keyCode: 124))
        #expect(editor.handleKeyEvent(event)); try helper.paint(view)
        #expect(editor.getSelections().last?.end.character == 3 && context?.getSelectionText() == "one")
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func commandLeftTogglesIndentAndHomeUsesSoftLineStart() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, _, editor) = try await helper.mount("    let value = 1\n"); defer { window.close() }
        editor.select(.init(location: 12, length: 0))
        func press(_ key: UInt16, flags: NSEvent.ModifierFlags) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
            #expect(editor.handleKeyEvent(event))
        }
        try press(123, flags: .command); #expect(editor.getSelections().last?.focus.character == 4)
        try press(123, flags: .command); #expect(editor.getSelections().last?.focus.character == 0)
        try press(123, flags: [.command, .shift]); #expect(editor.getSelections().last?.end.character == 4)
        try press(115, flags: []); #expect(editor.getSelections().last?.focus.character == 0)
        _ = try await editor.complete(.discard)
    }
}

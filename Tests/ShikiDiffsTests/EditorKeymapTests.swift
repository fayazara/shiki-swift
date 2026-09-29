import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct EditorKeymapTests {
    func event(_ text: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    @Test func defaultsPlatformPrecedenceAndPhysicalFallback() throws {
        let bindings: [(String, NSEvent.ModifierFlags, UInt16, EditorCommand)] = [
            ("\t", [], 48, .indent), ("\t", [.shift], 48, .outdent), ("[", [.command], 33, .indentLess), ("]", [.command], 30, .indentMore),
            ("z", [.command], 6, .undo), ("Z", [.command, .shift], 6, .redo), ("a", [.command], 0, .selectAll), ("d", [.command], 2, .findNextMatch),
            ("f", [.command], 3, .openSearchPanel), ("ƒ", [.command, .option], 3, .openSearchReplacePanel),
            ("", [.option], 126, .moveLineUp), ("", [.option], 125, .moveLineDown), ("", [.option, .shift], 126, .copyLineUp), ("", [.option, .shift], 125, .copyLineDown),
            ("", [], 53, .simplifySelection), ("\r", [.command], 36, .insertBlankLine), ("k", [.control], 40, .deleteHardLineForward),
            ("/", [.command], 44, .toggleComment), ("Å", [.option, .shift], 0, .toggleBlockComment),
            ("", [.command], 115, .moveCursorToDocStart), ("", [.command], 119, .moveCursorToDocEnd),
            ("", [.command, .shift], 126, .expandSelectionDocStart), ("", [.command, .shift], 125, .expandSelectionDocEnd)]
        #expect(Set(bindings.map(\.3)) == Set(EditorCommand.allCases))
        for (text, flags, code, command) in bindings { #expect(try resolveEditorCommandFromKeyboardEvent(event(text, flags, code: code)) == command) }
        let custom = EditorKeymap([
            .init(bindings: ["cmd+d": .copyLineDown, "ctrl+d": .deleteHardLineForward, "F6": .toggleComment]),
            .init(platform: .mac, bindings: ["cmdOrCtrl+d": .copyLineUp]),
            .init(platform: .windows, bindings: ["cmd+d": .undo]),
            .init(bindings: ["bad+f": .redo, "cmd+???": .redo])])
        #expect(try resolveEditorCommandFromKeyboardEvent(event("d", [.command], code: 2), keymap: custom) == .copyLineUp)
        #expect(try resolveEditorCommandFromKeyboardEvent(event("", code: 97), keymap: custom) == .toggleComment)
        #expect(try resolveEditorCommandFromKeyboardEvent(event("f", [.command], code: 3), keymap: custom) == .openSearchPanel)
        #expect(try resolveEditorCommandFromKeyboardEvent(event("f", [.command, .control], code: 3), keymap: custom) == nil)
        #expect(try resolveEditorCommandFromKeyboardEvent(event("g", [.command], code: 3), keymap: .init([.init(bindings: ["cmd+g": .undo])])) == .undo)
        #expect(try resolveFindAgainShortcut(event("", [.command, .shift], code: 5)) == .previous)
        #expect(try resolveFindAgainShortcut(event("g", [.command, .option], code: 5)) == nil)
    }
    @Test @MainActor func customCommandsUseTheSameInputAndUndoPaths() async throws {
        let (view, editor) = try await MultipleSelectionTests().makeEditor("one\ntwo\nthree")
        editor.keymap = .init([.init(bindings: ["cmd+d": .copyLineDown, "F6": .moveCursorToDocEnd])])
        #expect(try editor.handleKeyEvent(event("d", [.command], code: 2)))
        #expect(editor.getText() == "one\none\ntwo\nthree")
        editor.undo(nil); #expect(editor.getText() == "one\ntwo\nthree")
        #expect(try editor.handleKeyEvent(event("", code: 97)))
        #expect(editor.getSelections().last?.focus == .init(line: 2, character: 5))
        #expect(try editor.handleKeyEvent(event("p", [.control, .option], code: 35)))
        #expect(editor.getText() == "one\nthree\ntwo")
        editor.undo(nil)
        editor.performCommand(.expandSelectionDocStart)
        #expect(editor.getSelections().last?.start == .init(line: 0, character: 0))
        #expect(view.attachedEditor === editor); _ = try await editor.complete(.discard)
        #expect(!editor.performCommand(.insertBlankLine))
    }
}

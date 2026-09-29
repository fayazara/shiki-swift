#if os(macOS)
import AppKit

public enum EditorCommand: String, CaseIterable, Codable, Sendable {
    case indent, outdent, indentLess, indentMore, undo, redo, selectAll, findNextMatch
    case openSearchPanel, openSearchReplacePanel, moveLineUp, moveLineDown, copyLineUp, copyLineDown
    case simplifySelection, insertBlankLine, deleteHardLineForward, toggleComment, toggleBlockComment
    case moveCursorToDocStart, moveCursorToDocEnd, expandSelectionDocStart, expandSelectionDocEnd
}
public enum EditorKeyboardPlatform: String, Codable, Sendable { case mac, windows, linux }
public struct EditorKeymapGroup: Equatable, Sendable {
    public var platform: EditorKeyboardPlatform?
    /// Upstream shortcut names: for example `cmdOrCtrl+shift+d`, `alt+ArrowUp`, or `F6`.
    public var bindings: [String: EditorCommand]
    public init(platform: EditorKeyboardPlatform? = nil, bindings: [String: EditorCommand]) {
        self.platform = platform; self.bindings = bindings
    }
}

/// Compiled once, with later groups winning. This native port evaluates macOS
/// groups; other platform groups can be retained in a shared configuration.
public struct EditorKeymap: Equatable, Sendable {
    public let groups: [EditorKeymapGroup]
    private var commands: [Int: [String: EditorCommand]] = [:]
    public init(_ groups: [EditorKeymapGroup] = []) {
        self.groups = groups
        for group in groups where group.platform == nil || group.platform == .mac {
            for (shortcut, command) in group.bindings {
                var parts = shortcut.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
                guard let key = parts.popLast(), Self.keys.contains(key) else { continue }
                var mask = 0, valid = true
                for part in parts {
                    switch part {
                    case "alt": mask |= 1
                    case "ctrl": mask |= 2
                    case "cmd", "cmdOrCtrl": mask |= 4
                    case "shift": mask |= 8
                    default: valid = false
                    }
                }
                if valid { commands[mask, default: [:]][key] = command }
            }
        }
    }
    fileprivate func command(mask: Int, key: String, physicalKey: String?) -> EditorCommand? {
        commands[mask]?[key] ?? physicalKey.flatMap { commands[mask]?[$0] }
    }
    private static let keys = Set(Array("abcdefghijklmnopqrstuvwxyz0123456789`-=,./;'[]\\").map(String.init)
        + ["Space", "Tab", "Enter", "Escape", "Backspace", "Delete", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"]
        + (1...12).map { "F\($0)" })
    fileprivate static let defaults = EditorKeymap([
        .init(bindings: ["Tab": .indent, "shift+Tab": .outdent, "cmdOrCtrl+[": .indentLess, "cmdOrCtrl+]": .indentMore,
            "cmdOrCtrl+z": .undo, "cmdOrCtrl+shift+z": .redo, "cmdOrCtrl+a": .selectAll, "cmdOrCtrl+d": .findNextMatch,
            "cmdOrCtrl+f": .openSearchPanel, "cmdOrCtrl+alt+f": .openSearchReplacePanel,
            "alt+ArrowUp": .moveLineUp, "alt+ArrowDown": .moveLineDown,
            "shift+alt+ArrowUp": .copyLineUp, "shift+alt+ArrowDown": .copyLineDown,
            "Escape": .simplifySelection, "cmdOrCtrl+Enter": .insertBlankLine, "cmdOrCtrl+/": .toggleComment,
            "shift+alt+a": .toggleBlockComment, "cmdOrCtrl+Home": .moveCursorToDocStart, "cmdOrCtrl+End": .moveCursorToDocEnd,
            "cmdOrCtrl+shift+Home": .expandSelectionDocStart, "cmdOrCtrl+shift+End": .expandSelectionDocEnd]),
        .init(platform: .mac, bindings: ["ctrl+k": .deleteHardLineForward, "ctrl+alt+p": .moveLineUp, "ctrl+alt+n": .moveLineDown,
            "cmd+ArrowUp": .moveCursorToDocStart, "cmd+ArrowDown": .moveCursorToDocEnd,
            "cmd+shift+ArrowUp": .expandSelectionDocStart, "cmd+shift+ArrowDown": .expandSelectionDocEnd])
    ])
}

/// Named function/navigation keys use AppKit's virtual key codes. Printable
/// characters take precedence, then the physical ANSI key supplies the same
/// fallback as upstream KeyboardEvent.code (including Option/dead keys).
public func resolveEditorCommandFromKeyboardEvent(_ event: NSEvent, keymap: EditorKeymap? = nil) -> EditorCommand? {
    let mask = (event.modifierFlags.contains(.option) ? 1 : 0) | (event.modifierFlags.contains(.control) ? 2 : 0)
        | (event.modifierFlags.contains(.command) ? 4 : 0) | (event.modifierFlags.contains(.shift) ? 8 : 0)
    let physical = editorPhysicalKeys[event.keyCode]
    let printable = event.charactersIgnoringModifiers?.lowercased() ?? ""
    let key = editorNamedKeys[event.keyCode] ?? (printable == " " ? "Space" : printable)
    return keymap?.command(mask: mask, key: key, physicalKey: physical)
        ?? EditorKeymap.defaults.command(mask: mask, key: key, physicalKey: physical)
}
public enum FindAgainDirection: Sendable { case next, previous }
public func resolveFindAgainShortcut(_ event: NSEvent) -> FindAgainDirection? {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard flags == [.command] || flags == [.command, .shift],
          event.charactersIgnoringModifiers?.lowercased() == "g" || event.keyCode == 5 else { return nil }
    return flags.contains(.shift) ? .previous : .next
}
private let editorNamedKeys: [UInt16: String] = [36: "Enter", 76: "Enter", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape",
    117: "Delete", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
private let editorPhysicalKeys: [UInt16: String] = [0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
    12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
    30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`", 49: "Space"]

#endif

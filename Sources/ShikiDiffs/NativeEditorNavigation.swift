#if os(macOS)
import AppKit

/// Browser-native word/paragraph movement is adapted to the Foundation word
/// segmenter used for the native text-system adaptation. It only reads the current/visited hard lines, not a full
/// document copy or a temporary text view.
enum NativeEditorNavigation {
    case wordBackward, wordForward, paragraphStart, paragraphEnd, paragraphBackward, paragraphForward
    var forward: Bool { self == .wordForward || self == .paragraphEnd || self == .paragraphForward }
}

func nativeEditorDestination(_ document: TextDocument, from position: TextPosition,
                             movement: NativeEditorNavigation, layout: EditorCursorLayout = .init()) -> TextPosition {
    var position = document.normalizePosition(position)
    let forward = movement.forward
    func adjacent(_ line: Int) -> Int? {
        let next = line + (forward ? 1 : -1)
        guard next >= 0, next < document.lineCount else { return nil }
        guard let resolved = layout.resolve(next, forward: forward), resolved >= 0, resolved < document.lineCount else { return nil }
        return resolved
    }
    switch movement {
    case .paragraphStart, .paragraphEnd, .paragraphBackward, .paragraphForward:
        let length = document.getLineText(position.line).utf16.count
        if movement == .paragraphBackward && position.character == 0 || movement == .paragraphForward && position.character == length,
           let line = adjacent(position.line) { position.line = line }
        position.character = forward ? document.getLineText(position.line).utf16.count : 0
        return position
    case .wordBackward, .wordForward:
        while true {
            let text = document.getLineText(position.line)
            var boundary: Int?
            let options: String.EnumerationOptions = forward ? [.byWords, .substringNotRequired] : [.byWords, .substringNotRequired, .reverse]
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: options) { _, range, _, stop in
                let word = NSRange(range, in: text)
                let candidate = forward ? NSMaxRange(word) : word.location
                if forward ? candidate > position.character : candidate < position.character {
                    boundary = candidate; stop = true
                }
            }
            if let boundary { position.character = boundary; return position }
            guard let line = adjacent(position.line) else {
                position.character = forward ? text.utf16.count : 0
                return position
            }
            position = .init(line: line, character: forward ? 0 : document.getLineText(line).utf16.count)
        }
    }
}

#endif

#if os(macOS)
// Native adaptation of @pierre/diffs editor/selection.ts.
import Foundation

public enum EditorSelectionDirection: Int, Codable, Sendable { case backward = -1, none = 0, forward = 1 }
public struct EditorSelection: Codable, Equatable, Sendable {
    public var start: TextPosition
    public var end: TextPosition
    public var direction: EditorSelectionDirection
    public init(start: TextPosition, end: TextPosition, direction: EditorSelectionDirection = .none) {
        self.start = start; self.end = end; self.direction = direction
    }
    public init(anchor: TextPosition, focus: TextPosition) {
        let order = compareEditorPositions(anchor, focus)
        start = order <= 0 ? anchor : focus; end = order <= 0 ? focus : anchor
        direction = order == 0 ? .none : order < 0 ? .forward : .backward
    }
    public var anchor: TextPosition { direction == .backward ? end : start }
    public var focus: TextPosition { direction == .backward ? start : end }
    public var isCollapsed: Bool { start == end }
}
public enum EditorCursorMovement: String, Codable, Sendable { case textStart, start, end, up, down, left, right }
/// UTF-16 wrap boundaries and currently renderable document lines. Nil lines means no folding.
public struct EditorCursorLayout: Sendable {
    public var softLineOffsets: [Int: [Int]]?
    public var renderableLines: [Int]?
    public init(softLineOffsets: [Int: [Int]]? = nil, renderableLines: [Int]? = nil) {
        self.softLineOffsets = softLineOffsets; self.renderableLines = renderableLines.map { Array(Set($0)).sorted() }
    }
    func resolve(_ line: Int, forward: Bool) -> Int? {
        guard let lines = renderableLines else { return line }
        var lower = 0, upper = lines.count
        while lower < upper { let mid = (lower + upper) / 2; if lines[mid] < line { lower = mid + 1 } else { upper = mid } }
        if forward { return lower < lines.count ? lines[lower] : nil }
        if lower < lines.count && lines[lower] == line { return line }
        return lower > 0 ? lines[lower - 1] : nil
    }
}
func compareEditorPositions(_ a: TextPosition, _ b: TextPosition) -> Int {
    a.line == b.line ? (a.character == b.character ? 0 : a.character < b.character ? -1 : 1) : a.line < b.line ? -1 : 1
}
public func snapCharacterToGraphemeBoundary(_ text: String, character: Int) -> Int {
    let text = text as NSString
    guard character > 0, character < text.length else { return character }
    let range = text.rangeOfComposedCharacterSequence(at: character)
    return range.location < character ? NSMaxRange(range) : character
}
private struct EditorSoftLine { var start: Int; var end: Int; var index: Int; var count: Int }
private func softLine(_ document: TextDocument, line: Int, index: Int, layout: EditorCursorLayout) -> EditorSoftLine {
    let length = document.getLineText(line).utf16.count
    guard let offsets = layout.softLineOffsets?[line], offsets.count >= 2 else { return .init(start: 0, end: length, index: 0, count: 1) }
    let count = offsets.count - 1, index = min(max(0, index), offsets.count - 2)
    let start = min(length, max(0, offsets[index])), end = min(length, max(0, offsets[index + 1]))
    return .init(start: start, end: max(start, end), index: index, count: count)
}
private func softLine(_ document: TextDocument, position: TextPosition, layout: EditorCursorLayout) -> EditorSoftLine {
    guard let offsets = layout.softLineOffsets?[position.line], offsets.count >= 2 else {
        return softLine(document, line: position.line, index: 0, layout: layout)
    }
    for index in 0..<(offsets.count - 1) {
        let info = softLine(document, line: position.line, index: index, layout: layout)
        if position.character >= info.start && position.character <= info.end { return info }
    }
    return softLine(document, line: position.line, index: position.character < offsets[0] ? 0 : offsets.count - 2, layout: layout)
}
public func mapCursorMove(_ document: TextDocument, selections: [EditorSelection], movement: EditorCursorMovement,
                          layout: EditorCursorLayout = .init()) -> [EditorSelection] {
    selections.map { selection in
        var position = movement == .up || movement == .left ? selection.start : selection.end
        switch movement {
        case .textStart, .start, .end:
            position = selection.focus
            let soft = softLine(document, position: position, layout: layout)
            if movement == .textStart {
                let line = document.getLineText(position.line) as NSString
                var indent = soft.start
                while indent < soft.end && (line.character(at: indent) == 32 || line.character(at: indent) == 9) { indent += 1 }
                position.character = position.character == indent ? soft.start : indent
            } else { position.character = movement == .start ? soft.start : soft.end }
        case .up, .down:
            let forward = movement == .down, delta = forward ? 1 : -1
            if layout.softLineOffsets != nil {
                let current = softLine(document, position: position, layout: layout)
                var targetLine = position.line, index = current.index + delta
                if index < 0 || index >= current.count {
                    let next = position.line + delta
                    guard next >= 0, next < document.lineCount, let resolved = layout.resolve(next, forward: forward) else {
                        return .init(start: position, end: position)
                    }
                    targetLine = min(resolved, document.lineCount - 1)
                    index = forward ? 0 : max(0, (layout.softLineOffsets?[targetLine]?.count ?? 2) - 2)
                }
                let target = softLine(document, line: targetLine, index: index, layout: layout)
                let goal = target.start + max(0, position.character - current.start)
                let landed = target.index == target.count - 1 ? goal : min(goal, target.end)
                position = .init(line: targetLine, character: snapCharacterToGraphemeBoundary(document.getLineText(targetLine), character: landed))
            } else if position.line + delta >= 0 && position.line + delta < document.lineCount {
                position.line = min(layout.resolve(position.line + delta, forward: forward) ?? position.line, document.lineCount - 1)
            }
        case .left, .right:
            guard selection.isCollapsed else { return .init(start: position, end: position) }
            let line = document.getLineText(position.line) as NSString, forward = movement == .right
            position.character = min(position.character, line.length)
            if !forward && position.character > 0 { position.character = line.rangeOfComposedCharacterSequence(at: position.character - 1).location }
            else if forward && position.character < line.length { position.character = NSMaxRange(line.rangeOfComposedCharacterSequence(at: position.character)) }
            else {
                let next = position.line + (forward ? 1 : -1)
                if next >= 0, next < document.lineCount, let target = layout.resolve(next, forward: forward) {
                    position.line = min(target, document.lineCount - 1)
                    position.character = forward ? 0 : document.getLineText(position.line).utf16.count
                }
            }
        }
        return .init(start: position, end: position)
    }
}
public func mapSelectionShift(_ document: TextDocument, selections: [EditorSelection], movement: EditorCursorMovement,
                             layout: EditorCursorLayout = .init()) -> [EditorSelection] {
    selections.map { selection in
        let focus = selection.focus
        let moved = mapCursorMove(document, selections: [.init(start: focus, end: focus)], movement: movement, layout: layout)[0]
        return .init(anchor: selection.anchor, focus: moved.focus)
    }
}

/// Range removed by the upstream word-backward command, including its whitespace rule.
public func resolveDeleteWordBackwardRange(_ document: TextDocument, selection: EditorSelection) -> TextRange {
    guard selection.isCollapsed else { return .init(start: selection.start, end: selection.end) }
    let caret = selection.focus
    if caret.character == 0 {
        let start = caret.line > 0 ? TextPosition(line: caret.line - 1, character: document.getLineText(caret.line - 1).utf16.count) : caret
        return .init(start: start, end: caret)
    }
    let text = document.getLineText(caret.line) as NSString
    let head = min(caret.character, text.length)
    var position = head, match: Int?
    while position > 0 {
        let range = text.rangeOfComposedCharacterSequence(at: position - 1), part = text.substring(with: range)
        let kind: Int
        if part.unicodeScalars.allSatisfy({ isECMAScriptWhitespace($0.value) }) { kind = 0 }
        else if part.unicodeScalars.contains(where: { $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" }) { kind = 1 }
        else { kind = 2 }
        if let match, match != kind { break }
        if kind != 0 || position != head { match = kind }
        position = range.location
    }
    return .init(start: .init(line: caret.line, character: position), end: caret)
}
public func resolveDeleteHardLineForwardRange(_ document: TextDocument, selection: EditorSelection) -> TextRange {
    guard selection.isCollapsed else { return .init(start: selection.start, end: selection.end) }
    let caret = selection.focus, length = document.getLineText(caret.line).utf16.count
    let end = caret.character < length ? TextPosition(line: caret.line, character: length)
        : caret.line < document.lineCount - 1 ? TextPosition(line: caret.line + 1, character: 0) : caret
    return .init(start: caret, end: end)
}

public func resolveDeleteSoftLineBackwardRange(_ document: TextDocument, selection: EditorSelection,
                                               layout: EditorCursorLayout = .init()) -> TextRange {
    guard selection.isCollapsed else { return .init(start: selection.start, end: selection.end) }
    let caret = selection.focus, start = softLine(document, position: caret, layout: layout).start
    if caret.character > start { return .init(start: .init(line: caret.line, character: start), end: caret) }
    guard caret.line > 0 else { return .init(start: caret, end: caret) }
    return .init(start: .init(line: caret.line - 1, character: document.getLineText(caret.line - 1).utf16.count),
                 end: .init(line: caret.line, character: 0))
}

public func resolveIndentEdits(_ document: TextDocument, selection: EditorSelection, tabSize: Int = 2,
                                outdent: Bool = false) -> (edits: [TextEdit], selection: EditorSelection) {
    var edits: [TextEdit] = [], next = selection
    let block = selection.start.line != selection.end.line
    let end = selection.end.line - (block && selection.end.character == 0 ? 1 : 0)
    guard selection.start.line <= end else { return (edits, next) }
    for line in selection.start.line...end {
        let text = document.getLineText(line)
        if block && trimECMAScriptWhitespace(text).isEmpty { continue }
        let unit = text.utf16.first == 9 ? "\t" : String(repeating: " ", count: max(0, tabSize))
        var deleteLength = 0
        if outdent {
            if text.utf16.first == 9 { deleteLength = 1 }
            else if text.utf16.first == 32 {
                let leading = text.unicodeScalars.prefix { isECMAScriptWhitespace($0.value) }.reduce(0) { $0 + $1.utf16.count }
                deleteLength = min(unit.utf16.count, leading)
            }
            if deleteLength == 0 { continue }
        }
        let insert = outdent ? "" : unit, delta = insert.utf16.count - deleteLength
        edits.append(.init(range: .init(start: .init(line: line, character: 0), end: .init(line: line, character: deleteLength)), newText: insert))
        if line == selection.start.line { next.start.character = max(0, selection.start.character + delta) }
        if line == selection.end.line { next.end.character = max(0, selection.end.character + delta) }
    }
    return (edits, next)
}

func expandSingleNewlineInsert(_ document: TextDocument, text: String, offset: Int) -> String {
    guard text == "\n" || text == "\r" || text == "\r\n" else { return text }
    let line = document.getLineText(document.positionAt(offset).line)
    return text + String(String.UnicodeScalarView(line.unicodeScalars.prefix { $0 == " " || $0 == "\t" }))
}

#endif

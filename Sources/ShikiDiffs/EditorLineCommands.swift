#if os(macOS)
// Native adaptation of @pierre/diffs editor line commands.
import Foundation

public struct EditorLineBlock: Codable, Equatable, Sendable {
    public var startLine: Int
    public var endLine: Int
}
public struct EditorCommandEdits: Sendable {
    public var edits: [TextEdit]
    public var selections: [EditorSelection]
}
public enum EditorLineCommand: String, Codable, Sendable { case moveUp, moveDown, copyUp, copyDown, insertBlankLine }

public func getSelectedLineBlocks(_ selections: [EditorSelection]) -> [EditorLineBlock] {
    var blocks: [EditorLineBlock] = selections.map { selection in
        let excluded = selection.end.character == 0 && !selection.isCollapsed
        let end = max(selection.start.line, selection.end.line - (excluded ? 1 : 0))
        return EditorLineBlock(startLine: selection.start.line, endLine: end)
    }
    blocks.sort { a, b in a.startLine == b.startLine ? a.endLine < b.endLine : a.startLine < b.startLine }
    var merged: [EditorLineBlock] = []
    for block in blocks {
        if let previous = merged.last, block.startLine <= previous.endLine + 1 {
            merged[merged.count - 1].endLine = max(previous.endLine, block.endLine)
        } else { merged.append(block) }
    }
    return merged
}
public func resolveLineCommandEdits(_ document: TextDocument, selections: [EditorSelection], command: EditorLineCommand) -> EditorCommandEdits {
    var edits: [TextEdit] = [], next = selections
    if command == .insertBlankLine {
        let lines = Array(Set(selections.map { $0.focus.line })).sorted()
        var target: [Int: TextPosition] = [:]
        for (index, line) in lines.enumerated() {
            let text = document.getLineText(line), indent = editorLeadingWhitespace(text)
            let position = TextPosition(line: line, character: text.utf16.count)
            edits.append(.init(range: .init(start: position, end: position), newText: document.eol + indent))
            target[line] = .init(line: line + 1 + index, character: indent.utf16.count)
        }
        next = selections.map { let position = target[$0.focus.line]!; return .init(start: position, end: position) }
        return .init(edits: edits, selections: next)
    }
    let blocks = getSelectedLineBlocks(selections), forward = command == .moveDown || command == .copyDown
    guard let first = blocks.first, let last = blocks.last else { return .init(edits: [], selections: selections) }
    if command == .moveUp || command == .moveDown {
        guard !(forward && last.endLine >= document.lineCount - 1), !(!forward && first.startLine == 0) else {
            return .init(edits: [], selections: selections)
        }
        for block in forward ? Array(blocks.reversed()) : blocks {
            let adjacent = forward ? block.endLine + 1 : block.startLine - 1
            let lines = forward ? [adjacent] + Array(block.startLine...block.endLine) : Array(block.startLine...block.endLine) + [adjacent]
            let endLine = forward ? adjacent : block.endLine
            let hasBreak = endLine < document.lineCount - 1
            let end = hasBreak ? TextPosition(line: endLine + 1, character: 0)
                : .init(line: endLine, character: document.getLineText(endLine).utf16.count)
            let text = lines.map { document.getLineText($0) }.joined(separator: document.eol) + (hasBreak ? document.eol : "")
            edits.append(.init(range: .init(start: .init(line: forward ? block.startLine : adjacent, character: 0), end: end), newText: text))
        }
        let lastLength = document.getLineText(forward && last.endLine == document.lineCount - 2 ? last.endLine : document.lineCount - 1).utf16.count
        func shifted(_ position: TextPosition) -> TextPosition {
            let line = position.line + (forward ? 1 : -1)
            if line < 0 { return .init(line: 0, character: 0) }
            if line >= document.lineCount { return .init(line: document.lineCount - 1, character: lastLength) }
            return .init(line: line, character: position.character)
        }
        next = selections.map { .init(start: shifted($0.start), end: shifted($0.end), direction: $0.direction) }
    } else {
        var copiedBefore: [Int] = [], count = 0
        for block in blocks {
            copiedBefore.append(count); count += block.endLine - block.startLine + 1
            let start = document.offsetAt(.init(line: block.startLine, character: 0))
            let end = document.offsetAt(.init(line: block.endLine, character: document.getLineText(block.endLine).utf16.count))
            let text = try! document.getText(in: .init(location: start, length: end - start))
            let position: TextPosition, insert: String
            if forward {
                position = .init(line: block.startLine, character: 0); insert = text + document.eol
            } else if block.endLine < document.lineCount - 1 {
                position = .init(line: block.endLine + 1, character: 0); insert = text + document.eol
            } else {
                position = .init(line: block.endLine, character: document.getLineText(block.endLine).utf16.count); insert = document.eol + text
            }
            edits.append(.init(range: .init(start: position, end: position), newText: insert))
        }
        next = selections.map { selection in
            var low = 0, high = blocks.count
            while low < high { let mid = (low + high) / 2; if blocks[mid].endLine < selection.start.line { low = mid + 1 } else { high = mid } }
            let index = min(low, blocks.count - 1), block = blocks[index]
            let shift = copiedBefore[index] + (forward ? block.endLine - block.startLine + 1 : 0)
            return .init(start: .init(line: selection.start.line + shift, character: selection.start.character),
                         end: .init(line: selection.end.line + shift, character: selection.end.character), direction: selection.direction)
        }
    }
    return .init(edits: edits, selections: next)
}
func editorLeadingWhitespace(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.prefix { isECMAScriptWhitespace($0.value) }))
}

#endif

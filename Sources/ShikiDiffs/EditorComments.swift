#if os(macOS)
// Native adaptation of @pierre/diffs editor/languages.ts.
import Foundation

public struct EditorBlockCommentTokens: Equatable, Sendable {
    public var open: String
    public var close: String
    public init(_ open: String, _ close: String) { self.open = open; self.close = close }
}
public enum EditorLineCommentToken: Equatable, Sendable { case token(String), disabled }
public struct EditorLanguageCommentConfig: Sendable {
    public var lineComment: EditorLineCommentToken?
    public var blockComment: EditorBlockCommentTokens?
    public init(lineComment: EditorLineCommentToken? = nil, blockComment: EditorBlockCommentTokens? = nil) {
        self.lineComment = lineComment; self.blockComment = blockComment
    }
}
public struct EditorResolvedCommentConfig: Sendable {
    public var lineComment: String?
    public var blockComment: EditorBlockCommentTokens
}
public func resolveCommentConfig(_ languageID: String, overrides: [String: EditorLanguageCommentConfig] = [:]) -> EditorResolvedCommentConfig {
    var line: String? = "//", block = EditorBlockCommentTokens("/*", "*/")
    switch languageID {
    case "sql", "lua": line = "--"
    case "ruby", "coffeescript", "julia", "yaml", "yml", "zsh", "makefile", "powershell", "diff", "r", "perl", "python", "dotenv", "dockerfile": line = "#"
    case "rst": line = ".."
    case "cmd": line = "@REM"
    case "ini": line = ";"
    case "vb": line = "'"
    case "pug": line = "//-"
    case "tex": line = "%"
    case "clojure": line = ";;"
    case "markdown", "handlebars", "xml", "html", "css", "razor", "prompt": line = nil
    default: break
    }
    switch languageID {
    case "ruby": block = .init("=begin", "=end")
    case "coffeescript": block = .init("###", "###")
    case "julia": block = .init("#=", "=#")
    case "markdown", "xml", "html", "razor", "prompt": block = .init("<!--", "-->")
    case "handlebars": block = .init("{{!--", "--}}")
    case "ini": block = .init(";", " ")
    case "powershell": block = .init("<#", "#>")
    case "lua": block = .init("--[[", "]]")
    case "diff": block = .init("#", " ")
    case "fsharp": block = .init("(*", "*)")
    case "python": block = .init("\"\"\"", "\"\"\"")
    default: break
    }
    if let override = overrides[languageID] {
        if let value = override.lineComment { if case .token(let token) = value { line = token } else { line = nil } }
        if let value = override.blockComment { block = value }
    }
    return .init(lineComment: line, blockComment: block)
}
public func resolveLineCommentEdits(_ document: TextDocument, selections: [EditorSelection], token: String) -> [TextEdit] {
    struct Line { var line: Int; var comment: Int; var empty: Bool; var indent: Int; var single = false }
    var lines: [Line] = [], seen: Set<Int> = []
    for selection in selections {
        let end = selection.end.line - (selection.start.line < selection.end.line && selection.end.character == 0 ? 1 : 0)
        guard end >= selection.start.line else { continue }
        let startIndex = lines.count
        var minIndent = Int.max
        for line in selection.start.line...end where seen.insert(line).inserted {
            let text = document.getLineText(line), indent = editorLeadingWhitespace(text).utf16.count
            let empty = indent == text.utf16.count
            if !empty { minIndent = min(minIndent, indent) }
            lines.append(.init(line: line, comment: jsEditorSlice(text, indent, indent + token.utf16.count).utf16.elementsEqual(token.utf16) ? indent : -1,
                               empty: empty, indent: indent))
        }
        if minIndent != .max { for i in startIndex..<lines.count where !lines[i].empty { lines[i].indent = minIndent } }
        if lines.count == startIndex + 1 { lines[startIndex].single = true }
    }
    let shouldComment = lines.contains { $0.comment < 0 && (!$0.empty || $0.single) }
    return lines.compactMap { line in
        if shouldComment {
            guard !line.empty || line.single else { return nil }
            let position = TextPosition(line: line.line, character: line.indent)
            return .init(range: .init(start: position, end: position), newText: token + " ")
        }
        guard line.comment >= 0 else { return nil }
        let text = document.getLineText(line.line), end = line.comment + token.utf16.count
        return .init(range: .init(start: .init(line: line.line, character: line.comment),
                                 end: .init(line: line.line, character: end + (jsEditorSlice(text, end, end + 1) == " " ? 1 : 0))), newText: "")
    }
}
public struct EditorCommentSelectionOffsets: Sendable {
    public var start: Int
    public var end: Int
    public var direction: EditorSelectionDirection
}
public struct EditorBlockCommentEdits: Sendable {
    public var edits: [TextEdit]
    public var nextSelectionOffsets: [EditorCommentSelectionOffsets]
}
private struct CommentOffsetEdit { var start: Int; var end: Int; var text = "" }
private struct CommentMatch { var open: CommentOffsetEdit; var close: CommentOffsetEdit; var contentStart: Int; var contentEnd: Int }
private func editorSlice(_ document: TextDocument, _ start: Int, _ end: Int) -> String {
    let a = max(0, min(document.utf16Length, start)), b = max(0, min(document.utf16Length, end))
    return try! document.getText(in: .init(location: a, length: max(0, b - a)))
}
private func jsEditorSlice(_ text: String, _ start: Int, _ end: Int) -> String {
    let value = text as NSString, length = value.length
    let a = min(length, start < 0 ? max(0, length + start) : start), b = min(length, end < 0 ? max(0, length + end) : end)
    return value.substring(with: .init(location: a, length: max(0, b - a)))
}
private func trailingEditorWhitespace(_ text: String) -> Int {
    text.unicodeScalars.reversed().prefix { isECMAScriptWhitespace($0.value) }.reduce(0) { $0 + $1.utf16.count }
}
private func findEditorBlockComment(_ document: TextDocument, tokens: EditorBlockCommentTokens, from: Int, to: Int) -> CommentMatch? {
    let open = tokens.open, close = tokens.close, openLength = open.utf16.count, closeLength = close.utf16.count
    let before = editorSlice(document, max(0, from - 50), from), after = editorSlice(document, to, to + 50)
    let spaceBefore = trailingEditorWhitespace(before), spaceAfter = editorLeadingWhitespace(after).utf16.count
    let beforeOffset = before.utf16.count - spaceBefore
    if jsEditorSlice(before, beforeOffset - openLength, beforeOffset).utf16.elementsEqual(open.utf16),
       jsEditorSlice(after, spaceAfter, spaceAfter + closeLength).utf16.elementsEqual(close.utf16) {
        return .init(open: .init(start: from - spaceBefore - openLength, end: from - spaceBefore + (spaceBefore > 0 ? 1 : 0)),
                     close: .init(start: to + spaceAfter - (spaceAfter > 0 ? 1 : 0), end: to + spaceAfter + closeLength), contentStart: from, contentEnd: to)
    }
    let short = to - from <= 100 ? editorSlice(document, from, to) : nil
    let startText = short ?? editorSlice(document, from, from + 50), endText = short ?? editorSlice(document, to - 50, to)
    let startSpace = editorLeadingWhitespace(startText).utf16.count, endSpace = trailingEditorWhitespace(endText)
    let closeStart = to - endSpace - closeLength
    guard jsEditorSlice(startText, startSpace, startSpace + openLength).utf16.elementsEqual(open.utf16),
          editorSlice(document, closeStart, closeStart + closeLength).utf16.elementsEqual(close.utf16) else { return nil }
    let openStart = from + startSpace
    let openEnd = openStart + openLength + (jsEditorSlice(startText, openLength + startSpace, openLength + startSpace + 1).unicodeScalars.contains { isECMAScriptWhitespace($0.value) } ? 1 : 0)
    let closeDelete = closeStart - (editorSlice(document, closeStart - 1, closeStart).unicodeScalars.contains { isECMAScriptWhitespace($0.value) } ? 1 : 0)
    return .init(open: .init(start: openStart, end: openEnd), close: .init(start: closeDelete, end: closeStart + closeLength), contentStart: openEnd, contentEnd: closeDelete)
}
public func resolveBlockCommentEdits(_ document: TextDocument, selections: [EditorSelection], tokens: EditorBlockCommentTokens,
                                     linewise: Bool = false) -> EditorBlockCommentEdits? {
    struct Range { var from: Int; var to: Int; var direction: EditorSelectionDirection; var comment: CommentMatch? }
    var ranges = selections.map { selection in
        var start = selection.start, end = selection.end
        if linewise {
            if start.line < end.line && end.character == 0 { end.line -= 1 }
            start.character = editorLeadingWhitespace(document.getLineText(start.line)).utf16.count
            end.character = document.getLineText(end.line).utf16.count
        }
        return Range(from: document.offsetAt(start), to: document.offsetAt(end), direction: selection.direction)
    }
    if linewise && ranges.count > 1 {
        ranges.sort { $0.from == $1.from ? $0.to < $1.to : $0.from < $1.from }
        var merged: [Range] = []
        for range in ranges {
            if let last = merged.last, range.from <= last.to { merged[merged.count - 1].to = max(last.to, range.to) }
            else { merged.append(range) }
        }
        ranges = merged
    }
    for i in ranges.indices { ranges[i].comment = findEditorBlockComment(document, tokens: tokens, from: ranges[i].from, to: ranges[i].to) }
    let uncomment = ranges.allSatisfy { $0.comment != nil }
    var offsets: [CommentOffsetEdit] = []
    for range in ranges {
        if uncomment, let comment = range.comment { offsets += [comment.open, comment.close] }
        else if range.comment == nil {
            if range.from == range.to { offsets.append(.init(start: range.from, end: range.to, text: tokens.open + "  " + tokens.close)) }
            else { offsets += [.init(start: range.from, end: range.from, text: tokens.open + " "), .init(start: range.to, end: range.to, text: " " + tokens.close)] }
        }
    }
    guard !offsets.isEmpty else { return nil }
    offsets = offsets.enumerated().sorted { a, b in
        a.element.start == b.element.start ? (a.element.end == b.element.end ? a.offset < b.offset : a.element.end < b.element.end) : a.element.start < b.element.start
    }.map(\.element)
    let edits = offsets.map { TextEdit(range: .init(start: document.positionAt($0.start), end: document.positionAt($0.end)), newText: $0.text) }
    if linewise { return .init(edits: edits, nextSelectionOffsets: []) }
    // Prefix deltas and binary lookup keep many selections from scanning every earlier edit.
    var deltas = [0]
    for edit in offsets { deltas.append(deltas.last! + edit.text.utf16.count - (edit.end - edit.start)) }
    func map(_ offset: Int, association: Int) -> Int {
        var low = 0, high = offsets.count
        while low < high { let mid = (low + high) / 2; if offsets[mid].end < offset { low = mid + 1 } else { high = mid } }
        var delta = deltas[low]
        for edit in offsets[low...] {
            if offset < edit.start { break }
            if edit.start == edit.end && offset == edit.start {
                if association < 0 { break }
                delta += edit.text.utf16.count; continue
            }
            if offset > edit.end { delta += edit.text.utf16.count - (edit.end - edit.start); continue }
            if offset == edit.end { return edit.start + delta + edit.text.utf16.count }
            return edit.start + delta + (association > 0 ? edit.text.utf16.count : 0)
        }
        return offset + delta
    }
    let selections = ranges.map { range -> EditorCommentSelectionOffsets in
        let start: Int, end: Int
        if uncomment, let comment = range.comment { start = map(comment.contentStart, association: 1); end = map(comment.contentEnd, association: -1) }
        else if range.comment != nil { start = map(range.from, association: 1); end = map(range.to, association: 1) }
        else if range.from == range.to { start = map(range.from, association: -1) + tokens.open.utf16.count + 1; end = start }
        else { start = map(range.from, association: 1); end = map(range.to, association: -1) }
        return .init(start: start, end: end, direction: range.direction)
    }
    return .init(edits: edits, nextSelectionOffsets: selections)
}

#endif

#if os(macOS)
import Foundation

public func selectionIntersects(_ a: EditorSelection, _ b: EditorSelection) -> Bool {
    if a.isCollapsed && b.isCollapsed { return a.start == b.start }
    if a.isCollapsed { return compareEditorPositions(b.start, a.start) <= 0 && compareEditorPositions(a.start, b.end) <= 0 }
    if b.isCollapsed { return compareEditorPositions(a.start, b.start) <= 0 && compareEditorPositions(b.start, a.end) <= 0 }
    return compareEditorPositions(a.start, b.end) < 0 && compareEditorPositions(b.start, a.end) < 0
}

/// Touching nonempty ranges remain separate; a caret on a range boundary merges
/// into it. The most recently added selection determines order and direction.
public func mergeOverlappingSelections(_ selections: [EditorSelection]) -> [EditorSelection] {
    guard selections.count > 1 else { return selections }
    let ordered = selections.enumerated().sorted {
        let start = compareEditorPositions($0.element.start, $1.element.start)
        let end = compareEditorPositions($0.element.end, $1.element.end)
        return start != 0 ? start < 0 : end != 0 ? end < 0 : $0.offset < $1.offset
    }
    var current: (offset: Int, element: EditorSelection) = ordered[0]
    var result: [(offset: Int, element: EditorSelection)] = []
    for entry in ordered.dropFirst() {
        guard selectionIntersects(current.element, entry.element) else {
            result.append(current); current = entry; continue
        }
        let latest = entry.offset > current.offset ? entry : current
        let start = compareEditorPositions(entry.element.start, current.element.start) < 0 ? entry.element.start : current.element.start
        let end = compareEditorPositions(entry.element.end, current.element.end) > 0 ? entry.element.end : current.element.end
        var direction = latest.element.direction
        if direction == .none && start != end { direction = latest.element.start == start ? .backward : .forward }
        current = (latest.offset, .init(start: start, end: end, direction: direction))
    }
    result.append(current)
    return result.sorted { $0.offset < $1.offset }.map(\.element)
}

public enum SelectionReplacementError: Error { case textCountMismatch }
struct SelectionReplacements {
    var edits: [ResolvedTextEdit]
    var selections: [(anchor: Int, focus: Int)]
}
/// Resolves positions against the original document, retaining selection order
/// even when the primary (last) caret precedes another caret in source order.
func resolveSelectionReplacements(_ document: TextDocument, selections: [EditorSelection], texts: [String],
                                  documentOrder: Bool = false, preserveInnerSelection: Bool = true, expandNewlines: Bool = true) throws -> SelectionReplacements {
    guard selections.count == texts.count else { throw SelectionReplacementError.textCountMismatch }
    var ordered: [(index: Int, start: Int, end: Int)] = try selections.enumerated().map { index, value in
        let resolved = try document.resolveEdits([.init(range: .init(start: value.start, end: value.end), newText: "")])[0]
        return (index: index, start: resolved.range.location, end: NSMaxRange(resolved.range))
    }
    ordered.sort {
        if $0.start != $1.start { return $0.start < $1.start }
        if $0.end != $1.end { return $0.end < $1.end }
        return $0.index < $1.index
    }
    var edits: [ResolvedTextEdit] = [], positions = Array(repeating: (anchor: 0, focus: 0), count: selections.count)
    if texts.allSatisfy(\.isEmpty) {
        for entry in ordered where entry.start < entry.end {
            if let last = edits.last, entry.start < NSMaxRange(last.range) {
                edits[edits.count - 1].range.length = max(NSMaxRange(last.range), entry.end) - last.range.location
            } else { edits.append(.init(range: .init(location: entry.start, length: entry.end - entry.start), newText: "")) }
        }
        for entry in ordered {
            let offset = remapEditorOffset(entry.end, through: edits)
            positions[entry.index] = (offset, offset)
        }
    } else {
        var delta = 0, previousEnd = -1
        for (order, entry) in ordered.enumerated() {
            guard entry.start >= previousEnd else { throw TextDocumentError.overlappingEdits }
            previousEnd = entry.end
            let replacement = texts[documentOrder ? order : entry.index]
            let text = document.normalizeEol(expandNewlines ? expandSingleNewlineInsert(document, text: replacement, offset: entry.start) : replacement)
            edits.append(.init(range: .init(location: entry.start, length: entry.end - entry.start), newText: text))
            let start = entry.start + delta, end = start + text.utf16.count
            positions[entry.index] = (end, end)
            if preserveInnerSelection, entry.end > entry.start {
                let original = try document.getText(in: .init(location: entry.start, length: entry.end - entry.start))
                let nsText = text as NSString
                let inner: NSRange
                if nsText.length == original.utf16.count + 2,
                   getAutoSurroundReplacementTexts(document, selections: [selections[entry.index]], character: nsText.substring(to: 1))?.first?.utf16.elementsEqual(text.utf16) == true {
                    inner = .init(location: 1, length: original.utf16.count)
                } else { inner = nsText.range(of: original, options: .literal) }
                if inner.location != NSNotFound { positions[entry.index] = (start + inner.location, start + NSMaxRange(inner)) }
            }
            delta += text.utf16.count - (entry.end - entry.start)
        }
    }
    return .init(edits: edits, selections: positions)
}

public func expandCollapsedSelectionToWord(_ document: TextDocument, selection: EditorSelection) -> EditorSelection {
    guard selection.isCollapsed else { return selection }
    let position = document.positionAt(document.offsetAt(selection.start)), text = document.getLineText(position.line)
    var match: NSRange?
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, stop in
        let range = NSRange(range, in: text)
        if position.character >= range.location && position.character <= NSMaxRange(range) { match = range; stop = true }
    }
    guard let match else { return selection }
    return .init(start: .init(line: position.line, character: match.location), end: .init(line: position.line, character: NSMaxRange(match)), direction: .forward)
}

public func findNextMatch(_ document: TextDocument, selections: [EditorSelection]) -> [EditorSelection]? {
    guard !selections.isEmpty else { return nil }
    let normalized = selections.map { expandCollapsedSelectionToWord(document, selection: $0) }
    let texts = normalized.map { document.getText(.init(start: $0.start, end: $0.end)) }
    guard let needle = texts.first, !needle.isEmpty, texts.allSatisfy({ $0.utf16.elementsEqual(needle.utf16) }) else { return nil }
    let occupied = normalized.map { selection in
        let start = document.offsetAt(selection.start), end = document.offsetAt(selection.end)
        return NSRange(location: start, length: end - start)
    }
    guard let offset = document.findNextNonOverlappingSubstring(needle, occupied: occupied) else {
        return normalized == selections ? nil : normalized
    }
    return normalized + [.init(anchor: document.positionAt(offset), focus: document.positionAt(offset + needle.utf16.count))]
}

#endif

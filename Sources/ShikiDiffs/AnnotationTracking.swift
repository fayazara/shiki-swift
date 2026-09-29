#if os(macOS)
import Foundation

/// Repositions annotations using the upstream editor's line mapping rules.
/// Returns nil when no annotation is affected. Identity and payload are retained.
public func applyDocumentChangeToLineAnnotations(_ change: TextDocumentChange, annotations: [LineAnnotation]) -> [LineAnnotation]? {
    let changes = change.changedLineChanges.filter { $0.lineDelta != 0 }
    guard !changes.isEmpty else { return nil }
    var changed = false
    let result = annotations.compactMap { annotation -> LineAnnotation? in
        guard annotation.side != .deletions, annotation.lineNumber > 0 else { return annotation }
        var line = annotation.lineNumber - 1
        var lineCount = change.previousLineCount
        for edit in changes {
            let inserted = max(0, edit.endLine - edit.startLine)
            let end = edit.startLine + max(0, inserted - edit.lineDelta)
            let deletesEnd = edit.lineDelta < 0 && edit.endedAtDocumentEnd
            lineCount = max(1, lineCount + edit.lineDelta)
            if line < edit.startLine { continue }
            if line > end || (end > edit.startLine && line == end && !deletesEnd) {
                line += edit.lineDelta; changed = true
                continue
            }
            changed = true
            if edit.startLine == end {
                if edit.startCharacter == 0 { line += inserted }
                continue
            }
            if edit.lineDelta < 0 && !(line == edit.startLine && edit.startCharacter > 0)
                && !(line == end && !deletesEnd) { return nil }
            let offset = min(max(0, line - edit.startLine), inserted)
            line = max(0, min(edit.startLine + offset, lineCount - 1))
        }
        var moved = annotation; moved.lineNumber = line + 1
        return moved
    }
    return changed ? result : nil
}

#endif

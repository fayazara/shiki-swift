#if os(macOS)
import Foundation
import CSDRegex

public enum EditPredictionSource: String, Codable, Sendable { case user, prediction }
public struct EditPredictRequest: Codable, Equatable, Sendable {
    public struct EditableRange: Codable, Equatable, Sendable { public var start: Int; public var end: Int }
    public struct History: Codable, Equatable, Sendable { public var diff: String; public var source: EditPredictionSource }
    public var path: String
    public var version: Int
    public var eol: String
    public var excerptText: String
    public var excerptStartLine: Int
    public var cursorOffsetInExcerpt: Int
    public var editableRange: EditableRange
    public var editHistory: [History]
}
public struct EditPredictResponse: Sendable {
    public var edits: [TextEdit]
    public var newCursor: TextPosition
    public init(edits: [TextEdit], newCursor: TextPosition) { self.edits = edits; self.newCursor = newCursor }
}
public struct EditPredictionHistoryRecord: Codable, Equatable, Sendable {
    public var path: String
    public var hunk: String
    public var start: Int
    public var end: Int
    public var at: Double
    public var source: EditPredictionSource
    struct Fragment: Codable, Equatable, Sendable {
        var baseText: String; var currentText: String; var currentStart: Int; var currentEnd: Int; var startLine: Int
    }
    var fragment: Fragment?
    public init(path: String, hunk: String, start: Int, end: Int, at: Double, source: EditPredictionSource) {
        self.path = path; self.hunk = hunk; self.start = start; self.end = end; self.at = at; self.source = source
    }
}
public struct TextDocumentChangeTransaction: Sendable {
    public var appliedEdits: [ResolvedTextEdit]
    public var inverseEdits: [ResolvedTextEdit]
    public init(appliedEdits: [ResolvedTextEdit], inverseEdits: [ResolvedTextEdit]) { self.appliedEdits = appliedEdits; self.inverseEdits = inverseEdits }
}

/// Builds the same bounded excerpt as upstream. The callback is evaluated at
/// most once per candidate line; lines beyond the budget are never read.
public func buildEditPredictionRequest(path: String, document: TextDocument, cursorOffset: Int,
                                       history: [EditPredictionHistoryRecord] = [],
                                       isLineEditable: (Int) -> Bool = { _ in true }) -> EditPredictRequest? {
    var cursor = min(max(0, cursorOffset), document.utf16Length)
    if cursor > 0, cursor < document.utf16Length,
       let before = document.utf16CodeUnit(at: cursor - 1), let after = document.utf16CodeUnit(at: cursor),
       (before == 13 && after == 10) || ((0xD800...0xDBFF).contains(before) && (0xDC00...0xDFFF).contains(after)) { cursor -= 1 }
    let cursorLine = document.positionAt(cursor).line
    var editable: [Int: Bool] = [:], costs: [Int: Int] = [:]
    func canEdit(_ line: Int) -> Bool {
        guard line >= 0 && line < document.lineCount else { return false }
        if let value = editable[line] { return value }
        let value = isLineEditable(line); editable[line] = value; return value
    }
    func cost(_ line: Int) -> Int {
        if let value = costs[line] { return value }
        let length = (try? document.getLineLength(line)) ?? 0
        let value = length / 3 > 662 ? 663 : max(1, document.getLineText(line).utf8.count / 3)
        costs[line] = value; return value
    }
    func expand(_ first: inout Int, _ last: inout Int, _ budget: Int, _ accepts: (Int) -> Bool) {
        var remaining = budget
        while remaining > 0 && (first > 0 || last < document.lineCount - 1) {
            var expanded = false
            if first > 0, accepts(first - 1), cost(first - 1) <= remaining {
                first -= 1; remaining -= cost(first); expanded = true
            }
            if last < document.lineCount - 1, accepts(last + 1), cost(last + 1) <= remaining {
                last += 1; remaining -= cost(last); expanded = true
            }
            if !expanded { break }
        }
    }
    guard canEdit(cursorLine) else { return nil }
    var first = cursorLine, last = cursorLine, remaining = max(0, 262 - cost(cursorLine))
    while remaining > 0 && (canEdit(first - 1) || canEdit(last + 1)) {
        if canEdit(last + 1) {
            let next = cost(last + 1); if next > remaining { break }
            last += 1; remaining -= next
        }
        if canEdit(first - 1), remaining > 0 {
            let next = cost(first - 1); if next > remaining { break }
            first -= 1; remaining -= next
        }
    }
    expand(&first, &last, remaining + 88, canEdit)
    var contextFirst = first, contextLast = last
    expand(&contextFirst, &contextLast, 150, { _ in true })
    guard (first...last).reduce(0, { $0 + cost($1) }) <= 512,
          (contextFirst...contextLast).reduce(0, { $0 + cost($1) }) <= 662 else { return nil }
    let start = document.offsetAt(.init(line: contextFirst, character: 0))
    let end = document.offsetAt(.init(line: contextLast, character: Int.max))
    let request = EditPredictRequest(path: path, version: document.version, eol: document.eol,
        excerptText: document.getTextSlice(start: start, end: end), excerptStartLine: contextFirst, cursorOffsetInExcerpt: cursor - start,
        editableRange: .init(start: document.offsetAt(.init(line: first, character: 0)) - start,
                             end: document.offsetAt(.init(line: last, character: Int.max)) - start),
        editHistory: history.suffix(10).map { .init(diff: $0.hunk, source: $0.source) })
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let encoded = try? encoder.encode(request), encoded.count <= 128 * 1024 else { return nil }
    return request
}

public enum EditPredictionPattern: Sendable, Equatable {
    case glob(String)
    /// ECMAScript expression and flags. Invalid expressions/flags do not match.
    case regex(String, flags: String = "")
}
public func matchesEditPredictionPattern(path: String, pattern: EditPredictionPattern) -> Bool {
    let source: String, flags: String
    switch pattern {
    case .regex(let expression, let options): source = expression; flags = options
    case .glob(let pattern):
        let characters = Array(pattern.replacingOccurrences(of: "\\", with: "/").utf16)
        var result = "^", index = 0
        let escaped = Set("\\^$.*+?()[]{}|".utf16)
        while index < characters.count {
            let character = characters[index]
            if character == 42 {
                if index + 1 < characters.count && characters[index + 1] == 42 {
                    index += 1
                    if index + 1 < characters.count && characters[index + 1] == 47 { index += 1; result += "(?:.*/)?" }
                    else { result += ".*" }
                } else { result += "[^/]*" }
            } else if character == 63 { result += "[^/]" }
            else {
                if escaped.contains(character) { result += "\\" }
                // Copy surrogate pairs intact into the Swift String pattern.
                if (0xD800...0xDBFF).contains(character), index + 1 < characters.count, (0xDC00...0xDFFF).contains(characters[index + 1]) {
                    result += String(decoding: characters[index...index + 1], as: UTF16.self); index += 1
                } else { result += String(decoding: [character], as: UTF16.self) }
            }
            index += 1
        }
        source = result + "$"; flags = ""
    }
    var error = [CChar](repeating: 0, count: 256)
    guard let expression = source.withCString({ bytes in flags.withCString { sd_regex_create_flags(bytes, source.utf8.count, $0, &error, Int32(error.count)) } }) else { return false }
    defer { sd_regex_destroy(expression) }
    let units = Array(path.utf16)
    guard units.count <= Int(Int32.max) / 2 else { return false }
    var ranges = [Int32](repeating: -1, count: Int(sd_regex_capture_count(expression)) * 2)
    return units.withUnsafeBufferPointer { buffer in
        var sentinel: UInt16 = 0
        return withUnsafePointer(to: &sentinel) { empty in
            sd_regex_exec(expression, buffer.baseAddress ?? empty, Int32(units.count), 0, &ranges, Int32(ranges.count), 100) == 1
        }
    }
}

// All slices below are bounded to 6 KiB. UTF-16 comparisons intentionally avoid
// Swift's canonically equivalent String equality.
private struct PredictionLines {
    var units: [UInt16]
    var starts = [0]
    init(_ text: String) {
        units = Array(text.utf16); var index = 0
        while index < units.count {
            if units[index] == 13 && index + 1 < units.count && units[index + 1] == 10 { index += 1 }
            if units[index] == 10 || units[index] == 13 { starts.append(index + 1) }
            index += 1
        }
    }
    var count: Int { units.isEmpty ? 0 : starts.count - (starts.last == units.count ? 1 : 0) }
    func end(_ line: Int) -> Int {
        guard line + 1 < starts.count else { return units.count }
        let next = starts[line + 1]
        return next - (next >= 2 && units[next - 1] == 10 && units[next - 2] == 13 ? 2 : 1)
    }
    func line(_ line: Int) -> ArraySlice<UInt16> { units[starts[line]..<end(line)] }
    func slice(_ first: Int, _ end: Int) -> String {
        String(decoding: units[(first < starts.count ? starts[first] : units.count)..<(end < starts.count ? starts[end] : units.count)], as: UTF16.self)
    }
}
private struct PredictionBounds {
    var oldCount: Int; var newCount: Int; var prefix = 0; var suffix = 0
    init(_ old: PredictionLines, _ new: PredictionLines) {
        oldCount = old.count; newCount = new.count
        while prefix < oldCount && prefix < newCount && old.line(prefix).elementsEqual(new.line(prefix)) { prefix += 1 }
        while suffix < oldCount - prefix && suffix < newCount - prefix && old.line(oldCount - 1 - suffix).elementsEqual(new.line(newCount - 1 - suffix)) { suffix += 1 }
    }
}
private func predictionHunk(_ path: String, _ oldText: String, _ newText: String, _ offset: Int) -> (String, PredictionBounds)? {
    guard !oldText.utf16.elementsEqual(newText.utf16) else { return nil }
    let old = PredictionLines(oldText), new = PredictionLines(newText), bounds = PredictionBounds(old, new)
    guard bounds.prefix != bounds.oldCount || bounds.prefix != bounds.newCount else { return nil }
    let oldChangedEnd = bounds.oldCount - bounds.suffix, newChangedEnd = bounds.newCount - bounds.suffix
    guard old.slice(bounds.prefix, oldChangedEnd).utf8.count <= 6144, new.slice(bounds.prefix, newChangedEnd).utf8.count <= 6144 else { return nil }
    let start = max(0, bounds.prefix - 3), oldEnd = min(bounds.oldCount, oldChangedEnd + 3), newEnd = min(bounds.newCount, newChangedEnd + 3)
    let oldCount = oldEnd - start, newCount = newEnd - start, line = start + offset
    var output = ["--- a/\(path)", "+++ b/\(path)", "@@ -\(oldCount == 0 ? line : line + 1),\(oldCount) +\(newCount == 0 ? line : line + 1),\(newCount) @@"]
    for i in start..<bounds.prefix { output.append(" " + String(decoding: old.line(i), as: UTF16.self)) }
    for i in bounds.prefix..<oldChangedEnd { output.append("-" + String(decoding: old.line(i), as: UTF16.self)) }
    for i in bounds.prefix..<newChangedEnd { output.append("+" + String(decoding: new.line(i), as: UTF16.self)) }
    for i in oldChangedEnd..<oldEnd { output.append(" " + String(decoding: old.line(i), as: UTF16.self)) }
    let hunk = output.joined(separator: "\n")
    return hunk.utf8.count <= 6144 ? (hunk, bounds) : nil
}
private func predictionApply(_ text: String, start: Int, edits: [ResolvedTextEdit]) -> String? {
    let units = Array(text.utf16); var output: [UInt16] = [], offset = 0
    for edit in edits {
        guard edit.range.location >= start, edit.range.length >= 0 else { return nil }
        let lo = edit.range.location - start
        guard lo >= offset, lo <= units.count, edit.range.length <= units.count - lo else { return nil }
        let hi = lo + edit.range.length
        output += units[offset..<lo]; output += edit.newText.utf16; offset = hi
    }
    output += units[offset...]
    return String(decoding: output, as: UTF16.self)
}
private func predictionSlice(_ text: String, _ start: Int, _ end: Int? = nil) -> String {
    let units = Array(text.utf16), lo = min(max(0, start), units.count), hi = min(max(0, end ?? units.count), units.count)
    return hi >= lo ? String(decoding: units[lo..<hi], as: UTF16.self) : ""
}
private struct PredictionCapture { var before: String; var after: String; var offset: Int; var line: Int; var bounds: PredictionBounds }
private func predictionCapture(_ document: TextDocument, _ transaction: TextDocumentChangeTransaction) -> PredictionCapture? {
    guard let first = transaction.inverseEdits.first,
          transaction.inverseEdits.allSatisfy({ $0.range.location >= 0 && $0.range.location <= document.utf16Length &&
              $0.range.length >= 0 && $0.range.length <= document.utf16Length - $0.range.location }) else { return nil }
    var start = first.range.location, end = NSMaxRange(first.range)
    for edit in transaction.inverseEdits.dropFirst() { start = min(start, edit.range.location); end = max(end, NSMaxRange(edit.range)) }
    let positions = document.positionsAt([start, end])
    for context in [11, 3] {
        let first = max(0, positions[0].line - context), last = min(document.lineCount - 1, positions[1].line + context)
        let lo = document.offsetAt(.init(line: first, character: 0))
        let hi = last + 1 < document.lineCount ? document.offsetAt(.init(line: last + 1, character: 0)) : document.utf16Length
        guard hi - lo <= 6144 else { continue }
        let after = document.getTextSlice(start: lo, end: hi)
        guard after.utf8.count <= 6144, let before = predictionApply(after, start: lo, edits: transaction.inverseEdits),
              before.utf16.count <= 6144, before.utf8.count <= 6144 else { continue }
        return .init(before: before, after: after, offset: lo, line: first, bounds: .init(.init(before), .init(after)))
    }
    return nil
}
/// Records a bounded unified hunk without flattening the surrounding document.
public func recordEditPrediction(history: [EditPredictionHistoryRecord], path: String, document: TextDocument,
                                 transaction: TextDocumentChangeTransaction, source: EditPredictionSource,
                                 at: Double = Date().timeIntervalSince1970 * 1000) -> [EditPredictionHistoryRecord] {
    var kept = Array(history.suffix(10))
    func clearPreviousFragment() { if !kept.isEmpty { kept[kept.count - 1].fragment = nil } }
    guard let fragment = predictionCapture(document, transaction) else { clearPreviousFragment(); return kept }
    guard !fragment.before.utf16.elementsEqual(fragment.after.utf16) else { return kept }
    let changedStart = fragment.line + fragment.bounds.prefix
    let beforeEndLine = fragment.line + fragment.bounds.oldCount - fragment.bounds.suffix
    if let last = kept.last, let previous = last.fragment {
        let gapValue = changedStart > last.end ? changedStart.subtractingReportingOverflow(last.end)
            : (last.start > beforeEndLine ? last.start.subtractingReportingOverflow(beforeEndLine) : (0, false))
        let gap = gapValue.1 ? Int.max : gapValue.0
        if last.path.utf16.elementsEqual(path.utf16), last.source == source, at - last.at < 1000, gap <= 8 {
            let beforeEnd = fragment.offset + fragment.before.utf16.count
            let overlapStart = max(previous.currentStart, fragment.offset), overlapEnd = min(previous.currentEnd, beforeEnd)
            if overlapStart <= overlapEnd,
               predictionSlice(previous.currentText, overlapStart - previous.currentStart, overlapEnd - previous.currentStart).utf16.elementsEqual(
                predictionSlice(fragment.before, overlapStart - fragment.offset, overlapEnd - fragment.offset).utf16) {
                let unionStart = min(previous.currentStart, fragment.offset)
                let current = previous.currentStart <= fragment.offset
                    ? previous.currentText + predictionSlice(fragment.before, max(0, previous.currentEnd - fragment.offset))
                    : fragment.before + predictionSlice(previous.currentText, max(0, beforeEnd - previous.currentStart))
                let base = predictionSlice(current, 0, previous.currentStart - unionStart) + previous.baseText + predictionSlice(current, previous.currentEnd - unionStart)
                let line = previous.currentStart <= fragment.offset ? previous.startLine : fragment.line
                if let next = predictionApply(current, start: unionStart, edits: transaction.appliedEdits),
                   base.utf16.count <= 6144, next.utf16.count <= 6144, base.utf8.count <= 6144, next.utf8.count <= 6144 {
                    if base.utf16.elementsEqual(next.utf16) { kept.removeLast(); return kept }
                    if let (hunk, bounds) = predictionHunk(path, base, next, line) {
                        var record = EditPredictionHistoryRecord(path: path, hunk: hunk, start: line + bounds.prefix,
                            end: line + bounds.newCount - bounds.suffix, at: at, source: source)
                        record.fragment = .init(baseText: base, currentText: next, currentStart: unionStart, currentEnd: unionStart + next.utf16.count, startLine: line)
                        kept[kept.count - 1] = record; return kept
                    }
                }
            }
        }
    }
    clearPreviousFragment()
    guard let (hunk, _) = predictionHunk(path, fragment.before, fragment.after, fragment.line) else { return kept }
    var record = EditPredictionHistoryRecord(path: path, hunk: hunk, start: changedStart,
        end: fragment.line + fragment.bounds.newCount - fragment.bounds.suffix, at: at, source: source)
    record.fragment = .init(baseText: fragment.before, currentText: fragment.after, currentStart: fragment.offset,
                            currentEnd: fragment.offset + fragment.after.utf16.count, startLine: fragment.line)
    kept.append(record); return Array(kept.suffix(10))
}

/// Checks the provider response against the request before any preview or edit.
/// A bounded affected-line slice validates post-edit cursor geometry without
/// changing the live editor. Invalid/no-op responses are ignored.
public func validateEditPredictionResponse(_ response: EditPredictResponse, request: EditPredictRequest,
                                           document: TextDocument) -> EditPredictResponse? {
    guard request.version == document.version, !response.edits.isEmpty, response.edits.count <= 256,
          request.excerptStartLine >= 0, request.excerptStartLine < document.lineCount else { return nil }
    func valid(_ position: TextPosition, in value: TextDocument) -> Bool {
        guard position.line >= 0, position.line < value.lineCount, position.character >= 0,
              position.character <= ((try? value.getLineLength(position.line)) ?? -1) else { return false }
        let offset = value.offsetAt(position)
        if let before = value.utf16CodeUnit(at: offset - 1), let after = value.utf16CodeUnit(at: offset),
           (0xD800...0xDBFF).contains(before), (0xDC00...0xDFFF).contains(after) { return false }
        return true
    }
    let excerptStart = document.offsetAt(.init(line: request.excerptStartLine, character: 0))
    guard request.editableRange.start >= 0, request.editableRange.end >= request.editableRange.start,
          request.editableRange.end <= document.utf16Length - excerptStart else { return nil }
    let lower = excerptStart + request.editableRange.start, upper = excerptStart + request.editableRange.end
    var bytes = 0, edits: [ResolvedTextEdit] = []
    for edit in response.edits {
        guard valid(edit.range.start, in: document), valid(edit.range.end, in: document) else { return nil }
        let start = document.offsetAt(edit.range.start), end = document.offsetAt(edit.range.end)
        guard start <= end, start >= lower, end <= upper else { return nil }
        bytes += edit.newText.utf8.count; guard bytes <= 128 * 1024 else { return nil }
        edits.append(.init(range: .init(location: start, length: end - start), newText: edit.newText))
    }
    edits = edits.enumerated().sorted {
        if $0.element.range.location != $1.element.range.location { return $0.element.range.location < $1.element.range.location }
        if $0.element.range.length != $1.element.range.length { return $0.element.range.length < $1.element.range.length }
        return $0.offset < $1.offset
    }.map(\.element)
    for i in edits.indices.dropFirst() where NSMaxRange(edits[i - 1].range) > edits[i].range.location { return nil }
    edits.removeAll { $0.newText.utf16.elementsEqual(document.getTextSlice(start: $0.range.location, end: NSMaxRange($0.range)).utf16) }
    guard !edits.isEmpty else { return nil }
    // Only the affected bounded lines are copied; a document copy/application
    // would rebuild the entire line index for a multi-edit prediction.
    let firstLine = document.positionAt(edits[0].range.location).line, lastLine = document.positionAt(NSMaxRange(edits.last!.range)).line
    let affectedStart = document.offsetAt(.init(line: firstLine, character: 0)), affectedEnd = document.offsetAt(.init(line: lastLine, character: Int.max))
    guard let predicted = predictionApply(document.getTextSlice(start: affectedStart, end: affectedEnd), start: affectedStart, edits: edits) else { return nil }
    let local = TextDocument(uri: "prediction", text: predicted)
    let endLine = firstLine + local.lineCount - 1, delta = local.lineCount - (lastLine - firstLine + 1)
    let cursor = response.newCursor
    if cursor.line >= firstLine && cursor.line <= endLine {
        guard valid(.init(line: cursor.line - firstLine, character: cursor.character), in: local) else { return nil }
    } else {
        guard cursor.line >= 0 else { return nil }
        let (originalLine, overflow) = cursor.line.subtractingReportingOverflow(cursor.line < firstLine ? 0 : delta)
        guard !overflow, valid(.init(line: originalLine, character: cursor.character), in: document) else { return nil }
    }
    return .init(edits: edits.map { .init(range: .init(start: document.positionAt($0.range.location), end: document.positionAt(NSMaxRange($0.range))), newText: $0.newText) }, newCursor: cursor)
}

#endif

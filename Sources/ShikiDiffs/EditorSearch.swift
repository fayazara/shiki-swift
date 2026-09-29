#if os(macOS)
import Foundation
import CSDRegex

public struct EditorSearchParams: Codable, Equatable, Sendable {
    public var text: String
    public var replaceText: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool
    public init(text: String, replaceText: String = "", caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.text = text; self.replaceText = replaceText; self.caseSensitive = caseSensitive; self.wholeWord = wholeWord; self.regex = regex
    }
}
public enum EditorSearchError: Error { case executionLimit, allocationFailure, documentTooLarge }

private final class EditorSearchRegex {
    let handle: OpaquePointer
    var ranges: [Int32]
    init?(_ params: EditorSearchParams) {
        let special: Set<Unicode.Scalar> = Set(".*+?^${}()|[]\\".unicodeScalars)
        let pattern = params.regex ? params.text : params.text.unicodeScalars.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
        let bytes = pattern.utf8CString
        var error = Array<CChar>(repeating: 0, count: 256)
        guard let value = bytes.withUnsafeBufferPointer({ buffer in
            sd_regex_create(buffer.baseAddress!, buffer.count - 1, params.caseSensitive ? 0 : 1, params.regex ? 1 : 0, &error, Int32(error.count))
        }) else { return nil }
        handle = value; ranges = Array(repeating: -1, count: Int(sd_regex_capture_count(value)) * 2)
    }
    deinit { sd_regex_destroy(handle) }
    func match(_ pointer: UnsafePointer<UInt16>, length: Int, from: Int) throws -> Bool {
        guard length <= Int(Int32.max / 2) else { throw EditorSearchError.documentTooLarge }
        let result = sd_regex_exec(handle, pointer, Int32(length), Int32(from), &ranges, Int32(ranges.count), 1000)
        if result == -2 { throw EditorSearchError.executionLimit }
        if result < 0 { throw EditorSearchError.allocationFailure }
        return result == 1
    }
}
private func searchWordSeparator(_ unit: UInt16) -> Bool {
    if unit <= 32 || unit == 127 { return true }
    return "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?".utf16.contains(unit)
}
extension TextDocument {
    /// Source-compatible line-by-line search, capped at 100,000 nonempty matches.
    /// Invalid expressions and newline-spanning queries produce no matches.
    public func search(_ params: EditorSearchParams) throws -> [NSRange] {
        guard !params.text.isEmpty, utf16Length > 0,
              !params.text.contains("\n"), !params.text.contains("\r"),
              !(params.regex && (params.text.contains("\\n") || params.text.contains("\\r"))),
              let pattern = EditorSearchRegex(params) else { return [] }
        var units = Array(getText().utf16), result: [NSRange] = []
        let count = units.count
        units.append(0) // Provides a valid pointer even for the final empty line.
        try units.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            var start = 0
            while start <= count {
                try Task.checkCancellation()
                var end = start
                while end < count && units[end] != 10 && units[end] != 13 { end += 1 }
                let length = end - start
                var cursor = 0
                var iterations = 0
                while cursor <= length {
                    if iterations % 128 == 0 { try Task.checkCancellation() }
                    iterations += 1
                    guard try pattern.match(base + start, length: length, from: cursor) else { break }
                    let relative = Int(pattern.ranges[0]), matchEnd = Int(pattern.ranges[1])
                    if matchEnd == relative {
                        cursor = relative + 1
                        if relative + 1 < length, (0xD800...0xDBFF).contains(units[start + relative]), (0xDC00...0xDFFF).contains(units[start + relative + 1]) { cursor += 1 }
                        continue
                    }
                    let absolute = start + relative, absoluteEnd = start + matchEnd
                    if !params.wholeWord || ((absolute == 0 || searchWordSeparator(units[absolute - 1])) && (absoluteEnd == count || searchWordSeparator(units[absoluteEnd]))) {
                        result.append(.init(location: absolute, length: absoluteEnd - absolute))
                        if result.count == 100_000 { return }
                    }
                    cursor = matchEnd
                }
                if end == count { break }
                start = end + (units[end] == 13 && end + 1 < count && units[end + 1] == 10 ? 2 : 1)
            }
        }
        return result
    }
}
public func buildSearchReplacementText(_ document: TextDocument, params: EditorSearchParams, match: NSRange) throws -> String {
    var cache = SearchReplacementLine()
    return try expandSearchReplacement(document, params: params, match: match, pattern: params.regex ? EditorSearchRegex(params) : nil, cache: &cache)
}
private struct SearchReplacementLine { var line = -1; var units: [UInt16] = [] }
private func expandSearchReplacement(_ document: TextDocument, params: EditorSearchParams, match: NSRange,
                                     pattern: EditorSearchRegex?, cache: inout SearchReplacementLine) throws -> String {
    guard params.regex, let pattern else { return params.replaceText }
    let position = document.positionAt(match.location), start = document.offsetAt(.init(line: position.line, character: 0))
    if cache.line != position.line {
        cache.line = position.line; cache.units = Array(document.getLineText(position.line).utf16); cache.units.append(0)
    }
    let units = cache.units, length = units.count - 1, relative = match.location - start
    guard relative >= 0, relative <= length else { return params.replaceText }
    let found = try units.withUnsafeBufferPointer { try pattern.match($0.baseAddress!, length: length, from: relative) }
    guard found, pattern.ranges[0] == relative, pattern.ranges[1] - pattern.ranges[0] == match.length else { return params.replaceText }
    let replacement = Array(params.replaceText.utf16)
    var result: [UInt16] = [], index = 0
    while index < replacement.count {
        guard replacement[index] == 36, index + 1 < replacement.count else { result.append(replacement[index]); index += 1; continue }
        let next = replacement[index + 1]
        if next == 36 { result.append(36); index += 2; continue }
        var group: Int?
        if next == 38 { group = 0; index += 2 }
        else if (48...57).contains(next) {
            var number = 0; index += 1
            while index < replacement.count && (48...57).contains(replacement[index]) {
                number = min(1_000_000, number * 10 + Int(replacement[index] - 48)); index += 1
            }
            group = number
        } else { result.append(36); index += 1 }
        if let group, group < pattern.ranges.count / 2 {
            let a = Int(pattern.ranges[group * 2]), b = Int(pattern.ranges[group * 2 + 1])
            if a >= 0 && b >= a { result.append(contentsOf: units[a..<b]) }
        }
    }
    return String(decoding: result, as: UTF16.self)
}

/// Builds a batch against this exact document snapshot. Regex compilation and
/// UTF-16 line buffers are reused across matches on the same logical line.
public func buildSearchReplacementEdits(_ document: TextDocument, params: EditorSearchParams) throws -> [ResolvedTextEdit] {
    let matches = try document.search(params), pattern = params.regex ? EditorSearchRegex(params) : nil
    var cache = SearchReplacementLine(), edits: [ResolvedTextEdit] = []
    edits.reserveCapacity(matches.count)
    for match in matches {
        try Task.checkCancellation()
        let text = try expandSearchReplacement(document, params: params, match: match, pattern: pattern, cache: &cache)
        edits.append(.init(range: match, newText: text))
    }
    return edits
}

#endif

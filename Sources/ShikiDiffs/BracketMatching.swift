#if os(macOS)
import Foundation

public enum AutoSurround: String, Sendable, CaseIterable {
    case `default`, never, brackets, quotes, languageDefined
}

/// Like upstream, languageDefined currently uses the standard surrounding pairs.
public func getAutoSurroundReplacementTexts(_ document: TextDocument, selections: [EditorSelection],
                                            character: String, autoSurround: AutoSurround = .default) -> [String]? {
    let pairs = ["(": ")", "[": "]", "{": "}", "<": ">", "\"": "\"", "'": "'", "`": "`"]
    guard autoSurround != .never, let close = pairs[character], !selections.isEmpty,
          selections.allSatisfy({ !$0.isCollapsed }) else { return nil }
    let quote = ["\"", "'", "`"].contains(character)
    guard !(autoSurround == .brackets && quote), !(autoSurround == .quotes && !quote) else { return nil }
    return selections.map { character + document.getText(.init(start: $0.start, end: $0.end)) + close }
}

/// Searches at most 1,000 lines and 50,000 UTF-16 characters, including ignored
/// text. Ignored ranges must be ordered, disjoint, line-local UTF-16 ranges.
/// Only slices within the scan budget are copied, even for megabyte-long lines.
public func findBracketMatchRanges(_ document: TextDocument, position: TextPosition,
                                  ignoredRanges: (Int) -> [NSRange] = { _ in [] }) -> [TextRange]? {
    let position = document.positionAt(document.offsetAt(position))
    let pairs: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125, 41: 40, 93: 91, 125: 123]
    func length(_ line: Int) -> Int {
        document.offsetAt(.init(line: line, character: Int.max)) - document.offsetAt(.init(line: line, character: 0))
    }
    func units(_ line: Int, _ range: Range<Int>) -> [UInt16] {
        let start = document.offsetAt(.init(line: line, character: 0)) + range.lowerBound
        return Array(((try? document.getText(in: .init(location: start, length: range.count))) ?? "").utf16)
    }
    let ignored = ignoredRanges(position.line)
    var adjacent: (Int, UInt16)?
    for column in [position.character - 1, position.character] where column >= 0 && column < length(position.line) {
        guard !ignored.contains(where: { NSLocationInRange(column, $0) }),
              let char = units(position.line, column..<(column + 1)).first, pairs[char] != nil else { continue }
        adjacent = (column, char); break
    }
    guard let (column, char) = adjacent, let mate = pairs[char] else { return nil }
    let forward = char == 40 || char == 91 || char == 123
    var line = position.line, scanned = 0, lines = 0, depth = 0
    while line >= 0 && line < document.lineCount && lines < 1_000 && scanned < 50_000 {
        let count = length(line)
        let start = line == position.line ? column : forward ? 0 : count - 1
        let lower = forward ? start : max(0, start + 1 - (50_000 - scanned))
        let upper = forward ? min(count, start + (50_000 - scanned)) : start + 1
        let ranges = ignoredRanges(line)
        var rangeIndex = forward ? 0 : ranges.count - 1
        let slice = units(line, lower..<max(lower, upper))
        for index in 0..<slice.count {
            let local = forward ? index : slice.count - 1 - index, column = lower + local
            scanned += 1
            if forward {
                while rangeIndex < ranges.count && NSMaxRange(ranges[rangeIndex]) <= column { rangeIndex += 1 }
            } else {
                while rangeIndex >= 0 && ranges[rangeIndex].location > column { rangeIndex -= 1 }
            }
            if ranges.indices.contains(rangeIndex), NSLocationInRange(column, ranges[rangeIndex]) { continue }
            if slice[local] == char { depth += 1 }
            else if slice[local] == mate {
                depth -= 1
                if depth == 0 {
                    let source = TextPosition(line: position.line, character: adjacent!.0)
                    let match = TextPosition(line: line, character: column)
                    return (forward ? [source, match] : [match, source]).map {
                        .init(start: $0, end: .init(line: $0.line, character: $0.character + 1))
                    }
                }
            }
        }
        lines += 1; line += forward ? 1 : -1
    }
    return nil
}

#endif

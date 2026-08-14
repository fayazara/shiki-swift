import Foundation

/// One source line and its absolute UTF-16 offset in the original code.
public struct ShikiSplitLine: Codable, Equatable, Sendable {
    public var content: String
    public var offset: Int

    public init(content: String, offset: Int) {
        self.content = content
        self.offset = offset
    }
}

/// Splits source code exactly like Shiki v4.4.3's `splitLines` utility.
///
/// Only LF and CRLF are line endings; a lone CR stays in line content. The
/// returned offsets count UTF-16 code units, matching JavaScript and TextMate.
/// A terminal line ending produces a final empty line.
public func splitLines(
    _ code: String,
    preserveEnding: Bool = false
) -> [ShikiSplitLine] {
    let codeUnits = Array(code.utf16)

    if codeUnits.isEmpty {
        return [ShikiSplitLine(content: "", offset: 0)]
    }

    var lines: [ShikiSplitLine] = []
    var lineStart = 0
    var index = 0

    while index < codeUnits.count {
        guard codeUnits[index] == 0x000A else {
            index += 1
            continue
        }

        let endingStart = index > lineStart && codeUnits[index - 1] == 0x000D
            ? index - 1
            : index
        let contentEnd = preserveEnding ? index + 1 : endingStart
        let content = String(decoding: codeUnits[lineStart..<contentEnd], as: UTF16.self)
        lines.append(ShikiSplitLine(content: content, offset: lineStart))

        lineStart = index + 1
        index += 1
    }

    let finalContent = String(decoding: codeUnits[lineStart...], as: UTF16.self)
    lines.append(ShikiSplitLine(content: finalContent, offset: lineStart))
    return lines
}

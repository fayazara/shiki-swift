import Foundation

struct TokenInteractionSpan: Equatable, Sendable {
    let lineCharStart: Int
    let lineCharEnd: Int
    let tokenText: String
    let whitespaceOnly: Bool
}

/// One entry per original Shiki token, independent of inline diff decoration.
/// Constructed only for queried lines; subsequent pointer lookups are logarithmic.
struct TokenInteractionIndex: Sendable {
    let spans: [TokenInteractionSpan]
    init(contents: [String], fallback: String) {
        var offset = 0
        spans = (contents.isEmpty ? [fallback] : contents).compactMap { text in
            let length = text.utf16.count
            guard length > 0 else { return nil }
            defer { offset += length }
            return .init(lineCharStart: offset, lineCharEnd: offset + length, tokenText: text,
                         whitespaceOnly: text.unicodeScalars.allSatisfy { isECMAScriptWhitespace($0.value) })
        }
    }
    func token(at character: Int, includeWhitespace: Bool) -> TokenInteractionSpan? {
        guard character >= 0 else { return nil }
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].lineCharEnd <= character { low = middle + 1 } else { high = middle }
        }
        guard spans.indices.contains(low), character >= spans[low].lineCharStart,
              includeWhitespace || !spans[low].whitespaceOnly else { return nil }
        return spans[low]
    }
}

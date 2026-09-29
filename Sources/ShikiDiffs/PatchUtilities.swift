import Foundation

public struct ParsedLine: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case context, metadata, addition, deletion }
    public let line: String
    public let type: Kind
}

/// Removes one ASCII patch prefix. A prefix without content represents a newline.
public func parseLineType(_ line: String) -> ParsedLine? {
    guard let first = line.unicodeScalars.first else { return nil }
    let kind: ParsedLine.Kind
    switch first {
    case " ": kind = .context
    case "\\": kind = .metadata
    case "+": kind = .addition
    case "-": kind = .deletion
    default: return nil
    }
    let content = String(line.unicodeScalars.dropFirst())
    return ParsedLine(line: content.isEmpty ? "\n" : content, type: kind)
}

/// The last hunk determines the consumed-file extent; this does not sort hunks.
public func getTotalLineCountFromHunks(_ hunks: [Hunk]) -> Int {
    guard let last = hunks.last else { return 0 }
    func end(_ start: Int, _ count: Int) -> Int { start - (count == 0 ? 0 : 1) + count }
    return max(end(last.additionStart, last.additionCount), end(last.deletionStart, last.deletionCount))
}

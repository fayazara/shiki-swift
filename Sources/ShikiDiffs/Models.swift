// Native adaptation of @pierre/diffs 1.4.2. See LICENSE and THIRD_PARTY_NOTICES.md.
import Foundation

public struct FileContents: Codable, Equatable, Sendable {
    public var name: String
    public var contents: String
    public var lang: String?
    public var header: String?
    public var cacheKey: String?
    public init(name: String, contents: String, lang: String? = nil, header: String? = nil, cacheKey: String? = nil) {
        self.name = name; self.contents = contents; self.lang = lang; self.header = header; self.cacheKey = cacheKey
    }
}
public enum ChangeType: String, Codable, Sendable {
    case change, renamePure = "rename-pure", renameChanged = "rename-changed", new, deleted
}
public struct HunkContent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case context, change }
    public var type: Kind
    public var lines: Int
    public var deletions: Int
    public var additions: Int
    public var deletionLineIndex: Int
    public var additionLineIndex: Int
    public init(type: Kind, lines: Int = 0, deletions: Int = 0, additions: Int = 0, deletionLineIndex: Int, additionLineIndex: Int) {
        self.type = type; self.lines = lines; self.deletions = deletions; self.additions = additions
        self.deletionLineIndex = deletionLineIndex; self.additionLineIndex = additionLineIndex
    }
    public var oldCount: Int { type == .context ? lines : deletions }
    public var newCount: Int { type == .context ? lines : additions }
    enum CodingKeys: String, CodingKey { case type, lines, deletions, additions, deletionLineIndex, additionLineIndex }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(Kind.self, forKey: .type)
        lines = try c.decodeIfPresent(Int.self, forKey: .lines) ?? 0
        deletions = try c.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
        additions = try c.decodeIfPresent(Int.self, forKey: .additions) ?? 0
        deletionLineIndex = try c.decode(Int.self, forKey: .deletionLineIndex)
        additionLineIndex = try c.decode(Int.self, forKey: .additionLineIndex)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(deletionLineIndex, forKey: .deletionLineIndex)
        try c.encode(additionLineIndex, forKey: .additionLineIndex)
        if type == .context { try c.encode(lines, forKey: .lines) }
        else { try c.encode(deletions, forKey: .deletions); try c.encode(additions, forKey: .additions) }
    }
}
public struct Hunk: Codable, Equatable, Sendable {
    public var collapsedBefore = 0
    public var additionStart = 0
    public var additionCount = 0
    public var additionLines = 0
    public var additionLineIndex = 0
    public var deletionStart = 0
    public var deletionCount = 0
    public var deletionLines = 0
    public var deletionLineIndex = 0
    public var hunkContent: [HunkContent] = []
    public var hunkContext: String?
    public var hunkSpecs: String?
    public var splitLineStart = 0
    public var splitLineCount = 0
    public var unifiedLineStart = 0
    public var unifiedLineCount = 0
    public var noEOFCRDeletions = false
    public var noEOFCRAdditions = false
    public init() {}
    public var oldBoundary: Int { deletionStart - (deletionCount > 0 ? 1 : 0) }
    public var newBoundary: Int { additionStart - (additionCount > 0 ? 1 : 0) }
}
public struct FileDiffMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var prevName: String?
    public var lang: String?
    public var newObjectId: String?
    public var prevObjectId: String?
    public var mode: String?
    public var prevMode: String?
    public var type: ChangeType = .change
    public var hunks: [Hunk] = []
    public var splitLineCount = 0
    public var unifiedLineCount = 0
    public var isPartial = true
    public var deletionLines: [String] = []
    public var additionLines: [String] = []
    public var cacheKey: String?
    public init(name: String) { self.name = name }
    /// Session regions persist until `finishEditSessionForDiff` recomputes the ordinary diff.
    public var editSessionDirty: Bool?
    public var additions: Int { hunks.reduce(0) { $0 + $1.additionLines } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.deletionLines } }
}
public struct ParsedPatch: Codable, Equatable, Sendable {
    public var patchMetadata: String?
    public var files: [FileDiffMetadata]
    public init(patchMetadata: String? = nil, files: [FileDiffMetadata] = []) { self.patchMetadata = patchMetadata; self.files = files }
}
public enum DiffError: Error, LocalizedError, Equatable {
    case invalidPatch(String), missingFiles, invalidHunk, partialDiff, invalidHydration
    public var errorDescription: String? {
        switch self {
        case .invalidPatch(let reason): return "Invalid patch: \(reason)"
        case .missingFiles: return "Provide at least one file."
        case .invalidHunk: return "The hunk index is out of range."
        case .partialDiff: return "Full file contents are required for this operation."
        case .invalidHydration: return "The loaded files do not match this partial diff."
        }
    }
}
/// Preserves original LF/CRLF terminators, with no phantom final row.
public func splitFileContents(_ contents: String) -> [String] {
    guard !contents.isEmpty else { return [] }
    // Splitting on a Unicode scalar is intentional: Swift treats CRLF as one Character.
    let ns = contents as NSString
    var result: [String] = []; var start = 0
    for (offset, unit) in contents.utf16.enumerated() where unit == 10 {
        result.append(ns.substring(with: NSRange(location: start, length: offset + 1 - start)))
        start = offset + 1
    }
    if start < ns.length { result.append(ns.substring(from: start)) }
    return result
}
public func cleanLastNewline(_ value: String) -> String {
    if value.hasSuffix("\r\n") { return String(value.dropLast()) }
    if value.hasSuffix("\n") { return String(value.dropLast()) }
    return value
}
public func composeCacheKey(_ scope: String, _ segments: String...) -> String { cacheKey(scope, segments) }
func cacheKey(_ scope: String, _ segments: [String]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [scope] + segments, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return "ck1:" + String(decoding: data, as: UTF8.self)
}
func isECMAScriptWhitespace(_ value: UInt32) -> Bool {
    (9...13).contains(value) || value == 32 || value == 160 || value == 0x1680 || (0x2000...0x200A).contains(value) ||
        value == 0x2028 || value == 0x2029 || value == 0x202F || value == 0x205F || value == 0x3000 || value == 0xFEFF
}
func trimECMAScriptWhitespace(_ value: String) -> String {
    let scalars = value.unicodeScalars
    var start = scalars.startIndex, end = scalars.endIndex
    while start < end && isECMAScriptWhitespace(scalars[start].value) { start = scalars.index(after: start) }
    while end > start {
        let previous = scalars.index(before: end)
        guard isECMAScriptWhitespace(scalars[previous].value) else { break }
        end = previous
    }
    return String(scalars[start..<end])
}

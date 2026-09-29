import Foundation
import CryptoKit
import Shiki

public struct HighlightCacheStatistics: Sendable {
    public var hits: Int
    public var misses: Int
    public var entries: Int
    /// Conservative retained-content estimate, not process resident memory.
    public var estimatedBytes: Int
}
/// Actor-owned LRU. Keys include exact source bytes and all tokenization inputs.
struct TokenCache {
    struct Key: Hashable { let digest: SHA256.Digest; let language: String; let theme: String; let maxLineLength: Int }
    struct Entry { let source: String; let tokens: TokensResult; let cost: Int; var accessed: UInt64 }
    var entries: [Key: Entry] = [:]
    var bytes = 0, hits = 0, misses = 0
    var clock: UInt64 = 0
    let capacity: Int
    init(capacity: Int) { self.capacity = max(0, capacity) }
    static func key(_ source: String, language: String, theme: String, maxLineLength: Int) -> Key {
        .init(digest: SHA256.hash(data: Data(source.utf8)), language: language, theme: theme, maxLineLength: maxLineLength)
    }
    mutating func get(_ key: Key, source: String) -> TokensResult? {
        guard var entry = entries[key], entry.source.utf8.elementsEqual(source.utf8) else { misses += 1; return nil }
        clock &+= 1; entry.accessed = clock; entries[key] = entry; hits += 1; return entry.tokens
    }
    mutating func insert(_ value: TokensResult, key: Key, source: String) {
        let cost = source.utf8.count + value.tokens.reduce(0) { total, line in total + 24 + line.reduce(0) { $0 + 128 + $1.content.utf8.count } }
        guard cost <= capacity else { return }
        if let previous = entries.removeValue(forKey: key) { bytes -= previous.cost }
        while bytes + cost > capacity || entries.count >= 64 {
            guard let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            bytes -= removed.cost
        }
        clock &+= 1; entries[key] = .init(source: source, tokens: value, cost: cost, accessed: clock); bytes += cost
    }
    mutating func clear() { entries.removeAll(); bytes = 0; hits = 0; misses = 0 }
    var statistics: HighlightCacheStatistics { .init(hits: hits, misses: misses, entries: entries.count, estimatedBytes: bytes) }
}

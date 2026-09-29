import Foundation

/// Recovers the source order of object keys in JSON documents.
///
/// `JSONDecoder` decodes objects into Swift dictionaries, whose iteration
/// order is randomized per process. A few TextMate/Shiki fields are ordered
/// in JavaScript (`Object.keys` follows insertion order) and that order is
/// observable: injection priority ties, and the numbering of synthetic theme
/// color replacements. This scanner walks the raw UTF-8 bytes once and returns
/// the key order of an object at a key path without building a DOM.
public enum JSONKeyOrder {
    /// Returns the keys, in document order, of the object found by following
    /// `path` from the root object. Returns nil when the path does not resolve
    /// to an object or the document is malformed.
    public static func keys(atPath path: [String], in data: Data) -> [String]? {
        data.withUnsafeBytes { raw -> [String]? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            var scanner = Scanner(bytes: base, count: raw.count)
            return scanner.keys(atPath: path[...])
        }
    }

    private struct Scanner {
        let bytes: UnsafePointer<UInt8>
        let count: Int
        var position = 0

        init(bytes: UnsafePointer<UInt8>, count: Int) {
            self.bytes = bytes
            self.count = count
        }

        mutating func keys(atPath path: ArraySlice<String>) -> [String]? {
            skipWhitespace()
            guard peek() == UInt8(ascii: "{") else { return nil }
            if path.isEmpty {
                return objectKeys()
            }
            position += 1
            let target = path.first!
            while true {
                skipWhitespace()
                if peek() == UInt8(ascii: "}") { return nil }
                guard let key = readString() else { return nil }
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else { return nil }
                position += 1
                skipWhitespace()
                if key == target {
                    return keys(atPath: path.dropFirst())
                }
                guard skipValue() else { return nil }
                skipWhitespace()
                if peek() == UInt8(ascii: ",") {
                    position += 1
                } else {
                    return nil
                }
            }
        }

        private mutating func objectKeys() -> [String]? {
            guard peek() == UInt8(ascii: "{") else { return nil }
            position += 1
            var result: [String] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "}") { return result }
            while true {
                skipWhitespace()
                guard let key = readString() else { return nil }
                result.append(key)
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else { return nil }
                position += 1
                skipWhitespace()
                guard skipValue() else { return nil }
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","):
                    position += 1
                case UInt8(ascii: "}"):
                    return result
                default:
                    return nil
                }
            }
        }

        private func peek() -> UInt8? {
            position < count ? bytes[position] : nil
        }

        private mutating func skipWhitespace() {
            while position < count {
                switch bytes[position] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    position += 1
                default:
                    return
                }
            }
        }

        /// Reads a JSON string, decoding escapes, positioned at the opening quote.
        private mutating func readString() -> String? {
            guard peek() == UInt8(ascii: "\"") else { return nil }
            let start = position
            position += 1
            var hasEscape = false
            while position < count {
                let byte = bytes[position]
                if byte == UInt8(ascii: "\\") {
                    hasEscape = true
                    position += 2
                    continue
                }
                if byte == UInt8(ascii: "\"") {
                    position += 1
                    let buffer = UnsafeBufferPointer(
                        start: bytes + start,
                        count: position - start
                    )
                    if !hasEscape {
                        return String(
                            decoding: UnsafeBufferPointer(
                                rebasing: buffer.dropFirst().dropLast()
                            ),
                            as: UTF8.self
                        )
                    }
                    return try? JSONDecoder().decode(String.self, from: Data(buffer))
                }
                position += 1
            }
            return nil
        }

        private mutating func skipValue() -> Bool {
            guard let byte = peek() else { return false }
            switch byte {
            case UInt8(ascii: "\""):
                return readStringFast()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while position < count {
                    let current = bytes[position]
                    switch current {
                    case UInt8(ascii: "\""):
                        guard readStringFast() else { return false }
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 {
                            position += 1
                            return true
                        }
                    default:
                        break
                    }
                    position += 1
                }
                return false
            default:
                while position < count {
                    switch bytes[position] {
                    case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                         0x20, 0x09, 0x0A, 0x0D:
                        return true
                    default:
                        position += 1
                    }
                }
                return true
            }
        }

        private mutating func readStringFast() -> Bool {
            guard peek() == UInt8(ascii: "\"") else { return false }
            position += 1
            while position < count {
                let byte = bytes[position]
                if byte == UInt8(ascii: "\\") {
                    position += 2
                    continue
                }
                position += 1
                if byte == UInt8(ascii: "\"") { return true }
            }
            return false
        }
    }
}

/// Orders dictionary keys by a recorded source order. Keys absent from the
/// recorded order follow in lexicographic UTF-16 order, so the result is always
/// deterministic even for dictionaries constructed in code.
func orderedKeys<Value>(
    of dictionary: [String: Value],
    preferredOrder: [String]?
) -> [String] {
    var result: [String] = []
    result.reserveCapacity(dictionary.count)
    var seen: Set<String> = []
    for key in preferredOrder ?? [] where dictionary[key] != nil {
        if seen.insert(key).inserted {
            result.append(key)
        }
    }
    if result.count == dictionary.count { return result }
    let remaining = dictionary.keys
        .filter { !seen.contains($0) }
        .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    result.append(contentsOf: remaining)
    return result
}

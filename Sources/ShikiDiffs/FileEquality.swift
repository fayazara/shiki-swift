import Foundation

/// Matches upstream `areFilesEqual`: headers do not participate, and strings
/// compare exact UTF-16 sequences rather than Unicode canonical equivalence.
public func areFilesEqual(_ first: FileContents?, _ second: FileContents?) -> Bool {
    func equal(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.utf16.elementsEqual(b.utf16)
        default: return false
        }
    }
    return equal(first?.cacheKey, second?.cacheKey)
        && equal(first?.contents, second?.contents)
        && equal(first?.name, second?.name)
        && equal(first?.lang, second?.lang)
}

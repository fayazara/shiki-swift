import Foundation

public struct TrailingContextMismatch: Error, LocalizedError, Equatable, Sendable {
    public let additions: Int
    public let deletions: Int
    public let fileName: String
    public let errorPrefix: String
    public var errorDescription: String? {
        "\(errorPrefix): trailing context mismatch (additions=\(additions), deletions=\(deletions)) for \(fileName)"
    }
}

public func getTrailingContextRangeSize(fileDiff: FileDiffMetadata, errorPrefix: String = "getTrailingContextRangeSize") throws -> Int {
    guard let last = fileDiff.hunks.last, !fileDiff.isPartial,
          !fileDiff.additionLines.isEmpty, !fileDiff.deletionLines.isEmpty else { return 0 }
    let additions = fileDiff.additionLines.count - last.newBoundary - last.additionCount
    let deletions = fileDiff.deletionLines.count - last.oldBoundary - last.deletionCount
    if additions <= 0 && deletions <= 0 { return 0 }
    guard additions == deletions else {
        throw TrailingContextMismatch(additions: additions, deletions: deletions, fileName: fileDiff.name, errorPrefix: errorPrefix)
    }
    return min(additions, deletions)
}

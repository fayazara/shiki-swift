/// Retain this wrapper when a host needs upstream reference-identity semantics.
/// Distinct wrappers around equal metadata remain distinct without cache keys.
public final class DiffTarget: Sendable {
    public let metadata: FileDiffMetadata
    public init(_ metadata: FileDiffMetadata) { self.metadata = metadata }
}

/// Compares cache keys when either target supplies one, otherwise reference identity.
/// Does not traverse source lines, hunks, or other potentially large metadata.
public func areDiffTargetsEqual(_ lhs: DiffTarget?, _ rhs: DiffTarget?) -> Bool {
    let leftKey = lhs?.metadata.cacheKey, rightKey = rhs?.metadata.cacheKey
    if leftKey != nil || rightKey != nil {
        guard let leftKey, let rightKey else { return false }
        return leftKey.utf16.elementsEqual(rightKey.utf16)
    }
    return lhs === rhs
}

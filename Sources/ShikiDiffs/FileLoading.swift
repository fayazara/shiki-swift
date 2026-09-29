#if os(macOS)
import Foundation

public struct LoadedDiffFiles: Sendable {
    public var oldFile: FileContents?
    public var newFile: FileContents
    public init(oldFile: FileContents?, newFile: FileContents) { self.oldFile = oldFile; self.newFile = newFile }
}
public typealias DiffContentsLoader = @Sendable (FileDiffMetadata) async throws -> LoadedDiffFiles

public extension DiffHighlighter {
    func hydrate(_ diff: FileDiffMetadata, files: LoadedDiffFiles, options: DiffRenderOptions = .init()) async throws -> HighlightedDiff {
        try await prepare(hydratePartialDiff(diff, oldFile: files.oldFile, newFile: files.newFile), options: options)
    }
}

public extension HighlightedDiff {
    /// Reuses a logical document identity while retaining this prepared revision.
    func identifyingSource(as sourceID: UUID) -> HighlightedDiff {
        .init(id: id, sourceID: sourceID, diff: diff, oldTokens: oldTokens, newTokens: newTokens,
              oldSpans: oldSpans, newSpans: newSpans, foreground: foreground,
              background: background, palette: palette, preparationMilliseconds: preparationMilliseconds)
    }
}

#endif

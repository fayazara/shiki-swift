#if os(macOS)
import Foundation

/// Retains unresolved source markers and stable diff group identities while
/// conflicts are resolved in any order, like upstream UnresolvedFile.
public struct UnresolvedFileState: Sendable {
    public private(set) var file: FileContents
    public private(set) var result: MergeConflictResult
    public private(set) var revision = UUID()
    public init(file: FileContents, maxContextLines: Int = 6) throws {
        self.file = file; result = try parseMergeConflictDiffFromFile(file, maxContextLines: maxContextLines)
    }
    public mutating func resolve(conflictIndex: Int, resolution: DiffResolution) throws {
        guard let index = result.actions.firstIndex(where: { $0.conflictIndex == conflictIndex }) else {
            throw DiffError.invalidPatch("Conflict is missing or already resolved")
        }
        let action = result.actions[index], region = action.conflict
        let lines = splitFileContents(file.contents)
        guard region.startLineIndex >= 0, region.endLineIndex < lines.count,
              region.startLineIndex < region.separatorLineIndex, region.separatorLineIndex < region.endLineIndex else {
            throw DiffError.invalidPatch("Invalid unresolved source region")
        }
        let current = Array(lines[(region.startLineIndex + 1)..<(region.baseMarkerLineIndex ?? region.separatorLineIndex)])
        let incoming = Array(lines[(region.separatorLineIndex + 1)..<region.endLineIndex])
        let replacement = resolution == .deletions ? current : resolution == .additions ? incoming : current + incoming
        let resolved = try resolveConflict(result.fileDiff, conflict: action, resolution: resolution)
        let text = (Array(lines[..<region.startLineIndex]) + replacement + Array(lines[(region.endLineIndex + 1)...])).joined()
        let label = resolution == .deletions ? "current" : resolution == .additions ? "incoming" : "both"
        let key = file.cacheKey.map { $0 + ":mc-\(conflictIndex)-\(label)" }
        file = .init(name: file.name, contents: text, cacheKey: key)
        result.fileDiff = resolved
        result.actions.remove(at: index)
        let delta = replacement.count - (region.endLineIndex - region.startLineIndex + 1)
        for i in result.actions.indices where result.actions[i].conflict.startLineIndex > region.endLineIndex {
            var next = result.actions[i].conflict
            next.startLineIndex += delta; next.startLineNumber += delta
            next.separatorLineIndex += delta; next.separatorLineNumber += delta
            next.endLineIndex += delta; next.endLineNumber += delta
            next.baseMarkerLineIndex = next.baseMarkerLineIndex.map { $0 + delta }
            next.baseMarkerLineNumber = next.baseMarkerLineNumber.map { $0 + delta }
            result.actions[i].conflict = next
        }
        result.markerRows = buildMergeConflictMarkerRows(resolved, actions: result.actions)
        result.currentFile.contents = resolved.deletionLines.joined()
        result.incomingFile.contents = resolved.additionLines.joined()
        revision = UUID()
    }
}

#endif

#if os(macOS)
import Foundation

public enum CodeColumnType: String, Codable, Sendable { case unified, additions, deletions }

/// Metadata supplied to an upstream-style hunk separator renderer.
public struct HunkData: Equatable, Sendable {
    public struct Expandable: Equatable, Sendable {
        public var chunked: Bool
        public var up: Bool
        public var down: Bool
        public init(chunked: Bool, up: Bool, down: Bool) {
            self.chunked = chunked; self.up = up; self.down = down
        }
    }
    public var slotName: String
    public var hunkIndex: Int
    public var lines: Int
    public var lineCountKnown: Bool
    public var type: CodeColumnType
    public var expandable: Expandable?
    public init(slotName: String, hunkIndex: Int, lines: Int, lineCountKnown: Bool,
                type: CodeColumnType, expandable: Expandable? = nil) {
        self.slotName = slotName; self.hunkIndex = hunkIndex; self.lines = lines
        self.lineCountKnown = lineCountKnown; self.type = type; self.expandable = expandable
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.slotName.utf16.elementsEqual(rhs.slotName.utf16) && lhs.hunkIndex == rhs.hunkIndex
            && lhs.lines == rhs.lines && lhs.lineCountKnown == rhs.lineCountKnown
            && lhs.type == rhs.type && lhs.expandable == rhs.expandable
    }
}

public func areHunkDataEqual(_ lhs: HunkData, _ rhs: HunkData) -> Bool { lhs == rhs }

public func getHunkSeparatorSlotName(type: CodeColumnType, hunkIndex: Int) -> String {
    "hunk-separator-\(type.rawValue)-\(hunkIndex)"
}

public extension DiffRow {
    /// Metadata for a concrete collapsed-context row. Non-separator rows return nil.
    /// Partial files require a context loader before expansion can be offered.
    func hunkData(in diff: FileDiffMetadata, type: CodeColumnType,
                  expansionLineCount: Int = 100, canHydrateContext: Bool = false) -> HunkData? {
        guard case let .separator(hidden, index) = kind else { return nil }
        let unknown = diff.isPartial && canHydrateContext && index == diff.hunks.count && hidden == 0
        let rangeSize: Int
        if diff.hunks.indices.contains(index) { rangeSize = max(0, diff.hunks[index].collapsedBefore) }
        else if index == diff.hunks.count {
            guard let trailing = try? getTrailingContextRangeSize(fileDiff: diff) else { return nil }
            rangeSize = trailing
        } else { rangeSize = 0 }
        return .init(slotName: getHunkSeparatorSlotName(type: type, hunkIndex: index),
            hunkIndex: index, lines: hidden, lineCountKnown: !unknown, type: type,
            expandable: !diff.isPartial || canHydrateContext
                ? .init(chunked: rangeSize > expansionLineCount, up: index > 0, down: index < diff.hunks.count)
                : nil)
    }
}

public enum HunkExpansionAction: String, Equatable, Sendable {
    case up, down, both, all
}

public extension HunkData {
    /// Ordered controls emitted by upstream line-info separators.
    var expansionActions: [HunkExpansionAction] {
        guard let expandable else { return [] }
        if !expandable.chunked {
            return [expandable.up && expandable.down ? .both : expandable.down ? .down : .up]
        }
        var actions: [HunkExpansionAction] = []
        if expandable.up { actions.append(.up) }
        if expandable.down { actions.append(.down) }
        actions.append(.all)
        return actions
    }
}

#endif

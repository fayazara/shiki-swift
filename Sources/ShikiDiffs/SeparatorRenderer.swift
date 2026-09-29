#if os(macOS)
import AppKit

/// Creates custom collapsed-context content for each visible code column.
/// Select `hunkSeparators = .custom` to replace the built-in separator.
/// Retain this object across SwiftUI updates to preserve mounted controls.
@MainActor public final class DiffSeparatorRenderer {
    public typealias Expand = @MainActor (HunkExpansionAction) -> Bool
    public let render: (HunkData, @escaping Expand) -> NSView?
    public init(_ render: @escaping (HunkData, @escaping Expand) -> NSView?) {
        self.render = render
    }
}

#endif

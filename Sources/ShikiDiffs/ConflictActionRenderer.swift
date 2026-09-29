#if os(macOS)
import AppKit

/// Custom controls for a parsed merge conflict. Keep this renderer in host state.
/// The resolve function rejects actions from replaced or unmounted controls.
@MainActor public final class DiffConflictActionRenderer {
    public typealias Resolve = @MainActor (DiffResolution) -> Bool
    public let render: (MergeConflictDiffAction, @escaping Resolve) -> NSView?
    public init(_ render: @escaping (MergeConflictDiffAction, @escaping Resolve) -> NSView?) {
        self.render = render
    }
}

#endif

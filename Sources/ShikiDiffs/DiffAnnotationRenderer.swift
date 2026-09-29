#if os(macOS)
import AppKit

/// Retain this renderer across SwiftUI updates to preserve mounted annotation
/// views. Replace the object when the rendering implementation changes.
@MainActor public final class DiffAnnotationRenderer {
    public let render: (LineAnnotation) -> NSView?
    public init(_ render: @escaping (LineAnnotation) -> NSView?) { self.render = render }
}

#endif

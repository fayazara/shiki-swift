#if os(macOS)
import AppKit

/// Native counterpart of the web library's reduced-motion media query.
@MainActor public func prefersReducedMotion() -> Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

#endif

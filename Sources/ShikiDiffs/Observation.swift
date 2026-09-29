#if os(macOS)
import AppKit

/// Owns exactly one NotificationCenter registration and removes it at teardown.
final class NotificationObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(name: Notification.Name, object: AnyObject, handler: @escaping @Sendable (Notification) -> Void) {
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main, using: handler)
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor final class ViewFrameSizeObservation: NSObject {
    private weak var view: NSView?
    private var size: NSSize
    private let onResize: () -> Void
    init(view: NSView, onResize: @escaping () -> Void) {
        self.view = view; self.size = view.frame.size; self.onResize = onResize
        super.init()
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: view)
    }
    @objc private func frameChanged(_ notification: Notification) {
        guard let view, view.frame.size != size else { return }
        size = view.frame.size
        onResize()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

#endif

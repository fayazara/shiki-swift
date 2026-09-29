#if os(macOS)
import AppKit

/// AppKit equivalents of upstream's presence-based header render callbacks.
/// Metadata supplements the change counts. A custom-header callback suppresses
/// all default slots, including when it returns nil. Return a fresh view for
/// each header host, or retain a view belonging only to that host.
@MainActor public struct DiffHeaderRenderers {
    public typealias Renderer = (FileDiffMetadata) -> NSView?
    public var renderHeaderPrefix: Renderer?
    public var renderHeaderFilenameSuffix: Renderer?
    public var renderHeaderMetadata: Renderer?
    public var renderCustomHeader: Renderer?
    var isEmpty: Bool {
        renderHeaderPrefix == nil && renderHeaderFilenameSuffix == nil
            && renderHeaderMetadata == nil && renderCustomHeader == nil
    }
    public init(renderHeaderPrefix: Renderer? = nil, renderHeaderFilenameSuffix: Renderer? = nil,
                renderHeaderMetadata: Renderer? = nil, renderCustomHeader: Renderer? = nil) {
        self.renderHeaderPrefix = renderHeaderPrefix
        self.renderHeaderFilenameSuffix = renderHeaderFilenameSuffix
        self.renderHeaderMetadata = renderHeaderMetadata
        self.renderCustomHeader = renderCustomHeader
    }
}

@MainActor final class DiffHeaderView: NSView {
    let filename = NSTextField(labelWithString: "")
    private let status = DiffStatusIcon(frame: .zero)
    let counts = NSTextField(labelWithString: "")
    private(set) var prefix: NSView?
    private(set) var suffix: NSView?
    private(set) var metadata: NSView?
    private(set) var custom: NSView?
    private(set) var customMode = false
    var onSizeChange: (() -> Void)?
    private var frameObservations: [ViewFrameSizeObservation] = []
    private var placingContent = false
    private var minimumHeight: CGFloat = 44
    static func defaultHeight(options: DiffRenderOptions) -> CGFloat { options.lineHeight + 24 }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(status)
        for label in [filename, counts] {
            label.font = .systemFont(ofSize: 13, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    private func size(_ view: NSView?) -> NSSize {
        guard let view else { return .zero }
        if view === filename || view === counts, let label = view as? NSTextField {
            // Truncating text fields can report a constrained intrinsic width.
            // Measure the actual header text before allocating available space.
            let text = view === counts ? counts.attributedStringValue.size() : (label.stringValue as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 12)])
            return .init(width: ceil(text.width) + 4, height: max(ceil(text.height), label.intrinsicContentSize.height))
        }
        let intrinsic = view.intrinsicContentSize, fitting = view.fittingSize
        return .init(width: max(0, intrinsic.width >= 0 ? intrinsic.width : max(fitting.width, view.frame.width)),
                     height: max(0, intrinsic.height >= 0 ? intrinsic.height : max(fitting.height, view.frame.height)))
    }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        let wasPlacing = placingContent; placingContent = true
        defer { placingContent = wasPlacing }
        if customMode {
            if let custom, custom.frame.width != max(0, width) {
                custom.setFrameSize(.init(width: max(0, width), height: custom.frame.height))
                custom.needsLayout = true
                custom.layoutSubtreeIfNeeded()
            }
            return size(custom).height
        }
        return max(minimumHeight, [prefix, suffix, metadata].map { size($0).height }.max() ?? 0)
    }
    func update(_ document: HighlightedDiff, renderers: DiffHeaderRenderers, file: FileContents? = nil, options: DiffRenderOptions = .init()) {
        frameObservations.removeAll()
        let wasPlacing = placingContent; placingContent = true
        defer { placingContent = wasPlacing }
        minimumHeight = Self.defaultHeight(options: options)
        filename.font = .systemFont(ofSize: options.fontSize, weight: .regular)
        let countFont = options.fontName.flatMap { NSFont(name: $0, size: options.fontSize) } ?? .monospacedSystemFont(ofSize: options.fontSize, weight: .regular)
        counts.font = countFont
        for view in [prefix, suffix, metadata, custom] { view?.removeFromSuperview() }
        prefix = nil; suffix = nil; metadata = nil; custom = nil
        let diff = document.diff
        customMode = renderers.renderCustomHeader != nil
        filename.isHidden = customMode; counts.isHidden = customMode
        status.isHidden = customMode
        status.change = file == nil ? diff.type : nil
        status.color = file != nil ? .diffHex(document.foreground) : .diffHex(diff.type == .new ? document.palette.addition : diff.type == .deleted ? document.palette.deletion : document.palette.modified)
        status.needsDisplay = true
        layer?.backgroundColor = NSColor.diffHex(document.background).cgColor
        if let render = renderers.renderCustomHeader {
            custom = render(diff)
            if let custom { addSubview(custom) }
        } else {
            filename.stringValue = file?.name ?? ((diff.prevName.map { $0 + " → " } ?? "") + diff.name)
            var parts: [String] = []
            if diff.deletions > 0 || diff.additions == 0 { parts.append("−\(diff.deletions)") }
            if diff.additions > 0 || diff.deletions == 0 { parts.append("+\(diff.additions)") }
            let countsText = NSMutableAttributedString(string: "")
            if file == nil {
                for (index, part) in parts.enumerated() {
                    if index > 0 { countsText.append(NSAttributedString(string: "  ")) }
                    countsText.append(NSAttributedString(string: part, attributes: [.font: countFont, .foregroundColor: NSColor.diffHex(part.hasPrefix("−") ? document.palette.deletion : document.palette.addition)]))
                }
            }
            countsText.addAttribute(.font, value: countFont, range: NSRange(location: 0, length: countsText.length))
            counts.attributedStringValue = countsText
            filename.textColor = .diffHex(document.foreground)
            prefix = renderers.renderHeaderPrefix?(diff)
            suffix = renderers.renderHeaderFilenameSuffix?(diff)
            metadata = renderers.renderHeaderMetadata?(diff)
            for view in [prefix, suffix, metadata] { if let view { addSubview(view) } }
        }
        frameObservations = [prefix, suffix, metadata, custom].compactMap { $0 }.map { view in
            ViewFrameSizeObservation(view: view) { [weak self] in
                guard let self, !self.placingContent else { return }
                self.needsLayout = true; self.onSizeChange?()
            }
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let wasPlacing = placingContent; placingContent = true
        defer { placingContent = wasPlacing }
        if customMode { custom?.frame = bounds; return }
        var left: CGFloat = 16, right = max(16, bounds.width - 16)
        status.frame = .init(x: left, y: (bounds.height - 16) / 2, width: 16, height: 16)
        left += 24
        func place(_ view: NSView, x: CGFloat, width: CGFloat) {
            let height = min(bounds.height, size(view).height)
            view.frame = .init(x: x, y: (bounds.height - height) / 2, width: max(0, width), height: height)
        }
        if let metadata {
            let width = min(size(metadata).width, max(0, right - left))
            right -= width; place(metadata, x: right, width: width); right -= 8
        }
        let countWidth = min(size(counts).width, max(0, right - left))
        right -= countWidth; place(counts, x: right, width: countWidth); right -= 16
        if let prefix {
            let width = min(size(prefix).width, max(0, right - left))
            place(prefix, x: left, width: width); left += width + 8
        }
        let suffixWidth = min(size(suffix).width, max(0, right - left))
        let available = max(0, right - left - (suffix == nil ? 0 : suffixWidth + 8))
        let filenameWidth = min(size(filename).width, available)
        place(filename, x: left, width: filenameWidth); left += filenameWidth
        if let suffix { place(suffix, x: left + 8, width: suffixWidth) }
    }
}


@MainActor private final class DiffStatusIcon: NSView {
    var change: ChangeType? = .change
    var color = NSColor.systemBlue
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let symbol: DiffSymbol
        switch change {
        case .change: symbol = .modified
        case .new: symbol = .added
        case .deleted: symbol = .deleted
        case .renamePure, .renameChanged: symbol = .moved
        case nil: symbol = .fileCode
        }
        symbol.draw(in: bounds, color: color)
    }
}

#endif

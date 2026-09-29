#if os(macOS)
import AppKit
import SwiftUI

/// Owns a source stream, its tokenizer, and a virtualized native presentation.
/// Each setup replaces the previous source. Cancellation preserves the last
/// snapshot; cleanUp also clears it. Callbacks run on the main actor.
@MainActor public final class NativeFileStreamView: NSView {
    public let fileView = NativeFileView(frame: .zero)
    public var onPreRender: ((NativeFileStreamView) -> Void)?
    public var onPostRender: ((NativeFileStreamView) -> Void)?
    public var onStreamStart: (() -> Void)?
    public var onStreamWrite: ((StreamTokenEvent) -> Void)?
    public var onStreamClose: (() -> Void)?
    public var onStreamAbort: ((any Error) -> Void)?
    public private(set) var isStreaming = false
    public private(set) var document: HighlightedDiff?
    public private(set) var error: (any Error)?
    public var startingLineIndex = 1 { didSet { fileView.diffView.startingLineIndex = startingLineIndex } }
    public var themeAppearance: DiffThemeAppearance = .system {
        didSet { if themeAppearance != oldValue { present() } }
    }
    private var lightDocument: HighlightedDiff?
    private var darkDocument: HighlightedDiff?
    private var presentationRevision = UUID()
    private var options = DiffRenderOptions()
    private var generation = UUID()
    private var streamTask: Task<Void, Never>?
    private var abortCurrent: ((any Error) -> Void)?

    public override init(frame: NSRect) { super.init(frame: frame); addSubview(fileView) }
    public required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    deinit { streamTask?.cancel() }
    public override func layout() { super.layout(); fileView.frame = bounds }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if themeAppearance == .system { present() }
    }
    private func present() {
        guard let lightDocument, let darkDocument else { return }
        let light = themeAppearance == .light || (themeAppearance == .system && effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua)
        install(light ? lightDocument : darkDocument, generation: generation)
    }
    private func streamOptions(_ options: DiffRenderOptions) -> DiffRenderOptions {
        var options = options
        options.disableFileHeader = true; options.diffIndicators = .none; options.disableBackground = true
        return options
    }
    public func setOptions(_ options: DiffRenderOptions) {
        let options = streamOptions(options)
        guard self.options != options else { return }
        self.options = options
        if let document { install(document, generation: generation) }
    }
    public func setup(_ source: AsyncThrowingStream<String, any Error>, name: String,
                      configuration: StreamTokenizerConfiguration, options: DiffRenderOptions = .init()) {
        setup(source, name: name, primary: configuration, alternate: nil, options: options)
    }
    /// Token write callbacks keep the light tokenizer's stable identity across
    /// appearance switches. The displayed snapshot uses the selected theme.
    public func setup(_ source: AsyncThrowingStream<String, any Error>, name: String,
                      configuration: ThemedStreamTokenizerConfiguration, options: DiffRenderOptions = .init()) {
        setup(source, name: name, primary: configuration.light, alternate: configuration.dark, options: options)
    }
    private func setup(_ source: AsyncThrowingStream<String, any Error>, name: String,
                       primary: StreamTokenizerConfiguration, alternate: StreamTokenizerConfiguration?, options: DiffRenderOptions) {
        cancel()
        guard !isStreaming else { return }
        let request = UUID(); generation = request; self.options = streamOptions(options)
        document = nil; lightDocument = nil; darkDocument = nil; error = nil; fileView.cleanUp()
        // A presentation teardown callback can install another source.
        guard generation == request else { return }
        let stream = FileStream(name: name, configuration: primary)
        let alternateStream = alternate.map { FileStream(name: name, configuration: $0) }
        isStreaming = true; abortCurrent = onStreamAbort
        let start = onStreamStart, write = onStreamWrite, close = onStreamClose
        streamTask = Task { [weak self] in
            guard self?.generation == request else { return }
            start?()
            guard self?.generation == request, !Task.isCancelled else { return }
            do {
                for try await chunk in source {
                    try Task.checkCancellation()
                    let result = try await stream.appendWithUpdate(chunk)
                    let alternateDocument = try await alternateStream?.append(chunk)
                    try Task.checkCancellation()
                    guard self?.receive(result, alternate: alternateDocument, generation: request, write: write) == true else { return }
                }
                try Task.checkCancellation()
                let final = await stream.close()
                let alternateFinal = await alternateStream?.close()
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                self.installSnapshots(final, alternate: alternateFinal, generation: request)
                guard self.generation == request else { return }
                self.isStreaming = false; self.abortCurrent = nil; self.streamTask = nil
                close?()
            } catch {
                guard let self, self.generation == request else { return }
                self.error = error; self.isStreaming = false; self.streamTask = nil
                let abort = self.abortCurrent; self.abortCurrent = nil
                abort?(error)
            }
        }
    }
    private func receive(_ result: FileStreamAppendResult, alternate: HighlightedDiff?, generation request: UUID, write: ((StreamTokenEvent) -> Void)?) -> Bool {
        guard generation == request else { return false }
        let update = result.tokens
        if update.recall > 0 { write?(.recall(update.recall)) }
        guard generation == request else { return false }
        for token in update.stable + update.unstable {
            write?(.token(token))
            guard generation == request else { return false }
        }
        installSnapshots(result.document, alternate: alternate, generation: request)
        return generation == request
    }
    private func installSnapshots(_ primary: HighlightedDiff, alternate: HighlightedDiff?, generation request: UUID) {
        guard generation == request else { return }
        if let alternate {
            lightDocument = primary; darkDocument = alternate.identifyingSource(as: primary.sourceID)
            present()
        } else { install(primary, generation: request) }
    }
    private func install(_ document: HighlightedDiff, generation request: UUID) {
        guard generation == request else { return }
        let revision = UUID(); presentationRevision = revision
        onPreRender?(self)
        guard generation == request, presentationRevision == revision else { return }
        self.document = document
        fileView.render(document, file: .init(name: document.diff.name, contents: document.diff.additionLines.joined()), options: options)
        guard generation == request, presentationRevision == revision else { return }
        onPostRender?(self)
    }
    public func cancel() {
        generation = UUID(); streamTask?.cancel(); streamTask = nil
        let abort = abortCurrent; abortCurrent = nil
        let wasStreaming = isStreaming; isStreaming = false
        if wasStreaming { abort?(CancellationError()) }
    }
    public func cleanUp() {
        cancel()
        // Abort handlers may deliberately start a new stream.
        guard !isStreaming else { return }
        document = nil; lightDocument = nil; darkDocument = nil; error = nil; fileView.cleanUp()
    }
    public func waitForCompletion() async { await streamTask?.value; await fileView.diffView.waitForLayout() }
}

/// Supply a new streamID for a different source or tokenizer configuration;
/// layout/font updates preserve the current stream.
public struct FileStreamView: NSViewRepresentable {
    public var source: AsyncThrowingStream<String, any Error>
    public var streamID: UUID
    public var name: String
    public var configuration: StreamTokenizerConfiguration
    public var adaptiveConfiguration: ThemedStreamTokenizerConfiguration?
    public var themeAppearance: DiffThemeAppearance
    public var options: DiffRenderOptions
    public var startingLineIndex: Int
    public var onPreRender: ((NativeFileStreamView) -> Void)?
    public var onPostRender: ((NativeFileStreamView) -> Void)?
    public var onStreamStart: (() -> Void)?
    public var onStreamWrite: ((StreamTokenEvent) -> Void)?
    public var onStreamClose: (() -> Void)?
    public var onStreamAbort: ((any Error) -> Void)?
    public init(source: AsyncThrowingStream<String, any Error>, streamID: UUID, name: String,
                configuration: StreamTokenizerConfiguration, options: DiffRenderOptions = .init(), startingLineIndex: Int = 1,
                adaptiveConfiguration: ThemedStreamTokenizerConfiguration? = nil, themeAppearance: DiffThemeAppearance = .system,
                onPreRender: ((NativeFileStreamView) -> Void)? = nil, onPostRender: ((NativeFileStreamView) -> Void)? = nil,
                onStreamStart: (() -> Void)? = nil, onStreamWrite: ((StreamTokenEvent) -> Void)? = nil,
                onStreamClose: (() -> Void)? = nil, onStreamAbort: ((any Error) -> Void)? = nil) {
        self.source = source; self.streamID = streamID; self.name = name; self.configuration = configuration
        self.options = options; self.startingLineIndex = startingLineIndex
        self.adaptiveConfiguration = adaptiveConfiguration; self.themeAppearance = themeAppearance
        self.onPreRender = onPreRender; self.onPostRender = onPostRender
        self.onStreamStart = onStreamStart; self.onStreamWrite = onStreamWrite; self.onStreamClose = onStreamClose; self.onStreamAbort = onStreamAbort
    }
    @MainActor public final class Coordinator { var id: UUID? }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func makeNSView(context: Context) -> NativeFileStreamView { .init(frame: .zero) }
    public func updateNSView(_ view: NativeFileStreamView, context: Context) {
        view.onPreRender = onPreRender; view.onPostRender = onPostRender
        view.onStreamStart = onStreamStart; view.onStreamWrite = onStreamWrite
        view.onStreamClose = onStreamClose; view.onStreamAbort = onStreamAbort
        view.startingLineIndex = startingLineIndex; view.themeAppearance = themeAppearance
        if context.coordinator.id != streamID {
            context.coordinator.id = streamID
            if let adaptiveConfiguration { view.setup(source, name: name, configuration: adaptiveConfiguration, options: options) }
            else { view.setup(source, name: name, configuration: configuration, options: options) }
        } else { view.setOptions(options) }
    }
    public static func dismantleNSView(_ view: NativeFileStreamView, coordinator: Coordinator) { view.cleanUp() }
}

#endif

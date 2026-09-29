#if os(macOS)
import Shiki

/// Remove the specified number of previously emitted tokens before applying
/// subsequent tokens. Recall events only occur when `allowRecalls` is enabled.
public enum StreamTokenEvent: Equatable, Sendable {
    case token(ThemedToken)
    case recall(Int)
}

/// Pull-based native adaptation of upstream's CodeToTokenTransformStream.
/// Each iterator owns its tokenizer and consumes the source only when its
/// current chunk's output has drained. Source errors and cancellation terminate
/// that iterator without flushing incomplete text.
public struct CodeToTokenTransformStream<Source: AsyncSequence>: AsyncSequence where Source.Element == String {
    public typealias Element = StreamTokenEvent
    private let source: Source
    public let configuration: StreamTokenizerConfiguration
    public var language: String { configuration.language }
    public var theme: String { configuration.theme }
    public let allowRecalls: Bool

    public init(_ source: Source, language: String, theme: String = "github-dark", allowRecalls: Bool = false) {
        self.init(source, configuration: .init(language: language, theme: theme), allowRecalls: allowRecalls)
    }
    public init(_ source: Source, configuration: StreamTokenizerConfiguration, allowRecalls: Bool = false) {
        self.source = source; self.configuration = configuration; self.allowRecalls = allowRecalls
    }
    public func makeAsyncIterator() -> AsyncIterator {
        .init(source: source.makeAsyncIterator(), configuration: configuration, allowRecalls: allowRecalls)
    }
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var source: Source.AsyncIterator
        private let tokenizer: ShikiStreamTokenizer
        private let allowRecalls: Bool
        private var pending: [StreamTokenEvent] = []
        private var nextIndex = 0
        private var finished = false

        fileprivate init(source: Source.AsyncIterator, configuration: StreamTokenizerConfiguration, allowRecalls: Bool) {
            self.source = source; self.allowRecalls = allowRecalls
            tokenizer = .init(configuration: configuration)
        }
        public mutating func next() async throws -> StreamTokenEvent? {
            do {
                while true {
                    try Task.checkCancellation()
                    if nextIndex < pending.count {
                        let event = pending[nextIndex]; nextIndex += 1
                        return event
                    }
                    pending.removeAll(keepingCapacity: false); nextIndex = 0
                    if finished { return nil }
                    if let chunk = try await source.next() {
                        try Task.checkCancellation()
                        let update = try await tokenizer.enqueue(chunk)
                        if allowRecalls && update.recall > 0 { pending.append(.recall(update.recall)) }
                        pending.append(contentsOf: update.stable.map(StreamTokenEvent.token))
                        if allowRecalls { pending.append(contentsOf: update.unstable.map(StreamTokenEvent.token)) }
                    } else {
                        let tail = await tokenizer.close()
                        if !allowRecalls { pending = tail.map(StreamTokenEvent.token) }
                        finished = true
                    }
                }
            } catch {
                finished = true; pending = []; nextIndex = 0
                throw error
            }
        }
    }
}

#endif

import Testing
import Shiki
@testable import ShikiDiffs

private actor ChunkProbe {
    enum Failure: Error { case source }
    let chunks: [String]
    let failAtEnd: Bool
    private(set) var reads = 0
    init(_ chunks: [String], failAtEnd: Bool = false) { self.chunks = chunks; self.failAtEnd = failAtEnd }
    func next() throws -> String? {
        defer { reads += 1 }
        if reads < chunks.count { return chunks[reads] }
        if failAtEnd { throw Failure.source }
        return nil
    }
    nonisolated var sequence: AsyncThrowingStream<String, any Error> {
        .init(unfolding: { try await self.next() })
    }
}

struct TokenTransformStreamTests {
    @Test(arguments: [false, true]) func outputReconstructsChunksAndMatchesTokenizerProtocol(recalls: Bool) async throws {
        let chunks = ["/* comment\n", "still", " comment */\nlet va", "lue = \"👋\"", "\n", "tail"]
        let probe = ChunkProbe(chunks)
        var events: [StreamTokenEvent] = []
        for try await event in CodeToTokenTransformStream(probe.sequence, language: "swift", theme: "pierre-dark", allowRecalls: recalls) { events.append(event) }
        let reference = ShikiStreamTokenizer(language: "swift", theme: "pierre-dark")
        var expected: [StreamTokenEvent] = []
        for chunk in chunks {
            let update = try await reference.enqueue(chunk)
            if recalls && update.recall > 0 { expected.append(.recall(update.recall)) }
            expected += update.stable.map(StreamTokenEvent.token)
            if recalls { expected += update.unstable.map(StreamTokenEvent.token) }
        }
        let tail = await reference.close()
        if !recalls { expected += tail.map(StreamTokenEvent.token) }
        #expect(events == expected)
        var reconstructed: [ThemedToken] = []
        for event in events {
            switch event {
            case .token(let token): reconstructed.append(token)
            case .recall(let count):
                try #require(count <= reconstructed.count)
                reconstructed.removeLast(count)
            }
        }
        #expect(reconstructed.map(\.content).joined() == chunks.joined())
        #expect(events.contains { if case .recall = $0 { return true }; return false } == recalls)
    }

    @Test func consumerBackpressureDoesNotReadNextChunkEarly() async throws {
        let probe = ChunkProbe(["one\ntwo\n", "three\n"])
        var iterator = CodeToTokenTransformStream(probe.sequence, language: "text").makeAsyncIterator()
        #expect(await probe.reads == 0)
        // Plain text yields one token plus a newline token for each complete line.
        for _ in 0..<4 {
            #expect(try await iterator.next() != nil)
            #expect(await probe.reads == 1)
        }
        #expect(try await iterator.next() != nil)
        #expect(await probe.reads == 2)
    }

    @Test func sourceFailureTerminatesWithoutFlushingPendingText() async throws {
        let probe = ChunkProbe(["pending"], failAtEnd: true)
        var iterator = CodeToTokenTransformStream(probe.sequence, language: "text").makeAsyncIterator()
        await #expect(throws: ChunkProbe.Failure.self) { try await iterator.next() }
        #expect(try await iterator.next() == nil)
        #expect(await probe.reads == 2)
    }

    @Test func cancellationDoesNotConsumeSource() async throws {
        let probe = ChunkProbe(["unused\n"])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var iterator = CodeToTokenTransformStream(probe.sequence, language: "text").makeAsyncIterator()
            await #expect(throws: CancellationError.self) { try await iterator.next() }
        }
        await task.value
        #expect(await probe.reads == 0)
    }
}

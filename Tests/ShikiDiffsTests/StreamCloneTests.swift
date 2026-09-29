import Testing
@testable import ShikiDiffs

struct StreamCloneTests {
    @Test func cloneBranchesGrammarAndPendingTextButSharesStableBuffer() async throws {
        let source = ShikiStreamTokenizer(language: "swift", theme: "pierre-dark")
        let prefix = "/* comment\ncontinued"
        _ = try await source.enqueue(prefix)
        let clone = await source.clone()
        #expect(await clone.tokensStable == source.tokensStable)
        #expect(await clone.tokensUnstable == source.tokensUnstable)
        #expect(await clone.lastUnstableCodeChunk == "continued")
        let sourceTail = " source */\nlet source = 1"
        let cloneTail = " clone */\nlet clone = 2"
        async let sourceResult = source.enqueue(sourceTail)
        async let cloneResult = clone.enqueue(cloneTail)
        let (a, b) = try await (sourceResult, cloneResult)
        for (tail, actual) in [(sourceTail, a), (cloneTail, b)] {
            let reference = ShikiStreamTokenizer(language: "swift", theme: "pierre-dark")
            _ = try await reference.enqueue(prefix)
            let expected = try await reference.enqueue(tail)
            #expect(actual.recall == expected.recall)
            #expect(actual.stable == expected.stable)
            #expect(actual.unstable == expected.unstable)
        }
        let shared = await source.tokensStable
        #expect(await clone.tokensStable == shared)
        let contents = shared.map(\.content).joined()
        #expect(contents.hasPrefix("/* comment\n"))
        #expect(contents.contains("continued source */\n"))
        #expect(contents.contains("continued clone */\n"))
        #expect(await source.lastUnstableCodeChunk == "let source = 1")
        #expect(await clone.lastUnstableCodeChunk == "let clone = 2")
        await clone.clear()
        #expect(await clone.tokensStable.isEmpty)
        #expect(await source.tokensStable == shared)
        _ = try await clone.enqueue("fresh\n")
        #expect(await source.tokensStable == shared)
        #expect(await clone.tokensStable.map(\.content).joined() == "fresh\n")
        #expect(await source.close() == a.unstable)
        #expect(await clone.tokensStable.map(\.content).joined() == "fresh\n")
    }

    @Test func cloneBeforeFirstChunkAndAfterClose() async throws {
        let source = ShikiStreamTokenizer(language: "text")
        let early = await source.clone()
        _ = try await source.enqueue("one\npending")
        #expect(await early.tokensStable.map(\.content).joined() == "one\n")
        #expect(await early.tokensUnstable.isEmpty)
        _ = await source.close()
        let closed = await source.clone()
        #expect(await closed.lastUnstableCodeChunk.isEmpty)
        #expect(await closed.tokensUnstable.isEmpty)
        _ = try await closed.enqueue("two\n")
        #expect(await source.tokensStable.map(\.content).joined() == "one\ntwo\n")
        #expect(await early.tokensStable == source.tokensStable)
    }
}

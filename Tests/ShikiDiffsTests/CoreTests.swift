import Testing
import Foundation
@testable import ShikiDiffs

@Suite struct PatchParityTests {
    struct TrimFixture: Decodable { var patch: String; var contextSize: Int; var expected: String }
    @Test func upstreamContextTrimming() throws {
        let url = fixtureURL("trim-oracle")!
        for (index, fixture) in try JSONDecoder().decode([TrimFixture].self, from: Data(contentsOf: url)).enumerated() {
            #expect(trimPatchContext(fixture.patch, contextSize: fixture.contextSize) == fixture.expected, "Trim fixture \(index)")
        }
    }
    struct Fixture: Decodable { var name: String; var patch: String; var expected: [ParsedPatch] }
    @Test func upstreamPatchOracle() throws {
        let url = fixtureURL("patch-oracle")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let actual = try parsePatchFiles(fixture.patch, cacheKeyPrefix: "oracle")
            #expect(actual == fixture.expected, "Upstream mismatch: \(fixture.name)")
            for diff in actual.flatMap(\.files) {
                for style in DiffStyle.allCases {
                    var options = DiffRenderOptions(); options.diffStyle = style
                    #expect(DiffRenderPlan.unannotatedRowCount(diff, options: options, expandedRegions: [:]) == DiffRenderPlan(diff: diff, options: options).rows.count)
                }
            }
        }
    }
    @Test func strictMalformedPatch() {
        #expect(throws: DiffError.self) { try parsePatchFiles("--- f\n+++ f\n@@ -1,6 +1,6 @@\n-a\n+A\n c0\n c1\n-b\n+B\n", throwOnError: true) }
    }
    @Test func newlines() {
        #expect(splitFileContents("") == [])
        #expect(splitFileContents("a\n") == ["a\n"])
        #expect(splitFileContents("a\r\nb\r\n") == ["a\r\n", "b\r\n"])
        #expect(splitFileContents("\n\n") == ["\n", "\n"])
        #expect(splitFileContents("😀\nlast") == ["😀\n", "last"])
        #expect(cleanLastNewline("a\r\n") == "a")
    }
    @Test func collisionSafeKeys() {
        #expect(composeCacheKey("diff", "a:b", "c") != composeCacheKey("diff", "a", "b:c"))
        #expect(composeCacheKey("diff", "a", "b") == #"ck1:["diff","a","b"]"#)
    }
    @Test func hydratePreservesGeometry() throws {
        let partial = try #require(try processFile("--- f\n+++ f\n@@ -3 +3 @@\n-old\n+new\n", cacheKey: "partial", throwOnError: true))
        let full = try hydratePartialDiff(partial, oldFile: .init(name: "f", contents: "a\nb\nold\nz\n"), newFile: .init(name: "f", contents: "a\nb\nnew\nz\n"))
        #expect(full.hunks[0].additionLineIndex == 2)
        #expect(full.hunks[0].hunkContent[0].additionLineIndex == 2)
        #expect(full.splitLineCount == 4)
        #expect(full.cacheKey == "partial:hydrated")
        #expect(partial.isPartial)
    }
}
@Suite struct DiffAlgorithmTests {
    @Test func allShortSequencesAreShortest() {
        // Independent dynamic-programming oracle, only in tests, exhaustively checks
        // reconstruction and minimum edit count for ambiguous repeated tokens.
        let sequences = (0..<81).map { value -> [Int] in
            var v = value, result: [Int] = []
            for _ in 0..<4 { result.append(v % 3); v /= 3 }
            return result
        }
        for a in sequences { for b in sequences {
            let edits = sequenceDiff(a, b)
            var ai = 0, bi = 0, result: [Int] = [], cost = 0
            for edit in edits {
                switch edit.kind {
                case .equal: result += a[ai..<(ai + edit.count)]; #expect(Array(a[ai..<(ai + edit.count)]) == Array(b[bi..<(bi + edit.count)])); ai += edit.count; bi += edit.count
                case .delete: ai += edit.count; cost += edit.count
                case .insert: result += b[bi..<(bi + edit.count)]; bi += edit.count; cost += edit.count
                }
            }
            var dp = Array(0...b.count)
            for x in a.indices {
                var next = [x + 1] + Array(repeating: 0, count: b.count)
                for y in b.indices { next[y + 1] = a[x] == b[y] ? dp[y] : min(dp[y + 1], next[y]) + 1 }
                dp = next
            }
            #expect(result == b); #expect(ai == a.count); #expect(bi == b.count); #expect(cost == dp.last!)
        }}
    }
    @Test func largeSparseChange() throws {
        let old = (0..<20_000).map { "line \($0)\n" }.joined()
        let new = old.replacingOccurrences(of: "line 15000\n", with: "changed 15000\n")
        let diff = try parseDiffFromFile(.init(name: "f", contents: old), .init(name: "f", contents: new))
        #expect(diff.hunks.count == 1); #expect(diff.additions == 1); #expect(diff.deletions == 1)
        #expect(diff.hunks[0].additionStart == 14_997)
        #expect(diff.splitLineCount == 20_000)
        #expect(diff.additionLines.joined() == new)
    }
    @Test func insertDeleteAndRename() throws {
        let added = try parseDiffFromFile(nil, .init(name: "f", contents: "a\nb\n"))
        #expect(added.type == .new); #expect(added.hunks[0].deletionStart == 0); #expect(added.additions == 2)
        let removed = try parseDiffFromFile(.init(name: "f", contents: "a"), nil)
        #expect(removed.type == .deleted); #expect(removed.hunks[0].noEOFCRDeletions)
        let rename = try parseDiffFromFile(.init(name: "old", contents: "a"), .init(name: "new", contents: "a"))
        #expect(rename.type == .renamePure); #expect(rename.prevName == "old"); #expect(rename.hunks.isEmpty)
        #expect(throws: DiffError.missingFiles) { try parseDiffFromFile(nil, nil) }
    }
    @Test func contextZeroAndEOFDifference() throws {
        let diff = try parseDiffFromFile(.init(name: "f", contents: "a\nb\n"), .init(name: "f", contents: "a\nb"), options: .init(context: 0))
        #expect(diff.hunks[0].additionStart == 2)
        #expect(diff.hunks[0].additionCount == 1)
        #expect(diff.hunks[0].noEOFCRAdditions)
        #expect(!diff.hunks[0].noEOFCRDeletions)
    }
}
@Suite struct RenderPlanTests {
    @Test func splitUnifiedAndExpansion() throws {
        let old = (0..<1000).map { "\($0)\n" }.joined()
        let diff = try parseDiffFromFile(.init(name: "f", contents: old), .init(name: "f", contents: old.replacingOccurrences(of: "500\n", with: "new\nextra\n")))
        var options = DiffRenderOptions()
        let split = DiffRenderPlan(diff: diff, options: options)
        #expect(split.rows.count == 12)
        options.diffStyle = .unified
        #expect(DiffRenderPlan(diff: diff, options: options).rows.count == 13)
        options.expandUnchanged = true
        let full = DiffRenderPlan(diff: diff, options: options)
        #expect(full.rows.count == 1002)
        let bottom = full.visibleRange(y: 20_000, height: 600, lineHeight: 22)
        #expect(bottom.count <= 45); #expect(bottom.lowerBound > 800)
        #expect(full.visibleRange(y: 1e9, height: 600, lineHeight: 22).isEmpty)
    }
    @Test func utf16InlineRanges() {
        let spans = inlineDiff("😀 hello", "😀 world", type: .word)
        #expect(spans.deletions == [.init(NSRange(location: 3, length: 5))])
        #expect(spans.additions == [.init(NSRange(location: 3, length: 5))])
    }
}

@Suite struct ResolutionParityTests {
    struct Fixture: Decodable { var name: String; var input: FileDiffMetadata; var action: String; var expected: FileDiffMetadata }
    @Test func upstreamHunkResolution() throws {
        let url = fixtureURL("resolution-oracle")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let resolution: DiffResolution = fixture.action == "accept" ? .additions : fixture.action == "reject" ? .deletions : .both
            let actual = try diffAcceptRejectHunk(fixture.input, hunkIndex: 0, resolution: resolution)
            #expect(actual == fixture.expected, "Resolution mismatch: \(fixture.name)")
        }
    }
}

@Suite struct StreamingTests {
    @Test func incompleteLinesAreRecalledAndCommentsContinue() async throws {
        let tokenizer = ShikiStreamTokenizer(language: "typescript")
        var all: [String] = []
        let chunks = ["/* hel", "lo\nwor", "ld */\nconst mes", "sage = '👋';\n"]
        var unstable: [String] = []
        for chunk in chunks {
            let update = try await tokenizer.enqueue(chunk)
            #expect(update.recall == unstable.count)
            all += update.stable.map(\.content); unstable = update.unstable.map(\.content)
        }
        all += await tokenizer.close().map(\.content)
        #expect(all.joined() == chunks.joined())
        await tokenizer.clear()
        #expect(await tokenizer.tokensStable.isEmpty)
        #expect(await tokenizer.tokensUnstable.isEmpty)
    }
    @Test func wordAltJoinsSingleCharacterGaps() {
        let plain = inlineDiff("old one", "new two", type: .word)
        let joined = inlineDiff("old one", "new two", type: .wordAlt)
        #expect(plain.deletions.count == 2)
        #expect(joined.deletions.count == 1)
        #expect(joined.deletions.first?.range == NSRange(location: 0, length: 7))
    }
}

@Suite struct FileDiffParityTests {
    struct Fixture: Decodable { var oldFile: FileContents; var newFile: FileContents; var context: Int; var expected: FileDiffMetadata }
    @Test func pinnedJsDiffFilePairs() throws {
        let url = fixtureURL("diff-oracle")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        var mismatches: [Int] = []
        for (i, fixture) in fixtures.enumerated() {
            let actual = try parseDiffFromFile(fixture.oldFile, fixture.newFile, options: .init(context: fixture.context))
            if actual != fixture.expected {
                if mismatches.isEmpty {
                    try JSONEncoder().encode(actual).write(to: URL(fileURLWithPath: "/tmp/swift-diffs-actual.json"))
                    try JSONEncoder().encode(fixture.expected).write(to: URL(fileURLWithPath: "/tmp/swift-diffs-expected.json"))
                }
                mismatches.append(i)
            }
        }
        #expect(mismatches.isEmpty, "File pair oracle mismatches: \(mismatches)")
    }
}

@Suite struct SourceEncodingTests {
    @Test func canonicallyEquivalentUnicodeIsStillAChange() throws {
        let diff = try parseDiffFromFile(.init(name: "f", contents: "cafe\u{301}\n"), .init(name: "f", contents: "café\n"))
        #expect(diff.additions == 1); #expect(diff.deletions == 1)
    }
    @Test func CRLF() throws {
        let diff = try parseDiffFromFile(.init(name: "f", contents: "a\r\n"), .init(name: "f", contents: "a\n"))
        #expect(!diff.hunks[0].noEOFCRDeletions)
        #expect(!diff.hunks[0].noEOFCRAdditions)
    }
}

@Suite struct FileStreamTests {
    @Test func closingConcurrentStreamFreezesItsSnapshot() async throws {
        for _ in 0..<20 {
            let stream = FileStream(name: "f.txt", language: "text")
            let closed = await withTaskGroup(of: Void.self) { group in
                for index in 0..<30 { group.addTask { _ = try? await stream.append("line \(index)\n") } }
                await Task.yield()
                let result = await stream.close()
                await group.waitForAll()
                return result
            }
            let final = await stream.close()
            #expect(final.diff == closed.diff)
            #expect(final.newTokens == closed.newTokens)
            await #expect(throws: DiffError.self) { try await stream.append("late") }
        }
    }

    @Test func concurrentAppendsProduceDistinctCompletePrefixes() async throws {
        let stream = FileStream(name: "f.txt", language: "text")
        let snapshots = try await withThrowingTaskGroup(of: HighlightedDiff.self) { group in
            for index in 0..<100 { group.addTask { try await stream.append("line \(index)\n") } }
            var result: [HighlightedDiff] = []
            for try await snapshot in group { result.append(snapshot) }
            return result.sorted { $0.diff.additionLines.count < $1.diff.additionLines.count }
        }
        #expect(snapshots.map { $0.diff.additionLines.count } == Array(1...100))
        let final = await stream.close()
        #expect(Set(final.diff.additionLines) == Set((0..<100).map { "line \($0)\n" }))
        for snapshot in snapshots {
            #expect(Array(final.diff.additionLines.prefix(snapshot.diff.additionLines.count)) == snapshot.diff.additionLines)
            #expect(snapshot.newTokens.map { $0.map(\.content).joined() } == snapshot.diff.additionLines.map(cleanLastNewline))
        }
        await #expect(throws: DiffError.self) { try await stream.append("late\n") }
    }

    @Test func streamingSnapshotsRetainIdentityAndReconstructSource() async throws {
        let stream = FileStream(name: "f.swift", theme: "pierre-dark")
        var source = "", previous: HighlightedDiff?
        for chunk in ["let gr", "eeting = \"👋\"\n", "/* start\n", "end */\n", "final"] {
            source += chunk
            let snapshot = try await stream.append(chunk)
            #expect(snapshot.diff.additionLines.joined() == source)
            #expect(snapshot.newTokens.map { $0.map(\.content).joined() } == snapshot.diff.additionLines.map(cleanLastNewline))
            if let previous { #expect(snapshot.sourceID == previous.sourceID); #expect(snapshot.id != previous.id) }
            previous = snapshot
        }
        let final = await stream.close(); #expect(final.diff.additionLines.joined() == source)
    }
}

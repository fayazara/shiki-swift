import XCTest
@testable import ShikiCore

final class OnigurumaTests: XCTestCase {
    func testConcurrentScannerCreationIsSafe() async throws {
        let participantCount = 64
        let startGate = ConcurrentStartGate(participantCount: participantCount)

        try await withThrowingTaskGroup(of: OnigCaptureIndex.self) { group in
            for _ in 0..<participantCount {
                group.addTask {
                    await startGate.arriveAndWait()
                    let scanner = try OnigScanner(patterns: [#"(hello)"#])
                    let match = try XCTUnwrap(
                        scanner.findNextMatchSync("hello", startPosition: 0)
                    )
                    return try XCTUnwrap(match.captureIndices.first)
                }
            }

            for try await capture in group {
                XCTAssertEqual(capture, OnigCaptureIndex(start: 0, end: 5))
            }
        }
    }

    func testFindsEarliestPatternAndUsesPatternOrderForTies() throws {
        let scanner = try OnigScanner(patterns: ["a.", "b", "a"])

        let first = try XCTUnwrap(scanner.findNextMatchSync("zab", startPosition: 0))
        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(first.captureIndices[0], OnigCaptureIndex(start: 1, end: 3))

        let tie = try XCTUnwrap(scanner.findNextMatchSync("ab", startPosition: 0))
        XCTAssertEqual(tie.index, 0)
    }

    func testReturnsCaptureGroups() throws {
        let scanner = try OnigScanner(patterns: [#"(?<=foo)(b(ar))"#])
        let match = try XCTUnwrap(scanner.findNextMatchSync("foobar", startPosition: 0))

        XCTAssertEqual(match.index, 0)
        XCTAssertEqual(
            match.captureIndices,
            [
                OnigCaptureIndex(start: 3, end: 6),
                OnigCaptureIndex(start: 3, end: 6),
                OnigCaptureIndex(start: 4, end: 6),
            ]
        )
    }

    func testReturnsMoreThanOneThousandCaptureGroups() throws {
        let groupCount = 1_001
        let scanner = try OnigScanner(
            patterns: [String(repeating: "(a)", count: groupCount)]
        )
        let match = try XCTUnwrap(
            scanner.findNextMatchSync(
                String(repeating: "a", count: groupCount),
                startPosition: 0
            )
        )

        XCTAssertEqual(match.captureIndices.count, groupCount + 1)
        XCTAssertEqual(
            match.captureIndices[0],
            OnigCaptureIndex(start: 0, end: groupCount)
        )
        XCTAssertEqual(
            match.captureIndices[1],
            OnigCaptureIndex(start: 0, end: 1)
        )
        XCTAssertEqual(
            match.captureIndices[1_000],
            OnigCaptureIndex(start: 999, end: 1_000)
        )
        XCTAssertEqual(
            match.captureIndices[1_001],
            OnigCaptureIndex(start: 1_000, end: 1_001)
        )
    }

    func testReportsUTF16OffsetsLikeShiki() throws {
        let scanner = try OnigScanner(patterns: [#"(x)"#])
        let match = try XCTUnwrap(scanner.findNextMatchSync("🙂x", startPosition: 0))

        XCTAssertEqual(match.captureIndices[0], OnigCaptureIndex(start: 2, end: 3))
        XCTAssertEqual(match.captureIndices[1], OnigCaptureIndex(start: 2, end: 3))
    }

    func testConvertsOffsetsInsideNonBMPScalarLikeVSCodeBridge() {
        let value = OnigString("a🙂b")

        XCTAssertEqual(value.utf16Length, 4)
        XCTAssertEqual(value.utf8Length, 6)
        XCTAssertEqual(value.convertUTF16OffsetToUTF8(1), 1)
        XCTAssertEqual(value.convertUTF16OffsetToUTF8(2), 1)
        XCTAssertEqual(value.convertUTF16OffsetToUTF8(3), 5)
        XCTAssertEqual(value.convertUTF8OffsetToUTF16(4), 1)
        XCTAssertEqual(value.convertUTF8OffsetToUTF16(5), 3)
    }

    func testSupportsGAnchorAtRequestedPosition() throws {
        let scanner = try OnigScanner(patterns: [#"\Gbar"#])

        XCTAssertNil(try scanner.findNextMatchSync("foobar", startPosition: 0))
        let match = try XCTUnwrap(scanner.findNextMatchSync("foobar", startPosition: 3))
        XCTAssertEqual(match.captureIndices[0], OnigCaptureIndex(start: 3, end: 6))
    }

    func testRejectsInvalidOnigurumaPattern() {
        XCTAssertThrowsError(try OnigScanner(patterns: ["("])) { error in
            guard case let OnigurumaError.invalidPattern(pattern, message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(pattern, "(")
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testUsesPinnedOnigurumaVersion() {
        XCTAssertEqual(OnigScanner.version, "6.9.8")
    }
}

private actor ConcurrentStartGate {
    private let participantCount: Int
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arriveAndWait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            guard continuations.count == participantCount else { return }

            let ready = continuations
            continuations.removeAll(keepingCapacity: false)
            ready.forEach { $0.resume() }
        }
    }
}

extension OnigurumaTests {
    func testLongLineCacheMatchesFreshSearchesAcrossPositionsOptionsAndInputs() throws {
        let patterns = [#"\Gx"#, #"(tail)"#, #"\Astart"#, #"(missing)"#, #"(x)?(tail)"#]
        let scanner = try OnigScanner(patterns: patterns)
        let inputs = [
            OnigString("start" + String(repeating: "x", count: 1200) + "tail"),
            OnigString("start" + String(repeating: "y", count: 1200) + "tail"),
        ]
        for input in [inputs[0], inputs[1], inputs[0]] {
            for options: OnigFindOptions in [[], .notBeginPosition, .notBeginString, []] {
                for position in [0, 5, 500, 1205, 1206, 5, 1209] {
                    let cold = try OnigScanner(patterns: patterns)
                    XCTAssertEqual(
                        try scanner.findNextMatchSync(input, startPosition: position, options: options),
                        try cold.findNextMatchSync(input, startPosition: position, options: options)
                    )
                }
            }
        }
    }

    func testRegSetAndLongLinePathsPreserveTiesAndUnmatchedCaptures() throws {
        for padding in [10, 999, 1000, 1200] {
            let scanner = try OnigScanner(patterns: [#"(z)?(a)"#, "a"])
            let input = OnigString(String(repeating: "x", count: padding) + "a")
            for position in [0, padding / 2, padding] {
                let match = try XCTUnwrap(scanner.findNextMatchSync(input, startPosition: position))
                XCTAssertEqual(match.index, 0)
                XCTAssertEqual(match.captureIndices[0], .init(start: padding, end: padding + 1))
                XCTAssertEqual(match.captureIndices[1].start, Int(UInt32.max))
            }
        }
    }

    func testSharedScannerSerializesReusableBuffers() async throws {
        let scanner = try OnigScanner(patterns: [#"(🙂)([a-z]+)"#])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let match = try XCTUnwrap(scanner.findNextMatchSync("🙂hello", startPosition: 0))
                    XCTAssertEqual(match.captureIndices, [
                        .init(start: 0, end: 7), .init(start: 0, end: 2), .init(start: 2, end: 7),
                    ])
                }
            }
            try await group.waitForAll()
        }
    }
}

import XCTest
@testable import ShikiCore

final class ShikiLineSplittingTests: XCTestCase {
    func testEmptyAndSingleLineInputs() {
        XCTAssertEqual(splitLines(""), [.init(content: "", offset: 0)])
        XCTAssertEqual(
            splitLines("hello world"),
            [.init(content: "hello world", offset: 0)]
        )
    }

    func testLFAndCRLFAreSplitAndLoneCRIsPreserved() {
        let code = "a\rb\r\nc\nd"

        XCTAssertEqual(
            splitLines(code),
            [
                .init(content: "a\rb", offset: 0),
                .init(content: "c", offset: 5),
                .init(content: "d", offset: 7),
            ]
        )
        XCTAssertEqual(
            splitLines(code, preserveEnding: true),
            [
                .init(content: "a\rb\r\n", offset: 0),
                .init(content: "c\n", offset: 5),
                .init(content: "d", offset: 7),
            ]
        )
    }

    func testTrailingLineEndingProducesFinalEmptyLine() {
        XCTAssertEqual(
            splitLines("first\n"),
            [
                .init(content: "first", offset: 0),
                .init(content: "", offset: 6),
            ]
        )
        XCTAssertEqual(
            splitLines("\r\n", preserveEnding: true),
            [
                .init(content: "\r\n", offset: 0),
                .init(content: "", offset: 2),
            ]
        )
        XCTAssertEqual(
            splitLines("\n\n"),
            [
                .init(content: "", offset: 0),
                .init(content: "", offset: 1),
                .init(content: "", offset: 2),
            ]
        )
    }

    func testOffsetsUseUTF16ForEmojiAndCombiningMarks() {
        let combining = "e\u{301}"
        let code = "😀\n\(combining)\r\nZ\n"

        XCTAssertEqual(code.count, 6, "Swift Character count is intentionally not the offset unit")
        XCTAssertEqual(code.utf16.count, 9)
        XCTAssertEqual(
            splitLines(code),
            [
                .init(content: "😀", offset: 0),
                .init(content: combining, offset: 3),
                .init(content: "Z", offset: 7),
                .init(content: "", offset: 9),
            ]
        )

        let preserved = splitLines(code, preserveEnding: true)
        XCTAssertEqual(
            preserved,
            [
                .init(content: "😀\n", offset: 0),
                .init(content: "\(combining)\r\n", offset: 3),
                .init(content: "Z\n", offset: 7),
                .init(content: "", offset: 9),
            ]
        )
        XCTAssertEqual(preserved.map(\.content).joined(), code)
    }
}

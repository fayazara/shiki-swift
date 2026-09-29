import Testing
@testable import ShikiDiffs

struct PatchUtilityTests {
    @Test func patchPrefixesPreserveUTF16Content() throws {
        for (prefix, kind) in [("+", ParsedLine.Kind.addition), ("-", .deletion), (" ", .context), ("\\", .metadata)] {
            #expect(parseLineType(prefix)?.line == "\n")
            #expect(parseLineType(prefix)?.type == kind)
            for body in ["abc\r\n", "\u{301}x\n", "😀", "\r", "\n"] {
                #expect(parseLineType(prefix + body)?.line == body)
            }
        }
        for invalid in ["", "abc", "＠", "\n"] { #expect(parseLineType(invalid) == nil) }
        let patch = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-\u{301}old\n+\u{301}new\n"
        let files = try parsePatchFiles(patch)
        #expect(files.first?.files.first?.additionLines == ["\u{301}new\n"])
        let second = "--- a/g\n+++ b/g\n@@ -1 +1 @@\n-x\n+y\n"
        let multiple = try parsePatchFiles(patch + second, throwOnError: true)
        #expect(multiple.first?.files.count == 2)
        #expect(multiple.first?.files.last?.additionLines == ["y\n"])

    }
    @Test func newlineHelpersMatchCodeUnitRules() {
        let alphabet = ["x", "\r", "\n", "\u{301}"]
        var strings = [""]
        for _ in 0..<5 { strings += strings.flatMap { prefix in alphabet.map { prefix + $0 } } }
        for value in Set(strings) {
            var units = Array(value.utf16)
            if units.last == 10 { units.removeLast(); if units.last == 13 { units.removeLast() } }
            #expect(cleanLastNewline(value) == String(decoding: units, as: UTF16.self))
            let raw = Array(value.utf16)
            let crlf = zip(raw, raw.dropFirst()).contains { $0 == 13 && $1 == 10 }
            let expected: LineEnding = crlf ? .CRLF : raw.contains(13) ? .CR : raw.contains(10) ? .LF : .none
            #expect(getLineEndingType(value) == expected)
        }
    }
    @Test func lastHunkExtentUsesZeroCountBoundaries() {
        #expect(getTotalLineCountFromHunks([]) == 0)
        var first = Hunk(); first.additionStart = 100; first.additionCount = 5
        var last = Hunk(); last.additionStart = 4; last.additionCount = 0
        last.deletionStart = 2; last.deletionCount = 2
        #expect(getTotalLineCountFromHunks([first, last]) == 4)
        last.deletionStart = 7; last.deletionCount = 3
        #expect(getTotalLineCountFromHunks([last]) == 9)
    }
}

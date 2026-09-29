import Testing
@testable import ShikiDiffs

@Suite struct FileEqualityTests {
    @Test func matchesUpstreamFieldsAndOptionalValues() {
        let file = FileContents(name: "f", contents: "text", lang: "text", header: "First", cacheKey: "key")
        #expect(areFilesEqual(nil, nil))
        #expect(!areFilesEqual(file, nil))
        var other = file; other.header = "Second"
        #expect(areFilesEqual(file, other))
        other.cacheKey = "new"; #expect(!areFilesEqual(file, other))
        other = file; other.contents += "\n"; #expect(!areFilesEqual(file, other))
        other = file; other.name = "g"; #expect(!areFilesEqual(file, other))
        other = file; other.lang = nil; #expect(!areFilesEqual(file, other))
    }
    @Test func doesNotCollapseCanonicalUnicodeDifferences() {
        let composed = "é", decomposed = "e\u{301}"
        #expect(composed == decomposed)
        #expect(!areFilesEqual(.init(name: "f", contents: composed), .init(name: "f", contents: decomposed)))
        #expect(!areFilesEqual(.init(name: composed, contents: ""), .init(name: decomposed, contents: "")))
        #expect(!areFilesEqual(.init(name: "f", contents: "", lang: composed), .init(name: "f", contents: "", lang: decomposed)))
        #expect(!areFilesEqual(.init(name: "f", contents: "", cacheKey: composed), .init(name: "f", contents: "", cacheKey: decomposed)))
    }
}

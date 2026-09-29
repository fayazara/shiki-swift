import Testing
@testable import ShikiDiffs

@Suite struct FileAnnotationHelpersTests {
    @Test func fileLevelMeansExactlyZero() {
        #expect(!includesFileAnnotations(nil))
        #expect(!includesFileAnnotations([]))
        #expect(!includesFileAnnotations([.init(lineNumber: -1, text: "Negative"), .init(lineNumber: 1, text: "First line")]))
        #expect(includesFileAnnotations([.init(side: .deletions, lineNumber: 0, text: "File")]))
        #expect(getFileAnnotations([0: ["a", "b"], 1: ["c"]]) == ["a", "b"])
        #expect(getFileAnnotations([0: [String]()]) == nil)
        #expect(getFileAnnotations([1: ["a"]]) == nil)
    }
    @Test func onlyNonemptyTopRangeIncludesFileAnnotations() {
        for start in [-1, 0, 1, 100] {
            for total in [-1, 0, 1, 100] {
                #expect(shouldRenderFileAnnotations(.init(startingLine: start, totalLines: total, bufferBefore: 200, bufferAfter: 200)) == (start == 0 && total > 0))
            }
        }
    }
}

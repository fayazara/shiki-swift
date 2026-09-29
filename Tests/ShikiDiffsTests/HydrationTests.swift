import Foundation
import Testing
@testable import ShikiDiffs

struct HydrationTests {
    @Test func matchesUpstreamHydrationFixtures() throws {
        struct Fixture: Decodable {
            let name: String
            let input: FileDiffMetadata
            let oldFile: FileContents?
            let newFile: FileContents
            let expected: FileDiffMetadata?
            let error: String?
        }
        let url = try #require(fixtureURL("hydration-oracle"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        #expect(fixtures.count == 328)
        #expect(fixtures.filter { $0.error != nil }.count == 14)
        for fixture in fixtures {
            let files = LoadedDiffFiles(oldFile: fixture.oldFile, newFile: fixture.newFile)
            var merged = fixture.input
            if fixture.error != nil {
                #expect(throws: DiffError.self, Comment(rawValue: fixture.name)) { try hydratePartialDiff(fixture.input, files: files) }
                #expect(throws: DiffError.self, Comment(rawValue: fixture.name)) { try hydratePartialDiff(&merged, files: files) }
                #expect(merged == fixture.input)
            } else {
                let expected = try #require(fixture.expected)
                #expect(try hydratePartialDiff(fixture.input, files: files) == expected, Comment(rawValue: fixture.name))
                #expect(try hydratePartialDiff(&merged, files: files) == expected, Comment(rawValue: fixture.name))
                #expect(merged == expected, Comment(rawValue: fixture.name))
            }
        }
    }

    @Test func cloneAndMergePreserveIndependentValues() throws {
        let original = try #require(try processFile("--- f\n+++ f\n@@ -3 +3 @@\n-old\n+new\n", cacheKey: "patch", throwOnError: true))
        let files = LoadedDiffFiles(oldFile: .init(name: "f", contents: "a\nb\nold\nz\n"), newFile: .init(name: "f", contents: "a\nb\nnew\nz\n"))
        let clone = try hydratePartialDiff(original, files: files)
        var merged = original
        let returned = try hydratePartialDiff(&merged, files: files)
        #expect(merged == clone)
        #expect(returned == merged)
        #expect(original.isPartial)
        #expect(merged.splitLineCount == 4)
        #expect(merged.cacheKey == "patch:hydrated")
        merged.hunks[0].hunkContent[0].additionLineIndex = 100
        #expect(clone.hunks[0].hunkContent[0].additionLineIndex == 2)
    }

    @Test func failedMergeIsAtomic() throws {
        let original = try #require(try processFile("--- f\n+++ f\n@@ -3 +3 @@\n-old\n+new\n", throwOnError: true))
        var merged = original
        let shortFiles = LoadedDiffFiles(oldFile: .init(name: "f", contents: "old\n"), newFile: .init(name: "f", contents: "new\n"))
        #expect(throws: DiffError.self) { try hydratePartialDiff(&merged, files: shortFiles) }
        #expect(merged == original)
        let missingOld = LoadedDiffFiles(oldFile: nil, newFile: shortFiles.newFile)
        #expect(throws: DiffError.self) { try hydratePartialDiff(&merged, files: missingOld) }
        #expect(merged == original)
    }

    @Test func pureRenamePreservesGeometryAndUsesNewFileKey() throws {
        var original = FileDiffMetadata(name: "renamed.txt")
        original.type = .renamePure
        original.prevName = "old.txt"
        original.isPartial = true
        original.splitLineCount = 17
        original.unifiedLineCount = 19
        let files = LoadedDiffFiles(oldFile: nil, newFile: .init(name: "renamed.txt", contents: "a\r\nb", cacheKey: "new"))
        let result = try hydratePartialDiff(original, files: files)
        #expect(result.splitLineCount == 17)
        #expect(result.unifiedLineCount == 19)
        #expect(result.deletionLines == ["a\r\n", "b"])
        #expect(result.additionLines == result.deletionLines)
        #expect(result.cacheKey == "new")
        #expect(!result.isPartial)
    }
}

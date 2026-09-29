import Testing
@testable import ShikiDiffs

struct DiffTargetTests {
    @Test func unkeyedTargetsUseIdentityIncludingAbsence() {
        let metadata = FileDiffMetadata(name: "f.txt")
        let target = DiffTarget(metadata)
        #expect(areDiffTargetsEqual(target, target))
        #expect(!areDiffTargetsEqual(target, DiffTarget(metadata)))
        #expect(areDiffTargetsEqual(nil, nil))
        #expect(!areDiffTargetsEqual(target, nil))
        #expect(!areDiffTargetsEqual(nil, target))
    }
    @Test func keysOverrideIdentityAndContentWithoutUnicodeNormalization() {
        var a = FileDiffMetadata(name: "a.txt"); a.cacheKey = ""
        var b = FileDiffMetadata(name: "b.txt"); b.cacheKey = ""
        #expect(areDiffTargetsEqual(DiffTarget(a), DiffTarget(b)))
        b.cacheKey = nil
        #expect(!areDiffTargetsEqual(DiffTarget(a), DiffTarget(b)))
        #expect(!areDiffTargetsEqual(DiffTarget(a), nil))
        a.cacheKey = "é"; b.cacheKey = "e\u{301}"
        #expect(!areDiffTargetsEqual(DiffTarget(a), DiffTarget(b)))
        b.cacheKey = "é"
        #expect(areDiffTargetsEqual(DiffTarget(a), DiffTarget(b)))
    }
}

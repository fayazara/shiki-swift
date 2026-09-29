import Testing
@testable import ShikiDiffs

@Suite struct AnnotationEqualityTests {
    @Test func upstreamFieldsExcludeNativePresentation() {
        let metadata = LineAnnotationMetadata(["author": "Ada"])
        let a = LineAnnotation(id: "a", lineNumber: 1, text: "First", metadata: metadata)
        var b = LineAnnotation(id: "b", lineNumber: 1, text: "Second", metadata: metadata)
        #expect(areLineAnnotationsEqual(a, b))
        #expect(areDiffLineAnnotationsEqual(a, b))
        b.side = .deletions
        #expect(areLineAnnotationsEqual(a, b))
        #expect(!areDiffLineAnnotationsEqual(a, b))
        b.lineNumber = 2
        #expect(!areLineAnnotationsEqual(a, b))
        b.lineNumber = 1
        b.metadata = .init(["author": "Ada"])
        #expect(!areLineAnnotationsEqual(a, b))
    }
    @Test func primitiveStrictEquality() {
        func equal(_ a: LineAnnotationMetadata.Primitive, _ b: LineAnnotationMetadata.Primitive) -> Bool {
            areLineAnnotationsEqual(LineAnnotation(lineNumber: 1, text: "", metadata: .init(primitive: a)),
                                    .init(lineNumber: 1, text: "", metadata: .init(primitive: b)))
        }
        #expect(equal(.null, .null))
        #expect(equal(.boolean(true), .boolean(true)))
        #expect(!equal(.boolean(true), .number(1)))
        #expect(equal(.number(-0.0), .number(0)))
        #expect(!equal(.number(.nan), .number(.nan)))
        let nan = LineAnnotationMetadata(primitive: .number(.nan))
        #expect(!(nan == nan))
        #expect(equal(.string("hello"), .string("hello")))
        #expect(!equal(.string("é"), .string("e\u{301}")))
        let absent = LineAnnotation(lineNumber: 1, text: "")
        #expect(areLineAnnotationsEqual(absent, absent))
        #expect(!areLineAnnotationsEqual(absent, .init(lineNumber: 1, text: "", metadata: .init(primitive: .null))))
        #expect(LineAnnotationMetadata("hello") != LineAnnotationMetadata(primitive: .string("hello")))
    }
}

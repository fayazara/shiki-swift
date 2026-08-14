import XCTest
@testable import ShikiCore

final class TextMateScopeAttributesTests: XCTestCase {
    func testBasicScopeProviderMatchesLanguagesAndStandardTokenTypes() {
        let provider = BasicScopeAttributesProvider(
            initialLanguageID: 1,
            embeddedLanguages: [
                "source.js": 2,
                "source.js.embedded": 3,
                "text.html": 4,
            ]
        )

        XCTAssertEqual(provider.getDefaultAttributes(), .init(1, .notSet))
        XCTAssertEqual(provider.getBasicScopeAttributes(nil), .init(0, .other))
        XCTAssertEqual(
            provider.getBasicScopeAttributes("source.js.embedded.html"),
            .init(3, .notSet)
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("source.js.comment.line"),
            .init(2, .comment)
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("string.quoted.double"),
            .init(0, .string)
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("constant.regex.escape"),
            .init(0, .regex)
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("meta.embedded.block"),
            .init(0, .other)
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("entity.mycomment"),
            .init(0, .notSet)
        )
    }

    func testStandardTokenMatcherUsesLeftmostWordBoundaryMatch() {
        let provider = BasicScopeAttributesProvider(initialLanguageID: 1)

        XCTAssertEqual(
            provider.getBasicScopeAttributes("source.string.comment").tokenType,
            .string
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("source.comment-string").tokenType,
            .comment
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("source._comment").tokenType,
            .notSet,
            "An underscore is a JavaScript regular-expression word character"
        )
    }

    func testMetadataMergeRetainsUnsetFieldsAndOverwritesConcreteFields() {
        let existing = EncodedTokenMetadata.set(
            0,
            languageID: 1,
            tokenType: .string,
            containsBalancedBrackets: true,
            fontStyle: .italic,
            foreground: 7,
            background: 8
        )

        let unchanged = AttributedScopeStack.mergeAttributes(
            existing,
            BasicScopeAttributes(0, .notSet),
            nil
        )
        XCTAssertEqual(unchanged, existing)

        let merged = AttributedScopeStack.mergeAttributes(
            existing,
            BasicScopeAttributes(9, .comment),
            StyleAttributes(fontStyle: .bold, foregroundID: 10, backgroundID: 11)
        )
        XCTAssertEqual(EncodedTokenMetadata.getLanguageID(merged), 9)
        XCTAssertEqual(EncodedTokenMetadata.getTokenType(merged), .comment)
        XCTAssertTrue(EncodedTokenMetadata.containsBalancedBrackets(merged))
        XCTAssertEqual(EncodedTokenMetadata.getFontStyle(merged), .bold)
        XCTAssertEqual(EncodedTokenMetadata.getForeground(merged), 10)
        XCTAssertEqual(EncodedTokenMetadata.getBackground(merged), 11)
        XCTAssertEqual(StackElementMetadata.getLanguageID(merged), 9)
    }

    func testAttributedScopePushMergesMetadataAndPreservesScopePath() {
        let provider = MockMetadataProvider(
            languages: ["source.swift": 1, "meta.embedded": 7],
            styles: [
                "source.swift": .init(fontStyle: .italic, foregroundID: 2, backgroundID: 3),
                "comment.line": .init(fontStyle: .bold, foregroundID: 4, backgroundID: 0),
            ]
        )
        let root = AttributedScopeStack.createRootAndLookUpScopeName(
            "source.swift",
            0,
            provider
        )
        let pushed = root.pushAttributed("comment.line meta.embedded", provider)

        XCTAssertEqual(pushed.getScopeNames(), [
            "source.swift",
            "comment.line",
            "meta.embedded",
        ])
        XCTAssertEqual(pushed.description, "source.swift comment.line meta.embedded")
        XCTAssertEqual(EncodedTokenMetadata.getLanguageID(root.tokenAttributes), 1)
        XCTAssertEqual(EncodedTokenMetadata.getFontStyle(root.tokenAttributes), .italic)
        XCTAssertEqual(EncodedTokenMetadata.getTokenType(pushed.parent!.tokenAttributes), .comment)
        XCTAssertEqual(EncodedTokenMetadata.getFontStyle(pushed.parent!.tokenAttributes), .bold)
        XCTAssertEqual(EncodedTokenMetadata.getLanguageID(pushed.tokenAttributes), 7)
        XCTAssertEqual(EncodedTokenMetadata.getTokenType(pushed.tokenAttributes), .other)
        XCTAssertTrue(root.pushAttributed(nil, provider) === root)
    }

    func testAttributedScopeEqualityAndExtensionFrames() throws {
        let provider = MockMetadataProvider()
        let base = AttributedScopeStack.createRoot("source.swift", 1)
        let stack = base.pushAttributed("meta.function entity.name", provider)

        let equivalentBase = AttributedScopeStack.createRoot("source.swift", 1)
        let equivalent = equivalentBase.pushAttributed(
            "meta.function entity.name",
            provider
        )
        XCTAssertEqual(stack, equivalent)
        XCTAssertNotEqual(stack, AttributedScopeStack.createRoot("entity.name", 1))

        let frames = try XCTUnwrap(stack.getExtensionIfDefined(base))
        XCTAssertEqual(
            frames.map(\.scopeNames),
            [["meta.function"], ["entity.name"]]
        )
        let rebuilt = try XCTUnwrap(
            AttributedScopeStack.fromExtension(base, frames)
        )
        XCTAssertEqual(rebuilt, stack)
        XCTAssertNil(
            stack.getExtensionIfDefined(equivalentBase),
            "Extension ancestry is identity-based, like the upstream linked stack"
        )
    }
}

private final class MockMetadataProvider: AttributedScopeStackMetadataProvider {
    private let basic: BasicScopeAttributesProvider
    private let styles: [ScopeName: StyleAttributes]

    init(
        languages: [ScopeName: Int] = [:],
        styles: [ScopeName: StyleAttributes] = [:]
    ) {
        basic = BasicScopeAttributesProvider(
            initialLanguageID: 0,
            embeddedLanguages: languages
        )
        self.styles = styles
    }

    func getMetadataForScope(_ scopeName: ScopeName?) -> BasicScopeAttributes {
        basic.getBasicScopeAttributes(scopeName)
    }

    func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes? {
        styles[scopePath.scopeName]
    }
}

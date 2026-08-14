import XCTest
@testable import ShikiCore

final class TextMateBasicScopeAttributesTests: XCTestCase {
    func testDefaultAndNullScopeMetadataMatchUpstreamSentinels() {
        let provider = BasicScopeAttributesProvider(
            initialLanguageID: 17,
            embeddedLanguages: nil
        )

        XCTAssertEqual(
            provider.getDefaultAttributes(),
            BasicScopeAttributes(17, .notSet)
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes(nil),
            BasicScopeAttributes(0, .other)
        )
    }

    func testEmbeddedLanguageChoosesMostSpecificScopePrefix() {
        let provider = BasicScopeAttributesProvider(
            initialLanguageID: 1,
            embeddedLanguages: [
                "source.js": 2,
                "source.js.jquery": 3,
            ]
        )

        XCTAssertEqual(
            provider.getBasicScopeAttributes("source.js.jquery.embedded").languageID,
            3
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("source.js.react").languageID,
            2
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("source.json").languageID,
            0
        )
    }

    func testStandardTokenTypesUseTextMateWordBoundaries() {
        let provider = BasicScopeAttributesProvider(initialLanguageID: 1)

        XCTAssertEqual(
            provider.getBasicScopeAttributes("punctuation.comment.block").tokenType,
            .comment
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("string.quoted.swift").tokenType,
            .string
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("constant.regex.swift").tokenType,
            .regex
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("meta.embedded.block").tokenType,
            .other
        )
        XCTAssertEqual(
            provider.getBasicScopeAttributes("commentary.swift").tokenType,
            .notSet
        )
    }
}

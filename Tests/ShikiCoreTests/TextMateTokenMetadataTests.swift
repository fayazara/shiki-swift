import XCTest
@testable import ShikiCore

final class TextMateTokenMetadataTests: XCTestCase {
    func testPacksTheVscodeTextMateBitLayout() {
        let metadata = EncodedTokenMetadata.set(
            0,
            languageID: 1,
            tokenType: .regex,
            containsBalancedBrackets: false,
            fontStyle: [.underline, .bold],
            foreground: 101,
            background: 102
        )

        XCTAssertEqual(metadata, 0x6632_B301)
        XCTAssertEqual(EncodedTokenMetadata.getLanguageID(metadata), 1)
        XCTAssertEqual(EncodedTokenMetadata.getTokenType(metadata), .regex)
        XCTAssertFalse(EncodedTokenMetadata.containsBalancedBrackets(metadata))
        XCTAssertEqual(EncodedTokenMetadata.getFontStyle(metadata), [.underline, .bold])
        XCTAssertEqual(EncodedTokenMetadata.getForeground(metadata), 101)
        XCTAssertEqual(EncodedTokenMetadata.getBackground(metadata), 102)
        XCTAssertEqual(
            EncodedTokenMetadata.toBinaryStr(metadata),
            "01100110001100101011001100000001"
        )
    }

    func testSentinelsRetainFieldsWhileConcreteZeroValuesOverwrite() {
        let original = EncodedTokenMetadata.set(
            0,
            languageID: 7,
            tokenType: .string,
            containsBalancedBrackets: true,
            fontStyle: [.italic, .bold],
            foreground: 12,
            background: 34
        )

        let retained = EncodedTokenMetadata.set(original)
        XCTAssertEqual(retained, original)

        let overwritten = EncodedTokenMetadata.set(
            original,
            tokenType: .other,
            containsBalancedBrackets: false,
            fontStyle: .none
        )
        XCTAssertEqual(EncodedTokenMetadata.getTokenType(overwritten), .other)
        XCTAssertFalse(EncodedTokenMetadata.containsBalancedBrackets(overwritten))
        XCTAssertEqual(EncodedTokenMetadata.getFontStyle(overwritten), .none)
        XCTAssertEqual(EncodedTokenMetadata.getLanguageID(overwritten), 7)
        XCTAssertEqual(EncodedTokenMetadata.getForeground(overwritten), 12)
        XCTAssertEqual(EncodedTokenMetadata.getBackground(overwritten), 34)
    }

    func testSupportsEveryAvailableBit() {
        let metadata = EncodedTokenMetadata.set(
            0,
            languageID: 255,
            tokenType: .regex,
            containsBalancedBrackets: true,
            fontStyle: [.italic, .bold, .underline, .strikethrough],
            foreground: 511,
            background: 255
        )

        XCTAssertEqual(metadata, UInt32.max)
        XCTAssertEqual(EncodedTokenMetadata.getFontStyle(metadata).rawValue, 15)
    }

    func testFontStyleMatchesUpstreamStringsAndRawValues() {
        XCTAssertEqual(FontStyle.notSet.rawValue, -1)
        XCTAssertEqual(FontStyle.none.description, "none")
        XCTAssertEqual(
            FontStyle([.italic, .bold, .underline, .strikethrough]).description,
            "italic bold underline strikethrough"
        )
        XCTAssertEqual(toOptionalTokenType(.comment), .comment)
    }
}

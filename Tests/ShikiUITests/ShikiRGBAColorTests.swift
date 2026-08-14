#if canImport(SwiftUI)
import SwiftUI
#endif
import XCTest
@testable import ShikiUI

final class ShikiRGBAColorTests: XCTestCase {
    func testDecodesCSSHexLengths() {
        XCTAssertEqual(
            ShikiRGBAColor(hex: "#abc"),
            .init(red: 0xAA, green: 0xBB, blue: 0xCC)
        )
        XCTAssertEqual(
            ShikiRGBAColor(hex: "#abcd"),
            .init(red: 0xAA, green: 0xBB, blue: 0xCC, alpha: 0xDD)
        )
        XCTAssertEqual(
            ShikiRGBAColor(hex: "#A1b2C3"),
            .init(red: 0xA1, green: 0xB2, blue: 0xC3)
        )
        XCTAssertEqual(
            ShikiRGBAColor(hex: " #A1b2C380\n"),
            .init(red: 0xA1, green: 0xB2, blue: 0xC3, alpha: 0x80)
        )
    }

    func testRejectsMalformedHexWithoutTrapping() {
        for value in [
            "", "abc", "#12", "#12345", "#1234567", "#123456789",
            "#ggg", "#12x456", "##123456",
        ] {
            XCTAssertNil(ShikiRGBAColor(hex: value), "Expected \(value) to be rejected")
            XCTAssertNil(Color(shikiHex: value))
        }
    }

    #if canImport(SwiftUI)
    func testSwiftUIColorUsesSRGBComponentsAndAlpha() {
        let color = ShikiRGBAColor(red: 0x12, green: 0x34, blue: 0x56, alpha: 0x78)
        XCTAssertEqual(Color(shikiHex: "#12345678"), color.swiftUIColor)
    }
    #endif
}

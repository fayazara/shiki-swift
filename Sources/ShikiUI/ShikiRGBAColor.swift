import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// An sRGB color decoded from a CSS/VS Code hexadecimal color literal.
public struct ShikiRGBAColor: Codable, Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Decodes CSS `#RGB`, `#RGBA`, `#RRGGBB`, and `#RRGGBBAA` forms.
    public init?(hex: String) {
        let source = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.first == "#" else { return nil }

        let digits = Array(source.dropFirst().utf8)
        switch digits.count {
        case 3, 4:
            guard
                let red = Self.nibble(digits[0]),
                let green = Self.nibble(digits[1]),
                let blue = Self.nibble(digits[2])
            else { return nil }

            let alpha: UInt8
            if digits.count == 4 {
                guard let decodedAlpha = Self.nibble(digits[3]) else { return nil }
                alpha = decodedAlpha * 17
            } else {
                alpha = 255
            }

            self.init(
                red: red * 17,
                green: green * 17,
                blue: blue * 17,
                alpha: alpha
            )

        case 6, 8:
            guard
                let red = Self.byte(digits[0], digits[1]),
                let green = Self.byte(digits[2], digits[3]),
                let blue = Self.byte(digits[4], digits[5])
            else { return nil }

            let alpha: UInt8
            if digits.count == 8 {
                guard let decodedAlpha = Self.byte(digits[6], digits[7]) else {
                    return nil
                }
                alpha = decodedAlpha
            } else {
                alpha = 255
            }

            self.init(red: red, green: green, blue: blue, alpha: alpha)

        default:
            return nil
        }
    }

    #if canImport(SwiftUI)
    public var swiftUIColor: Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
    #endif

    private static func byte(_ high: UInt8, _ low: UInt8) -> UInt8? {
        guard let high = nibble(high), let low = nibble(low) else { return nil }
        return high * 16 + low
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            byte - 0x30
        case 0x41...0x46:
            byte - 0x41 + 10
        case 0x61...0x66:
            byte - 0x61 + 10
        default:
            nil
        }
    }
}

#if canImport(SwiftUI)
public extension Color {
    /// Creates an sRGB SwiftUI color from a CSS/VS Code hex literal.
    init?(shikiHex: String) {
        guard let color = ShikiRGBAColor(hex: shikiHex) else { return nil }
        self = color.swiftUIColor
    }
}
#endif

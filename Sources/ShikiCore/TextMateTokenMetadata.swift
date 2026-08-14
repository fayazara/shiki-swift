import Foundation

/// The four standard token classifications encoded by `vscode-textmate`.
public enum StandardTokenType: UInt32, Codable, CaseIterable, Sendable {
    case other = 0
    case comment = 1
    case string = 2
    case regex = 3
}

/// A standard token classification that can also represent "leave unchanged".
///
/// The raw values intentionally match `OptionalStandardTokenType` in
/// `@shikijs/vscode-textmate` 10.0.2.
public enum OptionalStandardTokenType: Int32, Codable, Sendable {
    case other = 0
    case comment = 1
    case string = 2
    case regex = 3
    case notSet = 8

    public init(_ tokenType: StandardTokenType) {
        switch tokenType {
        case .other: self = .other
        case .comment: self = .comment
        case .string: self = .string
        case .regex: self = .regex
        }
    }

    public var standardTokenType: StandardTokenType? {
        switch self {
        case .other: .other
        case .comment: .comment
        case .string: .string
        case .regex: .regex
        case .notSet: nil
        }
    }
}

/// Converts a concrete token classification to its optional representation.
public func toOptionalTokenType(_ tokenType: StandardTokenType) -> OptionalStandardTokenType {
    OptionalStandardTokenType(tokenType)
}

/// TextMate font-style bits.
///
/// `notSet` is a sentinel used while resolving themes. It must never be packed
/// into token metadata. All other values can be combined as an `OptionSet`.
public struct FontStyle: OptionSet, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let notSet = Self(rawValue: -1)
    public static let none: Self = []
    public static let italic = Self(rawValue: 1 << 0)
    public static let bold = Self(rawValue: 1 << 1)
    public static let underline = Self(rawValue: 1 << 2)
    public static let strikethrough = Self(rawValue: 1 << 3)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int32.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        if self == .notSet {
            return "not set"
        }

        var names: [String] = []
        if contains(.italic) { names.append("italic") }
        if contains(.bold) { names.append("bold") }
        if contains(.underline) { names.append("underline") }
        if contains(.strikethrough) { names.append("strikethrough") }
        return names.isEmpty ? "none" : names.joined(separator: " ")
    }
}

/// The unsigned 32-bit metadata word emitted by binary TextMate tokenization.
public typealias EncodedTokenAttributes = UInt32

/// Reads and updates the packed token metadata format used by
/// `@shikijs/vscode-textmate` 10.0.2.
///
/// The fields are laid out as follows, from least to most significant bit:
/// language ID (8), token type (2), balanced-bracket flag (1), font style (4),
/// foreground ID (9), and background ID (8). Keeping this as `UInt32` mirrors
/// JavaScript's final unsigned `>>> 0` conversion exactly.
public enum EncodedTokenMetadata {
    private static let languageIDMask: UInt32 = 0x0000_00FF
    private static let tokenTypeMask: UInt32 = 0x0000_0300
    private static let balancedBracketsMask: UInt32 = 0x0000_0400
    private static let fontStyleMask: UInt32 = 0x0000_7800
    private static let foregroundMask: UInt32 = 0x00FF_8000
    private static let backgroundMask: UInt32 = 0xFF00_0000

    private static let languageIDOffset: UInt32 = 0
    private static let tokenTypeOffset: UInt32 = 8
    private static let balancedBracketsOffset: UInt32 = 10
    private static let fontStyleOffset: UInt32 = 11
    private static let foregroundOffset: UInt32 = 15
    private static let backgroundOffset: UInt32 = 24

    public static func toBinaryStr(_ encodedTokenAttributes: EncodedTokenAttributes) -> String {
        let value = String(encodedTokenAttributes, radix: 2)
        return String(repeating: "0", count: 32 - value.count) + value
    }

    public static func toBinaryString(_ encodedTokenAttributes: EncodedTokenAttributes) -> String {
        toBinaryStr(encodedTokenAttributes)
    }

    public static func getLanguageID(_ encodedTokenAttributes: EncodedTokenAttributes) -> Int {
        Int((encodedTokenAttributes & languageIDMask) >> languageIDOffset)
    }

    /// Compatibility spelling matching the TypeScript API.
    public static func getLanguageId(_ encodedTokenAttributes: EncodedTokenAttributes) -> Int {
        getLanguageID(encodedTokenAttributes)
    }

    public static func getTokenType(_ encodedTokenAttributes: EncodedTokenAttributes) -> StandardTokenType {
        let value = (encodedTokenAttributes & tokenTypeMask) >> tokenTypeOffset
        return StandardTokenType(rawValue: value) ?? .other
    }

    public static func containsBalancedBrackets(_ encodedTokenAttributes: EncodedTokenAttributes) -> Bool {
        encodedTokenAttributes & balancedBracketsMask != 0
    }

    public static func getFontStyle(_ encodedTokenAttributes: EncodedTokenAttributes) -> FontStyle {
        let value = (encodedTokenAttributes & fontStyleMask) >> fontStyleOffset
        return FontStyle(rawValue: Int32(value))
    }

    public static func getForeground(_ encodedTokenAttributes: EncodedTokenAttributes) -> Int {
        Int((encodedTokenAttributes & foregroundMask) >> foregroundOffset)
    }

    public static func getBackground(_ encodedTokenAttributes: EncodedTokenAttributes) -> Int {
        Int((encodedTokenAttributes & backgroundMask) >> backgroundOffset)
    }

    /// Updates individual fields in an encoded metadata word.
    ///
    /// As in `vscode-textmate`, `0`, `.notSet`, or `nil` means that the
    /// corresponding existing field is retained.
    public static func set(
        _ encodedTokenAttributes: EncodedTokenAttributes,
        languageID: Int = 0,
        tokenType: OptionalStandardTokenType = .notSet,
        containsBalancedBrackets: Bool? = nil,
        fontStyle: FontStyle = .notSet,
        foreground: Int = 0,
        background: Int = 0
    ) -> EncodedTokenAttributes {
        var resolvedLanguageID = getLanguageID(encodedTokenAttributes)
        var resolvedTokenType = getTokenType(encodedTokenAttributes)
        var resolvedBalancedBrackets = self.containsBalancedBrackets(encodedTokenAttributes)
        var resolvedFontStyle = getFontStyle(encodedTokenAttributes)
        var resolvedForeground = getForeground(encodedTokenAttributes)
        var resolvedBackground = getBackground(encodedTokenAttributes)

        if languageID != 0 {
            resolvedLanguageID = languageID
        }
        if let concreteTokenType = tokenType.standardTokenType {
            resolvedTokenType = concreteTokenType
        }
        if let containsBalancedBrackets {
            resolvedBalancedBrackets = containsBalancedBrackets
        }
        if fontStyle != .notSet {
            resolvedFontStyle = fontStyle
        }
        if foreground != 0 {
            resolvedForeground = foreground
        }
        if background != 0 {
            resolvedBackground = background
        }

        return UInt32(truncatingIfNeeded: resolvedLanguageID) << languageIDOffset
            | resolvedTokenType.rawValue << tokenTypeOffset
            | UInt32(resolvedBalancedBrackets ? 1 : 0) << balancedBracketsOffset
            | UInt32(truncatingIfNeeded: resolvedFontStyle.rawValue) << fontStyleOffset
            | UInt32(truncatingIfNeeded: resolvedForeground) << foregroundOffset
            | UInt32(truncatingIfNeeded: resolvedBackground) << backgroundOffset
    }
}

import COniguruma
import Foundation

/// Options supported by the scanner contract used by VS Code TextMate.
public struct OnigFindOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let notBeginString = Self(rawValue: 1 << 0)
    public static let notEndString = Self(rawValue: 1 << 1)
    public static let notBeginPosition = Self(rawValue: 1 << 2)
}

public struct OnigCaptureIndex: Sendable, Equatable, Hashable {
    /// UTF-16 code-unit offset, matching Shiki and `NSRange` semantics.
    public let start: Int
    /// UTF-16 code-unit offset, matching Shiki and `NSRange` semantics.
    public let end: Int

    public var length: Int { end - start }

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct OnigMatch: Sendable, Equatable {
    /// Index of the matching pattern in the scanner's pattern array.
    public let index: Int
    public let captureIndices: [OnigCaptureIndex]

    public init(index: Int, captureIndices: [OnigCaptureIndex]) {
        self.index = index
        self.captureIndices = captureIndices
    }
}

public enum OnigurumaError: Error, Sendable, Equatable, CustomStringConvertible {
    case initializationFailed
    case invalidPattern(pattern: String, message: String)
    case searchFailed

    public var description: String {
        switch self {
        case .initializationFailed:
            "Could not initialize the native Oniguruma engine"
        case let .invalidPattern(pattern, message):
            "Invalid Oniguruma pattern \(String(reflecting: pattern)): \(message)"
        case .searchFailed:
            "The native Oniguruma search failed"
        }
    }
}

/// A string prepared for Oniguruma while retaining Shiki's UTF-16 offsets.
///
/// Oniguruma searches UTF-8 bytes. JavaScript—and therefore Shiki's public
/// token contract—uses UTF-16 code units. These maps mirror the conversion in
/// `vscode-oniguruma` so emoji and other non-BMP scalars produce identical
/// ranges in Swift and Shiki.
public final class OnigString: @unchecked Sendable {
    public let content: String
    public let utf16Length: Int
    public let utf8Length: Int

    let utf8Storage: [UInt8]
    private let utf16OffsetToUTF8: [Int]?
    private let utf8OffsetToUTF16: [Int]?

    public init(_ content: String) {
        self.content = content
        utf16Length = content.utf16.count
        utf8Length = content.utf8.count

        // The trailing byte guarantees a non-null pointer for an empty string;
        // it is not included in `utf8Length` or passed to Oniguruma.
        utf8Storage = Array(content.utf8) + [0]

        let needsOffsetMapping = utf8Length != utf16Length
        var utf16ToUTF8 = needsOffsetMapping
            ? Array(repeating: 0, count: utf16Length + 1)
            : []
        var utf8ToUTF16 = needsOffsetMapping
            ? Array(repeating: 0, count: utf8Length + 1)
            : []
        var utf16Offset = 0
        var utf8Offset = 0

        for scalar in content.unicodeScalars {
            let utf16Width = scalar.value > 0xFFFF ? 2 : 1
            let utf8Width: Int
            switch scalar.value {
            case ...0x7F:
                utf8Width = 1
            case ...0x7FF:
                utf8Width = 2
            case ...0xFFFF:
                utf8Width = 3
            default:
                utf8Width = 4
            }

            if needsOffsetMapping {
                for index in 0..<utf16Width {
                    utf16ToUTF8[utf16Offset + index] = utf8Offset
                }
                for index in 0..<utf8Width {
                    utf8ToUTF16[utf8Offset + index] = utf16Offset
                }
            }

            utf16Offset += utf16Width
            utf8Offset += utf8Width
        }

        if needsOffsetMapping {
            utf16ToUTF8[utf16Length] = utf8Length
            utf8ToUTF16[utf8Length] = utf16Length
            utf16OffsetToUTF8 = utf16ToUTF8
            utf8OffsetToUTF16 = utf8ToUTF16
        } else {
            utf16OffsetToUTF8 = nil
            utf8OffsetToUTF16 = nil
        }
    }

    public func convertUTF16OffsetToUTF8(_ offset: Int) -> Int {
        guard let utf16OffsetToUTF8 else { return offset }
        if offset < 0 { return 0 }
        if offset > utf16Length { return utf8Length }
        return utf16OffsetToUTF8[offset]
    }

    public func convertUTF8OffsetToUTF16(_ offset: Int) -> Int {
        guard let utf8OffsetToUTF16 else { return offset }
        if offset < 0 { return 0 }
        if offset > utf8Length { return utf16Length }
        return utf8OffsetToUTF16[offset]
    }
}

/// Native equivalent of `vscode-oniguruma`'s scanner interface.
///
/// Calls are serialized because each compiled pattern owns a reusable capture
/// region. This also makes a cached scanner safe to share between highlighters.
public final class OnigScanner: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var maxCaptureCount = 0
    private let lock = NSLock()

    public init(patterns: [String]) throws {
        guard let handle = shiki_onig_scanner_create() else {
            throw OnigurumaError.initializationFailed
        }
        self.handle = handle

        do {
            for pattern in patterns {
                try add(pattern: pattern)
            }
            maxCaptureCount = Int(
                shiki_onig_scanner_max_capture_count(handle)
            )
        } catch {
            shiki_onig_scanner_destroy(handle)
            self.handle = nil
            throw error
        }
    }

    deinit {
        if let handle {
            shiki_onig_scanner_destroy(handle)
        }
    }

    public static var version: String {
        String(cString: shiki_onig_version())
    }

    public func findNextMatchSync(
        _ string: String,
        startPosition: Int,
        options: OnigFindOptions = []
    ) throws -> OnigMatch? {
        try findNextMatchSync(
            OnigString(string),
            startPosition: startPosition,
            options: options
        )
    }

    public func findNextMatchSync(
        _ string: OnigString,
        startPosition: Int,
        options: OnigFindOptions = []
    ) throws -> OnigMatch? {
        guard let handle else {
            throw OnigurumaError.searchFailed
        }
        let utf8Start = string.convertUTF16OffsetToUTF8(startPosition)
        var patternIndex = 0
        var captureCount = 0
        var starts = Array(repeating: Int32(0), count: maxCaptureCount)
        var ends = Array(repeating: Int32(0), count: maxCaptureCount)

        lock.lock()
        defer { lock.unlock() }

        let status = string.utf8Storage.withUnsafeBufferPointer { stringBuffer in
            starts.withUnsafeMutableBufferPointer { startsBuffer in
                ends.withUnsafeMutableBufferPointer { endsBuffer in
                    shiki_onig_scanner_find_next(
                        handle,
                        stringBuffer.baseAddress,
                        string.utf8Length,
                        utf8Start,
                        options.rawValue,
                        &patternIndex,
                        startsBuffer.baseAddress,
                        endsBuffer.baseAddress,
                        startsBuffer.count,
                        &captureCount
                    )
                }
            }
        }

        switch status {
        case 0:
            return nil
        case 1:
            guard captureCount <= starts.count else {
                throw OnigurumaError.searchFailed
            }
            let captures = (0..<captureCount).map { index in
                // vscode-oniguruma reads the C int array through Uint32Array.
                // Preserve that wraparound for unmatched captures (-1).
                let start = Int(UInt32(bitPattern: starts[index]))
                let end = Int(UInt32(bitPattern: ends[index]))
                return OnigCaptureIndex(
                    start: string.convertUTF8OffsetToUTF16(start),
                    end: string.convertUTF8OffsetToUTF16(end)
                )
            }
            return OnigMatch(index: patternIndex, captureIndices: captures)
        default:
            throw OnigurumaError.searchFailed
        }
    }

    private func add(pattern: String) throws {
        guard let handle else {
            throw OnigurumaError.initializationFailed
        }
        let bytes = Array(pattern.utf8) + [0]
        var errorBuffer = Array(repeating: CChar(0), count: 512)

        let succeeded = bytes.withUnsafeBufferPointer { patternBuffer in
            errorBuffer.withUnsafeMutableBufferPointer { errorBuffer in
                shiki_onig_scanner_add_pattern(
                    handle,
                    patternBuffer.baseAddress,
                    bytes.count - 1,
                    errorBuffer.baseAddress,
                    errorBuffer.count
                )
            }
        }

        guard succeeded else {
            let message = errorBuffer.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return "Unknown error" }
                return String(cString: baseAddress)
            }
            throw OnigurumaError.invalidPattern(pattern: pattern, message: message)
        }
    }
}

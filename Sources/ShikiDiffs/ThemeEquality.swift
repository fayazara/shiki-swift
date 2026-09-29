#if os(macOS)
import Foundation

/// A single theme or an appearance-specific pair, matching upstream theme inputs.
public enum DiffThemeSelection: Sendable, Equatable {
    case single(String)
    case adaptive(DiffThemeNames)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.single(a), .single(b)):
            return a.utf16.elementsEqual(b.utf16)
        case let (.adaptive(a), .adaptive(b)):
            return a == b
        default:
            return false
        }
    }
}

/// Exact upstream equality: single names and adaptive pairs are distinct forms.
public func areThemesEqual(_ lhs: DiffThemeSelection?, _ rhs: DiffThemeSelection?) -> Bool {
    lhs == rhs
}

#endif

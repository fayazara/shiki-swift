import Foundation

/// Immutable, identity-bearing application metadata for an annotation.
/// Reuse this object across view updates; replacing it signals new metadata.
public final class LineAnnotationMetadata: Sendable, Equatable {
    /// JavaScript primitive metadata uses strict value equality, unlike object payloads.
    public enum Primitive: Sendable {
        case null
        case boolean(Bool)
        case number(Double)
        case string(String)
    }
    private let primitive: Primitive?
    private let storage: any Sendable
    public init<Value: Sendable>(_ value: Value) { storage = value; primitive = nil }
    public init(primitive: Primitive) { storage = primitive; self.primitive = primitive }
    public func value<Value: Sendable>(as type: Value.Type = Value.self) -> Value? { storage as? Value }
    public static func == (lhs: LineAnnotationMetadata, rhs: LineAnnotationMetadata) -> Bool {
        switch (lhs.primitive, rhs.primitive) {
        case (.none, .none): return lhs === rhs
        case (.some(.null), .some(.null)): return true
        case let (.some(.boolean(a)), .some(.boolean(b))): return a == b
        case let (.some(.number(a)), .some(.number(b))): return a == b
        case let (.some(.string(a)), .some(.string(b))): return a.utf16.elementsEqual(b.utf16)
        default: return false
        }
    }
}

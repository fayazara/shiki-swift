#if os(macOS)
import Foundation

/// A file annotation has no diff side. Its native identity and display text are
/// retained when adapting it to the shared additions-side renderer.
public struct FileLineAnnotation: Identifiable, Equatable, Sendable {
    public var id: String
    public var lineNumber: Int
    public var text: String
    public var metadata: LineAnnotationMetadata?
    public init(id: String = UUID().uuidString, lineNumber: Int, text: String, metadata: LineAnnotationMetadata? = nil) {
        self.id = id; self.lineNumber = lineNumber; self.text = text; self.metadata = metadata
    }
    public var renderedAnnotation: LineAnnotation {
        .init(id: id, side: .additions, lineNumber: lineNumber, text: text, metadata: metadata)
    }
    init(rendered annotation: LineAnnotation) {
        self.init(id: annotation.id, lineNumber: annotation.lineNumber, text: annotation.text, metadata: annotation.metadata)
    }
}

/// Preserves whether an upstream annotation contains a side property.
public enum EditorAnnotation: Sendable {
    case file(FileLineAnnotation)
    case diff(LineAnnotation)
    public var renderedAnnotation: LineAnnotation {
        switch self {
        case .file(let annotation): return annotation.renderedAnnotation
        case .diff(let annotation): return annotation
        }
    }
}

public func isDiffAnnotation(_ annotation: EditorAnnotation) -> Bool {
    if case .diff = annotation { return true }
    return false
}
public func isFileAnnotation(_ annotation: EditorAnnotation) -> Bool { !isDiffAnnotation(annotation) }

/// Upstream assumes homogeneous input and inspects only its first element.
/// Empty collections are valid for either shape.
public func isDiffAnnotationCollection(_ annotations: [EditorAnnotation]) -> Bool {
    annotations.first.map(isDiffAnnotation) ?? true
}
public func isFileAnnotationCollection(_ annotations: [EditorAnnotation]) -> Bool {
    annotations.first.map(isFileAnnotation) ?? true
}

/// Upstream file equality ignores native identity and display text.
public func areLineAnnotationsEqual(_ lhs: FileLineAnnotation, _ rhs: FileLineAnnotation) -> Bool {
    lhs.lineNumber == rhs.lineNumber && lhs.metadata == rhs.metadata
}

#endif

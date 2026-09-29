#if os(macOS)
import Foundation

/// Upstream render-range coordinates, including precomputed buffer extents.
public struct DiffRenderRange: Equatable, Sendable {
    public var startingLine: Int
    public var totalLines: Int
    public var bufferBefore: Int
    public var bufferAfter: Int
    public init(startingLine: Int, totalLines: Int, bufferBefore: Int = 0, bufferAfter: Int = 0) {
        self.startingLine = startingLine; self.totalLines = totalLines
        self.bufferBefore = bufferBefore; self.bufferAfter = bufferAfter
    }
}

public func includesFileAnnotations(_ annotations: [LineAnnotation]?) -> Bool {
    annotations?.contains { $0.lineNumber == 0 } ?? false
}

public func getFileAnnotations<Annotation>(_ annotations: [Int: [Annotation]]) -> [Annotation]? {
    guard let values = annotations[0], !values.isEmpty else { return nil }
    return values
}

public func shouldRenderFileAnnotations(_ range: DiffRenderRange) -> Bool {
    range.startingLine == 0 && range.totalLines > 0
}

/// Compares upstream file-annotation fields; native IDs and display text are excluded.
public func areLineAnnotationsEqual(_ lhs: LineAnnotation, _ rhs: LineAnnotation) -> Bool {
    lhs.lineNumber == rhs.lineNumber && lhs.metadata == rhs.metadata
}

/// Compares upstream diff-annotation fields, including the side.
public func areDiffLineAnnotationsEqual(_ lhs: LineAnnotation, _ rhs: LineAnnotation) -> Bool {
    lhs.side == rhs.side && areLineAnnotationsEqual(lhs, rhs)
}

#endif

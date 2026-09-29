#if os(macOS)
import Foundation

public enum MarkerSeverity: String, Sendable, CaseIterable { case error, warning, info, hint }
/// Diagnostic positions are zero-based UTF-16 positions. Supply native rich
/// content through DiffEditor.renderMarkerPopover instead of HTML messages.
public struct Marker: Sendable {
    public var id: UUID
    public var start: TextPosition
    public var end: TextPosition
    public var severity: MarkerSeverity
    public var message: String
    public var source: String?
    public var metadata: LineAnnotationMetadata?
    public init(id: UUID = UUID(), start: TextPosition, end: TextPosition, severity: MarkerSeverity,
                message: String, source: String? = nil, metadata: LineAnnotationMetadata? = nil) {
        self.id = id; self.start = start; self.end = end; self.severity = severity
        self.message = message; self.source = source; self.metadata = metadata
    }
}
public struct CaretMetadata: Sendable {
    public var color: String
    public var data: LineAnnotationMetadata?
    public init(color: String, data: LineAnnotationMetadata? = nil) { self.color = color; self.data = data }
}
/// A non-editable selection supplied by a collaborator or other external owner.
/// Matching endpoints draw a caret; selection direction determines its focus.
public struct EditorCaret: Sendable {
    public var anchor: TextPosition
    public var focus: TextPosition
    public var metadata: CaretMetadata
    public init(anchor: TextPosition, focus: TextPosition, metadata: CaretMetadata) {
        self.anchor = anchor; self.focus = focus; self.metadata = metadata
    }
}

/// Static interval tree. A visible-line lookup visits only intersecting branches;
/// multi-million-line diagnostics do not allocate an entry for each source row.
struct EditorOverlayIndex {
    private struct Node {
        var index: Int
        var lower: Int
        var upper: Int
        var maximum: Int
        var left: Int?
        var right: Int?
    }
    private var nodes: [Node] = []
    private var root: Int?
    init(_ intervals: [ClosedRange<Int>] = []) {
        let sorted = intervals.enumerated().sorted { $0.element.lowerBound < $1.element.lowerBound }
        func build(_ range: Range<Int>) -> Int? {
            guard !range.isEmpty else { return nil }
            let middle = range.lowerBound + range.count / 2, entry = sorted[middle]
            let left = build(range.lowerBound..<middle), right = build((middle + 1)..<range.upperBound)
            let index = nodes.count
            nodes.append(.init(index: entry.offset, lower: entry.element.lowerBound, upper: entry.element.upperBound,
                               maximum: max(entry.element.upperBound, left.map { nodes[$0].maximum } ?? Int.min, right.map { nodes[$0].maximum } ?? Int.min), left: left, right: right))
            return index
        }
        root = build(0..<sorted.count)
    }
    func query(_ line: Int) -> [Int] {
        var result: [Int] = []
        func visit(_ index: Int?) {
            guard let index, nodes[index].maximum >= line else { return }
            let node = nodes[index]
            visit(node.left)
            if node.lower <= line {
                if node.upper >= line { result.append(node.index) }
                visit(node.right)
            }
        }
        visit(root)
        return result.sorted()
    }
}

/// Upstream caret affinity: positions inside a replacement move to its end.
func remapEditorOffset(_ offset: Int, through edits: [ResolvedTextEdit]) -> Int {
    var delta = 0
    for edit in edits {
        if offset < edit.range.location { break }
        if offset >= NSMaxRange(edit.range) { delta += edit.newText.utf16.count - edit.range.length }
        else { return edit.range.location + delta + edit.newText.utf16.count }
    }
    return offset + delta
}

#endif

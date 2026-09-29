#if os(macOS)
import Foundation
import CoreText

/// CoreText enumerates pairs of logical caret edges in visual order. A pair
/// can cover multiple UTF-16 units (a combining sequence or surrogate pair).
struct TokenLineGeometry {
    struct Cluster {
        let range: NSRange
        let left: CGFloat
        let right: CGFloat
    }
    let clusters: [Cluster]
    init(_ line: CTLine) {
        var clusters: [Cluster] = []
        var pending: (offset: CGFloat, index: Int)?
        CTLineEnumerateCaretOffsets(line) { rawOffset, index, _, _ in
            let offset = CGFloat(rawOffset)
            if let first = pending {
                let start = min(first.index, index), end = max(first.index, index) + 1
                clusters.append(.init(range: .init(location: start, length: end - start), left: min(first.offset, offset), right: max(first.offset, offset)))
                pending = nil
            } else { pending = (offset, index) }
        }
        self.clusters = clusters
    }
    func rects(for range: NSRange, origin: CGPoint, height: CGFloat) -> [CGRect] {
        guard range.length > 0 else { return [] }
        var output: [CGRect] = []
        for cluster in clusters where NSIntersectionRange(cluster.range, range).length > 0 && cluster.right > cluster.left {
            let rect = CGRect(x: origin.x + cluster.left, y: origin.y, width: cluster.right - cluster.left, height: height)
            if let previous = output.last, abs(previous.maxX - rect.minX) < 0.01 {
                output[output.count - 1] = previous.union(rect)
            } else { output.append(rect) }
        }
        return output
    }
}

#endif

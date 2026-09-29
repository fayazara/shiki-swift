#if os(macOS)
import Foundation

/// Fixed code-line geometry plus sparse variable-height annotation rows.
/// Storage scales with annotation count, not the number of source lines.
struct RowHeightIndex {
    let rowCount: Int
    let lineHeight: CGFloat
    private let variableRows: [Int]
    private var extras = FileHeightIndex()
    private var supplementalRows: [Int] = []
    private var supplementalOffsets: [CGFloat] = [0]
    mutating func setSupplementalHeights(_ heights: [Int: CGFloat]) {
        supplementalRows = heights.keys.filter { $0 >= 0 && $0 < rowCount && heights[$0]!.isFinite && heights[$0]! > 0 }.sorted()
        supplementalOffsets = [0]
        for row in supplementalRows { supplementalOffsets.append(supplementalOffsets.last! + heights[row]!) }
    }
    private func supplementalHeight(before row: Int) -> CGFloat {
        var lo = 0, hi = supplementalRows.count
        while lo < hi { let mid = (lo + hi) / 2; if supplementalRows[mid] < row { lo = mid + 1 } else { hi = mid } }
        return supplementalOffsets[lo]
    }

    init(rowCount: Int, lineHeight: CGFloat, variableRows: [Int] = []) {
        self.rowCount = max(0, rowCount)
        self.lineHeight = max(1, lineHeight)
        self.variableRows = Array(Set(variableRows.filter { $0 >= 0 && $0 < rowCount })).sorted()
        for _ in self.variableRows { extras.append(0) }
    }
    private func slot(before row: Int) -> Int {
        var low = 0, high = variableRows.count
        while low < high {
            let mid = low + (high - low) / 2
            if variableRows[mid] < row { low = mid + 1 } else { high = mid }
        }
        return low
    }
    func origin(of row: Int) -> CGFloat {
        let boundary = min(rowCount, max(0, row))
        return CGFloat(boundary) * lineHeight + extras[slot(before: boundary)] + supplementalHeight(before: boundary)
    }
    var totalHeight: CGFloat { origin(of: rowCount) }
    func height(of row: Int) -> CGFloat { origin(of: row + 1) - origin(of: row) }
    mutating func setHeight(_ height: CGFloat, for row: Int) {
        let index = slot(before: row)
        guard index < variableRows.count, variableRows[index] == row, height.isFinite else { return }
        extras.update(index, height: max(0, height) - lineHeight)
    }
    func row(at y: CGFloat) -> Int {
        guard rowCount > 0, y >= 0 else { return 0 }
        if y >= totalHeight { return rowCount - 1 }
        if variableRows.isEmpty && supplementalRows.isEmpty { return min(rowCount - 1, Int(y / lineHeight)) }
        var low = 0, high = rowCount
        while low < high {
            let middle = low + (high - low) / 2
            if origin(of: middle + 1) <= y { low = middle + 1 } else { high = middle }
        }
        return min(low, rowCount - 1)
    }
}


extension RowHeightIndex {
    init(rows: [DiffRow], options: DiffRenderOptions) {
        let variable = rows.indices.filter {
            if !rows[$0].annotations.isEmpty { return true }
            switch rows[$0].kind { case .separator, .conflictMarker(_, .start): return true; default: return false }
        }
        self.init(rowCount: rows.count, lineHeight: options.lineHeight, variableRows: variable)
        for index in variable {
            switch rows[index].kind {
            case .separator:
                let height: CGFloat = options.hunkSeparators == .simple ? 4 : options.hunkSeparators == .lineInfo ? 48 : 32
                let edgeInset: CGFloat = options.hunkSeparators == .lineInfo ? (rows[index].separatorIsFirst ? 8 : 0) + (rows[index].separatorIsLast ? 8 : 0) : 0
                setHeight(height - edgeInset, for: index)
            case .conflictMarker(_, .start): setHeight(options.lineHeight + options.mergeConflictActionHeight, for: index)
            default: break
            }
        }
    }
}

#endif

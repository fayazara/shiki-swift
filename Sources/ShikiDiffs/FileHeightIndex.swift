import Foundation

/// Fenwick index of file extents. Measuring one newly visible header updates
/// subsequent offsets in O(log n), without visiting the intervening files.
struct FileHeightIndex {
    private var values: [CGFloat] = []
    private var tree: [CGFloat] = [0]
    var count: Int { values.count + 1 }
    var last: CGFloat? { self[values.count] }
    subscript(_ boundary: Int) -> CGFloat {
        var index = boundary, sum: CGFloat = 0
        while index > 0 { sum += tree[index]; index -= index & -index }
        return sum
    }
    mutating func append(_ height: CGFloat) {
        let index = values.count + 1
        let start = index - (index & -index)
        let covered = self[index - 1] - self[start]
        values.append(height); tree.append(covered + height)
    }
    mutating func update(_ file: Int, height: CGFloat) {
        let delta = height - values[file]; values[file] = height
        var index = file + 1
        while index < tree.count { tree[index] += delta; index += index & -index }
    }
    func file(at offset: CGFloat) -> Int {
        guard !values.isEmpty else { return 0 }
        var index = 0, sum: CGFloat = 0, step = 1
        while step <= values.count / 2 { step *= 2 }
        while step > 0 {
            let next = index + step
            if next <= values.count, sum + tree[next] <= offset { index = next; sum += tree[next] }
            step /= 2
        }
        return min(index, values.count - 1)
    }
}

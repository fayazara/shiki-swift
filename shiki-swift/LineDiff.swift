import Foundation

/// A line diff for the Large File Diff demo: Myers' O(ND) algorithm in its
/// divide-and-conquer form (bisecting on the middle snake), so memory stays
/// linear however many lines changed. Common prefixes and suffixes are trimmed
/// first, and a deadline turns a pathological diff into a coarse one instead of
/// a hang.
nonisolated enum LineDiff {
    /// One step of the edit script, in file order.
    enum Op: Sendable, Equatable {
        case equal(old: Int, new: Int)
        case removed(old: Int)
        case added(new: Int)
        /// A run of unchanged lines hidden in "changes only" mode.
        case gap(old: Int, new: Int, count: Int)
    }

    struct Result: Sendable {
        var ops: [Op]
        var added: Int
        var removed: Int
        var hunks: Int
        /// The deadline passed; the remaining region is reported as replaced.
        var timedOut: Bool
    }

    static func compute(old: [String], new: [String], timeLimit: TimeInterval = 8) -> Result {
        // Intern lines so comparisons are integer comparisons.
        var table: [String: Int] = [:]
        table.reserveCapacity(old.count)
        func id(_ line: String) -> Int {
            if let known = table[line] { return known }
            let next = table.count
            table[line] = next
            return next
        }
        let a = old.map(id)
        let b = new.map(id)

        let engine = Engine(a: a, b: b, deadline: Date().addingTimeInterval(timeLimit))
        engine.run(0, a.count, 0, b.count)

        var ops: [Op] = []
        ops.reserveCapacity(max(a.count, b.count))
        var i = 0
        var j = 0
        var added = 0
        var removed = 0
        var hunks = 0
        var inHunk = false
        while i < a.count || j < b.count {
            if i < a.count, engine.removed[i] {
                ops.append(.removed(old: i))
                i += 1
                removed += 1
                if !inHunk { hunks += 1; inHunk = true }
            } else if j < b.count, engine.added[j] {
                ops.append(.added(new: j))
                j += 1
                added += 1
                if !inHunk { hunks += 1; inHunk = true }
            } else {
                ops.append(.equal(old: i, new: j))
                i += 1
                j += 1
                inHunk = false
            }
        }
        return Result(ops: ops, added: added, removed: removed, hunks: hunks, timedOut: engine.timedOut)
    }

    /// Keeps `context` unchanged lines around each change and folds the rest
    /// into `.gap` entries.
    static func collapsing(_ ops: [Op], context: Int) -> [Op] {
        var visible = [Bool](repeating: false, count: ops.count)
        for (index, op) in ops.enumerated() {
            switch op {
            case .removed, .added:
                let lower = max(0, index - context)
                let upper = min(ops.count - 1, index + context)
                for k in lower...upper { visible[k] = true }
            default:
                break
            }
        }
        var output: [Op] = []
        var index = 0
        while index < ops.count {
            if visible[index] {
                output.append(ops[index])
                index += 1
                continue
            }
            let start = index
            while index < ops.count, !visible[index] { index += 1 }
            if case let .equal(old, new) = ops[start] {
                output.append(.gap(old: old, new: new, count: index - start))
            }
        }
        return output
    }

    // MARK: - Engine

    private final class Engine {
        let a: [Int]
        let b: [Int]
        var removed: [Bool]
        var added: [Bool]
        let deadline: Date
        var timedOut = false

        init(a: [Int], b: [Int], deadline: Date) {
            self.a = a
            self.b = b
            removed = [Bool](repeating: false, count: a.count)
            added = [Bool](repeating: false, count: b.count)
            self.deadline = deadline
        }

        func run(_ aLow: Int, _ aHigh: Int, _ bLow: Int, _ bHigh: Int) {
            var aLo = aLow, aHi = aHigh, bLo = bLow, bHi = bHigh
            while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] { aLo += 1; bLo += 1 }
            while aLo < aHi, bLo < bHi, a[aHi - 1] == b[bHi - 1] { aHi -= 1; bHi -= 1 }
            if aLo == aHi {
                for j in bLo..<bHi { added[j] = true }
                return
            }
            if bLo == bHi {
                for i in aLo..<aHi { removed[i] = true }
                return
            }
            guard let (x, y) = bisect(aLo, aHi, bLo, bHi),
                  !(x == 0 && y == 0), !(x == aHi - aLo && y == bHi - bLo) else {
                for i in aLo..<aHi { removed[i] = true }
                for j in bLo..<bHi { added[j] = true }
                return
            }
            run(aLo, aLo + x, bLo, bLo + y)
            run(aLo + x, aHi, bLo + y, bHi)
        }

        /// Finds a point on an optimal path by growing forward and reverse
        /// searches until they overlap (Myers, "An O(ND) Difference
        /// Algorithm and Its Variations", section 4b).
        private func bisect(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> (Int, Int)? {
            let n = aHi - aLo
            let m = bHi - bLo
            let maxD = (n + m + 1) / 2
            let offset = maxD
            let length = 2 * maxD
            var forward = [Int](repeating: -1, count: length + 2)
            var reverse = [Int](repeating: -1, count: length + 2)
            forward[offset + 1] = 0
            reverse[offset + 1] = 0
            let delta = n - m
            // Odd deltas can overlap on the forward pass, even ones on the reverse.
            let front = delta % 2 != 0
            var k1Start = 0, k1End = 0, k2Start = 0, k2End = 0

            for d in 0..<maxD {
                if d & 63 == 0, Date() > deadline {
                    timedOut = true
                    return nil
                }
                var k1 = -d + k1Start
                while k1 <= d - k1End {
                    let index = offset + k1
                    var x1: Int
                    if k1 == -d || (k1 != d && forward[index - 1] < forward[index + 1]) {
                        x1 = forward[index + 1]
                    } else {
                        x1 = forward[index - 1] + 1
                    }
                    var y1 = x1 - k1
                    while x1 < n, y1 < m, a[aLo + x1] == b[bLo + y1] { x1 += 1; y1 += 1 }
                    forward[index] = x1
                    if x1 > n {
                        k1End += 2
                    } else if y1 > m {
                        k1Start += 2
                    } else if front {
                        let other = offset + delta - k1
                        if other >= 0, other < length, reverse[other] != -1, x1 >= n - reverse[other] {
                            return (x1, y1)
                        }
                    }
                    k1 += 2
                }

                var k2 = -d + k2Start
                while k2 <= d - k2End {
                    let index = offset + k2
                    var x2: Int
                    if k2 == -d || (k2 != d && reverse[index - 1] < reverse[index + 1]) {
                        x2 = reverse[index + 1]
                    } else {
                        x2 = reverse[index - 1] + 1
                    }
                    var y2 = x2 - k2
                    while x2 < n, y2 < m, a[aHi - x2 - 1] == b[bHi - y2 - 1] { x2 += 1; y2 += 1 }
                    reverse[index] = x2
                    if x2 > n {
                        k2End += 2
                    } else if y2 > m {
                        k2Start += 2
                    } else if !front {
                        let other = offset + delta - k2
                        if other >= 0, other < length, forward[other] != -1 {
                            let x1 = forward[other]
                            let y1 = offset + x1 - other
                            if x1 >= n - x2 { return (x1, y1) }
                        }
                    }
                    k2 += 2
                }
            }
            return nil
        }
    }
}

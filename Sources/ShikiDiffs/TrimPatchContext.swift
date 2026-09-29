import Foundation

/// Trims patch context and splits distant changes using upstream's range rules.
public func trimPatchContext(_ patch: String, contextSize: Int = 10) -> String {
    let size = max(0, contextSize)
    struct Pending {
        var oldStart: Int; var newStart: Int
        var oldCount = 0; var newCount = 0
        var body: [String] = []; var context: [String] = []
        mutating func flush(_ mode: Int, size: Int) {
            if mode == 0, context.count > size {
                let difference = context.count - size
                context.removeFirst(difference); oldStart += difference; newStart += difference
            }
            if mode == 2, context.count > size { context = Array(context.prefix(size)) }
            body.append(contentsOf: context); oldCount += context.count; newCount += context.count; context = []
        }
        func emit(into output: inout [String]) {
            func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
            output.append("@@ -\(range(oldStart, oldCount)) +\(range(newStart, newCount)) @@")
            output.append(contentsOf: body)
        }
    }
    let regex = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
    var output: [String] = [], pending: Pending?
    for line in patch.components(separatedBy: "\n") {
        if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if var hunk = pending, !hunk.body.isEmpty { hunk.flush(2, size: size); hunk.emit(into: &output) }
            let ns = line as NSString
            pending = Pending(oldStart: Int(ns.substring(with: match.range(at: 1))) ?? 0, newStart: Int(ns.substring(with: match.range(at: 3))) ?? 0)
            continue
        }
        guard var hunk = pending else { output.append(line); continue }
        if line.hasPrefix(" ") { hunk.context.append(line) }
        else if !line.isEmpty {
            if !hunk.body.isEmpty && hunk.context.count > size * 2 {
                let omitted = hunk.context.count - size * 2
                // JS slice(-0) retains the whole array; keep that edge behavior.
                let trailing = size == 0 ? hunk.context : Array(hunk.context.suffix(size))
                hunk.flush(2, size: size); hunk.emit(into: &output)
                hunk = Pending(oldStart: hunk.oldStart + hunk.oldCount + omitted, newStart: hunk.newStart + hunk.newCount + omitted, context: trailing)
            }
            hunk.flush(hunk.body.isEmpty ? 0 : 1, size: size)
            hunk.body.append(line)
            if line.hasPrefix("+") { hunk.newCount += 1 }
            else if line.hasPrefix("-") { hunk.oldCount += 1 }
        }
        pending = hunk
    }
    if var hunk = pending, !hunk.body.isEmpty { hunk.flush(2, size: size); hunk.emit(into: &output) }
    return output.joined(separator: "\n") + (patch.utf8.last == 10 ? "\n" : "")
}

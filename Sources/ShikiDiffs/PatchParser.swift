#if os(macOS)
import Foundation

public func parsePatchFiles(_ data: String, cacheKeyPrefix: String? = nil, throwOnError: Bool = false) throws -> [ParsedPatch] {
    let lines = splitFileContents(data)
    var chunks: [String] = [], current = ""
    for line in lines {
        if line.hasPrefix("From "), cleanLastNewline(line).range(of: #"^From [a-f0-9]+ .+$"#, options: .regularExpression) != nil, !current.isEmpty { chunks.append(current); current = "" }
        current += line
    }
    if !current.isEmpty || chunks.isEmpty { chunks.append(current) }
    return try chunks.enumerated().map { index, chunk in
        try parsePatch(chunk, prefix: cacheKeyPrefix, patchIndex: index, strict: throwOnError)
    }
}
public func processPatch(_ data: String, cacheKeyPrefix: String? = nil, throwOnError: Bool = false) throws -> ParsedPatch {
    try parsePatch(data, prefix: cacheKeyPrefix, patchIndex: nil, strict: throwOnError)
}
private func parsePatch(_ data: String, prefix: String?, patchIndex: Int?, strict: Bool) throws -> ParsedPatch {
    let lines = splitFileContents(data), git = data.hasPrefix("diff --git") || data.contains("\ndiff --git")
    var result = ParsedPatch(), chunks: [String] = [], current = "", opened = false, oldRemaining = 0, newRemaining = 0
    for i in lines.indices {
        let line = lines[i]
        let boundary = git ? line.hasPrefix("diff --git") : oldRemaining <= 0 && newRemaining <= 0 && isFilenameHeader(line, prefix: "---") && i + 1 < lines.count && isFilenameHeader(lines[i + 1], prefix: "+++")
        if boundary {
            if opened { chunks.append(current) } else if !current.isEmpty { result.patchMetadata = current }
            current = ""; opened = true
        }
        if let h = parseHunkHeader(line) { oldRemaining = h.deletionCount; newRemaining = h.additionCount }
        else if opened {
            switch line.unicodeScalars.first {
            case " ": oldRemaining -= 1; newRemaining -= 1
            case "-": oldRemaining -= 1
            case "+": newRemaining -= 1
            default: break
            }
        }
        current += line
    }
    if opened { chunks.append(current) } else { result.patchMetadata = current }
    for chunk in chunks {
        let key = prefix.map { cacheKey("patch-file", [$0] + (patchIndex.map { [String($0)] } ?? []) + [String(result.files.count)]) }
        if let file = try processFile(chunk, cacheKey: key, throwOnError: strict) { result.files.append(file) }
    }
    return result
}
private func captures(_ pattern: String, _ text: String) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
}
private func parseHunkHeader(_ line: String) -> Hunk? {
    guard let c = captures(#"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: (.*?))?\r?\n?$"#, line), let oldStart = Int(c[0] ?? ""), let newStart = Int(c[2] ?? "") else { return nil }
    var h = Hunk(); h.deletionStart = oldStart; h.additionStart = newStart
    h.deletionCount = Int(c[1] ?? "1") ?? 1; h.additionCount = Int(c[3] ?? "1") ?? 1
    h.hunkContext = c[4]; h.hunkSpecs = line
    return h
}
private func isFilenameHeader(_ line: String, prefix: String) -> Bool {
    guard line.hasPrefix(prefix), line.utf8.count > 4 else { return false }
    let rest = line.dropFirst(3)
    return (rest.first == " " || rest.first == "\t") && !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
public func processFile(_ data: String, cacheKey: String? = nil, throwOnError: Bool = false) throws -> FileDiffMetadata? {
    let lines = splitFileContents(data), git = data.hasPrefix("diff --git")
    guard git || lines.contains(where: { isFilenameHeader($0, prefix: "---") }) else { return nil }
    var diff = FileDiffMetadata(name: ""); diff.cacheKey = cacheKey
    var i = 0
    while i < lines.count && !lines[i].hasPrefix("@@ ") {
        let line = cleanLastNewline(lines[i])
        if line.hasPrefix("diff --git "), let c = captures(#"^diff --git (?:\"a/(.*?)\"|a/(.*?)) (?:\"b/(.*?)\"|b/(.*))$"#, line) {
            diff.prevName = c[0] ?? c[1]; diff.name = c[2] ?? c[3] ?? ""
        } else if line.hasPrefix("diff --git"), throwOnError { throw DiffError.invalidPatch("Invalid git diff header")
        } else if let c = captures(git ? #"^(---|\+\+\+)\s+[ab]/([^\t\r\n]+)"# : #"^(---|\+\+\+)\s+([^\t\r\n]+)"#, line), let rawName = c[1] {
            let name = rawName.trimmingCharacters(in: .whitespaces)
            if name != "/dev/null" {
                if c[0] == "---" { diff.prevName = name; diff.name = name }
                else { diff.name = name }
            }
        } else if line.hasPrefix("new file mode ") { diff.type = .new; diff.mode = String(line.dropFirst(14)) }
        else if line.hasPrefix("deleted file mode ") { diff.type = .deleted; diff.mode = String(line.dropFirst(18)) }
        else if line.hasPrefix("new mode ") { diff.mode = String(line.dropFirst(9)) }
        else if line.hasPrefix("old mode ") { diff.prevMode = String(line.dropFirst(9)) }
        else if line.hasPrefix("similarity index ") { diff.type = line.hasPrefix("similarity index 100%") ? .renamePure : .renameChanged }
        else if git && line.hasPrefix("rename from ") { diff.prevName = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces) }
        else if git && line.hasPrefix("rename to ") { diff.name = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces) }
        else if line.hasPrefix("index "), let c = captures(#"^index ([0-9a-fA-F]+)\.\.([0-9a-fA-F]+)(?: (\d+))?$"#, line) { diff.prevObjectId = c[0]; diff.newObjectId = c[1]; if let mode = c[2] { diff.mode = mode } }
        i += 1
    }
    while i < lines.count {
        guard var h = parseHunkHeader(lines[i]) else {
            if throwOnError && lines[i].hasPrefix("@@") { throw DiffError.invalidPatch("Malformed hunk header") }
            i += 1; continue
        }
        h.additionLineIndex = diff.additionLines.count; h.deletionLineIndex = diff.deletionLines.count
        let declaredOld = h.deletionCount, declaredNew = h.additionCount
        let oldBoundary = h.oldBoundary, newBoundary = h.newBoundary
        var oldCount = 0, newCount = 0, last: Character?
        i += 1
        while i < lines.count && !lines[i].hasPrefix("@@ ") {
            let raw = lines[i]
            if raw.hasPrefix("--") && raw.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            guard let scalar = raw.unicodeScalars.first else { i += 1; continue }
            let char = Character(String(scalar))
            if char == "\\" {
                if last == "-" || last == " " {
                    h.noEOFCRDeletions = true
                    if !diff.deletionLines.isEmpty { let n = diff.deletionLines.count - 1; diff.deletionLines[n] = cleanLastNewline(diff.deletionLines[n]) }
                }
                if last == "+" || last == " " {
                    h.noEOFCRAdditions = true
                    if !diff.additionLines.isEmpty { let n = diff.additionLines.count - 1; diff.additionLines[n] = cleanLastNewline(diff.additionLines[n]) }
                }
                i += 1; continue
            }
            guard char == " " || char == "+" || char == "-" else {
                if oldCount >= declaredOld && newCount >= declaredNew { break }
                if throwOnError { throw DiffError.invalidPatch("Invalid hunk body line") }
                i += 1; continue
            }
            let kind: HunkContent.Kind = char == " " ? .context : .change
            if h.hunkContent.last?.type != kind {
                h.hunkContent.append(.init(type: kind, deletionLineIndex: diff.deletionLines.count, additionLineIndex: diff.additionLines.count))
            }
            let n = h.hunkContent.count - 1
            let text = parseLineType(raw)!.line
            if char != "+" { diff.deletionLines.append(text); oldCount += 1 }
            if char != "-" { diff.additionLines.append(text); newCount += 1 }
            if char == " " { h.hunkContent[n].lines += 1 }
            else if char == "-" { h.hunkContent[n].deletions += 1 }
            else { h.hunkContent[n].additions += 1 }
            last = char; i += 1
        }
        if oldCount != declaredOld || newCount != declaredNew {
            if throwOnError { throw DiffError.invalidPatch("Hunk line count mismatch") }
            h.deletionCount = oldCount; h.additionCount = newCount
            h.deletionStart = oldBoundary + (oldCount > 0 ? 1 : 0); h.additionStart = newBoundary + (newCount > 0 ? 1 : 0)
        }
        diff.hunks.append(h)
    }
    if throwOnError && !git && diff.hunks.isEmpty { throw DiffError.invalidPatch("Unified file has no hunks") }
    if !git, let prev = diff.prevName, prev != diff.name { diff.type = diff.hunks.isEmpty ? .renamePure : .renameChanged }
    if diff.type != .renamePure && diff.type != .renameChanged { diff.prevName = nil }
    recomputeGeometry(&diff); realignChangeContentBySimilarity(&diff); return diff
}

#endif

#if os(macOS)
import Foundation
import CoreText

/// Shapes wrapped fragments away from the main actor. Presentation still uses
/// fixed-height physical rows, so scrolling remains a direct destination lookup.
actor DiffWrapLayout {
    static let shared = DiffWrapLayout()
    func layout(diff: FileDiffMetadata, options: DiffRenderOptions, expandedRegions: [Int: HunkExpansionRegion], width: Double, fontName: String) throws -> DiffRenderPlan {
        try layout(plan: DiffRenderPlan(diff: diff, options: options, expandedRegions: expandedRegions), diff: diff, width: width, fontName: fontName, fontSize: options.fontSize)
    }
    func layout(plan: DiffRenderPlan, diff: FileDiffMetadata, width: Double, fontName: String, fontSize: Double) throws -> DiffRenderPlan {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        var oldRanges: [Int: [NSRange]] = [:], newRanges: [Int: [NSRange]] = [:]
        func ranges(_ text: String) -> [NSRange] {
            let text = cleanLastNewline(text)
            let length = text.utf16.count
            guard length > 0 else { return [NSRange(location: 0, length: 0)] }
            let value = CFAttributedStringCreate(nil, text as CFString, attributes)!
            let typesetter = CTTypesetterCreateWithAttributedString(value)
            var result: [NSRange] = [], start = 0
            while start < length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, max(width, 1))
                if count <= 0 { count = CTTypesetterSuggestClusterBreak(typesetter, start, max(width, 1)) }
                if count <= 0 { count = (text as NSString).rangeOfComposedCharacterSequence(at: start).length }
                result.append(NSRange(location: start, length: count)); start += count
            }
            return result
        }
        var output: [DiffRow] = []; output.reserveCapacity(plan.rows.count)
        for (position, row) in plan.rows.enumerated() {
            if position % 128 == 0 { try Task.checkCancellation() }
            guard row.kind == .context || row.kind == .change else { output.append(row); continue }
            let old: [NSRange], new: [NSRange]
            if let index = row.oldIndex {
                if let cached = oldRanges[index] { old = cached }
                else { old = ranges(diff.deletionLines[index]); oldRanges[index] = old }
            } else { old = [] }
            if let index = row.newIndex {
                if let cached = newRanges[index] { new = cached }
                else { new = ranges(diff.additionLines[index]); newRanges[index] = new }
            } else { new = [] }
            for fragment in 0..<max(old.count, new.count) {
                var physical = row; physical.isContinuation = fragment > 0
                if old.indices.contains(fragment) { physical.oldRange = old[fragment] } else { physical.oldIndex = nil; physical.oldNumber = nil }
                if new.indices.contains(fragment) { physical.newRange = new[fragment] } else { physical.newIndex = nil; physical.newNumber = nil }
                output.append(physical)
            }
        }
        return DiffRenderPlan(rows: output)
    }
}

#endif

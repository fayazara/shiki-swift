#if os(macOS)
import Foundation
import Shiki

public enum DiffOverflow: String, CaseIterable, Sendable { case scroll, wrap }
public enum DiffStyle: String, CaseIterable, Codable, Sendable { case split, unified }
public enum DiffIndicators: String, CaseIterable, Sendable { case bars, classic, none }
public enum LineDiffType: String, CaseIterable, Sendable { case wordAlt = "word-alt", word, char, none }
public enum HunkSeparators: String, CaseIterable, Sendable { case simple, metadata, lineInfo = "line-info", lineInfoBasic = "line-info-basic", custom }
public enum DiffSide: String, Codable, Sendable { case deletions, additions }
public enum ExpansionDirection: Sendable { case up, down, both }
public enum MergeConflictActionsType: String, CaseIterable, Sendable { case `default`, none, custom }
public struct HunkExpansionRegion: Codable, Equatable, Sendable {
    public var fromStart: Int
    public var fromEnd: Int
    public init(fromStart: Int = 0, fromEnd: Int = 0) { self.fromStart = fromStart; self.fromEnd = fromEnd }
    mutating func expand(_ direction: ExpansionDirection, by count: Int) {
        func adding(_ value: Int) -> Int {
            let sum = value.addingReportingOverflow(count)
            return sum.overflow ? (count >= 0 ? Int.max : Int.min) : sum.partialValue
        }
        if direction == .up || direction == .both { fromStart = adding(fromStart) }
        if direction == .down || direction == .both { fromEnd = adding(fromEnd) }
    }
}
public struct DiffRenderOptions: Equatable, Sendable {
    public var diffStyle: DiffStyle = .split
    public var diffIndicators: DiffIndicators = .bars
    public var lineDiffType: LineDiffType = .wordAlt
    public var hunkSeparators: HunkSeparators = .lineInfo
    public var mergeConflictActionsType: MergeConflictActionsType = .default
    var mergeConflictActionHeight: Double { mergeConflictActionsType == .none ? 0 : 28 }
    public var disableBackground = false
    public var disableFileHeader = false
    public var stickyHeader = false
    public var disableLineNumbers = false
    public var collapsed = false
    public var expandUnchanged = false
    public var collapsedContextThreshold = 1
    public var expansionLineCount = 100
    public var maxLineDiffLength = 1000
    public var tokenizeMaxLineLength = 1000
    public var tokenizeMaxLength = 100_000
    public var theme = "pierre-dark"
    public var overflow: DiffOverflow = .scroll
    public var fontName: String?
    public var fontSize: Double = 13
    public var lineHeight: Double = 20
    public init() {}
}
public struct LineAnnotation: Identifiable, Equatable, Sendable {
    public var id: String
    public var side: DiffSide
    /// One-based source line, or zero for an annotation above the file's first row.
    public var lineNumber: Int
    public var text: String
    public var metadata: LineAnnotationMetadata?
    public init(id: String = UUID().uuidString, side: DiffSide = .additions, lineNumber: Int, text: String, metadata: LineAnnotationMetadata? = nil) {
        self.id = id; self.side = side; self.lineNumber = lineNumber; self.text = text; self.metadata = metadata
    }
}
public struct LineSelection: Equatable, Sendable {
    public var side: DiffSide
    public var startLine: Int
    public var endLine: Int
    public var endSide: DiffSide?
    public init(side: DiffSide, startLine: Int, endLine: Int, endSide: DiffSide? = nil) { self.side = side; self.startLine = startLine; self.endLine = endLine; self.endSide = endSide }
}
/// Zero-based source lines and UTF-16 columns. Endpoints retain anchor direction.
public struct DiffTextSelection: Equatable, Sendable {
    public var side: DiffSide
    public var anchor: TextPosition
    public var head: TextPosition
    public init(side: DiffSide, anchor: TextPosition, head: TextPosition) { self.side = side; self.anchor = anchor; self.head = head }
    var ordered: (TextPosition, TextPosition) {
        anchor.line < head.line || (anchor.line == head.line && anchor.character <= head.character) ? (anchor, head) : (head, anchor)
    }
}
public struct DiffSpan: Equatable, Sendable { public var range: NSRange; public init(_ range: NSRange) { self.range = range } }
public struct InlineChanges: Sendable { public var deletions: [DiffSpan]; public var additions: [DiffSpan] }
// jsdiff 9's diffWordsWithSpace alphabet deliberately treats non-Latin letters
// as individual tokens. Keep its ECMAScript whitespace set, including BOM.
private let inlineWordRegex: NSRegularExpression = {
    let word = #"a-zA-Z0-9_\x{AD}\x{C0}-\x{D6}\x{D8}-\x{F6}\x{F8}-\x{2C6}\x{2C8}-\x{2D7}\x{2DE}-\x{2FF}\x{1E00}-\x{1EFF}"#
    let space = #"\x{9}\x{B}\x{C}\x{20}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#
    return try! NSRegularExpression(pattern: "(\\r?\\n)|[\(word)]+|[\(space)]+|[^\(word)]")
}()
public func inlineDiff(_ old: String, _ new: String, type: LineDiffType = .wordAlt, maxLength: Int = 1000) -> InlineChanges {
    let old = cleanLastNewline(old), new = cleanLastNewline(new)
    guard type != .none, old.utf16.count <= maxLength, new.utf16.count <= maxLength else { return .init(deletions: [], additions: []) }
    func words(_ s: String) -> [String] {
        if type == .char { return s.unicodeScalars.map(String.init) }
        let ns = s as NSString
        return inlineWordRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    let a = words(old), b = words(new), edits = sequenceDiff(a, b)
    var ai = 0, bi = 0
    var removed: [(Bool, String)] = [], added: [(Bool, String)] = []
    func push(_ text: String, _ neutral: Bool, _ last: Bool, into spans: inout [(Bool, String)]) {
        if type == .wordAlt, !last, let previous = spans.last,
           neutral == !previous.0 || (neutral && text.utf16.count == 1 && previous.0) {
            spans[spans.count - 1].1 += text
        } else { spans.append((!neutral, text)) }
    }
    for (index, e) in edits.enumerated() {
        let last = index == edits.count - 1
        switch e.kind {
        case .equal:
            let text = a[ai..<(ai + e.count)].joined()
            push(text, true, last, into: &removed); push(text, true, last, into: &added)
            ai += e.count; bi += e.count
        case .delete:
            push(a[ai..<(ai + e.count)].joined(), false, last, into: &removed); ai += e.count
        case .insert:
            push(b[bi..<(bi + e.count)].joined(), false, last, into: &added); bi += e.count
        }
    }
    func ranges(_ spans: [(Bool, String)]) -> [DiffSpan] {
        var offset = 0, result: [DiffSpan] = []
        for (changed, text) in spans {
            let length = text.utf16.count
            if changed { result.append(.init(NSRange(location: offset, length: length))) }; offset += length
        }
        return result
    }
    return .init(deletions: ranges(removed), additions: ranges(added))
}
public enum DiffRowKind: Equatable, Sendable { case context, change, separator(hidden: Int, hunk: Int), annotation(String), noNewline, conflictMarker(String, MergeConflictMarkerRow.Kind), editorCaret }
public struct DiffRow: Equatable, Sendable {
    public var kind: DiffRowKind
    /// Annotation values hosted by this physical row. Split rows may contain one
    /// annotation on each side; source indices remain nil for non-code rows.
    public var annotations: [LineAnnotation] = []
    public var oldIndex: Int?
    public var newIndex: Int?
    public var oldNumber: Int?
    public var newNumber: Int?
    public var hunkIndex: Int?
    public var oldRange: NSRange?
    public var newRange: NSRange?
    public var isContinuation = false
    public var conflictIndex: Int?
    public var conflictSide: DiffSide?
    /// Whether a no-newline metadata row belongs to changed rather than context text.
    public var noNewlineChanged = false
    /// Source lines represented by a collapsed-context separator.
    public var separatorIsFirst = false
    public var separatorIsLast = false
    public var hiddenOldLines: ClosedRange<Int>?
    public var hiddenNewLines: ClosedRange<Int>?
    func matchesScrollAnchor(_ anchor: DiffRow) -> Bool {
        if !anchor.annotations.isEmpty {
            return annotations.map { $0.id } == anchor.annotations.map { $0.id }
                && annotations.map { $0.side } == anchor.annotations.map { $0.side }
        }
        if anchor.oldIndex != nil || anchor.newIndex != nil {
            return oldIndex == anchor.oldIndex && newIndex == anchor.newIndex
        }
        return kind == anchor.kind && hunkIndex == anchor.hunkIndex
    }
    public init(kind: DiffRowKind, oldIndex: Int? = nil, newIndex: Int? = nil, oldNumber: Int? = nil, newNumber: Int? = nil, hunkIndex: Int? = nil) {
        self.kind = kind; self.oldIndex = oldIndex; self.newIndex = newIndex; self.oldNumber = oldNumber; self.newNumber = newNumber; self.hunkIndex = hunkIndex
    }
}
public struct DiffRenderPlan: Sendable {
    public let rows: [DiffRow]
    // Matches DiffHunksRenderer.pushSeparator: simple omits the leading gap;
    // metadata only renders when the following hunk carries patch metadata.
    private static func showsSeparator(_ diff: FileDiffMetadata, index: Int, options: DiffRenderOptions) -> Bool {
        switch options.hunkSeparators {
        case .simple: return index > 0
        case .metadata: return diff.hunks.indices.contains(index) && diff.hunks[index].hunkSpecs != nil
        case .lineInfo, .lineInfoBasic, .custom: return true
        }
    }
    // Whole-review prefix offsets need counts, not a row allocation for every
    // offscreen file. Annotated files use the full plan instead.
    static func unannotatedRowCount(_ diff: FileDiffMetadata, options: DiffRenderOptions, expandedRegions: [Int: HunkExpansionRegion]) -> Int {
        guard !options.collapsed else { return 0 }
        if diff.hunks.isEmpty { return diff.isPartial ? 0 : min(diff.deletionLines.count, diff.additionLines.count) }
        func gap(_ count: Int, _ index: Int) -> Int {
            guard count > 0 else { return 0 }
            if !diff.isPartial && (options.expandUnchanged || count <= options.collapsedContextThreshold) { return count }
            let region = expandedRegions[index] ?? .init()
            let shown = diff.isPartial ? 0 : min(count, max(0, region.fromStart) + max(0, region.fromEnd))
            return shown + (shown < count && showsSeparator(diff, index: index, options: options) ? 1 : 0)
        }
        var count = 0
        for (index, hunk) in diff.hunks.enumerated() {
            count += gap(hunk.collapsedBefore, index)
            for content in hunk.hunkContent {
                count += content.type == .context ? content.lines : options.diffStyle == .split ? max(content.additions, content.deletions) : content.additions + content.deletions
            }
            if options.diffStyle == .split {
                if hunk.noEOFCRAdditions || hunk.noEOFCRDeletions { count += 1 }
            } else { count += (hunk.noEOFCRAdditions ? 1 : 0) + (hunk.noEOFCRDeletions ? 1 : 0) }
        }
        if !diff.isPartial, let last = diff.hunks.last { count += gap(max(0, diff.additionLines.count - last.newBoundary - last.additionCount), diff.hunks.count) }
        return count
    }
    static func estimatedHeight(_ diff: FileDiffMetadata, options: DiffRenderOptions, expandedRegions: [Int: HunkExpansionRegion], annotations: [LineAnnotation] = []) -> CGFloat {
        if !annotations.isEmpty {
            return RowHeightIndex(rows: DiffRenderPlan(diff: diff, options: options, expandedRegions: expandedRegions, annotations: annotations).rows, options: options).totalHeight
        }
        let count = unannotatedRowCount(diff, options: options, expandedRegions: expandedRegions)
        guard !options.collapsed, !diff.hunks.isEmpty else { return CGFloat(count) * options.lineHeight }
        func collapsed(_ lines: Int, _ index: Int) -> Int {
            guard showsSeparator(diff, index: index, options: options) else { return 0 }
            guard lines > 0, diff.isPartial || (!options.expandUnchanged && lines > options.collapsedContextThreshold) else { return 0 }
            let region = expandedRegions[index] ?? .init()
            return diff.isPartial || region.fromStart + region.fromEnd < lines ? 1 : 0
        }
        var separators = diff.hunks.enumerated().reduce(0) { $0 + collapsed($1.element.collapsedBefore, $1.offset) }
        if !diff.isPartial, let last = diff.hunks.last {
            separators += collapsed(max(0, diff.additionLines.count - last.newBoundary - last.additionCount), diff.hunks.count)
        }
        let separatorHeight: CGFloat = options.hunkSeparators == .simple ? 4 : options.hunkSeparators == .lineInfo ? 48 : 32
        var height = CGFloat(count) * options.lineHeight + CGFloat(separators) * (separatorHeight - options.lineHeight)
        if options.hunkSeparators == .lineInfo {
            height -= CGFloat(collapsed(diff.hunks[0].collapsedBefore, 0)) * 8
            if !diff.isPartial, let last = diff.hunks.last {
                height -= CGFloat(collapsed(max(0, diff.additionLines.count - last.newBoundary - last.additionCount), diff.hunks.count)) * 8
            }
        }
        return height
    }
    init(rows: [DiffRow]) { self.rows = rows }
    public init(diff: FileDiffMetadata, options: DiffRenderOptions = .init(), expandedHunks: Set<Int> = [], expandedLineCounts: [Int: Int] = [:], expandedRegions: [Int: HunkExpansionRegion] = [:], annotations: [LineAnnotation] = [], markerRows: [MergeConflictMarkerRow] = [], canHydrateContext: Bool = false) {
        var options = options
        if !markerRows.isEmpty { options.diffStyle = .unified; options.lineDiffType = .none }
        var rows: [DiffRow] = []
        if options.collapsed { self.rows = []; return }
        let byOld = Dictionary(grouping: annotations.filter { $0.side == .deletions }, by: \.lineNumber)
        let byNew = Dictionary(grouping: annotations.filter { $0.side == .additions }, by: \.lineNumber)
        func appendAnnotations(_ old: [LineAnnotation], _ new: [LineAnnotation], hunk: Int?) {
            let groups: [[LineAnnotation]]
            if options.diffStyle == .unified { groups = (old + new).map { [$0] } }
            else {
                groups = (0..<max(old.count, new.count)).map { index in
                    (old.indices.contains(index) ? [old[index]] : []) + (new.indices.contains(index) ? [new[index]] : [])
                }
            }
            for group in groups {
                var row = DiffRow(kind: .annotation(group.map(\.text).joined(separator: "\n")), hunkIndex: hunk)
                row.annotations = group
                rows.append(row)
            }
        }
        func append(_ row: DiffRow) {
            rows.append(row)
            appendAnnotations(row.oldNumber.flatMap { byOld[$0] } ?? [], row.newNumber.flatMap { byNew[$0] } ?? [], hunk: row.hunkIndex)
            if options.diffStyle == .unified, let hi = row.hunkIndex, diff.hunks.indices.contains(hi) {
                let hunk = diff.hunks[hi]
                for side in [DiffSide.deletions, .additions] {
                    let old = side == .deletions
                    let flagged = old ? hunk.noEOFCRDeletions : hunk.noEOFCRAdditions
                    let number = old ? row.oldNumber : row.newNumber
                    let last = old ? hunk.deletionStart + hunk.deletionCount - 1 : hunk.additionStart + hunk.additionCount - 1
                    if flagged, number == last {
                        var marker = DiffRow(kind: .noNewline, oldNumber: old ? number : nil, newNumber: old ? nil : number, hunkIndex: hi)
                        marker.noNewlineChanged = row.kind == .change
                        rows.append(marker)
                    }
                }
            }
        }
        appendAnnotations(diff.type == .new ? [] : byOld[0] ?? [], diff.type == .deleted ? [] : byNew[0] ?? [], hunk: nil)
        func context(_ count: Int, _ oi: Int, _ ni: Int, _ on: Int, _ nn: Int, _ hi: Int?) {
            guard count > 0 else { return }
            for k in 0..<count { append(.init(kind: .context, oldIndex: oi + k, newIndex: ni + k, oldNumber: on + k, newNumber: nn + k, hunkIndex: hi)) }
        }
        func gap(_ count: Int, _ oi: Int, _ ni: Int, _ hi: Int) {
            guard count > 0 else { return }
            if !diff.isPartial && (options.expandUnchanged || expandedHunks.contains(hi) || count <= options.collapsedContextThreshold) {
                context(count, oi, ni, oi + 1, ni + 1, nil)
            } else {
                let region = expandedRegions[hi] ?? .init(fromStart: expandedLineCounts[hi] ?? 0)
                let start = diff.isPartial ? 0 : min(count, max(0, region.fromStart))
                let end = diff.isPartial ? 0 : min(count - start, max(0, region.fromEnd))
                if start + end >= count { context(count, oi, ni, oi + 1, ni + 1, nil) }
                else {
                    if start > 0 { context(start, oi, ni, oi + 1, ni + 1, nil) }
                    var separator = DiffRow(kind: .separator(hidden: count - start - end, hunk: hi), hunkIndex: hi)
                    separator.separatorIsFirst = hi == 0
                    separator.separatorIsLast = hi == diff.hunks.count
                    // Gap boundaries use source coordinates even when the
                    // patch omits the corresponding text from its line arrays.
                    separator.hiddenOldLines = (oi + start + 1)...(oi + count - end)
                    separator.hiddenNewLines = (ni + start + 1)...(ni + count - end)
                    if Self.showsSeparator(diff, index: hi, options: options) { rows.append(separator) }
                    if end > 0 { context(end, oi + count - end, ni + count - end, oi + count - end + 1, ni + count - end + 1, nil) }
                }
            }
        }
        if diff.hunks.isEmpty {
            if !diff.isPartial { context(min(diff.deletionLines.count, diff.additionLines.count), 0, 0, 1, 1, nil) }
            self.rows = rows; return
        }
        var oldEnd = 0, newEnd = 0
        for (hi, h) in diff.hunks.enumerated() {
            gap(h.collapsedBefore, oldEnd, newEnd, hi)
            var on = h.deletionStart, nn = h.additionStart
            for c in h.hunkContent {
                if c.type == .context { context(c.lines, c.deletionLineIndex, c.additionLineIndex, on, nn, hi) }
                else if options.diffStyle == .split {
                    for k in 0..<max(c.deletions, c.additions) {
                        append(.init(kind: .change, oldIndex: k < c.deletions ? c.deletionLineIndex + k : nil, newIndex: k < c.additions ? c.additionLineIndex + k : nil, oldNumber: k < c.deletions ? on + k : nil, newNumber: k < c.additions ? nn + k : nil, hunkIndex: hi))
                    }
                } else {
                    for k in 0..<c.deletions { append(.init(kind: .change, oldIndex: c.deletionLineIndex + k, oldNumber: on + k, hunkIndex: hi)) }
                    for k in 0..<c.additions { append(.init(kind: .change, newIndex: c.additionLineIndex + k, newNumber: nn + k, hunkIndex: hi)) }
                }
                on += c.oldCount; nn += c.newCount
            }
            if options.diffStyle == .split && (h.noEOFCRAdditions || h.noEOFCRDeletions) {
                var marker = DiffRow(kind: .noNewline, oldNumber: h.noEOFCRDeletions ? on - 1 : nil, newNumber: h.noEOFCRAdditions ? nn - 1 : nil, hunkIndex: hi)
                marker.noNewlineChanged = h.hunkContent.last?.type == .change
                rows.append(marker)
            }
            oldEnd = h.oldBoundary + h.deletionCount; newEnd = h.newBoundary + h.additionCount
        }
        if !diff.isPartial { gap(max(0, diff.additionLines.count - newEnd), oldEnd, newEnd, diff.hunks.count) }
        else if canHydrateContext && (diff.type == .change || diff.type == .renameChanged) && (options.hunkSeparators == .lineInfo || options.hunkSeparators == .lineInfoBasic || options.hunkSeparators == .custom) {
            var trailing = DiffRow(kind: .separator(hidden: 0, hunk: diff.hunks.count), hunkIndex: diff.hunks.count)
            trailing.separatorIsLast = true; rows.append(trailing)
        }
        if options.diffStyle == .unified && !markerRows.isEmpty {
            var before: [Int: [MergeConflictMarkerRow]] = [:], after: [Int: [MergeConflictMarkerRow]] = [:]
            for marker in markerRows {
                if marker.type == .end { after[marker.lineIndex, default: []].append(marker) }
                else { before[marker.lineIndex, default: []].append(marker) }
            }
            var counters: [Int: Int] = [:], decorated: [DiffRow] = []
            var activeConflict: Int?, activeSide: DiffSide?
            for row in rows {
                guard let hi = row.hunkIndex, diff.hunks.indices.contains(hi), row.kind == .context || row.kind == .change else { decorated.append(row); continue }
                let index = counters[hi] ?? diff.hunks[hi].unifiedLineStart
                for marker in before[index] ?? [] {
                    var markerRow = DiffRow(kind: .conflictMarker(cleanLastNewline(marker.lineText), marker.type), hunkIndex: hi)
                    markerRow.conflictIndex = marker.conflictIndex; decorated.append(markerRow)
                    activeConflict = marker.conflictIndex
                    activeSide = marker.type == .separator ? .additions : .deletions
                }
                var codeRow = row; codeRow.conflictIndex = activeConflict; codeRow.conflictSide = activeSide
                decorated.append(codeRow)
                for marker in after[index] ?? [] {
                    var markerRow = DiffRow(kind: .conflictMarker(cleanLastNewline(marker.lineText), marker.type), hunkIndex: hi)
                    markerRow.conflictIndex = marker.conflictIndex; decorated.append(markerRow)
                    activeConflict = nil; activeSide = nil
                }
                counters[hi] = index + 1
            }
            rows = decorated
        }
        self.rows = rows
    }
    /// Direct destination lookup. Never scans the rows between scroll positions.
    public func visibleRange(y: Double, height: Double, lineHeight: Double, overscan: Int = 8) -> Range<Int> {
        guard lineHeight > 0 else { return 0..<0 }
        let lower = min(rows.count, max(0, Int(floor(y / lineHeight)) - overscan))
        let upper = min(rows.count, max(lower, Int(ceil((y + height) / lineHeight)) + overscan))
        return lower..<upper
    }
}
public struct DiffPalette: Equatable, Sendable {
    public var addition: String
    public var deletion: String
    public var modified: String
    public var isLight: Bool
    public var editorLineHighlightBackground: String?
    public var editorLineHighlightBorder: String?
    public var editorErrorForeground: String?
    public var editorWarningForeground: String?
    public var editorInfoForeground: String?
    public var editorHintForeground: String?
    public init(addition: String = "#5ecc71", deletion: String = "#ff6762", modified: String = "#009fff", isLight: Bool = false, editorLineHighlightBackground: String? = nil, editorLineHighlightBorder: String? = nil, editorErrorForeground: String? = nil, editorWarningForeground: String? = nil, editorInfoForeground: String? = nil, editorHintForeground: String? = nil) {
        self.addition = addition; self.deletion = deletion; self.modified = modified; self.isLight = isLight
        self.editorLineHighlightBackground = editorLineHighlightBackground; self.editorLineHighlightBorder = editorLineHighlightBorder
        self.editorErrorForeground = editorErrorForeground; self.editorWarningForeground = editorWarningForeground
        self.editorInfoForeground = editorInfoForeground; self.editorHintForeground = editorHintForeground
    }
}
public struct HighlightedDiff: Sendable {
    public let id: UUID
    public let sourceID: UUID
    public let diff: FileDiffMetadata
    public let oldTokens: [[ThemedToken]]
    public let newTokens: [[ThemedToken]]
    public let oldSpans: [Int: [DiffSpan]]
    public let newSpans: [Int: [DiffSpan]]
    public let foreground: String
    public let background: String
    public let palette: DiffPalette
    public let preparationMilliseconds: Double
    public init(id: UUID = UUID(), sourceID: UUID? = nil, diff: FileDiffMetadata, oldTokens: [[ThemedToken]], newTokens: [[ThemedToken]], oldSpans: [Int: [DiffSpan]] = [:], newSpans: [Int: [DiffSpan]] = [:], foreground: String, background: String, palette: DiffPalette = .init(), preparationMilliseconds: Double = 0) {
        self.id = id; self.sourceID = sourceID ?? id; self.diff = diff
        self.oldTokens = oldTokens; self.newTokens = newTokens; self.oldSpans = oldSpans; self.newSpans = newSpans
        self.foreground = foreground; self.background = background; self.palette = palette; self.preparationMilliseconds = preparationMilliseconds
    }
}
public struct ResolvedLanguage: Sendable {
    public let name: String
    public let data: [LanguageRegistration]
    public init(name: String, data: [LanguageRegistration]) { self.name = name; self.data = data }
}

/// One serial owner for the synchronous TextMate engine; no highlighting on the main actor.
public actor DiffHighlighter {
    /// Optional process-wide reuse; callers can still create isolated highlighters.
    public static let shared = DiffHighlighter()
    public static func getSharedHighlighter(languages: [String] = [], themes: [String] = []) async throws -> DiffHighlighter {
        try await shared.preload(languages: languages, themes: themes)
        return shared
    }
    /// Reads readiness without creating Shiki or starting resource loads.
    public var isHighlighterLoaded: Bool { highlighter != nil }
    /// Releases the engine and prepared caches while preserving registrations.
    /// Work awaiting loaders is invalidated; a later explicit request can reload.
    public func disposeHighlighter() {
        guard highlighter != nil else { return }
        lifecycleGeneration = UUID()
        cleanUpResolvedLanguages(); cleanUpResolvedThemes()
        palettes.removeAll(); preparationStageMilliseconds.removeAll()
        highlighter = nil
    }
    public func getHighlighterIfLoaded(languages: [String] = [], themes: [String] = []) -> DiffHighlighter? {
        guard highlighter != nil, areLanguagesAttached(languages), areThemesAttached(themes) else { return nil }
        return self
    }

    public typealias LanguageLoader = @Sendable () async throws -> [LanguageRegistration]
    private var languageLoaders: [String: LanguageLoader] = [:]
    private var languageLoads: [String: (id: UUID, task: Task<[LanguageRegistration], any Error>)] = [:]
    public private(set) var attachedLanguages: Set<String> = []
    public private(set) var resolvedLanguages: [String: ResolvedLanguage] = [:]
    private var eagerLanguages: [String: ResolvedLanguage] = [:]
    /// Snapshot names; loaders and pending task handles remain actor-owned.
    public var registeredCustomLanguageNames: Set<String> { Set(languageLoaders.keys) }
    public var resolvingLanguageNames: Set<String> { Set(languageLoads.keys) }
    /// Registers a lazy grammar loader. Duplicate names retain the first loader.
    @discardableResult public func registerCustomLanguage(_ name: String, extensionsOrFilenames: [String] = [], loader: @escaping LanguageLoader) throws -> Bool {
        guard name != "text", name != "ansi" else { throw DiffError.invalidPatch("Reserved language name: \(name)") }
        guard languageLoaders[name] == nil else { return false }
        languageLoaders[name] = loader
        for key in extensionsOrFilenames { setCustomExtension(key, language: name) }
        return true
    }
    public func hasResolvedLanguages(_ names: [String]) -> Bool { names.allSatisfy { resolvedLanguages[$0] != nil } }
    public func areLanguagesAttached(_ names: [String]) -> Bool {
        names.allSatisfy { $0 == "text" || $0 == "ansi" || attachedLanguages.contains($0) }
    }
    public func getResolvedLanguages(_ names: [String]) throws -> [ResolvedLanguage] {
        try names.map { name in
            guard let result = resolvedLanguages[name] else { throw DiffError.invalidPatch("Language is not resolved: \(name)") }
            return result
        }
    }
    public func getResolvedOrResolveLanguage(_ name: String) async throws -> ResolvedLanguage {
        if let cached = resolvedLanguages[name] { return cached }
        return try await resolveLanguage(name)
    }
    /// Cached entries precede newly resolved entries, matching upstream ordering.
    public func resolveLanguages(_ names: [String]) async throws -> [ResolvedLanguage] {
        var result: [ResolvedLanguage] = []
        var pending: [Task<ResolvedLanguage, any Error>] = []
        for name in names where name != "text" && name != "ansi" {
            if let cached = resolvedLanguages[name] { result.append(cached) }
            else { pending.append(Task { try await self.getResolvedOrResolveLanguage(name) }) }
        }
        result += try await orderedLoadResults(pending)
        return result
    }
    public func resolveLanguage(_ name: String) async throws -> ResolvedLanguage {
        guard name != "text", name != "ansi" else { throw DiffError.invalidPatch("Language does not require grammar resolution: \(name)") }
        let pending: (id: UUID, task: Task<[LanguageRegistration], any Error>)
        if let existing = languageLoads[name] { pending = existing }
        else {
            if let loader = languageLoaders[name] {
                pending = (UUID(), Task { try await loader() })
            } else {
                try ensureHighlighter()
                let grammars = try eagerLanguages[name]?.data ?? highlighter!.assets.loadLanguageClosure(named: name)
                pending = (UUID(), Task { grammars })
            }
            languageLoads[name] = pending
        }
        do {
            let result = ResolvedLanguage(name: name, data: try await pending.task.value)
            if resolvedLanguages[name] == nil { resolvedLanguages[name] = result }
            if languageLoads[name]?.id == pending.id { languageLoads[name] = nil }
            return result
        } catch {
            if languageLoads[name]?.id == pending.id { languageLoads[name] = nil }
            throw error
        }
    }
    public func attachResolvedLanguages(_ languages: [ResolvedLanguage]) throws {
        try ensureHighlighter()
        for incoming in languages where !attachedLanguages.contains(incoming.name) {
            let value = resolvedLanguages[incoming.name] ?? incoming
            if resolvedLanguages[incoming.name] == nil { resolvedLanguages[incoming.name] = value }
            guard value.data.contains(where: { $0.name == value.name || $0.aliases?.contains(value.name) == true }) else {
                throw DiffError.invalidPatch("No returned grammar declares requested language name or alias: \(value.name)")
            }
            try highlighter!.loadLanguages(value.data)
            clearCache()
            attachedLanguages.insert(value.name)
        }
    }
    /// Like upstream, this preserves registered loaders and pending language loads.
    public func cleanUpResolvedLanguages() {
        resolvedLanguages.removeAll(); attachedLanguages.removeAll(); clearCache()
    }
    private func attachLanguage(_ name: String) async throws {
        guard !areLanguagesAttached([name]) else { return }
        let generation = lifecycleGeneration
        let value = try await getResolvedOrResolveLanguage(name)
        try checkLifecycle(generation)
        try Task.checkCancellation()
        try attachResolvedLanguages([value])
    }
    public typealias ThemeLoader = @Sendable () async throws -> ShikiTheme
    private var themeLoaders: [String: ThemeLoader] = [:]
    // Upstream registers Pierre themes at module initialization and reserves a
    // bundled fallback when first resolved. Cleanup preserves that registry.
    private var registeredThemeNames: Set<String> = ["pierre-dark", "pierre-light"]
    private var themeLoads: [String: (id: UUID, task: Task<ShikiResolvedTheme, any Error>)] = [:]
    public private(set) var attachedThemes: Set<String> = []
    public private(set) var resolvedThemes: [String: ShikiResolvedTheme] = [:]
    private var eagerThemes: [String: ShikiResolvedTheme] = [:]
    private var themeLoadGeneration = UUID()
    /// Clears custom-theme resolution state while retaining registered loaders.
    /// Existing prepared documents remain usable; new preparations load again.
    public func cleanUpResolvedThemes() {
        themeLoadGeneration = UUID()
        for pending in themeLoads.values { pending.task.cancel() }
        themeLoads.removeAll()
        for name in attachedThemes { palettes[name] = nil }
        attachedThemes.removeAll(); resolvedThemes.removeAll()
        clearCache()
    }
    @discardableResult public func registerCustomTheme(_ name: String, loader: @escaping ThemeLoader) -> Bool {
        guard registeredThemeNames.insert(name).inserted else { return false }
        themeLoaders[name] = loader
        return true
    }
    public func hasResolvedThemes(_ names: [String]) -> Bool { names.allSatisfy { resolvedThemes[$0] != nil } }
    public func areThemesAttached(_ names: [String]) -> Bool { names.allSatisfy { attachedThemes.contains($0) } }
    public func getResolvedThemes(_ names: [String]) throws -> [ShikiResolvedTheme] {
        try names.map { name in
            guard let value = resolvedThemes[name] else { throw DiffError.invalidPatch("Theme is not resolved: \(name)") }
            return value
        }
    }
    /// Resolves concurrently while preserving the requested theme order.
    public func resolveThemes(_ names: [String]) async throws -> [ShikiResolvedTheme] {
        for name in names { try prepareThemeResolution(name) }
        let pending = names.map { name in Task { try await self.resolveTheme(name) } }
        return try await orderedLoadResults(pending)
    }
    private func prepareThemeResolution(_ name: String) throws {
        guard !registeredThemeNames.contains(name) else { return }
        try ensureHighlighter()
        guard eagerThemes[name] != nil || highlighter!.assets.themeInfo(named: name) != nil else {
            throw DiffError.invalidPatch("No valid theme loader registered for: \(name)")
        }
        registeredThemeNames.insert(name)
    }
    public func resolveTheme(_ name: String) async throws -> ShikiResolvedTheme {
        try prepareThemeResolution(name)
        if let value = resolvedThemes[name] { return value }
        let generation = themeLoadGeneration
        let pending: (id: UUID, task: Task<ShikiResolvedTheme, any Error>)
        if let existing = themeLoads[name] { pending = existing }
        else {
            if let loader = themeLoaders[name] {
                pending = (UUID(), Task { normalizeTheme(try await loader()) })
            } else {
                try ensureHighlighter()
                let theme = try eagerThemes[name] ?? highlighter!.assets.loadTheme(named: name)
                pending = (UUID(), Task { theme })
            }
            themeLoads[name] = pending
        }
        do {
            let normalized = try await pending.task.value
            guard themeLoadGeneration == generation else { throw CancellationError() }
            guard normalized.name == name else { throw DiffError.invalidPatch("Resolved theme name does not match requested theme: \(name)") }
            if resolvedThemes[name] == nil { resolvedThemes[name] = normalized }
            if themeLoads[name]?.id == pending.id { themeLoads[name] = nil }
            return normalized
        } catch {
            if themeLoads[name]?.id == pending.id { themeLoads[name] = nil }
            throw error
        }
    }
    public func getResolvedOrResolveTheme(_ name: String) async throws -> ShikiResolvedTheme {
        if let value = resolvedThemes[name] { return value }
        return try await resolveTheme(name)
    }
    public func attachResolvedThemes(_ themes: [ShikiResolvedTheme]) throws {
        try ensureHighlighter()
        for theme in themes {
            guard let name = theme.name else { throw DiffError.invalidPatch("Resolved theme requires a name") }
            if attachedThemes.contains(name) { continue }
            if resolvedThemes[name] == nil { resolvedThemes[name] = theme }
            try highlighter!.registerTheme(theme)
            palettes[name] = Self.palette(colors: theme.colors, isLight: theme.type == .light)
            attachedThemes.insert(name)
        }
    }
    public func attachResolvedThemes(named names: [String]) throws { try attachResolvedThemes(getResolvedThemes(names)) }
    private func attachTheme(_ name: String) async throws {
        guard !attachedThemes.contains(name) else { return }
        let generation = lifecycleGeneration
        let value = try await resolveTheme(name)
        try checkLifecycle(generation)
        try Task.checkCancellation()
        try attachResolvedThemes([value])
    }
    private var highlighter: ShikiHighlighter?
    private var lifecycleGeneration = UUID()
    private func checkLifecycle(_ generation: UUID) throws {
        guard generation == lifecycleGeneration else { throw CancellationError() }
    }
    private struct SharedChunkKey: Equatable {
        let name: [UInt16]
        let previousName: [UInt16]?
        let language: String
        let theme: String
        let limit: Int
    }
    private var retainedSharedChunks: (key: SharedChunkKey, chunks: SharedTokenChunks)?
    private let sharedChunkCapacity: Int
    /// Lines reused from grammar-state-compatible chunks in the last preparation.
    public private(set) var sharedChunkReusedLines = 0
    /// Conservative content estimate for the separately bounded chunk cache.
    public var sharedChunkCachedBytes: Int { retainedSharedChunks?.chunks.estimatedBytes ?? 0 }
    private var tokenCache: TokenCache
    private var palettes: [String: DiffPalette] = [:]
    private var editorDocuments: [EditorTokenKey: IncrementalTokenDocument] = [:]
    private var editorDocumentOrder: [EditorTokenKey] = []
    public private(set) var editorHighlightStatistics = EditorHighlightStatistics()
    /// Stage durations from the last successful preparation, in milliseconds.
    /// Token stages include source assembly and cache lookup as well as Shiki.
    public private(set) var preparationStageMilliseconds: [String: Double] = [:]
    public init(cacheCapacityBytes: Int = 128 * 1024 * 1024, sharedChunkCacheCapacityBytes: Int = 64 * 1024 * 1024) {
        tokenCache = TokenCache(capacity: cacheCapacityBytes)
        sharedChunkCapacity = max(0, sharedChunkCacheCapacityBytes)
    }
    public var cacheStatistics: HighlightCacheStatistics { tokenCache.statistics }
    public func clearCache() { retainedSharedChunks = nil; sharedChunkReusedLines = 0; tokenCache.clear(); editorDocuments = [:]; editorDocumentOrder = []; editorHighlightStatistics = .init() }
    public func releaseEditingSession(_ session: UUID) {
        editorDocuments = editorDocuments.filter { $0.key.session != session }
        editorDocumentOrder.removeAll { $0.session == session }
        updateEditorCacheStatistics()
    }
    public func prepareForEditing(_ diff: FileDiffMetadata, session: UUID, options: DiffRenderOptions = .init()) async throws -> HighlightedDiff {
        try await prepareDocument(diff, options: options, editingSession: session)
    }
    private func updateEditorCacheStatistics() {
        editorHighlightStatistics.cachedDocuments = editorDocuments.count
        editorHighlightStatistics.estimatedBytes = editorDocuments.values.reduce(0) { $0 + $1.estimatedBytes }
    }
    private func ensureHighlighter() throws {
        guard highlighter == nil else { return }
        let engine = try ShikiHighlighter()
        for name in ["pierre-dark", "pierre-light"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json") else { throw DiffError.invalidPatch("Missing bundled theme: \(name)") }
            let theme = try JSONDecoder().decode(ShikiTheme.self, from: Data(contentsOf: url))
            try engine.registerTheme(theme)
            eagerThemes[name] = normalizeTheme(theme)
            palettes[name] = Self.palette(colors: theme.colors, isLight: theme.type == .light)
        }
        highlighter = engine
    }
    /// Resolves registered resources and retains their engine for new streams.
    /// Existing configurations remain usable after this actor is disposed.
    public func streamConfiguration(language: String, theme: String = "pierre-dark", options: TokenizeWithThemeOptions = .init(includeExplanation: .tokenType)) async throws -> StreamTokenizerConfiguration {
        let generation = lifecycleGeneration
        try Task.checkCancellation()
        try ensureHighlighter()
        try await attachTheme(theme)
        try checkLifecycle(generation)
        try await attachLanguage(language)
        try checkLifecycle(generation)
        try Task.checkCancellation()
        return .init(language: language, theme: theme, highlighter: highlighter!, palette: palettes[theme] ?? .init(), options: options)
    }
    /// A theme-correct preview while full tokenization runs. Optional prefix
    /// highlighting is capped at 256 lines and 64K UTF-16 units per complete side;
    /// partial patches remain plain. Pass sourceID to prepare to retain UI state.
    public func preparePreview(_ diff: FileDiffMetadata, options: DiffRenderOptions = .init(), highlightedLineCount: Int = 0) async throws -> HighlightedDiff {
        let generation = lifecycleGeneration
        try Task.checkCancellation()
        let started = ContinuousClock.now
        try ensureHighlighter()
        try await attachTheme(options.theme)
        try checkLifecycle(generation)
        try Task.checkCancellation()
        let colors = try highlighter!.codeToTokens("", language: "text", theme: options.theme)
        if palettes[options.theme] == nil, let theme = try? highlighter!.assets.loadTheme(named: options.theme) {
            palettes[options.theme] = Self.palette(colors: theme.colors, isLight: theme.type == .light)
        }
        var oldTokens: [[ThemedToken]] = [], newTokens: [[ThemedToken]] = []
        if highlightedLineCount > 0, !diff.isPartial,
           max(diff.deletionLines.count, diff.additionLines.count) <= options.tokenizeMaxLength {
            func prefix(_ lines: [String]) -> (source: String, count: Int) {
                var source = "", count = 0, length = 0
                for line in lines.prefix(min(highlightedLineCount, 256)) {
                    let size = line.utf16.count
                    guard size <= 65_536 - length else { break }
                    source += line; length += size; count += 1
                }
                return (source, count)
            }
            let old = prefix(diff.deletionLines), new = prefix(diff.additionLines)
            let oldLanguage = diff.lang ?? getFiletypeFromFileName(diff.prevName ?? diff.name)
            let newLanguage = diff.lang ?? getFiletypeFromFileName(diff.name)
            try await attachLanguage(oldLanguage)
            try checkLifecycle(generation)
            if newLanguage != oldLanguage { try await attachLanguage(newLanguage) }
            try checkLifecycle(generation)
            try Task.checkCancellation()
            oldTokens = Array(try highlighter!.codeToTokens(old.source, language: oldLanguage, theme: options.theme,
                options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: options.tokenizeMaxLineLength, tokenizeTimeLimit: 0)).tokens.prefix(old.count))
            if oldLanguage == newLanguage && old.source.utf16.elementsEqual(new.source.utf16) {
                newTokens = oldTokens
            } else {
                try Task.checkCancellation()
                newTokens = Array(try highlighter!.codeToTokens(new.source, language: newLanguage, theme: options.theme,
                    options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: options.tokenizeMaxLineLength, tokenizeTimeLimit: 0)).tokens.prefix(new.count))
            }
        }
        try Task.checkCancellation()
        let elapsed = started.duration(to: .now).components
        return .init(diff: diff, oldTokens: oldTokens, newTokens: newTokens, foreground: colors.fg ?? "#c9d1d9", background: colors.bg ?? "#0d1117", palette: palettes[options.theme] ?? .init(), preparationMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    }
    public func prepare(_ diff: FileDiffMetadata, options: DiffRenderOptions = .init(), sourceID: UUID? = nil) async throws -> HighlightedDiff {
        let result = try await prepareDocument(diff, options: options, editingSession: nil)
        guard let sourceID else { return result }
        return .init(id: result.id, sourceID: sourceID, diff: result.diff, oldTokens: result.oldTokens, newTokens: result.newTokens, oldSpans: result.oldSpans, newSpans: result.newSpans, foreground: result.foreground, background: result.background, palette: result.palette, preparationMilliseconds: result.preparationMilliseconds)
    }
    private func prepareDocument(_ diff: FileDiffMetadata, options: DiffRenderOptions, editingSession: UUID?) async throws -> HighlightedDiff {
        let generation = lifecycleGeneration
        try Task.checkCancellation()
        let started = ContinuousClock.now
        editorHighlightStatistics.retokenizedLines = 0; editorHighlightStatistics.reusedLines = 0
        try ensureHighlighter()
        try await attachTheme(options.theme)
        try checkLifecycle(generation)
        let highlighter = highlighter!
        if palettes[options.theme] == nil, let theme = try? highlighter.assets.loadTheme(named: options.theme) {
            palettes[options.theme] = Self.palette(colors: theme.colors, isLight: theme.type == .light)
        }
        let massive = max(diff.deletionLines.count, diff.additionLines.count) > options.tokenizeMaxLength
        let oldLanguage = massive ? "text" : diff.lang ?? getFiletypeFromFileName(diff.prevName ?? diff.name)
        let newLanguage = massive ? "text" : diff.lang ?? getFiletypeFromFileName(diff.name)
        try await attachLanguage(oldLanguage)
        try checkLifecycle(generation)
        if newLanguage != oldLanguage { try await attachLanguage(newLanguage) }
        try checkLifecycle(generation)
        let setupFinished = ContinuousClock.now
        let identicalSides = editingSession == nil && !diff.isPartial && oldLanguage == newLanguage
            && diff.deletionLines.count == diff.additionLines.count
            && zip(diff.deletionLines, diff.additionLines).allSatisfy { $0.utf16.elementsEqual($1.utf16) }
        sharedChunkReusedLines = 0
        let sharedChunks: SharedTokenChunks?
        if editingSession == nil, !diff.isPartial, oldLanguage == newLanguage,
           oldLanguage != "ansi", oldLanguage != "text", diff.deletionLines.count >= 256 {
            let key = SharedChunkKey(name: Array(diff.name.utf16), previousName: diff.prevName.map { Array($0.utf16) },
                                     language: oldLanguage, theme: options.theme, limit: options.tokenizeMaxLineLength)
            if retainedSharedChunks?.key != key {
                retainedSharedChunks = (key, SharedTokenChunks(capacityBytes: sharedChunkCapacity))
            }
            sharedChunks = retainedSharedChunks?.chunks
        } else { sharedChunks = nil }
        func highlight(_ lines: [String], language: String) throws -> TokensResult {
            try Task.checkCancellation()
            let source = lines.joined()
            let key = TokenCache.key(source, language: language, theme: options.theme, maxLineLength: options.tokenizeMaxLineLength)
            if let cached = tokenCache.get(key, source: source) { return cached }
            let result: TokensResult
            if let sharedChunks {
                result = try sharedChunks.highlight(source, engine: highlighter, language: language, theme: options.theme, limit: options.tokenizeMaxLineLength)
                sharedChunkReusedLines += sharedChunks.reusedLines
            } else {
                result = try highlighter.codeToTokens(source, language: language, theme: options.theme, options: .init(includeExplanation: .tokenType, tokenizeMaxLineLength: options.tokenizeMaxLineLength, tokenizeTimeLimit: 0))
            }
            try Task.checkCancellation()
            tokenCache.insert(result, key: key, source: source)
            return result
        }
        func highlightSide(_ side: DiffSide, language: String) throws -> TokensResult {
            let lines = side == .deletions ? diff.deletionLines : diff.additionLines
            if let editingSession, !diff.isPartial {
                let key = EditorTokenKey(session: editingSession, side: side.rawValue, language: language, theme: options.theme, limit: options.tokenizeMaxLineLength)
                var existing = editorDocuments[key]
                if existing == nil, side == .additions, oldLanguage == newLanguage,
                   diff.deletionLines.count == lines.count, zip(diff.deletionLines, lines).allSatisfy({ $0.utf16.elementsEqual($1.utf16) }) {
                    var oldKey = key; oldKey.side = DiffSide.deletions.rawValue
                    existing = editorDocuments[oldKey]?.copy()
                }
                let document = existing ?? IncrementalTokenDocument()
                let result = try document.update(source: lines.joined(), engine: highlighter, language: language, theme: options.theme, maxLineLength: options.tokenizeMaxLineLength)
                editorDocuments[key] = document
                editorDocumentOrder.removeAll { $0 == key }; editorDocumentOrder.append(key)
                editorHighlightStatistics.retokenizedLines += document.retokenizedLines
                editorHighlightStatistics.reusedLines += document.reusedLines
                updateEditorCacheStatistics()
                while editorDocuments.count > 8 || editorHighlightStatistics.estimatedBytes > 64 * 1024 * 1024 {
                    editorDocuments.removeValue(forKey: editorDocumentOrder.removeFirst()); updateEditorCacheStatistics()
                }
                return result
            }
            guard diff.isPartial, diff.hunks.count > 1 else { return try highlight(lines, language: language) }
            // Omitted source may contain an unmatched closing delimiter. Like
            // upstream's per-hunk buckets, do not carry grammar state over gaps.
            var result = try highlight([], language: "text")
            result.tokens = Array(repeating: [], count: lines.count)
            for hunk in diff.hunks {
                try Task.checkCancellation()
                let start = side == .deletions ? hunk.deletionLineIndex : hunk.additionLineIndex
                let count = side == .deletions ? hunk.deletionCount : hunk.additionCount
                guard count > 0 else { continue }
                let bucket = try highlight(Array(lines[start..<(start + count)]), language: language)
                for index in 0..<min(count, bucket.tokens.count) { result.tokens[start + index] = bucket.tokens[index] }
            }
            return result
        }
        let a = try highlightSide(.deletions, language: oldLanguage)
        let oldFinished = ContinuousClock.now
        try Task.checkCancellation()
        let b = identicalSides ? a : try highlightSide(.additions, language: newLanguage)
        let newFinished = ContinuousClock.now
        var oldSpans: [Int: [DiffSpan]] = [:], newSpans: [Int: [DiffSpan]] = [:]
        for h in diff.hunks {
            try Task.checkCancellation()
            for c in h.hunkContent where c.type == .change {
                for k in 0..<min(c.deletions, c.additions) {
                    let oi = c.deletionLineIndex + k, ni = c.additionLineIndex + k
                    let spans = inlineDiff(diff.deletionLines[oi], diff.additionLines[ni], type: options.lineDiffType, maxLength: options.maxLineDiffLength)
                    oldSpans[oi] = spans.deletions; newSpans[ni] = spans.additions
                }
            }
        }
        let finished = ContinuousClock.now
        func milliseconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
            let duration = from.duration(to: to).components
            return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        }
        preparationStageMilliseconds = ["setup": milliseconds(started, setupFinished),
            "oldTokens": milliseconds(setupFinished, oldFinished),
            "newTokens": milliseconds(oldFinished, newFinished),
            "inlineDiff": milliseconds(newFinished, finished)]
        let elapsed = started.duration(to: finished).components
        return .init(id: UUID(), diff: diff, oldTokens: a.tokens, newTokens: b.tokens, oldSpans: oldSpans, newSpans: newSpans, foreground: b.fg ?? "#c9d1d9", background: b.bg ?? "#0d1117", palette: palettes[options.theme] ?? .init(), preparationMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    }
    public func registerTheme(_ theme: ShikiTheme) throws {
        try ensureHighlighter()
        try highlighter!.registerTheme(theme)
        let normalized = normalizeTheme(theme)
        if let name = normalized.name {
            eagerThemes[name] = normalized; resolvedThemes[name] = normalized; attachedThemes.insert(name)
            palettes[name] = Self.palette(colors: normalized.colors, isLight: normalized.type == .light)
        }
        clearCache()
    }
    public func registerLanguage(_ language: LanguageRegistration) throws {
        try ensureHighlighter()
        try highlighter!.registerLanguage(language)
        for name in [language.name] + (language.aliases ?? []) {
            let value = ResolvedLanguage(name: name, data: [language])
            eagerLanguages[name] = value; resolvedLanguages[name] = value; attachedLanguages.insert(name)
        }
        clearCache()
    }
    public func preload(languages: [String] = [], themes: [String] = []) async throws {
        let generation = lifecycleGeneration
        try ensureHighlighter()
        var languageTasks: [Task<ResolvedLanguage, any Error>] = []
        var themeTasks: [Task<ShikiResolvedTheme, any Error>] = []
        var seen: Set<[UInt16]> = []
        let uniqueLanguages = languages.filter { seen.insert(Array($0.utf16)).inserted && $0 != "text" && $0 != "ansi" }
        for language in uniqueLanguages {
            if let cached = resolvedLanguages[language] { try attachResolvedLanguages([cached]) }
            else { languageTasks.append(Task { try await self.getResolvedOrResolveLanguage(language) }) }
        }
        for theme in themes {
            if let cached = resolvedThemes[theme] { try attachResolvedThemes([cached]) }
            else { themeTasks.append(Task { try await self.resolveTheme(theme) }) }
        }
        let languageGroup = Task {
            let resolved = try await orderedLoadResults(languageTasks)
            try checkLifecycle(generation)
            try attachResolvedLanguages(resolved)
            for language in uniqueLanguages { _ = try highlighter!.codeToTokens("", language: language, theme: "pierre-dark") }
        }
        let themeGroup = Task {
            let resolved = try await orderedLoadResults(themeTasks)
            try checkLifecycle(generation)
            try attachResolvedThemes(resolved)
            for theme in themes { _ = try highlighter!.codeToTokens("", language: "text", theme: theme) }
        }
        _ = try await orderedLoadResults([languageGroup, themeGroup])
    }
    nonisolated static func palette(colors: [String: String]?, isLight: Bool) -> DiffPalette {
        .init(addition: colors?["gitDecoration.addedResourceForeground"] ?? colors?["terminal.ansiGreen"] ?? (isLight ? "#0dbe4e" : "#5ecc71"),
              deletion: colors?["gitDecoration.deletedResourceForeground"] ?? colors?["terminal.ansiRed"] ?? (isLight ? "#ff2e3f" : "#ff6762"),
              modified: colors?["gitDecoration.modifiedResourceForeground"] ?? colors?["terminal.ansiBlue"] ?? "#009fff", isLight: isLight, editorLineHighlightBackground: colors?["editor.lineHighlightBackground"], editorLineHighlightBorder: colors?["editor.lineHighlightBorder"], editorErrorForeground: colors?["editorError.foreground"], editorWarningForeground: colors?["editorWarning.foreground"], editorInfoForeground: colors?["editorInfo.foreground"], editorHintForeground: colors?["editorHint.foreground"])
    }
}
public extension DiffHighlighter {
    func prepare(oldFile: FileContents?, newFile: FileContents?, diffOptions: DiffOptions = .init(), options: DiffRenderOptions = .init()) async throws -> HighlightedDiff {
        try await prepare(parseDiffFromFile(oldFile, newFile, options: diffOptions), options: options)
    }
}

public extension DiffHighlighter {
    func resolve(_ diff: FileDiffMetadata, hunkIndex: Int, resolution: DiffResolution, options: DiffRenderOptions = .init()) async throws -> HighlightedDiff {
        try await prepare(diffAcceptRejectHunk(diff, hunkIndex: hunkIndex, resolution: resolution), options: options)
    }
}

#endif

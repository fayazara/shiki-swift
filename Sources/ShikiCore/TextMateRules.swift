/*---------------------------------------------------------
 * Copyright (C) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------*/

import Foundation

/// A compiled TextMate rule identifier. Positive identifiers are allocated by
/// a rule registry; negative identifiers are reserved for synthetic patterns.
public typealias RuleID = Int

/// The synthetic identifier emitted when a begin/end rule's end pattern wins.
public let endRuleID: RuleID = -1

/// The synthetic identifier emitted when a begin/while rule's while pattern wins.
public let whileRuleID: RuleID = -2

/// Compatibility spelling matching `vscode-textmate`'s exported constant.
public let endRuleId = endRuleID

/// Compatibility spelling matching `vscode-textmate`'s exported constant.
public let whileRuleId = whileRuleID

public func ruleID(from number: Int) -> RuleID { number }
public func number(from ruleID: RuleID) -> Int { ruleID }

public enum TextMateRuleError: Error, Equatable, CustomStringConvertible {
    case missingRule(RuleID)
    case missingResolvedEndPattern
    case unsupportedCaptureRuleOperation
    case disposedCompiledRule
    case invalidScannerPatternIndex(Int)

    public var description: String {
        switch self {
        case let .missingRule(ruleID):
            "No compiled TextMate rule is registered for id \(ruleID)"
        case .missingResolvedEndPattern:
            "A begin/end rule with back references requires a resolved end pattern"
        case .unsupportedCaptureRuleOperation:
            "Capture rules cannot be collected or compiled directly"
        case .disposedCompiledRule:
            "The compiled TextMate rule has been disposed"
        case let .invalidScannerPatternIndex(index):
            "The Oniguruma scanner returned invalid pattern index \(index)"
        }
    }
}

/// Scanner surface used by the TextMate compiler. The native scanner conforms,
/// while the protocol also permits deterministic scanner doubles in tests.
public protocol TextMateOnigScanner: AnyObject {
    func findNextMatchSync(
        _ string: String,
        startPosition: Int,
        options: OnigFindOptions
    ) throws -> OnigMatch?

    func findNextMatchSync(
        _ string: OnigString,
        startPosition: Int,
        options: OnigFindOptions
    ) throws -> OnigMatch?

    func dispose()
}

extension OnigScanner: TextMateOnigScanner {
    /// `OnigScanner` owns its native handle through ARC. `CompiledRule` drops
    /// its final strong reference immediately after invoking this hook.
    public func dispose() {}
}

/// Oniguruma construction required by compiled TextMate rules.
public protocol TextMateOnigLibrary {
    func createOnigScanner(_ sources: [String]) throws -> any TextMateOnigScanner
    func createOnigString(_ string: String) -> OnigString
}

public extension TextMateOnigLibrary {
    func createOnigString(_ string: String) -> OnigString {
        OnigString(string)
    }
}

/// Default adapter backed by this package's native Oniguruma build.
public struct NativeTextMateOnigLibrary: TextMateOnigLibrary, Sendable {
    public init() {}

    public func createOnigScanner(_ sources: [String]) throws -> any TextMateOnigScanner {
        try OnigScanner(patterns: sources)
    }
}

/// Registry contract consumed while flattening nested rules into scanner patterns.
///
/// `rule(with:)` is optional because a recursively referenced descriptor can be
/// observed while its registration closure is still being evaluated. This is
/// the same transient state used by `vscode-textmate`'s JavaScript registry.
public protocol TextMateRuleRegistry: AnyObject {
    func rule(with ruleID: RuleID) -> Rule?
    func registerRule(_ factory: (RuleID) -> Rule) -> Rule
}

/// External grammar lookup used by top-level include references.
public protocol TextMateGrammarRegistry: AnyObject {
    func externalGrammar(
        scopeName: String,
        repository: RawRepository
    ) -> RawGrammar?
}

public protocol TextMateRuleFactoryHelper:
    TextMateRuleRegistry, TextMateGrammarRegistry {}

public protocol TextMateRuleCompilerContext:
    TextMateRuleRegistry, TextMateOnigLibrary {}

public enum IncludeReference: Equatable, Sendable {
    case base
    case selfReference
    case relative(ruleName: String)
    case topLevel(scopeName: String)
    case topLevelRepository(scopeName: String, ruleName: String)
}

/// Parses the five include forms accepted by TextMate grammars.
public func parseInclude(_ include: String) -> IncludeReference {
    if include == "$base" {
        return .base
    }
    if include == "$self" {
        return .selfReference
    }

    guard let sharp = include.firstIndex(of: "#") else {
        return .topLevel(scopeName: include)
    }
    if sharp == include.startIndex {
        return .relative(ruleName: String(include[include.index(after: sharp)...]))
    }
    return .topLevelRepository(
        scopeName: String(include[..<sharp]),
        ruleName: String(include[include.index(after: sharp)...])
    )
}

/// Scope-name capture expansion from `vscode-textmate`'s `RegexSource` utility.
public enum RegexSource {
    public static func hasCaptures(_ source: String?) -> Bool {
        guard let source else { return false }
        let units = Array(source.utf16)
        var index = 0
        while index < units.count {
            guard units[index] == asciiDollar else {
                index += 1
                continue
            }
            if index + 1 < units.count, isASCIIDigit(units[index + 1]) {
                return true
            }
            if captureCommandEnd(in: units, startingAt: index) != nil {
                return true
            }
            index += 1
        }
        return false
    }

    public static func replaceCaptures(
        _ source: String,
        captureSource: String,
        captureIndices: [OnigCaptureIndex]
    ) -> String {
        let units = Array(source.utf16)
        var result: [UInt16] = []
        result.reserveCapacity(units.count)
        var cursor = 0

        while cursor < units.count {
            guard units[cursor] == asciiDollar else {
                result.append(units[cursor])
                cursor += 1
                continue
            }

            var matchEnd: Int?
            var captureNumber: Int?
            var command: CaptureCommand?

            if cursor + 1 < units.count, isASCIIDigit(units[cursor + 1]) {
                var end = cursor + 2
                while end < units.count, isASCIIDigit(units[end]) { end += 1 }
                captureNumber = decimalInteger(units[(cursor + 1)..<end])
                matchEnd = end
            } else if let parsed = captureCommandEnd(in: units, startingAt: cursor) {
                captureNumber = parsed.capture
                command = parsed.command
                matchEnd = parsed.end
            }

            guard
                let end = matchEnd,
                let captureNumber,
                captureIndices.indices.contains(captureNumber)
            else {
                result.append(units[cursor])
                cursor += 1
                continue
            }

            let capture = captureIndices[captureNumber]
            var replacement = javascriptSubstring(
                captureSource,
                start: capture.start,
                end: capture.end
            )
            while replacement.utf16.first == asciiDot {
                replacement = String(replacement.dropFirst())
            }
            switch command {
            case .downcase:
                replacement = replacement.lowercased()
            case .upcase:
                replacement = replacement.uppercased()
            case nil:
                break
            }
            result.append(contentsOf: replacement.utf16)
            cursor = end
        }

        return String(decoding: result, as: UTF16.self)
    }
}

private enum CaptureCommand {
    case downcase
    case upcase
}

private let asciiDollar = UInt16(0x24)
private let asciiDot = UInt16(0x2E)

private func isASCIIDigit(_ unit: UInt16) -> Bool {
    unit >= 0x30 && unit <= 0x39
}

private func decimalInteger(_ units: ArraySlice<UInt16>) -> Int? {
    var value = 0
    guard !units.isEmpty else { return nil }
    for unit in units {
        guard isASCIIDigit(unit) else { return nil }
        let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
        let (added, addOverflow) = multiplied.addingReportingOverflow(Int(unit - 0x30))
        guard !multiplyOverflow, !addOverflow else { return nil }
        value = added
    }
    return value
}

private func captureCommandEnd(
    in units: [UInt16],
    startingAt start: Int
) -> (capture: Int, command: CaptureCommand, end: Int)? {
    // ${12:/downcase} and ${12:/upcase}
    guard
        start + 5 < units.count,
        units[start] == asciiDollar,
        units[start + 1] == 0x7B
    else { return nil }

    var cursor = start + 2
    let digitStart = cursor
    while cursor < units.count, isASCIIDigit(units[cursor]) { cursor += 1 }
    guard
        cursor > digitStart,
        cursor + 2 < units.count,
        units[cursor] == 0x3A,
        units[cursor + 1] == 0x2F
    else { return nil }
    let capture = decimalInteger(units[digitStart..<cursor])
    cursor += 2

    let downcase = Array("downcase".utf16)
    let upcase = Array("upcase".utf16)
    let command: CaptureCommand
    if units[cursor...].starts(with: downcase) {
        command = .downcase
        cursor += downcase.count
    } else if units[cursor...].starts(with: upcase) {
        command = .upcase
        cursor += upcase.count
    } else {
        return nil
    }

    guard cursor < units.count, units[cursor] == 0x7D, let capture else {
        return nil
    }
    return (capture, command, cursor + 1)
}

private func javascriptSubstring(_ source: String, start: Int, end: Int) -> String {
    let units = Array(source.utf16)
    var lower = min(max(0, start), units.count)
    var upper = min(max(0, end), units.count)
    if lower > upper { swap(&lower, &upper) }
    return String(decoding: units[lower..<upper], as: UTF16.self)
}

private func escapeRegExpCharacters(_ value: String) -> String {
    let punctuation = CharacterSet(charactersIn: "-\\{}*+?|^$.,[]()#")
    var result = ""
    result.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
        let shouldEscape = punctuation.contains(scalar)
            || isJavaScriptRegExpWhitespace(scalar.value)
        if shouldEscape { result.append("\\") }
        result.unicodeScalars.append(scalar)
    }
    return result
}

private func isJavaScriptRegExpWhitespace(_ scalar: UInt32) -> Bool {
    switch scalar {
    case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        true
    default:
        false
    }
}

private func hasNumericBackReference(_ source: String) -> Bool {
    let units = Array(source.utf16)
    guard units.count > 1 else { return false }
    for index in 0..<(units.count - 1) {
        if units[index] == 0x5C, isASCIIDigit(units[index + 1]) {
            return true
        }
    }
    return false
}

private func resolveNumericBackReferences(
    in source: String,
    lineText: String,
    captureIndices: [OnigCaptureIndex]
) -> String {
    let capturedValues = captureIndices.map {
        javascriptSubstring(lineText, start: $0.start, end: $0.end)
    }
    let units = Array(source.utf16)
    var result: [UInt16] = []
    result.reserveCapacity(units.count)
    var cursor = 0

    while cursor < units.count {
        guard
            units[cursor] == 0x5C,
            cursor + 1 < units.count,
            isASCIIDigit(units[cursor + 1])
        else {
            result.append(units[cursor])
            cursor += 1
            continue
        }

        var end = cursor + 2
        while end < units.count, isASCIIDigit(units[end]) { end += 1 }
        let captureNumber = decimalInteger(units[(cursor + 1)..<end])
        let captured = captureNumber.flatMap { capturedValues.indices.contains($0) ? capturedValues[$0] : nil } ?? ""
        result.append(contentsOf: escapeRegExpCharacters(captured).utf16)
        cursor = end
    }

    return String(decoding: result, as: UTF16.self)
}

private struct RegExpSourceAnchorCache {
    let a0g0: String
    let a0g1: String
    let a1g0: String
    let a1g1: String
}

/// A single scanner source paired with the rule identifier it emits.
public final class RegExpSource {
    public private(set) var source: String
    public let ruleID: RuleID
    public private(set) var hasAnchor: Bool
    public let hasBackReferences: Bool

    private var anchorCache: RegExpSourceAnchorCache?

    public init(_ regExpSource: String, ruleID: RuleID) {
        let units = Array(regExpSource.utf16)
        var output: [UInt16] = []
        var lastPushedPosition = 0
        var foundAnchor = false
        var position = 0

        while position < units.count {
            if units[position] == 0x5C, position + 1 < units.count {
                let next = units[position + 1]
                if next == 0x7A { // z
                    output.append(contentsOf: units[lastPushedPosition..<position])
                    output.append(contentsOf: "$(?!\\n)(?<!\\n)".utf16)
                    lastPushedPosition = position + 2
                } else if next == 0x41 || next == 0x47 { // A or G
                    foundAnchor = true
                }
                position += 2
            } else {
                position += 1
            }
        }

        hasAnchor = foundAnchor
        if lastPushedPosition == 0 {
            source = regExpSource
        } else {
            output.append(contentsOf: units[lastPushedPosition..<units.count])
            source = String(decoding: output, as: UTF16.self)
        }
        self.ruleID = ruleID
        hasBackReferences = hasNumericBackReference(source)
        anchorCache = foundAnchor ? Self.buildAnchorCache(source) : nil
    }

    public func clone() -> RegExpSource {
        RegExpSource(source, ruleID: ruleID)
    }

    public func setSource(_ newSource: String) {
        guard source != newSource else { return }
        source = newSource
        if hasAnchor {
            anchorCache = Self.buildAnchorCache(source)
        }
    }

    public func resolveBackReferences(
        lineText: String,
        captureIndices: [OnigCaptureIndex]
    ) -> String {
        resolveNumericBackReferences(
            in: source,
            lineText: lineText,
            captureIndices: captureIndices
        )
    }

    public func resolveAnchors(allowA: Bool, allowG: Bool) -> String {
        guard hasAnchor, let anchorCache else { return source }
        return switch (allowA, allowG) {
        case (false, false): anchorCache.a0g0
        case (false, true): anchorCache.a0g1
        case (true, false): anchorCache.a1g0
        case (true, true): anchorCache.a1g1
        }
    }

    private static func buildAnchorCache(_ source: String) -> RegExpSourceAnchorCache {
        let units = Array(source.utf16)
        var a0g0 = units
        var a0g1 = units
        var a1g0 = units
        var a1g1 = units
        var position = 0

        while position < units.count {
            guard units[position] == 0x5C, position + 1 < units.count else {
                position += 1
                continue
            }
            switch units[position + 1] {
            case 0x41: // A
                a0g0[position + 1] = 0xFFFF
                a0g1[position + 1] = 0xFFFF
                a1g0[position + 1] = 0x41
                a1g1[position + 1] = 0x41
            case 0x47: // G
                a0g0[position + 1] = 0xFFFF
                a0g1[position + 1] = 0x47
                a1g0[position + 1] = 0xFFFF
                a1g1[position + 1] = 0x47
            default:
                break
            }
            position += 2
        }

        return RegExpSourceAnchorCache(
            a0g0: String(decoding: a0g0, as: UTF16.self),
            a0g1: String(decoding: a0g1, as: UTF16.self),
            a1g0: String(decoding: a1g0, as: UTF16.self),
            a1g1: String(decoding: a1g1, as: UTF16.self)
        )
    }
}

private struct AnchorCombination: Hashable {
    let allowA: Bool
    let allowG: Bool
}

/// Mutable scanner-source collection with the same four-way anchor cache as
/// `vscode-textmate`.
public final class RegExpSourceList {
    private var items: [RegExpSource] = []
    private var hasAnchors = false
    private var cached: CompiledRule?
    private var anchorCache: [AnchorCombination: CompiledRule] = [:]

    public init() {}

    public var count: Int { items.count }

    public func dispose() {
        cached?.dispose()
        cached = nil
        for compiled in anchorCache.values { compiled.dispose() }
        anchorCache.removeAll(keepingCapacity: false)
    }

    public func push(_ item: RegExpSource) {
        items.append(item)
        hasAnchors = hasAnchors || item.hasAnchor
    }

    public func unshift(_ item: RegExpSource) {
        items.insert(item, at: 0)
        hasAnchors = hasAnchors || item.hasAnchor
    }

    public func setSource(at index: Int, to newSource: String) {
        guard items[index].source != newSource else { return }
        dispose()
        items[index].setSource(newSource)
    }

    public func compile(_ onigLibrary: any TextMateOnigLibrary) throws -> CompiledRule {
        if let cached { return cached }
        let compiled = try CompiledRule(
            onigLibrary: onigLibrary,
            regularExpressions: items.map(\.source),
            ruleIDs: items.map(\.ruleID)
        )
        cached = compiled
        return compiled
    }

    public func compileAG(
        _ onigLibrary: any TextMateOnigLibrary,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule {
        guard hasAnchors else { return try compile(onigLibrary) }
        let key = AnchorCombination(allowA: allowA, allowG: allowG)
        if let compiled = anchorCache[key] { return compiled }
        let compiled = try CompiledRule(
            onigLibrary: onigLibrary,
            regularExpressions: items.map {
                $0.resolveAnchors(allowA: allowA, allowG: allowG)
            },
            ruleIDs: items.map(\.ruleID)
        )
        anchorCache[key] = compiled
        return compiled
    }
}

public struct FindNextMatchResult: Equatable, Sendable {
    public let ruleID: RuleID
    public let captureIndices: [OnigCaptureIndex]

    public init(ruleID: RuleID, captureIndices: [OnigCaptureIndex]) {
        self.ruleID = ruleID
        self.captureIndices = captureIndices
    }
}

/// A scanner plus its position-to-rule mapping.
public final class CompiledRule: CustomStringConvertible {
    public let regularExpressions: [String]
    public let ruleIDs: [RuleID]

    private var scanner: (any TextMateOnigScanner)?

    public init(
        onigLibrary: any TextMateOnigLibrary,
        regularExpressions: [String],
        ruleIDs: [RuleID]
    ) throws {
        self.regularExpressions = regularExpressions
        self.ruleIDs = ruleIDs
        scanner = try onigLibrary.createOnigScanner(regularExpressions)
    }

    deinit { dispose() }

    public func dispose() {
        guard let scanner else { return }
        scanner.dispose()
        self.scanner = nil
    }

    public var description: String {
        zip(ruleIDs, regularExpressions)
            .map { "   - \($0): \($1)" }
            .joined(separator: "\n")
    }

    public func findNextMatchSync(
        _ string: String,
        startPosition: Int,
        options: OnigFindOptions = []
    ) throws -> FindNextMatchResult? {
        guard let scanner else { throw TextMateRuleError.disposedCompiledRule }
        return try mapMatch(
            scanner.findNextMatchSync(
                string,
                startPosition: startPosition,
                options: options
            )
        )
    }

    public func findNextMatchSync(
        _ string: OnigString,
        startPosition: Int,
        options: OnigFindOptions = []
    ) throws -> FindNextMatchResult? {
        guard let scanner else { throw TextMateRuleError.disposedCompiledRule }
        return try mapMatch(
            scanner.findNextMatchSync(
                string,
                startPosition: startPosition,
                options: options
            )
        )
    }

    private func mapMatch(_ match: OnigMatch?) throws -> FindNextMatchResult? {
        guard let match else { return nil }
        guard ruleIDs.indices.contains(match.index) else {
            throw TextMateRuleError.invalidScannerPatternIndex(match.index)
        }
        return FindNextMatchResult(
            ruleID: ruleIDs[match.index],
            captureIndices: match.captureIndices
        )
    }
}

/// Base class for all compiled TextMate rule kinds.
public class Rule {
    public let location: TextMateLocation?
    public let id: RuleID

    private let nameIsCapturing: Bool
    private let name: String?
    private let contentNameIsCapturing: Bool
    private let contentName: String?

    public init(
        location: TextMateLocation?,
        id: RuleID,
        name: String?,
        contentName: String?
    ) {
        self.location = location
        self.id = id
        self.name = name.flatMap { $0.isEmpty ? nil : $0 }
        nameIsCapturing = RegexSource.hasCaptures(self.name)
        self.contentName = contentName.flatMap { $0.isEmpty ? nil : $0 }
        contentNameIsCapturing = RegexSource.hasCaptures(self.contentName)
    }

    public var debugName: String {
        let sourceLocation: String
        if let location {
            sourceLocation = "\(textMateBasename(location.filename ?? "unknown")):\(location.line)"
        } else {
            sourceLocation = "unknown"
        }
        return "\(String(describing: type(of: self)))#\(id) @ \(sourceLocation)"
    }

    public func getName(
        lineText: String?,
        captureIndices: [OnigCaptureIndex]?
    ) -> String? {
        guard
            nameIsCapturing,
            let name,
            let lineText,
            let captureIndices
        else { return name }
        return RegexSource.replaceCaptures(
            name,
            captureSource: lineText,
            captureIndices: captureIndices
        )
    }

    public func getContentName(
        lineText: String,
        captureIndices: [OnigCaptureIndex]
    ) -> String? {
        guard contentNameIsCapturing, let contentName else { return contentName }
        return RegexSource.replaceCaptures(
            contentName,
            captureSource: lineText,
            captureIndices: captureIndices
        )
    }

    public func dispose() {}

    public func collectPatterns(
        _ grammar: any TextMateRuleRegistry,
        into output: RegExpSourceList
    ) throws {
        preconditionFailure("Rule subclasses must implement collectPatterns")
    }

    public func compile(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?
    ) throws -> CompiledRule {
        preconditionFailure("Rule subclasses must implement compile")
    }

    public func compileAG(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule {
        preconditionFailure("Rule subclasses must implement compileAG")
    }
}

private func textMateBasename(_ path: String) -> String {
    var path = path
    while path.count > 1, path.last == "/" || path.last == "\\" {
        path.removeLast()
    }
    if let separator = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
        return String(path[path.index(after: separator)...])
    }
    return path
}

public final class CaptureRule: Rule {
    /// Zero means the capture is not retokenized.
    public let retokenizeCapturedWithRuleID: RuleID

    public init(
        location: TextMateLocation?,
        id: RuleID,
        name: String?,
        contentName: String?,
        retokenizeCapturedWithRuleID: RuleID
    ) {
        self.retokenizeCapturedWithRuleID = retokenizeCapturedWithRuleID
        super.init(location: location, id: id, name: name, contentName: contentName)
    }

    public override func collectPatterns(
        _ grammar: any TextMateRuleRegistry,
        into output: RegExpSourceList
    ) throws {
        throw TextMateRuleError.unsupportedCaptureRuleOperation
    }

    public override func compile(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?
    ) throws -> CompiledRule {
        throw TextMateRuleError.unsupportedCaptureRuleOperation
    }

    public override func compileAG(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule {
        throw TextMateRuleError.unsupportedCaptureRuleOperation
    }
}

public final class MatchRule: Rule {
    private let matchSource: RegExpSource
    public let captures: [CaptureRule?]
    private var cachedCompiledPatterns: RegExpSourceList?

    public init(
        location: TextMateLocation?,
        id: RuleID,
        name: String?,
        match: String,
        captures: [CaptureRule?]
    ) {
        matchSource = RegExpSource(match, ruleID: id)
        self.captures = captures
        super.init(location: location, id: id, name: name, contentName: nil)
    }

    public var debugMatchRegExp: String { matchSource.source }

    public override func dispose() {
        cachedCompiledPatterns?.dispose()
        cachedCompiledPatterns = nil
    }

    public override func collectPatterns(
        _ grammar: any TextMateRuleRegistry,
        into output: RegExpSourceList
    ) {
        output.push(matchSource)
    }

    public override func compile(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?
    ) throws -> CompiledRule {
        try compiledPatterns(grammar).compile(grammar)
    }

    public override func compileAG(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule {
        try compiledPatterns(grammar).compileAG(
            grammar,
            allowA: allowA,
            allowG: allowG
        )
    }

    private func compiledPatterns(
        _ grammar: any TextMateRuleCompilerContext
    ) throws -> RegExpSourceList {
        if let cachedCompiledPatterns { return cachedCompiledPatterns }
        let result = RegExpSourceList()
        collectPatterns(grammar, into: result)
        cachedCompiledPatterns = result
        return result
    }
}

private protocol RuleWithPatterns: AnyObject {
    var patterns: [RuleID] { get }
    var hasMissingPatterns: Bool { get }
}

public final class IncludeOnlyRule: Rule, RuleWithPatterns {
    public let hasMissingPatterns: Bool
    public let patterns: [RuleID]
    private var cachedCompiledPatterns: RegExpSourceList?

    public init(
        location: TextMateLocation?,
        id: RuleID,
        name: String?,
        contentName: String?,
        compiledPatterns: CompilePatternsResult
    ) {
        patterns = compiledPatterns.patterns
        hasMissingPatterns = compiledPatterns.hasMissingPatterns
        super.init(location: location, id: id, name: name, contentName: contentName)
    }

    public override func dispose() {
        cachedCompiledPatterns?.dispose()
        cachedCompiledPatterns = nil
    }

    public override func collectPatterns(
        _ grammar: any TextMateRuleRegistry,
        into output: RegExpSourceList
    ) throws {
        for pattern in patterns {
            guard let rule = grammar.rule(with: pattern) else {
                throw TextMateRuleError.missingRule(pattern)
            }
            try rule.collectPatterns(grammar, into: output)
        }
    }

    public override func compile(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?
    ) throws -> CompiledRule {
        try compiledPatterns(grammar).compile(grammar)
    }

    public override func compileAG(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule {
        try compiledPatterns(grammar).compileAG(
            grammar,
            allowA: allowA,
            allowG: allowG
        )
    }

    private func compiledPatterns(
        _ grammar: any TextMateRuleCompilerContext
    ) throws -> RegExpSourceList {
        if let cachedCompiledPatterns { return cachedCompiledPatterns }
        let result = RegExpSourceList()
        try collectPatterns(grammar, into: result)
        cachedCompiledPatterns = result
        return result
    }
}

public final class BeginEndRule: Rule, RuleWithPatterns {
    private let beginSource: RegExpSource
    public let beginCaptures: [CaptureRule?]
    private let endSource: RegExpSource
    public let endHasBackReferences: Bool
    public let endCaptures: [CaptureRule?]
    public let applyEndPatternLast: Bool
    public let hasMissingPatterns: Bool
    public let patterns: [RuleID]
    private var cachedCompiledPatterns: RegExpSourceList?

    public init(
        location: TextMateLocation?,
        id: RuleID,
        name: String?,
        contentName: String?,
        begin: String,
        beginCaptures: [CaptureRule?],
        end: String?,
        endCaptures: [CaptureRule?],
        applyEndPatternLast: Bool?,
        compiledPatterns: CompilePatternsResult
    ) {
        beginSource = RegExpSource(begin, ruleID: id)
        self.beginCaptures = beginCaptures
        endSource = RegExpSource(
            (end?.isEmpty == false ? end : nil) ?? "\u{FFFF}",
            ruleID: endRuleID
        )
        endHasBackReferences = endSource.hasBackReferences
        self.endCaptures = endCaptures
        self.applyEndPatternLast = applyEndPatternLast ?? false
        patterns = compiledPatterns.patterns
        hasMissingPatterns = compiledPatterns.hasMissingPatterns
        super.init(location: location, id: id, name: name, contentName: contentName)
    }

    public var debugBeginRegExp: String { beginSource.source }
    public var debugEndRegExp: String { endSource.source }

    public override func dispose() {
        cachedCompiledPatterns?.dispose()
        cachedCompiledPatterns = nil
    }

    public func getEndWithResolvedBackReferences(
        lineText: String,
        captureIndices: [OnigCaptureIndex]
    ) -> String {
        endSource.resolveBackReferences(
            lineText: lineText,
            captureIndices: captureIndices
        )
    }

    public override func collectPatterns(
        _ grammar: any TextMateRuleRegistry,
        into output: RegExpSourceList
    ) {
        output.push(beginSource)
    }

    public override func compile(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?
    ) throws -> CompiledRule {
        try compiledPatterns(grammar, endRegexSource: endRegexSource).compile(grammar)
    }

    public override func compileAG(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule {
        try compiledPatterns(grammar, endRegexSource: endRegexSource).compileAG(
            grammar,
            allowA: allowA,
            allowG: allowG
        )
    }

    private func compiledPatterns(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?
    ) throws -> RegExpSourceList {
        if cachedCompiledPatterns == nil {
            let result = RegExpSourceList()
            for pattern in patterns {
                guard let rule = grammar.rule(with: pattern) else {
                    throw TextMateRuleError.missingRule(pattern)
                }
                try rule.collectPatterns(grammar, into: result)
            }
            let end = endSource.hasBackReferences ? endSource.clone() : endSource
            if applyEndPatternLast {
                result.push(end)
            } else {
                result.unshift(end)
            }
            cachedCompiledPatterns = result
        }

        guard let cachedCompiledPatterns else {
            preconditionFailure("Compiled pattern list was not initialized")
        }
        if endSource.hasBackReferences {
            guard let endRegexSource else {
                throw TextMateRuleError.missingResolvedEndPattern
            }
            let index = applyEndPatternLast ? cachedCompiledPatterns.count - 1 : 0
            cachedCompiledPatterns.setSource(at: index, to: endRegexSource)
        }
        return cachedCompiledPatterns
    }
}

public final class BeginWhileRule: Rule, RuleWithPatterns {
    private let beginSource: RegExpSource
    public let beginCaptures: [CaptureRule?]
    public let whileCaptures: [CaptureRule?]
    private let whileSource: RegExpSource
    public let whileHasBackReferences: Bool
    public let hasMissingPatterns: Bool
    public let patterns: [RuleID]
    private var cachedCompiledPatterns: RegExpSourceList?
    private var cachedCompiledWhilePatterns: RegExpSourceList?

    public init(
        location: TextMateLocation?,
        id: RuleID,
        name: String?,
        contentName: String?,
        begin: String,
        beginCaptures: [CaptureRule?],
        whilePattern: String,
        whileCaptures: [CaptureRule?],
        compiledPatterns: CompilePatternsResult
    ) {
        beginSource = RegExpSource(begin, ruleID: id)
        self.beginCaptures = beginCaptures
        self.whileCaptures = whileCaptures
        whileSource = RegExpSource(whilePattern, ruleID: whileRuleID)
        whileHasBackReferences = whileSource.hasBackReferences
        patterns = compiledPatterns.patterns
        hasMissingPatterns = compiledPatterns.hasMissingPatterns
        super.init(location: location, id: id, name: name, contentName: contentName)
    }

    public var debugBeginRegExp: String { beginSource.source }
    public var debugWhileRegExp: String { whileSource.source }

    public override func dispose() {
        cachedCompiledPatterns?.dispose()
        cachedCompiledPatterns = nil
        cachedCompiledWhilePatterns?.dispose()
        cachedCompiledWhilePatterns = nil
    }

    public func getWhileWithResolvedBackReferences(
        lineText: String,
        captureIndices: [OnigCaptureIndex]
    ) -> String {
        whileSource.resolveBackReferences(
            lineText: lineText,
            captureIndices: captureIndices
        )
    }

    public override func collectPatterns(
        _ grammar: any TextMateRuleRegistry,
        into output: RegExpSourceList
    ) {
        output.push(beginSource)
    }

    public override func compile(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?
    ) throws -> CompiledRule {
        try compiledPatterns(grammar).compile(grammar)
    }

    public override func compileAG(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule {
        try compiledPatterns(grammar).compileAG(
            grammar,
            allowA: allowA,
            allowG: allowG
        )
    }

    public func compileWhile(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?
    ) throws -> CompiledRule {
        try compiledWhilePatterns(endRegexSource: endRegexSource).compile(grammar)
    }

    public func compileWhileAG(
        _ grammar: any TextMateRuleCompilerContext,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule {
        try compiledWhilePatterns(endRegexSource: endRegexSource).compileAG(
            grammar,
            allowA: allowA,
            allowG: allowG
        )
    }

    private func compiledPatterns(
        _ grammar: any TextMateRuleCompilerContext
    ) throws -> RegExpSourceList {
        if let cachedCompiledPatterns { return cachedCompiledPatterns }
        let result = RegExpSourceList()
        for pattern in patterns {
            guard let rule = grammar.rule(with: pattern) else {
                throw TextMateRuleError.missingRule(pattern)
            }
            try rule.collectPatterns(grammar, into: result)
        }
        cachedCompiledPatterns = result
        return result
    }

    private func compiledWhilePatterns(
        endRegexSource: String?
    ) -> RegExpSourceList {
        if cachedCompiledWhilePatterns == nil {
            let result = RegExpSourceList()
            result.push(whileSource.hasBackReferences ? whileSource.clone() : whileSource)
            cachedCompiledWhilePatterns = result
        }
        guard let cachedCompiledWhilePatterns else {
            preconditionFailure("Compiled while pattern list was not initialized")
        }
        if whileSource.hasBackReferences {
            cachedCompiledWhilePatterns.setSource(
                at: 0,
                to: endRegexSource ?? "\u{FFFF}"
            )
        }
        return cachedCompiledWhilePatterns
    }
}

public struct CompilePatternsResult: Equatable, Sendable {
    public let patterns: [RuleID]
    public let hasMissingPatterns: Bool

    public init(patterns: [RuleID], hasMissingPatterns: Bool) {
        self.patterns = patterns
        self.hasMissingPatterns = hasMissingPatterns
    }
}

/// Stateful rule compiler. `vscode-textmate` memoizes by mutating a private
/// `id` field on JavaScript rule objects. Swift raw rules are values, so this
/// factory uses the stable reference identity carried by each descriptor.
public final class RuleFactory {
    private var cache: [ObjectIdentifier: RuleID] = [:]
    // Preserve identity objects for the factory lifetime so ObjectIdentifier
    // values cannot be reused after callers pass temporary RawRule values.
    private var retainedIdentities: [ObjectIdentifier: AnyObject] = [:]

    public init() {}

    public func createCaptureRule(
        helper: any TextMateRuleFactoryHelper,
        location: TextMateLocation?,
        name: String?,
        contentName: String?,
        retokenizeCapturedWithRuleID: RuleID
    ) -> CaptureRule {
        let rule = helper.registerRule { id in
            CaptureRule(
                location: location,
                id: id,
                name: name,
                contentName: contentName,
                retokenizeCapturedWithRuleID: retokenizeCapturedWithRuleID
            )
        }
        guard let capture = rule as? CaptureRule else {
            preconditionFailure("Rule registry changed the capture rule type")
        }
        return capture
    }

    public func getCompiledRuleID(
        _ descriptor: RawRule,
        helper: any TextMateRuleFactoryHelper,
        repository: RawRepository
    ) -> RuleID {
        let identity = descriptor.compilerIdentity
        if let cached = cache[identity] {
            return cached
        }

        let rule = helper.registerRule { id in
            // Register before descending so self-recursive includes terminate.
            cache[identity] = id
            retainedIdentities[identity] = descriptor.compilerIdentityOwner
            return compileDescriptor(
                descriptor,
                id: id,
                helper: helper,
                repository: repository
            )
        }
        return rule.id
    }

    private func compileDescriptor(
        _ descriptor: RawRule,
        id: RuleID,
        helper: any TextMateRuleFactoryHelper,
        repository originalRepository: RawRepository
    ) -> Rule {
        if let match = descriptor.match, !match.isEmpty {
            return MatchRule(
                location: descriptor.location,
                id: id,
                name: descriptor.name,
                match: match,
                captures: compileCaptures(
                    descriptor.captures,
                    helper: helper,
                    repository: originalRepository
                )
            )
        }

        guard let begin = descriptor.begin else {
            var repository = originalRepository
            if let localRepository = descriptor.repository {
                repository = mergeRepositories(repository, localRepository)
            }
            var patterns = descriptor.patterns
            if patterns == nil, let include = descriptor.include, !include.isEmpty {
                patterns = [RawRule(include: include)]
            }
            return IncludeOnlyRule(
                location: descriptor.location,
                id: id,
                name: descriptor.name,
                contentName: descriptor.contentName,
                compiledPatterns: compilePatterns(
                    patterns,
                    helper: helper,
                    repository: repository
                )
            )
        }

        if let whilePattern = descriptor.whilePattern, !whilePattern.isEmpty {
            let beginCaptures = compileCaptures(
                descriptor.beginCaptures ?? descriptor.captures,
                helper: helper,
                repository: originalRepository
            )
            let whileCaptures = compileCaptures(
                descriptor.whileCaptures ?? descriptor.captures,
                helper: helper,
                repository: originalRepository
            )
            let patterns = compilePatterns(
                descriptor.patterns,
                helper: helper,
                repository: originalRepository
            )
            return BeginWhileRule(
                location: descriptor.location,
                id: id,
                name: descriptor.name,
                contentName: descriptor.contentName,
                begin: begin,
                beginCaptures: beginCaptures,
                whilePattern: whilePattern,
                whileCaptures: whileCaptures,
                compiledPatterns: patterns
            )
        }

        let beginCaptures = compileCaptures(
            descriptor.beginCaptures ?? descriptor.captures,
            helper: helper,
            repository: originalRepository
        )
        let endCaptures = compileCaptures(
            descriptor.endCaptures ?? descriptor.captures,
            helper: helper,
            repository: originalRepository
        )
        let patterns = compilePatterns(
            descriptor.patterns,
            helper: helper,
            repository: originalRepository
        )
        return BeginEndRule(
            location: descriptor.location,
            id: id,
            name: descriptor.name,
            contentName: descriptor.contentName,
            begin: begin,
            beginCaptures: beginCaptures,
            end: descriptor.end,
            endCaptures: endCaptures,
            applyEndPatternLast: descriptor.applyEndPatternLast,
            compiledPatterns: patterns
        )
    }

    private func compileCaptures(
        _ captures: RawCaptures?,
        helper: any TextMateRuleFactoryHelper,
        repository: RawRepository
    ) -> [CaptureRule?] {
        guard let captures else { return [] }

        let captureKeys = captures.keys.sorted(by: javascriptObjectKeyLessThan)
        let numericKeys = captureKeys.compactMap { key -> (String, Int)? in
            guard let number = javascriptParseInt10(key), number >= 0 else { return nil }
            return (key, number)
        }
        let maximumCaptureID = numericKeys.map(\.1).max() ?? 0
        var result = [CaptureRule?](repeating: nil, count: maximumCaptureID + 1)

        for (key, numericCaptureID) in numericKeys {
            guard let capture = captures[key] else { continue }
            var retokenizeCapturedWithRuleID = 0
            if capture.patterns != nil {
                retokenizeCapturedWithRuleID = getCompiledRuleID(
                    capture,
                    helper: helper,
                    repository: repository
                )
            }
            result[numericCaptureID] = createCaptureRule(
                helper: helper,
                location: capture.location,
                name: capture.name,
                contentName: capture.contentName,
                retokenizeCapturedWithRuleID: retokenizeCapturedWithRuleID
            )
        }
        return result
    }

    private func compilePatterns(
        _ patterns: [RawRule]?,
        helper: any TextMateRuleFactoryHelper,
        repository: RawRepository
    ) -> CompilePatternsResult {
        var result: [RuleID] = []

        for pattern in patterns ?? [] {
            var ruleID: RuleID?

            if let include = pattern.include, !include.isEmpty {
                switch parseInclude(include) {
                case .base, .selfReference:
                    if let included = repository[include] {
                        ruleID = getCompiledRuleID(
                            included,
                            helper: helper,
                            repository: repository
                        )
                    }

                case let .relative(ruleName):
                    if let included = repository[ruleName] {
                        ruleID = getCompiledRuleID(
                            included,
                            helper: helper,
                            repository: repository
                        )
                    }

                case let .topLevel(scopeName):
                    if
                        let external = helper.externalGrammar(
                            scopeName: scopeName,
                            repository: repository
                        ),
                        let included = external.repository["$self"]
                    {
                        ruleID = getCompiledRuleID(
                            included,
                            helper: helper,
                            repository: external.repository
                        )
                    }

                case let .topLevelRepository(scopeName, ruleName):
                    if
                        let external = helper.externalGrammar(
                            scopeName: scopeName,
                            repository: repository
                        ),
                        let included = external.repository[ruleName]
                    {
                        ruleID = getCompiledRuleID(
                            included,
                            helper: helper,
                            repository: external.repository
                        )
                    }
                }
            } else {
                ruleID = getCompiledRuleID(
                    pattern,
                    helper: helper,
                    repository: repository
                )
            }

            guard let ruleID else { continue }
            if
                let aggregate = helper.rule(with: ruleID) as? any RuleWithPatterns,
                aggregate.hasMissingPatterns,
                aggregate.patterns.isEmpty
            {
                continue
            }
            result.append(ruleID)
        }

        return CompilePatternsResult(
            patterns: result,
            hasMissingPatterns: (patterns?.count ?? 0) != result.count
        )
    }
}

private func mergeRepositories(
    _ base: RawRepository,
    _ overlay: RawRepository
) -> RawRepository {
    var rules = base.rules
    for (name, rule) in overlay.rules { rules[name] = rule }
    return RawRepository(rules, location: overlay.location ?? base.location)
}

private func javascriptParseInt10(_ source: String) -> Int? {
    let units = Array(source.utf16)
    var cursor = 0
    while cursor < units.count, isJavaScriptWhitespace(units[cursor]) { cursor += 1 }
    var sign = 1
    if cursor < units.count, units[cursor] == 0x2B || units[cursor] == 0x2D {
        if units[cursor] == 0x2D { sign = -1 }
        cursor += 1
    }
    let start = cursor
    while cursor < units.count, isASCIIDigit(units[cursor]) { cursor += 1 }
    guard cursor > start, let magnitude = decimalInteger(units[start..<cursor]) else {
        return nil
    }
    let (value, overflow) = magnitude.multipliedReportingOverflow(by: sign)
    return overflow ? nil : value
}

private func isJavaScriptWhitespace(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        true
    default:
        false
    }
}

private func javascriptObjectKeyLessThan(_ lhs: String, _ rhs: String) -> Bool {
    let lhsIndex = javascriptArrayIndex(lhs)
    let rhsIndex = javascriptArrayIndex(rhs)
    switch (lhsIndex, rhsIndex) {
    case let (left?, right?): return left < right
    case (_?, nil): return true
    case (nil, _?): return false
    case (nil, nil): return lhs < rhs
    }
}

private func javascriptArrayIndex(_ source: String) -> UInt32? {
    guard
        !source.isEmpty,
        source == "0" || source.first != "0",
        source.allSatisfy({ $0 >= "0" && $0 <= "9" }),
        let value = UInt32(source),
        value != UInt32.max,
        String(value) == source
    else { return nil }
    return value
}

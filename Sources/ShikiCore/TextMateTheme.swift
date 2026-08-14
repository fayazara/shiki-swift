/*---------------------------------------------------------
 * Copyright (C) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------*/

import Foundation

/// Identifiers with a binary dot operator, such as `source.swift`.
public typealias ScopeName = String

/// A space-delimited expression of nested scope names.
public typealias ScopePath = String

/// A comma-delimited expression of alternative scope paths.
public typealias ScopePattern = String

/// Errors raised while compiling a TextMate theme.
public enum TextMateThemeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A frozen color map did not contain a color required by the theme.
    case missingColorInColorMap(String)

    public var description: String {
        switch self {
        case let .missingColorInColorMap(color):
            "Missing color in color map - \(color)"
        }
    }
}

extension TextMateThemeError: LocalizedError {
    public var errorDescription: String? {
        description
    }
}

/// A persistent linked stack of TextMate scopes, ordered outermost to innermost.
public final class ScopeStack: @unchecked Sendable, CustomStringConvertible {
    public let parent: ScopeStack?
    public let scopeName: ScopeName

    public init(parent: ScopeStack?, scopeName: ScopeName) {
        self.parent = parent
        self.scopeName = scopeName
    }

    /// Compatibility initializer matching `vscode-textmate`'s positional constructor.
    public convenience init(_ parent: ScopeStack?, _ scopeName: ScopeName) {
        self.init(parent: parent, scopeName: scopeName)
    }

    /// Appends every supplied scope name to a possibly empty stack.
    public static func push(_ path: ScopeStack?, _ scopeNames: [ScopeName]) -> ScopeStack? {
        var result = path
        for name in scopeNames {
            result = ScopeStack(parent: result, scopeName: name)
        }
        return result
    }

    /// Creates a nonempty scope stack.
    public static func from(_ first: ScopeName, _ segments: ScopeName...) -> ScopeStack {
        var result = ScopeStack(parent: nil, scopeName: first)
        for segment in segments {
            result = ScopeStack(parent: result, scopeName: segment)
        }
        return result
    }

    /// Creates a scope stack from a dynamically sized array.
    public static func from(_ segments: [ScopeName]) -> ScopeStack? {
        push(nil, segments)
    }

    /// The empty list produces the empty scope stack, as in the TypeScript overload.
    public static func from() -> ScopeStack? {
        nil
    }

    public func push(_ scopeName: ScopeName) -> ScopeStack {
        ScopeStack(parent: self, scopeName: scopeName)
    }

    public func getSegments() -> [ScopeName] {
        var item: ScopeStack? = self
        var result: [ScopeName] = []
        while let current = item {
            result.append(current.scopeName)
            item = current.parent
        }
        return result.reversed()
    }

    public var description: String {
        getSegments().joined(separator: " ")
    }

    /// Returns whether this stack contains `other` as the same linked ancestor node.
    public func extends(_ other: ScopeStack) -> Bool {
        if self === other {
            return true
        }
        guard let parent else {
            return false
        }
        return parent.extends(other)
    }

    /// Returns the scopes appended after `base`, or `nil` when `base` is not an ancestor.
    public func getExtensionIfDefined(_ base: ScopeStack?) -> [ScopeName]? {
        var result: [ScopeName] = []
        var item: ScopeStack? = self
        while let current = item, current !== base {
            result.append(current.scopeName)
            item = current.parent
        }
        return item === base ? result.reversed() : nil
    }
}

/// The style selected for a TextMate scope stack.
public struct StyleAttributes: Equatable, Sendable {
    public let fontStyle: FontStyle
    public let foregroundID: Int
    public let backgroundID: Int

    /// Compatibility spelling matching `vscode-textmate`.
    public var foregroundId: Int { foregroundID }

    /// Compatibility spelling matching `vscode-textmate`.
    public var backgroundId: Int { backgroundID }

    public init(_ fontStyle: FontStyle, _ foregroundID: Int, _ backgroundID: Int) {
        self.fontStyle = fontStyle
        self.foregroundID = foregroundID
        self.backgroundID = backgroundID
    }

    public init(fontStyle: FontStyle, foregroundID: Int, backgroundID: Int) {
        self.init(fontStyle, foregroundID, backgroundID)
    }
}

/// A parsed, but not yet inheritance-resolved, TextMate theme rule.
public struct ParsedThemeRule: Equatable, Sendable {
    public let scope: ScopeName
    public let parentScopes: [ScopeName]?
    public let index: Int
    public let fontStyle: FontStyle
    public let foreground: String?
    public let background: String?

    public init(
        _ scope: ScopeName,
        _ parentScopes: [ScopeName]?,
        _ index: Int,
        _ fontStyle: FontStyle,
        _ foreground: String?,
        _ background: String?
    ) {
        self.scope = scope
        self.parentScopes = parentScopes
        self.index = index
        self.fontStyle = fontStyle
        self.foreground = foreground
        self.background = background
    }

    public init(
        scope: ScopeName,
        parentScopes: [ScopeName]?,
        index: Int,
        fontStyle: FontStyle,
        foreground: String?,
        background: String?
    ) {
        self.init(scope, parentScopes, index, fontStyle, foreground, background)
    }
}

/// Parses a raw Shiki theme's `settings` array exactly as `vscode-textmate` does.
public func parseTheme(_ source: ShikiTheme?) -> [ParsedThemeRule] {
    parseThemeSettings(source?.settings)
}

/// Parses a normalized Shiki theme's TextMate settings.
public func parseTheme(_ source: ShikiResolvedTheme) -> [ParsedThemeRule] {
    parseThemeSettings(source.settings)
}

/// Converts TextMate font-style bits to their source spelling.
public func fontStyleToString(_ fontStyle: FontStyle) -> String {
    fontStyle.description
}

/// Maps colors to the compact numeric IDs stored in token metadata.
///
/// A dynamically built map deliberately leaves index zero empty because zero
/// means "not set" in `vscode-textmate`. Supplying a map freezes it: requesting
/// any absent color then raises `TextMateThemeError.missingColorInColorMap`.
public final class ColorMap {
    private let isFrozen: Bool
    private var lastColorID: Int
    private var idToColor: [String?]
    private var colorToID: [String: Int]

    public init(_ colorMap: [String?]? = nil) {
        lastColorID = 0
        idToColor = []
        colorToID = [:]

        if let colorMap {
            isFrozen = true
            idToColor = colorMap
            for (index, color) in colorMap.enumerated() {
                if let color {
                    colorToID[color] = index
                }
            }
        } else {
            isFrozen = false
        }
    }

    public func getID(_ color: String?) throws -> Int {
        guard let color else {
            return 0
        }

        let normalizedColor = color.uppercased()
        // JavaScript's original `if (value)` intentionally treats ID zero as
        // absent, even if a frozen caller placed a color at that slot.
        if let value = colorToID[normalizedColor], value != 0 {
            return value
        }

        if isFrozen {
            throw TextMateThemeError.missingColorInColorMap(normalizedColor)
        }

        lastColorID += 1
        let value = lastColorID
        colorToID[normalizedColor] = value
        while idToColor.count <= value {
            idToColor.append(nil)
        }
        idToColor[value] = normalizedColor
        return value
    }

    /// Compatibility spelling matching `vscode-textmate`.
    public func getId(_ color: String?) throws -> Int {
        try getID(color)
    }

    public func getColorMap() -> [String?] {
        idToColor
    }
}

/// A resolved trie rule. Instances are cloned as trie branches inherit styles.
public final class ThemeTrieElementRule {
    public var scopeDepth: Int
    public let parentScopes: [ScopeName]
    public var fontStyle: FontStyle
    public var foreground: Int
    public var background: Int

    public init(
        _ scopeDepth: Int,
        _ parentScopes: [ScopeName]?,
        _ fontStyle: FontStyle,
        _ foreground: Int,
        _ background: Int
    ) {
        self.scopeDepth = scopeDepth
        self.parentScopes = parentScopes ?? []
        self.fontStyle = fontStyle
        self.foreground = foreground
        self.background = background
    }

    public func clone() -> ThemeTrieElementRule {
        ThemeTrieElementRule(scopeDepth, parentScopes, fontStyle, foreground, background)
    }

    public static func cloneArray(_ rules: [ThemeTrieElementRule]) -> [ThemeTrieElementRule] {
        rules.map { $0.clone() }
    }

    /// Compatibility spelling matching `vscode-textmate`.
    public static func cloneArr(_ rules: [ThemeTrieElementRule]) -> [ThemeTrieElementRule] {
        cloneArray(rules)
    }

    public func acceptOverwrite(
        _ scopeDepth: Int,
        _ fontStyle: FontStyle,
        _ foreground: Int,
        _ background: Int
    ) {
        if self.scopeDepth <= scopeDepth {
            self.scopeDepth = scopeDepth
        }
        if fontStyle != .notSet {
            self.fontStyle = fontStyle
        }
        if foreground != 0 {
            self.foreground = foreground
        }
        if background != 0 {
            self.background = background
        }
    }
}

/// A segment trie that resolves TextMate scope inheritance and specificity.
public final class ThemeTrieElement {
    private let mainRule: ThemeTrieElementRule
    private var rulesWithParentScopes: [ThemeTrieElementRule]
    private var children: [String: ThemeTrieElement]

    public init(
        _ mainRule: ThemeTrieElementRule,
        _ rulesWithParentScopes: [ThemeTrieElementRule] = [],
        _ children: [String: ThemeTrieElement] = [:]
    ) {
        self.mainRule = mainRule
        self.rulesWithParentScopes = rulesWithParentScopes
        self.children = children
    }

    public func match(_ scope: ScopeName) -> [ThemeTrieElementRule] {
        if !scope.isEmpty {
            let (head, tail) = splitFirstScopeSegment(scope)
            if let child = children[head] {
                return child.match(tail)
            }
        }

        // ECMAScript specifies a stable Array.sort. Retain insertion order when
        // two specificity comparisons tie rather than relying on Swift's sort.
        return (rulesWithParentScopes + [mainRule])
            .enumerated()
            .sorted { left, right in
                let comparison = Self.compareBySpecificity(left.element, right.element)
                return comparison == 0 ? left.offset < right.offset : comparison < 0
            }
            .map(\.element)
    }

    public func insert(
        _ scopeDepth: Int,
        _ scope: ScopeName,
        _ parentScopes: [ScopeName]?,
        _ fontStyle: FontStyle,
        _ foreground: Int,
        _ background: Int
    ) {
        if scope.isEmpty {
            insertHere(scopeDepth, parentScopes, fontStyle, foreground, background)
            return
        }

        let (head, tail) = splitFirstScopeSegment(scope)
        let child: ThemeTrieElement
        if let existing = children[head] {
            child = existing
        } else {
            child = ThemeTrieElement(
                mainRule.clone(),
                ThemeTrieElementRule.cloneArray(rulesWithParentScopes)
            )
            children[head] = child
        }

        child.insert(scopeDepth + 1, tail, parentScopes, fontStyle, foreground, background)
    }

    private static func compareBySpecificity(
        _ left: ThemeTrieElementRule,
        _ right: ThemeTrieElementRule
    ) -> Int {
        if left.scopeDepth != right.scopeDepth {
            return right.scopeDepth - left.scopeDepth
        }

        var leftParentIndex = 0
        var rightParentIndex = 0

        while true {
            // A direct-child combinator changes matching, but not specificity.
            if leftParentIndex < left.parentScopes.count,
               left.parentScopes[leftParentIndex] == ">" {
                leftParentIndex += 1
            }
            if rightParentIndex < right.parentScopes.count,
               right.parentScopes[rightParentIndex] == ">" {
                rightParentIndex += 1
            }

            guard leftParentIndex < left.parentScopes.count,
                  rightParentIndex < right.parentScopes.count else {
                break
            }

            let lengthDifference = right.parentScopes[rightParentIndex].utf16.count
                - left.parentScopes[leftParentIndex].utf16.count
            if lengthDifference != 0 {
                return lengthDifference
            }

            leftParentIndex += 1
            rightParentIndex += 1
        }

        return right.parentScopes.count - left.parentScopes.count
    }

    private func insertHere(
        _ scopeDepth: Int,
        _ parentScopes: [ScopeName]?,
        _ fontStyle: FontStyle,
        _ foreground: Int,
        _ background: Int
    ) {
        guard let parentScopes else {
            mainRule.acceptOverwrite(scopeDepth, fontStyle, foreground, background)
            return
        }

        if let existingRule = rulesWithParentScopes.first(where: {
            compareStringArrays($0.parentScopes, parentScopes) == 0
        }) {
            existingRule.acceptOverwrite(scopeDepth, fontStyle, foreground, background)
            return
        }

        let inheritedFontStyle = fontStyle == .notSet ? mainRule.fontStyle : fontStyle
        let inheritedForeground = foreground == 0 ? mainRule.foreground : foreground
        let inheritedBackground = background == 0 ? mainRule.background : background
        rulesWithParentScopes.append(
            ThemeTrieElementRule(
                scopeDepth,
                parentScopes,
                inheritedFontStyle,
                inheritedForeground,
                inheritedBackground
            )
        )
    }
}

/// A compiled TextMate theme ready for synchronous scope-stack matching.
public final class Theme {
    private let colorMap: ColorMap
    private let defaults: StyleAttributes
    private let root: ThemeTrieElement
    private var cachedRootMatches: [ScopeName: [ThemeTrieElementRule]] = [:]
    private let cacheLock = NSLock()

    public init(_ colorMap: ColorMap, _ defaults: StyleAttributes, _ root: ThemeTrieElement) {
        self.colorMap = colorMap
        self.defaults = defaults
        self.root = root
    }

    public static func createFromRawTheme(
        _ source: ShikiTheme?,
        colorMap: [String?]? = nil
    ) throws -> Theme {
        try createFromParsedTheme(parseTheme(source), colorMap: colorMap)
    }

    /// Compatibility overload for Shiki's already normalized theme model.
    public static func createFromRawTheme(
        _ source: ShikiResolvedTheme,
        colorMap: [String?]? = nil
    ) throws -> Theme {
        try createFromParsedTheme(parseTheme(source), colorMap: colorMap)
    }

    public static func createFromParsedTheme(
        _ source: [ParsedThemeRule],
        colorMap frozenColorMap: [String?]? = nil
    ) throws -> Theme {
        try resolveParsedThemeRules(source, frozenColorMap)
    }

    /// Compiles an already normalized Shiki theme.
    public static func create(
        from source: ShikiResolvedTheme,
        colorMap: [String?]? = nil
    ) throws -> Theme {
        try createFromParsedTheme(parseTheme(source), colorMap: colorMap)
    }

    public func getColorMap() -> [String?] {
        colorMap.getColorMap()
    }

    public func getDefaults() -> StyleAttributes {
        defaults
    }

    public func match(_ scopePath: ScopeStack?) -> StyleAttributes? {
        guard let scopePath else {
            return defaults
        }

        let matchingTrieElements: [ThemeTrieElementRule]
        cacheLock.lock()
        if let cached = cachedRootMatches[scopePath.scopeName] {
            matchingTrieElements = cached
        } else {
            let matched = root.match(scopePath.scopeName)
            cachedRootMatches[scopePath.scopeName] = matched
            matchingTrieElements = matched
        }
        cacheLock.unlock()

        guard let effectiveRule = matchingTrieElements.first(where: {
            scopePathMatchesParentScopes(scopePath.parent, $0.parentScopes)
        }) else {
            return nil
        }

        return StyleAttributes(
            effectiveRule.fontStyle,
            effectiveRule.foreground,
            effectiveRule.background
        )
    }
}

/// A discoverable native spelling for `vscode-textmate`'s `Theme` type.
public typealias TextMateTheme = Theme

public extension ShikiResolvedTheme {
    /// Compiles this resolved theme into the synchronous TextMate matcher.
    func compile(colorMap: [String?]? = nil) throws -> TextMateTheme {
        try Theme.create(from: self, colorMap: colorMap)
    }
}

private func parseThemeSettings(_ settings: [ShikiThemeRule]?) -> [ParsedThemeRule] {
    guard let settings else {
        return []
    }

    var result: [ParsedThemeRule] = []
    for (index, entry) in settings.enumerated() {
        guard let tokenSettings = entry.settings else {
            continue
        }

        let scopes: [String]
        switch entry.scope {
        case let .string(scope):
            let withoutLeadingCommas = scope.drop { $0 == "," }
            let cleaned = withoutLeadingCommas.dropLastWhile { $0 == "," }
            scopes = String(cleaned).components(separatedBy: ",")
        case let .array(scopeList):
            scopes = scopeList
        case nil:
            scopes = [""]
        }

        var fontStyle: FontStyle = .notSet
        if let sourceFontStyle = tokenSettings.fontStyle {
            fontStyle = .none
            for segment in sourceFontStyle.components(separatedBy: " ") {
                switch segment {
                case "italic": fontStyle.insert(.italic)
                case "bold": fontStyle.insert(.bold)
                case "underline": fontStyle.insert(.underline)
                case "strikethrough": fontStyle.insert(.strikethrough)
                default: break
                }
            }
        }

        let foreground = tokenSettings.foreground.flatMap { color in
            isValidHexColor(color) ? color : nil
        }
        let background = tokenSettings.background.flatMap { color in
            isValidHexColor(color) ? color : nil
        }

        for sourceScope in scopes {
            let trimmedScope = sourceScope.trimmingCharacters(in: .whitespacesAndNewlines)
            let segments = trimmedScope.components(separatedBy: " ")
            let scope = segments.last ?? ""
            let parentScopes: [String]? = segments.count > 1
                ? Array(segments.dropLast().reversed())
                : nil

            result.append(
                ParsedThemeRule(
                    scope,
                    parentScopes,
                    index,
                    fontStyle,
                    foreground,
                    background
                )
            )
        }
    }

    return result
}

private func resolveParsedThemeRules(
    _ source: [ParsedThemeRule],
    _ frozenColorMap: [String?]?
) throws -> Theme {
    // Keep the original position as a final tie-break so this remains stable
    // like ECMAScript's Array.sort even when duplicate source indices occur.
    var parsedThemeRules = source.enumerated().sorted { left, right in
        var comparison = compareJavaScriptStrings(left.element.scope, right.element.scope)
        if comparison == 0 {
            comparison = compareOptionalStringArrays(
                left.element.parentScopes,
                right.element.parentScopes
            )
        }
        if comparison == 0 {
            comparison = left.element.index - right.element.index
        }
        return comparison == 0 ? left.offset < right.offset : comparison < 0
    }.map(\.element)

    var defaultFontStyle: FontStyle = .none
    var defaultForeground = "#000000"
    var defaultBackground = "#ffffff"
    while parsedThemeRules.first?.scope == "" {
        let incomingDefaults = parsedThemeRules.removeFirst()
        if incomingDefaults.fontStyle != .notSet {
            defaultFontStyle = incomingDefaults.fontStyle
        }
        if let foreground = incomingDefaults.foreground {
            defaultForeground = foreground
        }
        if let background = incomingDefaults.background {
            defaultBackground = background
        }
    }

    let colorMap = ColorMap(frozenColorMap)
    let defaults = try StyleAttributes(
        defaultFontStyle,
        colorMap.getID(defaultForeground),
        colorMap.getID(defaultBackground)
    )
    let root = ThemeTrieElement(
        ThemeTrieElementRule(0, nil, .notSet, 0, 0)
    )

    for rule in parsedThemeRules {
        root.insert(
            0,
            rule.scope,
            rule.parentScopes,
            rule.fontStyle,
            try colorMap.getID(rule.foreground),
            try colorMap.getID(rule.background)
        )
    }

    return Theme(colorMap, defaults, root)
}

private func scopePathMatchesParentScopes(
    _ initialScopePath: ScopeStack?,
    _ parentScopes: [ScopeName]
) -> Bool {
    if parentScopes.isEmpty {
        return true
    }

    var scopePath = initialScopePath
    var index = 0
    while index < parentScopes.count {
        var scopePattern = parentScopes[index]
        var scopeMustMatch = false

        if scopePattern == ">" {
            if index == parentScopes.count - 1 {
                return false
            }
            index += 1
            scopePattern = parentScopes[index]
            scopeMustMatch = true
        }

        while let candidate = scopePath {
            if matchesScope(candidate.scopeName, scopePattern) {
                break
            }
            if scopeMustMatch {
                return false
            }
            scopePath = candidate.parent
        }

        guard let matchedScope = scopePath else {
            return false
        }
        scopePath = matchedScope.parent
        index += 1
    }

    return true
}

private func matchesScope(_ scopeName: ScopeName, _ scopePattern: ScopeName) -> Bool {
    if scopePattern == scopeName {
        return true
    }

    let scopeUnits = Array(scopeName.utf16)
    let patternUnits = Array(scopePattern.utf16)
    guard scopeUnits.count > patternUnits.count,
          scopeUnits.starts(with: patternUnits) else {
        return false
    }
    return scopeUnits[patternUnits.count] == 0x2E
}

private func splitFirstScopeSegment(_ scope: ScopeName) -> (head: String, tail: String) {
    guard let dot = scope.firstIndex(of: ".") else {
        return (scope, "")
    }
    return (
        String(scope[..<dot]),
        String(scope[scope.index(after: dot)...])
    )
}

private func isValidHexColor(_ color: String) -> Bool {
    let units = Array(color.utf8)
    guard [4, 5, 7, 9].contains(units.count), units.first == 0x23 else {
        return false
    }
    return units.dropFirst().allSatisfy { byte in
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}

/// JavaScript compares strings lexicographically by UTF-16 code units.
private func compareJavaScriptStrings(_ left: String, _ right: String) -> Int {
    let leftUnits = Array(left.utf16)
    let rightUnits = Array(right.utf16)
    let sharedCount = min(leftUnits.count, rightUnits.count)
    for index in 0..<sharedCount {
        if leftUnits[index] < rightUnits[index] {
            return -1
        }
        if leftUnits[index] > rightUnits[index] {
            return 1
        }
    }
    if leftUnits.count < rightUnits.count {
        return -1
    }
    if leftUnits.count > rightUnits.count {
        return 1
    }
    return 0
}

private func compareOptionalStringArrays(_ left: [String]?, _ right: [String]?) -> Int {
    switch (left, right) {
    case (nil, nil):
        return 0
    case (nil, _):
        return -1
    case (_, nil):
        return 1
    case let (left?, right?):
        return compareStringArrays(left, right)
    }
}

private func compareStringArrays(_ left: [String], _ right: [String]) -> Int {
    if left.count != right.count {
        return left.count - right.count
    }
    for index in left.indices {
        let comparison = compareJavaScriptStrings(left[index], right[index])
        if comparison != 0 {
            return comparison
        }
    }
    return 0
}

private extension Substring {
    func dropLastWhile(_ predicate: (Character) -> Bool) -> Substring {
        var result = self
        while let last = result.last, predicate(last) {
            result = result.dropLast()
        }
        return result
    }
}

import Foundation

/// Source location metadata optionally attached by `vscode-textmate`'s JSON
/// and plist parsers.
public struct TextMateLocation: Codable, Equatable, Sendable {
    public var filename: String?

    /// One-based source line.
    public var line: Int

    /// Zero-based UTF-16 code-unit column, matching JavaScript string offsets.
    public var character: Int

    /// Compatibility spelling matching the serialized `char` key.
    public var char: Int {
        get { character }
        set { character = newValue }
    }

    public init(filename: String?, line: Int, character: Int) {
        self.filename = filename
        self.line = line
        self.character = character
    }

    private enum CodingKeys: String, CodingKey {
        case filename
        case line
        case character = "char"
    }
}

/// A dynamically keyed collection of raw TextMate rules.
///
/// Both repositories and capture maps have this shape. Location metadata is
/// split from the entries so `$vscodeTextmateLocation` is never mistaken for a
/// grammar rule during iteration.
public struct RawRuleCollection: Codable, Equatable, Sendable,
    ExpressibleByDictionaryLiteral, Sequence
{
    public typealias Key = String
    public typealias Value = RawRule
    public typealias Element = Dictionary<String, RawRule>.Element

    public var rules: [String: RawRule]
    public var location: TextMateLocation?
    private var encodedAsArray: Bool

    public init(
        _ rules: [String: RawRule] = [:],
        location: TextMateLocation? = nil
    ) {
        self.rules = rules
        self.location = location
        encodedAsArray = false
    }

    public init(dictionaryLiteral elements: (String, RawRule)...) {
        rules = Dictionary(uniqueKeysWithValues: elements)
        location = nil
        encodedAsArray = false
    }

    public subscript(key: String) -> RawRule? {
        get { rules[key] }
        set { rules[key] = newValue }
    }

    public var count: Int { rules.count }
    public var isEmpty: Bool { rules.isEmpty }
    public var keys: Dictionary<String, RawRule>.Keys { rules.keys }
    public var values: Dictionary<String, RawRule>.Values { rules.values }

    public func makeIterator() -> Dictionary<String, RawRule>.Iterator {
        rules.makeIterator()
    }

    public init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var decodedRules: [String: RawRule] = [:]
            var index = 0
            while !array.isAtEnd {
                if try array.decodeNil() {
                    index += 1
                    continue
                }
                decodedRules[String(index)] = try array.decode(RawRule.self)
                index += 1
            }
            rules = decodedRules
            location = nil
            encodedAsArray = true
            return
        }

        let container = try decoder.container(keyedBy: TextMateDynamicCodingKey.self)
        var decodedRules: [String: RawRule] = [:]
        var decodedLocation: TextMateLocation?

        for key in container.allKeys {
            if key.stringValue == "$vscodeTextmateLocation" {
                decodedLocation = try container.decodeIfPresent(TextMateLocation.self, forKey: key)
            } else if let rule = try container.decodeIfPresent(RawRule.self, forKey: key) {
                decodedRules[key.stringValue] = rule
            }
        }

        rules = decodedRules
        location = decodedLocation
        encodedAsArray = false
    }

    public func encode(to encoder: Encoder) throws {
        if encodedAsArray {
            var container = encoder.unkeyedContainer()
            let indexedRules = Dictionary(
                uniqueKeysWithValues: rules.compactMap { key, value in
                    Int(key).map { ($0, value) }
                }
            )
            if let lastIndex = indexedRules.keys.max(), lastIndex >= 0 {
                for index in 0...lastIndex {
                    if let rule = indexedRules[index] {
                        try container.encode(rule)
                    } else {
                        try container.encodeNil()
                    }
                }
            }
            return
        }

        var container = encoder.container(keyedBy: TextMateDynamicCodingKey.self)
        for (name, rule) in rules {
            try container.encode(rule, forKey: TextMateDynamicCodingKey(name))
        }
        if let location {
            try container.encode(
                location,
                forKey: TextMateDynamicCodingKey("$vscodeTextmateLocation")
            )
        }
    }
}

public typealias RawRepository = RawRuleCollection
public typealias RawCaptures = RawRuleCollection

/// A recursive rule from a TextMate plist or JSON grammar.
public struct RawRule: Codable, Equatable, Sendable {
    /// Keep the recursive descriptor payload behind one reference. Besides
    /// matching vscode-textmate's JavaScript object model, this keeps recursive
    /// rule compilation within the small stacks used by Swift cooperative
    /// executor threads. Setters use copy-on-write so `RawRule` remains a value.
    private final class Storage: @unchecked Sendable {
        var include: String?
        var name: String?
        var contentName: String?
        var match: String?
        var captures: RawCaptures?
        var begin: String?
        var beginCaptures: RawCaptures?
        var end: String?
        var endCaptures: RawCaptures?
        var whilePattern: String?
        var whileCaptures: RawCaptures?
        var patterns: [RawRule]?
        var repository: RawRepository?
        var applyEndPatternLast: Bool?
        var location: TextMateLocation?

        init(
            include: String?,
            name: String?,
            contentName: String?,
            match: String?,
            captures: RawCaptures?,
            begin: String?,
            beginCaptures: RawCaptures?,
            end: String?,
            endCaptures: RawCaptures?,
            whilePattern: String?,
            whileCaptures: RawCaptures?,
            patterns: [RawRule]?,
            repository: RawRepository?,
            applyEndPatternLast: Bool?,
            location: TextMateLocation?
        ) {
            self.include = include
            self.name = name
            self.contentName = contentName
            self.match = match
            self.captures = captures
            self.begin = begin
            self.beginCaptures = beginCaptures
            self.end = end
            self.endCaptures = endCaptures
            self.whilePattern = whilePattern
            self.whileCaptures = whileCaptures
            self.patterns = patterns
            self.repository = repository
            self.applyEndPatternLast = applyEndPatternLast
            self.location = location
        }

        func copy() -> Storage {
            Storage(
                include: include,
                name: name,
                contentName: contentName,
                match: match,
                captures: captures,
                begin: begin,
                beginCaptures: beginCaptures,
                end: end,
                endCaptures: endCaptures,
                whilePattern: whilePattern,
                whileCaptures: whileCaptures,
                patterns: patterns,
                repository: repository,
                applyEndPatternLast: applyEndPatternLast,
                location: location
            )
        }
    }

    private var storage: Storage

    /// Internal compiler identity. It is deliberately absent from Codable and
    /// semantic equality, just like vscode-textmate's private descriptor ID.
    var compilerIdentity: ObjectIdentifier { ObjectIdentifier(storage) }
    var compilerIdentityOwner: AnyObject { storage }

    public var include: String? {
        get { storage.include }
        set { ensureUniqueStorage(); storage.include = newValue }
    }
    public var name: String? {
        get { storage.name }
        set { ensureUniqueStorage(); storage.name = newValue }
    }
    public var contentName: String? {
        get { storage.contentName }
        set { ensureUniqueStorage(); storage.contentName = newValue }
    }
    public var match: String? {
        get { storage.match }
        set { ensureUniqueStorage(); storage.match = newValue }
    }
    public var captures: RawCaptures? {
        get { storage.captures }
        set { ensureUniqueStorage(); storage.captures = newValue }
    }
    public var begin: String? {
        get { storage.begin }
        set { ensureUniqueStorage(); storage.begin = newValue }
    }
    public var beginCaptures: RawCaptures? {
        get { storage.beginCaptures }
        set { ensureUniqueStorage(); storage.beginCaptures = newValue }
    }
    public var end: String? {
        get { storage.end }
        set { ensureUniqueStorage(); storage.end = newValue }
    }
    public var endCaptures: RawCaptures? {
        get { storage.endCaptures }
        set { ensureUniqueStorage(); storage.endCaptures = newValue }
    }
    public var whilePattern: String? {
        get { storage.whilePattern }
        set { ensureUniqueStorage(); storage.whilePattern = newValue }
    }
    public var whileCaptures: RawCaptures? {
        get { storage.whileCaptures }
        set { ensureUniqueStorage(); storage.whileCaptures = newValue }
    }
    public var patterns: [RawRule]? {
        get { storage.patterns }
        set { ensureUniqueStorage(); storage.patterns = newValue }
    }
    public var repository: RawRepository? {
        get { storage.repository }
        set { ensureUniqueStorage(); storage.repository = newValue }
    }
    public var applyEndPatternLast: Bool? {
        get { storage.applyEndPatternLast }
        set { ensureUniqueStorage(); storage.applyEndPatternLast = newValue }
    }
    public var location: TextMateLocation? {
        get { storage.location }
        set { ensureUniqueStorage(); storage.location = newValue }
    }

    public init(
        include: String? = nil,
        name: String? = nil,
        contentName: String? = nil,
        match: String? = nil,
        captures: RawCaptures? = nil,
        begin: String? = nil,
        beginCaptures: RawCaptures? = nil,
        end: String? = nil,
        endCaptures: RawCaptures? = nil,
        whilePattern: String? = nil,
        whileCaptures: RawCaptures? = nil,
        patterns: [RawRule]? = nil,
        repository: RawRepository? = nil,
        applyEndPatternLast: Bool? = nil,
        location: TextMateLocation? = nil
    ) {
        storage = Storage(
            include: include,
            name: name,
            contentName: contentName,
            match: match,
            captures: captures,
            begin: begin,
            beginCaptures: beginCaptures,
            end: end,
            endCaptures: endCaptures,
            whilePattern: whilePattern,
            whileCaptures: whileCaptures,
            patterns: patterns,
            repository: repository,
            applyEndPatternLast: applyEndPatternLast,
            location: location
        )
    }

    private mutating func ensureUniqueStorage() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }
    }

    public static func == (lhs: RawRule, rhs: RawRule) -> Bool {
        lhs.include == rhs.include
            && lhs.name == rhs.name
            && lhs.contentName == rhs.contentName
            && lhs.match == rhs.match
            && lhs.captures == rhs.captures
            && lhs.begin == rhs.begin
            && lhs.beginCaptures == rhs.beginCaptures
            && lhs.end == rhs.end
            && lhs.endCaptures == rhs.endCaptures
            && lhs.whilePattern == rhs.whilePattern
            && lhs.whileCaptures == rhs.whileCaptures
            && lhs.patterns == rhs.patterns
            && lhs.repository == rhs.repository
            && lhs.applyEndPatternLast == rhs.applyEndPatternLast
            && lhs.location == rhs.location
    }

    public init(from decoder: Decoder) throws {
        // A small number of long-standing TextMate grammars contain capture
        // entries as strings or arrays instead of rule objects. JavaScript
        // property access treats both as objects with no `name`, `patterns`,
        // or `contentName`, so vscode-textmate compiles an inert capture rule.
        // Decode them to an empty descriptor to preserve that behavior.
        if let scalar = try? decoder.singleValueContainer(),
           (try? scalar.decode(String.self)) != nil {
            self.init()
            return
        }
        if (try? decoder.unkeyedContainer()) != nil {
            self.init()
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let applyEndPatternLast: Bool?
        if let bool = try? container.decodeIfPresent(Bool.self, forKey: .applyEndPatternLast) {
            applyEndPatternLast = bool
        } else if let integer = try container.decodeIfPresent(
            Int.self,
            forKey: .applyEndPatternLast
        ) {
            // Several canonical TextMate grammars use 0/1 here. The JS engine
            // accepts them through ordinary truthiness even though the public
            // TypeScript shape says boolean.
            applyEndPatternLast = integer != 0
        } else {
            applyEndPatternLast = nil
        }

        self.init(
            include: try container.decodeIfPresent(String.self, forKey: .include),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            contentName: try container.decodeIfPresent(String.self, forKey: .contentName),
            match: try container.decodeIfPresent(String.self, forKey: .match),
            captures: try container.decodeIfPresent(RawCaptures.self, forKey: .captures),
            begin: try container.decodeIfPresent(String.self, forKey: .begin),
            beginCaptures: try container.decodeIfPresent(
                RawCaptures.self,
                forKey: .beginCaptures
            ),
            end: try container.decodeIfPresent(String.self, forKey: .end),
            endCaptures: try container.decodeIfPresent(
                RawCaptures.self,
                forKey: .endCaptures
            ),
            whilePattern: try container.decodeIfPresent(String.self, forKey: .whilePattern),
            whileCaptures: try container.decodeIfPresent(
                RawCaptures.self,
                forKey: .whileCaptures
            ),
            patterns: try container.decodeIfPresent([RawRule].self, forKey: .patterns),
            repository: try container.decodeIfPresent(RawRepository.self, forKey: .repository),
            applyEndPatternLast: applyEndPatternLast,
            location: try container.decodeIfPresent(TextMateLocation.self, forKey: .location)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(include, forKey: .include)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(contentName, forKey: .contentName)
        try container.encodeIfPresent(match, forKey: .match)
        try container.encodeIfPresent(captures, forKey: .captures)
        try container.encodeIfPresent(begin, forKey: .begin)
        try container.encodeIfPresent(beginCaptures, forKey: .beginCaptures)
        try container.encodeIfPresent(end, forKey: .end)
        try container.encodeIfPresent(endCaptures, forKey: .endCaptures)
        try container.encodeIfPresent(whilePattern, forKey: .whilePattern)
        try container.encodeIfPresent(whileCaptures, forKey: .whileCaptures)
        try container.encodeIfPresent(patterns, forKey: .patterns)
        try container.encodeIfPresent(repository, forKey: .repository)
        try container.encodeIfPresent(applyEndPatternLast, forKey: .applyEndPatternLast)
        try container.encodeIfPresent(location, forKey: .location)
    }

    private enum CodingKeys: String, CodingKey {
        case include
        case name
        case contentName
        case match
        case captures
        case begin
        case beginCaptures
        case end
        case endCaptures
        case whilePattern = "while"
        case whileCaptures
        case patterns
        case repository
        case applyEndPatternLast
        case location = "$vscodeTextmateLocation"
    }
}

/// A raw TextMate grammar, before rules are compiled against Oniguruma.
public struct RawGrammar: Codable, Equatable, Sendable {
    public var repository: RawRepository
    public var scopeName: String
    public var patterns: [RawRule]
    public var injections: [String: RawRule]?
    public var injectionSelector: String?
    public var fileTypes: [String]?
    public var name: String?
    public var firstLineMatch: String?
    public var location: TextMateLocation?

    public init(
        scopeName: String,
        repository: RawRepository = [:],
        patterns: [RawRule] = [],
        injections: [String: RawRule]? = nil,
        injectionSelector: String? = nil,
        fileTypes: [String]? = nil,
        name: String? = nil,
        firstLineMatch: String? = nil,
        location: TextMateLocation? = nil
    ) {
        self.repository = repository
        self.scopeName = scopeName
        self.patterns = patterns
        self.injections = injections
        self.injectionSelector = injectionSelector
        self.fileTypes = fileTypes
        self.name = name
        self.firstLineMatch = firstLineMatch
        self.location = location
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repository = try container.decodeIfPresent(RawRepository.self, forKey: .repository) ?? [:]
        scopeName = try container.decode(String.self, forKey: .scopeName)
        patterns = try container.decodeIfPresent([RawRule].self, forKey: .patterns) ?? []
        injections = try container.decodeIfPresent([String: RawRule].self, forKey: .injections)
        injectionSelector = try container.decodeIfPresent(String.self, forKey: .injectionSelector)
        fileTypes = try container.decodeIfPresent([String].self, forKey: .fileTypes)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        firstLineMatch = try container.decodeIfPresent(String.self, forKey: .firstLineMatch)
        location = try container.decodeIfPresent(TextMateLocation.self, forKey: .location)
    }

    private enum CodingKeys: String, CodingKey {
        case repository
        case scopeName
        case patterns
        case injections
        case injectionSelector
        case fileTypes
        case name
        case firstLineMatch
        case location = "$vscodeTextmateLocation"
    }
}

public protocol RawGrammarRepresentable {
    var rawGrammar: RawGrammar { get }
}

extension RawGrammar: RawGrammarRepresentable {
    public var rawGrammar: RawGrammar { self }
}

/// Shiki's registration envelope, flattened into the same JSON object as its
/// underlying TextMate grammar.
public struct LanguageRegistration: Codable, Equatable, Sendable, RawGrammarRepresentable {
    public var name: String
    public var displayName: String?
    public var aliases: [String]?
    public var embeddedLangs: [String]?
    public var embeddedLanguages: [String]?
    public var embeddedLangsLazy: [String]?
    public var balancedBracketSelectors: [String]?
    public var unbalancedBracketSelectors: [String]?
    public var foldingStopMarker: String?
    public var foldingStartMarker: String?
    public var injectTo: [String]?

    private var grammar: RawGrammar

    public var rawGrammar: RawGrammar {
        var result = grammar
        result.name = name
        return result
    }

    public var scopeName: String { grammar.scopeName }
    public var repository: RawRepository { grammar.repository }
    public var patterns: [RawRule] { grammar.patterns }
    public var injections: [String: RawRule]? { grammar.injections }
    public var injectionSelector: String? { grammar.injectionSelector }
    public var fileTypes: [String]? { grammar.fileTypes }
    public var firstLineMatch: String? { grammar.firstLineMatch }
    public var location: TextMateLocation? { grammar.location }

    public init(
        name: String,
        grammar: RawGrammar,
        displayName: String? = nil,
        aliases: [String]? = nil,
        embeddedLangs: [String]? = nil,
        embeddedLanguages: [String]? = nil,
        embeddedLangsLazy: [String]? = nil,
        balancedBracketSelectors: [String]? = nil,
        unbalancedBracketSelectors: [String]? = nil,
        foldingStopMarker: String? = nil,
        foldingStartMarker: String? = nil,
        injectTo: [String]? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.aliases = aliases
        self.embeddedLangs = embeddedLangs
        self.embeddedLanguages = embeddedLanguages
        self.embeddedLangsLazy = embeddedLangsLazy
        self.balancedBracketSelectors = balancedBracketSelectors
        self.unbalancedBracketSelectors = unbalancedBracketSelectors
        self.foldingStopMarker = foldingStopMarker
        self.foldingStartMarker = foldingStartMarker
        self.injectTo = injectTo
        var registeredGrammar = grammar
        registeredGrammar.name = name
        self.grammar = registeredGrammar
    }

    public init(from decoder: Decoder) throws {
        grammar = try RawGrammar(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases)
        embeddedLangs = try container.decodeIfPresent([String].self, forKey: .embeddedLangs)
        embeddedLanguages = try container.decodeIfPresent([String].self, forKey: .embeddedLanguages)
        embeddedLangsLazy = try container.decodeIfPresent([String].self, forKey: .embeddedLangsLazy)
        balancedBracketSelectors = try container.decodeIfPresent(
            [String].self,
            forKey: .balancedBracketSelectors
        )
        unbalancedBracketSelectors = try container.decodeIfPresent(
            [String].self,
            forKey: .unbalancedBracketSelectors
        )
        foldingStopMarker = try container.decodeIfPresent(String.self, forKey: .foldingStopMarker)
        foldingStartMarker = try container.decodeIfPresent(String.self, forKey: .foldingStartMarker)
        injectTo = try container.decodeIfPresent([String].self, forKey: .injectTo)
    }

    public func encode(to encoder: Encoder) throws {
        try rawGrammar.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(aliases, forKey: .aliases)
        try container.encodeIfPresent(embeddedLangs, forKey: .embeddedLangs)
        try container.encodeIfPresent(embeddedLanguages, forKey: .embeddedLanguages)
        try container.encodeIfPresent(embeddedLangsLazy, forKey: .embeddedLangsLazy)
        try container.encodeIfPresent(balancedBracketSelectors, forKey: .balancedBracketSelectors)
        try container.encodeIfPresent(unbalancedBracketSelectors, forKey: .unbalancedBracketSelectors)
        try container.encodeIfPresent(foldingStopMarker, forKey: .foldingStopMarker)
        try container.encodeIfPresent(foldingStartMarker, forKey: .foldingStartMarker)
        try container.encodeIfPresent(injectTo, forKey: .injectTo)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case displayName
        case aliases
        case embeddedLangs
        case embeddedLanguages
        case embeddedLangsLazy
        case balancedBracketSelectors
        case unbalancedBracketSelectors
        case foldingStopMarker
        case foldingStartMarker
        case injectTo
    }
}

/// A map from a scope name to a nonzero TextMate language ID.
public typealias EmbeddedLanguagesMap = [String: Int]

/// A map from a scope selector to a standard token classification.
public typealias TokenTypeMap = [String: StandardTokenType]

/// Per-grammar configuration accepted by the TextMate registry.
public struct GrammarConfiguration: Codable, Equatable, Sendable {
    public var embeddedLanguages: EmbeddedLanguagesMap?
    public var tokenTypes: TokenTypeMap?
    public var balancedBracketSelectors: [String]?
    public var unbalancedBracketSelectors: [String]?

    public init(
        embeddedLanguages: EmbeddedLanguagesMap? = nil,
        tokenTypes: TokenTypeMap? = nil,
        balancedBracketSelectors: [String]? = nil,
        unbalancedBracketSelectors: [String]? = nil
    ) {
        self.embeddedLanguages = embeddedLanguages
        self.tokenTypes = tokenTypes
        self.balancedBracketSelectors = balancedBracketSelectors
        self.unbalancedBracketSelectors = unbalancedBracketSelectors
    }
}

private struct TextMateDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

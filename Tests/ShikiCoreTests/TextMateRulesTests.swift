import XCTest
@testable import ShikiCore

final class TextMateRulesTests: XCTestCase {
    func testParsesEveryIncludeReferenceKind() {
        XCTAssertEqual(parseInclude("$base"), .base)
        XCTAssertEqual(parseInclude("$self"), .selfReference)
        XCTAssertEqual(parseInclude("#strings"), .relative(ruleName: "strings"))
        XCTAssertEqual(parseInclude("source.swift"), .topLevel(scopeName: "source.swift"))
        XCTAssertEqual(
            parseInclude("source.swift#comments"),
            .topLevelRepository(scopeName: "source.swift", ruleName: "comments")
        )
        XCTAssertEqual(
            parseInclude("source.swift#"),
            .topLevelRepository(scopeName: "source.swift", ruleName: "")
        )
    }

    func testRegExpSourceRewritesZAndResolvesAAndGExactly() {
        let source = RegExpSource(#"\Afoo\Gbar\z"#, ruleID: 7)

        XCTAssertEqual(source.source, #"\Afoo\Gbar$(?!\n)(?<!\n)"#)
        XCTAssertTrue(source.hasAnchor)
        XCTAssertEqual(
            source.resolveAnchors(allowA: false, allowG: false),
            "\\\u{FFFF}foo\\\u{FFFF}bar$(?!\\n)(?<!\\n)"
        )
        XCTAssertEqual(
            source.resolveAnchors(allowA: false, allowG: true),
            "\\\u{FFFF}foo\\Gbar$(?!\\n)(?<!\\n)"
        )
        XCTAssertEqual(
            source.resolveAnchors(allowA: true, allowG: false),
            "\\Afoo\\\u{FFFF}bar$(?!\\n)(?<!\\n)"
        )
        XCTAssertEqual(
            source.resolveAnchors(allowA: true, allowG: true),
            #"\Afoo\Gbar$(?!\n)(?<!\n)"#
        )

        let escaped = RegExpSource(#"\\A"#, ruleID: 8)
        XCTAssertFalse(escaped.hasAnchor)
        XCTAssertEqual(escaped.resolveAnchors(allowA: false, allowG: false), #"\\A"#)
    }

    func testScopeCaptureReplacementUsesUTF16OffsetsCommandsAndLeadingDotRemoval() {
        let line = "🙂.foo.bar"
        let captures = [
            OnigCaptureIndex(start: 0, end: 10),
            OnigCaptureIndex(start: 2, end: 6),
            OnigCaptureIndex(start: 6, end: 10),
        ]

        XCTAssertTrue(RegexSource.hasCaptures("entity.$1.${2:/upcase}"))
        XCTAssertFalse(RegexSource.hasCaptures("entity.name"))
        XCTAssertEqual(
            RegexSource.replaceCaptures(
                "entity.$1.${2:/upcase}.${1:/downcase}.$9",
                captureSource: line,
                captureIndices: captures
            ),
            "entity.foo.BAR.foo.$9"
        )
    }

    func testBackReferenceResolutionUsesUTF16AndEscapesOnigurumaCharacters() {
        let source = RegExpSource(#"^\1:\2:\9$"#, ruleID: endRuleID)
        let line = "🙂a.b c"
        let captures = [
            OnigCaptureIndex(start: 0, end: 7),
            OnigCaptureIndex(start: 2, end: 5),
            OnigCaptureIndex(start: 5, end: 7),
        ]

        XCTAssertTrue(source.hasBackReferences)
        XCTAssertEqual(
            source.resolveBackReferences(lineText: line, captureIndices: captures),
            #"^a\.b:\ c:$"#
        )
    }

    func testCompiledRulePreservesScannerPatternOrderingAndRuleMapping() throws {
        let context = TestGrammarContext()
        let factory = RuleFactory()
        let descriptor = RawRule(
            name: "meta.block.test",
            begin: #"BEGIN"#,
            end: #"END"#,
            patterns: [
                RawRule(name: "word.test", match: #"[a-z]+"#),
                RawRule(name: "number.test", match: #"\d+"#),
            ]
        )

        let id = factory.getCompiledRuleID(descriptor, helper: context, repository: [:])
        let rule = try XCTUnwrap(context.rule(with: id) as? BeginEndRule)
        let compiled = try rule.compile(context, endRegexSource: nil)

        XCTAssertEqual(compiled.regularExpressions, ["END", "[a-z]+", #"\d+"#])
        XCTAssertEqual(compiled.ruleIDs.first, endRuleID)
        XCTAssertEqual(compiled.ruleIDs.dropFirst(), rule.patterns[...])

        let end = try XCTUnwrap(compiled.findNextMatchSync("xx END 42", startPosition: 3))
        XCTAssertEqual(end.ruleID, endRuleID)
        XCTAssertEqual(end.captureIndices[0], OnigCaptureIndex(start: 3, end: 6))

        let tie = try XCTUnwrap(compiled.findNextMatchSync("42", startPosition: 0))
        XCTAssertEqual(tie.ruleID, rule.patterns[1])
    }

    func testApplyEndPatternLastMovesOnlyTheSyntheticEndPattern() throws {
        let context = TestGrammarContext()
        let factory = RuleFactory()
        let descriptor = RawRule(
            begin: "BEGIN",
            end: "same",
            patterns: [RawRule(match: "same")],
            applyEndPatternLast: true
        )

        let id = factory.getCompiledRuleID(descriptor, helper: context, repository: [:])
        let rule = try XCTUnwrap(context.rule(with: id) as? BeginEndRule)
        let compiled = try rule.compile(context, endRegexSource: nil)

        XCTAssertEqual(compiled.regularExpressions, ["same", "same"])
        XCTAssertEqual(compiled.ruleIDs, [rule.patterns[0], endRuleID])
        XCTAssertEqual(
            try compiled.findNextMatchSync("same", startPosition: 0)?.ruleID,
            rule.patterns[0]
        )
    }

    func testFactoryCreatesAllRuleKindsAndCompilesCaptureRetokenization() throws {
        let context = TestGrammarContext()
        let factory = RuleFactory()

        let matchID = factory.getCompiledRuleID(
            RawRule(
                name: "entity.$1",
                match: "(x)",
                captures: [
                    "1": RawRule(name: "capture.one"),
                    "3": RawRule(
                        name: "capture.three",
                        patterns: [RawRule(match: "x")]
                    ),
                ]
            ),
            helper: context,
            repository: [:]
        )
        let match = try XCTUnwrap(context.rule(with: matchID) as? MatchRule)
        XCTAssertEqual(match.captures.count, 4)
        XCTAssertNil(match.captures[0])
        XCTAssertEqual(match.captures[1]?.getName(lineText: nil, captureIndices: nil), "capture.one")
        XCTAssertNil(match.captures[2])
        XCTAssertNotEqual(match.captures[3]?.retokenizeCapturedWithRuleID, 0)

        let includeID = factory.getCompiledRuleID(
            RawRule(patterns: [RawRule(match: "x")]),
            helper: context,
            repository: [:]
        )
        XCTAssertTrue(context.rule(with: includeID) is IncludeOnlyRule)

        let beginEndID = factory.getCompiledRuleID(
            RawRule(begin: "x", end: "y", whilePattern: ""),
            helper: context,
            repository: [:]
        )
        XCTAssertTrue(context.rule(with: beginEndID) is BeginEndRule)

        let beginWhileID = factory.getCompiledRuleID(
            RawRule(begin: "x", whilePattern: "y"),
            helper: context,
            repository: [:]
        )
        XCTAssertTrue(context.rule(with: beginWhileID) is BeginWhileRule)
    }

    func testCaptureNamesResolveFromUTF16MatchOffsets() throws {
        let context = TestGrammarContext()
        let factory = RuleFactory()
        let id = factory.getCompiledRuleID(
            RawRule(name: "entity.$1.${2:/upcase}", match: "x"),
            helper: context,
            repository: [:]
        )
        let rule = try XCTUnwrap(context.rule(with: id))

        XCTAssertEqual(
            rule.getName(
                lineText: "🙂.foo.bar",
                captureIndices: [
                    OnigCaptureIndex(start: 0, end: 10),
                    OnigCaptureIndex(start: 2, end: 6),
                    OnigCaptureIndex(start: 6, end: 10),
                ]
            ),
            "entity.foo.BAR"
        )
    }

    func testLocalBaseSelfAndExternalIncludesFlattenInSourceOrder() throws {
        let context = TestGrammarContext()
        let factory = RuleFactory()

        var externalRepository: RawRepository = [
            "named": RawRule(match: "external-named")
        ]
        externalRepository["$self"] = RawRule(patterns: [RawRule(match: "external-self")])
        externalRepository["$base"] = externalRepository["$self"]
        context.externalGrammars["source.external"] = RawGrammar(
            scopeName: "source.external",
            repository: externalRepository
        )

        let repository: RawRepository = [
            "$base": RawRule(match: "base"),
            "$self": RawRule(match: "self"),
            "local": RawRule(match: "local"),
        ]
        let descriptor = RawRule(patterns: [
            RawRule(include: "$base"),
            RawRule(include: "$self"),
            RawRule(include: "#local"),
            RawRule(include: "source.external"),
            RawRule(include: "source.external#named"),
        ])

        let id = factory.getCompiledRuleID(
            descriptor,
            helper: context,
            repository: repository
        )
        let rule = try XCTUnwrap(context.rule(with: id) as? IncludeOnlyRule)
        let compiled = try rule.compile(context, endRegexSource: nil)

        XCTAssertEqual(
            compiled.regularExpressions,
            ["base", "self", "local", "external-self", "external-named"]
        )
    }

    func testMissingIncludesAreTrackedAndEmptyMissingAggregatesAreRemoved() throws {
        let context = TestGrammarContext()
        let factory = RuleFactory()
        let descriptor = RawRule(patterns: [
            RawRule(patterns: [RawRule(include: "#does-not-exist")]),
            RawRule(include: "#also-missing"),
            RawRule(match: "kept"),
        ])

        let id = factory.getCompiledRuleID(descriptor, helper: context, repository: [:])
        let rule = try XCTUnwrap(context.rule(with: id) as? IncludeOnlyRule)

        XCTAssertTrue(rule.hasMissingPatterns)
        XCTAssertEqual(rule.patterns.count, 1)
        XCTAssertTrue(context.rule(with: rule.patterns[0]) is MatchRule)
        XCTAssertEqual(
            try rule.compile(context, endRegexSource: nil).regularExpressions,
            ["kept"]
        )
    }

    func testRecursiveSelfRegistrationTerminatesAndReusesRuleID() throws {
        let context = TestGrammarContext()
        let factory = RuleFactory()
        let selfRule = RawRule(
            name: "source.recursive",
            patterns: [RawRule(include: "$self")]
        )
        let repository: RawRepository = ["$self": selfRule, "$base": selfRule]

        let first = factory.getCompiledRuleID(
            selfRule,
            helper: context,
            repository: repository
        )
        let second = factory.getCompiledRuleID(
            repository["$self"]!,
            helper: context,
            repository: repository
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(context.registeredRuleCount, 1)
        XCTAssertEqual((context.rule(with: first) as? IncludeOnlyRule)?.patterns, [first])
    }

    func testRuleFactoryMemoizesDescriptorIdentityInsteadOfStructuralEquality() {
        let context = TestGrammarContext()
        let factory = RuleFactory()
        let descriptor = RawRule(match: "same")
        let descriptorCopy = descriptor
        let structurallyEqualDescriptor = RawRule(match: "same")

        let first = factory.getCompiledRuleID(
            descriptor,
            helper: context,
            repository: ["first": RawRule(match: "first")]
        )
        let copied = factory.getCompiledRuleID(
            descriptorCopy,
            helper: context,
            repository: ["second": RawRule(match: "second")]
        )
        let structurallyEqual = factory.getCompiledRuleID(
            structurallyEqualDescriptor,
            helper: context,
            repository: ["first": RawRule(match: "first")]
        )

        XCTAssertEqual(descriptor, structurallyEqualDescriptor)
        XCTAssertEqual(first, copied)
        XCTAssertNotEqual(first, structurallyEqual)
        XCTAssertEqual(context.registeredRuleCount, 2)
    }

    func testRawRuleCopyOnWritePreservesValueSemanticsAndCompilerIdentity() {
        let original = RawRule(name: "original", match: "x")
        let originalIdentity = original.compilerIdentity
        var modified = original

        XCTAssertEqual(modified.compilerIdentity, originalIdentity)
        modified.name = "modified"

        XCTAssertEqual(original.name, "original")
        XCTAssertEqual(modified.name, "modified")
        XCTAssertNotEqual(modified.compilerIdentity, originalIdentity)
        XCTAssertEqual(
            MemoryLayout<RawRule>.size,
            MemoryLayout<UnsafeRawPointer>.size,
            "RawRule must remain reference-sized for recursive grammar compilation"
        )
    }

    func testDeepDescriptorCompilationFitsCooperativeExecutorStack() async {
        var descriptor = RawRule(name: "leaf", match: "leaf")
        for depth in 0..<64 {
            let capture = RawRule(name: "capture.\(depth)")
            descriptor = RawRule(
                name: "level.\(depth)",
                begin: "begin",
                beginCaptures: ["0": capture],
                end: "end",
                endCaptures: ["0": capture],
                patterns: [descriptor]
            )
        }

        let registeredRuleCount = await Task.detached {
            let context = TestGrammarContext()
            let factory = RuleFactory()
            _ = factory.getCompiledRuleID(
                descriptor,
                helper: context,
                repository: [:]
            )
            return context.registeredRuleCount
        }.value

        XCTAssertEqual(registeredRuleCount, 65 + (64 * 2))
    }

    func testBeginEndAndWhileBackReferencesUpdateCachedScannerSources() throws {
        let context = TestGrammarContext()
        let factory = RuleFactory()

        let endID = factory.getCompiledRuleID(
            RawRule(begin: #"(['\"])"#, end: #"\1"#),
            helper: context,
            repository: [:]
        )
        let endRule = try XCTUnwrap(context.rule(with: endID) as? BeginEndRule)
        XCTAssertTrue(endRule.endHasBackReferences)
        let resolvedEnd = endRule.getEndWithResolvedBackReferences(
            lineText: "'",
            captureIndices: [
                OnigCaptureIndex(start: 0, end: 1),
                OnigCaptureIndex(start: 0, end: 1),
            ]
        )
        XCTAssertEqual(resolvedEnd, #"'"#)
        XCTAssertEqual(
            try endRule.compile(context, endRegexSource: resolvedEnd).regularExpressions,
            ["'"]
        )

        let whileID = factory.getCompiledRuleID(
            RawRule(begin: "(x)", whilePattern: #"^\1"#),
            helper: context,
            repository: [:]
        )
        let whileRule = try XCTUnwrap(context.rule(with: whileID) as? BeginWhileRule)
        XCTAssertTrue(whileRule.whileHasBackReferences)
        XCTAssertEqual(
            whileRule.getWhileWithResolvedBackReferences(
                lineText: "x",
                captureIndices: [
                    OnigCaptureIndex(start: 0, end: 1),
                    OnigCaptureIndex(start: 0, end: 1),
                ]
            ),
            "^x"
        )
        let compiledWhile = try whileRule.compileWhile(context, endRegexSource: "^x")
        XCTAssertEqual(compiledWhile.regularExpressions, ["^x"])
        XCTAssertEqual(compiledWhile.ruleIDs, [whileRuleID])
    }

    func testAnchorCompilationCachesAllCombinationsAndDisposesScanners() throws {
        let library = RecordingOnigLibrary()
        let list = RegExpSourceList()
        list.push(RegExpSource(#"\Afoo\G"#, ruleID: 11))

        let a0g0 = try list.compileAG(library, allowA: false, allowG: false)
        let a0g0Again = try list.compileAG(library, allowA: false, allowG: false)
        let a1g1 = try list.compileAG(library, allowA: true, allowG: true)

        XCTAssertTrue(a0g0 === a0g0Again)
        XCTAssertFalse(a0g0 === a1g1)
        XCTAssertEqual(library.sources.count, 2)
        XCTAssertEqual(library.sources[0], ["\\\u{FFFF}foo\\\u{FFFF}"])
        XCTAssertEqual(library.sources[1], [#"\Afoo\G"#])

        list.dispose()
        XCTAssertEqual(library.scanners.map(\.disposeCount), [1, 1])
        XCTAssertThrowsError(
            try a0g0.findNextMatchSync("foo", startPosition: 0)
        ) { error in
            XCTAssertEqual(error as? TextMateRuleError, .disposedCompiledRule)
        }
    }
}

private final class TestGrammarContext:
    TextMateRuleFactoryHelper, TextMateRuleCompilerContext
{
    private var lastRuleID = 0
    private var rules: [RuleID: Rule] = [:]
    var externalGrammars: [String: RawGrammar] = [:]

    var registeredRuleCount: Int { rules.count }

    func rule(with ruleID: RuleID) -> Rule? {
        rules[ruleID]
    }

    func registerRule(_ factory: (RuleID) -> Rule) -> Rule {
        lastRuleID += 1
        let id = lastRuleID
        let rule = factory(id)
        rules[id] = rule
        return rule
    }

    func externalGrammar(
        scopeName: String,
        repository: RawRepository
    ) -> RawGrammar? {
        externalGrammars[scopeName]
    }

    func createOnigScanner(_ sources: [String]) throws -> any TextMateOnigScanner {
        try OnigScanner(patterns: sources)
    }

    func createOnigString(_ string: String) -> OnigString {
        OnigString(string)
    }
}

private final class RecordingOnigLibrary: TextMateOnigLibrary {
    var sources: [[String]] = []
    var scanners: [RecordingScanner] = []

    func createOnigScanner(_ sources: [String]) throws -> any TextMateOnigScanner {
        self.sources.append(sources)
        let scanner = RecordingScanner()
        scanners.append(scanner)
        return scanner
    }
}

private final class RecordingScanner: TextMateOnigScanner {
    var disposeCount = 0

    func findNextMatchSync(
        _ string: String,
        startPosition: Int,
        options: OnigFindOptions
    ) throws -> OnigMatch? {
        nil
    }

    func findNextMatchSync(
        _ string: OnigString,
        startPosition: Int,
        options: OnigFindOptions
    ) throws -> OnigMatch? {
        nil
    }

    func dispose() {
        disposeCount += 1
    }
}

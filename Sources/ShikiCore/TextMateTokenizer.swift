/*---------------------------------------------------------
 * Copyright (C) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------*/

import Foundation

/// The scope-bearing result of tokenizing one line.
///
/// All token indices use UTF-16 code units, matching JavaScript strings,
/// `vscode-textmate`, and Shiki's public token contract.
public struct TokenizeLineResult: Sendable {
    public let tokens: [TextMateToken]
    public let ruleStack: StateStackImpl
    public let stoppedEarly: Bool

    public init(
        tokens: [TextMateToken],
        ruleStack: StateStackImpl,
        stoppedEarly: Bool
    ) {
        self.tokens = tokens
        self.ruleStack = ruleStack
        self.stoppedEarly = stoppedEarly
    }
}

/// The metadata-packed result of tokenizing one line.
///
/// Each token occupies two entries: its UTF-16 start offset followed by its
/// encoded TextMate metadata.
public struct TokenizeLineResult2: Sendable {
    public let tokens: [UInt32]
    public let ruleStack: StateStackImpl
    public let stoppedEarly: Bool

    public init(
        tokens: [UInt32],
        ruleStack: StateStackImpl,
        stoppedEarly: Bool
    ) {
        self.tokens = tokens
        self.ruleStack = ruleStack
        self.stoppedEarly = stoppedEarly
    }
}

/// Internal scanner-loop result, exposed for parity with `_tokenizeString`.
public struct TokenizeStringResult: Sendable {
    public let stack: StateStackImpl
    public let stoppedEarly: Bool

    public init(stack: StateStackImpl, stoppedEarly: Bool) {
        self.stack = stack
        self.stoppedEarly = stoppedEarly
    }
}

public enum TextMateTokenizerError:
    Error, Equatable, Sendable, CustomStringConvertible
{
    case scannerReturnedNoCaptures
    case unexpectedEndRule(RuleID)

    public var description: String {
        switch self {
        case .scannerReturnedNoCaptures:
            "A TextMate scanner match did not contain its full-match capture."
        case let .unexpectedEndRule(ruleID):
            "Synthetic end rule matched while rule \(ruleID) was not a begin/end rule."
        }
    }
}

public extension Grammar {
    /// Tokenizes one logical line and emits scope arrays.
    ///
    /// `timeLimit` is measured in milliseconds. Zero disables the limit.
    func tokenizeLine(
        _ lineText: String,
        previousState: StateStackImpl? = nil,
        timeLimit: Int = 0
    ) throws -> TokenizeLineResult {
        let result = try tokenize(
            lineText,
            previousState: previousState,
            emitBinaryTokens: false,
            timeLimit: timeLimit
        )
        return TokenizeLineResult(
            tokens: result.lineTokens.getResult(
                result.ruleStack,
                lineLength: result.lineLength
            ),
            ruleStack: result.ruleStack,
            stoppedEarly: result.stoppedEarly
        )
    }

    /// Compatibility overload matching `vscode-textmate`'s `prevState` label.
    func tokenizeLine(
        _ lineText: String,
        prevState: StateStackImpl?,
        timeLimit: Int = 0
    ) throws -> TokenizeLineResult {
        try tokenizeLine(
            lineText,
            previousState: prevState,
            timeLimit: timeLimit
        )
    }

    /// Tokenizes one logical line and emits packed metadata pairs.
    func tokenizeLine2(
        _ lineText: String,
        previousState: StateStackImpl? = nil,
        timeLimit: Int = 0
    ) throws -> TokenizeLineResult2 {
        let result = try tokenize(
            lineText,
            previousState: previousState,
            emitBinaryTokens: true,
            timeLimit: timeLimit
        )
        return TokenizeLineResult2(
            tokens: result.lineTokens.getBinaryResult(
                result.ruleStack,
                lineLength: result.lineLength
            ),
            ruleStack: result.ruleStack,
            stoppedEarly: result.stoppedEarly
        )
    }

    /// Compatibility overload matching `vscode-textmate`'s `prevState` label.
    func tokenizeLine2(
        _ lineText: String,
        prevState: StateStackImpl?,
        timeLimit: Int = 0
    ) throws -> TokenizeLineResult2 {
        try tokenizeLine2(
            lineText,
            previousState: prevState,
            timeLimit: timeLimit
        )
    }

    private func tokenize(
        _ sourceLine: String,
        previousState: StateStackImpl?,
        emitBinaryTokens: Bool,
        timeLimit: Int
    ) throws -> (
        lineLength: Int,
        lineTokens: LineTokens,
        ruleStack: StateStackImpl,
        stoppedEarly: Bool
    ) {
        let initial = stateForTokenizingLine(previousState: previousState)

        // vscode-textmate always adds a sentinel newline. Grammar patterns can
        // consume it, and LineTokens removes the sentinel-only final token.
        let lineText = sourceLine + "\n"
        let onigLineText = createOnigString(lineText)
        let lineLength = onigLineText.utf16Length
        let lineTokens = makeLineTokens(
            emitBinaryTokens: emitBinaryTokens,
            lineText: lineText
        )
        let result = try tokenizeString(
            grammar: self,
            lineText: onigLineText,
            isFirstLine: initial.isFirstLine,
            linePosition: 0,
            stack: initial.state,
            lineTokens: lineTokens,
            checkWhileConditions: true,
            timeLimit: timeLimit
        )

        return (
            lineLength,
            lineTokens,
            result.stack,
            result.stoppedEarly
        )
    }
}

/// Native port of `vscode-textmate`'s `_tokenizeString` scanner loop.
public func tokenizeString(
    grammar: Grammar,
    lineText: OnigString,
    isFirstLine initialIsFirstLine: Bool,
    linePosition initialLinePosition: Int,
    stack initialStack: StateStackImpl,
    lineTokens: LineTokens,
    checkWhileConditions: Bool,
    timeLimit: Int
) throws -> TokenizeStringResult {
    let lineLength = lineText.utf16Length
    var isFirstLine = initialIsFirstLine
    var linePosition = initialLinePosition
    var stack = initialStack
    var anchorPosition = -1

    if checkWhileConditions {
        let result = try checkWhileConditionsForLine(
            grammar: grammar,
            lineText: lineText,
            isFirstLine: isFirstLine,
            linePosition: linePosition,
            stack: stack,
            lineTokens: lineTokens
        )
        stack = result.stack
        linePosition = result.linePosition
        isFirstLine = result.isFirstLine
        anchorPosition = result.anchorPosition
    }

    let startTime = Date().timeIntervalSince1970
    while true {
        if timeLimit != 0 {
            let elapsedMilliseconds = Int(
                (Date().timeIntervalSince1970 - startTime) * 1_000
            )
            if elapsedMilliseconds > timeLimit {
                return TokenizeStringResult(stack: stack, stoppedEarly: true)
            }
        }

        guard let result = try matchRuleOrInjections(
            grammar: grammar,
            lineText: lineText,
            isFirstLine: isFirstLine,
            linePosition: linePosition,
            stack: stack,
            anchorPosition: anchorPosition
        ) else {
            lineTokens.produce(stack, endIndex: lineLength)
            return TokenizeStringResult(stack: stack, stoppedEarly: false)
        }

        let captureIndices = result.captureIndices
        guard let fullMatch = captureIndices.first else {
            throw TextMateTokenizerError.scannerReturnedNoCaptures
        }
        let hasAdvanced = fullMatch.end > linePosition

        if result.matchedRuleID == endRuleID {
            guard let poppedRule = stack.getRule(grammar) as? BeginEndRule else {
                throw TextMateTokenizerError.unexpectedEndRule(stack.ruleID)
            }

            lineTokens.produce(stack, endIndex: fullMatch.start)
            if let nameScopesList = stack.nameScopesList {
                stack = stack.withContentNameScopesList(nameScopesList)
            }
            try handleCaptures(
                grammar: grammar,
                lineText: lineText,
                isFirstLine: isFirstLine,
                stack: stack,
                lineTokens: lineTokens,
                captures: poppedRule.endCaptures,
                captureIndices: captureIndices
            )
            lineTokens.produce(stack, endIndex: fullMatch.end)

            let popped = stack
            guard let parent = stack.parent else {
                throw TextMateTokenizerError.unexpectedEndRule(stack.ruleID)
            }
            stack = parent
            anchorPosition = popped.getAnchorPos()

            if !hasAdvanced && popped.getEnterPos() == linePosition {
                // A rule was pushed and popped without consuming input. Keep
                // the pushed state, emit the remainder, and stop this line.
                stack = popped
                lineTokens.produce(stack, endIndex: lineLength)
                return TokenizeStringResult(stack: stack, stoppedEarly: false)
            }
        } else {
            let rule = grammar.getRule(result.matchedRuleID)
            lineTokens.produce(stack, endIndex: fullMatch.start)

            let beforePush = stack
            let scopeName = rule.getName(
                lineText: lineText.content,
                captureIndices: captureIndices
            )
            guard let currentContentScopes = stack.contentNameScopesList else {
                preconditionFailure("A tokenizing state must carry content scopes.")
            }
            let nameScopesList = currentContentScopes.pushAttributed(
                scopeName,
                grammar
            )
            stack = stack.push(
                ruleID: result.matchedRuleID,
                enterPos: linePosition,
                anchorPos: anchorPosition,
                beginRuleCapturedEOL: fullMatch.end == lineLength,
                endRule: nil,
                nameScopesList: nameScopesList,
                contentNameScopesList: nameScopesList
            )

            if let pushedRule = rule as? BeginEndRule {
                try handleCaptures(
                    grammar: grammar,
                    lineText: lineText,
                    isFirstLine: isFirstLine,
                    stack: stack,
                    lineTokens: lineTokens,
                    captures: pushedRule.beginCaptures,
                    captureIndices: captureIndices
                )
                lineTokens.produce(stack, endIndex: fullMatch.end)
                anchorPosition = fullMatch.end

                let contentName = pushedRule.getContentName(
                    lineText: lineText.content,
                    captureIndices: captureIndices
                )
                let contentNameScopesList = nameScopesList.pushAttributed(
                    contentName,
                    grammar
                )
                stack = stack.withContentNameScopesList(contentNameScopesList)

                if pushedRule.endHasBackReferences {
                    stack = stack.withEndRule(
                        pushedRule.getEndWithResolvedBackReferences(
                            lineText: lineText.content,
                            captureIndices: captureIndices
                        )
                    )
                }

                if !hasAdvanced && beforePush.hasSameRuleAs(stack) {
                    guard let parent = stack.pop() else {
                        preconditionFailure("A just-pushed state must have a parent.")
                    }
                    stack = parent
                    lineTokens.produce(stack, endIndex: lineLength)
                    return TokenizeStringResult(stack: stack, stoppedEarly: false)
                }
            } else if let pushedRule = rule as? BeginWhileRule {
                try handleCaptures(
                    grammar: grammar,
                    lineText: lineText,
                    isFirstLine: isFirstLine,
                    stack: stack,
                    lineTokens: lineTokens,
                    captures: pushedRule.beginCaptures,
                    captureIndices: captureIndices
                )
                lineTokens.produce(stack, endIndex: fullMatch.end)
                anchorPosition = fullMatch.end

                let contentName = pushedRule.getContentName(
                    lineText: lineText.content,
                    captureIndices: captureIndices
                )
                let contentNameScopesList = nameScopesList.pushAttributed(
                    contentName,
                    grammar
                )
                stack = stack.withContentNameScopesList(contentNameScopesList)

                if pushedRule.whileHasBackReferences {
                    stack = stack.withEndRule(
                        pushedRule.getWhileWithResolvedBackReferences(
                            lineText: lineText.content,
                            captureIndices: captureIndices
                        )
                    )
                }

                if !hasAdvanced && beforePush.hasSameRuleAs(stack) {
                    guard let parent = stack.pop() else {
                        preconditionFailure("A just-pushed state must have a parent.")
                    }
                    stack = parent
                    lineTokens.produce(stack, endIndex: lineLength)
                    return TokenizeStringResult(stack: stack, stoppedEarly: false)
                }
            } else {
                guard let matchingRule = rule as? MatchRule else {
                    preconditionFailure("A scanner emitted a non-match leaf rule.")
                }
                try handleCaptures(
                    grammar: grammar,
                    lineText: lineText,
                    isFirstLine: isFirstLine,
                    stack: stack,
                    lineTokens: lineTokens,
                    captures: matchingRule.captures,
                    captureIndices: captureIndices
                )
                lineTokens.produce(stack, endIndex: fullMatch.end)

                guard let parent = stack.pop() else {
                    preconditionFailure("A just-pushed match state must have a parent.")
                }
                stack = parent

                if !hasAdvanced {
                    stack = stack.safePop()
                    lineTokens.produce(stack, endIndex: lineLength)
                    return TokenizeStringResult(stack: stack, stoppedEarly: false)
                }
            }
        }

        if fullMatch.end > linePosition {
            linePosition = fullMatch.end
            isFirstLine = false
        }
    }
}

private struct WhileCheckResult {
    let stack: StateStackImpl
    let linePosition: Int
    let anchorPosition: Int
    let isFirstLine: Bool
}

/// Walks begin/while states from bottom to top before normal line scanning.
private func checkWhileConditionsForLine(
    grammar: Grammar,
    lineText: OnigString,
    isFirstLine initialIsFirstLine: Bool,
    linePosition initialLinePosition: Int,
    stack initialStack: StateStackImpl,
    lineTokens: LineTokens
) throws -> WhileCheckResult {
    var stack = initialStack
    var linePosition = initialLinePosition
    var isFirstLine = initialIsFirstLine
    var anchorPosition = stack.beginRuleCapturedEOL ? 0 : -1

    var whileRules: [(stack: StateStackImpl, rule: BeginWhileRule)] = []
    var node: StateStackImpl? = stack
    while let current = node {
        if let rule = current.getRule(grammar) as? BeginWhileRule {
            whileRules.append((current, rule))
        }
        node = current.pop()
    }

    while let whileEntry = whileRules.popLast() {
        let prepared = try prepareWhileSearch(
            rule: whileEntry.rule,
            grammar: grammar,
            endRegexSource: whileEntry.stack.endRule,
            allowA: isFirstLine,
            allowG: linePosition == anchorPosition
        )
        let match = try prepared.scanner.findNextMatchSync(
            lineText,
            startPosition: linePosition,
            options: prepared.options
        )

        if let match {
            if match.ruleID != whileRuleID {
                guard let parent = whileEntry.stack.pop() else {
                    preconditionFailure("A begin/while state must have a parent.")
                }
                stack = parent
                break
            }
            if let fullMatch = match.captureIndices.first {
                lineTokens.produce(whileEntry.stack, endIndex: fullMatch.start)
                try handleCaptures(
                    grammar: grammar,
                    lineText: lineText,
                    isFirstLine: isFirstLine,
                    stack: whileEntry.stack,
                    lineTokens: lineTokens,
                    captures: whileEntry.rule.whileCaptures,
                    captureIndices: match.captureIndices
                )
                lineTokens.produce(whileEntry.stack, endIndex: fullMatch.end)
                anchorPosition = fullMatch.end
                if fullMatch.end > linePosition {
                    linePosition = fullMatch.end
                    isFirstLine = false
                }
            }
        } else {
            guard let parent = whileEntry.stack.pop() else {
                preconditionFailure("A begin/while state must have a parent.")
            }
            stack = parent
            break
        }
    }

    return WhileCheckResult(
        stack: stack,
        linePosition: linePosition,
        anchorPosition: anchorPosition,
        isFirstLine: isFirstLine
    )
}

private struct RuleMatchResult {
    let captureIndices: [OnigCaptureIndex]
    let matchedRuleID: RuleID
}

private struct InjectionMatchResult {
    let priorityMatch: Bool
    let captureIndices: [OnigCaptureIndex]
    let matchedRuleID: RuleID
}

private func matchRuleOrInjections(
    grammar: Grammar,
    lineText: OnigString,
    isFirstLine: Bool,
    linePosition: Int,
    stack: StateStackImpl,
    anchorPosition: Int
) throws -> RuleMatchResult? {
    let ruleMatch = try matchRule(
        grammar: grammar,
        lineText: lineText,
        isFirstLine: isFirstLine,
        linePosition: linePosition,
        stack: stack,
        anchorPosition: anchorPosition
    )

    let injections = grammar.getInjections()
    if injections.isEmpty {
        return ruleMatch
    }

    guard let injectionMatch = try matchInjections(
        injections,
        grammar: grammar,
        lineText: lineText,
        isFirstLine: isFirstLine,
        linePosition: linePosition,
        stack: stack,
        anchorPosition: anchorPosition
    ) else {
        return ruleMatch
    }
    guard let ruleMatch else {
        return RuleMatchResult(
            captureIndices: injectionMatch.captureIndices,
            matchedRuleID: injectionMatch.matchedRuleID
        )
    }
    guard
        let normalStart = ruleMatch.captureIndices.first?.start,
        let injectionStart = injectionMatch.captureIndices.first?.start
    else {
        throw TextMateTokenizerError.scannerReturnedNoCaptures
    }

    if injectionStart < normalStart
        || (injectionMatch.priorityMatch && injectionStart == normalStart)
    {
        return RuleMatchResult(
            captureIndices: injectionMatch.captureIndices,
            matchedRuleID: injectionMatch.matchedRuleID
        )
    }
    return ruleMatch
}

private func matchRule(
    grammar: Grammar,
    lineText: OnigString,
    isFirstLine: Bool,
    linePosition: Int,
    stack: StateStackImpl,
    anchorPosition: Int
) throws -> RuleMatchResult? {
    let rule = stack.getRule(grammar)
    let prepared = try prepareSearch(
        rule: rule,
        grammar: grammar,
        endRegexSource: stack.endRule,
        allowA: isFirstLine,
        allowG: linePosition == anchorPosition
    )
    guard let match = try prepared.scanner.findNextMatchSync(
        lineText,
        startPosition: linePosition,
        options: prepared.options
    ) else {
        return nil
    }
    return RuleMatchResult(
        captureIndices: match.captureIndices,
        matchedRuleID: match.ruleID
    )
}

private func matchInjections(
    _ injections: [Injection],
    grammar: Grammar,
    lineText: OnigString,
    isFirstLine: Bool,
    linePosition: Int,
    stack: StateStackImpl,
    anchorPosition: Int
) throws -> InjectionMatchResult? {
    var bestMatchRating = Int.max
    var bestCaptureIndices: [OnigCaptureIndex]?
    var bestRuleID = 0
    var bestPriority = 0
    let scopes = stack.contentNameScopesList?.getScopeNames() ?? []

    for injection in injections {
        guard injection.matcher(scopes) else { continue }
        let rule = grammar.getRule(injection.ruleID)
        let prepared = try prepareSearch(
            rule: rule,
            grammar: grammar,
            endRegexSource: nil,
            allowA: isFirstLine,
            allowG: linePosition == anchorPosition
        )
        guard
            let match = try prepared.scanner.findNextMatchSync(
                lineText,
                startPosition: linePosition,
                options: prepared.options
            ),
            let fullMatch = match.captureIndices.first
        else { continue }

        let rating = fullMatch.start
        if rating >= bestMatchRating {
            continue
        }

        bestMatchRating = rating
        bestCaptureIndices = match.captureIndices
        bestRuleID = match.ruleID
        bestPriority = injection.priority

        if bestMatchRating == linePosition {
            break
        }
    }

    guard let bestCaptureIndices else { return nil }
    return InjectionMatchResult(
        priorityMatch: bestPriority == -1,
        captureIndices: bestCaptureIndices,
        matchedRuleID: bestRuleID
    )
}

private typealias PreparedSearch = (
    scanner: CompiledRule,
    options: OnigFindOptions
)

// This release of vscode-textmate has UseOnigurumaFindOptions=false. Anchor
// rewriting through compileAG is therefore the compatibility path; the helper
// below remains the exact equivalent of the alternate native-options path.
private let useOnigurumaFindOptions = false

private func prepareSearch(
    rule: Rule,
    grammar: Grammar,
    endRegexSource: String?,
    allowA: Bool,
    allowG: Bool
) throws -> PreparedSearch {
    if useOnigurumaFindOptions {
        return (
            try rule.compile(grammar, endRegexSource: endRegexSource),
            findOptions(allowA: allowA, allowG: allowG)
        )
    }
    return (
        try rule.compileAG(
            grammar,
            endRegexSource: endRegexSource,
            allowA: allowA,
            allowG: allowG
        ),
        []
    )
}

private func prepareWhileSearch(
    rule: BeginWhileRule,
    grammar: Grammar,
    endRegexSource: String?,
    allowA: Bool,
    allowG: Bool
) throws -> PreparedSearch {
    if useOnigurumaFindOptions {
        return (
            try rule.compileWhile(grammar, endRegexSource: endRegexSource),
            findOptions(allowA: allowA, allowG: allowG)
        )
    }
    return (
        try rule.compileWhileAG(
            grammar,
            endRegexSource: endRegexSource,
            allowA: allowA,
            allowG: allowG
        ),
        []
    )
}

private func findOptions(allowA: Bool, allowG: Bool) -> OnigFindOptions {
    var options: OnigFindOptions = []
    if !allowA {
        options.insert(.notBeginString)
    }
    if !allowG {
        options.insert(.notBeginPosition)
    }
    return options
}

private struct LocalStackElement {
    let scopes: AttributedScopeStack
    let endPosition: Int
}

private func handleCaptures(
    grammar: Grammar,
    lineText: OnigString,
    isFirstLine: Bool,
    stack: StateStackImpl,
    lineTokens: LineTokens,
    captures: [CaptureRule?],
    captureIndices: [OnigCaptureIndex]
) throws {
    guard !captures.isEmpty, let fullMatch = captureIndices.first else {
        return
    }

    let length = min(captures.count, captureIndices.count)
    var localStack: [LocalStackElement] = []
    let maxEnd = fullMatch.end

    for index in 0..<length {
        guard let captureRule = captures[index] else { continue }
        let captureIndex = captureIndices[index]

        if captureIndex.length == 0 {
            continue
        }
        if captureIndex.start > maxEnd {
            break
        }

        while let local = localStack.last,
              local.endPosition <= captureIndex.start
        {
            lineTokens.produceFromScopes(
                local.scopes,
                endIndex: local.endPosition
            )
            localStack.removeLast()
        }

        if let local = localStack.last {
            lineTokens.produceFromScopes(
                local.scopes,
                endIndex: captureIndex.start
            )
        } else {
            lineTokens.produce(stack, endIndex: captureIndex.start)
        }

        if captureRule.retokenizeCapturedWithRuleID != 0 {
            guard let contentScopes = stack.contentNameScopesList else {
                preconditionFailure("A tokenizing state must carry content scopes.")
            }
            let scopeName = captureRule.getName(
                lineText: lineText.content,
                captureIndices: captureIndices
            )
            let nameScopesList = contentScopes.pushAttributed(
                scopeName,
                grammar
            )
            let contentName = captureRule.getContentName(
                lineText: lineText.content,
                captureIndices: captureIndices
            )
            let contentNameScopesList = nameScopesList.pushAttributed(
                contentName,
                grammar
            )
            let stackClone = stack.push(
                ruleID: captureRule.retokenizeCapturedWithRuleID,
                enterPos: captureIndex.start,
                anchorPos: -1,
                beginRuleCapturedEOL: false,
                endRule: nil,
                nameScopesList: nameScopesList,
                contentNameScopesList: contentNameScopesList
            )
            let prefix = utf16Prefix(
                lineText.content,
                endingAt: captureIndex.end
            )
            _ = try tokenizeString(
                grammar: grammar,
                lineText: grammar.createOnigString(prefix),
                isFirstLine: isFirstLine && captureIndex.start == 0,
                linePosition: captureIndex.start,
                stack: stackClone,
                lineTokens: lineTokens,
                checkWhileConditions: false,
                timeLimit: 0
            )
            continue
        }

        if let captureScopeName = captureRule.getName(
            lineText: lineText.content,
            captureIndices: captureIndices
        ) {
            guard let base = localStack.last?.scopes
                ?? stack.contentNameScopesList
            else {
                preconditionFailure("A tokenizing state must carry content scopes.")
            }
            localStack.append(
                LocalStackElement(
                    scopes: base.pushAttributed(captureScopeName, grammar),
                    endPosition: captureIndex.end
                )
            )
        }
    }

    while let local = localStack.popLast() {
        lineTokens.produceFromScopes(
            local.scopes,
            endIndex: local.endPosition
        )
    }
}

private func utf16Prefix(_ source: String, endingAt end: Int) -> String {
    let units = Array(source.utf16)
    let boundedEnd = min(max(0, end), units.count)
    return String(decoding: units[..<boundedEnd], as: UTF16.self)
}

import Foundation

/// Public immutable-stack behavior exposed by `vscode-textmate`.
public protocol StateStack: AnyObject, Sendable {
    var depth: Int { get }
    func clone() -> StateStackImpl
    func equals(_ other: StateStackImpl) -> Bool
}

/// One portable frame used to diff and reconstruct a tokenizer state stack.
public struct StateStackFrame: Codable, Equatable, Sendable {
    public var ruleID: Int
    public var enterPos: Int?
    public var anchorPos: Int?
    public var beginRuleCapturedEOL: Bool
    public var endRule: String?
    public var nameScopesList: [AttributedScopeStackFrame]
    public var contentNameScopesList: [AttributedScopeStackFrame]

    /// Compatibility spelling matching the serialized `ruleId` field.
    public var ruleId: Int {
        get { ruleID }
        set { ruleID = newValue }
    }

    public init(
        ruleID: Int,
        enterPos: Int? = nil,
        anchorPos: Int? = nil,
        beginRuleCapturedEOL: Bool,
        endRule: String?,
        nameScopesList: [AttributedScopeStackFrame],
        contentNameScopesList: [AttributedScopeStackFrame]
    ) {
        self.ruleID = ruleID
        self.enterPos = enterPos
        self.anchorPos = anchorPos
        self.beginRuleCapturedEOL = beginRuleCapturedEOL
        self.endRule = endRule
        self.nameScopesList = nameScopesList
        self.contentNameScopesList = contentNameScopesList
    }

    private enum CodingKeys: String, CodingKey {
        case ruleID = "ruleId"
        case enterPos
        case anchorPos
        case beginRuleCapturedEOL
        case endRule
        case nameScopesList
        case contentNameScopesList
    }
}

/// A persistent pushed TextMate rule state.
///
/// The stack is structurally immutable except for line-local enter and anchor
/// positions, which `reset()` clears recursively before tokenizing a new line.
public final class StateStackImpl: @unchecked Sendable,
    StateStack, CustomStringConvertible
{
    /// Sentinel exported by `vscode-textmate` as `INITIAL`.
    public static let NULL = StateStackImpl(
        parent: nil,
        ruleID: 0,
        enterPos: 0,
        anchorPos: 0,
        beginRuleCapturedEOL: false,
        endRule: nil,
        nameScopesList: nil,
        contentNameScopesList: nil
    )

    public let parent: StateStackImpl?
    public let ruleID: Int
    public let beginRuleCapturedEOL: Bool
    public let endRule: String?
    public let nameScopesList: AttributedScopeStack?
    public let contentNameScopesList: AttributedScopeStack?
    public let depth: Int

    /// Compatibility spelling matching `vscode-textmate`.
    public var ruleId: Int { ruleID }

    private var enterPos: Int
    private var anchorPos: Int

    public init(
        parent: StateStackImpl?,
        ruleID: Int,
        enterPos: Int,
        anchorPos: Int,
        beginRuleCapturedEOL: Bool,
        endRule: String?,
        nameScopesList: AttributedScopeStack?,
        contentNameScopesList: AttributedScopeStack?
    ) {
        self.parent = parent
        self.ruleID = ruleID
        self.enterPos = enterPos
        self.anchorPos = anchorPos
        self.beginRuleCapturedEOL = beginRuleCapturedEOL
        self.endRule = endRule
        self.nameScopesList = nameScopesList
        self.contentNameScopesList = contentNameScopesList
        depth = parent.map { $0.depth + 1 } ?? 1
    }

    public convenience init(
        _ parent: StateStackImpl?,
        _ ruleID: Int,
        _ enterPos: Int,
        _ anchorPos: Int,
        _ beginRuleCapturedEOL: Bool,
        _ endRule: String?,
        _ nameScopesList: AttributedScopeStack?,
        _ contentNameScopesList: AttributedScopeStack?
    ) {
        self.init(
            parent: parent,
            ruleID: ruleID,
            enterPos: enterPos,
            anchorPos: anchorPos,
            beginRuleCapturedEOL: beginRuleCapturedEOL,
            endRule: endRule,
            nameScopesList: nameScopesList,
            contentNameScopesList: contentNameScopesList
        )
    }

    public func equals(_ other: StateStackImpl) -> Bool {
        if self === other {
            return true
        }
        guard Self.structurallyEquals(self, other) else {
            return false
        }
        return AttributedScopeStack.equals(
            contentNameScopesList,
            other.contentNameScopesList
        )
    }

    public func equals(_ other: StateStackImpl?) -> Bool {
        guard let other else { return false }
        return equals(other)
    }

    public func clone() -> StateStackImpl {
        self
    }

    public func reset() {
        var element: StateStackImpl? = self
        while let current = element {
            current.enterPos = -1
            current.anchorPos = -1
            element = current.parent
        }
    }

    public func pop() -> StateStackImpl? {
        parent
    }

    public func safePop() -> StateStackImpl {
        parent ?? self
    }

    public func push(
        ruleID: Int,
        enterPos: Int,
        anchorPos: Int,
        beginRuleCapturedEOL: Bool,
        endRule: String?,
        nameScopesList: AttributedScopeStack?,
        contentNameScopesList: AttributedScopeStack?
    ) -> StateStackImpl {
        StateStackImpl(
            parent: self,
            ruleID: ruleID,
            enterPos: enterPos,
            anchorPos: anchorPos,
            beginRuleCapturedEOL: beginRuleCapturedEOL,
            endRule: endRule,
            nameScopesList: nameScopesList,
            contentNameScopesList: contentNameScopesList
        )
    }

    public func push(
        ruleId: Int,
        enterPos: Int,
        anchorPos: Int,
        beginRuleCapturedEOL: Bool,
        endRule: String?,
        nameScopesList: AttributedScopeStack?,
        contentNameScopesList: AttributedScopeStack?
    ) -> StateStackImpl {
        push(
            ruleID: ruleId,
            enterPos: enterPos,
            anchorPos: anchorPos,
            beginRuleCapturedEOL: beginRuleCapturedEOL,
            endRule: endRule,
            nameScopesList: nameScopesList,
            contentNameScopesList: contentNameScopesList
        )
    }

    /// UTF-16 position where this state was pushed on the current line.
    public func getEnterPos() -> Int {
        enterPos
    }

    /// UTF-16 anchor position captured when this state was pushed.
    public func getAnchorPos() -> Int {
        anchorPos
    }

    public func getRule(_ grammar: any TextMateRuleRegistry) -> Rule {
        guard let rule = grammar.rule(with: ruleID) else {
            preconditionFailure("No compiled TextMate rule for id \(ruleID)")
        }
        return rule
    }

    public func withContentNameScopesList(
        _ contentNameScopeStack: AttributedScopeStack
    ) -> StateStackImpl {
        if contentNameScopesList === contentNameScopeStack {
            return self
        }
        guard let parent else {
            preconditionFailure("A root state cannot replace its content scope stack.")
        }
        return parent.push(
            ruleID: ruleID,
            enterPos: enterPos,
            anchorPos: anchorPos,
            beginRuleCapturedEOL: beginRuleCapturedEOL,
            endRule: endRule,
            nameScopesList: nameScopesList,
            contentNameScopesList: contentNameScopeStack
        )
    }

    public func withEndRule(_ endRule: String) -> StateStackImpl {
        if self.endRule == endRule {
            return self
        }
        return StateStackImpl(
            parent: parent,
            ruleID: ruleID,
            enterPos: enterPos,
            anchorPos: anchorPos,
            beginRuleCapturedEOL: beginRuleCapturedEOL,
            endRule: endRule,
            nameScopesList: nameScopesList,
            contentNameScopesList: contentNameScopesList
        )
    }

    /// Used by the tokenizer to detect zero-width endless rule loops.
    public func hasSameRuleAs(_ other: StateStackImpl) -> Bool {
        var element: StateStackImpl? = self
        while let current = element, current.enterPos == other.enterPos {
            if current.ruleID == other.ruleID {
                return true
            }
            element = current.parent
        }
        return false
    }

    public func toStateStackFrame() -> StateStackFrame {
        StateStackFrame(
            ruleID: ruleID,
            beginRuleCapturedEOL: beginRuleCapturedEOL,
            endRule: endRule,
            nameScopesList: nameScopesList?.getExtensionIfDefined(
                parent?.nameScopesList
            ) ?? [],
            contentNameScopesList: contentNameScopesList?.getExtensionIfDefined(
                nameScopesList
            ) ?? []
        )
    }

    public static func pushFrame(
        _ stack: StateStackImpl?,
        _ frame: StateStackFrame
    ) -> StateStackImpl {
        let namesScopeList = AttributedScopeStack.fromExtension(
            stack?.nameScopesList,
            frame.nameScopesList
        )
        return StateStackImpl(
            parent: stack,
            ruleID: frame.ruleID,
            enterPos: frame.enterPos ?? -1,
            anchorPos: frame.anchorPos ?? -1,
            beginRuleCapturedEOL: frame.beginRuleCapturedEOL,
            endRule: frame.endRule,
            nameScopesList: namesScopeList,
            contentNameScopesList: AttributedScopeStack.fromExtension(
                namesScopeList,
                frame.contentNameScopesList
            )
        )
    }

    public var description: String {
        var frames: [String] = []
        writeDescription(into: &frames)
        return "[\(frames.joined(separator: ","))]"
    }

    private static func structurallyEquals(
        _ first: StateStackImpl?,
        _ second: StateStackImpl?
    ) -> Bool {
        var left = first
        var right = second

        while true {
            switch (left, right) {
            case (nil, nil):
                return true
            case (nil, _), (_, nil):
                return false
            case let (leftValue?, rightValue?):
                if leftValue === rightValue {
                    return true
                }
                if leftValue.depth != rightValue.depth
                    || leftValue.ruleID != rightValue.ruleID
                    || leftValue.endRule != rightValue.endRule {
                    return false
                }
                left = leftValue.parent
                right = rightValue.parent
            }
        }
    }

    private func writeDescription(into frames: inout [String]) {
        parent?.writeDescription(into: &frames)
        let nameScopes = nameScopesList?.description ?? "undefined"
        let contentScopes = contentNameScopesList?.description ?? "undefined"
        frames.append("(\(ruleID), \(nameScopes), \(contentScopes))")
    }
}

/// Initial TextMate state sentinel. Identity is significant to the grammar.
public let INITIAL: StateStackImpl = StateStackImpl.NULL

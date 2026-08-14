import XCTest
@testable import ShikiCore

final class TextMateStateStackTests: XCTestCase {
    func testDepthClonePopAndSafePop() {
        let root = makeState(ruleID: 1)
        let child = root.push(
            ruleID: 2,
            enterPos: 4,
            anchorPos: 3,
            beginRuleCapturedEOL: false,
            endRule: "end",
            nameScopesList: nil,
            contentNameScopesList: nil
        )

        XCTAssertEqual(root.depth, 1)
        XCTAssertEqual(child.depth, 2)
        XCTAssertTrue(root.clone() === root)
        XCTAssertTrue(child.pop() === root)
        XCTAssertTrue(child.safePop() === root)
        XCTAssertTrue(root.safePop() === root)
        XCTAssertTrue(INITIAL === StateStackImpl.NULL)
    }

    func testStructuralEqualityIgnoresLinePositionsAndCapturedEOL() {
        let scopes1 = AttributedScopeStack.createRoot("source.swift", 42)
        let scopes2 = AttributedScopeStack.createRoot("source.swift", 42)

        let firstRoot = makeState(
            ruleID: 1,
            enterPos: 0,
            anchorPos: 0,
            capturedEOL: false,
            contentScopes: scopes1
        )
        let first = firstRoot.push(
            ruleID: 2,
            enterPos: 5,
            anchorPos: 2,
            beginRuleCapturedEOL: false,
            endRule: "dynamic",
            nameScopesList: scopes1,
            contentNameScopesList: scopes1
        )

        let secondRoot = makeState(
            ruleID: 1,
            enterPos: 99,
            anchorPos: 88,
            capturedEOL: true,
            contentScopes: scopes2
        )
        let second = secondRoot.push(
            ruleID: 2,
            enterPos: 77,
            anchorPos: 66,
            beginRuleCapturedEOL: true,
            endRule: "dynamic",
            nameScopesList: nil,
            contentNameScopesList: scopes2
        )

        XCTAssertTrue(first.equals(second))
        XCTAssertFalse(first.equals(nil))
        XCTAssertFalse(first.withEndRule("different").equals(second))

        let differentScopes = AttributedScopeStack.createRoot("source.swift", 43)
        let differentContent = secondRoot.push(
            ruleID: 2,
            enterPos: 77,
            anchorPos: 66,
            beginRuleCapturedEOL: true,
            endRule: "dynamic",
            nameScopesList: nil,
            contentNameScopesList: differentScopes
        )
        XCTAssertFalse(first.equals(differentContent))
    }

    func testResetClearsUTF16LinePositionsAcrossEntireStack() {
        let root = makeState(
            ruleID: 1,
            enterPos: "😀".utf16.count,
            anchorPos: 1
        )
        let child = root.push(
            ruleID: 2,
            enterPos: "e\u{301}".utf16.count,
            anchorPos: 2,
            beginRuleCapturedEOL: false,
            endRule: nil,
            nameScopesList: nil,
            contentNameScopesList: nil
        )

        XCTAssertEqual(root.getEnterPos(), 2)
        XCTAssertEqual(child.getEnterPos(), 2)
        child.reset()
        XCTAssertEqual(root.getEnterPos(), -1)
        XCTAssertEqual(root.getAnchorPos(), -1)
        XCTAssertEqual(child.getEnterPos(), -1)
        XCTAssertEqual(child.getAnchorPos(), -1)
    }

    func testContentAndEndRuleReplacementPreservePersistentParent() {
        let provider = MockStateMetadataProvider()
        let nameScopes = AttributedScopeStack.createRoot("source.swift", 1)
        let contentScopes = nameScopes.pushAttributed("meta.block", provider)
        let root = makeState(ruleID: 1, contentScopes: nameScopes)
        let child = root.push(
            ruleID: 2,
            enterPos: 3,
            anchorPos: 1,
            beginRuleCapturedEOL: true,
            endRule: "old",
            nameScopesList: nameScopes,
            contentNameScopesList: nameScopes
        )

        XCTAssertTrue(child.withContentNameScopesList(nameScopes) === child)
        let withContent = child.withContentNameScopesList(contentScopes)
        XCTAssertTrue(withContent.parent === root)
        XCTAssertTrue(withContent.contentNameScopesList === contentScopes)
        XCTAssertEqual(withContent.getEnterPos(), 3)

        XCTAssertTrue(child.withEndRule("old") === child)
        let withEnd = child.withEndRule("new")
        XCTAssertTrue(withEnd.parent === root)
        XCTAssertEqual(withEnd.endRule, "new")
        XCTAssertEqual(withEnd.beginRuleCapturedEOL, true)
    }

    func testHasSameRuleOnlyWhileEnterPositionsMatch() {
        let root = makeState(ruleID: 10, enterPos: 4)
        let child = root.push(
            ruleID: 20,
            enterPos: 4,
            anchorPos: 0,
            beginRuleCapturedEOL: false,
            endRule: nil,
            nameScopesList: nil,
            contentNameScopesList: nil
        )

        XCTAssertTrue(child.hasSameRuleAs(makeState(ruleID: 10, enterPos: 4)))
        XCTAssertTrue(child.hasSameRuleAs(makeState(ruleID: 20, enterPos: 4)))
        XCTAssertFalse(child.hasSameRuleAs(makeState(ruleID: 10, enterPos: 5)))
    }

    func testFramesRoundTripScopesAndDefaultTransientPositions() throws {
        let provider = MockStateMetadataProvider()
        let rootName = AttributedScopeStack.createRoot("source.swift", 1)
        let rootContent = rootName.pushAttributed("meta.root", provider)
        let root = makeState(
            ruleID: 1,
            enterPos: 9,
            anchorPos: 8,
            contentScopes: rootContent,
            nameScopes: rootName
        )

        let childName = rootContent.pushAttributed("meta.block", provider)
        let childContent = childName.pushAttributed("string.quoted", provider)
        let child = root.push(
            ruleID: 2,
            enterPos: 7,
            anchorPos: 6,
            beginRuleCapturedEOL: true,
            endRule: "captured-end",
            nameScopesList: childName,
            contentNameScopesList: childContent
        )

        let rootFrame = root.toStateStackFrame()
        let childFrame = child.toStateStackFrame()
        XCTAssertNil(rootFrame.enterPos)
        XCTAssertNil(rootFrame.anchorPos)

        let rebuiltRoot = StateStackImpl.pushFrame(nil, rootFrame)
        let rebuiltChild = StateStackImpl.pushFrame(rebuiltRoot, childFrame)
        XCTAssertTrue(child.equals(rebuiltChild))
        XCTAssertEqual(rebuiltChild.getEnterPos(), -1)
        XCTAssertEqual(rebuiltChild.getAnchorPos(), -1)
        XCTAssertEqual(rebuiltChild.nameScopesList?.getScopeNames(), childName.getScopeNames())
        XCTAssertEqual(rebuiltChild.contentNameScopesList?.getScopeNames(), childContent.getScopeNames())

        let encoded = try JSONEncoder().encode(childFrame)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["ruleId"] as? Int, 2)
        XCTAssertEqual(try JSONDecoder().decode(StateStackFrame.self, from: encoded), childFrame)
    }

    func testRuleRegistrySeamAndDescription() {
        let scopes = AttributedScopeStack.createRoot("source.swift", 1)
        let root = makeState(
            ruleID: 7,
            contentScopes: scopes,
            nameScopes: scopes
        )

        let registry = MockRuleRegistry()
        XCTAssertTrue(root.getRule(registry) === registry.rule)
        XCTAssertEqual(root.description, "[(7, source.swift, source.swift)]")
    }

    private func makeState(
        ruleID: Int,
        enterPos: Int = 0,
        anchorPos: Int = 0,
        capturedEOL: Bool = false,
        contentScopes: AttributedScopeStack? = nil,
        nameScopes: AttributedScopeStack? = nil
    ) -> StateStackImpl {
        StateStackImpl(
            parent: nil,
            ruleID: ruleID,
            enterPos: enterPos,
            anchorPos: anchorPos,
            beginRuleCapturedEOL: capturedEOL,
            endRule: nil,
            nameScopesList: nameScopes,
            contentNameScopesList: contentScopes
        )
    }
}

private final class MockStateMetadataProvider: AttributedScopeStackMetadataProvider {
    func getMetadataForScope(_ scopeName: ScopeName?) -> BasicScopeAttributes {
        BasicScopeAttributes(0, .notSet)
    }

    func themeMatch(_ scopePath: ScopeStack) -> StyleAttributes? {
        nil
    }
}

private final class MockRuleRegistry: TextMateRuleRegistry {
    let rule = Rule(location: nil, id: 7, name: nil, contentName: nil)

    func rule(with ruleID: RuleID) -> Rule? {
        ruleID == rule.id ? rule : nil
    }

    func registerRule(_ factory: (RuleID) -> Rule) -> Rule {
        factory(8)
    }
}

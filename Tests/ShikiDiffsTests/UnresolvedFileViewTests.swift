import AppKit
import Shiki
import SwiftUI
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct UnresolvedFileViewTests {
    private var file: FileContents {
        .init(name: "merge.swift", contents: "<<<<<<< HEAD\nlet a = 1\n=======\nlet a = 2\n>>>>>>> feature\n\n<<<<<<< HEAD\nlet b = 3\n=======\nlet b = 4\n>>>>>>> feature\n")
    }
    @MainActor private func settled(_ view: NativeUnresolvedFileView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while view.isPreparing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparing)
        #expect(view.preparationError == nil)
    }
    @Test @MainActor func inheritedNavigationSurvivesHighlightingAndResetsWithSource() async throws {
        let prefix = (1...80).map { "before \($0)\n" }.joined()
        let suffix = (1...80).map { "after \($0)\n" }.joined()
        let source = FileContents(name: "folds.txt", contents: prefix + "<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> branch\n" + suffix)
        let view = NativeUnresolvedFileView(frame: .init(x: 0, y: 0, width: 700, height: 250))
        var options = DiffRenderOptions(); options.expansionLineCount = 3
        try view.render(file: source, options: options)
        #expect(view.isPreparing)
        #expect(try !view.isLineRenderable(10))
        #expect(try view.getNearestRenderableLine(10, direction: .up) == nil)
        let next = try #require(try view.getNearestRenderableLine(10, direction: .down))
        #expect(next > 10)
        var expansions = 0
        view.diffView.onExpansion = { _, _, _ in expansions += 1 }
        #expect(try view.revealLine(10))
        #expect(try view.revealLine(140))
        #expect(expansions == 2)
        try await settled(view)
        #expect(try view.isLineRenderable(10))
        #expect(try view.isLineRenderable(140))
        #expect(try !view.revealLine(10))
        #expect(expansions == 2)
        // A new externally supplied source begins a fresh expansion state.
        try view.render(file: source, options: options)
        #expect(try !view.isLineRenderable(10))
        try await settled(view)
        #expect(try !view.isLineRenderable(10))
        view.cleanUp()
        #expect(try view.isLineRenderable(10))
        #expect(try view.getNearestRenderableLine(10, direction: .down) == 10)
        #expect(try !view.revealLine(10))
    }
    @Test @MainActor func automaticResolutionOwnsSourceAndRejectsStaleActions() async throws {
        let view = NativeUnresolvedFileView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        var events: [MergeConflictActionPayload] = []
        view.behavior = .automatic { file, payload in
            #expect(areFilesEqual(file, view.state?.file))
            events.append(payload)
        }
        try view.render(file: file)
        let source = view.diffView.displayedDocument?.sourceID
        let stale = try #require(view.diffView.onResolveConflict)
        #expect(try view.performResolution(1, resolution: .additions))
        stale(0, .both)
        #expect(view.state?.result.actions.map(\.conflictIndex) == [0])
        #expect(try view.performResolution(0, resolution: .deletions))
        #expect(try view.performResolution(0, resolution: .both) == false)
        #expect(view.state?.file.contents == "let a = 1\n\nlet b = 4\n")
        #expect(events.map(\.conflict.conflictIndex) == [1, 0])
        try await settled(view)
        #expect(view.diffView.displayedDocument?.sourceID == source)
        #expect(view.diffView.mergeConflictActions.isEmpty)
        #expect(view.state?.result.markerRows.isEmpty == true)
        view.cleanUp()
    }
    @Test @MainActor func controlledActionCanResolveAndInstallItsOwnState() async throws {
        let view = NativeUnresolvedFileView()
        var payloads: [MergeConflictActionPayload] = []
        view.behavior = .controlled { payload, instance in
            #expect(instance === view); payloads.append(payload)
        }
        try view.render(file: file)
        let original = view.state?.revision
        #expect(try view.performResolution(0, resolution: .both))
        #expect(view.state?.revision == original)
        let next = try #require(try view.resolveConflict(0, resolution: .both))
        #expect(view.state?.revision == original)
        view.render(state: next)
        #expect(view.state?.result.actions.count == 1)
        #expect(payloads.count == 1)
        try await settled(view)
        view.cleanUp()
    }
    @Test @MainActor func replacementAndCleanupDiscardPendingHighlighting() async throws {
        actor Gate {
            var continuation: CheckedContinuation<ShikiTheme, Never>?
            func load() async -> ShikiTheme { await withCheckedContinuation { continuation = $0 } }
            var waiting: Bool { continuation != nil }
            func finish() { continuation?.resume(returning: .init(name: "delayed", type: .dark)); continuation = nil }
        }
        let gate = Gate(), highlighter = DiffHighlighter()
        await highlighter.registerCustomTheme("delayed") { await gate.load() }
        let view = NativeUnresolvedFileView(highlighter: highlighter)
        var options = DiffRenderOptions(); options.theme = "delayed"
        try view.render(file: file, options: options)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.waiting) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.waiting)
        let stale = try #require(view.diffView.onResolveConflict)
        try view.render(file: .init(name: "replacement.txt", contents: "replacement\n"))
        stale(0, .both)
        try await settled(view)
        #expect(view.state?.file.name == "replacement.txt")
        let documentID = view.diffView.displayedDocument?.id
        await gate.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(view.diffView.displayedDocument?.id == documentID)
        view.cleanUp()
        #expect(view.state == nil && view.diffView.isHidden)
        #expect(view.diffView.onResolveConflict == nil && !view.isPreparing)
        try view.render(file: file)
        try await settled(view)
        #expect(!view.diffView.isHidden && view.state?.result.actions.count == 2)
        view.cleanUp()
    }
    @Test @MainActor func resolutionCallbackCanReplaceSource() async throws {
        let view = NativeUnresolvedFileView()
        view.behavior = .automatic { _, _ in
            try? view.render(file: .init(name: "next.txt", contents: "next\n"))
        }
        try view.render(file: file)
        #expect(try view.performResolution(0, resolution: .additions))
        try await settled(view)
        #expect(view.state?.file.name == "next.txt")
        #expect(view.diffView.displayedDocument?.diff.name == "next.txt")
        view.cleanUp()
    }

    @Test @MainActor func failedHighlightingRetainsResolvableState() async throws {
        enum Failure: Error { case unavailable }
        let highlighter = DiffHighlighter()
        await highlighter.registerCustomTheme("broken") { throw Failure.unavailable }
        let view = NativeUnresolvedFileView(highlighter: highlighter)
        var errors = 0
        view.onError = { _ in errors += 1 }
        var options = DiffRenderOptions(); options.theme = "broken"
        try view.render(file: file, options: options)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while view.isPreparing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparing && view.preparationError != nil && errors == 1)
        #expect(view.state?.result.actions.count == 2)
        let retained = try #require(view.state)
        view.render(state: retained)
        try await settled(view)
        #expect(try view.performResolution(0, resolution: .both))
        try await settled(view)
        #expect(view.state?.result.actions.count == 1)
        view.cleanUp()
    }
    @Test @MainActor func swiftUIUpdatesPreserveResolutionAndHostEchoes() async throws {
        let highlighter = DiffHighlighter()
        var input = UnresolvedFileView(file: file, highlighter: highlighter)
        let coordinator = input.makeCoordinator()
        let view = NativeUnresolvedFileView(highlighter: highlighter)
        coordinator.update(input, view: view)
        try await settled(view)
        #expect(try view.performResolution(0, resolution: .deletions))
        try await settled(view)
        let revision = view.state?.revision
        let source = view.diffView.displayedDocument?.sourceID
        let document = view.diffView.displayedDocument?.id
        coordinator.update(input, view: view)
        #expect(view.diffView.displayedDocument?.id == document)
        input.options.fontName = "Menlo"; input.options.fontSize = 16
        coordinator.update(input, view: view)
        try await settled(view)
        #expect(view.state?.revision == revision)
        #expect(view.state?.result.actions.map(\.conflictIndex) == [1])
        #expect(view.diffView.displayedDocument?.sourceID == source)
        input.file = try #require(view.state?.file)
        coordinator.update(input, view: view)
        try await settled(view)
        #expect(view.state?.result.actions.map(\.conflictIndex) == [1])
        #expect(view.state?.revision == revision)
        input.options.theme = "pierre-light"
        coordinator.update(input, view: view)
        try await settled(view)
        #expect(view.state?.revision == revision)
        #expect(view.diffView.displayedDocument?.palette.isLight == true)
        input.file = .init(name: "new.txt", contents: "new source\n")
        coordinator.update(input, view: view)
        try await settled(view)
        #expect(view.state?.file.name == "new.txt")
        #expect(view.diffView.displayedDocument?.sourceID != source)
        UnresolvedFileView.dismantleNSView(view, coordinator: coordinator)
        #expect(view.state == nil && view.diffView.isHidden)
    }

    @Test @MainActor func swiftUIContextChangesDoNotRestoreResolvedSource() async throws {
        var input = UnresolvedFileView(file: file)
        let coordinator = input.makeCoordinator()
        let view = NativeUnresolvedFileView(highlighter: coordinator.highlighter)
        coordinator.update(input, view: view)
        #expect(try view.performResolution(0, resolution: .additions))
        let resolvedSource = view.state?.file.contents
        input.maxContextLines = 2
        coordinator.update(input, view: view)
        try await settled(view)
        #expect(view.state?.file.contents == resolvedSource)
        #expect(view.state?.result.actions.count == 1)
        view.cleanUp()
    }

    @Test @MainActor func swiftUISelectionOnlyUpdateDoesNotPrepareAgain() async throws {
        var selection: LineSelection? = .init(side: .additions, startLine: 1, endLine: 1)
        var notifications = 0
        var input = UnresolvedFileView(file: file, onSelectionChange: { _ in notifications += 1 },
            selectedLines: Binding(get: { selection }, set: { selection = $0 }),
            activeLineSide: .additions, lineNumberOnly: true)
        let renderer = DiffConflictActionRenderer { _, _ in NSView(frame: .init(x: 0, y: 0, width: 200, height: 30)) }
        input.conflictActionRenderer = renderer
        let coordinator = input.makeCoordinator()
        let view = NativeUnresolvedFileView(highlighter: coordinator.highlighter)
        coordinator.update(input, view: view)
        try await settled(view)
        #expect(view.diffView.selectedLines == selection)
        #expect(view.diffView.selectionHighlightSide == .additions)
        #expect(view.diffView.selectionLineNumberOnly)
        #expect(view.diffView.conflictActionRenderer === renderer)
        let document = view.diffView.displayedDocument?.id
        // Initial document installation may report its selection reset. Updating
        // the controlled binding must not echo another notification to the host.
        let previousNotifications = notifications
        selection = nil
        coordinator.update(input, view: view)
        #expect(view.diffView.selectedLines == nil)
        #expect(!view.isPreparing && view.diffView.displayedDocument?.id == document)
        #expect(notifications == previousNotifications)
        view.cleanUp()
    }

    @Test @MainActor func displayChangesReusePreparedTokens() async throws {
        let view = NativeUnresolvedFileView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        try view.render(file: file)
        try await settled(view)
        let state = try #require(view.state)
        let prepared = try #require(view.diffView.displayedDocument)
        #expect(!prepared.newTokens.isEmpty)
        var options = DiffRenderOptions()
        options.fontName = "Menlo"; options.fontSize = 18; options.lineHeight = 28
        options.overflow = .wrap; options.mergeConflictActionsType = .none
        view.render(state: state, options: options, annotations: [.init(side: .additions, lineNumber: 1, text: "Review this change")])
        #expect(!view.isPreparing)
        #expect(view.diffView.displayedDocument?.id == prepared.id)
        #expect(view.diffView.displayedDocument?.newTokens == prepared.newTokens)
        options.theme = "pierre-light"
        view.render(state: state, options: options)
        #expect(view.isPreparing)
        try await settled(view)
        #expect(view.diffView.displayedDocument?.palette.isLight == true)
        options.tokenizeMaxLength = 0
        view.render(state: state, options: options)
        #expect(view.isPreparing)
        try await settled(view)
        view.cleanUp()
    }

    @Test @MainActor func pendingPreparationUsesLatestLayoutWithoutRestart() async throws {
        actor Gate {
            var continuation: CheckedContinuation<ShikiTheme, Never>?
            var waiting: Bool { continuation != nil }
            func load() async -> ShikiTheme { await withCheckedContinuation { continuation = $0 } }
            func finish() { continuation?.resume(returning: .init(name: "layout-gate", type: .dark)); continuation = nil }
        }
        let gate = Gate(), highlighter = DiffHighlighter()
        await highlighter.registerCustomTheme("layout-gate") { await gate.load() }
        let view = NativeUnresolvedFileView(frame: .init(x: 0, y: 0, width: 800, height: 600), highlighter: highlighter)
        var options = DiffRenderOptions(); options.theme = "layout-gate"
        try view.render(file: file, options: options)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.waiting) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.waiting)
        let plainID = view.diffView.displayedDocument?.id
        let canvas = try #require(view.diffView.scrollView.documentView)
        #expect(canvas.accessibilityCustomActions()?.contains { $0.name.hasPrefix("Accept current change at conflict ") } == true)
        options.lineHeight = 40; options.mergeConflictActionsType = .none
        view.render(state: try #require(view.state), options: options)
        #expect(view.isPreparing && view.diffView.displayedDocument?.id == plainID)
        let height = view.diffView.scrollView.documentView?.frame.height
        await gate.finish()
        try await settled(view)
        #expect(view.diffView.displayedDocument?.id != plainID)
        #expect(view.diffView.scrollView.documentView?.frame.height == height)
        #expect(canvas.accessibilityCustomActions()?.contains { $0.name.hasPrefix("Accept current change at conflict ") } != true)
        view.cleanUp()
    }

}

import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct SearchControllerTests {
    @MainActor func setup(_ old: String, _ new: String) async throws -> (NSWindow, NativeDiffView, DiffEditor) {
        let highlighter = DiffHighlighter()
        let prepared = try await highlighter.prepare(oldFile: .init(name: "test.txt", contents: old), newFile: .init(name: "test.txt", contents: new))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 900, height: 520)); window.contentView = view
        view.render(prepared)
        let editor = try view.beginEditing(highlighter: highlighter)
        await editor.waitForRendering()
        return (window, view, editor)
    }
    @Test @MainActor func searchBarNavigationReplacementAndUndo() async throws {
        let (window, view, editor) = try await setup("", "alpha beta\nbeta gamma\nbeta")
        defer { window.close() }
        let originalHeight = view.scrollView.frame.height
        let search = try #require(editor.openSearch())
        search.params = .init(text: "beta", replaceText: "result")
        await search.waitForResults()
        #expect(search.matches.count == 3)
        #expect(search.resultLabel == "1 of 3")
        #expect(editor.selectedText == "beta")
        search.next(previous: true); #expect(search.resultLabel == "3 of 3")
        search.next(); #expect(search.resultLabel == "1 of 3")
        view.layoutSubtreeIfNeeded()
        #expect(view.scrollView.frame.height == originalHeight - 80)
        search.replacing = true; view.layoutSubtreeIfNeeded()
        #expect(view.scrollView.frame.height == originalHeight - 116)
        let bar = try #require(view.subviews.compactMap { $0 as? DiffSearchBar }.first)
        #expect(bar.query.frame.width > 200)
        #expect(bar.query.convert(bar.query.bounds, to: view).minX >= 0)
        window.setContentSize(.init(width: 400, height: 520)); view.layoutSubtreeIfNeeded()
        #expect(bar.query.frame.width >= 80)
        window.setContentSize(.init(width: 900, height: 520)); view.layoutSubtreeIfNeeded()
        search.replace()
        await search.waitForReplacement(); await search.waitForResults()
        #expect(editor.document.getText() == "alpha result\nbeta gamma\nbeta")
        #expect(search.matches.count == 2)
        #expect(search.resultLabel == "1 of 2")
        editor.undo(nil); await search.waitForResults()
        #expect(search.matches.count == 3)
        search.replace(all: true)
        await search.waitForReplacement(); await search.waitForResults(); await editor.waitForRendering()
        #expect(editor.document.getText() == "alpha result\nresult gamma\nresult")
        #expect(search.resultLabel == "No results")
        editor.undo(nil); await search.waitForResults(); await editor.waitForRendering()
        #expect(editor.document.getText() == "alpha beta\nbeta gamma\nbeta")
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: "/tmp/swift-diffs-search.png")) }
        search.close(); view.layoutSubtreeIfNeeded()
        #expect(editor.search == nil)
        #expect(view.scrollView.frame.height == originalHeight)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func searchRevealsFoldedMatchAndDiscardsOldQuery() async throws {
        let lines = (0..<80).map { "line \($0)\n" }; var changed = lines
        changed[10] = "changed ten\n"; changed[50] = "changed fifty\n"
        let (window, view, editor) = try await setup(lines.joined(), changed.joined())
        defer { window.close() }
        editor.select(.init(location: editor.document.offsetAt(.init(line: 46, character: 0)), length: 0))
        let search = try #require(editor.openSearch())
        let expansions = view.editorExpansions
        search.params = .init(text: "line 31")
        search.params = .init(text: "line 30")
        await search.waitForResults()
        #expect(search.matches.count == 1)
        #expect(search.current == nil)
        search.next()
        #expect(editor.selectedText == "line 30")
        #expect(view.editorExpansions != expansions)
        #expect(editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil).height > 0)
        search.params = .init(text: "line")
        search.close()
        await search.waitForResults()
        #expect(editor.search == nil); #expect(search.matches.isEmpty)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func keyboardAndTypingWithSearchOpen() async throws {
        let source = (0..<20_000).map { "source line \($0)\n" }.joined()
        let (window, view, editor) = try await setup(source, source)
        defer { window.close() }
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        view.scrollView.documentView!.keyDown(with: key)
        let search = try #require(editor.search)
        for i in 0..<100 { search.params = .init(text: "source line \(i)") }
        search.params = .init(text: "source line 19999")
        await search.waitForResults()
        #expect(search.matches.count == 1)
        editor.select(.init(location: 0, length: 0))
        let clock = ContinuousClock(), start = clock.now
        for _ in 0..<100 { editor.insertText("x", replacementRange: .init(location: NSNotFound, length: 0)) }
        let elapsed = start.duration(to: clock.now)
        print("100 edits with search open / 20,000 lines: \(elapsed)")
        #expect(elapsed < .seconds(2))
        await search.waitForResults()
        let match = try #require(search.matches.first)
        #expect(try editor.document.getText(in: match) == "source line 19999")
        let bar = try #require(view.subviews.compactMap { $0 as? DiffSearchBar }.first)
        let next = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5))
        #expect(bar.performKeyEquivalent(with: next))
        #expect(editor.selectedText == "source line 19999")
        _ = try await editor.complete(.discard)
        #expect(editor.search == nil)
    }

    @Test @MainActor func closedSessionCannotCloseItsReplacement() async throws {
        let (window, _, editor) = try await setup("", "alpha beta")
        defer { window.close() }
        let first = try #require(editor.openSearch())
        first.close()
        let second = try #require(editor.openSearch(replacing: true))
        second.params = .init(text: "beta")
        first.close()
        #expect(editor.search === second)
        await second.waitForResults()
        #expect(second.matches.count == 1)
        #expect(!first.isSearching)
        second.replace(all: true)
        second.close()
        await second.waitForReplacement()
        #expect(editor.document.getText() == "alpha beta")
        #expect(editor.search == nil)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func replacementRejectsInvalidRangesAndPrecancelledComposition() async throws {
        let (window, _, editor) = try await setup("", "alpha")
        defer { window.close() }
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: 4, length: Int.max), NSRange(location: 0, length: 0)] {
            do {
                try await editor.replaceSearchMatch(range, params: .init(text: "a", replaceText: "b"), expectedVersion: editor.document.version)
                Issue.record("Invalid search range should fail")
            } catch DiffEditorError.invalidSearchReplacement { }
        }
        editor.select(.init(location: 5, length: 0))
        editor.setMarkedText("ni", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        do {
            try await editor.replaceSearchMatch(.init(location: NSNotFound, length: 1), params: .init(text: "a"), expectedVersion: editor.document.version)
            Issue.record("Invalid range during composition should fail")
        } catch DiffEditorError.invalidSearchReplacement { }
        #expect(editor.hasMarkedText())
        let task = Task { try await editor.replaceAll(.init(text: "alpha", replaceText: "changed")) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled replacement should fail") } catch is CancellationError { }
        #expect(editor.hasMarkedText())
        editor.doCommand(by: NSSelectorFromString("cancelOperation:"))
        #expect(editor.document.getText() == "alpha")
        _ = try await editor.complete(.discard)
    }

}

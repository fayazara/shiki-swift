import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct GutterUtilityTests {
    @Test @MainActor func editingRetainsCustomControlAndLatestLineTarget() async throws {
        let file = FileContents(name: "edit.txt", contents: "first\nsecond\nthird\n")
        let worker = DiffHighlighter()
        let prepared = try await worker.prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.interactionHandlers.enableGutterUtility = true
        var calls = 0
        var getter: (@MainActor () -> DiffHoveredLine?)?
        let control = NSView(frame: .init(x: 0, y: 0, width: 20, height: 20))
        view.renderGutterUtility = { read in calls += 1; getter = read; return control }
        view.render(prepared)
        let editor = try view.beginEditing(highlighter: worker)
        await editor.waitForRendering()
        editor.select(.init(location: 0, length: 0))
        editor.insertText("inserted\n", replacementRange: .init(location: NSNotFound, length: 0))
        await editor.waitForRendering()
        view.selectLines(.init(side: .additions, startLine: 3, endLine: 3), notify: false)
        // The edit can collapse unchanged context. A hidden source target must
        // stay hidden until its context is expanded.
        #expect(getter?() == nil && control.isHidden)
        let current = try #require(view.displayedDocument)
        let plan = DiffRenderPlan(diff: current.diff, options: .init())
        let hidden = try #require(plan.rows.first { $0.hiddenNewLines?.contains(3) == true })
        if case .separator(_, let hunk) = hidden.kind { view.expandHunk(hunk, lines: 100, direction: .both) }
        view.layoutSubtreeIfNeeded()
        view.selectLines(.init(side: .additions, startLine: 3, endLine: 3), notify: false)
        #expect(getter?() == .init(lineNumber: 3, side: .additions))
        #expect(calls == 1 && !control.isHidden)
        editor.select(.init(location: 0, length: 8))
        editor.insertText("updated", replacementRange: .init(location: NSNotFound, length: 0))
        await editor.waitForRendering()
        #expect(view.displayedDocument?.diff.additionLines.first == "updated\n")
        editor.onEditComplete = { _ in true }
        _ = try await editor.complete(.install)
        #expect(calls == 1 && control.superview === view.scrollView.documentView)
        view.selectLines(.init(side: .additions, startLine: 2, endLine: 2), notify: false)
        #expect(getter?()?.lineNumber == 2)
    }

    @Test @MainActor func builtInButtonDragsAndReportsStableCompletedRange() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 20))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var events: [String] = [], reported: [LineSelection] = []
        view.interactionHandlers = .init(onLineSelectionStart: { _ in events.append("start") },
            onLineSelectionEnd: { range in events.append("end"); if let range { reported.append(range) } },
            onLineSelected: { range in events.append("selected"); if let range { reported.append(range) } },
            controlledSelection: true, enableGutterUtility: true, onGutterUtilityClick: { range in
                events.append("action"); reported.append(range); view.selectLines(nil, notify: false)
            })
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render(document, options: options)
        let canvas = try #require(view.scrollView.documentView)
        view.selectLines(.init(side: .deletions, startLine: 5, endLine: 2), notify: false)
        let button = try #require(canvas.subviews.first { $0.accessibilityRole() == .button })
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        }
        button.mouseDown(with: try event(.leftMouseDown, .init(x: button.frame.midX, y: button.frame.midY)))
        button.mouseDragged(with: try event(.leftMouseDragged, .init(x: 400, y: 145)))
        button.mouseUp(with: try event(.leftMouseUp, .init(x: 400, y: 165)))
        let expected = LineSelection(side: .deletions, startLine: 2, endLine: 9, endSide: .additions)
        #expect(events == ["start", "action", "end", "selected"])
        #expect(reported == [expected, expected, expected])
        #expect(view.selectedLines == nil)
        // An old control must not drag into a document installed mid-gesture.
        view.selectLines(.init(side: .additions, startLine: 2, endLine: 2), notify: false)
        button.mouseDown(with: try event(.leftMouseDown, .init(x: button.frame.midX, y: button.frame.midY)))
        let replacement = FileContents(name: "other.txt", contents: "new\nfile\n")
        view.render(try await DiffHighlighter().prepare(oldFile: replacement, newFile: replacement), options: options)
        let actionsBefore = reported.count
        button.mouseDragged(with: try event(.leftMouseDragged, .init(x: 400, y: 25)))
        button.mouseUp(with: try event(.leftMouseUp, .init(x: 400, y: 25)))
        #expect(reported.count == actionsBefore && view.selectedLines == nil)
        view.interactionHandlers.enableGutterUtility = false
        #expect(button.superview == nil)
    }

    @Test @MainActor func reviewTargetsFollowIdentityAndUnmounting() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 20))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let review = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 200))
        review.interactionHandlers.enableGutterUtility = true
        review.fileInteractionHandlers.enableGutterUtility = true
        var getters: [@MainActor () -> CodeViewGutterTarget?] = []
        review.gutterRenderer = .init { read in getters.append(read); return NSButton(title: "+", target: nil, action: nil) }
        try review.setItems((0..<100).map { .init(id: "item-\($0)", document: document, file: $0 == 0 ? file : nil) })
        #expect(getters.count < 10)
        #expect(review.selectLines(.init(side: .additions, startLine: 2, endLine: 2), inItem: "item-0"))
        let read = try #require(getters.first)
        #expect(read()?.itemID == "item-0" && read()?.side == nil && read()?.file == file)
        #expect(review.updateItemID("item-0", to: "renamed"))
        #expect(read()?.itemID == "renamed")
        let renamed = try #require(review.getItem("renamed"))
        let second = try #require(review.getItem("item-1"))
        try review.setItems([second, renamed] + (2..<100).map { .init(id: "item-\($0)", document: document) })
        #expect(read()?.itemID == "renamed")
        review.scrollToFile(at: 90)
        #expect(read() == nil && review.mountedFileCount < 10)
        #expect(review.selectLines(.init(side: .deletions, startLine: 2, endLine: 2), inItem: "item-90"))
        #expect(getters.compactMap { $0() }.contains { $0.itemID == "item-90" && $0.side == .deletions })
        review.gutterRenderer = nil
        #expect(getters.allSatisfy { $0() == nil })
    }

    @Test @MainActor func reviewRendererCanResetDuringMount() async throws {
        let file = FileContents(name: "f.txt", contents: "line\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let review = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 200))
        review.gutterRenderer = .init { [weak review] _ in review?.reset(); return NSView() }
        try review.setItems([.init(id: "file", document: document)])
        #expect(review.fileCount == 0 && review.mountedFileCount == 0)
    }

    @Test @MainActor func fileAndThemeAdaptersRetainControls() async throws {
        let file = FileContents(name: "f.txt", contents: "first\nsecond\n")
        let themed = try await DiffHighlighter().prepareThemes(oldFile: file, newFile: file)
        let view = NativeFileView(frame: .init(x: 0, y: 0, width: 600, height: 200))
        view.interactionHandlers.enableGutterUtility = true
        var readFile: (@MainActor () -> FileHoveredLine?)?, calls = 0
        let renderer = FileGutterRenderer { read in calls += 1; readFile = read; return NSView(frame: .init(x: 0, y: 0, width: 20, height: 20)) }
        view.gutterRenderer = renderer; view.render(themed.dark, file: file)
        view.diffView.selectLines(.init(side: .additions, startLine: 2, endLine: 2))
        #expect(readFile?()?.lineNumber == 2)
        view.gutterRenderer = renderer; view.render(themed.dark, file: file)
        #expect(calls == 1)
        let themedView = NativeThemedDiffView(frame: view.frame)
        themedView.interactionHandlers.enableGutterUtility = true
        var readDiff: (@MainActor () -> DiffHoveredLine?)?, themeCalls = 0
        themedView.gutterRenderer = .init { read in themeCalls += 1; readDiff = read; return NSView(frame: .init(x: 0, y: 0, width: 20, height: 20)) }
        themedView.themeAppearance = .dark; themedView.render(themed)
        themedView.diffView.selectLines(.init(side: .deletions, startLine: 1, endLine: 1))
        themedView.themeAppearance = .light
        #expect(themeCalls == 1 && readDiff?() == .init(lineNumber: 1, side: .deletions))
    }

    @Test @MainActor func retainedControlFollowsHoverSelectionAndViewport() async throws {
        let file = FileContents(name: "gutter.txt", contents: String(repeating: "line\n", count: 100))
        let worker = DiffHighlighter()
        let document = try await worker.prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 200)); window.contentView = view
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.interactionHandlers.enableGutterUtility = true
        view.render(document, options: options)
        let canvas = try #require(view.scrollView.documentView)
        let utility = NSButton(title: "+", target: nil, action: nil)
        var getter: (@MainActor () -> DiffHoveredLine?)?, calls = 0
        view.renderGutterUtility = { read in getter = read; calls += 1; return utility }
        #expect(utility.isHidden && getter?() == nil)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(.init(x: 400, y: 25), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        canvas.mouseMoved(with: event)
        #expect(!utility.isHidden && getter?() == .init(lineNumber: 2, side: .additions))
        #expect(utility.frame.minX > 300 && utility.frame.minY == 20)
        view.selectLines(.init(side: .deletions, startLine: 5, endLine: 3))
        #expect(getter?() == .init(lineNumber: 5, side: .deletions))
        #expect(utility.frame.minX < 300 && utility.frame.minY == 80)
        canvas.mouseExited(with: event)
        #expect(!utility.isHidden && getter?() == .init(lineNumber: 5, side: .deletions))
        view.scrollToRow(60)
        #expect(utility.isHidden && getter?() == nil)
        view.scrollToRow(0)
        #expect(!utility.isHidden && getter?()?.lineNumber == 5)
        view.selectLines(nil)
        #expect(utility.isHidden && getter?() == nil)
        #expect(calls == 1 && canvas.subviews.filter { $0 === utility }.count == 1)
        view.renderGutterUtility = { _ in nil }
        #expect(utility.superview == nil)
        view.renderGutterUtility = nil
        view.interactionHandlers.enableGutterUtility = false
        #expect(canvas.trackingAreas.isEmpty)
    }

    @Test @MainActor func replacementAndReentrantRendererDoNotLeaveStaleControl() async throws {
        let worker = DiffHighlighter()
        let file = FileContents(name: "f.txt", contents: "first\nsecond\n")
        let document = try await worker.prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 200))
        view.interactionHandlers.enableGutterUtility = true
        view.render(document)
        let abandoned = NSView(), retained = NSView()
        view.renderGutterUtility = { _ in
            view.renderGutterUtility = { _ in retained }
            return abandoned
        }
        #expect(abandoned.superview == nil && retained.superview != nil)
        view.selectLines(.init(side: .additions, startLine: 1, endLine: 1))
        #expect(view.getHoveredLine()?.lineNumber == 1)
        let other = FileContents(name: "other.txt", contents: "replacement\n")
        view.render(try await worker.prepare(oldFile: other, newFile: other))
        #expect(view.getHoveredLine() == nil && retained.isHidden)
        var options = DiffRenderOptions(); options.disableLineNumbers = true
        view.interactionHandlers.enableGutterUtility = true
        view.render(document, options: options)
        view.selectLines(.init(side: .additions, startLine: 1, endLine: 1))
        #expect(retained.isHidden)
    }
}

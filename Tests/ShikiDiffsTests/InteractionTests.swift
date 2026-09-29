import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct InteractionTests {
    @Test @MainActor func accessibleSourceTracksSideAndReplacement() async throws {
        let worker = DiffHighlighter()
        let old = "old 🐝\n", new = "new e\u{301}\n"
        let document = try await worker.prepare(oldFile: .init(name: "a.txt", contents: old), newFile: .init(name: "a.txt", contents: new))
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.render(document)
        let canvas = try #require(view.scrollView.documentView)
        for _ in 0..<3 {
            #expect(canvas.accessibilityValue() as? String == new)
            #expect(canvas.accessibilityNumberOfCharacters() == new.utf16.count)
            #expect(canvas.accessibilityString(for: NSRange(location: 4, length: 2)) == "e\u{301}")
        }
        view.selectLines(.init(side: .deletions, startLine: 1, endLine: 1))
        #expect(canvas.accessibilityValue() as? String == old)
        #expect(canvas.accessibilityNumberOfCharacters() == old.utf16.count)
        view.selectLines(nil)
        #expect(canvas.accessibilityValue() as? String == new)
        let replacement = try await worker.prepare(oldFile: .init(name: "b.txt", contents: "x"), newFile: .init(name: "b.txt", contents: "replacement"))
        view.render(replacement)
        #expect(canvas.accessibilityValue() as? String == "replacement")
        #expect(canvas.accessibilityNumberOfCharacters() == 11)
        #expect(canvas.accessibilityString(for: NSRange(location: 11, length: 1)) == nil)
    }

    @Test @MainActor func accessibleSeparatorActionsRejectStaleState() async throws {
        let lines = (0..<400).map { "line \($0)\n" }
        var edited = lines; edited[200] = "changed\n"
        let worker = DiffHighlighter()
        let document = try await worker.prepare(oldFile: .init(name: "f.txt", contents: lines.joined()), newFile: .init(name: "f.txt", contents: edited.joined()))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.disableFileHeader = true; options.expansionLineCount = 20
        view.render(document, options: options)
        let canvas = try #require(view.scrollView.documentView)
        let actions = try #require(canvas.accessibilityCustomActions())
        let down = try #require(actions.first { $0.name == "Expand down context at hunk 1" })
        let perform = try #require(down.handler)
        let before = view.rowCount
        #expect(perform())
        #expect(view.rowCount == before + 20)
        #expect(!perform())
        #expect(view.rowCount == before + 20)
        let current = try #require(canvas.accessibilityCustomActions()?.first)
        let stale = try #require(current.handler)
        view.scrollToRow(view.rowCount - 1)
        let scrolled = view.scrollView.contentView.bounds.origin
        let rowCount = view.rowCount
        #expect(!stale())
        #expect(view.rowCount == rowCount)
        #expect(view.scrollView.contentView.bounds.origin == scrolled)
        view.scrollToRow(0)
        let file = FileContents(name: "replacement.txt", contents: "replacement\n")
        let replacement = try await worker.prepare(oldFile: file, newFile: file)
        view.render(replacement, options: options)
        #expect(!stale())
        #expect(canvas.accessibilityCustomActions() == nil)
        #expect(view.displayedDocument?.id == replacement.id)
    }

    @Test(arguments: [0, 1, 2], [180.0, 600.0]) @MainActor func middleSeparatorTargetsExpandIndependently(target: Int, width: Double) async throws {
        let lines = (0..<500).map { "line \($0)\n" }
        var edited = lines; edited[10] = "first change\n"; edited[400] = "second change\n"
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: lines.joined()), newFile: .init(name: "f.txt", contents: edited.joined()))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: width, height: 600)); window.contentView = view
        var options = DiffRenderOptions(); options.disableFileHeader = true; options.expansionLineCount = 20
        view.render(document, options: options)
        let plan = DiffRenderPlan(diff: document.diff, options: options)
        let index = try #require(plan.rows.firstIndex { if case .separator(_, 1) = $0.kind { return true }; return false })
        let data = try #require(plan.rows[index].hunkData(in: document.diff, type: .unified, expansionLineCount: 20))
        #expect(data.expansionActions == [.up, .down, .all])
        var direction: ExpansionDirection?
        var count: Int?
        var hunk: Int?
        view.onExpansion = { hunk = $0; count = $1; direction = $2 }
        let before = view.rowCount
        let canvas = try #require(view.scrollView.documentView)
        if target == 0 {
            let rect = NSRect(x: 0, y: view.measuredRowHeights.origin(of: index), width: canvas.visibleRect.width, height: view.measuredRowHeights.height(of: index))
            let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: rect))
            canvas.cacheDisplay(in: rect, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/swift-diffs-separator-\(Int(width)).png"))
        }
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(.init(x: target == 2 ? 100 : 24, y: view.measuredRowHeights.origin(of: index) + (target == 0 ? 16 : target == 1 ? 32 : 24)), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        canvas.mouseDown(with: click)
        #expect(hunk == 1)
        #expect(direction == (target == 0 ? .up : target == 1 ? .down : .both))
        #expect(count == (target == 2 ? data.lines : 20))
        #expect(view.rowCount == before + (target == 2 ? data.lines - 1 : 20))
    }

    @Test @MainActor func leadingSeparatorClickExpandsTowardFirstHunk() async throws {
        let lines = (0..<400).map { "line \($0)\n" }
        var edited = lines; edited[200] = "changed\n"
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: lines.joined()), newFile: .init(name: "f.txt", contents: edited.joined()))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.disableFileHeader = true; options.expansionLineCount = 20
        view.render(document, options: options)
        var direction: ExpansionDirection?
        var expandedIndex: Int?
        var expandedCount: Int?
        view.onExpansion = { expandedIndex = $0; expandedCount = $1; direction = $2 }
        let before = view.rowCount
        let canvas = try #require(view.scrollView.documentView)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(.init(x: 24, y: 24), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        canvas.mouseDown(with: event)
        #expect(expandedIndex == 0)
        #expect(expandedCount == 20)
        #expect(direction == .down)
        #expect(view.rowCount == before + 20)
        let hidden = document.diff.hunks[0].collapsedBefore - 20
        let allEvent = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(.init(x: 160, y: 10), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        canvas.mouseDown(with: allEvent)
        #expect(direction == .both)
        #expect(expandedCount == hidden)
        #expect(view.rowCount == before + 20 + hidden - 1)
        for style in [HunkSeparators.simple, .metadata] {
            options.hunkSeparators = style
            let fresh = NativeDiffView(frame: view.frame); window.contentView = fresh
            fresh.render(document, options: options)
            expandedIndex = nil
            fresh.onExpansion = { expandedIndex = $0; expandedCount = $1; direction = $2 }
            let count = fresh.rowCount
            let freshCanvas = try #require(fresh.scrollView.documentView)
            let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: freshCanvas.convert(.init(x: 24, y: 24), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0))
            freshCanvas.mouseDown(with: click)
            #expect(expandedIndex == nil)
            #expect(fresh.rowCount == count)
        }
    }

    @Test @MainActor func keyboardSelectionNormalizesOnlyGeneratedEndSide() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\nthree\nfour\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.render(document)
        let canvas = try #require(view.scrollView.documentView)
        func down(_ flags: NSEvent.ModifierFlags) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
            canvas.keyDown(with: event)
        }
        try down([.shift])
        #expect(view.selectedLines == .init(side: .additions, startLine: 2, endLine: 2))
        let explicit = LineSelection(side: .deletions, startLine: 1, endLine: 2, endSide: .deletions)
        view.selectLines(explicit)
        #expect(view.selectedLines == explicit)
        try down([.shift])
        #expect(view.selectedLines == .init(side: .deletions, startLine: 1, endLine: 3))
        view.selectLines(.init(side: .deletions, startLine: 1, endLine: 2, endSide: .additions))
        try down([.shift])
        #expect(view.selectedLines == .init(side: .deletions, startLine: 1, endLine: 3, endSide: .additions))
        try down([])
        #expect(view.selectedLines == .init(side: .additions, startLine: 4, endLine: 4))
    }

    @Test @MainActor func gutterDragCanEndOnOppositeSide() async throws {
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "a\nold\nz\n"), newFile: .init(name: "f.txt", contents: "a\nx\ny\nz\n"))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.render(document)
        var committed: LineSelection?
        var commitCount = 0
        view.interactionHandlers = .init(enableLineSelection: true, onLineSelected: { committed = $0; commitCount += 1 })
        let canvas = try #require(view.scrollView.documentView)
        let height = DiffRenderOptions().lineHeight
        func paintedColumns(at columns: [Int] = [200, 500]) throws -> [[NSColor]] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            canvas.draw(.init(x: 0, y: 0, width: 600, height: 300))
            return try columns.map { x in
                try (0..<Int(height * 4)).map { y in
                    try #require(bitmap.colorAt(x: x, y: 299 - y))
                }
            }
        }
        let unselectedPixels = try paintedColumns()
        let unselectedGutters = try paintedColumns(at: [5, 305])
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, .init(x: 10, y: height + 5)))
        canvas.mouseDragged(with: event(.leftMouseDragged, .init(x: 310, y: height * 2 + 5)))
        canvas.mouseUp(with: event(.leftMouseUp, .init(x: 310, y: height * 2 + 5)))
        #expect(view.selectedLines == .init(side: .deletions, startLine: 2, endLine: 3, endSide: .additions))
        #expect(committed == view.selectedLines)
        #expect(view.selectedText() == "old\nx\ny\n")
        let selectedPixels = try paintedColumns()
        #expect(selectedPixels[0] != unselectedPixels[0])
        #expect(selectedPixels[1] != unselectedPixels[1])
        let draggedSelection = view.selectedLines
        // Upstream paints logical rows in both split columns even when both
        // endpoints refer to the same source side.
        view.selectLines(.init(side: .additions, startLine: 2, endLine: 3), notify: false)
        #expect(try paintedColumns() == selectedPixels)
        view.selectLines(draggedSelection, notify: false, activeLineSide: .additions)
        let newSideOnly = try paintedColumns()
        #expect(newSideOnly[0] == unselectedPixels[0])
        #expect(newSideOnly[1] == selectedPixels[1])
        let commitsBeforeStyleChange = commitCount
        view.selectLines(draggedSelection, lineNumberOnly: true)
        #expect(commitCount == commitsBeforeStyleChange)
        #expect(try paintedColumns() == unselectedPixels)
        let selectedGutters = try paintedColumns(at: [5, 305])
        #expect(selectedGutters[0] != unselectedGutters[0])
        #expect(selectedGutters[1] != unselectedGutters[1])
        view.selectLines(nil, notify: false)
        #expect(try paintedColumns() == unselectedPixels)
        view.selectLines(draggedSelection, notify: false, activeLineSide: .additions, lineNumberOnly: true)
        func shiftClick(_ point: NSPoint) {
            let location = canvas.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let shifted = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
                if type == .leftMouseDown { canvas.mouseDown(with: shifted) } else { canvas.mouseUp(with: shifted) }
            }
        }
        // Clicking above the range keeps its lower endpoint as the anchor.
        shiftClick(.init(x: 10, y: 5))
        #expect(view.selectedLines == .init(side: .additions, startLine: 3, endLine: 1, endSide: .deletions))
        #expect(view.selectionHighlightSide == nil && !view.selectionLineNumberOnly)
        // Extending a reverse range below its end uses the end as its anchor.
        shiftClick(.init(x: 310, y: height * 3 + 5))
        #expect(view.selectedLines == .init(side: .deletions, startLine: 1, endLine: 4, endSide: .additions))
        let up = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126))
        canvas.keyDown(with: up)
        #expect(view.selectedLines == .init(side: .deletions, startLine: 1, endLine: 3, endSide: .additions))
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        canvas.keyDown(with: down)
        #expect(view.selectedLines == .init(side: .additions, startLine: 4, endLine: 4))
    }
    @Test @MainActor func shiftClickUsesUpstreamDirectedRangeAnchor() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\nthree\nfour\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 400, height: 200)); window.contentView = view
        var options = DiffRenderOptions(); options.diffStyle = .unified
        view.render(document, options: options)
        view.interactionHandlers.enableLineSelection = true
        let canvas = try #require(view.scrollView.documentView)
        // Expected anchors follow InteractionManager's directed range rule,
        // including clicks inside and outside both forward and reverse ranges.
        for (start, end, anchors) in [(2, 3, [3, 2, 2, 2]), (3, 2, [3, 3, 2, 2])] {
            for clicked in 1...4 {
                view.selectLines(.init(side: .additions, startLine: start, endLine: end), notify: false)
                let location = canvas.convert(.init(x: 10, y: CGFloat(clicked - 1) * options.lineHeight + 5), to: nil)
                func event(_ type: NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: location, modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
                }
                canvas.mouseDown(with: event(.leftMouseDown)); canvas.mouseUp(with: event(.leftMouseUp))
                #expect(view.selectedLines == .init(side: .additions, startLine: anchors[clicked - 1], endLine: clicked))
            }
        }
    }
    @Test @MainActor func gutterSelectionRequiresOptInWithoutSuppressingClicks() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 400, height: 200)); window.contentView = view
        var options = DiffRenderOptions(); options.diffStyle = .unified
        view.render(document, options: options)
        let canvas = try #require(view.scrollView.documentView)
        var clicks = 0
        view.interactionHandlers = .init(onLineNumberClick: { _ in clicks += 1 })
        func event(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(.init(x: 10, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, y: 10)); canvas.mouseUp(with: event(.leftMouseUp, y: 10))
        #expect(clicks == 1 && view.selectedLines == nil)
        view.interactionHandlers.enableLineSelection = true
        canvas.mouseDown(with: event(.leftMouseDown, y: 10)); canvas.mouseDragged(with: event(.leftMouseDragged, y: 30))
        #expect(view.selectedLines?.startLine == 1 && view.selectedLines?.endLine == 2)
        view.interactionHandlers.enableLineSelection = false
        canvas.mouseDragged(with: event(.leftMouseDragged, y: 10))
        #expect(view.selectedLines?.endLine == 2)
        canvas.mouseUp(with: event(.leftMouseUp, y: 10))
        #expect(clicks == 1)
        #expect(FileInteractionHandlers(enableLineSelection: true).adapting(file).enableLineSelection)
        var lifecycle: [String] = []
        func record(_ name: String, _ value: LineSelection?) { lifecycle.append(name + ":" + (value.map { String($0.endLine) } ?? "nil")) }
        view.selectLines(nil, notify: false)
        view.interactionHandlers = .init(enableLineSelection: true,
            onLineSelectionStart: { record("start", $0) }, onLineSelectionChange: { record("change", $0) },
            onLineSelectionEnd: { record("end", $0) }, onLineSelected: { record("committed", $0) })
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        canvas.mouseDragged(with: event(.leftMouseDragged, y: 30))
        canvas.mouseDragged(with: event(.leftMouseDragged, y: 30))
        canvas.mouseUp(with: event(.leftMouseUp, y: 30))
        #expect(lifecycle == ["start:1", "change:2", "end:2", "committed:2"])
        lifecycle = []; view.selectLines(nil, notify: false)
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        canvas.cancelOperation(nil)
        canvas.mouseDragged(with: event(.leftMouseDragged, y: 30))
        canvas.mouseUp(with: event(.leftMouseUp, y: 30))
        #expect(view.selectedLines == nil)
        #expect(lifecycle == ["start:1"])
        lifecycle = []; view.selectLines(.init(side: .additions, startLine: 1, endLine: 1), notify: false)
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        #expect(view.selectedLines != nil && lifecycle.isEmpty)
        canvas.mouseUp(with: event(.leftMouseUp, y: 10))
        #expect(view.selectedLines == nil)
        #expect(lifecycle == ["end:nil", "committed:nil"])
        lifecycle = []; view.selectLines(.init(side: .additions, startLine: 1, endLine: 1), notify: false)
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        canvas.mouseDragged(with: event(.leftMouseDragged, y: 30))
        canvas.mouseUp(with: event(.leftMouseUp, y: 30))
        #expect(lifecycle == ["start:2", "change:2", "end:2", "committed:2"])

        let replacement = HighlightedDiff(diff: document.diff, oldTokens: document.oldTokens, newTokens: document.newTokens, foreground: document.foreground, background: document.background)
        lifecycle = []; view.selectLines(.init(side: .additions, startLine: 1, endLine: 1), notify: false)
        view.onSelectionChange = { value in
            if value == nil { view.onSelectionChange = nil; view.render(replacement, options: options) }
        }
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        canvas.mouseUp(with: event(.leftMouseUp, y: 10))
        #expect(lifecycle.isEmpty)
        #expect(view.displayedDocument?.id == replacement.id)
        view.interactionHandlers.onLineSelectionEnd = { _ in
            lifecycle.append("end")
            view.render(document, options: options)
        }
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        canvas.mouseUp(with: event(.leftMouseUp, y: 10))
        #expect(lifecycle == ["start:1", "end"])
        lifecycle = []; view.selectLines(nil, notify: false)
        view.interactionHandlers = .init(enableLineSelection: true,
            onLineSelectionStart: { record("start", $0) }, onLineSelectionChange: { record("change", $0) },
            onLineSelectionEnd: { record("end", $0) }, onLineSelected: { record("committed", $0) }, controlledSelection: true)
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        canvas.mouseDragged(with: event(.leftMouseDragged, y: 30))
        #expect(view.selectedLines == nil)
        canvas.mouseUp(with: event(.leftMouseUp, y: 30))
        #expect(view.selectedLines == nil)
        #expect(lifecycle == ["start:1", "change:2", "end:2", "committed:2"])
        view.interactionHandlers.onLineSelected = { view.selectLines($0, notify: false) }
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        canvas.mouseUp(with: event(.leftMouseUp, y: 10))
        #expect(view.selectedLines == .init(side: .additions, startLine: 1, endLine: 1))
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        #expect(view.selectedLines != nil)
        canvas.mouseUp(with: event(.leftMouseUp, y: 10))
        #expect(view.selectedLines == nil)
        #expect(FileInteractionHandlers(controlledSelection: true).adapting(file).controlledSelection)
        lifecycle = []
        view.interactionHandlers.onLineSelectionChange = { _ in
            view.selectLines(.init(side: .additions, startLine: 1, endLine: 1), notify: false)
        }
        view.interactionHandlers.onLineSelected = { record("committed", $0) }
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        canvas.mouseDragged(with: event(.leftMouseDragged, y: 30))
        canvas.mouseUp(with: event(.leftMouseUp, y: 30))
        #expect(view.selectedLines?.endLine == 1)
        #expect(lifecycle == ["start:1", "end:1", "committed:1"])
        lifecycle = []; view.selectLines(nil, notify: false)
        view.interactionHandlers.onLineSelectionChange = { record("change", $0) }
        view.interactionHandlers.onLineSelectionEnd = { value in
            record("end", value)
            view.selectLines(.init(side: .additions, startLine: 2, endLine: 2), notify: false)
        }
        canvas.mouseDown(with: event(.leftMouseDown, y: 10))
        canvas.mouseUp(with: event(.leftMouseUp, y: 10))
        #expect(lifecycle == ["start:1", "end:1", "committed:2"])
        #expect(view.selectedLines == .init(side: .additions, startLine: 2, endLine: 2))
        view.selectLines(nil, notify: false)
        lifecycle = []
        view.selectLines(.init(side: .additions, startLine: 2, endLine: 2))
        view.selectLines(.init(side: .additions, startLine: 2, endLine: 2))
        #expect(lifecycle == ["committed:2"])
        view.selectLines(nil, notify: false)
        #expect(lifecycle == ["committed:2"])




    }
    @Test @MainActor func hoverHighlightModesPaintOnlyRequestedRegions() async throws {
        let file = FileContents(name: "f.txt", contents: "abc\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 400, height: 200)); window.contentView = view
        var options = DiffRenderOptions(); options.diffStyle = .unified
        view.render(document, options: options)
        let canvas = try #require(view.scrollView.documentView)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(.init(x: 100, y: 10), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        func pixels() throws -> [NSColor] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            canvas.draw(.init(x: 0, y: 0, width: 400, height: 200))
            return try [40, 180].map { try #require(bitmap.colorAt(x: $0, y: 189)) }
        }
        let baseline = try pixels()
        for mode in [LineHoverHighlight.number, .line, .both] {
            view.interactionHandlers = .init(lineHoverHighlight: mode)
            canvas.mouseMoved(with: event)
            #expect(!canvas.trackingAreas.isEmpty)
            let painted = try pixels()
            #expect((painted[0] != baseline[0]) == (mode != .line))
            #expect((painted[1] != baseline[1]) == (mode != .number))
            canvas.mouseExited(with: event)
            #expect(try pixels() == baseline)
        }
        view.selectLines(.init(side: .additions, startLine: 1, endLine: 1), notify: false)
        view.interactionHandlers = .init()
        let selected = try pixels()
        #expect(selected != baseline)
        #expect(selected[0] != selected[1])
        view.interactionHandlers = .init(lineHoverHighlight: .line)
        canvas.mouseMoved(with: event)
        let selectedHovered = try pixels()
        #expect(selectedHovered[0] == selected[0])
        #expect(selectedHovered[1] != selected[1])
        canvas.mouseExited(with: event)
        #expect(try pixels() == selected)
        view.interactionHandlers = .init()
        #expect(canvas.trackingAreas.isEmpty)
        #expect(FileInteractionHandlers(lineHoverHighlight: .both).adapting(file).lineHoverHighlight == .both)
        view.selectLines(nil, notify: false)
        let editor = try view.beginEditing()
        await editor.waitForRendering()
        editor.select(.init(location: 0, length: 0))
        let caret = try pixels()
        editor.select(.init(location: 0, length: 1))
        let textSelected = try pixels()
        // Code away from selected text loses the active treatment; gutter remains.
        #expect(caret[0] == textSelected[0])
        if view.displayedDocument?.palette.editorLineHighlightBackground != nil {
            #expect(caret[1] != textSelected[1])
        }

    }
    @Test @MainActor func lineAndGutterClicksUseNativeHitGeometry() async throws {
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "same\nold\n"), newFile: .init(name: "f.txt", contents: "same\nnew\n"))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = view
        view.render(document)
        let canvas = try #require(view.scrollView.documentView)
        var lines: [DiffLineClickEvent] = [], numbers: [DiffLineClickEvent] = []
        view.interactionHandlers = .init(onLineClick: { lines.append($0) })
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [.shift], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func click(_ point: NSPoint) { canvas.mouseDown(with: event(.leftMouseDown, point)); canvas.mouseUp(with: event(.leftMouseUp, point)) }
        click(.init(x: 10, y: 10))
        #expect(lines.count == 1 && lines[0].numberColumn)
        #expect(lines[0].lineNumber == 1 && lines[0].annotationSide == .deletions && lines[0].lineType == .context)
        view.interactionHandlers.onLineNumberClick = { numbers.append($0) }
        click(.init(x: 10, y: 30))
        #expect(lines.count == 1 && numbers.count == 1)
        #expect(numbers[0].lineType == .changeDeletion)
        click(.init(x: view.scrollView.contentSize.width / 2 + 100, y: 30))
        #expect(lines.count == 2 && !lines[1].numberColumn)
        #expect(lines[1].annotationSide == .additions && lines[1].lineType == .changeAddition)
        #expect(lines[1].lineRect.contains(.init(x: view.scrollView.contentSize.width / 2 + 100, y: 30)))
        #expect(lines[1].event.modifierFlags.contains(.shift))
        canvas.mouseDown(with: event(.leftMouseDown, .init(x: 100, y: 10)))
        canvas.mouseDragged(with: event(.leftMouseDragged, .init(x: 110, y: 30)))
        canvas.mouseUp(with: event(.leftMouseUp, .init(x: 110, y: 30)))
        #expect(lines.count == 2 && numbers.count == 1)
        view.render(document, annotations: [.init(lineNumber: 1, text: "Note")])
        click(.init(x: 100, y: 30))
        #expect(lines.count == 2 && numbers.count == 1)
        var options = DiffRenderOptions(); options.disableLineNumbers = true
        view.render(document, options: options)
        click(.init(x: 10, y: 10))
        #expect(lines.count == 3 && !lines[2].numberColumn)
        #expect(lines[2].fileDiff.name == "f.txt")
        let other = try await DiffHighlighter().prepare(oldFile: .init(name: "other.txt", contents: "same\n"), newFile: .init(name: "other.txt", contents: "same\n"))
        canvas.mouseDown(with: event(.leftMouseDown, .init(x: 100, y: 10)))
        view.render(other)
        canvas.mouseUp(with: event(.leftMouseUp, .init(x: 100, y: 10)))
        #expect(lines.count == 3)

    }
    @Test @MainActor func fileAndMultiFileAdaptersForwardClicks() async throws {
        let file = FileContents(name: "file.txt", contents: "same\n", header: "Metadata", cacheKey: "original")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        func click(_ canvas: NSView) {
            let point = canvas.convert(.init(x: 100, y: 10), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
            }
        }
        let single = NativeFileView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = single
        var received: FileContents?
        single.interactionHandlers = .init(onLineClick: { received = $0.file })
        single.render(document, file: file)
        click(try #require(single.diffView.scrollView.documentView))
        #expect(received == file)
        let review = NativeCodeView(frame: single.frame); window.contentView = review
        var names: [String] = []
        review.interactionHandlers = .init(onLineClick: { names.append($0.fileDiff.name) })
        review.render([document])
        let mounted = try #require(review.scrollView.documentView?.subviews.compactMap { $0 as? NativeDiffView }.first)
        click(try #require(mounted.scrollView.documentView))
        #expect(names == ["file.txt"])
        review.interactionHandlers = .init()
        click(try #require(mounted.scrollView.documentView))
        #expect(names.count == 1)
    }

    @Test @MainActor func hoverTransitionsReuseOneTrackingArea() async throws {
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "same\nold\n"), newFile: .init(name: "f.txt", contents: "same\nnew\n"))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = view
        view.render(document)
        let canvas = try #require(view.scrollView.documentView)
        var events: [String] = []
        view.interactionHandlers = .init(onLineEnter: { events.append("enter:\($0.annotationSide.rawValue):\($0.lineNumber):\($0.numberColumn)") },
                                         onLineLeave: { events.append("leave:\($0.annotationSide.rawValue):\($0.lineNumber):\($0.numberColumn)") })
        func move(_ x: CGFloat, _ y: CGFloat) {
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(.init(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
            canvas.mouseMoved(with: event)
        }
        move(10, 10); move(100, 10); move(120, 10)
        #expect(events == ["enter:deletions:1:true"])
        move(100, 30)
        #expect(events.suffix(2) == ["leave:deletions:1:true", "enter:deletions:2:false"])
        move(view.scrollView.contentSize.width / 2 + 100, 30)
        #expect(events.suffix(2) == ["leave:deletions:2:false", "enter:additions:2:false"])
        move(100, 200)
        #expect(events.last == "leave:additions:2:false")
        let count = events.count; move(120, 200); #expect(events.count == count)
        let tracking = try #require(canvas.trackingAreas.first)
        for _ in 0..<20 { canvas.updateTrackingAreas() }
        #expect(canvas.trackingAreas.count == 1 && canvas.trackingAreas.first === tracking)
        view.interactionHandlers = .init()
        #expect(canvas.trackingAreas.isEmpty)
        move(100, 10); #expect(events.count == count)
    }

    @Test @MainActor func stationaryPointerFollowsScrollAndDragging() async throws {
        let contents = (0..<100).map { "line \($0)\n" }.joined()
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: contents), newFile: .init(name: "f.txt", contents: contents))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = view
        view.render(document)
        let canvas = try #require(view.scrollView.documentView)
        var entered: [Int] = [], left: [Int] = []
        view.interactionHandlers = .init(onLineEnter: { entered.append($0.lineNumber) }, onLineLeave: { left.append($0.lineNumber) })
        func event(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(.init(x: 100, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        }
        canvas.mouseMoved(with: event(.mouseMoved, y: 10))
        #expect(entered == [1])
        view.restoreEditorScrollOrigin(.init(x: 0, y: 200))
        #expect(entered == [1, 11] && left == [1])
        canvas.mouseDragged(with: event(.leftMouseDragged, y: 250))
        #expect(entered.last == 13 && left.last == 11)
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: canvas.convert(.init(x: 100, y: 250), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        canvas.mouseExited(with: exit)
        let count = entered.count
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 400))
        #expect(entered.count == count && left.last == 13)
    }

    @Test @MainActor func reviewTransfersStationaryHoverAcrossUnmountedFiles() async throws {
        let highlighter = DiffHighlighter()
        var documents: [HighlightedDiff] = []
        for index in 0..<100 {
            let file = FileContents(name: "f\(index).txt", contents: "line\n")
            documents.append(try await highlighter.prepare(oldFile: file, newFile: file))
        }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let review = NativeCodeView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = review
        var entered: [String] = [], left: [String] = [], transitions: [String] = []
        review.interactionHandlers = .init(onLineEnter: { entered.append($0.fileDiff.name); transitions.append("enter:" + $0.fileDiff.name) }, onLineLeave: { left.append($0.fileDiff.name); transitions.append("leave:" + $0.fileDiff.name) })
        review.render(documents)
        let host = try #require(review.scrollView.documentView)
        let location = host.convert(.init(x: 100, y: 58), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        host.mouseMoved(with: event)
        #expect(entered == ["f0.txt"])
        let mounted = Set(host.subviews.map(ObjectIdentifier.init))
        review.headerRenderers = .init(renderHeaderPrefix: { _ in NSTextField(labelWithString: "Review") })
        #expect(Set(host.subviews.map(ObjectIdentifier.init)) == mounted)
        #expect(entered == ["f0.txt"] && left.isEmpty)
        let second = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: host.convert(.init(x: 100, y: 130), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0))
        host.mouseMoved(with: second)
        #expect(transitions.suffix(2) == ["leave:f0.txt", "enter:f1.txt"])
        host.mouseMoved(with: event)
        #expect(transitions.suffix(2) == ["leave:f1.txt", "enter:f0.txt"])
        entered = ["f0.txt"]; left = []
        review.scrollToFile(at: 80)
        #expect(left == ["f0.txt"])
        #expect(entered == ["f0.txt", "f80.txt"])
        #expect(review.mountedFileCount <= 9)
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        host.mouseExited(with: exit)
        #expect(left.last == "f80.txt")
        review.scrollToFile(at: 20)
        #expect(entered.count == 2)
        host.updateTrackingAreas()
        #expect(host.trackingAreas.count == 1)
        review.interactionHandlers = .init(onLineClick: { _ in })
        host.updateTrackingAreas()
        #expect(host.trackingAreas.isEmpty)
        #expect(host.subviews.compactMap { $0 as? NativeDiffView }.allSatisfy { $0.scrollView.documentView?.trackingAreas.isEmpty == true })
        host.mouseMoved(with: event)
        review.interactionHandlers = .init(onLineEnter: { entered.append($0.fileDiff.name) })
        review.scrollToFile(at: 40)
        #expect(entered.count == 2)
    }

}

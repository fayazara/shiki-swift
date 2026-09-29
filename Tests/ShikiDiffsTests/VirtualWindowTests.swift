import Testing
import AppKit
@testable import ShikiDiffs

struct VirtualWindowTests {
    @Test @MainActor func windowSnapshotTracksMountingWithoutChangingViewport() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        #expect(view.getWindowSpecs() == .init(top: 0, bottom: 0))
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems((0..<100).map { .init(id: "file\($0)", document: document) }, options: options)
        view.layoutSubtreeIfNeeded()
        view.overscrollSize = 200
        view.scrollToFile(at: 50)
        let position = view.scrollTop, count = view.mountedFileCount
        let snapshot = view.getWindowSpecs()
        #expect(snapshot.top == floor(Double(position) - 200))
        #expect(snapshot.bottom == ceil(Double(position + view.scrollView.contentView.bounds.height) + 200))
        #expect(view.scrollTop == position && view.mountedFileCount == count)
        view.reset()
        #expect(view.getWindowSpecs() == .init(top: 0, bottom: 0))
    }
    @Test @MainActor func renderedItemSnapshotsFollowMountedViewport() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems((0..<100).map { .init(id: "item\($0)", document: document, file: $0 == 99 ? file : nil) }, options: options)
        view.layoutSubtreeIfNeeded()
        let first = view.getRenderedItems()
        #expect(!first.isEmpty && first.count == view.mountedFileCount)
        #expect(first.first?.id == "item0")
        #expect(first.first?.version == document.id)
        view.scrollToFile(at: 99)
        let last = view.getRenderedItems()
        #expect(last.count == view.mountedFileCount)
        #expect(last.contains { $0.id == "item99" && $0.isFile })
        #expect(!last.contains { $0.id == "item0" })
        #expect(first.first?.id == "item0")
        #expect(view.updateItemID("item99", to: "renamed"))
        #expect(view.getRenderedItems().contains { $0.id == "renamed" })
        view.reset()
        #expect(view.getRenderedItems().isEmpty)
    }
    @Test @MainActor func itemTopLookupDoesNotMountOrScroll() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems((0..<100).map { .init(id: "item\($0)", document: document) }, layout: .init(paddingTop: 17, paddingBottom: 19, gap: 11))
        view.layoutSubtreeIfNeeded()
        let mounted = view.mountedFileCount, top = view.scrollTop
        #expect(view.getTopForItem("item0") == 17)
        let last = try #require(view.getTopForItem("item99"))
        #expect(last > 300)
        #expect(view.getTopForItem("missing") == nil)
        #expect(view.mountedFileCount == mounted && view.scrollTop == top)
        #expect(view.updateItemID("item99", to: "renamed"))
        #expect(view.getTopForItem("renamed") == last)
        #expect(view.getTopForItem("item99") == nil)
    }
    @Test @MainActor func reviewSelectionNotificationsSupportReentrantRemoval() async throws {
        let file = FileContents(name: "f.txt", contents: "first\nsecond\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems([.init(id: "one", document: document)])
        var events: [CodeViewLineSelection?] = []
        view.onSelectedLinesChange = { selection in
            events.append(selection)
            if selection == nil {
                do { try view.setItems([.init(id: "replacement", document: document)]) }
                catch { Issue.record("Reentrant update failed: \(error)") }
            }
        }
        let range = LineSelection(side: .additions, startLine: 1, endLine: 1)
        view.setSelectedLines(.init(id: "one", range: range))
        #expect(events == [.init(id: "one", range: range)])
        #expect(view.updateItemID("one", to: "renamed"))
        #expect(events.last! == .init(id: "renamed", range: range))
        #expect(try view.removeItem("renamed"))
        #expect(events.count == 3 && events.last! == nil)
        #expect(view.getItem("replacement") != nil)
        view.setSelectedLines(.init(id: "absent", range: range))
        #expect(events.count == 3)
        try view.setItems([.init(id: "replacement", document: document)])
        #expect(events.count == 4 && events.last! == nil)
    }
    @Test @MainActor func deferredItemSelectionReconcilesExactIdentity() async throws {
        let file = FileContents(name: "f.txt", contents: "first\nsecond\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        let range = LineSelection(side: .additions, startLine: 2, endLine: 2)
        let target = CodeViewLineSelection(id: "e\u{301}", range: range)
        view.setSelectedLines(target)
        #expect(view.getSelectedLines() == target)
        #expect(view.selectedLines == nil)
        try view.setItems([.init(id: target.id, document: document)])
        #expect(view.getSelectedLines() == target)
        #expect(view.selectedText(inItem: target.id) == "second\n")
        view.setSelectedLines(.init(id: "é", range: range))
        #expect(view.selectedLines == nil)
        #expect(view.getSelectedLines()?.id.utf16.elementsEqual("é".utf16) == true)
        try view.setItems([.init(id: target.id, document: document)])
        #expect(view.getSelectedLines() == nil)
        view.setSelectedLines(target)
        view.clearSelectedLines()
        #expect(view.getSelectedLines() == nil)
        view.setSelectedLines(.init(id: "absent", range: range))
        view.reset()
        #expect(view.getSelectedLines() == nil)
        view.setSelectedLines(.init(id: "absent", range: range))
        view.render([document])
        #expect(view.getSelectedLines() == nil)
    }
    @Test @MainActor func teardownCallbackCanReplaceRemovedIdentity() async throws {
        let highlighter = DiffHighlighter()
        let old = FileContents(name: "f.txt", contents: "old\n")
        let fresh = FileContents(name: "f.txt", contents: "replacement\n")
        let document = try await highlighter.prepare(oldFile: old, newFile: old)
        let replacement = try await highlighter.prepare(oldFile: fresh, newFile: fresh)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems([.init(id: "file", document: document)])
        let editor = try view.beginEditingItem("file")
        var notifications = 0
        editor.onEditComplete = { _ in
            notifications += 1
            do { try view.setItems([.init(id: "file", document: replacement)]) }
            catch { Issue.record("Replacement failed: \(error)") }
            return true
        }
        _ = try view.removeItem("file")
        await editor.waitForTeardown()
        #expect(notifications == 1)
        #expect(view.getItem("file")?.document.id == replacement.id)
        #expect(view.fileCount == 1 && !editor.isActive)
        let next = try view.beginEditingItem("file")
        #expect(next !== editor && next.document.getText() == "replacement\n")
        view.reset(); await next.waitForTeardown()
        #expect(notifications == 1)
    }

    @Test(arguments: [false, true]) @MainActor func removalBeforeCompletionDeliveryNotifiesExactlyOnce(reset: Bool) async throws {
        let file = FileContents(name: "f.txt", contents: "original\n")
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems([.init(id: "file", document: prepared)])
        let editor = try view.beginEditingItem("file")
        editor.select(.init(location: 0, length: 8))
        editor.insertText("edited", replacementRange: .init(location: NSNotFound, length: 0))
        let barrier = CompletionFinalizationBarrier()
        editor.beforeCompletionFinalization = { await barrier.hold() }
        var notifications = 0, writes = 0
        view.onItemsChange = { _ in writes += 1 }
        editor.onEditComplete = { event in
            notifications += 1
            #expect(event.newFile?.contents == "edited\n")
            #expect(view.getItem("file") == nil)
            return true
        }
        let completion = Task { try await view.completeEditingItem("file") }
        await barrier.waitForEntry()
        #expect(!editor.isActive && notifications == 0)
        if reset { view.reset() } else { _ = try view.removeItem("file") }
        barrier.release()
        do {
            _ = try await completion.value
            Issue.record("Removed completion unexpectedly succeeded")
        } catch DiffEditorError.detached { }
        await editor.waitForTeardown()
        #expect(notifications == 1 && writes == 0)
        #expect(view.fileCount == 0 && view.mountedFileCount == 0)
        #expect(editor.installedCompletionDocument == nil)
    }

    @Test(arguments: [false, true]) @MainActor func removalNotifiesActiveEditorWithoutInstalling(reset: Bool) async throws {
        let file = FileContents(name: "f.txt", contents: "original\n")
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems([.init(id: "file", document: prepared)])
        let editor = try view.beginEditingItem("file")
        editor.select(.init(location: 0, length: 8))
        editor.insertText("edited", replacementRange: .init(location: NSNotFound, length: 0))
        var completions = 0, writes = 0
        view.onItemsChange = { _ in writes += 1 }
        editor.onEditComplete = { result in
            completions += 1
            #expect(result.newFile?.contents == "edited\n")
            #expect(view.getItem("file") == nil)
            return true
        }
        if reset { view.reset() } else { #expect(try view.removeItem("file")) }
        #expect(!editor.isActive && view.mountedFileCount == 0)
        await editor.waitForTeardown()
        #expect(completions == 1 && writes == 0)
        #expect(view.fileCount == 0 && editor.installedCompletionDocument == nil)
        view.reset(); await editor.waitForTeardown()
        #expect(completions == 1)
    }

    @Test @MainActor func itemSelectionUsesCurrentIdentityWithoutMounting() async throws {
        let file = FileContents(name: "f.txt", contents: "first\nsecond\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        let items = (0..<100).map { CodeViewItem(id: "item-\($0)", document: document) }
        try view.setItems(items)
        let mounted = view.mountedFileCount
        let range = LineSelection(side: .additions, startLine: 2, endLine: 2)
        #expect(view.selectLines(range, inItem: "item-99", notify: false))
        #expect(view.selectedText(inItem: "item-99") == "second\n")
        #expect(view.mountedFileCount == mounted && view.scrollTop == 0)
        #expect(!view.selectLines(range, inItem: "missing"))
        #expect(view.selectedItemLines?.id == "item-99")
        try view.setItems(Array(items.reversed()))
        #expect(view.selectedItemLines?.id == "item-99")
        #expect(view.selectText(.init(side: .additions, anchor: .init(line: 0, character: 1), head: .init(line: 0, character: 4)), inItem: "item-99"))
        #expect(view.selectedText(inItem: "item-99") == "irs")
        #expect(view.updateItemID("item-99", to: "renamed"))
        #expect(view.selectedText(inItem: "renamed") == "irs")
        #expect(view.selectLines(nil, inItem: "renamed", notify: false))
        #expect(view.selectedItemLines == nil)
    }

    @Test(arguments: [0, 1, 2]) @MainActor func offscreenCompletionDoesNotOverwriteHostReplacement(change: Int) async throws {
        let highlighter = DiffHighlighter()
        let original = FileContents(name: "f.txt", contents: "original\n")
        let updated = FileContents(name: "f.txt", contents: "host replacement\n")
        let document = try await highlighter.prepare(oldFile: original, newFile: original)
        let replacement = try await highlighter.prepare(oldFile: original, newFile: updated)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems((0..<100).map { .init(id: "file-\($0)", document: document) })
        let editor = try view.beginEditingItem("file-0")
        editor.select(.init(location: 0, length: 8))
        editor.insertText("local", replacementRange: .init(location: NSNotFound, length: 0))
        view.scrollToFile(at: 90)
        #expect(editor.isSuspended)
        let next = CodeViewItem(id: "file-0", document: change == 0 ? replacement : document,
            annotations: change == 1 ? [.init(lineNumber: 1, text: "New host comment")] : [],
            file: change == 2 ? original : nil)
        var writeBacks = 0
        view.onItemsChange = { _ in writeBacks += 1 }
        editor.onEditComplete = { _ in
            do { #expect(try view.updateItem(next)) }
            catch { Issue.record("Replacement failed: \(error)") }
            return true
        }
        do {
            _ = try await view.completeEditingItem("file-0")
            Issue.record("Superseded completion unexpectedly installed")
        } catch DiffEditorError.detached { }
        #expect(view.getItem("file-0")?.document.id == next.document.id)
        #expect(view.getItem("file-0")?.annotations == next.annotations)
        #expect(view.getItem("file-0")?.file == next.file)
        #expect(writeBacks == 0)
        #expect(view.getEditor("file-0") == nil)
    }

    @Test(arguments: [false, true]) @MainActor func completionCallbackRemovalCannotResurrectItem(reset: Bool) async throws {
        let file = FileContents(name: "f.swift", contents: "let value = 1\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems([.init(id: "file", document: document)])
        let editor = try view.beginEditingItem("file")
        editor.select(.init(location: 12, length: 1))
        editor.insertText("2", replacementRange: .init(location: NSNotFound, length: 0))
        var completions = 0, writeBacks = 0
        view.onItemsChange = { _ in writeBacks += 1 }
        editor.onEditComplete = { event in
            completions += 1
            #expect(event.newFile?.contents == "let value = 2\n")
            if reset { view.reset() }
            else {
                do { #expect(try view.removeItem("file")) }
                catch { Issue.record("Removal failed: \(error)") }
            }
            return true
        }
        do {
            _ = try await view.completeEditingItem("file")
            Issue.record("Removed session unexpectedly installed")
        } catch DiffEditorError.detached { }
        #expect(completions == 1 && writeBacks == 0)
        #expect(view.getItem("file") == nil && view.getEditor("file") == nil)
        #expect(view.fileCount == 0 && view.mountedFileCount == 0)
        #expect(editor.installedCompletionDocument == nil)
    }

    @Test @MainActor func resetClearsReviewAndAllowsReuseWithSameIDs() async throws {
        let file = FileContents(name: "reset.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems((0..<20).map { .init(id: "file-\($0)", document: document) })
        let editor = try view.beginEditingItem("file-0")
        view.scrollToFile(at: 19)
        view.selectLines(.init(side: .additions, startLine: 2, endLine: 3), inFileAt: 19)
        view.reset()
        #expect(view.fileCount == 0 && view.mountedFileCount == 0)
        #expect(view.scrollTop == 0 && view.selectedItemLines == nil)
        #expect(view.getItem("file-0") == nil && !editor.isActive)
        await editor.waitForRendering()
        try view.setItems([.init(id: "file-0", document: document)])
        view.layoutSubtreeIfNeeded()
        #expect(view.fileCount == 1 && view.mountedFileCount == 1)
        #expect(view.selectedItemLines == nil && view.getEditor("file-0") == nil)
        #expect(view.scrollTop == 0)
    }

    @Test @MainActor func swiftUIDismantlingRetiresSessionsAndDisconnectsController() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        let controller = CodeViewController(); controller.attach(view)
        try view.setItems([.init(id: "file", document: document)])
        let editor = try view.beginEditingItem("file")
        var callbacks = 0
        let cancel = view.subscribeToScroll { _, _ in callbacks += 1 }
        CodeView.dismantleNSView(view, coordinator: ())
        #expect(!editor.isActive && !editor.isPreparing)
        #expect(controller.view == nil)
        #expect(view.fileCount == 0 && view.mountedFileCount == 0)
        #expect(callbacks == 0)
        await editor.waitForRendering()
        #expect(view.mountedFileCount == 0)
        cancel()
        let replacement = NativeCodeView(frame: .zero)
        controller.attach(replacement)
        CodeView.dismantleNSView(view, coordinator: ())
        #expect(controller.view === replacement)
    }

    @Test @MainActor func offscreenEditCompletionInstallsIntoItemAndSurvivesRemount() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems((0..<100).map { .init(id: "file-\($0)", document: document) })
        let editor = try view.beginEditingItem("file-0")
        editor.select(.init(location: 0, length: 4)); editor.insertText("edited", replacementRange: .init(location: NSNotFound, length: 0))
        view.scrollToFile(at: 90)
        #expect(editor.isSuspended)
        _ = try await view.completeEditingItem("file-0")
        #expect(view.getEditor("file-0") == nil)
        #expect(view.getItem("file-0")?.document.diff.additionLines.first == "edited\n")
        view.scrollToFile(at: 0)
        let mounted = try #require(view.scrollView.documentView?.subviews.compactMap { $0 as? NativeDiffView }.first)
        #expect(mounted.displayedDocument?.diff.additionLines.first == "edited\n")
        let next = try view.beginEditingItem("file-0")
        next.select(.init(location: 0, length: 6)); next.insertText("discarded", replacementRange: .init(location: NSNotFound, length: 0))
        view.scrollToFile(at: 90)
        _ = try await view.completeEditingItem("file-0", mode: .discard)
        #expect(view.getItem("file-0")?.document.diff.additionLines.first == "edited\n")
    }

    @Test @MainActor func reviewEditorSurvivesViewportRemovalAndItemRename() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems((0..<100).map { .init(id: "file-\($0)", document: document) })
        let editor = try view.beginEditingItem("file-0")
        editor.select(.init(location: 0, length: 4)); editor.insertText("edited", replacementRange: .init(location: NSNotFound, length: 0))
        await editor.waitForRendering()
        view.scrollToFile(at: 90)
        #expect(editor.isSuspended && editor.isActive)
        #expect(view.mountedFileCount <= 2)
        #expect(view.updateItemID("file-0", to: "renamed"))
        #expect(view.getEditor("renamed") === editor)
        #expect(view.getEditor("file-0") == nil)
        view.scrollToFile(at: 0)
        await editor.waitForRendering()
        #expect(!editor.isSuspended)
        #expect(editor.document.getText().hasPrefix("edited\n"))
        editor.undoManager.undo()
        #expect(editor.document.getText() == file.contents)
        #expect(try view.removeItem("renamed"))
        #expect(!editor.isActive && view.getEditor("renamed") == nil)
    }

    @Test @MainActor func mixedReviewRoutesFileHeadersAndSelectionCallbacks() async throws {
        let file = FileContents(name: "original.txt", contents: String(repeating: "line\n", count: 100), lang: "text", cacheKey: "original-key")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var received: [FileContents] = [], fileSelections = 0, diffSelections = 0
        view.fileHeaderRenderers = .init(renderCustomHeader: { metadata in
            received.append(metadata)
            return NSView(frame: .init(x: 0, y: 0, width: 100, height: 80))
        })
        view.fileInteractionHandlers = .init(onLineSelected: { _ in fileSelections += 1 })
        view.interactionHandlers = .init(onLineSelected: { _ in diffSelections += 1 })
        try view.setItems([.init(id: "file", document: document, file: file), .init(id: "diff", document: document)])
        #expect(received == [file])
        let range = LineSelection(side: .additions, startLine: 1, endLine: 1)
        view.selectLines(range, inFileAt: 0)
        #expect(fileSelections == 1 && diffSelections == 0)
        view.selectLines(range, inFileAt: 1)
        #expect(fileSelections == 1 && diffSelections == 1)
        view.fileInteractionHandlers = .init(onLineSelected: { _ in fileSelections += 10 })
        view.selectLines(range, inFileAt: 0)
        #expect(fileSelections == 11)
        view.fileHeaderRenderers = .init(renderCustomHeader: { metadata in
            received.append(metadata)
            return NSView(frame: .init(x: 0, y: 0, width: 100, height: 120))
        })
        #expect(received.last == file)
    }

    @Test @MainActor func mixedReviewFilesUseFullWidthWrappingAndExpandedContent() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: String(repeating: "word ", count: 30) + "\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.overflow = .wrap; options.disableFileHeader = true
        try view.setItems([.init(id: "file", document: document, file: file), .init(id: "diff", document: document)], options: options)
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparingWrappedLayout)
        var fileOptions = options; fileOptions.diffStyle = .unified; fileOptions.expandUnchanged = true
        let expected = try await DiffWrapLayout.shared.layout(plan: .init(diff: document.diff, options: fileOptions), diff: document.diff,
            width: view.scrollView.contentSize.width - 72,
            fontName: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName, fontSize: 13)
        let mounted = try #require(view.scrollView.documentView?.subviews.compactMap { $0 as? NativeDiffView }.first)
        #expect(mounted.rowCount == expected.rows.count)
        #expect(view.scrollToRange(.init(side: .additions, startLine: 90, endLine: 90), inItem: "file"))
        let row = try #require(expected.rows.firstIndex { $0.newNumber == 90 })
        #expect(view.scrollTop == CGFloat(8 + row * 20))
    }

    @Test @MainActor func pendingItemNavigationSurvivesRenameAndReorder() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: String(repeating: "word ", count: 30) + "\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.overflow = .wrap; options.disableFileHeader = true
        try view.setItems((0..<100).map { .init(id: "file-\($0)", document: document) }, options: options)
        #expect(view.isPreparingWrappedLayout)
        let range = LineSelection(side: .additions, startLine: 50, endLine: 52)
        #expect(view.scrollToRange(range, inItem: "file-90", align: .end, offset: 10))
        #expect(view.updateItemID("file-90", to: "renamed"))
        let target = try #require(view.getItem("renamed"))
        try view.setItems([target, .init(id: "other", document: document)])
        view.setFrameSize(.init(width: 1000, height: 300)); view.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparingWrappedLayout)
        let plan = try await DiffWrapLayout.shared.layout(plan: .init(diff: document.diff, options: options), diff: document.diff,
            width: view.scrollView.contentSize.width / 2 - 72,
            fontName: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName, fontSize: 13)
        let last = try #require(plan.rows.lastIndex { $0.newNumber == 52 })
        let expected = CGFloat(8 + (last + 1) * 20 - 300 + 10)
        #expect(view.scrollTop == expected)
    }

    @Test @MainActor func explicitItemIDsReconcileRenameAndRejectDuplicates() async throws {
        let file = FileContents(name: "same.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.disableFileHeader = true
        let a = CodeViewItem(id: "a", document: document), b = CodeViewItem(id: "b", document: document)
        try view.setItems([a, b], options: options)
        let range = LineSelection(side: .additions, startLine: 50, endLine: 51)
        view.selectLines(range, inFileAt: 1)
        #expect(view.scrollToRange(range, inItem: "b"))
        try view.setItems([b, a])
        #expect(view.selectedItemLines?.id == "b" && view.selectedLines?.fileIndex == 0)
        #expect(view.scrollTop == 988)
        #expect(view.updateItemID("b", to: "renamed"))
        #expect(view.selectedItemLines?.id == "renamed")
        #expect(view.getItem("b") == nil)
        #expect(!view.updateItemID("renamed", to: "a"))
        do { try view.addItem(a); Issue.record("Duplicate item accepted") }
        catch CodeViewItemError.duplicateID(let id) { #expect(id == "a") }
        #expect(view.fileCount == 2 && view.selectedItemLines?.id == "renamed")
        #expect(try view.removeItem("renamed"))
        #expect(view.selectedItemLines == nil)
        #expect(!(try view.removeItem("missing")))
        try view.setItems([.init(id: "é", document: document), .init(id: "e\u{301}", document: document)])
        #expect(view.fileCount == 2)
        #expect(view.getItem("é")?.id.utf16.count == 1)
        #expect(view.getItem("e\u{301}")?.id.utf16.count == 2)
    }

    @Test @MainActor func reorderedReviewRetainsSelectionAndScrollBySourceIdentity() async throws {
        let file = FileContents(name: "same.txt", contents: String(repeating: "line\n", count: 100))
        let original = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let a = original.identifyingSource(as: UUID()), b = original.identifyingSource(as: UUID()), c = original.identifyingSource(as: UUID())
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render([a, b], options: options)
        view.selectLines(.init(side: .additions, startLine: 50, endLine: 51), inFileAt: 1)
        #expect(view.scrollToLine(50, inFileAt: 1))
        view.render([c, b, a], options: options)
        #expect(view.selectedLines?.fileIndex == 1)
        view.render([b, c, a], options: options)
        #expect(view.selectedLines?.fileIndex == 0)
        #expect(view.scrollTop == 988)
        view.render([c, a], options: options)
        #expect(view.selectedLines == nil)
    }

    @Test @MainActor func reviewSelectionMovesBetweenMountedAndUnmountedFiles() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render(Array(repeating: document, count: 100), options: options)
        let range = LineSelection(side: .additions, startLine: 2, endLine: 3)
        view.selectLines(range, inFileAt: 0)
        let first = try #require(view.scrollView.documentView?.subviews.compactMap { $0 as? NativeDiffView }.first)
        view.selectLines(range, inFileAt: 90)
        #expect(first.selectedLines == nil)
        #expect(view.selectedText(inFileAt: 0).isEmpty)
        #expect(view.selectedLines?.fileIndex == 90)
        view.scrollToFile(at: 90)
        let active = try #require(view.scrollView.documentView?.subviews.compactMap { $0 as? NativeDiffView }.first { $0.selectedLines != nil })
        #expect(active.selectedLines == range)
        view.clearSelectedLines(notify: false)
        #expect(view.selectedLines == nil && active.selectedLines == nil)
        active.selectLines(range)
        #expect(view.selectedLines?.fileIndex == 90)
        view.scrollToFile(at: 0)
        let destination = try #require(view.scrollView.documentView?.subviews.compactMap { $0 as? NativeDiffView }.first)
        destination.selectLines(range)
        #expect(view.selectedLines?.fileIndex == 0)
        #expect(view.selectedText(inFileAt: 90).isEmpty)
    }

    @Test @MainActor func scrollSubscriptionsObserveNavigationAndCancelIndependently() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        weak var weakView: NativeCodeView?
        var cancellations: [@MainActor () -> Void] = []
        autoreleasepool {
        var view: NativeCodeView? = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        weakView = view
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view!.render([document], options: options)
        var first: [CGFloat] = [], second: [CGFloat] = []
        let cancelFirst = view!.subscribeToScroll { top, sender in
            #expect(sender === weakView)
            first.append(top)
        }
        let cancelSecond = view!.subscribeToScroll { top, _ in second.append(top) }
        #expect(first.isEmpty && second.isEmpty)
        #expect(view!.scrollToLine(50, inFileAt: 0))
        #expect(first.last == 988 && second.last == 988)
        cancelFirst(); cancelFirst()
        let firstCount = first.count
        #expect(view!.scrollToLine(60, inFileAt: 0))
        #expect(first.count == firstCount)
        #expect(second.last == 1188)
        #expect(view!.scrollTop == 1188)
        cancelSecond()
        cancellations = [cancelFirst, cancelSecond]
        view = nil
        }
        #expect(weakView == nil)
        cancellations.forEach { $0() }
    }

    @Test @MainActor func reviewRangeNavigationUsesBothEndpoints() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render([document], options: options)
        for range in [LineSelection(side: .additions, startLine: 40, endLine: 50),
                      LineSelection(side: .deletions, startLine: 50, endLine: 40, endSide: .additions)] {
            #expect(view.scrollToRange(range, inFileAt: 0, align: .center))
            #expect(view.scrollView.contentView.bounds.minY == 748)
            #expect(view.scrollToRange(range, inFileAt: 0, align: .end))
            #expect(view.scrollView.contentView.bounds.minY == 708)
        }
        #expect(!view.scrollToRange(.init(side: .additions, startLine: 40, endLine: 101), inFileAt: 0))
        #expect(view.scrollView.contentView.bounds.minY == 708)
    }

    @Test @MainActor func pendingLineNavigationUsesLatestTargetAndWidth() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: String(repeating: "word ", count: 30) + "\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.overflow = .wrap; options.disableFileHeader = true
        view.render(Array(repeating: document, count: 100), options: options)
        #expect(view.isPreparingWrappedLayout)
        #expect(view.scrollToLine(10, inFileAt: 20))
        #expect(view.scrollToLine(50, inFileAt: 90))
        view.scrollToFile(at: -1)
        view.setFrameSize(.init(width: 1000, height: 300)); view.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparingWrappedLayout)
        let plan = try await DiffWrapLayout.shared.layout(plan: .init(diff: document.diff, options: options), diff: document.diff,
            width: view.scrollView.contentSize.width / 2 - 72,
            fontName: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName, fontSize: 13)
        let row = try #require(plan.rows.firstIndex { $0.newNumber == 50 })
        let expected = CGFloat(8 + 90 * (plan.rows.count * 20 + 8) + row * 20)
        #expect(view.scrollView.contentView.bounds.minY == expected)
        #expect(view.mountedFileCount <= 2)
    }

    @Test @MainActor func pendingRangeNavigationUsesBothEndpointsAfterWidthChange() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: String(repeating: "word ", count: 30) + "\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.overflow = .wrap; options.disableFileHeader = true
        view.render(Array(repeating: document, count: 100), options: options)
        #expect(view.isPreparingWrappedLayout)
        #expect(view.scrollToLine(10, inFileAt: 20))
        #expect(view.scrollToRange(.init(side: .deletions, startLine: 52, endLine: 50, endSide: .additions), inFileAt: 90, align: .end))
        #expect(!view.scrollToRange(.init(side: .additions, startLine: 50, endLine: 101), inFileAt: 90))
        view.scrollToFile(at: -1)
        view.setFrameSize(.init(width: 1000, height: 300)); view.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparingWrappedLayout)
        let plan = try await DiffWrapLayout.shared.layout(plan: .init(diff: document.diff, options: options), diff: document.diff,
            width: view.scrollView.contentSize.width / 2 - 72,
            fontName: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName, fontSize: 13)
        let row = try #require(plan.rows.lastIndex { $0.oldNumber == 52 })
        let expected = CGFloat(8 + 90 * (plan.rows.count * 20 + 8) + (row + 1) * 20 - 300)
        #expect(view.scrollView.contentView.bounds.minY == expected)
        #expect(view.mountedFileCount <= 2)
    }

    @Test @MainActor func reviewLineAlignmentMatchesUpstreamOffsets() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render([document], options: options)
        for (alignment, expected) in [(CodeViewScrollAlignment.start, CGFloat(978)), (.center, 858), (.end, 718)] {
            #expect(view.scrollToLine(50, inFileAt: 0, align: alignment, offset: 10))
            #expect(view.scrollView.contentView.bounds.minY == expected)
        }
        view.scrollToFile(at: 0)
        #expect(view.scrollToLine(50, inFileAt: 0, align: .nearest))
        #expect(view.scrollView.contentView.bounds.minY == 708)
        #expect(view.scrollToLine(50, inFileAt: 0, align: .nearest))
        #expect(view.scrollView.contentView.bounds.minY == 708)
        #expect(view.scrollToLine(1, inFileAt: 0, align: .nearest))
        #expect(view.scrollView.contentView.bounds.minY == 8)
    }

    @Test @MainActor func reviewNavigatesToLineWithoutMountingIntermediateFiles() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render(Array(repeating: document, count: 1000), options: options)
        #expect(view.scrollToLine(50, inFileAt: 900))
        let expected: CGFloat = 8 + 900 * 2008 + 49 * 20
        #expect(view.scrollView.contentView.bounds.minY == expected)
        #expect(view.mountedFileCount <= 2)
        #expect(!view.scrollToLine(101, inFileAt: 900))
        #expect(!view.scrollToLine(1, inFileAt: 1000))
        #expect(view.scrollView.contentView.bounds.minY == expected)
        view.headerRenderers = .init(renderCustomHeader: { _ in NSView(frame: .init(x: 0, y: 0, width: 600, height: 120)) })
        options.disableFileHeader = false
        view.render([document, document], options: options)
        #expect(view.scrollToLine(50, inFileAt: 0))
        #expect(view.scrollView.contentView.bounds.minY == 1108)
    }

    @Test @MainActor func reviewLayoutControlsPaddingGapAndExtent() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 20))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 100))
        var options = DiffRenderOptions(); options.disableFileHeader = true
        let documents = Array(repeating: document, count: 3)
        view.render(documents, options: options, layout: .init(paddingTop: 17, paddingBottom: 23, gap: 11))
        #expect(view.scrollView.documentView?.frame.height == CGFloat(1262))
        view.scrollToFile(at: 1)
        #expect(view.scrollView.contentView.bounds.minY == 428)
        view.render(documents, options: options, layout: .init(paddingTop: 5, paddingBottom: 7, gap: 3))
        #expect(view.scrollView.contentView.bounds.minY == 408)
        #expect(view.scrollView.documentView?.frame.height == CGFloat(1218))
    }

    @Test @MainActor func replacingReviewCancelsPendingWrapAndClearsNeighbors() async throws {
        let file = FileContents(name: "long.swift", contents: String(repeating: "let value = 123; ", count: 60) + "\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.overscrollSize = 600
        var options = DiffRenderOptions(); options.overflow = .wrap
        view.render(Array(repeating: document, count: 1000), options: options)
        #expect(view.isPreparingWrappedLayout)
        view.scrollToFile(at: 500)
        #expect(view.mountedFileCount > 0)
        #expect(view.scrollToLine(1, inFileAt: 900))
        view.render([], options: options)
        #expect(view.fileCount == 0)
        #expect(view.mountedFileCount == 0)
        #expect(!view.isPreparingWrappedLayout)
        #expect(view.scrollView.contentView.bounds.origin == .zero)
        let replacementFile = FileContents(name: "replacement.txt", contents: "replacement\n")
        let replacement = try await DiffHighlighter().prepare(oldFile: replacementFile, newFile: replacementFile)
        view.render([replacement], options: options)
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.isPreparingWrappedLayout)
        #expect(view.fileCount == 1)
        #expect(view.mountedFileCount == 1)
        #expect(view.scrollView.documentView?.frame.height == view.scrollView.contentSize.height)
        #expect(view.scrollView.contentView.bounds.origin == .zero)
    }

    @Test @MainActor func reviewOverscrollMountsBoundedNeighborsAndReleasesThem() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.render(Array(repeating: document, count: 1000))
        view.scrollToFile(at: 500)
        let originalPosition = view.scrollView.contentView.bounds.origin
        let originalCount = view.mountedFileCount
        view.overscrollSize = 600
        #expect(view.mountedFileCount > originalCount)
        #expect(view.mountedFileCount < 25)
        #expect(view.scrollView.contentView.bounds.origin == originalPosition)
        view.scrollToFile(at: 900)
        #expect(view.mountedFileCount < 25)
        view.overscrollSize = 0
        #expect(view.mountedFileCount == originalCount)
        let destination = view.scrollView.contentView.bounds.origin
        view.overscrollSize = .infinity
        #expect(view.mountedFileCount == originalCount)
        #expect(view.scrollView.contentView.bounds.origin == destination)
    }

    @Test func upstreamWindowBoundaries() {
        #expect(createWindowFromScrollPosition(scrollTop: 0, height: 100, scrollHeight: 1000, overscrollSize: 50) == .init(top: 0, bottom: 150))
        #expect(createWindowFromScrollPosition(scrollTop: 100.25, height: 100, scrollHeight: 1000, overscrollSize: 50) == .init(top: 50, bottom: 251))
        #expect(createWindowFromScrollPosition(scrollTop: 900, height: 100, scrollHeight: 1000, overscrollSize: 50) == .init(top: 850, bottom: 1000))
        #expect(createWindowFromScrollPosition(scrollTop: -40, height: 100, scrollHeight: 1000, overscrollSize: 50) == .init(top: 0, bottom: 110))
        #expect(createWindowFromScrollPosition(scrollTop: 1100, height: 100, scrollHeight: 1000, overscrollSize: 50) == .init(top: 1050, bottom: 1050))
        #expect(createWindowFromScrollPosition(scrollTop: 0, height: 100, scrollHeight: 20, overscrollSize: 50) == .init(top: 0, bottom: 200))
        #expect(createWindowFromScrollPosition(scrollTop: 100.25, height: 100, scrollHeight: 1000, fitPerfectly: true, fitPerfectlyOverscroll: 20, overscrollSize: 50) == .init(top: 80.25, bottom: 240.25))
    }
    @Test func optionalEqualityIncludesEveryCoordinate() {
        #expect(areVirtualWindowSpecsEqual(nil, nil))
        #expect(!areVirtualWindowSpecsEqual(nil, .init(top: 0, bottom: 0)))
        #expect(!areVirtualWindowSpecsEqual(.init(top: 0, bottom: 1), .init(top: 1, bottom: 1)))
        #expect(!areVirtualWindowSpecsEqual(.init(top: 0, bottom: 1), .init(top: 0, bottom: 2)))
        let a = DiffRenderRange(startingLine: 1, totalLines: 10, bufferBefore: 2, bufferAfter: 3)
        #expect(areRenderRangesEqual(a, a))
        #expect(areRenderRangesEqual(nil, nil))
        #expect(!areRenderRangesEqual(a, nil))
        for path in [\DiffRenderRange.startingLine, \.totalLines, \.bufferBefore, \.bufferAfter] {
            var b = a; b[keyPath: path] += 1
            #expect(!areRenderRangesEqual(a, b))
        }
    }
}

@MainActor private final class CompletionFinalizationBarrier {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation; entered = true
            entryWaiter?.resume(); entryWaiter = nil
        }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@Suite(.serialized) struct VirtualLifecycleTests {
    private func makeItems() async throws -> [CodeViewItem] {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        return (0..<30).map { .init(id: "item\($0)", document: document) }
    }
    @Test @MainActor func retiredSnapshotUnmountsAndReleasesPresentation() async throws {
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems(try await makeItems(), options: options)
        let first = try #require(view.getRenderedItems().first)
        var unmounts = 0
        first.instance.onPostRender = { instance, phase in
            if phase == .unmount { unmounts += 1; #expect(instance.displayedDocument != nil) }
        }
        view.scrollToFile(at: 29)
        #expect(unmounts == 1)
        #expect(first.instance.displayedDocument == nil)
        #expect(first.instance.rowCount == 0)
        view.scrollToFile(at: 0)
        let remounted = try #require(view.getRenderedItems().first { $0.id == first.id })
        #expect(remounted.instance !== first.instance)
        view.reset()
        #expect(unmounts == 1)
    }
    @Test @MainActor func unmountMayResetOrReplaceReview() async throws {
        let items = try await makeItems()
        for replace in [false, true] {
            let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
            var options = DiffRenderOptions(); options.expandUnchanged = true
            try view.setItems(items, options: options)
            let first = try #require(view.getRenderedItems().first)
            first.instance.onPostRender = { _, phase in
                if phase == .unmount {
                    if replace { try! view.setItems([.init(id: "replacement", document: items[0].document)]) }
                    else { view.reset() }
                }
            }
            view.scrollToFile(at: 29)
            view.layoutSubtreeIfNeeded()
            #expect(view.fileCount == (replace ? 1 : 0))
            #expect((view.getItem("replacement") != nil) == replace)
            #expect(view.getRenderedItems().allSatisfy { $0.id == "replacement" })
            view.reset()
        }
    }
    @Test @MainActor func unmountDuringResetCanReplaceReview() async throws {
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        let items = try await makeItems()
        try view.setItems(items)
        let first = try #require(view.getRenderedItems().first)
        first.instance.onPostRender = { _, phase in
            if phase == .unmount { try! view.setItems([.init(id: "replacement", document: items[0].document)]) }
        }
        view.reset()
        view.layoutSubtreeIfNeeded()
        #expect(view.fileCount == 1)
        #expect(view.getItem("replacement") != nil)
        #expect(view.getRenderedItems().map(\.id) == ["replacement"])
        view.reset()
    }
    @Test @MainActor func replacementDuringReconciliationKeepsReusedEditorAttached() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let keep = CodeViewItem(id: "keep", document: document)
        let drop = CodeViewItem(id: "drop", document: document)
        let outer = CodeViewItem(id: "outer", document: document)
        let replacement = CodeViewItem(id: "replacement", document: document)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 700))
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems([keep, drop], options: options)
        let editor = try view.beginEditingItem("keep")
        let retained = try #require(view.getRenderedItems().first { $0.id == "keep" })
        let retiring = try #require(view.getRenderedItems().first { $0.id == "drop" })
        var errors = 0
        editor.onError = { _ in errors += 1 }
        editor.select(.init(location: 0, length: 0))
        editor.insertText("prefix ", replacementRange: .init(location: NSNotFound, length: 0))
        retiring.instance.onPostRender = { _, phase in
            if phase == .unmount { try! view.setItems([keep, replacement]) }
        }
        try view.setItems([keep, outer])
        view.layoutSubtreeIfNeeded()
        #expect(view.getItem("replacement") != nil && view.getItem("outer") == nil)
        let current = try #require(view.getRenderedItems().first { $0.id == "keep" })
        #expect(current.instance === retained.instance)
        #expect(current.instance.attachedEditor === editor)
        #expect(editor.isActive && !editor.isSuspended)
        #expect(errors == 0)
        #expect(editor.document.getText() == "prefix one\ntwo\n")
        editor.undo(nil)
        #expect(editor.document.getText() == "one\ntwo\n")
        view.reset()
    }
    @Test @MainActor func editorTextAndUndoSurviveVirtualCleanup() async throws {
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        let items = try await makeItems()
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems(items, options: options)
        let editor = try view.beginEditingItem("item0")
        editor.select(.init(location: 0, length: 0))
        editor.insertText("prefix ", replacementRange: .init(location: NSNotFound, length: 0))
        let first = try #require(view.getRenderedItems().first { $0.id == "item0" })
        var sawActiveEditorAtUnmount = false
        first.instance.onPostRender = { instance, phase in
            if phase == .unmount { sawActiveEditorAtUnmount = instance.attachedEditor === editor && !editor.isSuspended }
        }
        view.scrollToFile(at: 29)
        #expect(sawActiveEditorAtUnmount)
        #expect(editor.isSuspended)
        view.scrollToFile(at: 0)
        #expect(editor.isActive && !editor.isSuspended)
        #expect(editor.document.getText().hasPrefix("prefix line"))
        editor.undo(nil)
        #expect(editor.document.getText() == String(repeating: "line\n", count: 100))
        view.reset()
    }
}

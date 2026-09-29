import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct AttachedEditorTests {
    @Test @MainActor func fileEditorAcceptsExplicitSideLessAnnotationReplacement() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let note = FileLineAnnotation(id: "note", lineNumber: 2, text: "original", metadata: .init("payload"))
        let host = NativeFileView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        host.render(prepared, file: file, fileAnnotations: [note])
        let editor = try host.diffView.beginEditing()
        editor.select(.init(location: 0, length: 0))
        editor.insertText("zero\n", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.currentFileAnnotations?.first?.lineNumber == 3)
        try editor.setFileAnnotations([note])
        #expect(editor.currentFileAnnotations == [note])
        try editor.setFileAnnotations([])
        #expect(editor.currentFileAnnotations == [])
        try editor.setFileAnnotations([note])
        let result = try await editor.complete(.discard)
        #expect(result.fileAnnotations == [note])
        #expect(result.fileAnnotations?.first?.metadata === note.metadata)
        let diffView = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        diffView.render(prepared, annotations: [note.renderedAnnotation])
        let diffEditor = try diffView.beginEditing()
        #expect(throws: DiffEditorError.self) { try diffEditor.setFileAnnotations([]) }
        #expect(diffEditor.currentAnnotations == [note.renderedAnnotation])
        #expect(diffEditor.currentFileAnnotations == nil)
        _ = try await diffEditor.complete(.discard)
    }
    @Test(arguments: ["install", "discard", "remove"]) @MainActor
    func fileAnnotationShapeSurvivesEditorCompletion(_ mode: String) async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let metadata = LineAnnotationMetadata(["thread": "review"])
        let note = FileLineAnnotation(id: "note", lineNumber: 2, text: "Keep this", metadata: metadata)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        try view.setItems([.init(id: "file", document: prepared, file: file, fileAnnotations: [note])])
        let editor = try view.beginEditingItem("file")
        #expect(editor.currentFileAnnotations == [note])
        editor.select(.init(location: 0, length: 0))
        editor.insertText("zero\n", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.currentFileAnnotations?.first?.lineNumber == 3)
        var event: DiffEditCompletion?
        editor.onEditComplete = { event = $0; return true }
        if mode == "remove" {
            #expect(try view.removeItem("file"))
            await editor.waitForTeardown()
        } else { _ = try await view.completeEditingItem("file", mode: mode == "install" ? .install : .discard) }
        let result = try #require(event)
        #expect(result.isFile)
        #expect(result.originalFileAnnotations == [note])
        let edited = try #require(result.fileAnnotations?.first)
        #expect(edited.id == note.id && edited.text == note.text && edited.lineNumber == 3)
        #expect(edited.metadata === metadata)
        if mode == "install" { #expect(view.getItem("file")?.fileAnnotations == result.fileAnnotations) }
        if mode == "discard" { #expect(view.getItem("file")?.fileAnnotations == [note]) }
    }
    @Test(arguments: [false, true]) @MainActor func discardedOrRejectedCompletionDoesNotInitializeSyntaxEngine(reject: Bool) async throws {
        let file = FileContents(name: "f.swift", contents: "let value = 1\n")
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.render(prepared)
        let highlighter = DiffHighlighter()
        let editor = try view.beginEditing(highlighter: highlighter)
        editor.suspend() // Cancel presentation before yielding the main actor.
        editor.select(.init(location: 12, length: 1))
        editor.insertText("2", replacementRange: .init(location: NSNotFound, length: 0))
        var completed = false
        editor.onEditComplete = { event in
            completed = true
            #expect(!event.isFile && event.fileAnnotations == nil && event.originalFileAnnotations == nil)
            #expect(event.newFile?.contents == "let value = 2\n")
            return !reject
        }
        _ = try await editor.complete(reject ? .install : .discard)
        #expect(completed)
        #expect(await highlighter.isHighlighterLoaded == false)
        #expect(editor.installedCompletionDocument == nil)
    }

    @Test @MainActor func compositionSurvivesSuspensionAsOneUndoUnit() async throws {
        let prepared = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "hello\r\n"), newFile: .init(name: "f.txt", contents: "hello\r\n"))
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); view.render(prepared)
        let editor = try view.beginEditing()
        editor.select(.init(location: 5, length: 0))
        let unspecified = NSRange(location: NSNotFound, length: 0)
        editor.setMarkedText("ni", selectedRange: .init(location: 2, length: 0), replacementRange: unspecified)
        editor.setMarkedText("你好", selectedRange: .init(location: 2, length: 0), replacementRange: unspecified)
        editor.suspend()
        #expect(!editor.hasMarkedText())
        #expect(editor.document.getText() == "hello你好\r\n")
        let next = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 300)); next.render(prepared)
        try next.resumeEditing(editor); await editor.waitForRendering()
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
        editor.undo(nil)
        #expect(editor.document.getText() == "hello\r\n")
        editor.redo(nil)
        #expect(editor.document.getText() == "hello你好\r\n")
        editor.abandon()
    }
    @Test @MainActor func canceledCompositionDoesNotReappearOnResume() async throws {
        let (window, view, editor) = try await makeView("hello\n", "hello\n")
        defer { window.close() }
        let prepared = try #require(view.displayedDocument)
        editor.select(.init(location: 5, length: 0))
        editor.setMarkedText("你", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        editor.doCommand(by: NSSelectorFromString("cancelOperation:"))
        editor.suspend()
        let next = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 300)); next.render(prepared)
        try next.resumeEditing(editor); await editor.waitForRendering()
        #expect(editor.document.getText() == "hello\n")
        #expect(!editor.hasMarkedText())
        #expect(!editor.undoManager.canUndo)
        editor.abandon()
    }

    @Test @MainActor func suspendedSessionRetainsEditsUndoAndRejectsWrongSource() async throws {
        let prepared = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "one\n"), newFile: .init(name: "f.txt", contents: "one\n"))
        let first = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        first.render(prepared)
        let editor = try first.beginEditing()
        editor.select(.init(location: 0, length: 3)); editor.insertText("two", replacementRange: .init(location: NSNotFound, length: 0))
        editor.suspend()
        #expect(editor.isSuspended && first.attachedEditor == nil)
        editor.select(.init(location: 3, length: 0)); editor.insertText("!", replacementRange: .init(location: NSNotFound, length: 0))
        editor.undoManager.undo()
        #expect(editor.document.getText() == "two\n")
        let next = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 300))
        next.render(prepared.identifyingSource(as: UUID()))
        do { try next.resumeEditing(editor); Issue.record("Wrong source accepted") }
        catch DiffEditorError.incompatibleSource { }
        #expect(editor.isSuspended && next.attachedEditor == nil)
        next.render(prepared)
        try next.resumeEditing(editor)
        await editor.waitForRendering()
        #expect(!editor.isSuspended && next.attachedEditor === editor)
        #expect(next.displayedDocument?.diff.additionLines.joined() == "two\n")
        editor.undoManager.undo()
        #expect(editor.document.getText() == "one\n")
        editor.abandon()
    }

    @Test @MainActor func crossSideRangeDoesNotBecomeAnEditableNewSideRange() async throws {
        let (window, view, editor) = try await makeView("old\nsecond\n", "new\nsecond\n")
        defer { window.close() }
        view.selectLines(.init(side: .additions, startLine: 1, endLine: 2, endSide: .deletions), notify: false)
        #expect(!editor.hasEditableSelection)
        view.selectLines(.init(side: .additions, startLine: 1, endLine: 2), notify: false)
        #expect(editor.hasEditableSelection)
    }
    @MainActor private func makeView(_ old: String, _ new: String, style: DiffStyle = .split) async throws -> (NSWindow, NativeDiffView, DiffEditor) {
        let highlighter = DiffHighlighter()
        let prepared = try await highlighter.prepare(oldFile: .init(name: "f.txt", contents: old), newFile: .init(name: "f.txt", contents: new))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 900, height: 500)); window.contentView = view
        var options = DiffRenderOptions(); options.diffStyle = style
        view.render(prepared, options: options)
        let editor = try view.beginEditing(highlighter: highlighter)
        await editor.waitForRendering()
        return (window, view, editor)
    }
    @Test @MainActor func wrappedActiveBorderDoesNotBoxEachFragment() async throws {
        let text = String(repeating: "word ", count: 80) + "\n"
        let (window, view, editor) = try await makeView(text, text, style: .unified)
        defer { window.close() }
        let source = try #require(view.displayedDocument)
        var palette = source.palette; palette.editorLineHighlightBorder = "#ff0000"
        let document = HighlightedDiff(diff: source.diff, oldTokens: source.oldTokens, newTokens: source.newTokens, foreground: source.foreground, background: source.background, palette: palette)
        var options = DiffRenderOptions(); options.diffStyle = .unified; options.overflow = .wrap
        view.renderEditor(document, options: options, annotations: [], expansions: [:])
        let plan = try await DiffWrapLayout.shared.layout(plan: DiffRenderPlan(diff: source.diff, options: options), diff: source.diff, width: 200, fontName: options.fontName ?? "Menlo", fontSize: options.fontSize)
        #expect(plan.rows.count > 3)
        view.installRenderPlan(plan)
        editor.select(.init(location: 0, length: 0))
        let canvas = try #require(view.scrollView.documentView)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        canvas.draw(.init(x: 0, y: 0, width: 900, height: 500))
        func isRed(_ y: Int) throws -> Bool {
            let color = try #require(bitmap.colorAt(x: 400, y: 499 - y)?.usingColorSpace(.deviceRGB))
            return color.redComponent > 0.9 && color.greenComponent < 0.1 && color.blueComponent < 0.1
        }
        #expect(try isRed(0))
        #expect(try !isRed(19))
        #expect(try !isRed(20))
    }
    @Test @MainActor func terminalCaretUsesActiveLineTreatment() async throws {
        let (window, view, editor) = try await makeView("abc\n", "abc\n", style: .unified)
        defer { window.close() }
        let canvas = try #require(view.scrollView.documentView)
        func band() throws -> [NSColor] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            canvas.draw(.init(x: 0, y: 0, width: 900, height: 500))
            return try (460..<480).map { try #require(bitmap.colorAt(x: 180, y: $0)) }
        }
        editor.select(.init(location: 0, length: 0))
        let inactive = try band()
        editor.select(.init(location: 4, length: 0))
        #expect(view.selectedTextRange?.head.line == 1)
        let active = try band()
        #expect(active != inactive)
        editor.select(.init(location: 0, length: 4))
        #expect(try band() == inactive)
    }
    @Test @MainActor func inputUndoRedoAndAcceptedCompletion() async throws {
        let (window, view, editor) = try await makeView("one\ntwo\n", "one\nchanged\n")
        defer { window.close() }
        #expect(throws: DiffEditorError.self) { try view.beginEditing() }
        editor.select(.init(location: 4, length: 7))
        editor.insertText("two", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.document.getText() == "one\ntwo\n")
        await editor.waitForRendering()
        #expect(view.displayedDocument?.diff.hunks.isEmpty == false)
        #expect(view.displayedDocument?.diff.hunks.allSatisfy { $0.additionLines == 0 && $0.deletionLines == 0 } == true)
        #expect(view.selectedTextRange?.head == .init(line: 1, character: 3))
        editor.undo(nil); #expect(editor.document.getText() == "one\nchanged\n")
        editor.redo(nil); #expect(editor.document.getText() == "one\ntwo\n")
        editor.onEditComplete = { event in
            #expect(event.originalFileDiff.additionLines.joined() == "one\nchanged\n")
            #expect(event.newFile?.contents == "one\ntwo\n")
            return true
        }
        let event = try await editor.complete()
        #expect(event.fileDiff.hunks.isEmpty)
        #expect(view.displayedDocument?.diff == event.fileDiff)
        #expect(!editor.isActive)
        #expect(view.attachedEditor == nil)
    }
    @Test @MainActor func markedTextIsOneUndoUnitAndHasScreenCoordinates() async throws {
        let (window, view, editor) = try await makeView("hello\n", "hello\n", style: .unified)
        defer { window.close() }
        editor.select(.init(location: 5, length: 0))
        let unspecified = NSRange(location: NSNotFound, length: 0)
        editor.setMarkedText("n", selectedRange: .init(location: 1, length: 0), replacementRange: unspecified)
        editor.setMarkedText("ni", selectedRange: .init(location: 2, length: 0), replacementRange: unspecified)
        #expect(editor.hasMarkedText())
        #expect(editor.markedRange() == .init(location: 5, length: 2))
        editor.insertText("你", replacementRange: unspecified)
        #expect(!editor.hasMarkedText()); #expect(editor.document.getText() == "hello你\n")
        await editor.waitForRendering()
        var actual = NSRange(location: NSNotFound, length: 0)
        let rect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: &actual)
        #expect(rect.height == 20); #expect(rect.width == 1)
        #expect(actual.location == 6)
        #expect(editor.characterIndex(for: .init(x: rect.minX, y: rect.midY)) == 6)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: "/tmp/swift-diffs-editor.png")) }
        editor.undo(nil); #expect(editor.document.getText() == "hello\n")
        editor.redo(nil); #expect(editor.document.getText() == "hello你\n")
        editor.setMarkedText("cancel", selectedRange: .init(location: 6, length: 0), replacementRange: unspecified)
        editor.doCommand(by: NSSelectorFromString("cancelOperation:"))
        #expect(editor.document.getText() == "hello你\n")
        editor.undo(nil); #expect(editor.document.getText() == "hello\n")
        editor.setMarkedText("provisional", selectedRange: .init(location: 11, length: 0), replacementRange: unspecified)
        editor.doCommand(by: NSSelectorFromString("cancelOperation:"))
        editor.redo(nil); #expect(editor.document.getText() == "hello你\n")
        _ = try await editor.complete(.discard)
        #expect(view.displayedDocument?.diff.additionLines.joined() == "hello\n")
    }
    @Test @MainActor func graphemeDeletionNewlineAndEmptyCaretRow() async throws {
        let (window, view, editor) = try await makeView("original\r\n", "a👩🏽‍💻b\r\n", style: .unified)
        defer { window.close() }
        let end = ("a👩🏽‍💻" as NSString).length
        editor.select(.init(location: end, length: 0))
        editor.doCommand(by: NSSelectorFromString("deleteBackward:"))
        #expect(editor.document.getText() == "ab\r\n")
        editor.doCommand(by: NSSelectorFromString("insertNewline:"))
        #expect(editor.document.getText() == "a\r\nb\r\n")
        editor.selectAll(nil); editor.insertText("", replacementRange: .init(location: NSNotFound, length: 0))
        await editor.waitForRendering()
        #expect(view.displayedDocument?.diff.additionLines == [""])
        #expect(editor.firstRect(forCharacterRange: .init(location: 0, length: 0), actualRange: nil).height == 20)
        editor.insertText("restored", replacementRange: .init(location: NSNotFound, length: 0))
        await editor.waitForRendering()
        #expect(view.displayedDocument?.diff.additionLines.joined() == "restored")
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func pendingExternalReplacementAndReadOnlyOldSide() async throws {
        let (window, view, editor) = try await makeView("old\n", "new\n")
        defer { window.close() }
        view.selectText(.init(side: .deletions, anchor: .init(line: 0, character: 0), head: .init(line: 0, character: 3)))
        #expect(!editor.hasEditableSelection)
        editor.insertText("blocked", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.document.getText() == "new\n")
        editor.select(.init(location: 0, length: 3)); editor.insertText("edited", replacementRange: .init(location: NSNotFound, length: 0))
        let replacement = try await DiffHighlighter().prepare(oldFile: .init(name: "other.txt", contents: "external old\n"), newFile: .init(name: "other.txt", contents: "external new\n"))
        view.render(replacement)
        await editor.waitForRendering()
        #expect(view.displayedDocument?.diff.deletionLines.joined() == "external old\n")
        #expect(editor.document.getText() == "external new\n")
        #expect(!editor.undoManager.canUndo)
        var called = false
        editor.onEditComplete = { event in called = true; #expect(event.originalFileDiff == replacement.diff); return true }
        _ = try await editor.complete(.discard)
        #expect(called); #expect(view.displayedDocument?.diff == replacement.diff)
    }
    @Test @MainActor func externalReplacementIsUndoableAndChangesTheDiffBaseline() async throws {
        let (window, view, editor) = try await makeView("old\n", "one\n")
        defer { window.close() }
        editor.select(.init(location: 0, length: 3)); editor.insertText("draft", replacementRange: .init(location: NSNotFound, length: 0))
        let replacement = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "new baseline\n"), newFile: .init(name: "f.txt", contents: "host update\n"))
        let note = LineAnnotation(id: "host", side: .additions, lineNumber: 1, text: "host comment")
        var notifications = 0
        editor.onChange = { _ in notifications += 1 }
        view.render(replacement, annotations: [note])
        #expect(notifications == 1 && editor.document.getText() == "host update\n")
        #expect(editor.currentAnnotations == [note])
        await editor.waitForRendering()
        #expect(view.displayedDocument?.diff.deletionLines == ["new baseline\n"])
        editor.undo(nil)
        #expect(editor.document.getText() == "draft\n" && editor.currentAnnotations.isEmpty)
        editor.undo(nil)
        #expect(editor.document.getText() == "one\n")
        editor.redo(nil); editor.redo(nil)
        #expect(editor.document.getText() == "host update\n" && editor.currentAnnotations == [note])
        // Reinstalling the same external revision is not another replacement.
        let before = notifications
        view.render(replacement, annotations: [note]); #expect(notifications == before)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func keyEventAndTrailingCaretInWrappedView() async throws {
        let (window, view, editor) = try await makeView("hello\n", "hello\n")
        defer { window.close() }
        editor.select(.init(location: 6, length: 0))
        var options = DiffRenderOptions(); options.overflow = .wrap
        view.render(try #require(view.displayedDocument), options: options)
        await editor.waitForRendering()
        let rect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        #expect(rect.height == 20)
        #expect(editor.characterIndex(for: .init(x: rect.minX, y: rect.midY)) == 6)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        view.scrollView.documentView!.keyDown(with: key)
        #expect(editor.document.getText() == "hello\nx")
        await editor.waitForRendering()
        #expect(view.displayedDocument?.diff.additionLines.joined() == "hello\nx")
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func keyboardMovementSkipsCollapsedContext() async throws {
        let lines = (0..<80).map { "line \($0)\n" }; var changed = lines
        changed[10] = "changed\n"; changed[50] = "changed\n"
        let (window, view, editor) = try await makeView(lines.joined(), changed.joined())
        defer { window.close() }
        let offset = editor.document.offsetAt(.init(line: 46, character: 0))
        editor.select(.init(location: offset, length: 0))
        let expansions = view.editorExpansions
        editor.doCommand(by: NSSelectorFromString("moveUp:"))
        #expect(view.selectedTextRange?.head == .init(line: 14, character: 0))
        #expect(view.editorExpansions == expansions)
        editor.doCommand(by: NSSelectorFromString("moveDownAndModifySelection:"))
        #expect(view.selectedTextRange?.anchor == .init(line: 14, character: 0))
        #expect(view.selectedTextRange?.head == .init(line: 46, character: 0))
        #expect(view.editorExpansions == expansions)
        editor.select(.init(location: offset, length: 0))
        editor.doCommand(by: NSSelectorFromString("moveLeft:"))
        #expect(view.selectedTextRange?.head == .init(line: 14, character: 7))
        #expect(view.editorExpansions == expansions)
        #expect(editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil).height == 20)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func goalColumnAndWordDeletion() async throws {
        let (window, view, editor) = try await makeView("", "abcdefghij\nx\nabcdefghij\nword  ")
        defer { window.close() }
        editor.select(.init(location: 8, length: 0))
        editor.doCommand(by: NSSelectorFromString("moveDown:"))
        #expect(view.selectedTextRange?.head == .init(line: 1, character: 1))
        editor.doCommand(by: NSSelectorFromString("moveDown:"))
        #expect(view.selectedTextRange?.head == .init(line: 2, character: 8))
        editor.doCommand(by: NSSelectorFromString("moveToEndOfDocument:"))
        editor.doCommand(by: NSSelectorFromString("deleteWordBackward:"))
        #expect(editor.document.getLineText(3) == "word")
        editor.doCommand(by: NSSelectorFromString("deleteWordBackward:"))
        #expect(editor.document.getLineText(3) == "")
        editor.select(.init(location: 3, length: 0))
        editor.doCommand(by: NSSelectorFromString("deleteToEndOfParagraph:"))
        #expect(editor.document.getLineText(0) == "abc")
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func indentationNewlinesAndSoftTabUndo() async throws {
        let (window, _, editor) = try await makeView("", "  alpha\n\nbeta")
        defer { window.close() }
        editor.selectAll(nil)
        editor.doCommand(by: NSSelectorFromString("insertTab:"))
        #expect(editor.document.getText() == "    alpha\n\n  beta")
        editor.undo(nil)
        #expect(editor.document.getText() == "  alpha\n\nbeta")
        editor.redo(nil)
        editor.doCommand(by: NSSelectorFromString("insertBacktab:"))
        #expect(editor.document.getText() == "  alpha\n\nbeta")
        editor.select(.init(location: 7, length: 0))
        editor.doCommand(by: NSSelectorFromString("insertNewline:"))
        #expect(editor.document.getText() == "  alpha\n  \n\nbeta")
        editor.doCommand(by: NSSelectorFromString("deleteBackward:"))
        #expect(editor.document.getText() == "  alpha\n\n\nbeta")
        editor.undo(nil)
        #expect(editor.document.getText() == "  alpha\n  \n\nbeta")
        editor.undo(nil)
        #expect(editor.document.getText() == "  alpha\n\nbeta")
        editor.select(.init(location: 4, length: 0))
        editor.doCommand(by: NSSelectorFromString("deleteToBeginningOfLine:"))
        #expect(editor.document.getText() == "pha\n\nbeta")
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func keyboardMovementUsesWrappedRows() async throws {
        let source = String(repeating: "abcdefghij ", count: 30) + "\nnext"
        let (window, view, editor) = try await makeView("", source, style: .unified)
        defer { window.close() }
        var options = DiffRenderOptions(); options.diffStyle = .unified; options.overflow = .wrap
        view.render(try #require(view.displayedDocument), options: options)
        await editor.waitForRendering()
        for _ in 0..<200 {
            if (view.editorCursorLayout.softLineOffsets?[0]?.count ?? 0) > 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let offsets = try #require(view.editorCursorLayout.softLineOffsets?[0])
        #expect(offsets.count > 2)
        editor.select(.init(location: 2, length: 0))
        editor.doCommand(by: NSSelectorFromString("moveDown:"))
        #expect(view.selectedTextRange?.head == .init(line: 0, character: offsets[1] + 2))
        editor.doCommand(by: NSSelectorFromString("moveUpAndModifySelection:"))
        #expect(view.selectedTextRange?.anchor == .init(line: 0, character: offsets[1] + 2))
        #expect(view.selectedTextRange?.head == .init(line: 0, character: 2))
        editor.doCommand(by: NSSelectorFromString("moveToEndOfLine:"))
        #expect(view.selectedTextRange?.head == .init(line: 0, character: offsets[1]))
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func lineCommandsAndCommentUndo() async throws {
        let (window, view, editor) = try await makeView("", "aa\n  bb\ncc")
        defer { window.close() }
        editor.select(.init(location: 5, length: 0))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126))
        view.scrollView.documentView!.keyDown(with: key)
        #expect(editor.document.getText() == "  bb\naa\ncc")
        #expect(view.selectedTextRange?.head == .init(line: 0, character: 2))
        editor.undo(nil); #expect(editor.document.getText() == "aa\n  bb\ncc")
        editor.redo(nil); #expect(editor.document.getText() == "  bb\naa\ncc")
        editor.performLineCommand(.copyDown)
        #expect(editor.document.getText() == "  bb\n  bb\naa\ncc")
        #expect(view.selectedTextRange?.head == .init(line: 1, character: 2))
        editor.undo(nil)
        editor.performLineCommand(.insertBlankLine)
        #expect(editor.document.getText() == "  bb\n  \naa\ncc")
        #expect(view.selectedTextRange?.head == .init(line: 1, character: 2))
        editor.undo(nil)
        editor.toggleComment()
        #expect(editor.document.getText() == "  // bb\naa\ncc")
        #expect(view.selectedTextRange?.head == .init(line: 0, character: 5))
        editor.toggleComment()
        #expect(editor.document.getText() == "  bb\naa\ncc")
        editor.select(.init(location: 2, length: 2))
        editor.toggleComment(block: true)
        #expect(editor.document.getText() == "  /* bb */\naa\ncc")
        #expect(editor.selectedText == "bb")
        editor.undo(nil); #expect(editor.document.getText() == "  bb\naa\ncc")
        #expect(editor.selectedText == "bb")
        editor.redo(nil); #expect(editor.selectedText == "bb")
        editor.toggleComment(block: true)
        #expect(editor.document.getText() == "  bb\naa\ncc")
        #expect(editor.selectedText == "bb")
        editor.doCommand(by: NSSelectorFromString("cancelOperation:"))
        #expect(editor.selectedRange().length == 0)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func historyPreservesBackwardSelectionAndCompositionCancellation() async throws {
        let (window, view, editor) = try await makeView("", "alpha beta")
        defer { window.close() }
        let backward = DiffTextSelection(side: .additions, anchor: .init(line: 0, character: 10), head: .init(line: 0, character: 6))
        view.selectText(backward)
        editor.toggleComment(block: true)
        #expect(editor.selectedText == "beta")
        let commented = view.selectedTextRange
        #expect(commented?.anchor.character ?? 0 > commented?.head.character ?? 0)
        editor.undo(nil)
        #expect(view.selectedTextRange == backward)
        editor.redo(nil)
        #expect(view.selectedTextRange == commented)
        editor.undo(nil)
        editor.setMarkedText("candidate", selectedRange: .init(location: 9, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        editor.doCommand(by: NSSelectorFromString("cancelOperation:"))
        #expect(editor.document.getText() == "alpha beta")
        #expect(view.selectedTextRange == backward)
        editor.redo(nil)
        #expect(view.selectedTextRange == commented)
        editor.undo(nil)
        editor.insertText("replacement", replacementRange: .init(location: NSNotFound, length: 0))
        editor.undo(nil)
        #expect(view.selectedTextRange == backward)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func clipboardLineCutsAndDeletedText() async throws {
        let (window, view, editor) = try await makeView("old\n", "first\r\nlast")
        defer { window.close() }
        let pasteboard = NSPasteboard(name: .init("ShikiDiffsTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        editor.select(.init(location: editor.document.utf16Length, length: 0))
        editor.copySelection(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "last")
        #expect(editor.selectedText.isEmpty)
        editor.cutSelection(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "last")
        #expect(editor.document.getText() == "first")
        editor.undo(nil)
        #expect(editor.document.getText() == "first\r\nlast")
        editor.select(.init(location: 2, length: 0))
        editor.cutSelection(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "first\r\n")
        #expect(editor.document.getText() == "last")
        editor.undo(nil)
        view.selectText(.init(side: .deletions, anchor: .init(line: 0, character: 0), head: .init(line: 0, character: 3)))
        editor.cutSelection(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "old")
        #expect(editor.document.getText() == "first\r\nlast")
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func asynchronousReplacementIsOneUndoBatch() async throws {
        let (window, view, editor) = try await makeView("", "one 1\r\none 2\r\n")
        defer { window.close() }
        editor.select(.init(location: editor.document.utf16Length, length: 0))
        let count = try await editor.replaceAll(.init(text: "one ([0-9])", replaceText: "$1\nnext", regex: true))
        #expect(count == 2)
        #expect(editor.document.getText() == "1\r\nnext\r\n2\r\nnext\r\n")
        #expect(editor.selectedRange().location == editor.document.utf16Length)
        editor.undo(nil)
        #expect(editor.document.getText() == "one 1\r\none 2\r\n")
        editor.redo(nil)
        #expect(editor.document.getText() == "1\r\nnext\r\n2\r\nnext\r\n")
        await editor.waitForRendering()
        #expect(view.displayedDocument?.diff.additionLines.joined() == editor.document.getText())
        #expect(!editor.isReplacingSearch)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func replacementRejectsInterveningEdits() async throws {
        let source = String(repeating: "match value\n", count: 40_000)
        let (window, _, editor) = try await makeView(source, source)
        defer { window.close() }
        let pending = Task { try await editor.replaceAll(.init(text: "match", replaceText: "changed")) }
        for _ in 0..<1000 {
            if editor.isReplacingSearch { break }
            await Task.yield()
        }
        #expect(editor.isReplacingSearch)
        editor.select(.init(location: 0, length: 0))
        editor.insertText("newest ", replacementRange: .init(location: NSNotFound, length: 0))
        do { _ = try await pending.value; Issue.record("Stale replacement should fail") }
        catch DiffEditorError.staleSearchDocument { }
        #expect(editor.document.getText() == "newest " + source)
        let cancelled = Task { try await editor.replaceAll(.init(text: "match", replaceText: "cancelled")) }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled replacement should fail") }
        catch is CancellationError { }
        #expect(editor.document.getText() == "newest " + source)
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func rapidInputKeepsLatestDocumentWithoutWaitingForHighlighting() async throws {
        let source = (0..<20_000).map { "source line \($0)\n" }.joined()
        let (window, view, editor) = try await makeView(source, source)
        defer { window.close() }
        let offset = editor.document.offsetAt(.init(line: 10_000, character: 0))
        editor.select(.init(location: offset, length: 0))
        let clock = ContinuousClock(), start = clock.now
        for _ in 0..<100 { editor.insertText("x", replacementRange: .init(location: NSNotFound, length: 0)) }
        let elapsed = start.duration(to: clock.now)
        print("Attached editor synchronous input, 100 edits / 20,000 lines: \(elapsed)")
        #expect(elapsed < .seconds(2))
        #expect(editor.document.getLineText(10_000) == String(repeating: "x", count: 100) + "source line 10000")
        await editor.waitForRendering()
        #expect(view.displayedDocument?.diff.additionLines.joined() == editor.document.getText())
        #expect(view.selectedTextRange?.head == .init(line: 10_000, character: 100))
        #expect(!editor.isPreparing)
        _ = try await editor.complete(.discard)
    }
}

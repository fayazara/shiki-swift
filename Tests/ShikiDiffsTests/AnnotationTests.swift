import Testing
import Foundation
import AppKit
@testable import ShikiDiffs

@Suite struct AnnotationTests {
    @Test @MainActor func annotationFrameResizeAutomaticallyUpdatesRowHeight() async throws {
        let file = FileContents(name: "f.txt", contents: "first\nsecond\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        window.contentView = view
        let annotation = NSView(frame: .init(x: 0, y: 0, width: 200, height: 80))
        view.renderAnnotation = { _ in annotation }
        view.render(document, annotations: [.init(lineNumber: 1, text: "Resizable")])
        view.layoutSubtreeIfNeeded()
        for height: CGFloat in [180, 60] {
            annotation.setFrameSize(.init(width: annotation.frame.width, height: height))
            view.layoutSubtreeIfNeeded()
            #expect(annotation.frame.height == height)
            #expect(annotation.superview === view.scrollView.documentView)
            let geometry = try #require(view.scrollView.documentView as? any TokenGeometryProviding)
            let nextLine = try #require(geometry.visibleTokenRects(lineNumber: 2, side: .additions, range: .init(location: 0, length: 1), revision: document.id).first)
            #expect(abs(nextLine.minY - (DiffRenderOptions().lineHeight + height)) < 0.01)
        }
    }
    @Test(arguments: [DiffOverflow.scroll, .wrap]) @MainActor func reorderedOffscreenAnnotationHeightsDoNotShiftViewport(overflow: DiffOverflow) async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.annotationRenderer = DiffAnnotationRenderer { _ in NSView(frame: .init(x: 0, y: 0, width: 100, height: 120)) }
        var items = (0..<100).map { CodeViewItem(id: "file-\($0)", document: document) }
        items[0].annotations = [.init(id: "note", lineNumber: 1, text: "Review")]
        var options = DiffRenderOptions(); options.overflow = overflow; options.disableFileHeader = true
        try view.setItems(items, options: options)
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparingWrappedLayout)
        view.layoutSubtreeIfNeeded()
        view.scrollToFile(at: 90)
        let position = view.scrollTop
        items.swapAt(0, 1)
        try view.setItems(items)
        #expect(!view.isPreparingWrappedLayout)
        #expect(view.scrollTop == position)
        #expect(view.mountedFileCount <= 2)
    }

    @Test(arguments: [DiffOverflow.scroll, .wrap]) @MainActor func reorderedItemsRetainMountedAnnotationControlAndRebindSelection(overflow: DiffOverflow) async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var calls = 0
        view.annotationRenderer = DiffAnnotationRenderer { _ in calls += 1; return NSTextField(string: "Draft") }
        let a = CodeViewItem(id: "a", document: document, annotations: [.init(id: "note", lineNumber: 1, text: "Review")])
        let b = CodeViewItem(id: "b", document: document)
        var options = DiffRenderOptions(); options.overflow = overflow
        try view.setItems([a, b], options: options)
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparingWrappedLayout)
        view.layoutSubtreeIfNeeded()
        let original = try #require(view.scrollView.documentView?.subviews.compactMap { $0 as? NativeDiffView }.first)
        let field = try #require(original.scrollView.documentView?.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Unsaved draft"
        let initialCalls = calls
        try view.setItems([b, a])
        #expect(!view.isPreparingWrappedLayout)
        view.layoutSubtreeIfNeeded()
        #expect(view.scrollView.documentView?.subviews.contains { $0 === original } == true)
        #expect(field.superview === original.scrollView.documentView)
        #expect(field.stringValue == "Unsaved draft" && calls == initialCalls)
        original.selectLines(.init(side: .additions, startLine: 1, endLine: 1))
        #expect(view.selectedItemLines?.id == "a")
        #expect(view.selectedLines?.fileIndex == 1)
    }

    @Test(arguments: [DiffOverflow.scroll, .wrap]) @MainActor func appendingReviewFilesRetainsVisibleCommentControls(overflow: DiffOverflow) async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        let field = NSTextField(string: "Draft review")
        var calls = 0
        view.annotationRenderer = DiffAnnotationRenderer { _ in calls += 1; return field }
        let notes = [0: [LineAnnotation(id: "note", lineNumber: 1, text: "Review")]]
        var options = DiffRenderOptions(); options.overflow = overflow
        func settle() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(!view.isPreparingWrappedLayout)
        }
        view.stageHeaderRenderers(.init())
        view.render([document], options: options, annotations: notes)
        try await settle()
        view.layoutSubtreeIfNeeded()
        let host = try #require(view.scrollView.documentView)
        let mounted = try #require(host.subviews.first { $0 is NativeDiffView })
        let parent = try #require(field.superview)
        field.stringValue = "Unsaved review text"
        let initialCalls = calls
        let position = view.scrollView.contentView.bounds.origin
        view.stageHeaderRenderers(.init())
        view.render(Array(repeating: document, count: 100), options: options, annotations: notes)
        try await settle()
        #expect(view.fileCount == 100)
        #expect(host.subviews.contains { $0 === mounted })
        #expect(field.superview === parent)
        #expect(field.stringValue == "Unsaved review text")
        #expect(calls == initialCalls)
        #expect(view.scrollView.contentView.bounds.origin == position)
        #expect(view.mountedFileCount <= 2)
    }

    @Test @MainActor func multiFileWrappingPreservesPositionInsideComment() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "word ", count: 100) + "\n" + String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let notes = [LineAnnotation(id: "note", lineNumber: 1, text: "Review")]
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.annotationRenderer = DiffAnnotationRenderer { _ in WidthSensitiveAnnotation(tall: true) }
        var options = DiffRenderOptions(); options.disableFileHeader = true; options.overflow = .wrap
        view.render([document, document], options: options, annotations: [0: notes])
        func settle() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(!view.isPreparingWrappedLayout)
            view.layoutSubtreeIfNeeded()
        }
        func targetY() async throws -> CGFloat {
            let plan = try await DiffWrapLayout.shared.layout(plan: .init(diff: document.diff, options: options, annotations: notes), diff: document.diff,
                width: view.scrollView.contentSize.width / 2 - 72,
                fontName: NSFont.monospacedSystemFont(ofSize: options.fontSize, weight: .regular).fontName, fontSize: options.fontSize)
            let row = try #require(plan.rows.firstIndex { $0.annotations.first?.id == "note" })
            return 8 + CGFloat(row) * 20 + 50
        }
        try await settle()
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 300)); view.layoutSubtreeIfNeeded()
        view.scrollView.contentView.scroll(to: .init(x: 0, y: try await targetY()))
        for width in [1000.0, 600.0] {
            window.setContentSize(.init(width: width, height: 300)); view.layoutSubtreeIfNeeded()
            try await settle()
            let expected = try await targetY()
            #expect(abs(view.scrollView.contentView.bounds.minY - expected) < 0.01)
        }
    }

    @Test @MainActor func multiFileResizePreservesPositionInsideComment() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.annotationRenderer = DiffAnnotationRenderer { _ in WidthSensitiveAnnotation(tall: true) }
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render([document, document], options: options, annotations: [0: [.init(id: "note", lineNumber: 1, text: "Review")]])
        view.layoutSubtreeIfNeeded()
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 8 + 20 + 50))
        window.setContentSize(.init(width: 1000, height: 300)); view.layoutSubtreeIfNeeded()
        #expect(view.scrollView.contentView.bounds.minY == 78)
        window.setContentSize(.init(width: 600, height: 300)); view.layoutSubtreeIfNeeded()
        #expect(view.scrollView.contentView.bounds.minY == 78)
    }

    @Test @MainActor func multiFileResizeInvalidatesOffscreenCommentMeasurements() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.annotationRenderer = DiffAnnotationRenderer { _ in WidthSensitiveAnnotation(tall: true) }
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render(Array(repeating: document, count: 3), options: options,
                    annotations: [0: [.init(id: "middle", lineNumber: 50, text: "Review")]])
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 900)); view.layoutSubtreeIfNeeded()
        view.scrollToFile(at: 1)
        #expect(view.scrollView.contentView.bounds.minY == 2176)
        view.scrollToFile(at: 0)
        window.setContentSize(.init(width: 1000, height: 300)); view.layoutSubtreeIfNeeded()
        view.scrollToFile(at: 1)
        #expect(view.scrollView.contentView.bounds.minY == 2036)
        view.scrollToFile(at: 0)
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 900)); view.layoutSubtreeIfNeeded()
        view.scrollToFile(at: 1)
        #expect(view.scrollView.contentView.bounds.minY == 2096)
    }

    @Test @MainActor func multiFileRetainsOffscreenAnnotationHeightOnReturn() async throws {
        let file = FileContents(name: "f.txt", contents: (1...100).map { "line \($0)\n" }.joined())
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.annotationRenderer = DiffAnnotationRenderer { _ in MutableHeightAnnotation() }
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render(Array(repeating: document, count: 100), options: options,
                    annotations: [0: [.init(id: "middle", lineNumber: 50, text: "Review")]])
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 900))
        view.layoutSubtreeIfNeeded()
        view.scrollToFile(at: 1)
        let measured = view.scrollView.contentView.bounds.minY
        #expect(abs(measured - 2096) < 0.01)
        view.scrollToFile(at: 90)
        view.scrollToFile(at: 0)
        view.layoutSubtreeIfNeeded()
        // The comment at line 50 is outside the returning viewport.
        view.scrollToFile(at: 1)
        #expect(abs(view.scrollView.contentView.bounds.minY - measured) < 0.01)
        #expect(view.mountedFileCount <= 2)
    }

    @Test @MainActor func multiFileCustomAnnotationsStayVirtualized() async throws {
        let file = FileContents(name: "f.txt", contents: (1...100).map { "line \($0)\n" }.joined())
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var calls = 0
        view.annotationRenderer = DiffAnnotationRenderer { _ in calls += 1; return MutableHeightAnnotation() }
        let notes = Dictionary(uniqueKeysWithValues: (0..<100).map { ($0, [LineAnnotation(id: "note", lineNumber: 1, text: "Review")]) })
        view.stageHeaderRenderers(.init())
        view.render(Array(repeating: document, count: 100), annotations: notes)
        view.layoutSubtreeIfNeeded()
        #expect(calls > 0)
        #expect(calls < 5)
        view.scrollToFile(at: 1)
        #expect(abs(view.scrollView.contentView.bounds.minY - (8 + 100 * 20 + 80 + 44 + 8)) < 0.01)
        view.scrollToFile(at: 90)
        view.layoutSubtreeIfNeeded()
        #expect(view.mountedFileCount <= 2)
        #expect(calls < 10)
    }

    @Test @MainActor func multiFileResizeKeepsAnnotationPixelOffset() async throws {
        let text = String(repeating: "word ", count: 30) + "\n" + (2...100).map { "line \($0)\n" }.joined()
        let file = FileContents(name: "f.txt", contents: text)
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let notes = [LineAnnotation(id: "first", lineNumber: 1, text: "First"), .init(id: "second", lineNumber: 50, text: "Second")]
        var options = DiffRenderOptions(); options.overflow = .wrap; options.disableFileHeader = true
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.render([document, document], options: options, annotations: [0: notes])
        var deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let fontName = NSFont.monospacedSystemFont(ofSize: options.fontSize, weight: .regular).fontName
        func annotationRow() async throws -> Int {
            let plan = try await DiffWrapLayout.shared.layout(plan: .init(diff: document.diff, options: options, annotations: notes), diff: document.diff, width: view.scrollView.contentSize.width / 2 - 72, fontName: fontName, fontSize: options.fontSize)
            return try #require(plan.rows.firstIndex { $0.annotations.first?.id == "second" })
        }
        let row = try await annotationRow()
        view.scrollView.contentView.scroll(to: .init(x: 0, y: CGFloat(row) * options.lineHeight + 5))
        let host = try #require(view.scrollView.documentView), oldHeight = host.frame.height
        window.setContentSize(.init(width: 1000, height: 300)); view.layoutSubtreeIfNeeded()
        #expect(view.isPreparingWrappedLayout)
        deadline = ContinuousClock.now + .seconds(5)
        while host.frame.height == oldHeight && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(host.frame.height != oldHeight)
        #expect(!view.isPreparingWrappedLayout)
        let newRow = try await annotationRow()
        #expect(abs(view.scrollView.contentView.bounds.minY - (CGFloat(newRow) * options.lineHeight + 5)) < 0.01)
    }
    @Test @MainActor func asynchronousResizeKeepsSecondAnnotationAndItsPixelOffset() async throws {
        let text = String(repeating: "word ", count: 30) + "\n" + (2...100).map { "line \($0)\n" }.joined()
        let file = FileContents(name: "f.txt", contents: text)
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.overflow = .wrap; options.disableFileHeader = true
        view.render(document, options: options, annotations: [.init(id: "first", lineNumber: 1, text: "First"), .init(id: "second", lineNumber: 50, text: "Second")])
        let initialCount = view.rowCount
        var deadline = ContinuousClock.now + .seconds(5)
        while view.rowCount == initialCount && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.rowCount > initialCount)
        view.scrollToLine(51)
        let commentY = view.scrollView.contentView.bounds.minY - options.lineHeight
        view.scrollView.contentView.scroll(to: .init(x: 0, y: commentY + 5))
        let oldCount = view.rowCount
        window.setContentSize(.init(width: 1000, height: 300)); view.layoutSubtreeIfNeeded()
        deadline = ContinuousClock.now + .seconds(5)
        while view.rowCount == oldCount && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.rowCount != oldCount)
        let actual = view.scrollView.contentView.bounds.minY
        view.scrollToLine(51)
        #expect(abs(actual - (view.scrollView.contentView.bounds.minY - options.lineHeight + 5)) < 0.01)
    }
    @Test func scrollAnchorDistinguishesAnnotationsWithoutSourceIndexes() {
        let firstNote = LineAnnotation(id: "first", lineNumber: 1, text: "Same text")
        let secondNote = LineAnnotation(id: "second", lineNumber: 50, text: "Same text")
        var first = DiffRow(kind: .annotation("Same text")); first.annotations = [firstNote]
        var second = DiffRow(kind: .annotation("Same text")); second.annotations = [secondNote]
        let separator = DiffRow(kind: .separator(hidden: 20, hunk: 0))
        #expect(!first.matchesScrollAnchor(second))
        #expect(!separator.matchesScrollAnchor(second))
        #expect(second.matchesScrollAnchor(second))
        var moved = second; moved.annotations[0].lineNumber = 55
        #expect(moved.matchesScrollAnchor(second))
    }
    @Test @MainActor func removingOffscreenAnnotationCanReplaceDocument() async throws {
        let worker = DiffHighlighter()
        let oldFile = FileContents(name: "old.txt", contents: (1...1000).map { "line \($0)\n" }.joined())
        let newFile = FileContents(name: "new.txt", contents: (1...100).map { "new \($0)\n" }.joined())
        let old = try await worker.prepare(oldFile: oldFile, newFile: oldFile)
        let replacement = try await worker.prepare(oldFile: newFile, newFile: newFile)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var replaced = false
        view.renderAnnotation = { note in
            let custom = RemovalAnnotation(frame: .init(x: 0, y: 0, width: 200, height: 120))
            if note.lineNumber == 1 {
                custom.onRemoval = { [weak view] in
                    guard !replaced else { return }; replaced = true
                    view?.render(replacement)
                }
            }
            return custom
        }
        view.render(old, annotations: [.init(lineNumber: 1, text: "First"), .init(lineNumber: 500, text: "Destination")])
        view.scrollToLine(500)
        view.layoutSubtreeIfNeeded()
        #expect(replaced)
        #expect(view.displayedDocument?.id == replacement.id)
        #expect(view.editorScrollOrigin.y == 0)
    }
    @Test @MainActor func replacingMetadataRefreshesCustomAnnotationView() async throws {
        struct Review: Sendable { let author: String }
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var calls = 0
        view.renderAnnotation = { note in
            calls += 1
            return NSTextField(labelWithString: note.metadata?.value(as: Review.self)?.author ?? "Missing")
        }
        var note = LineAnnotation(id: "review", lineNumber: 1, text: "Review", metadata: .init(Review(author: "Ada")))
        view.render(document, annotations: [note])
        let canvas = try #require(view.scrollView.documentView)
        let original = try #require(canvas.subviews.first as? NSTextField)
        #expect(original.stringValue == "Ada")
        view.render(document, annotations: [note])
        #expect(calls == 1)
        #expect(canvas.subviews.first === original)
        note.metadata = .init(Review(author: "Grace"))
        view.render(document, annotations: [note])
        let replacement = try #require(canvas.subviews.first as? NSTextField)
        #expect(calls == 2)
        #expect(replacement !== original)
        #expect(original.superview == nil)
        #expect(replacement.stringValue == "Grace")
    }
    @Test @MainActor func syntaxReplacementRetainsCustomAnnotationView() async throws {
        let file = FileContents(name: "f.swift", contents: "let value = 1\n")
        let worker = DiffHighlighter()
        let first = try await worker.prepare(oldFile: file, newFile: file)
        let second = try await worker.prepare(first.diff, sourceID: first.sourceID)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        var calls = 0
        view.renderAnnotation = { _ in calls += 1; return NSTextField(string: "Draft comment") }
        let annotations = [LineAnnotation(id: "note", lineNumber: 1, text: "Review")]
        view.render(first, annotations: annotations)
        let canvas = try #require(view.scrollView.documentView)
        let input = try #require(canvas.subviews.first as? NSTextField)
        input.stringValue = "Unsaved local state"
        view.render(second, annotations: annotations)
        #expect(calls == 1)
        #expect(canvas.subviews.first === input)
        #expect(input.stringValue == "Unsaved local state")
        let movedFile = FileContents(name: "f.swift", contents: "// inserted\nlet value = 1\n")
        let movedDiff = try parseDiffFromFile(file, movedFile)
        let movedDocument = try await worker.prepare(movedDiff, sourceID: first.sourceID)
        var movedAnnotations = annotations; movedAnnotations[0].lineNumber = 2
        view.render(movedDocument, annotations: movedAnnotations)
        #expect(calls == 1)
        #expect(canvas.subviews.first === input)
        #expect(input.stringValue == "Unsaved local state")
    }
    @Test @MainActor func multiFileAnnotationsContributeToScrollOffsets() async throws {
        let file = FileContents(name: "f.txt", contents: (1...100).map { "line \($0)\n" }.joined())
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        view.render([prepared, prepared, prepared])
        view.scrollToFile(at: 1)
        let before = view.scrollView.contentView.bounds.minY
        view.render([prepared, prepared, prepared], annotations: [0: [.init(lineNumber: 1, text: "Review")]])
        view.scrollToFile(at: 1)
        #expect(abs(view.scrollView.contentView.bounds.minY - before - 20) < 0.01)
        view.render([prepared, prepared, prepared])
        view.scrollToFile(at: 1)
        #expect(abs(view.scrollView.contentView.bounds.minY - before) < 0.01)
        #expect(view.mountedFileCount <= 2)
        var options = DiffRenderOptions(); options.overflow = .wrap
        view.render([prepared, prepared, prepared], options: options)
        var deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.isPreparingWrappedLayout)
        view.scrollToFile(at: 1)
        let wrappedBefore = view.scrollView.contentView.bounds.minY
        view.render([prepared, prepared, prepared], options: options, annotations: [0: [.init(lineNumber: 1, text: "Review")]])
        deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.isPreparingWrappedLayout)
        view.scrollToFile(at: 1)
        #expect(abs(view.scrollView.contentView.bounds.minY - wrappedBefore - 20) < 0.01)
    }
    @Test @MainActor func editableWrapperRetainsInstalledAnnotationsUntilHostChanges() {
        let coordinator = EditableFileDiffView.Coordinator()
        let sourceID = UUID()
        let original = [LineAnnotation(id: "note", lineNumber: 1, text: "Review")]
        var moved = original; moved[0].lineNumber = 3
        #expect(coordinator.resolveAnnotations(documentID: sourceID, provided: original) == original)
        coordinator.installedAnnotations = moved
        #expect(coordinator.resolveAnnotations(documentID: sourceID, provided: original) == moved)
        var supplied = original; supplied[0].text = "Updated review"
        #expect(coordinator.resolveAnnotations(documentID: sourceID, provided: supplied) == supplied)
        coordinator.installedAnnotations = moved
        #expect(coordinator.resolveAnnotations(documentID: UUID(), provided: original) == original)
    }
    @Test @MainActor func cancelledCompositionRestoresAnnotationRedoHistory() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\nthree\n")
        let highlighter = DiffHighlighter()
        let document = try await highlighter.prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        let annotations = [LineAnnotation(id: "note", lineNumber: 1, text: "Review")]
        view.render(document, annotations: annotations)
        let editor = try view.beginEditing(highlighter: highlighter)
        defer { editor.abandon() }
        editor.insertText("", replacementRange: .init(location: 0, length: 4))
        #expect(editor.currentAnnotations.isEmpty)
        editor.undo(nil)
        #expect(editor.currentAnnotations == annotations)
        editor.setMarkedText("temporary\n", selectedRange: .init(location: 0, length: 0), replacementRange: .init(location: 0, length: 0))
        #expect(editor.currentAnnotations.first?.lineNumber == 2)
        editor.doCommand(by: NSSelectorFromString("cancelOperation:"))
        #expect(editor.currentAnnotations == annotations)
        editor.redo(nil)
        #expect(editor.currentAnnotations.isEmpty)
        editor.undo(nil)
        #expect(editor.currentAnnotations == annotations)
        editor.setMarkedText("new\n", selectedRange: .init(location: 4, length: 0), replacementRange: .init(location: 0, length: 0))
        editor.unmarkText()
        #expect(editor.currentAnnotations.first?.lineNumber == 2)
        editor.undo(nil)
        #expect(editor.currentAnnotations == annotations)
        editor.redo(nil)
        #expect(editor.currentAnnotations.first?.lineNumber == 2)
        await editor.waitForRendering()
    }
    @Test @MainActor func externalAnnotationsDoNotResetMappedPositionsOnRefresh() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\nthree\n")
        let highlighter = DiffHighlighter()
        let document = try await highlighter.prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        let original = [LineAnnotation(id: "note", lineNumber: 2, text: "Review")]
        view.render(document, annotations: original)
        let editor = try view.beginEditing(highlighter: highlighter)
        defer { editor.abandon() }
        editor.insertText("first\n", replacementRange: .init(location: 0, length: 0))
        #expect(editor.currentAnnotations.first?.lineNumber == 3)
        view.render(document, annotations: original)
        #expect(editor.currentAnnotations.first?.lineNumber == 3)
        let replacement = [LineAnnotation(id: "new", lineNumber: 1, text: "New review")]
        view.render(document, annotations: replacement)
        #expect(editor.currentAnnotations == replacement)
        editor.insertText("another\n", replacementRange: .init(location: 0, length: 0))
        #expect(editor.currentAnnotations.first?.lineNumber == 2)
        editor.setAnnotations(replacement)
        #expect(editor.currentAnnotations == replacement)
        await editor.waitForRendering()
    }
    @Test @MainActor func customAnnotationSurvivesEditingLifecycle() async throws {
        let file = FileContents(name: "f.txt", contents: (1...100).map { "line \($0)\n" }.joined())
        let highlighter = DiffHighlighter()
        let document = try await highlighter.prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.renderAnnotation = { _ in NSView(frame: .init(x: 0, y: 0, width: 200, height: 120)) }
        let metadata = LineAnnotationMetadata(["author": "Ada"])
        view.render(document, annotations: [.init(lineNumber: 1, text: "Review", metadata: metadata)])
        let canvas = try #require(view.scrollView.documentView)
        #expect(canvas.subviews.count == 1)
        let editor = try view.beginEditing(highlighter: highlighter)
        await editor.waitForRendering()
        view.layoutSubtreeIfNeeded()
        #expect(canvas.subviews.count == 1)
        #expect(canvas.subviews.first?.frame.height == 120)
        editor.insertText("", replacementRange: .init(location: 0, length: 7))
        #expect(editor.currentAnnotations.isEmpty)
        editor.undo(nil)
        #expect(editor.currentAnnotations.map(\.lineNumber) == [1])
        #expect(editor.currentAnnotations.first?.metadata === metadata)
        editor.redo(nil)
        #expect(editor.currentAnnotations.isEmpty)
        editor.undo(nil)
        #expect(editor.currentAnnotations.map(\.lineNumber) == [1])
        #expect(editor.currentAnnotations.first?.metadata === metadata)
        var completion: DiffEditCompletion?
        editor.onEditComplete = { completion = $0; return true }
        try await editor.complete(.install)
        #expect(completion?.annotations == editor.currentAnnotations)
        #expect(completion?.originalAnnotations.map(\.lineNumber) == [1])
        #expect(completion?.annotations.first?.metadata === metadata)
        #expect(completion?.originalAnnotations.first?.metadata === metadata)
        #expect(view.displayedAnnotations.first?.metadata === metadata)
        view.layoutSubtreeIfNeeded()
        #expect(canvas.subviews.count == 1)
        #expect(canvas.subviews.first?.frame.height == 120)
        view.scrollToLine(2)
        #expect(abs(view.scrollView.contentView.bounds.minY - 140) < 0.01)
    }
    @Test @MainActor func customViewsFollowVisibleAnnotations() async throws {
        let file = FileContents(name: "f.txt", contents: (1...1000).map { "line \($0)\n" }.joined())
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.renderAnnotation = { NSTextField(labelWithString: $0.text) }
        view.render(document, annotations: (1...1000).map { .init(id: "\($0)", lineNumber: $0, text: "Comment \($0)") })
        view.layoutSubtreeIfNeeded()
        let canvas = try #require(view.scrollView.documentView)
        let initial = canvas.subviews.compactMap { $0 as? NSTextField }
        #expect(!initial.isEmpty && initial.count < 20)
        #expect(initial.contains { $0.stringValue == "Comment 1" })
        view.scrollToRow(1800)
        let destination = canvas.subviews.compactMap { $0 as? NSTextField }
        #expect(!destination.isEmpty && destination.count < 20)
        #expect(initial.allSatisfy { $0.superview == nil })
        view.renderAnnotation = { _ in nil }
        #expect(canvas.subviews.isEmpty)
        view.renderAnnotation = nil
        #expect(canvas.subviews.isEmpty)
    }
    @Test @MainActor func rendererReplacementDiscardsStaleReturnedView() async throws {
        let file = FileContents(name: "f.txt", contents: "line\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        let stale = NSTextField(labelWithString: "Stale")
        view.renderAnnotation = { [weak view] _ in
            view?.renderAnnotation = { _ in NSTextField(labelWithString: "Replacement") }
            return stale
        }
        view.render(document, annotations: [.init(lineNumber: 1, text: "Comment")])
        view.layoutSubtreeIfNeeded()
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        #expect(stale.superview == nil)
        let canvas = try #require(view.scrollView.documentView)
        #expect(canvas.subviews.compactMap { ($0 as? NSTextField)?.stringValue } == ["Replacement"])
    }
    @Test @MainActor func documentReplacementDiscardsStaleAnnotation() async throws {
        let worker = DiffHighlighter()
        let oldFile = FileContents(name: "old.txt", contents: "old\n")
        let newFile = FileContents(name: "new.txt", contents: "new\n")
        let old = try await worker.prepare(oldFile: oldFile, newFile: oldFile)
        let new = try await worker.prepare(oldFile: newFile, newFile: newFile)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        let stale = NSTextField(labelWithString: "Stale")
        view.renderAnnotation = { [weak view] annotation in
            if annotation.id == "old" {
                view?.render(new, annotations: [.init(id: "new", lineNumber: 1, text: "New comment")])
                return stale
            }
            return NSTextField(labelWithString: annotation.text)
        }
        view.render(old, annotations: [.init(id: "old", lineNumber: 1, text: "Old comment")])
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        #expect(view.displayedDocument?.id == new.id)
        #expect(stale.superview == nil)
        let canvas = try #require(view.scrollView.documentView)
        #expect(canvas.subviews.compactMap { ($0 as? NSTextField)?.stringValue } == ["New comment"])
    }
    @Test @MainActor func tallAnnotationMovesFollowingCodeAndScrollDestination() async throws {
        let file = FileContents(name: "f.txt", contents: (1...100).map { "line \($0)\n" }.joined())
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.renderAnnotation = { _ in NSView(frame: .init(x: 0, y: 0, width: 200, height: 120)) }
        view.render(document, annotations: [.init(lineNumber: 1, text: "Tall")])
        view.layoutSubtreeIfNeeded()
        let canvas = try #require(view.scrollView.documentView)
        #expect(canvas.subviews.first?.frame.height == 120)
        var clickedLine: Int?
        var clickedRect: NSRect?
        view.interactionHandlers = .init(onLineNumberClick: { clickedLine = $0.lineNumber; clickedRect = $0.numberRect }, enableLineSelection: true)
        func click(y: CGFloat) throws {
            let location = canvas.convert(.init(x: 10, y: y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
                if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
            }
        }
        try click(y: DiffRenderOptions().lineHeight + 125)
        #expect(clickedLine == 2)
        #expect(view.selectedLines == .init(side: .deletions, startLine: 2, endLine: 2))
        #expect(abs((clickedRect?.minY ?? -1) - (DiffRenderOptions().lineHeight + 120)) < 0.01)
        view.selectLines(nil, notify: false); clickedLine = nil
        try click(y: 80)
        #expect(clickedLine == nil && view.selectedLines == nil)
        view.scrollToLine(2)
        #expect(abs(view.scrollView.contentView.bounds.minY - (DiffRenderOptions().lineHeight + 120)) < 0.01)
        #expect(canvas.frame.height >= 100 * DiffRenderOptions().lineHeight + 120)
        view.scrollToRow(0)
        view.renderAnnotation = { _ in nil }
        view.layoutSubtreeIfNeeded()
        view.scrollToLine(2)
        #expect(abs(view.scrollView.contentView.bounds.minY - DiffRenderOptions().lineHeight) < 0.01)
        view.scrollToRow(0)
        view.renderAnnotation = { _ in NSView(frame: .init(x: 0, y: 0, width: 200, height: 120)) }
        view.layoutSubtreeIfNeeded(); view.scrollToLine(2)
        #expect(abs(view.scrollView.contentView.bounds.minY - (DiffRenderOptions().lineHeight + 120)) < 0.01)
        view.renderAnnotation = nil
        view.scrollToLine(2)
        #expect(abs(view.scrollView.contentView.bounds.minY - 2 * DiffRenderOptions().lineHeight) < 0.01)
    }
    @Test @MainActor func pairedAnnotationsRemeasureWhenViewportWidens() async throws {
        let file = FileContents(name: "f.txt", contents: (1...100).map { "line \($0)\n" }.joined())
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.renderAnnotation = { annotation in
            WidthSensitiveAnnotation(tall: annotation.side == .additions)
        }
        view.render(document, annotations: [
            .init(id: "old", side: .deletions, lineNumber: 1, text: "Old"),
            .init(id: "new", lineNumber: 1, text: "New")
        ])
        view.layoutSubtreeIfNeeded()
        let canvas = try #require(view.scrollView.documentView)
        #expect(canvas.subviews.count == 2)
        #expect(canvas.subviews.allSatisfy { abs($0.frame.height - 160) < 0.01 })
        window.setContentSize(.init(width: 900, height: 300))
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        #expect(canvas.subviews.allSatisfy { abs($0.frame.height - 80) < 0.01 })
        view.scrollToLine(2)
        #expect(abs(view.scrollView.contentView.bounds.minY - (DiffRenderOptions().lineHeight + 80)) < 0.01)
    }
    @Test @MainActor func dynamicHeightRefreshRetainsViewAndViewportAnchor() async throws {
        let file = FileContents(name: "f.txt", contents: (1...100).map { "line \($0)\n" }.joined())
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        let annotation = MutableHeightAnnotation()
        var calls = 0
        view.renderAnnotation = { _ in calls += 1; return annotation }
        view.render(document, annotations: [.init(lineNumber: 1, text: "Expandable")])
        view.layoutSubtreeIfNeeded()
        let initialCalls = calls
        let initialMeasurements = annotation.measurements
        for offset in [1, 3, 5, 3, 1, 0] {
            view.scrollView.contentView.scroll(to: .init(x: 0, y: offset))
            view.layoutSubtreeIfNeeded()
        }
        #expect(annotation.measurements == initialMeasurements)
        let origin = view.scrollView.contentView.bounds.origin
        annotation.preferredHeight = 180
        view.invalidateAnnotationLayout(); view.layoutSubtreeIfNeeded()
        #expect(annotation.frame.height == 180)
        #expect(annotation.measurements > initialMeasurements)
        #expect(calls == initialCalls)
        #expect(view.scrollView.contentView.bounds.origin == origin)
        annotation.preferredHeight = 60
        view.invalidateAnnotationLayout(); view.layoutSubtreeIfNeeded()
        #expect(annotation.frame.height == 60)
        #expect(calls == initialCalls)
        view.scrollToLine(2)
        #expect(abs(view.scrollView.contentView.bounds.minY - (DiffRenderOptions().lineHeight + 60)) < 0.01)
    }
    @Test @MainActor func asynchronousWindowResizeRetainsVisibleCommentControls() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "word ", count: 20) + "\nnext\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 500)); window.contentView = view
        view.renderAnnotation = { _ in NSTextField(string: "Draft") }
        var options = DiffRenderOptions(); options.overflow = .wrap
        view.render(document, options: options, annotations: [.init(id: "note", lineNumber: 1, text: "Review")])
        let canvas = try #require(view.scrollView.documentView)
        let input = try #require(canvas.subviews.first as? NSTextField)
        input.stringValue = "Keep this draft"
        let deadline = ContinuousClock.now + .seconds(5)
        while view.rowCount <= 3 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.rowCount > 3)
        for width: CGFloat in [1000, 500, 800] {
            let oldCount = view.rowCount
            window.setContentSize(.init(width: width, height: 500))
            view.layoutSubtreeIfNeeded()
            let deadline = ContinuousClock.now + .seconds(5)
            while view.rowCount == oldCount && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(view.rowCount != oldCount)
            #expect(canvas.subviews.first === input)
            #expect(input.stringValue == "Keep this draft")
        }
    }
    @Test @MainActor func wrappedLayoutRetainsVisibleCommentControls() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "word ", count: 20) + "\nnext\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let annotations = [LineAnnotation(id: "note", lineNumber: 1, text: "Review")]
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 500))
        view.renderAnnotation = { _ in NSTextField(string: "Draft") }
        view.render(document, annotations: annotations)
        let canvas = try #require(view.scrollView.documentView)
        let input = try #require(canvas.subviews.first as? NSTextField)
        input.stringValue = "Keep this draft"
        for width: CGFloat in [180, 320, 200] {
            let plan = try await DiffWrapLayout.shared.layout(plan: .init(diff: document.diff, annotations: annotations), diff: document.diff, width: width, fontName: "Menlo", fontSize: 13)
            view.installRenderPlan(plan)
            view.layoutSubtreeIfNeeded()
            #expect(canvas.subviews.first === input)
            #expect(input.stringValue == "Keep this draft")
        }
    }
    @Test @MainActor func wrappedPlanKeepsMeasuredAnnotationBeforeNextSourceLine() async throws {
        let source = String(repeating: "word ", count: 80) + "\n" + (2...100).map { "line \($0)\n" }.joined()
        let file = FileContents(name: "f.txt", contents: source)
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let annotations: [LineAnnotation] = [.init(id: "note", lineNumber: 1, text: "After wrapped line")]
        var options = DiffRenderOptions(); options.overflow = .wrap
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.renderAnnotation = { _ in NSView(frame: .init(x: 0, y: 0, width: 200, height: 120)) }
        view.render(document, options: options, annotations: annotations)
        for width: CGFloat in [180, 320] {
            let plan = try await DiffWrapLayout.shared.layout(plan: .init(diff: document.diff, options: options, annotations: annotations), diff: document.diff, width: width, fontName: "Menlo", fontSize: options.fontSize)
            let annotationRow = try #require(plan.rows.firstIndex { !$0.annotations.isEmpty })
            #expect(annotationRow > 1)
            view.installRenderPlan(plan)
            view.scrollToRow(annotationRow); view.layoutSubtreeIfNeeded()
            let canvas = try #require(view.scrollView.documentView)
            let annotation = try #require(canvas.subviews.first)
            #expect(abs(annotation.frame.minY - CGFloat(annotationRow) * options.lineHeight) < 0.01)
            #expect(annotation.frame.height == 120)
            view.scrollToLine(2)
            #expect(abs(view.scrollView.contentView.bounds.minY - (CGFloat(annotationRow) * options.lineHeight + 120)) < 0.01)
        }
    }
    @Test @MainActor func themeChangeRetainsOffscreenAnnotationHeight() async throws {
        let file = FileContents(name: "f.txt", contents: (1...100).map { "line \($0)\n" }.joined())
        let document = try await DiffHighlighter().prepareThemes(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeThemedDiffView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.annotationRenderer = .init { _ in NSView(frame: .init(x: 0, y: 0, width: 200, height: 120)) }
        view.themeAppearance = .dark
        view.render(document, annotations: [.init(lineNumber: 1, text: "Note")])
        view.diffView.scrollToLine(50)
        let before = view.diffView.scrollView.contentView.bounds.minY
        view.themeAppearance = .light
        view.layoutSubtreeIfNeeded()
        #expect(abs(view.diffView.scrollView.contentView.bounds.minY - before) < 0.01)
        view.diffView.scrollToLine(50)
        #expect(abs(view.diffView.scrollView.contentView.bounds.minY - before) < 0.01)
        view.themeAppearance = .dark
        view.layoutSubtreeIfNeeded()
        #expect(abs(view.diffView.scrollView.contentView.bounds.minY - before) < 0.01)
        view.diffView.scrollToLine(50)
        #expect(abs(view.diffView.scrollView.contentView.bounds.minY - before) < 0.01)
    }
    @Test func pairedSidesAndFileLevelAnnotations() throws {
        let diff = try parseDiffFromFile(.init(name: "f.txt", contents: "same\nold\n"), .init(name: "f.txt", contents: "same\nnew\n"))
        let annotations: [LineAnnotation] = [
            .init(id: "file-old", side: .deletions, lineNumber: 0, text: "Before"),
            .init(id: "file-new", lineNumber: 0, text: "After"),
            .init(id: "old", side: .deletions, lineNumber: 1, text: "Old context"),
            .init(id: "new", lineNumber: 1, text: "New context"),
            .init(id: "extra", lineNumber: 1, text: "Second comment"),
            .init(id: "invalid", lineNumber: -1, text: "Ignored"),
            .init(id: "outside", lineNumber: 99, text: "Ignored")
        ]
        let plan = DiffRenderPlan(diff: diff, annotations: annotations)
        #expect(plan.rows.filter { !$0.annotations.isEmpty }.map { $0.annotations.map(\.id) } == [["file-old", "file-new"], ["old", "new"], ["extra"]])
        #expect(plan.rows.first?.annotations.map(\.lineNumber) == [0, 0])
        #expect(plan.rows.filter { !$0.annotations.isEmpty }.allSatisfy { $0.oldIndex == nil && $0.newIndex == nil && $0.oldNumber == nil && $0.newNumber == nil })
        var options = DiffRenderOptions(); options.diffStyle = .unified
        #expect(DiffRenderPlan(diff: diff, options: options, annotations: annotations).rows.flatMap(\.annotations).map(\.id) == ["file-old", "file-new", "old", "new", "extra"])
        options.collapsed = true
        #expect(DiffRenderPlan(diff: diff, options: options, annotations: annotations).rows.isEmpty)
    }

    @Test func missingSideAndWrapping() async throws {
        let annotations: [LineAnnotation] = [.init(id: "old", side: .deletions, lineNumber: 0, text: "Old"), .init(id: "new", lineNumber: 0, text: "New")]
        var diff = try parseDiffFromFile(.init(name: "f.txt", contents: ""), .init(name: "f.txt", contents: String(repeating: "long line ", count: 30)))
        diff.type = .new
        let plan = DiffRenderPlan(diff: diff, annotations: annotations)
        #expect(plan.rows.flatMap(\.annotations).map(\.id) == ["new"])
        let wrapped = try await DiffWrapLayout.shared.layout(plan: plan, diff: diff, width: 80, fontName: "Menlo", fontSize: 13)
        #expect(wrapped.rows.count > plan.rows.count)
        #expect(wrapped.rows.flatMap(\.annotations) == plan.rows.flatMap(\.annotations))
        diff.type = .deleted
        #expect(DiffRenderPlan(diff: diff, annotations: annotations).rows.flatMap(\.annotations).map(\.id) == ["old"])
    }
}

@MainActor private final class WidthSensitiveAnnotation: NSView {
    let tall: Bool
    init(tall: Bool) { self.tall = tall; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Use init(tall:)") }
    override var intrinsicContentSize: NSSize {
        .init(width: NSView.noIntrinsicMetric, height: tall ? (bounds.width < 350 ? 160 : 80) : 60)
    }
}

@MainActor private final class MutableHeightAnnotation: NSView {
    var preferredHeight: CGFloat = 80
    var measurements = 0
    override var intrinsicContentSize: NSSize {
        measurements += 1
        return .init(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }
}

@MainActor private final class RemovalAnnotation: NSView {
    var onRemoval: (() -> Void)?
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { onRemoval?() }
    }
}

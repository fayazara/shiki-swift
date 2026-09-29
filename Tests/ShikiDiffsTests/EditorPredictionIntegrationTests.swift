import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct EditorPredictionIntegrationTests {
    actor Gate {
        var requests: [EditPredictRequest] = []
        var continuations: [CheckedContinuation<EditPredictResponse, any Error>] = []
        func predict(_ request: EditPredictRequest) async throws -> EditPredictResponse {
            requests.append(request)
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        func finish(_ response: EditPredictResponse) { continuations.removeFirst().resume(returning: response) }
        var count: Int { requests.count }
    }
    @MainActor func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(15)) }
        try #require(condition())
    }
    @MainActor func mount(_ text: String, style: DiffStyle = .unified, overflow: DiffOverflow = .scroll, width: CGFloat = 600) async throws -> (NSWindow, NativeDiffView, DiffEditor) {
        let file = FileContents(name: "f.txt", contents: text)
        var options = DiffRenderOptions(); options.expandUnchanged = true; options.diffStyle = style
        options.overflow = overflow; options.disableFileHeader = true; options.theme = "pierre-light"
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: width, height: 360)); window.contentView = view
        view.render(try await DiffHighlighter().prepare(oldFile: file, newFile: file, options: options), options: options)
        let editor = try view.beginEditing(); await editor.waitForRendering(); view.layoutSubtreeIfNeeded()
        return (window, view, editor)
    }
    @MainActor @discardableResult func paint(_ view: NativeDiffView, path: String? = nil) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        if let path { try data.write(to: URL(fileURLWithPath: path)) }
        return data
    }
    func insertion(_ text: String, line: Int = 0, character: Int = 4) -> EditPredictResponse {
        let start = TextPosition(line: line, character: character)
        let inserted = TextDocument(uri: "fragment", text: text)
        let lastLength = (try? inserted.getLineLength(inserted.lineCount - 1)) ?? 0
        return .init(edits: [.init(range: .init(start: start, end: start), newText: text)],
            newCursor: .init(line: line + inserted.lineCount - 1, character: inserted.lineCount == 1 ? character + lastLength : lastLength))
    }
    @Test @MainActor func multilinePreviewNeedsPaintAndAcceptsAsOneUndoGroup() async throws {
        let (window, view, editor) = try await mount("let value = 1\nprint(value)\n" + String(repeating: "// line\n", count: 30)); defer { window.close() }
        let baseline = view.contentHeight
        let response = insertion("result = 2\nlet ")
        editor.select(.init(location: 4, length: 0))
        editor.editPrediction = .init(provider: .init { _ in response })
        try await wait { editor.predictionController?.preview != nil }
        editor.predictionController?.preview?.rendered = false
        #expect(!editor.acceptEditPrediction())
        #expect(view.contentHeight > baseline)
        try paint(view, path: "/tmp/swift-diffs-prediction-multiline.png")
        #expect(editor.canAcceptEditPrediction)
        #expect(editor.acceptEditPrediction())
        #expect(editor.getText().hasPrefix("let result = 2\nlet value = 1"))
        #expect(editor.predictionController?.history.last?.source == .prediction)
        editor.editPrediction = nil
        editor.undo(nil); #expect(editor.getText().hasPrefix("let value = 1"))
        editor.redo(nil); #expect(editor.getText().hasPrefix("let result = 2\nlet value = 1"))
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func staleProviderResultsAndSuspensionNeverInstall() async throws {
        let (window, view, editor) = try await mount("let value = 1\n"); defer { window.close() }
        let gate = Gate()
        editor.editPrediction = .init(provider: .init { try await gate.predict($0) })
        let firstDeadline = ContinuousClock.now + .seconds(3)
        while await gate.count == 0, ContinuousClock.now < firstDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(await gate.count == 1)
        editor.select(.init(location: 4, length: 0))
        await gate.finish(insertion("stale", character: 0))
        try await Task.sleep(for: .milliseconds(40)); #expect(editor.predictionController?.preview == nil)
        let secondDeadline = ContinuousClock.now + .seconds(3)
        while await gate.count < 2, ContinuousClock.now < secondDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(await gate.count == 2)
        editor.suspend(); await gate.finish(insertion("suspended"))
        try await Task.sleep(for: .milliseconds(40)); #expect(editor.predictionController?.preview == nil)
        try view.resumeEditing(editor); await editor.waitForRendering()
        editor.editPrediction = nil; _ = try await editor.complete(.discard)
    }
    @Test @MainActor func subtleModeFiltersAndOptionToggle() async throws {
        let (window, view, editor) = try await mount("let value = 1\n"); defer { window.close() }
        let response = insertion("other + ")
        let provider = EditPredictProvider { _ in response }
        editor.editPrediction = .init(provider: provider, mode: .subtle, include: [])
        try await Task.sleep(for: .milliseconds(360)); #expect(editor.predictionController?.preview == nil)
        editor.editPrediction = .init(provider: provider, mode: .subtle, include: [.glob("**/*.txt")], exclude: [.glob("f.txt")])
        try await Task.sleep(for: .milliseconds(360)); #expect(editor.predictionController?.preview == nil)
        editor.editPrediction = .init(provider: provider, mode: .subtle, include: [.glob("**/*.txt")])
        try await wait { editor.predictionController?.preview != nil }
        try paint(view); #expect(!editor.canAcceptEditPrediction)
        let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58))
        editor.predictionModifierChanged(event); try paint(view); #expect(editor.canAcceptEditPrediction)
        editor.predictionModifierChanged(event); try paint(view); #expect(!editor.canAcceptEditPrediction)
        editor.dismissEditPrediction(); #expect(editor.predictionController?.preview == nil)
        editor.editPrediction = nil; _ = try await editor.complete(.discard)
    }
    @Test @MainActor func wrappingAndSplitSpacersStayAlignedAndClear() async throws {
        let (window, view, editor) = try await mount("let value = 1\nprint(value)\n" + String(repeating: "next\n", count: 20), style: .split, overflow: .wrap, width: 420); defer { window.close() }
        let baseline = view.contentHeight, response = insertion("someLongName + anotherLongName + ")
        editor.select(.init(location: 4, length: 0)); editor.editPrediction = .init(provider: .init { _ in response })
        try await wait { editor.predictionController?.preview != nil }
        try paint(view, path: "/tmp/swift-diffs-prediction-wrapped.png")
        #expect(view.contentHeight > baseline && editor.canAcceptEditPrediction)
        editor.dismissEditPrediction(); #expect(view.contentHeight == baseline)
        try paint(view); #expect(!editor.canAcceptEditPrediction)
        editor.editPrediction = nil; _ = try await editor.complete(.discard)
    }
    @Test func supplementalHeightsPreserveMeasuredAnnotations() {
        var index = RowHeightIndex(rowCount: 100_000, lineHeight: 20, variableRows: [3, 50])
        index.setHeight(80, for: 3); index.setSupplementalHeights([1: 40, 70_000: 60])
        #expect(index.origin(of: 4) == 180 && index.row(at: 45) == 1)
        index.setHeight(100, for: 3); #expect(index.origin(of: 4) == 200)
        index.setSupplementalHeights([:]); #expect(index.origin(of: 4) == 160 && index.totalHeight == 2_000_080)
    }
    @Test @MainActor func deletionReplacementAndOffscreenAcceptance() async throws {
        let (window, view, editor) = try await mount("let value = 1\nprint(value)\n" + String(repeating: "next\n", count: 80)); defer { window.close() }
        let start = TextPosition(line: 0, character: 4), end = TextPosition(line: 0, character: 9)
        let deletion = EditPredictResponse(edits: [.init(range: .init(start: start, end: end), newText: "")], newCursor: start)
        editor.editPrediction = .init(provider: .init { _ in deletion })
        try await wait { editor.predictionController?.preview != nil }
        let baseline = view.contentHeight
        try paint(view, path: "/tmp/swift-diffs-prediction-deletion.png")
        #expect(editor.canAcceptEditPrediction && view.contentHeight == baseline)
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 500)); view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        #expect(!editor.acceptEditPrediction())
        view.scrollView.contentView.scroll(to: .zero); try paint(view)
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        #expect(editor.handleKeyEvent(tab)); #expect(editor.getText().hasPrefix("let  = 1"))
        editor.editPrediction = nil; editor.undo(nil); await editor.waitForRendering()
        let replacement = EditPredictResponse(edits: [.init(range: .init(start: start, end: end), newText: "updated")], newCursor: .init(line: 0, character: 11))
        editor.editPrediction = .init(provider: .init { _ in replacement })
        try await wait { editor.predictionController?.preview != nil }
        try paint(view, path: "/tmp/swift-diffs-prediction-replacement.png")
        #expect(editor.acceptEditPrediction()); #expect(editor.getText().hasPrefix("let updated = 1"))
        editor.editPrediction = nil; _ = try await editor.complete(.discard)
    }
    @Test @MainActor func compositionCancelRestoresHistoryAndSuppressesRequests() async throws {
        let (window, view, editor) = try await mount("let value = 1\n"); defer { window.close() }
        let response = insertion(" /* result */", character: 0)
        editor.editPrediction = .init(provider: .init { _ in response })
        try await wait { editor.predictionController?.preview != nil }
        let history = editor.predictionController?.history
        editor.setMarkedText("候", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        editor.setMarkedText("候補", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(360)); #expect(editor.predictionController?.preview == nil)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(editor.predictionController?.history == history && editor.getText() == "let value = 1\n")
        editor.editPrediction = nil; _ = try await editor.complete(.discard)
        #expect(view.attachedEditor == nil)
    }
    @Test func touchingSourceLinesComposeOneGhostWithPreservedSuffix() {
        let document = TextDocument(uri: "f", text: "abc def ghi\nlast")
        let response = EditPredictResponse(edits: [
            .init(range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 1)), newText: "X"),
            .init(range: .init(start: .init(line: 0, character: 4), end: .init(line: 0, character: 7)), newText: "YZ")
        ], newCursor: .init(line: 0, character: 6))
        let groups = composeEditPredictionGroups(response, document: document)
        #expect(groups.count == 1 && groups[0].edit.newText == "Xbc YZ ghi" && groups[0].edit.range.end.character == 11)
        #expect(groups[0].insertionSuffix == nil)
    }

    @Test @MainActor func longGhostUsesHorizontalViewportAndProviderReplacement() async throws {
        let (window, view, editor) = try await mount("let value = 1\n"); defer { window.close() }
        let response = insertion(String(repeating: "x", count: 100_000))
        var provider = EditPredictProvider { _ in response }
        editor.editPrediction = .init(provider: provider)
        try await wait { editor.predictionController?.preview != nil }
        let canvas = try #require(view.scrollView.documentView)
        #expect(canvas.frame.width > 100_000)
        let start = ContinuousClock.now
        for index in 0..<16 {
            view.scrollView.contentView.scroll(to: .init(x: CGFloat(index) * (canvas.frame.width - 600) / 15, y: 0))
            try paint(view)
        }
        print("Prediction 100k ASCII ghost / 16 horizontal jumps: \(start.duration(to: .now))")
        let previous = editor.predictionController?.preview?.id
        let next = insertion("new")
        provider.predict = { _ in next }; editor.editPrediction = .init(provider: provider)
        try await wait { editor.predictionController?.preview?.id != nil && editor.predictionController?.preview?.id != previous }
        #expect(canvas.frame.width < 100_000)
        editor.editPrediction = nil; _ = try await editor.complete(.discard)
    }

}

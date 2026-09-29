import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct EditorOverlayTests {
    @Test func intervalIndexMatchesNaiveQueriesWithoutExpandingLongRanges() {
        let intervals = (0..<10_000).map { ($0 * 17)...($0 * 17 + $0 % 11) } + [0...Int.max]
        let index = EditorOverlayIndex(intervals)
        for line in stride(from: 0, through: 170_001, by: 397) {
            #expect(index.query(line) == intervals.indices.filter { intervals[$0].contains(line) })
        }
        #expect(index.query(Int.max) == [10_000])
    }
    @Test @MainActor func externalCaretsTrackEditsUndoAndCompositionCancellation() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(); view.render(prepared)
        let editor = try view.beginEditing()
        editor.setCarets([.init(anchor: .init(line: 0, character: 1), focus: .init(line: 1, character: 2), metadata: .init(color: "#00f"))])
        editor.insertText("😀\n", replacementRange: .init(location: 0, length: 0))
        #expect(editor.carets[0].anchor == .init(line: 1, character: 1))
        #expect(editor.carets[0].focus == .init(line: 2, character: 2))
        editor.undo(nil)
        #expect(editor.carets[0].anchor == .init(line: 0, character: 1))
        editor.redo(nil)
        #expect(editor.carets[0].focus == .init(line: 2, character: 2))
        let before = editor.carets[0]
        editor.select(.init(location: 0, length: 0))
        editor.setMarkedText("candidate\n", selectedRange: .init(location: 10, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(editor.carets[0].anchor == before.anchor && editor.carets[0].focus == before.focus)
        let original = editor.getText()
        #expect(try editor.applyEdits([
            .init(range: .init(start: .init(line: 1, character: 0), end: .init(line: 1, character: 0)), newText: "A"),
            .init(range: .init(start: .init(line: 2, character: 0), end: .init(line: 2, character: 0)), newText: "B")
        ]))
        #expect(editor.carets[0].anchor.character == before.anchor.character + 1)
        editor.undo(nil); #expect(editor.getText() == original && editor.canRedo())
        _ = try await editor.complete(.discard)
    }
    @Test @MainActor func diagnosticsNormalizeRangesAndUseBoundedHitQueries() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(); view.render(prepared)
        let editor = try view.beginEditing()
        let metadata = LineAnnotationMetadata("diagnostic")
        editor.setMarkers([.init(start: .init(line: 1, character: 2), end: .init(line: -9, character: -1), severity: .error, message: "Invalid", metadata: metadata)])
        #expect(editor.markers[0].start == .init(line: 0, character: 0))
        #expect(editor.marker(at: .init(line: 0, character: 2))?.metadata === metadata)
        #expect(editor.marker(at: .init(line: 1, character: 2)) == nil)
        editor.setMarkers([]); #expect(editor.markers(on: 0).isEmpty)
        _ = try await editor.complete(.discard)
    }
    @Test(arguments: [DiffOverflow.scroll, .wrap]) @MainActor
    func paintsDiagnosticWavesAndExternalSelection(overflow: DiffOverflow) async throws {
        let file = FileContents(name: "f.txt", contents: "diagnostic under this line\nexternal selection here\n")
        var options = DiffRenderOptions(); options.theme = "pierre-light"; options.diffStyle = .unified
        options.expandUnchanged = true; options.disableFileHeader = true; options.overflow = overflow
        let source = try await DiffHighlighter().prepare(oldFile: file, newFile: file, options: options)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 190, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 190, height: 240)); window.contentView = view
        view.render(source, options: options)
        let editor = try view.beginEditing(); await editor.waitForRendering()
        let marker = Marker(start: .init(line: 0, character: 0), end: .init(line: 0, character: 26), severity: .error, message: "Example error")
        editor.setMarkers([marker])
        editor.setCarets([.init(anchor: .init(line: 1, character: 0), focus: .init(line: 1, character: overflow == .wrap ? 18 : 8), metadata: .init(color: "#00f"))])
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var red = 0, blue = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if c.redComponent > 0.7 && c.greenComponent < 0.4 && c.blueComponent < 0.5 { red += 1 }
            if c.blueComponent > 0.8 && c.redComponent < 0.3 && c.greenComponent < 0.3 { blue += 1 }
        } }
        #expect(red > 10 && blue > 10)
        if overflow == .wrap {
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/swift-diffs-editor-overlays.png"))
        }
        _ = try await editor.complete(.discard)
    }
}

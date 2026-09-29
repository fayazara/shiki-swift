import AppKit
import ShikiCore
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct PredictionSuffixStyleTests {
    @Test @MainActor func movedSuffixPreservesBackgroundStrikeAndClearsChangedStyle() async throws {
        let helper = EditorPredictionIntegrationTests()
        let (window, view, editor) = try await helper.mount("let         tail\nnext\n"); defer { window.close() }
        let original = try #require(view.displayedDocument)
        var options = DiffRenderOptions(); options.theme = "pierre-light"; options.disableFileHeader = true; options.expandUnchanged = true
        options.diffStyle = .unified; options.fontName = "Menlo-Regular"
        func install(styled: Bool) {
            var tokens = original.newTokens
            tokens[0] = [.init(content: "let ", offset: 0, color: "#000000"),
                         .init(content: "        ", offset: 4, color: styled ? "#ff0000" : "#000000", bgColor: styled ? "#00ff00" : nil,
                               fontStyle: styled ? [.bold, .italic, .underline, .strikethrough] : .none),
                         .init(content: "tail", offset: 12, color: "#000000")]
            let document = HighlightedDiff(sourceID: original.sourceID, diff: original.diff, oldTokens: original.oldTokens, newTokens: tokens,
                foreground: "#000000", background: "#ffffff", palette: .init(isLight: true))
            view.renderEditor(document, options: options, annotations: [], expansions: [:]); view.layoutSubtreeIfNeeded()
        }
        func colorCounts(row: Int, middleOnly: Bool = false) throws -> (green: Int, red: Int) {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            let top = Int((CGFloat(row) * options.lineHeight + (middleOnly ? options.lineHeight / 2 : 0)) * scale)
            let bottom = Int((CGFloat(row + 1) * options.lineHeight - (middleOnly ? options.lineHeight / 2 - 1 : 0)) * scale)
            // Window bitmaps carry the display color profile; channel dominance
            // detects the known colors without assuming raw sRGB byte equality.
            var green = 0, red = 0
            for y in max(0, top)..<min(bitmap.pixelsHigh, bottom) {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.greenComponent > 0.85 && color.greenComponent > color.redComponent + 0.3 && color.greenComponent > color.blueComponent + 0.3 { green += 1 }
                    if color.redComponent > 0.8 && color.redComponent > color.greenComponent + 0.4 && color.redComponent > color.blueComponent + 0.4 { red += 1 }
                }
            }
            return (green, red)
        }
        install(styled: true)
        let preview = EditorPredictionPreview(helper.insertion("ghost\n"), document: editor.document)
        view.setPredictionPreview(preview)
        try helper.paint(view, path: "/tmp/swift-diffs-prediction-suffix-styles.png")
        #expect(try colorCounts(row: 1).green > 100)
        #expect(try colorCounts(row: 1, middleOnly: true).red > 50)
        install(styled: false); try helper.paint(view)
        #expect(try colorCounts(row: 1).green == 0 && colorCounts(row: 1, middleOnly: true).red == 0)
        install(styled: true)
        let longPreview = EditorPredictionPreview(helper.insertion(String(repeating: "x", count: 10_000)), document: editor.document)
        view.setPredictionPreview(longPreview)
        let canvas = try #require(view.scrollView.documentView)
        view.scrollView.contentView.scroll(to: .init(x: canvas.frame.width - view.bounds.width, y: 0))
        try helper.paint(view, path: "/tmp/swift-diffs-prediction-suffix-horizontal.png")
        #expect(try colorCounts(row: 0).green > 100)
        #expect(try colorCounts(row: 0, middleOnly: true).red > 50)
        view.setPredictionPreview(nil)
        _ = try await editor.complete(.discard)
    }
}

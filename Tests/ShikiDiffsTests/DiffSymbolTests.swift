import AppKit
import Testing
@testable import ShikiDiffs

@Suite struct DiffSymbolTests {
    @Test @MainActor func nativeSymbolsRenderDistinctShapesAndExpansionDirection() throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 96), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let sheet = SymbolSheet(frame: .init(x: 0, y: 0, width: 700, height: 96)); window.contentView = sheet
        let bitmap = try #require(sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds))
        sheet.cacheDisplay(in: sheet.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/swift-diffs-native-symbols.png"))
        var images = Set<Data>()
        for index in 0..<8 {
            let rect = NSRect(x: CGFloat(index) * 84 + 18, y: 12, width: 32, height: 32)
            let icon = try #require(sheet.bitmapImageRepForCachingDisplay(in: rect))
            sheet.cacheDisplay(in: rect, to: icon)
            images.insert(try #require(icon.representation(using: .png, properties: [:])))
        }
        // Seven distinct glyphs plus the vertically reversed expansion glyph.
        #expect(images.count == 8)
    }
}

@MainActor private final class SymbolSheet: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        let symbols: [DiffSymbol] = [.fileCode, .modified, .added, .deleted, .moved, .expand, .expandAll, .expand]
        let names = ["File", "Modified", "Added", "Deleted", "Moved", "Expand up", "Expand all", "Expand down"]
        for (index, symbol) in symbols.enumerated() {
            let x = CGFloat(index) * 84
            symbol.draw(in: .init(x: x + 18, y: 12, width: 32, height: 32), color: .black, flipY: index == 7)
            (names[index] as NSString).draw(at: .init(x: x + 4, y: 56), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
        }
    }
}

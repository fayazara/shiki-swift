import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct LineTrailingTextTests {
    /// Counts strongly magenta pixels, which nothing in the light theme's code uses.
    @MainActor private func magenta(in view: NSView) throws -> (total: Int, rows: ClosedRange<Int>?) {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var total = 0, low = Int.max, high = Int.min
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent > 0.6 && c.blueComponent > 0.6 && c.greenComponent < 0.35 {
                    total += 1; low = min(low, y); high = max(high, y)
                }
            }
        }
        return (total, total == 0 ? nil : low...high)
    }

    @MainActor private func makeView(_ code: String) async throws -> NativeFileView {
        let file = FileContents(name: "f.txt", contents: code)
        var options = DiffRenderOptions(); options.theme = "pierre-light"; options.disableFileHeader = true
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file, options: options)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 520, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeFileView(frame: window.contentView!.bounds)
        window.contentView = view
        view.render(document, file: file, options: options)
        return view
    }

    @Test @MainActor func paintsGhostTextAfterTheLineAndRepaintsWhenItChanges() async throws {
        let view = try await makeView("first\nsecond\nthird\n")
        #expect(try magenta(in: view).total == 0)

        view.lineTrailingText = [.init(lineNumber: 2, text: "You, 2 weeks ago • first commit", color: "#ff00ff")]
        let shown = try magenta(in: view)
        #expect(shown.total > 30)

        // It sits on the second line's row only.
        let rowHeight = Int(view.bounds.height) / 3
        let rows = try #require(shown.rows)
        #expect(rows.upperBound - rows.lowerBound < rowHeight * 2)

        // Moving it to another line moves the paint, and clearing it removes it.
        view.lineTrailingText = [.init(lineNumber: 3, text: "You, now", color: "#ff00ff")]
        let moved = try magenta(in: view)
        #expect(moved.total > 5)
        #expect(try #require(moved.rows).lowerBound > rows.lowerBound)
        view.lineTrailingText = []
        #expect(try magenta(in: view).total == 0)
    }

    @Test @MainActor func survivesARerenderAndIgnoresMissingLines() async throws {
        let view = try await makeView("only line\n")
        view.lineTrailingText = [.init(lineNumber: 1, text: "blame", color: "#ff00ff"), .init(lineNumber: 99, text: "nowhere", color: "#ff00ff")]
        let before = try magenta(in: view).total
        #expect(before > 5)
        view.rerender()
        #expect(try magenta(in: view).total == before)
    }

    @Test func defaultsToNoColor() {
        let ghost = LineTrailingText(lineNumber: 4, text: "x")
        #expect(ghost.color == nil && ghost.lineNumber == 4)
    }
}

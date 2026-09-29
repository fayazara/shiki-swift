import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct ReviewLifecycleCallbackTests {
    private func items() async throws -> [CodeViewItem] {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        return (0..<20).map { .init(id: "item\($0)", document: document) }
    }
    @Test @MainActor func sharedCallbackTracksRenamedIdentityAndRemount() async throws {
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var events: [(String, PostRenderPhase)] = []
        view.onPostRender = { item, phase in events.append((item.id, phase)) }
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems(try await items(), options: options)
        #expect(events.contains { $0.0 == "item0" && $0.1 == .mount })
        #expect(view.updateItemID("item0", to: "renamed"))
        let first = try #require(view.getRenderedItems().first)
        var directUnmounts = 0
        first.instance.onPostRender = { _, phase in if phase == .unmount { directUnmounts += 1 } }
        view.scrollToFile(at: 19)
        #expect(events.contains { $0.0 == "renamed" && $0.1 == .unmount })
        #expect(directUnmounts == 1)
        view.scrollToFile(at: 0)
        #expect(events.contains { $0.0 == "renamed" && $0.1 == .mount })
        view.reset()
        #expect(events.filter { $0.0 == "renamed" && $0.1 == .unmount }.count == 2)
    }
    @Test @MainActor func mountCallbackMayReplaceWholeReview() async throws {
        let input = try await items()
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var replaced = false
        view.onPostRender = { _, phase in
            if phase == .mount && !replaced {
                replaced = true
                try! view.setItems([.init(id: "replacement", document: input[0].document)])
            }
        }
        try view.setItems(input)
        #expect(view.fileCount == 1)
        #expect(view.getItem("replacement") != nil)
        #expect(view.getRenderedItems().map(\.id) == ["replacement"])
        view.reset()
    }
    @Test @MainActor func sharedUpdatesDoNotRequireReplacingInstanceCallback() async throws {
        let input = try await items()
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var updates = 0
        view.onPostRender = { _, phase in if phase == .update { updates += 1 } }
        try view.setItems(input)
        let first = try #require(view.getRenderedItems().first)
        var directUpdates = 0
        first.instance.onPostRender = { _, phase in if phase == .update { directUpdates += 1 } }
        first.instance.expandHunk(0, lines: 5)
        #expect(updates == 1 && directUpdates == 1)
        view.reset()
    }
}

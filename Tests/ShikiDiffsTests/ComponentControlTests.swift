import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct ComponentControlTests {
    @Test @MainActor func diffControlsPreserveSourceSelectionAndRefreshHeader() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var headers = 0, updates = 0
        view.headerRenderers = .init(renderHeaderMetadata: { _ in headers += 1; return nil })
        view.onPostRender = { _, phase in if phase == .update { updates += 1 } }
        view.render(document)
        let selection = LineSelection(side: .additions, startLine: 1, endLine: 2)
        view.selectLines(selection)
        var options = DiffRenderOptions(); options.fontSize = 19
        view.setOptions(options)
        let notes = [LineAnnotation(lineNumber: 1, text: "review")]
        view.setLineAnnotations(notes)
        let previousHeaders = headers
        view.rerender()
        #expect(headers == previousHeaders + 1)
        #expect(updates == 3)
        #expect(view.selectedLines == selection)
        #expect(view.displayedDocument?.sourceID == document.sourceID)
        #expect(view.displayedAnnotations == notes)
        view.setOptions(nil)
        #expect(updates == 3)
        view.cleanUp(); view.rerender()
        #expect(view.displayedDocument == nil)
    }
    @Test @MainActor func fileControlsAndCleanupDeliverOwnedLifecycle() async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeFileView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var phases: [PostRenderPhase] = []
        view.onPostRender = { instance, phase in
            #expect(instance === view); #expect(instance.file?.name == file.name)
            phases.append(phase)
        }
        view.render(document, file: file)
        var options = DiffRenderOptions(); options.collapsed = true
        view.setOptions(options)
        #expect(view.diffView.rowCount == 0)
        options.collapsed = false; view.setOptions(options)
        view.setLineAnnotations([.init(lineNumber: 1, text: "note")])
        view.rerender(); view.cleanUp(); view.cleanUp()
        #expect(phases.first == .mount && phases.last == .unmount)
        #expect(phases.filter { $0 == .unmount }.count == 1)
        #expect(view.file == nil && view.diffView.displayedDocument == nil)
    }
    @Test @MainActor func conflictOptionsAndAnnotationsRetainResolvedState() async throws {
        let view = NativeUnresolvedFileView()
        try view.render(file: .init(name: "f.txt", contents: "<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> branch\n"))
        #expect(try view.performResolution(0, resolution: .additions))
        let revision = view.state?.revision
        var options = DiffRenderOptions(); options.theme = "pierre-light"
        view.setOptions(options)
        view.setLineAnnotations([.init(lineNumber: 1, text: "retained")])
        view.rerender()
        #expect(view.state?.revision == revision)
        #expect(view.state?.file.contents == "new\n")
        #expect(view.diffView.displayedAnnotations.first?.text == "retained")
        view.cleanUp()
    }
}

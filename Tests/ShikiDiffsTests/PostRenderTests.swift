import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct PostRenderTests {
    private func document(_ name: String = "f.txt") -> HighlightedDiff {
        var diff = FileDiffMetadata(name: name)
        diff.isPartial = false
        return .init(diff: diff, oldTokens: [], newTokens: [], foreground: "#111111", background: "#ffffff")
    }
    @Test @MainActor func mountUpdateNoOpUnmountAndRemount() {
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 500, height: 200))
        var phases: [PostRenderPhase] = []
        view.onPostRender = { instance, phase in
            #expect(instance === view)
            if phase != .unmount { #expect(instance.displayedDocument != nil) }
            phases.append(phase)
        }
        let first = document()
        view.cleanUp(); #expect(phases.isEmpty)
        view.render(first); view.render(first)
        #expect(phases == [.mount])
        var options = DiffRenderOptions(); options.fontSize = 18
        view.render(first, options: options)
        #expect(phases == [.mount, .update])
        view.cleanUp(); view.cleanUp()
        #expect(phases == [.mount, .update, .unmount])
        #expect(view.displayedDocument == nil && view.rowCount == 0)
        view.render(first)
        #expect(phases == [.mount, .update, .unmount, .mount])
    }
    @Test @MainActor func callbacksCanReplaceSourceOrReenterCleanup() {
        let view = NativeDiffView(frame: .zero)
        let original = document("original"), replacement = document("replacement")
        var phases: [PostRenderPhase] = []
        view.onPostRender = { instance, phase in
            phases.append(phase)
            if phase == .mount { instance.render(replacement) }
        }
        view.render(original)
        #expect(view.displayedDocument?.id == replacement.id)
        #expect(phases == [.mount, .update])
        view.onPostRender = { instance, phase in
            phases.append(phase)
            if phase == .unmount { instance.render(original) }
        }
        view.cleanUp()
        #expect(view.displayedDocument?.id == original.id)
        #expect(phases.suffix(2) == [.unmount, .mount])
        view.onPostRender = { instance, phase in if phase == .unmount { instance.cleanUp() } }
        view.cleanUp()
        #expect(view.displayedDocument == nil)
    }
    @Test(arguments: [false, true]) @MainActor func cleanupDiscardsOrRecyclesEditor(_ recycle: Bool) async throws {
        let file = FileContents(name: "f.txt", contents: "one\ntwo\n")
        let prepared = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 500, height: 200))
        view.render(prepared)
        let editor = try view.beginEditing()
        editor.select(.init(location: 0, length: 0))
        editor.insertText("prefix ", replacementRange: .init(location: NSNotFound, length: 0))
        var phases: [PostRenderPhase] = []
        view.onPostRender = { _, phase in phases.append(phase) }
        view.cleanUp(recycle: recycle)
        #expect(phases == [.unmount])
        #expect(view.displayedDocument == nil && view.attachedEditor == nil)
        #expect(editor.isActive == recycle)
        if recycle {
            #expect(editor.isSuspended)
            view.render(prepared)
            try view.resumeEditing(editor)
            #expect(editor.document.getText() == "prefix one\ntwo\n")
            editor.undo(nil)
            #expect(editor.document.getText() == "one\ntwo\n")
            view.cleanUp()
            #expect(!editor.isActive)
        }
    }
    @Test @MainActor func mountCallbackCanCleanupConflictBeforeHighlightingStarts() throws {
        let view = NativeUnresolvedFileView()
        var phases: [PostRenderPhase] = []
        view.onPostRender = { instance, phase in
            phases.append(phase)
            if phase == .mount { instance.cleanUp() }
        }
        try view.render(file: .init(name: "f.txt", contents: "source\n"))
        #expect(phases == [.mount, .unmount])
        #expect(view.state == nil && !view.isPreparing)
        #expect(view.diffView.displayedDocument == nil)
    }
    @Test @MainActor func conflictLifecycleIncludesHighlightAndCleanup() async throws {
        let view = NativeUnresolvedFileView()
        let file = FileContents(name: "f.txt", contents: "<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> branch\n")
        var phases: [PostRenderPhase] = []
        view.onPostRender = { instance, phase in
            #expect(instance === view)
            #expect(instance.state != nil)
            phases.append(phase)
        }
        try view.render(file: file)
        #expect(phases == [.mount])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while view.isPreparing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparing && view.preparationError == nil)
        #expect(phases == [.mount, .update])
        view.cleanUp(); view.cleanUp()
        #expect(phases == [.mount, .update, .unmount])
        #expect(view.state == nil)
    }
    @Test @MainActor func conflictUnmountCanInstallReplacementWithoutBeingErased() throws {
        let view = NativeUnresolvedFileView()
        let old = FileContents(name: "old.txt", contents: "old\n")
        let new = FileContents(name: "new.txt", contents: "new\n")
        try view.render(file: old)
        view.onPostRender = { instance, phase in
            if phase == .unmount { try! instance.render(file: new) }
        }
        view.cleanUp()
        #expect(view.state?.file.name == "new.txt")
        #expect(view.diffView.displayedDocument?.diff.name == "new.txt")
        #expect(!view.diffView.isHidden)
        view.onPostRender = nil; view.cleanUp()
    }
}

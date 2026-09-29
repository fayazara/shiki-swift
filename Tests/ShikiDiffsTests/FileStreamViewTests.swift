import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct FileStreamViewTests {
    private func finite(_ chunks: [String]) -> AsyncThrowingStream<String, any Error> {
        .init { continuation in for chunk in chunks { continuation.yield(chunk) }; continuation.finish() }
    }
    @Test @MainActor func consumesSourceAndReportsTokenRecallsAndLifecycle() async throws {
        let view = NativeFileStreamView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var tokens: [String] = [], lifecycle: [String] = [], renders = 0, recalls = 0
        view.onStreamStart = { lifecycle.append("start") }
        view.onStreamWrite = { event in
            switch event {
            case .token(let token): tokens.append(token.content)
            case .recall(let count): tokens.removeLast(count); recalls += count
            }
        }
        view.onPreRender = { _ in renders += 1 }
        view.onStreamClose = { lifecycle.append("close") }
        view.onStreamAbort = { _ in lifecycle.append("abort") }
        view.startingLineIndex = 42
        view.setup(finite(["let val", "ue = 1\n", "print(value)"]), name: "stream.swift", configuration: .init(language: "swift"))
        await view.waitForCompletion()
        #expect(lifecycle == ["start", "close"] && renders == 4 && recalls > 0)
        #expect(tokens.joined() == "let value = 1\nprint(value)")
        #expect(view.fileView.file?.contents == tokens.joined())
        #expect(view.fileView.diffView.startingLineIndex == 42 && !view.isStreaming)
        view.cleanUp(); #expect(view.document == nil && lifecycle == ["start", "close"])
    }
    @Test @MainActor func sourceReplacementAbortsOnceAndPreventsLateWrites() async throws {
        let old = AsyncThrowingStream<String, any Error>.makeStream()
        let view = NativeFileStreamView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var aborted = 0, closed = 0
        view.onStreamAbort = { _ in aborted += 1 }; view.onStreamClose = { closed += 1 }
        view.setup(old.stream, name: "old.txt", configuration: .init(language: "text"))
        await Task.yield()
        view.setup(finite(["current\n"]), name: "current.txt", configuration: .init(language: "text"))
        await view.waitForCompletion()
        old.continuation.yield("stale\n"); old.continuation.finish()
        await Task.yield()
        #expect(aborted == 1 && closed == 1)
        #expect(view.fileView.file?.name == "current.txt" && view.fileView.file?.contents == "current\n")
        view.cleanUp()
    }
    @Test @MainActor func renderCallbackCanReplaceSourceWithoutInstallingOldSnapshot() async throws {
        let view = NativeFileStreamView(frame: .init(x: 0, y: 0, width: 500, height: 300))
        var replaced = false, closed = 0
        view.onPreRender = { view in
            guard !replaced else { return }; replaced = true
            view.setup(finite(["new"]), name: "new.txt", configuration: .init(language: "text"))
        }
        view.onStreamClose = { closed += 1 }
        view.setup(finite(["old"]), name: "old.txt", configuration: .init(language: "text"))
        await view.waitForCompletion(); await view.waitForCompletion()
        #expect(view.fileView.file?.contents == "new" && closed == 1)
        view.cleanUp()
    }
    @Test @MainActor func failurePreservesLastSnapshotAndDetachedViewsDoNotStayAlive() async throws {
        enum Failure: Error { case expected }
        let source = AsyncThrowingStream<String, any Error> { c in c.yield("partial"); c.finish(throwing: Failure.expected) }
        let view = NativeFileStreamView(frame: .zero)
        var failures = 0
        view.onStreamAbort = { error in #expect(error is Failure); failures += 1 }
        view.setup(source, name: "failure.txt", configuration: .init(language: "text"))
        await view.waitForCompletion()
        #expect(failures == 1 && view.error != nil && view.fileView.file?.contents == "partial")
        let pending = AsyncThrowingStream<String, any Error>.makeStream()
        var detached: NativeFileStreamView? = NativeFileStreamView(frame: .zero)
        weak var weakView = detached
        detached?.setup(pending.stream, name: "pending.txt", configuration: .init(language: "text"))
        await Task.yield(); detached = nil
        #expect(weakView == nil)
        pending.continuation.finish()
        view.cleanUp()
    }
    @Test @MainActor func adaptiveStreamSwitchesCachedThemesWithoutRestartOrRecall() async throws {
        let config = try await DiffHighlighter().streamConfiguration(language: "swift", themes: .init())
        let view = NativeFileStreamView(frame: .init(x: 0, y: 0, width: 500, height: 120))
        view.themeAppearance = .light
        var starts = 0, closes = 0, writes = 0, switched = false
        view.onStreamStart = { starts += 1 }; view.onStreamClose = { closes += 1 }
        view.onStreamWrite = { _ in writes += 1 }
        view.onPostRender = { view in
            guard !switched, view.document != nil else { return }; switched = true
            let original = view.document!, eventCount = writes
            #expect(original.palette.isLight)
            view.fileView.diffView.selectText(.init(side: .additions, anchor: .init(line: 0, character: 0), head: .init(line: 0, character: 3)))
            let selection = view.fileView.diffView.selectedText()
            view.themeAppearance = .dark
            #expect(view.document?.palette.isLight == false)
            #expect(view.document?.sourceID == original.sourceID)
            #expect(view.fileView.diffView.selectedText() == selection)
            view.themeAppearance = .light
            #expect(view.document?.id == original.id && writes == eventCount)
        }
        view.setup(finite(["let first = 1\n", "let second = 2\n"]), name: "f.swift", configuration: config)
        await view.waitForCompletion()
        #expect(switched && starts == 1 && closes == 1)
        #expect(view.fileView.file?.contents == "let first = 1\nlet second = 2\n")
        view.themeAppearance = .system; view.appearance = NSAppearance(named: .darkAqua)
        #expect(view.document?.palette.isLight == false)
        view.appearance = NSAppearance(named: .aqua)
        #expect(view.document?.palette.isLight == true)
        view.cleanUp(); view.themeAppearance = .dark; #expect(view.document == nil)
    }
    @Test @MainActor func preRenderAppearanceChangeKeepsNewestPresentation() async throws {
        let config = try await DiffHighlighter().streamConfiguration(language: "text", themes: .init())
        let view = NativeFileStreamView(frame: .zero)
        view.themeAppearance = .light
        var switched = false
        view.onPreRender = { view in
            guard !switched else { return }; switched = true; view.themeAppearance = .dark
        }
        view.setup(finite(["text"]), name: "f.txt", configuration: config)
        await view.waitForCompletion()
        #expect(view.document?.palette.isLight == false && view.fileView.file?.contents == "text")
        view.cleanUp()
    }

}

import AppKit
import Shiki
import SwiftUI
import Testing
@testable import ShikiDiffs

private actor EditorThemeGate {
    private(set) var arrived = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { arrived = true; if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor struct EditorHighlighterTests {
    @Test(arguments: [false, true]) func replacingPendingHighlighterPreservesEditingAndRejectsStaleTheme(oldFails: Bool) async throws {
        let old = DiffHighlighter(), replacement = DiffHighlighter(), gate = EditorThemeGate()
        await old.registerCustomTheme("replacement-fixture") {
            await gate.wait()
            if oldFails { throw DiffError.invalidPatch("stale theme failure") }
            return .init(name: "replacement-fixture", type: .light, colors: ["editor.foreground": "#111111", "editor.background": "#ffffff"])
        }
        try await replacement.registerTheme(.init(name: "replacement-fixture", type: .dark, colors: ["editor.foreground": "#aabbcc", "editor.background": "#123456"]))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let editor = NativeEditor(frame: .init(x: 0, y: 0, width: 600, height: 240), highlighter: old); window.contentView = editor
        var options = DiffRenderOptions(); options.theme = "replacement-fixture"
        var errors = 0; editor.onError = { _ in errors += 1 }
        editor.render(.init(name: "f.txt", contents: "original"), options: options)
        editor.layoutSubtreeIfNeeded()
        let arrivalDeadline = ContinuousClock.now + .seconds(3)
        while !(await gate.arrived) && ContinuousClock.now < arrivalDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.arrived)
        editor.replaceCharacters(in: NSRange(location: 8, length: 0), with: "!")
        editor.select([NSRange(location: 2, length: 0)])
        editor.highlighter = replacement
        let readyDeadline = ContinuousClock.now + .seconds(3)
        while editor.textView.backgroundColor != NSColor.diffHex("#123456") && ContinuousClock.now < readyDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.textView.backgroundColor == NSColor.diffHex("#123456"))
        #expect(editor.textView.string == "original!")
        #expect(editor.textView.selectedRange() == NSRange(location: 2, length: 0))
        #expect(editor.textView.undoManager?.canUndo == true)
        await gate.release()
        _ = try? await old.resolveTheme("replacement-fixture")
        try await Task.sleep(for: .milliseconds(20))
        #expect(editor.textView.backgroundColor == NSColor.diffHex("#123456"))
        #expect(errors == 0)
        editor.textView.undoManager?.undo()
        #expect(editor.textView.string == "original")
    }

    @Test func swiftUIWrapperRetainsDefaultAndSwitchesSuppliedHighlighter() async throws {
        let first = DiffHighlighter(), second = DiffHighlighter()
        let host = NSHostingView(rootView: EditorView(text: .constant("text"), name: "f.txt", highlighter: first))
        host.frame = .init(x: 0, y: 0, width: 600, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }; window.contentView = host
        func find(_ view: NSView) -> NativeEditor? {
            if let editor = view as? NativeEditor { return editor }
            return view.subviews.lazy.compactMap(find).first
        }
        host.layoutSubtreeIfNeeded()
        let editor = try #require(find(host))
        #expect(editor.highlighter === first)
        host.rootView = EditorView(text: .constant("text"), name: "f.txt", highlighter: second)
        host.layoutSubtreeIfNeeded()
        #expect(find(host) === editor)
        #expect(editor.highlighter === second)
        host.rootView = EditorView(text: .constant("text"), name: "f.txt")
        host.layoutSubtreeIfNeeded()
        let fallback = editor.highlighter
        #expect(fallback !== first && fallback !== second)
        host.rootView = EditorView(text: .constant("text"), name: "f.txt", wrapsLines: true)
        host.layoutSubtreeIfNeeded()
        #expect(find(host) === editor && editor.highlighter === fallback)
    }
}

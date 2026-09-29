import AppKit
import Shiki
import Testing
@testable import ShikiDiffs

@MainActor struct FallbackColorTests {
    @Test func emptyTokenColorsInheritThemeLikeAbsentColors() throws {
        let text = "Fallback foreground"
        var diff = FileDiffMetadata(name: "f.txt"); diff.isPartial = false
        diff.deletionLines = [text]; diff.additionLines = [text]
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 700, height: 120))
        var options = DiffRenderOptions(); options.disableFileHeader = true; options.disableLineNumbers = true
        for style in [FontStyle.none, .strikethrough] {
            func pixels(color: String?, background: String?) throws -> Data {
                let token = ThemedToken(content: text, offset: 0, color: color, bgColor: background, fontStyle: style)
                let document = HighlightedDiff(diff: diff, oldTokens: [[token]], newTokens: [[token]], foreground: "#d700af", background: "#ffffff", palette: .init(isLight: true))
                view.render(document, options: options); view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                return try #require(bitmap.representation(using: .png, properties: [:]))
            }
            let inherited = try pixels(color: nil, background: nil)
            #expect(try pixels(color: "", background: "") == inherited)
            #expect(try pixels(color: "#d700af", background: nil) == inherited)
            #expect(try pixels(color: "#00aa00", background: nil) != inherited)
        }
    }

    @Test func editorFallbackKeepsThemeAndLimitChangesRetokenize() async throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let editor = NativeEditor(frame: .init(x: 0, y: 0, width: 700, height: 250)); window.contentView = editor
        let file = FileContents(name: "f.swift", contents: "let value = 123\n")
        var options = DiffRenderOptions(); options.theme = "pierre-light"; options.tokenizeMaxLineLength = 3
        editor.render(file, options: options); editor.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        while editor.styledTokenCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.styledTokenCount > 0)
        let manager = try #require(editor.textView.layoutManager)
        #expect(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
        #expect(editor.textView.textColor != nil)
        options.tokenizeMaxLineLength = 1000
        editor.render(file, options: options)
        let recolorDeadline = ContinuousClock.now + .seconds(3)
        while manager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil && ContinuousClock.now < recolorDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
    }
}

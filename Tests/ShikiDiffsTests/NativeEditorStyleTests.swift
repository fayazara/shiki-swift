import AppKit
import Shiki
import Testing
@testable import ShikiDiffs

@MainActor struct NativeEditorStyleTests {
    @Test func syntaxTraitsUseSelectedFontAndClearWithTheme() async throws {
        let worker = DiffHighlighter()
        let grammar = try JSONDecoder().decode(LanguageRegistration.self, from: Data(#"{"name":"editor-styles","scopeName":"source.editor-styles","patterns":[{"match":"styled","name":"entity.styled"}]}"#.utf8))
        try await worker.registerLanguage(grammar)
        let theme = try JSONDecoder().decode(ShikiTheme.self, from: Data(##"{"name":"editor-styles","type":"light","colors":{"editor.foreground":"#112233","editor.background":"#ffffff"},"tokenColors":[{"scope":"entity.styled","settings":{"foreground":"#113355","background":"#ffeedd","fontStyle":"bold italic underline strikethrough"}}]}"##.utf8))
        try await worker.registerTheme(theme)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let editor = NativeEditor(frame: .init(x: 0, y: 0, width: 700, height: 250), highlighter: worker); window.contentView = editor
        let file = FileContents(name: "f.txt", contents: "styled plain\n", lang: "editor-styles")
        var options = DiffRenderOptions(); options.theme = "editor-styles"; options.fontName = "Menlo-Regular"
        editor.render(file, options: options); editor.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        while editor.styledTokenCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let manager = try #require(editor.textView.layoutManager)
        func attribute(_ key: NSAttributedString.Key, at index: Int = 0) -> Any? {
            if key == .font { return editor.textView.textStorage?.attribute(key, at: index, effectiveRange: nil) }
            return manager.temporaryAttribute(key, atCharacterIndex: index, effectiveRange: nil)
        }
        let font = try #require(attribute(.font) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains([.boldFontMask, .italicFontMask]))
        #expect(font.familyName == NSFont(name: "Menlo-Regular", size: options.fontSize)?.familyName)
        #expect(attribute(.underlineStyle) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attribute(.strikethroughStyle) as? Int == NSUnderlineStyle.single.rawValue)
        // Native Shiki currently emits no token background for this theme rule.
        #expect(attribute(.backgroundColor) == nil)
        let plainFont = try #require(attribute(.font, at: 8) as? NSFont)
        #expect(!NSFontManager.shared.traits(of: plainFont).contains(.boldFontMask))
        options.fontSize = 20
        editor.render(file, options: options)
        #expect((attribute(.font) as? NSFont)?.pointSize == 20)
        options.theme = "pierre-light"
        editor.render(file, options: options)
        let clearedDeadline = ContinuousClock.now + .seconds(3)
        while attribute(.strikethroughStyle) != nil && ContinuousClock.now < clearedDeadline { try await Task.sleep(for: .milliseconds(10)) }
        for key in [NSAttributedString.Key.backgroundColor, .underlineStyle, .strikethroughStyle] { #expect(attribute(key) == nil) }
        let resetFont = try #require(attribute(.font) as? NSFont)
        #expect(!NSFontManager.shared.traits(of: resetFont).contains(.boldFontMask))
        #expect(!NSFontManager.shared.traits(of: resetFont).contains(.italicFontMask))
    }
}
